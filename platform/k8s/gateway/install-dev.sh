#!/usr/bin/env bash
# Deploy the gateway (dev): create a self-signed TLS secret, then apply the Linkerd
# allow policies, the gateway ingress policy, Service and Deployment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="ns-gateway"

echo "==> [0.3/gateway] Ensuring TLS secret 'gateway-tls' in ${NS}"
if ! kubectl -n "${NS}" get secret gateway-tls >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  PASS="$(openssl rand -hex 16)"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TMP}/tls.key" -out "${TMP}/tls.crt" -days 365 \
    -subj "/CN=itorchestra-gateway" \
    -addext "subjectAltName=DNS:localhost,DNS:gateway.ns-gateway.svc.cluster.local"
  openssl pkcs12 -export -out "${TMP}/tls.pfx" \
    -inkey "${TMP}/tls.key" -in "${TMP}/tls.crt" -passout "pass:${PASS}"
  kubectl -n "${NS}" create secret generic gateway-tls \
    --from-file=tls.pfx="${TMP}/tls.pfx" \
    --from-literal=password="${PASS}"
  rm -rf "${TMP}"
  echo "    created secret gateway-tls (self-signed, 365d)"
else
  echo "    secret gateway-tls already exists (skip)"
fi

echo "==> Applying NetworkPolicies + Service + Deployment"
kubectl apply -f "${ROOT}/k8s/network-policies/allow-linkerd.yaml"
kubectl apply -f "${SCRIPT_DIR}/networkpolicy.yaml"
kubectl apply -f "${SCRIPT_DIR}/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/deployment.dev.yaml"

echo "==> Waiting for rollout"
kubectl -n "${NS}" rollout status deploy/gateway --timeout=180s

echo "==> Gateway state:"
kubectl -n "${NS}" get pods,svc -o wide
echo "==> [0.3/gateway] Deploy done."
