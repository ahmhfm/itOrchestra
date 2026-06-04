#!/usr/bin/env bash
# Install Cilium CNI via Helm and wait until it is Ready.
# Idempotent (helm upgrade --install). Run after K3s is installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CILIUM_NS="kube-system"
CILIUM_VERSION="${CILIUM_VERSION:-1.16.5}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> [0.1/cilium] Installing Cilium ${CILIUM_VERSION} via Helm"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found. Run tools install first." >&2; exit 1; }

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

helm upgrade --install cilium cilium/cilium \
  --namespace "${CILIUM_NS}" \
  --version "${CILIUM_VERSION}" \
  -f "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 10m

echo "==> Waiting for Cilium DaemonSet + operator rollout"
kubectl -n "${CILIUM_NS}" rollout status ds/cilium --timeout=300s
kubectl -n "${CILIUM_NS}" rollout status deploy/cilium-operator --timeout=300s

# Optional: install the cilium CLI for 'cilium status' / connectivity tests.
if ! command -v cilium >/dev/null 2>&1; then
  echo "==> Installing cilium CLI (optional, for status/connectivity checks)"
  CLI_ARCH=amd64; [ "$(uname -m)" = "aarch64" ] && CLI_ARCH=arm64
  CILIUM_CLI_VERSION="$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt || echo v0.16.20)"
  TMP="$(mktemp -d)"
  if curl -sL --fail -o "${TMP}/cilium.tar.gz" \
      "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"; then
    sudo tar -C /usr/local/bin -xzf "${TMP}/cilium.tar.gz"
    echo "    cilium CLI installed: $(cilium version --client 2>/dev/null | head -n1 || true)"
  else
    echo "    WARN: could not download cilium CLI; skipping (not required)."
  fi
  rm -rf "${TMP}"
fi

echo "==> Node should now report Ready:"
kubectl get nodes -o wide

echo "==> [0.1/cilium] Done."
