#!/usr/bin/env bash
# Install K3s server - DEV profile (single node, WSL2).
# Idempotent: safe to re-run. Installs config, runs the K3s installer, waits for Ready,
# and exposes kubeconfig at ~/.kube/config for the current user.
set -euo pipefail

K3S_CHANNEL="${K3S_CHANNEL:-stable}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${SCRIPT_DIR}/config.dev.yaml"

echo "==> [0.1/k3s] Installing K3s server (dev profile)"

if ! command -v systemctl >/dev/null 2>&1 || [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]; then
  echo "ERROR: systemd is not PID 1. Enable systemd in WSL: add '[boot]\\nsystemd=true' to /etc/wsl.conf, then 'wsl --shutdown'." >&2
  exit 1
fi

sudo mkdir -p /etc/rancher/k3s
sudo cp "${CONFIG_SRC}" /etc/rancher/k3s/config.yaml
echo "    installed /etc/rancher/k3s/config.yaml"

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" sh -s -
fi

# WSL2 quirk: the root filesystem is mounted with PRIVATE propagation, which late
# breaks Longhorn ("path /var/lib/longhorn is mounted on / but it is not a shared
# mount"). systemd on a normal Linux host re-shares / at boot; WSL does not. This
# drop-in re-shares / inside k3s's OWN mount namespace right before it starts, so the
# kubelet/containerd see a shared mount. The leading '-' makes it best-effort/no-op on
# hosts where / is already shared.
echo "    installing k3s rshared-mount drop-in (WSL2 Longhorn prerequisite)"
sudo mkdir -p /etc/systemd/system/k3s.service.d
sudo tee /etc/systemd/system/k3s.service.d/10-rshared-mount.conf >/dev/null <<'EOF'
[Service]
ExecStartPre=-/bin/mount --make-rshared /
EOF
sudo systemctl daemon-reload
echo "    (re)starting k3s to apply config + drop-in"
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
