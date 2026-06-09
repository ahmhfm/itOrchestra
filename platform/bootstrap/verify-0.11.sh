#!/usr/bin/env bash
# itOrchestra - Phase 0.11 verification (CI/CD pipeline assets).
# The pipeline itself runs on GitHub Actions; this script statically validates the assets in the
# repo so they are correct BEFORE they hit CI: required files present, all YAML parses, and -
# when the tools are installed locally - actionlint, buf lint/breaking, helm lint, and the
# dotnet format check pass. Tools that are absent are SKIPPED (not failed), so this is green on a
# plain server too. Run from anywhere; paths are resolved relative to the repo root.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP+1)); }

echo "== 1) Required CI/CD assets present =="
REQUIRED=(
  ".github/workflows/ci-dotnet.yml"
  ".github/workflows/ci-python.yml"
  ".github/workflows/ci-proto.yml"
  ".github/workflows/cd-helm.yml"
  ".github/workflows/gateway.yml"
  ".github/workflows/crewai.yml"
  ".github/actions/image-supply-chain/action.yml"
  ".github/dependabot.yml"
  "buf.yaml"
  "Directory.Build.props"
  ".editorconfig"
  "global.json"
  "platform/charts/itorchestra-service/Chart.yaml"
  "platform/charts/itorchestra-service/values.yaml"
  "platform/deploy/gateway/values-dev.yaml"
  "platform/deploy/gateway/values-staging.yaml"
  "platform/deploy/gateway/values-prod.yaml"
  "platform/deploy/crewai/values-dev.yaml"
  "platform/deploy/crewai/values-staging.yaml"
  "platform/deploy/crewai/values-prod.yaml"
)
MISSING=0
for f in "${REQUIRED[@]}"; do
  [ -f "${REPO}/${f}" ] || { echo "      missing: ${f}"; MISSING=$((MISSING+1)); }
done
[ "${MISSING}" -eq 0 ] && ok "all ${#REQUIRED[@]} required files present" || bad "${MISSING} required file(s) missing"

echo "== 2) YAML parses (workflows + chart + deploy values) =="
if command -v python3 >/dev/null 2>&1; then
  BAD_YAML=0
  # Exclude Helm chart templates/ (Go templating is not standalone YAML; `helm lint` covers it).
  while IFS= read -r y; do
    python3 -c "import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))" "${y}" 2>/dev/null \
      || { echo "      invalid YAML: ${y#${REPO}/}"; BAD_YAML=$((BAD_YAML+1)); }
  done < <(find "${REPO}/.github" "${REPO}/platform/charts" "${REPO}/platform/deploy" "${REPO}/buf.yaml" \
                -type f \( -name '*.yml' -o -name '*.yaml' \) -not -path '*/templates/*' 2>/dev/null)
  [ "${BAD_YAML}" -eq 0 ] && ok "all YAML documents parse" || bad "${BAD_YAML} YAML file(s) failed to parse"
else
  skip "python3 not available (YAML parse check)"
fi

echo "== 3) global.json pins the .NET 10 SDK =="
if grep -q '"version"[[:space:]]*:[[:space:]]*"10\.' "${REPO}/global.json" 2>/dev/null; then
  ok "global.json pins .NET 10 SDK"
else
  bad "global.json does not pin a .NET 10 SDK"
fi

echo "== 4) actionlint (workflow linter) =="
if command -v actionlint >/dev/null 2>&1; then
  ( cd "${REPO}" && actionlint ) && ok "actionlint clean" || bad "actionlint reported problems"
else
  skip "actionlint not installed"
fi

echo "== 5) buf lint + breaking (proto contracts) =="
if command -v buf >/dev/null 2>&1; then
  ( cd "${REPO}" && buf lint ) && ok "buf lint clean" || bad "buf lint failed"
  if ( cd "${REPO}" && git rev-parse --verify main >/dev/null 2>&1 ); then
    ( cd "${REPO}" && buf breaking --against '.git#branch=main' ) \
      && ok "buf breaking: no incompatible changes vs main" || bad "buf breaking detected incompatibilities"
  else
    skip "buf breaking (no local 'main' ref to diff against)"
  fi
else
  skip "buf not installed"
fi

echo "== 6) helm lint (chart x each env values) =="
if command -v helm >/dev/null 2>&1; then
  CHART="${REPO}/platform/charts/itorchestra-service"
  HELM_FAIL=0
  for v in gateway/values-dev gateway/values-staging gateway/values-prod \
           crewai/values-dev crewai/values-staging crewai/values-prod; do
    helm lint "${CHART}" --values "${REPO}/platform/deploy/${v}.yaml" >/dev/null 2>&1 \
      || { echo "      helm lint failed for ${v}.yaml"; HELM_FAIL=$((HELM_FAIL+1)); }
  done
  [ "${HELM_FAIL}" -eq 0 ] && ok "helm lint passed for all 6 env values" || bad "${HELM_FAIL} helm lint failure(s)"
  # Render the gRPC service to confirm the grpc-probe path templates correctly.
  helm template crewai "${CHART}" --values "${REPO}/platform/deploy/crewai/values-dev.yaml" \
    --set image.repository=ghcr.io/ahmhfm/itorchestra-crewai --set image.tag=sha-test >/dev/null 2>&1 \
    && ok "helm template renders the crewai (gRPC) release" || bad "helm template failed for crewai"
else
  skip "helm not installed"
fi

echo "== 7) dotnet format check (gateway) =="
if command -v dotnet >/dev/null 2>&1; then
  ( cd "${REPO}" && dotnet format platform/gateway/Gateway.csproj --verify-no-changes ) \
    && ok "dotnet format: gateway is well-formatted" || bad "dotnet format: gateway needs formatting (run 'dotnet format')"
else
  skip "dotnet SDK not installed"
fi

echo "========================================================"
echo "Phase 0.11 verification: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
