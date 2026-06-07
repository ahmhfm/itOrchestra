#!/usr/bin/env bash
# itOrchestra - Phase 0.7 one-shot (dev): deploy the reference SQL Server Always On AG
# (two-replica clusterless read-scale), seed connection details into Vault, then verify.
# Prerequisites: Phases 0.1-0.6 healthy (cluster, Longhorn StorageClass, Vault running).
# Note: each SQL replica needs >= 2 GiB RAM; ensure the VM has headroom.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Installing the MSSQL Always On AG"
bash "${ROOT}/k8s/mssql-ag/install-dev.sh"

echo "==> Verifying Phase 0.7"
bash "${SCRIPT_DIR}/verify-0.7.sh"
