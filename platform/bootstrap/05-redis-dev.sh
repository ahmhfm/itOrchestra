#!/usr/bin/env bash
# itOrchestra - Phase 0.6 one-shot (dev): deploy Redis (single-node StatefulSet, AOF on
# Longhorn, AUTH), mirror the password into Vault KV, then verify.
# Prerequisites: Phases 0.1-0.5 healthy (cluster, Longhorn StorageClass, Vault running).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Installing Redis"
bash "${ROOT}/k8s/redis/install-dev.sh"

echo "==> Verifying Phase 0.6"
bash "${SCRIPT_DIR}/verify-0.6.sh"
