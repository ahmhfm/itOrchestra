#!/usr/bin/env bash
# Install K3s agent (worker node) - PROD profile.
#
# Usage:
#   sudo K3S_TOKEN=<token> K3S_SERVER_URL=https://<control-plane-ip>:6443 ./install-agent-prod.sh
#
# The token MUST come from Vault / a secret manager - never commit it.
set -euo pipefail

K3S_CHANNEL="${K3S_CHANNEL:-stable}"
: "${K3S_TOKEN:?Set K3S_TOKEN (from Vault) before running}"
: "${K3S_SERVER_URL:?Set K3S_SERVER_URL=https://<control-plane-ip>:6443}"

echo "==> Installing K3s agent, joining ${K3S_SERVER_URL}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
  K3S_URL="${K3S_SERVER_URL}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  sh -s - agent

echo "==> Done. From a control-plane node verify: sudo k3s kubectl get nodes"
