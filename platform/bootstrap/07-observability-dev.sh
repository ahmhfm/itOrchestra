#!/usr/bin/env bash
# itOrchestra - Phase 0.8 one-shot (dev): deploy the central Observability stack
# (OpenSearch + Tempo + Prometheus + Grafana + AlertManager + OpenTelemetry Collector),
# rebuild the gateway with the /grafana route, seed Vault, then verify.
#
# Prerequisites: Phases 0.1-0.7 healthy (cluster + Longhorn, gateway, Vault running/unsealed),
# and a container builder (docker or nerdctl) on the VM for the gateway rebuild.
# NOTE: this stack is memory-hungry; ensure the VM has several GiB of headroom.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Installing the central Observability stack"
bash "${ROOT}/k8s/observability/install-dev.sh"

echo "==> Verifying Phase 0.8"
bash "${SCRIPT_DIR}/verify-0.8.sh"
