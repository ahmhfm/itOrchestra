#!/usr/bin/env bash
# itOrchestra - Phase 0.2 end-to-end DEV bootstrap (Linkerd service mesh).
# Prerequisite: Phase 0.1 complete and healthy (bash bootstrap/00-bootstrap-dev.sh).
# Idempotent; safe to re-run.
#
# Set INSTALL_VIZ=false to skip the (resource-heavier) linkerd-viz dashboard/metrics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
INSTALL_VIZ="${INSTALL_VIZ:-true}"

echo "########################################################"
echo "# itOrchestra Phase 0.2 - DEV bootstrap (Linkerd mesh)"
echo "# $(date -u '+%Y-%m-%d %H:%M:%S %Z')"
echo "########################################################"

# 1) Control plane (CLI, auto-generated certs)
bash "${ROOT}/k8s/cluster/linkerd/install-linkerd-dev.sh"

# 2) viz extension (dashboard + golden metrics) - optional
if [ "${INSTALL_VIZ}" = "true" ]; then
  bash "${ROOT}/k8s/cluster/linkerd/install-linkerd-viz.sh"
else
  echo "==> Skipping linkerd-viz (INSTALL_VIZ=false)"
fi

echo "########################################################"
echo "# Mesh bootstrap complete. Running verification..."
echo "########################################################"
bash "${ROOT}/bootstrap/verify-0.2.sh"
