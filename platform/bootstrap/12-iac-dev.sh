#!/usr/bin/env bash
# itOrchestra - Phase 0.13 one-shot (dev): bootstrap the IaC / GitOps control plane.
#   1. Seed the External Secrets Vault role + reapply the Vault ingress fence (re-run vault installer;
#      idempotent). This is the only piece ESO needs in Vault to authenticate.
#   2. Terraform: install ArgoCD + External Secrets Operator + register the App-of-Apps root.
#   3. Verify.
#
# Prereqs: Phase 0.5 (Vault initialized + unsealed) and a reachable kubeconfig. Terraform >= 1.5 must
# be on PATH; `terraform init` fetches the helm/kubernetes/kubectl providers.
#
# NOTE: if the GitHub repo is PRIVATE, ArgoCD cannot sync until you add repo credentials, e.g.:
#   argocd repo add https://github.com/ahmhfm/itOrchestra.git --username <user> --password <token>
# (or apply a repo-creds Secret labeled argocd.argoproj.io/secret-type=repository).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
TF_DIR="${ROOT}/infra/terraform/envs/dev"

command -v terraform >/dev/null 2>&1 || { echo "!! terraform not found on PATH" >&2; exit 1; }

echo "==> [0.13] Seeding the External Secrets Vault role + reapplying the Vault fence"
bash "${ROOT}/k8s/vault/install-dev.sh"

echo "==> [0.13] Terraform init + apply (ArgoCD + ESO + GitOps root)"
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

echo "==> [0.13] Verifying"
bash "${SCRIPT_DIR}/verify-0.13.sh"
