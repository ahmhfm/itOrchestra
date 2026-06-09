#!/usr/bin/env bash
# itOrchestra - Phase 0.12 one-shot (dev): deploy the Backup & DR layer (MinIO on hostPath +
# Velero with app-consistent hooks + a daily Schedule), then verify.
#
# Prerequisites: Phases 0.1 (cluster + Longhorn) and ideally 0.5/0.6/0.7 (Vault/Redis/MSSQL) so
# the hooks and the Vault mirror have something to act on. The MinIO bytes land on the VM host
# disk (default /srv/itorchestra/backups/minio) so backups survive loss of Longhorn/the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> Installing the Backup & DR layer (MinIO + Velero)"
bash "${ROOT}/k8s/backup/install-dev.sh"

echo "==> Verifying Phase 0.12"
bash "${SCRIPT_DIR}/verify-0.12.sh"
