#!/usr/bin/env bash
# Install MetalLB (L2 mode) via Helm and configure an IP pool.
# DEV: auto-detects the WSL eth0 /24 and renders the pool.
# PROD: pass PROFILE=prod to apply k8s/cluster/metallb/ippool.prod.yaml (edit it first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${PROFILE:-dev}"
METALLB_NS="metallb-system"
METALLB_VERSION="${METALLB_VERSION:-0.14.9}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> [0.1/metallb] Installing MetalLB ${METALLB_VERSION} (profile=${PROFILE})"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found." >&2; exit 1; }

helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo update metallb >/dev/null

kubectl get ns "${METALLB_NS}" >/dev/null 2>&1 || kubectl create ns "${METALLB_NS}"
# MetalLB speaker needs elevated privileges; relax PSA on its namespace.
kubectl label ns "${METALLB_NS}" \
  pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

helm upgrade --install metallb metallb/metallb \
  --namespace "${METALLB_NS}" \
  --version "${METALLB_VERSION}" \
  --wait --timeout 5m

kubectl -n "${METALLB_NS}" rollout status deploy/metallb-controller --timeout=180s

if [ "${PROFILE}" = "prod" ]; then
  echo "==> Applying PROD pool from ippool.prod.yaml (edit the range first!)"
  kubectl apply -f "${SCRIPT_DIR}/ippool.prod.yaml"
else
  echo "==> Detecting WSL eth0 subnet to render a dev L2 pool"
  NODE_IP="$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [ -z "${NODE_IP}" ]; then
    NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  fi
  BASE="$(echo "${NODE_IP}" | cut -d. -f1-3)"
  POOL_START="${BASE}.240"
  POOL_END="${BASE}.250"
  echo "    node IP=${NODE_IP}  ->  pool ${POOL_START}-${POOL_END}"
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: dev-pool
  namespace: ${METALLB_NS}
spec:
  addresses:
    - "${POOL_START}-${POOL_END}"
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: dev-l2
  namespace: ${METALLB_NS}
spec:
  ipAddressPools:
    - dev-pool
EOF
fi

echo "==> MetalLB pools:"
kubectl -n "${METALLB_NS}" get ipaddresspools.metallb.io
echo "==> [0.1/metallb] Done."
