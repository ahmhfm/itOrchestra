#!/usr/bin/env bash
# Deploy Redis (dev) into the 'redis' namespace: a single-node StatefulSet (official image,
# AOF persistence on Longhorn) with AUTH, out of the Linkerd mesh. The generated password is
# stored in the 'redis-auth' Secret (consumed by Redis) and mirrored into Vault KV
# (secret/itorchestra/shared/redis) so workloads read it from Vault.
#
# Idempotent: the password is generated once and reused.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="redis"
VAULT_NS="vault"

# Hex password: connection-string / CLI safe (no special chars to quote).
gen_pw() { openssl rand -hex 24; }

echo "==> [0.6/redis] Ensuring namespace is NOT meshed (shared infra; AUTH now, TLS in prod)"
kubectl annotate namespace "${NS}" linkerd.io/inject=disabled --overwrite >/dev/null

echo "==> Ensuring the redis-auth Secret"
if ! kubectl -n "${NS}" get secret redis-auth >/dev/null 2>&1; then
  kubectl -n "${NS}" create secret generic redis-auth --from-literal=password="$(gen_pw)"
  echo "    created secret redis-auth"
else
  echo "    secret redis-auth already exists (skip)"
fi

echo "==> Applying Redis manifests (ConfigMap, Service, StatefulSet)"
kubectl apply -f "${SCRIPT_DIR}/configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/statefulset.yaml"

echo "==> Waiting for Redis to be Ready (first boot provisions the Longhorn PVC)"
kubectl -n "${NS}" rollout status statefulset/redis --timeout=300s

echo "==> Mirroring the Redis password into Vault KV (secret/itorchestra/shared/redis)"
REDIS_PW="$(kubectl -n "${NS}" get secret redis-auth -o jsonpath='{.data.password}' | base64 -d)"
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  kubectl -n "${VAULT_NS}" exec -i vault-0 -- env \
    VAULT_ADDR="http://127.0.0.1:8200" \
    VAULT_TOKEN="${ROOT_TOKEN}" \
    REDIS_PW="${REDIS_PW}" \
    sh -s <<'EOSH'
set -e
vault kv put secret/itorchestra/shared/redis \
  host="redis.redis.svc.cluster.local" \
  port="6379" \
  password="$REDIS_PW" \
  connection-string="redis.redis.svc.cluster.local:6379,password=$REDIS_PW,abortConnect=false,ssl=false"
echo "  seeded: secret/itorchestra/shared/redis"
EOSH
else
  echo "    !! could not read Vault root token (is Phase 0.5 deployed?); skipping Vault mirror" >&2
fi

echo "==> Redis state:"
kubectl -n "${NS}" get pods,svc,pvc -o wide
echo "==> [0.6/redis] Deploy done."
echo "    In-cluster endpoint:  redis.redis.svc.cluster.local:6379 (AUTH required)"
echo "    Password (DEV ONLY):  kubectl -n ${NS} get secret redis-auth -o jsonpath='{.data.password}' | base64 -d; echo"
