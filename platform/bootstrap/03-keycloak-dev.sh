#!/usr/bin/env bash
# itOrchestra - Phase 0.4 one-shot (dev): rebuild the gateway image (now carrying the
# Keycloak routes), roll it, deploy Keycloak + its private MSSQL, then verify.
# Prerequisites: Phases 0.1-0.3 healthy; a container builder (docker/nerdctl) on the VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Rebuilding gateway image with Keycloak routes"
bash "${ROOT}/gateway/build-and-import-dev.sh"

echo "==> Rolling the gateway to pick up the new image"
kubectl -n ns-gateway rollout restart deploy/gateway
kubectl -n ns-gateway rollout status deploy/gateway --timeout=180s

echo "==> Installing Keycloak (+ private MSSQL)"
bash "${ROOT}/k8s/keycloak/install-dev.sh"

echo "==> Verifying Phase 0.4"
bash "${SCRIPT_DIR}/verify-0.4.sh"
