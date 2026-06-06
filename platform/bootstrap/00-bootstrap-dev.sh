#!/usr/bin/env bash
# itOrchestra - Phase 0.1 end-to-end DEV bootstrap (single-node K3s on an Ubuntu VM).
# Runs every sub-step in order. Idempotent; safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${HOME}/.kube/config"

echo "########################################################"
echo "# itOrchestra Phase 0.1 - DEV bootstrap"
echo "# $(date -u '+%Y-%m-%d %H:%M:%S %Z')"
echo "########################################################"

# 1) K3s serve
bash "${ROOT}/k8s/cluster/k3s/install-server-dev.sh"

# 2) kubectl + helm
bash "${ROOT}/bootstrap/install-tools.sh"

# 3) Cilium CNI (node becomes Ready after this)
bash "${ROOT}/k8s/cluster/cilium/install-cilium.sh"

# 4) MetalLB (internal LoadBalancer)
PROFILE=dev bash "${ROOT}/k8s/cluster/metallb/install.sh"

# 5) ingress-nginx (LoadBalancer via MetalLB)
bash "${ROOT}/k8s/cluster/ingress-nginx/install.sh"

# 6) Longhorn (storage)
bash "${ROOT}/k8s/cluster/longhorn/prereqs.sh"
LONGHORN_REPLICAS=1 bash "${ROOT}/k8s/cluster/longhorn/install.sh"

# 7) Namespaces (PSA + Linkerd labels)
kubectl apply -f "${ROOT}/k8s/namespaces/namespaces.yaml"

# 8) NetworkPolicies (default-deny + allow-DNS)
kubectl apply -f "${ROOT}/k8s/network-policies/default-deny.yaml"
kubectl apply -f "${ROOT}/k8s/network-policies/allow-dns.yaml"

echo "########################################################"
echo "# Bootstrap complete. Running verification..."
echo "########################################################"
bash "${ROOT}/bootstrap/verify-0.1.sh"
