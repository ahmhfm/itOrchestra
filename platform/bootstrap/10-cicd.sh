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

==> GitHub setup:
    1. Environments: 'dev', 'staging', 'prod' are configured (staging/prod require a reviewer and
       are restricted to the main / v* branches). Adjust reviewers in Settings > Environments.
    2. GHCR: the workflows push to ghcr.io/<owner>/itorchestra-<service> using GITHUB_TOKEN
       (packages: write). No extra secret needed. Make the packages internal/private as desired.
    3. Cosign: signing is keyless via GitHub OIDC (id-token: write) - no keys to manage.
    4. Real deploy (callers already pass apply=true; CD stays at lint + template until BOTH are set):
         - Register a self-hosted runner with cluster access (e.g. on the dev VM) and set the repo
           VARIABLE  DEPLOY_RUNNER  to its label (deploy jobs then run there; defaults to
           ubuntu-latest = scaffold-only).
         - Add the SECRET  KUBE_CONFIG  (base64 kubeconfig) so the deploy job can reach the cluster.
    5. Optional secret SNYK_TOKEN: enables the Snyk step (skipped silently if unset).
    6. Branch protection on 'main': require the 'gateway' and 'crewai' status checks to pass.

==> [0.11/cicd] Done. Push to a branch / open a PR to exercise the pipeline.
EOS
