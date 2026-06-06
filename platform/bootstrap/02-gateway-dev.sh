#!/usr/bin/env bash
# itOrchestra - Phase 0.3 one-shot (dev): build + import the gateway image, deploy it,
# then verify. Prerequisites: Phase 0.1 + 0.2 healthy, Linkerd CNI enabled (mesh follow-up),
# and a container builder (docker or nerdctl) on the VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

bash "${ROOT}/gateway/build-and-import-dev.sh"
bash "${ROOT}/k8s/gateway/install-dev.sh"
bash "${SCRIPT_DIR}/verify-0.3.sh"
