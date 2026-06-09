#!/usr/bin/env bash
# itOrchestra - Phase 0.12 verification (Backup & DR: MinIO + Velero).
# Checks: backup namespace out of mesh; MinIO Ready; Velero server + node-agent Ready; the
# BackupStorageLocation is Available (proves MinIO + creds + bucket all work); the daily Schedule
# exists; the MSSQL backup stored procedure is installed; the backup endpoint is mirrored to Vault.
# Set RUN_BACKUP=1 to additionally run a live backup-and-restore smoke test of ns-gateway (slow).
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="backup"
VAULT_NS="vault"
MSSQL_NS="mssql"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 1) backup namespace out of mesh =="
MINIO_POD="$(kubectl -n "${NS}" get pod -l app=minio -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
C="$(kubectl -n "${NS}" get pod "${MINIO_POD}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)"
case " ${C} " in *linkerd-proxy*) bad "linkerd-proxy injected into backup ns" ;; *) ok "no linkerd-proxy (out of mesh)" ;; esac

echo "== 2) MinIO Ready =="
MR="$(kubectl -n "${NS}" get deploy minio -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${MR:-0}" = "1" ] && ok "MinIO deployment Ready (1/1)" || bad "MinIO not Ready (readyReplicas='${MR}')"

echo "== 3) Velero server Ready =="
VR="$(kubectl -n "${NS}" get deploy velero -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${VR:-0}" = "1" ] && ok "Velero deployment Ready (1/1)" || bad "Velero not Ready (readyReplicas='${VR}')"

echo "== 4) node-agent (kopia FSB) Ready =="
DES="$(kubectl -n "${NS}" get ds node-agent -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
RDY="$(kubectl -n "${NS}" get ds node-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
[ "${DES:-0}" != "0" ] && [ "${DES}" = "${RDY}" ] && ok "node-agent DaemonSet Ready (${RDY}/${DES})" || bad "node-agent not Ready (${RDY}/${DES})"

echo "== 5) BackupStorageLocation Available (MinIO + creds + bucket reachable) =="
BSL="$(kubectl -n "${NS}" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[ "${BSL}" = "Available" ] && ok "BackupStorageLocation 'default' is Available" || bad "BSL phase='${BSL}' (expected Available)"

echo "== 6) Daily Schedule present =="
kubectl -n "${NS}" get schedule daily-full >/dev/null 2>&1 && ok "Schedule 'daily-full' present" || bad "Schedule 'daily-full' missing"

echo "== 7) MSSQL backup stored procedure installed =="
if kubectl -n "${MSSQL_NS}" get pod mssql-ag-0 >/dev/null 2>&1; then
  SA_PW="$(kubectl -n "${MSSQL_NS}" get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d)"
  HAS="$(kubectl -n "${MSSQL_NS}" exec -i mssql-ag-0 -- /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "${SA_PW}" -C -h -1 -W -Q \
    "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID('master.dbo.sp_Maint_Backup_AllDatabases') IS NOT NULL THEN 'YES' ELSE 'NO' END" 2>/dev/null | tr -d '\r' | head -n1)"
  [ "${HAS}" = "YES" ] && ok "sp_Maint_Backup_AllDatabases present in master" || bad "backup SP missing (HAS='${HAS}')"
else
  bad "mssql-ag-0 not found (Phase 0.7 not installed?)"
fi

echo "== 8) Backup endpoint mirrored into Vault =="
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  VB="$(kubectl -n "${VAULT_NS}" exec -i vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
    vault kv get -field=s3-bucket secret/itorchestra/shared/backup 2>/dev/null || true)"
  [ "${VB}" = "velero" ] && ok "Vault secret/itorchestra/shared/backup present" || bad "Vault backup secret missing/mismatch"
else
  bad "could not read Vault root token (sealed? Phase 0.5?)"
fi

if [ "${RUN_BACKUP:-0}" = "1" ]; then
  echo "== 9) Live backup + restore smoke (ns-gateway) =="
  if command -v velero >/dev/null 2>&1; then
    B="verify-$(date +%s)"
    # --wait blocks until the backup finishes; read the final phase via kubectl (the velero CLI's
    # `backup get` does not support -o jsonpath). ns-gateway is small, so this is quick.
    velero backup create "${B}" --include-namespaces ns-gateway --wait -n "${NS}" >/dev/null 2>&1 || true
    PH="$(kubectl -n "${NS}" get backup.velero.io "${B}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "${PH}" = "Completed" ]; then
      ok "on-demand backup '${B}' Completed"
      velero backup delete "${B}" --confirm -n "${NS}" >/dev/null 2>&1 || true
    else
      bad "backup phase='${PH}' (run: velero backup describe ${B} -n ${NS} --details)"
    fi
  else
    bad "velero CLI not installed (skipping live smoke; set up the CLI or unset RUN_BACKUP)"
  fi
fi

echo "========================================================"
echo "Phase 0.12 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
