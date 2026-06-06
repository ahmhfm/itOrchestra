#!/usr/bin/env bash
# Longhorn node prerequisites: open-iscsi (+ running iscsid) and NFS client.
# Run on every node that will host Longhorn storage (in dev, the single Ubuntu VM node).
set -euo pipefail

echo "==> [0.1/longhorn] Installing node prerequisites (open-iscsi, nfs-common)"

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y open-iscsi nfs-common util-linux
else
  echo "ERROR: this prereq script targets Debian/Ubuntu (apt). Adapt for your distro." >&2
  exit 1
fi

# Longhorn requires the iscsi_tcp kernel module + a running iscsid.
sudo modprobe iscsi_tcp || echo "    WARN: could not modprobe iscsi_tcp (may already be built-in)"
sudo systemctl enable --now iscsid || echo "    WARN: could not start iscsid via systemd"

echo "==> iscsid status:"
systemctl is-active iscsid || true
echo "==> [0.1/longhorn] Prerequisites done."
