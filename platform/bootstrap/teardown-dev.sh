#!/usr/bin/env bash
# Tear down the DEV cluster created by 00-bootstrap-dev.sh.
# Removes K3s entirely (uninstall script created by the K3s installer).
set -uo pipefail

echo "==> Tearing down itOrchestra dev cluster"
if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
  sudo /usr/local/bin/k3s-uninstall.sh
  echo "    K3s uninstalled."
else
  echo "    k3s-uninstall.sh not found - K3s may not be installed."
fi
rm -f "${HOME}/.kube/config" 2>/dev/null || true
echo "==> Done."
