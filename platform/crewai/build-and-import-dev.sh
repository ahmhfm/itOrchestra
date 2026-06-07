#!/usr/bin/env bash
# Build the CrewAI service image locally and import it into the K3s containerd image store
# (no external registry needed for dev). Uses docker if present, else nerdctl. Mirrors the
# gateway build pattern (Phase 0.3).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${CREWAI_IMAGE:-itorchestra/crewai:dev}"

echo "==> [0.10/crewai] Building image ${IMAGE} (this pulls crewai + deps; can take a few minutes)"

if command -v docker >/dev/null 2>&1; then
  DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
  ${DOCKER} build -t "${IMAGE}" "${SCRIPT_DIR}"
  echo "==> Importing ${IMAGE} into K3s containerd (k8s.io namespace)"
  ${DOCKER} save "${IMAGE}" | sudo k3s ctr images import -
elif command -v nerdctl >/dev/null 2>&1; then
  sudo nerdctl --namespace k8s.io build -t "${IMAGE}" "${SCRIPT_DIR}"
else
  echo "ERROR: need 'docker' or 'nerdctl' to build the image." >&2
  exit 1
fi

echo "==> Image present in K3s:"
sudo k3s ctr images ls | grep "${IMAGE%%:*}" || true
echo "==> [0.10/crewai] Build + import done."
