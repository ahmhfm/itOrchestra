#!/usr/bin/env bash
# itOrchestra - Phase 0.11 one-shot: validate the CI/CD pipeline assets and print the one-time
# GitHub-side setup checklist. Unlike the cluster phases, there is nothing to install into K8s
# here - the pipeline lives in GitHub Actions and runs on push/PR. This script just runs the
# static verifier (verify-0.11.sh) and reminds you what to configure once on GitHub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Verifying Phase 0.11 (CI/CD assets)"
bash "${SCRIPT_DIR}/verify-0.11.sh"

cat <<'EOS'

==> One-time GitHub setup (do this once in the repository settings):
    1. Environments: create 'dev', 'staging', 'prod'. Add Required reviewers to 'staging' and
       'prod' (this is the deployment approval gate). Optionally restrict to the 'main' branch.
    2. GHCR: the workflows push to ghcr.io/<owner>/itorchestra-<service> using GITHUB_TOKEN
       (packages: write). No extra secret needed. Make the packages internal/private as desired.
    3. Cosign: signing is keyless via GitHub OIDC (id-token: write) - no keys to manage.
    4. Optional secrets:
         - SNYK_TOKEN  : enables the Snyk step (skipped silently if unset).
         - KUBE_CONFIG : base64 kubeconfig for a real deploy; set apply=true in the caller and run
                         the deploy job on a runner that can reach the cluster (e.g. a self-hosted
                         runner on the VM). Without it, CD stays at lint + template (scaffold).
    5. Branch protection on 'main': require the 'gateway' and 'crewai' status checks to pass.

==> [0.11/cicd] Done. Push to a branch / open a PR to exercise the pipeline.
EOS
