#!/usr/bin/env bash
# Install the Linkerd-viz extension (dashboard + golden metrics) on the DEV cluster.
#
# Provides 'linkerd viz dashboard', plus success-rate / latency / RPS for meshed traffic.
# DEV uses the bundled in-cluster Prometheus (emptyDir, ephemeral - metrics reset on restart).
# In PROD this is normally replaced by the central observability stack (later 0.x step):
# point viz at an external long-term Prometheus instead of the bundled one.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export PATH="${HOME}/.linkerd2/bin:${PATH}"

command -v linkerd >/dev/null 2>&1 || {
  echo "ERROR: linkerd CLI not found. Run install-linkerd-dev.sh first." >&2; exit 1; }

echo "==> [0.2/linkerd-viz] Installing Linkerd-viz extension"
linkerd viz install | kubectl apply -f -

echo "==> Waiting for viz rollout"
kubectl -n linkerd-viz rollout status deploy/web              --timeout=300s
kubectl -n linkerd-viz rollout status deploy/metrics-api      --timeout=300s || true

echo "==> Validating viz (linkerd viz check)"
linkerd viz check || echo "    WARN: viz check reported issues; inspect with 'linkerd viz check'."

echo "==> [0.2/linkerd-viz] Done."
echo "    Open the dashboard from the VM shell:  linkerd viz dashboard &"
