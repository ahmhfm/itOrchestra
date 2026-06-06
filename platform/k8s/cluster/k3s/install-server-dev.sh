#!/usr/bin/env bash
# Install K3s server - DEV profile (single-node Ubuntu VM).
# Idempotent: safe to re-run. Installs config, runs the K3s installer, waits for Ready,
# and exposes kubeconfig at ~/.kube/config for the current user.
set -euo pipefail

K3S_CHANNEL="${K3S_CHANNEL:-stable}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${SCRIPT_DIR}/config.dev.yaml"

echo "==> [0.1/k3s] Installing K3s server (dev profile)"

if ! command -v systemctl >/dev/null 2>&1 || [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]; then
  echo "ERROR: systemd is not PID 1. This dev profile targets an Ubuntu VM (systemd is PID 1 by default)." >&2
  exit 1
fi

sudo mkdir -p /etc/rancher/k3s
sudo cp "${CONFIG_SRC}" /etc/rancher/k3s/config.yaml
echo "    installed /etc/rancher/k3s/config.yaml"

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" sh -s -
fi

# Longhorn requires '/' to be a SHARED mount. A normal Ubuntu VM already re-shares '/' at
# boot via systemd, so nothing extra is needed here.
echo "    (re)starting k3s to apply config"
sudo systemctl restart k3s

echo "==> Waiting for K3s API to become available"
for i in $(seq 1 60); do
  if sudo k3s kubectl get --raw='/readyz' >/dev/null 2>&1; then break; fi
  sleep 2
done

# Expose kubeconfig to the current (non-root) user.
mkdir -p "${HOME}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
echo "    kubeconfig written to ${HOME}/.kube/config"

echo "==> Node status (the node stays NotReady until a CNI is installed - that is expected here):"
KUBECONFIG="${HOME}/.kube/config" kubectl get nodes -o wide 2>/dev/null || sudo k3s kubectl get nodes -o wide || true

echo "==> [0.1/k3s] Done. Next: install Cilium (k8s/cluster/cilium/install-cilium.sh)."
