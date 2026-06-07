#!/usr/bin/env bash
# itOrchestra - Phase 0.10 one-shot (dev): build + import the CrewAI image, deploy the CrewAI
# multi-agent orchestration service (gRPC, meshed), provision its audit DB (CrewAiDb on the 0.7
# AG, stored-procedures only), wire it to the 0.9 AI layer (Ollama + Qdrant), seed Vault, verify.
#
# Prerequisites: Phases 0.1-0.9 healthy (mesh + Longhorn, Vault unsealed, Keycloak, the 0.7 AG,
# and the 0.9 AI layer with Qdrant + Ollama Ready). Needs 'docker' or 'nerdctl' to build the
# image. The build pulls crewai + deps and can take several minutes; CrewAI reasoning runs on the
# CPU LLM, so the first SubmitTask/Query is slow (fine for verification).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Building + importing the CrewAI image"
bash "${ROOT}/crewai/build-and-import-dev.sh"

echo "==> Deploying the CrewAI service"
bash "${ROOT}/k8s/crewai/install-dev.sh"

echo "==> Verifying Phase 0.10"
bash "${SCRIPT_DIR}/verify-0.10.sh"
