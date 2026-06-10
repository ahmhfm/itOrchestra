#!/usr/bin/env bash
# Phase 0.13: seed ONLY the External Secrets Operator's Vault policy + Kubernetes-auth role, plus
# (re)apply the Vault ingress fence so the external-secrets namespace can reach Vault on 8200.
#
# Unlike re-running k8s/vault/install-dev.sh, this does NOT touch Helm (no upgrade / pod roll). It
# assumes Vault was installed in Phase 0.5; if Vault is sealed (e.g. after a node reboot) it unseals
# it using the dev-stored key, waits for Ready, then seeds the role. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"   # platform/
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="vault"

echo "==> Reapplying the Vault ingress fence (allows external-secrets -> 8200)"
kubectl apply -f "${ROOT}/k8s/vault/networkpolicy.yaml"

echo "==> Waiting for the vault-0 pod to be Running"
PHASE=""
for _ in $(seq 1 60); do
  PHASE="$(kubectl -n "${NS}" get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${PHASE}" = "Running" ] && break
  sleep 5
done
[ "${PHASE}" = "Running" ] || { echo "!! vault-0 not Running (phase='${PHASE}'); is Phase 0.5 done?" >&2; exit 1; }

ROOT_TOKEN="$(kubectl -n "${NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)"
UNSEAL_KEY="$(kubectl -n "${NS}" get secret vault-unseal-keys -o jsonpath='{.data.unseal-key}' 2>/dev/null | base64 -d)"
[ -n "${ROOT_TOKEN}" ] || { echo "!! cannot read Vault root token (secret vault/vault-unseal-keys missing - Phase 0.5?)" >&2; exit 1; }

echo "==> Unsealing Vault if sealed"
SEALED="$(kubectl -n "${NS}" exec vault-0 -- vault status -format=json 2>/dev/null | tr -d ' \n' | grep -o '"sealed":[a-z]*' | head -n1 | cut -d: -f2 || true)"
if [ "${SEALED}" = "true" ]; then
  [ -n "${UNSEAL_KEY}" ] || { echo "!! Vault sealed but no unseal key stored" >&2; exit 1; }
  kubectl -n "${NS}" exec vault-0 -- vault operator unseal "${UNSEAL_KEY}" >/dev/null
  echo "    unsealed"
else
  echo "    already unsealed (sealed='${SEALED}')"
fi

echo "==> Waiting for vault-0 to report Ready"
kubectl -n "${NS}" wait --for=condition=Ready pod/vault-0 --timeout=120s

echo "==> Seeding the external-secrets policy + role (idempotent)"
kubectl -n "${NS}" exec -i vault-0 -- env \
  VAULT_ADDR="http://127.0.0.1:8200" \
  VAULT_TOKEN="${ROOT_TOKEN}" \
  sh -s <<'EOSH'
set -e
vault policy write itorchestra-external-secrets - <<'EOP'
path "secret/data/itorchestra/*" {
  capabilities = ["read"]
}
path "secret/metadata/itorchestra/*" {
  capabilities = ["read", "list"]
}
EOP

vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=itorchestra-external-secrets \
  ttl=1h

echo "  seeded: policy itorchestra-external-secrets + role external-secrets"
EOSH

echo "==> Done seeding the ESO Vault role."
