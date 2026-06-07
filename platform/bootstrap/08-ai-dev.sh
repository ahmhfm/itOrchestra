#!/usr/bin/env bash
# itOrchestra - Phase 0.9 one-shot (dev): deploy the internal AI layer
# (Qdrant 3-node cluster + 5 RAG collections + vLLM GPU chat + Ollama CPU embeddings),
# seed Vault, then verify.
#
# Prerequisites:
#   - Phases 0.1-0.8 healthy (cluster + Longhorn, Vault unsealed, kube-prometheus-stack for
#     ServiceMonitors).
#   - An NVIDIA GPU on the node with nvidia-container-toolkit installed on the HOST so K3s
#     registers the NVIDIA runtime (install-dev.sh deploys the device plugin + fails early if
#     no GPU is advertised).
# NOTE: vLLM (GPU) + Ollama + 3x Qdrant on top of the full 0.1-0.8 stack is heavy on a single
# VM; ensure several GiB of RAM headroom. First start pulls model weights (one-time).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Installing the AI layer (Qdrant + vLLM + Ollama)"
bash "${ROOT}/k8s/ai/install-dev.sh"

echo "==> Verifying Phase 0.9"
bash "${SCRIPT_DIR}/verify-0.9.sh"
