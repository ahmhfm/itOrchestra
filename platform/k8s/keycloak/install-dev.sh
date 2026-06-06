#!/usr/bin/env bash
# Deploy Keycloak (dev) + its private MSSQL into the 'keycloak' namespace, then wire it
# behind the YARP gateway. Idempotent: secrets/passwords are generated once and reused.
#
# Steps: secrets -> MSSQL StatefulSet -> DB bootstrap Job -> realm ConfigMap ->
#        Keycloak Deployment/Service (KC_HOSTNAME = gateway URL) -> NetworkPolicy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="keycloak"

# A SQL-Server-complexity-safe random password (upper+lower+digit+special, hex tail = no
# shell/SQL quoting hazards).
gen_pw() { echo "Aa1!$(openssl rand -hex 20)"; }

echo "==> [0.4/keycloak] Ensuring secrets in ${NS}"
if ! kubectl -n "${NS}" get secret keycloak-db >/dev/null 2>&1; then
  kubectl -n "${NS}" create secret generic keycloak-db \
    --from-literal=sa-password="$(gen_pw)" \
    --from-literal=kc-password="$(gen_pw)"
  echo "    created secret keycloak-db"
else
  echo "    secret keycloak-db already exists (skip)"
fi
if ! kubectl -n "${NS}" get secret keycloak-admin >/dev/null 2>&1; then
  kubectl -n "${NS}" create secret generic keycloak-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(gen_pw)"
  echo "    created secret keycloak-admin (user: admin)"
else
  echo "    secret keycloak-admin already exists (skip)"
fi

echo "==> Deploying private MSSQL (StatefulSet)"
kubectl apply -f "${SCRIPT_DIR}/mssql.dev.yaml"
echo "    waiting for MSSQL to be Ready (first boot pulls the image, can take a few minutes)"
kubectl -n "${NS}" rollout status statefulset/keycloak-mssql --timeout=600s

echo "==> Bootstrapping the keycloak database (Job)"
kubectl -n "${NS}" delete job keycloak-db-init --ignore-not-found
kubectl apply -f "${SCRIPT_DIR}/db-init-job.yaml"
kubectl -n "${NS}" wait --for=condition=complete job/keycloak-db-init --timeout=300s

echo "==> Applying realm import ConfigMap"
kubectl apply -f "${SCRIPT_DIR}/realm-configmap.yaml"

echo "==> Resolving gateway public URL for KC_HOSTNAME"
GW_IP="$(kubectl -n ns-gateway get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [ -z "${GW_IP}" ]; then
  echo "    !! gateway LoadBalancer IP not found (is Phase 0.3 deployed?). Aborting." >&2
  exit 1
fi
KC_URL="https://${GW_IP}"
echo "    KC_HOSTNAME=${KC_URL}"

echo "==> Deploying Keycloak + Service"
sed "s#PLACEHOLDER_SET_BY_INSTALL#${KC_URL}#" "${SCRIPT_DIR}/deployment.dev.yaml" | kubectl apply -f -

echo "==> Applying gateway egress NetworkPolicy"
kubectl apply -f "${SCRIPT_DIR}/networkpolicy.yaml"

echo "==> Waiting for Keycloak rollout (first start runs an auto-build; be patient)"
kubectl -n "${NS}" rollout status deploy/keycloak --timeout=600s

echo "==> Keycloak state:"
kubectl -n "${NS}" get pods,svc -o wide
echo "==> [0.4/keycloak] Deploy done. Admin password:"
echo "    kubectl -n ${NS} get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo"
