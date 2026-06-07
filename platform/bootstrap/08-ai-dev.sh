#!/usr/bin/env bash
# itOrchestra - Phase 0.9 one-shot (dev/CPU): deploy the internal AI layer
# (Qdrant 3-node cluster + 5 RAG collections + Ollama serving chat qwen2.5:1.5b + embeddings
# bge-m3, on CPU), seed Vault, then verify.
#
# Prerequisites: Phases 0.1-0.8 healthy (cluster + Longhorn, Vault unsealed, kube-prometheus-
# stack for the Qdrant ServiceMonitor). No GPU required in this profile - the LLM runs on CPU.
# NOTE: Ollama (chat + embedding models) + 3x Qdrant on top of the full 0.1-0.8 stack is heavy
# on a single VM; ensure several GiB of RAM headroom. First start pulls model weights (one-time,
# ~3.4GB total). CPU chat generation is slow - fine for verification, not for load.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Installing the AI layer (Qdrant + vLLM + Ollama)"
bash "${ROOT}/k8s/ai/install-dev.sh"

echo "==> Verifying Phase 0.9"
bash "${SCRIPT_DIR}/verify-0.9.sh"
