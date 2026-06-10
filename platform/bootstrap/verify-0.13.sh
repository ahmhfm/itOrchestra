#!/usr/bin/env bash
# itOrchestra - Phase 0.13 verification (IaC + GitOps bootstrap).
# Checks: ArgoCD core workloads Ready, External Secrets Operator Ready, the Vault-backed
# ClusterSecretStore Ready (proves ESO<->Vault auth), the Vault 'external-secrets' role present, and
# the App-of-Apps root + its first child Application registered/synced.
#
# Steps 3/5/6 poll, because ArgoCD reconciles the children a little after `terraform apply` returns.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
ARGO_NS="argocd"
ESO_NS="external-secrets"
VAULT_NS="vault"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 1) ArgoCD core workloads Ready =="
# server + repo-server are Deployments; the application-controller is a StatefulSet in recent charts.
for w in argocd-server argocd-repo-server argocd-application-controller; do
  if kubectl -n "${ARGO_NS}" get deploy "${w}" >/dev/null 2>&1; then
    AV="$(kubectl -n "${ARGO_NS}" get deploy "${w}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
    [ "${AV:-0}" -ge 1 ] 2>/dev/null && ok "${w} available (${AV})" || bad "${w} not available (avail='${AV}')"
  elif kubectl -n "${ARGO_NS}" get statefulset "${w}" >/dev/null 2>&1; then
    RR="$(kubectl -n "${ARGO_NS}" get statefulset "${w}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [ "${RR:-0}" -ge 1 ] 2>/dev/null && ok "${w} ready (${RR})" || bad "${w} not ready (ready='${RR}')"
  else
    bad "${w} not found in ${ARGO_NS}"
  fi
done

echo "== 2) External Secrets Operator Ready =="
ESOAV="$(kubectl -n "${ESO_NS}" get deploy external-secrets -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
[ "${ESOAV:-0}" -ge 1 ] 2>/dev/null && ok "external-secrets controller available (${ESOAV})" || bad "ESO controller not available (avail='${ESOAV}')"
kubectl -n "${ESO_NS}" get deploy external-secrets-webhook >/dev/null 2>&1 \
  && ok "external-secrets-webhook present" || bad "external-secrets-webhook missing"

echo "== 3) ClusterSecretStore vault-backend Ready (waits up to 120s for ArgoCD sync + Vault auth) =="
CSS=""
for _ in $(seq 1 24); do
  CSS="$(kubectl get clustersecretstore vault-backend -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "${CSS}" = "True" ] && break
  sleep 5
done
[ "${CSS}" = "True" ] && ok "ClusterSecretStore vault-backend Ready (ESO authenticated to Vault)" \
  || bad "ClusterSecretStore not Ready (status='${CSS}'); check the Vault role/fence + ESO logs"

echo "== 4) Vault 'external-secrets' role present + bound to ESO SA =="
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)"
if [ -n "${ROOT_TOKEN}" ]; then
  ESAN="$(kubectl -n "${VAULT_NS}" exec -i vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
            vault read -field=bound_service_account_names auth/kubernetes/role/external-secrets 2>/dev/null || true)"
  case "${ESAN}" in *external-secrets*) ok "Vault role 'external-secrets' bound to ESO SA" ;; *) bad "Vault role 'external-secrets' missing/misbound (SA='${ESAN}')" ;; esac
else
  bad "could not read Vault root token (sealed? Phase 0.5?)"
fi

echo "== 5) App-of-Apps root Application registered =="
RAPP="$(kubectl -n "${ARGO_NS}" get application itorchestra-root -o jsonpath='{.metadata.name}' 2>/dev/null)"
[ "${RAPP}" = "itorchestra-root" ] && ok "Application itorchestra-root present" || bad "root Application itorchestra-root missing"
SYNC=""
for _ in $(seq 1 12); do
  SYNC="$(kubectl -n "${ARGO_NS}" get application itorchestra-root -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  [ "${SYNC}" = "Synced" ] && break
  sleep 5
done
case "${SYNC}" in
  Synced) ok "itorchestra-root Synced" ;;
  "")     bad "itorchestra-root has no sync status yet (repo unreachable? private repo without creds?)" ;;
  *)      echo "  [WARN] itorchestra-root sync='${SYNC}' (still progressing)" ;;
esac

echo "== 6) platform-secrets child Application present =="
CHILD=""
for _ in $(seq 1 12); do
  CHILD="$(kubectl -n "${ARGO_NS}" get application platform-secrets -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
  [ -n "${CHILD}" ] && break
  sleep 5
done
[ -n "${CHILD}" ] && ok "child Application platform-secrets present (App-of-Apps working)" \
  || bad "child Application platform-secrets missing (root not synced yet?)"

echo "========================================================"
echo "Phase 0.13 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
