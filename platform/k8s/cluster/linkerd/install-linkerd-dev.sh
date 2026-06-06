#!/usr/bin/env bash
# Install the Linkerd service-mesh control plane on the DEV cluster (single-node Ubuntu VM K3s).
#
# Method (dev): the Linkerd CLI (edge channel = free OSS). The CLI auto-generates the
# trust-anchor + issuer certificates, so dev needs no external PKI. Idempotent: re-running
# applies the same manifests (kubectl apply) and is safe.
#
# PROD differs: never use auto-generated certs in production. Use Helm + an externally
# managed trust anchor (Vault) with cert-manager rotation -> see install-linkerd-prod.sh
# and docs/runbook-0.2.md ("Production").
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
LINKERD_BIN_DIR="${HOME}/.linkerd2/bin"
export PATH="${LINKERD_BIN_DIR}:${PATH}"
# Pin a specific edge build by exporting LINKERD2_VERSION=edge-X.X.X before running.
export INSTALL_LINKERD_CHANNEL="${INSTALL_LINKERD_CHANNEL:-edge}"
# Recent Linkerd requires the Gateway API CRDs to be present before install.
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"

echo "==> [0.2/linkerd] Installing Linkerd control plane (dev profile)"

# 1) Linkerd CLI (edge channel, free OSS).
if ! command -v linkerd >/dev/null 2>&1; then
  echo "    installing linkerd CLI (channel=${INSTALL_LINKERD_CHANNEL})"
  curl -sfL "https://run.linkerd.io/install-${INSTALL_LINKERD_CHANNEL}" | sh
fi
echo "    linkerd CLI: $(linkerd version --client --short 2>/dev/null || echo unknown)"

# 2) Pre-flight checks. Informative in dev; do not abort on warnings.
echo "==> Pre-install checks (linkerd check --pre)"
linkerd check --pre || echo "    WARN: pre-check reported issues; continuing (dev)."

# 3) Gateway API CRDs (Linkerd prerequisite), then Linkerd CRDs, then the control plane.
#    All idempotent via server-side / client-side apply.
echo "==> Installing Gateway API CRDs (${GATEWAY_API_VERSION})"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> Installing Linkerd CRDs"
linkerd install --crds | kubectl apply -f -

echo "==> Installing Linkerd control plane (auto-generated mTLS certs)"
linkerd install | kubectl apply -f -

# 4) Wait for the core control-plane deployments to roll out.
echo "==> Waiting for control-plane rollout"
kubectl -n linkerd rollout status deploy/linkerd-identity        --timeout=300s
kubectl -n linkerd rollout status deploy/linkerd-destination     --timeout=300s
kubectl -n linkerd rollout status deploy/linkerd-proxy-injector  --timeout=300s

# 5) Full health check (authoritative copy lives in verify-0.2.sh).
echo "==> Validating control plane (linkerd check)"
linkerd check || echo "    WARN: linkerd check reported issues; inspect with 'linkerd check'."

echo "==> [0.2/linkerd] Done. Control plane installed in namespace 'linkerd'."
