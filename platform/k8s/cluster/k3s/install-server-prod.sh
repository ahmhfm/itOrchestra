#!/usr/bin/env bash
# Install K3s server - PROD profile (HA control plane, embedded etcd).
#
# Usage:
#   FIRST control-plane node:
#     sudo K3S_TOKEN=<token> ./install-server-prod.sh --init
#   ADDITIONAL control-plane nodes:
#     sudo K3S_TOKEN=<token> K3S_SERVER_URL=https://<first-node-ip>:6443 ./install-server-prod.sh --join
#
# The token MUST come from Vault / a secret manager - never commit it.
set -euo pipefail

MODE="${1:-}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${K3S_TOKEN:?Set K3S_TOKEN (from Vault) before running}"

sudo mkdir -p /etc/rancher/k3s
sudo cp "${SCRIPT_DIR}/config.prod.yaml" /etc/rancher/k3s/config.yaml

case "${MODE}" in
  --init)
    echo "==> Installing FIRST control-plane server (cluster-init)"
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
      K3S_TOKEN="${K3S_TOKEN}" \
      sh -s - serve
    ;;
  --join)
    : "${K3S_SERVER_URL:?Set K3S_SERVER_URL=https://<first-node-ip>:6443}"
    echo "==> Joining additional control-plane server at ${K3S_SERVER_URL}"
    # cluster-init must NOT be set when joining; strip it from the copied config.
    sudo sed -i '/cluster-init:/d' /etc/rancher/k3s/config.yaml
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
      K3S_TOKEN="${K3S_TOKEN}" \
      sh -s - server --server "${K3S_SERVER_URL}"
    ;;
  *)
    echo "Usage: $0 --init | --join   (see header for env vars)" >&2
    exit 2
    ;;
esac

echo "==> Done. Verify with: sudo k3s kubectl get nodes"
echo "    Remember: install Cilium before nodes report Ready."
