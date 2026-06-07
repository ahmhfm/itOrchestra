#!/usr/bin/env bash
# Deploy HashiCorp Vault (dev) into the 'vault' namespace: Helm install (Raft + Longhorn
# PVC) + Agent Injector, then initialize/unseal, enable KV v2 + Kubernetes auth, seed the
# Phase 0.4 secrets, and create a sample policy/role.
#
# DEV ONLY: a single unseal key + the root token are stored in the k8s secret
# 'vault/vault-unseal-keys' for convenience. Prod uses Shamir split keys + KMS auto-unseal
# and never persists the root token.
#
# Idempotent: re-runs reuse the stored unseal key, re-unseal if sealed, and re-apply config.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="vault"
CHART_VERSION="0.32.0"
KC_NS="keycloak"
GW_CLIENT_SECRET="dev-gateway-secret-change-me"   # matches the api-gateway client in the realm import.

exec_v() { kubectl -n "${NS}" exec vault-0 -- "$@"; }

echo "==> [0.5/vault] Ensuring namespace is NOT meshed (Vault is critical infra in dev)"
kubectl annotate namespace "${NS}" linkerd.io/inject=disabled --overwrite >/dev/null

echo "==> Adding HashiCorp helm repo + installing the chart (v${CHART_VERSION})"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null
# No --wait: the pod stays NotReady until it is unsealed below.
helm upgrade --install vault hashicorp/vault \
  --namespace "${NS}" \
  --version "${CHART_VERSION}" \
  -f "${SCRIPT_DIR}/values.yaml"

echo "==> Waiting for the vault-0 pod to be Running (image pull may take a while)"
for i in $(seq 1 120); do
  PHASE="$(kubectl -n "${NS}" get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${PHASE}" = "Running" ] && break
  sleep 5
done
[ "${PHASE}" = "Running" ] || { echo "    !! vault-0 not Running (phase='${PHASE}')" >&2; exit 1; }

echo "==> Checking init/seal status"
STATUS_JSON="$(exec_v vault status -format=json 2>/dev/null || true)"
INITIALIZED="$(printf '%s' "${STATUS_JSON}" | tr -d ' \n' | grep -o '"initialized":[a-z]*' | head -n1 | cut -d: -f2)"

if [ "${INITIALIZED}" != "true" ]; then
  echo "    initializing Vault (1 key share, threshold 1 - DEV ONLY)"
  INIT_JSON="$(exec_v vault operator init -key-shares=1 -key-threshold=1 -format=json)"
  UNSEAL_KEY="$(printf '%s' "${INIT_JSON}" | tr -d ' \n' | sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)".*/\1/p')"
  ROOT_TOKEN="$(printf '%s' "${INIT_JSON}" | tr -d ' \n' | sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p')"
  [ -n "${UNSEAL_KEY}" ] && [ -n "${ROOT_TOKEN}" ] || { echo "    !! failed to parse init output" >&2; exit 1; }
  kubectl -n "${NS}" delete secret vault-unseal-keys --ignore-not-found >/dev/null
  kubectl -n "${NS}" create secret generic vault-unseal-keys \
    --from-literal=unseal-key="${UNSEAL_KEY}" \
    --from-literal=root-token="${ROOT_TOKEN}" >/dev/null
  echo "    stored unseal key + root token in secret vault/vault-unseal-keys"
else
  echo "    already initialized; reusing stored keys"
fi

UNSEAL_KEY="$(kubectl -n "${NS}" get secret vault-unseal-keys -o jsonpath='{.data.unseal-key}' | base64 -d)"
ROOT_TOKEN="$(kubectl -n "${NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' | base64 -d)"

SEALED="$(printf '%s' "$(exec_v vault status -format=json 2>/dev/null || true)" | tr -d ' \n' | grep -o '"sealed":[a-z]*' | head -n1 | cut -d: -f2)"
if [ "${SEALED}" = "true" ]; then
  echo "==> Unsealing"
  exec_v vault operator unseal "${UNSEAL_KEY}" >/dev/null
fi

echo "==> Waiting for vault-0 to report Ready"
kubectl -n "${NS}" wait --for=condition=Ready pod/vault-0 --timeout=120s

echo "==> Fetching Phase 0.4 secrets to seed into Vault"
KC_ADMIN_USER="$(kubectl -n "${KC_NS}" get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)"
KC_ADMIN_PW="$(kubectl   -n "${KC_NS}" get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)"
KC_SA_PW="$(kubectl      -n "${KC_NS}" get secret keycloak-db    -o jsonpath='{.data.sa-password}' | base64 -d)"
KC_DB_PW="$(kubectl      -n "${KC_NS}" get secret keycloak-db    -o jsonpath='{.data.kc-password}' | base64 -d)"

echo "==> Configuring engines, auth, policy/role, and seeding secrets"
kubectl -n "${NS}" exec -i vault-0 -- env \
  VAULT_ADDR="http://127.0.0.1:8200" \
  VAULT_TOKEN="${ROOT_TOKEN}" \
  KC_ADMIN_USER="${KC_ADMIN_USER}" \
  KC_ADMIN_PW="${KC_ADMIN_PW}" \
  KC_SA_PW="${KC_SA_PW}" \
  KC_DB_PW="${KC_DB_PW}" \
  GW_CLIENT_SECRET="${GW_CLIENT_SECRET}" \
  sh -s <<'EOSH'
set -e

# KV v2 at 'secret/' (idempotent).
vault secrets enable -path=secret kv-v2 2>/dev/null || echo "  kv-v2 already enabled"

# Kubernetes auth method: workloads authenticate with their ServiceAccount token.
vault auth enable kubernetes 2>/dev/null || echo "  kubernetes auth already enabled"
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

# Sample least-privilege policy: read-only on the gateway's secret subtree.
vault policy write itorchestra-gateway - <<'EOP'
path "secret/data/itorchestra/gateway/*" {
  capabilities = ["read"]
}
EOP

# Bind the policy to the gateway workload's ServiceAccount (dev: 'default' in ns-gateway).
vault write auth/kubernetes/role/gateway \
  bound_service_account_names=default \
  bound_service_account_namespaces=ns-gateway \
  policies=itorchestra-gateway \
  ttl=1h

# Seed the Phase 0.4 secrets (KV v2).
vault kv put secret/itorchestra/keycloak/admin   username="$KC_ADMIN_USER" password="$KC_ADMIN_PW"
vault kv put secret/itorchestra/keycloak/db       sa-password="$KC_SA_PW"  kc-password="$KC_DB_PW"
vault kv put secret/itorchestra/gateway/keycloak  client_secret="$GW_CLIENT_SECRET"

echo "  seeded: secret/itorchestra/{keycloak/admin, keycloak/db, gateway/keycloak}"
EOSH

echo "==> Vault state:"
kubectl -n "${NS}" get pods,svc -o wide
echo "==> [0.5/vault] Deploy done."
echo "    UI/CLI (port-forward):  kubectl -n ${NS} port-forward svc/vault 8200:8200"
echo "    Root token (DEV ONLY):  kubectl -n ${NS} get secret vault-unseal-keys -o jsonpath='{.data.root-token}' | base64 -d; echo"
