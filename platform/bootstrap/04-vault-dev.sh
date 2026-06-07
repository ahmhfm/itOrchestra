#!/usr/bin/env bash
# itOrchestra - Phase 0.5 one-shot (dev): deploy HashiCorp Vault (Raft + Longhorn) and the
# Agent Injector, initialize/unseal it, enable KV v2 + Kubernetes auth, seed the Phase 0.4
# secrets, create the sample policy/role, then verify.
# Prerequisites: Phases 0.1-0.4 healthy; helm installed on the VM; Longhorn StorageClass present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Installing + initializing Vault"
bash "${ROOT}/k8s/vault/install-dev.sh"

echo "==> Verifying Phase 0.5"
bash "${SCRIPT_DIR}/verify-0.5.sh"
