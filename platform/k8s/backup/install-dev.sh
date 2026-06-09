#!/usr/bin/env bash
# Deploy the Phase 0.12 Backup & DR layer into the 'backup' namespace:
#   1) MinIO  - single-instance S3 endpoint, bytes on the VM host disk (hostPath PV).
#   2) Velero - cluster backup/restore (resources + PV data via kopia FSB) targeting MinIO,
#               with app-consistent backup hooks (MSSQL stored-proc backup, Redis SAVE).
#   3) A daily Schedule, the MSSQL backup stored procedure, and a Vault mirror of the endpoint.
#
# Idempotent: secrets/bucket/Helm release/SP are all guarded and safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="backup"
VAULT_NS="vault"
MSSQL_NS="mssql"
BUCKET="velero"
VELERO_CHART_VERSION="${VELERO_CHART_VERSION:-12.0.2}"   # chart 12.0.2 -> Velero v1.18.1
MC_IMAGE="${MC_IMAGE:-minio/mc:RELEASE.2024-11-21T17-21-54Z}"
BACKUP_HOSTPATH="${BACKUP_HOSTPATH:-/srv/itorchestra/backups/minio}"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found." >&2; exit 1; }

echo "==> [0.12/backup] Ensuring the 'backup' namespace (privileged PSA, out of mesh)"
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

echo "==> Ensuring MinIO root credentials (secret minio-creds)"
if ! kubectl -n "${NS}" get secret minio-creds >/dev/null 2>&1; then
  kubectl -n "${NS}" create secret generic minio-creds \
    --from-literal=root-user="itorchestra-backup" \
    --from-literal=root-password="$(openssl rand -hex 24)"
  echo "    created secret minio-creds"
else
  echo "    secret minio-creds already exists (skip)"
fi
MINIO_USER="$(kubectl -n "${NS}" get secret minio-creds -o jsonpath='{.data.root-user}' | base64 -d)"
MINIO_PW="$(kubectl   -n "${NS}" get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"

echo "==> Deploying MinIO (hostPath=${BACKUP_HOSTPATH})"
sed "s#/srv/itorchestra/backups/minio#${BACKUP_HOSTPATH}#g" "${SCRIPT_DIR}/minio/pv-pvc.yaml" | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/minio/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/minio/deployment.yaml"
kubectl -n "${NS}" rollout status deployment/minio --timeout=300s

echo "==> Creating the '${BUCKET}' bucket (idempotent)"
POD="minio-mc-$$"
kubectl -n "${NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${NS}" run "${POD}" --restart=Never --image="${MC_IMAGE}" \
  --env=MC_HOST_local="http://${MINIO_USER}:${MINIO_PW}@minio.${NS}.svc.cluster.local:9000" \
  --command -- sh -c "mc mb -p local/${BUCKET}; mc ls local/" >/dev/null 2>&1 || true
kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD}" --timeout=120s >/dev/null 2>&1 || true
echo "    mc output:"; kubectl -n "${NS}" logs "${POD}" 2>/dev/null | sed 's/^/      /' || true
kubectl -n "${NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true

echo "==> Ensuring Velero's MinIO credentials (secret velero-minio, key 'cloud')"
CLOUD_TMP="$(mktemp)"
cat > "${CLOUD_TMP}" <<EOF
[default]
aws_access_key_id=${MINIO_USER}
aws_secret_access_key=${MINIO_PW}
EOF
kubectl -n "${NS}" delete secret velero-minio --ignore-not-found >/dev/null
kubectl -n "${NS}" create secret generic velero-minio --from-file=cloud="${CLOUD_TMP}" >/dev/null
rm -f "${CLOUD_TMP}"

echo "==> Installing Velero ${VELERO_CHART_VERSION} (chart) via Helm"
# Not silenced + --force-update: a transient failure to reach the chart repo must surface here
# (and abort) rather than be hidden, then fail confusingly on the next 'helm repo update'.
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
helm repo update vmware-tanzu >/dev/null
helm upgrade --install velero vmware-tanzu/velero \
  --namespace "${NS}" \
  --version "${VELERO_CHART_VERSION}" \
  -f "${SCRIPT_DIR}/velero/values.yaml" \
  --wait --timeout 8m

echo "==> Waiting for the node-agent (kopia) DaemonSet"
kubectl -n "${NS}" rollout status daemonset/node-agent --timeout=300s || true

echo "==> Applying the daily backup Schedule (with app-consistent hooks)"
kubectl apply -f "${SCRIPT_DIR}/velero/schedules.yaml"

echo "==> Installing the MSSQL backup stored procedure (if the AG is present)"
if kubectl -n "${MSSQL_NS}" get pod mssql-ag-0 >/dev/null 2>&1; then
  SA_PW="$(kubectl -n "${MSSQL_NS}" get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d)"
  kubectl -n "${MSSQL_NS}" exec -i mssql-ag-0 -- \
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${SA_PW}" -C -b \
    < "${SCRIPT_DIR}/mssql/sp_maint_backup.sql"
  echo "    installed master.dbo.sp_Maint_Backup_AllDatabases on mssql-ag-0"
else
  echo "    !! mssql-ag-0 not found (Phase 0.7?); skipping SP install (hook will no-op until present)"
fi

echo "==> Mirroring the backup endpoint into Vault (secret/itorchestra/shared/backup)"
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  # Non-fatal: if Vault is sealed/unavailable, warn and continue (the mirror is a convenience
  # catalog; the backup layer itself does not depend on it). Re-run after unsealing to seed it.
  if ! kubectl -n "${VAULT_NS}" exec -i vault-0 -- env \
    VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
    MINIO_USER="${MINIO_USER}" MINIO_PW="${MINIO_PW}" BUCKET="${BUCKET}" \
    sh -s <<'EOSH'
set -e
vault kv put secret/itorchestra/shared/backup \
  s3-endpoint="http://minio.backup.svc.cluster.local:9000" \
  s3-bucket="$BUCKET" \
  s3-access-key="$MINIO_USER" \
  s3-secret-key="$MINIO_PW"
echo "  seeded: secret/itorchestra/shared/backup"
EOSH
  then
    echo "    !! Vault mirror skipped (Vault sealed/unavailable). Unseal it, then re-run this script." >&2
  fi
else
  echo "    !! could not read Vault root token (Phase 0.5?); skipping Vault mirror" >&2
fi

echo "==> Backup layer state:"
kubectl -n "${NS}" get pods,svc,pvc 2>/dev/null
kubectl -n "${NS}" get backupstoragelocations.velero.io,schedules.velero.io 2>/dev/null || true
echo "==> [0.12/backup] Deploy done."
echo "    MinIO console:  kubectl -n ${NS} port-forward svc/minio 9001:9001  (user: ${MINIO_USER})"
echo "    On-demand run:  velero backup create manual-\$(date +%s) --from-schedule daily-full -n ${NS}"
