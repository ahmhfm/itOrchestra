#!/usr/bin/env bash
# Install kubectl + helm if missing. Idempotent.
set -euo pipefail

echo "==> [0.1/tools] Ensuring kubectl + helm are installed"

ARCH=amd64; [ "$(uname -m)" = "aarch64" ] && ARCH=arm64

if ! command -v kubectl >/dev/null 2>&1; then
  echo "    installing kubectl"
  KVER="$(curl -sL https://dl.k8s.io/release/stable.txt)"
  curl -sLO "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl"
  sudo install -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
else
  echo "    kubectl present: $(kubectl version --client -o yaml 2>/dev/null | grep -m1 gitVersion || true)"
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "    installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "    helm present: $(helm version --short 2>/dev/null || true)"
fi

echo "==> [0.1/tools] Done."
