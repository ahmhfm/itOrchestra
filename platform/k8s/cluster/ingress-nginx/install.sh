#!/usr/bin/env bash
# Install ingress-nginx via Helm as a LoadBalancer (gets an IP from MetalLB).
# Idempotent. Run after MetalLB is configured.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="ingress-nginx"
CHART_VERSION="${INGRESS_NGINX_VERSION:-4.11.3}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> [0.1/ingress-nginx] Installing ingress-nginx ${CHART_VERSION}"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found." >&2; exit 1; }

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"
kubectl label ns "${NS}" name="${NS}" --overwrite >/dev/null
kubectl label ns "${NS}" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "${NS}" \
  --version "${CHART_VERSION}" \
  -f "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 8m

kubectl -n "${NS}" rollout status deploy/ingress-nginx-controller --timeout=300s

echo "==> Waiting for MetalLB to assign an EXTERNAL-IP"
for i in $(seq 1 30); do
  EXT_IP="$(kubectl -n "${NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${EXT_IP}" ] && break
  sleep 3
done
echo "    ingress-nginx EXTERNAL-IP: ${EXT_IP:-<pending>}"
kubectl -n "${NS}" get svc ingress-nginx-controller

echo "==> [0.1/ingress-nginx] Done."
