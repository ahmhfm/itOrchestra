#!/usr/bin/env bash
# Build the gateway image locally and import it into the K3s containerd image store
# (no external registry needed for dev). Uses docker if present, else nerdctl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${GATEWAY_IMAGE:-itorchestra/gateway:dev}"

echo "==> [0.3/gateway] Building image ${IMAGE}"

if command -v docker >/dev/null 2>&1; then
  # Use sudo if the daemon isn't reachable as the current user (fresh VM, no docker group).
  DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
  ${DOCKER} build -t "${IMAGE}" "${SCRIPT_DIR}"
  echo "==> Importing ${IMAGE} into K3s containerd (k8s.io namespace)"
  ${DOCKER} save "${IMAGE}" | sudo k3s ctr images import -
elif command -v nerdctl >/dev/null 2>&1; then
  # nerdctl can build straight into the k8s.io containerd namespace K3s uses.
  sudo nerdctl --namespace k8s.io build -t "${IMAGE}" "${SCRIPT_DIR}"
else
  echo "ERROR: need 'docker' or 'nerdctl' to build the image." >&2
  echo "  Install docker:  sudo apt-get update && sudo apt-get install -y docker.io && sudo usermod -aG docker \$USER" >&2
  exit 1
fi

echo "==> Image present in K3s:"
sudo k3s ctr images ls | grep "${IMAGE%%:*}" || true
echo "==> [0.3/gateway] Build + import done."
