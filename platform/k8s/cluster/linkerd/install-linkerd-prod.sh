#!/usr/bin/env bash
# Install the Linkerd control plane on a PRODUCTION cluster via Helm with an externally
# managed PKI. This script is NOT run by the dev bootstrap; it documents the prod path.
#
# Key differences from dev:
#   - Certificates are NOT auto-generated. The trust anchor (root CA) is long-lived and
#     stored in Vault; the issuer (intermediate) is short-lived and rotated by cert-manager.
#   - Installed via Helm (linkerd-crds + linkerd-control-plane) for GitOps-friendly upgrades.
#   - HA control plane (multiple replicas, anti-affinity) via --set highAvailability=true.
#
# Prerequisites:
#   - helm, step (smallstep CLI) for one-time cert bootstrap, kubectl context = prod cluster.
#   - cert-manager installed (recommended) to rotate the identity issuer automatically.
#   - The trust anchor key kept OFFLINE / in Vault, never committed.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the prod cluster}"
LINKERD_CHANNEL="${LINKERD_CHANNEL:-edge}"          # edge | stable
CERT_DIR="${CERT_DIR:-./.linkerd-certs}"            # bootstrap-only; real anchor lives in Vault

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found." >&2; exit 1; }
command -v step >/dev/null 2>&1 || { echo "ERROR: step (smallstep) CLI not found." >&2; exit 1; }

echo "==> [0.2/linkerd:prod] Helm repo (${LINKERD_CHANNEL})"
helm repo add linkerd "https://helm.linkerd.io/${LINKERD_CHANNEL}" >/dev/null 2>&1 || true
helm repo update linkerd >/dev/null

# --- 1) Trust anchor + issuer (bootstrap). In real prod, pull the anchor from Vault. ---
mkdir -p "${CERT_DIR}"
if [ ! -f "${CERT_DIR}/ca.crt" ]; then
  echo "==> Generating trust anchor (root CA, 10y) - move ca.key to Vault afterwards"
  step certificate create root.linkerd.cluster.local \
    "${CERT_DIR}/ca.crt" "${CERT_DIR}/ca.key" \
    --profile root-ca --no-password --insecure --not-after 87600h
fi
echo "==> Generating issuer (intermediate, 1y) signed by the trust anchor"
step certificate create identity.linkerd.cluster.local \
  "${CERT_DIR}/issuer.crt" "${CERT_DIR}/issuer.key" \
  --profile intermediate-ca --not-after 8760h --no-password --insecure \
  --ca "${CERT_DIR}/ca.crt" --ca-key "${CERT_DIR}/ca.key"

# --- 2) Install CRDs, then the HA control plane with our certs. ---
echo "==> Installing linkerd-crds"
helm upgrade --install linkerd-crds linkerd/linkerd-crds \
  -n linkerd --create-namespace --wait

echo "==> Installing linkerd-control-plane (HA)"
helm upgrade --install linkerd-control-plane linkerd/linkerd-control-plane \
  -n linkerd \
  --set highAvailability=true \
  --set-file identityTrustAnchorsPEM="${CERT_DIR}/ca.crt" \
  --set-file identity.issuer.tls.crtPEM="${CERT_DIR}/issuer.crt" \
  --set-file identity.issuer.tls.keyPEM="${CERT_DIR}/issuer.key" \
  --wait

echo "==> Validate: linkerd check"
linkerd check || true

cat <<'NOTE'
==> [0.2/linkerd:prod] Done. Follow-ups for production:
    - Hand issuer rotation to cert-manager (linkerd.io docs: "Automatically Rotating Control
      Plane TLS Credentials"); delete the local ./.linkerd-certs bootstrap material.
    - Store ca.key in Vault; never commit any *.key. Use the Linkerd CNI plugin chained with
      Cilium so meshed pods satisfy the 'restricted' PodSecurity profile (see runbook-0.2.md).
NOTE
