# Runbook 0.11 - CI/CD pipeline (GitHub Actions)

Phase 0.11 adds the **standard build/test/secure/sign/deploy pipeline** that every itOrchestra
service uses. It is implemented as **reusable GitHub Actions workflows** plus one **composite
action** for the container supply chain, wired to the two services that exist today (the .NET
**gateway** and the Python **crewai**) and ready for every future service to adopt by copying a
~40-line caller workflow.

---

## 1. What runs, and when

| Trigger | What happens |
|--------|--------------|
| **Pull request** | restore -> format check -> strict build (analyzers + warnings-as-errors) -> tests (Testcontainers) -> `dotnet list package --vulnerable` -> optional Snyk -> **build image + Trivy scan + SBOM** (no push). For crewai also: **buf lint + buf breaking**. |
| **Push to `main` / tag `v*`** | everything above, **plus** push the image to **GHCR**, **Cosign** keyless sign + **SBOM attestation**, then progressive deploy **dev -> staging -> prod** (staging/prod gated by GitHub Environment reviewers). |

The .NET SDK is pinned by [`global.json`](../../global.json) (`10.0.100`, `rollForward:
latestFeature`). Strict analyzers + warnings-as-errors come from
[`Directory.Build.props`](../../Directory.Build.props); formatting rules from
[`.editorconfig`](../../.editorconfig).

---

## 2. Layout

```
.github/
  workflows/
    ci-dotnet.yml      reusable: restore/format/build/test/vuln/Snyk + image supply chain
    ci-python.yml      reusable: ruff lint/format + pytest + image supply chain
    ci-proto.yml       reusable: buf lint + buf breaking (vs main)
    cd-helm.yml        reusable: helm lint + template + (gated) deploy to an Environment
    gateway.yml        caller: gateway (.NET)  -> ci-dotnet + cd-helm (dev/staging/prod)
    crewai.yml         caller: crewai (Python) -> ci-proto + ci-python + cd-helm (dev/staging/prod)
  actions/
    image-supply-chain/action.yml   composite: build -> Trivy -> SBOM(Syft) -> push GHCR -> Cosign sign+attest
  dependabot.yml       weekly updates: github-actions, nuget, pip, docker
buf.yaml               proto lint + breaking rules (module: platform/crewai/proto)
Directory.Build.props  strict analyzers + TreatWarningsAsErrors for all .NET projects
.editorconfig          dotnet format rules
platform/
  charts/itorchestra-service/   generic microservice Helm chart (Deployment/Service/[NetworkPolicy])
  deploy/<service>/values-<env>.yaml   per-service, per-environment values (image injected by CD)
  bootstrap/10-cicd.sh           validate assets + print the GitHub setup checklist
  bootstrap/verify-0.11.sh       static verification (files, YAML, buf, helm, dotnet format)
```

---

## 3. The standard pipeline, stage by stage

1. **Restore / Build** - `dotnet restore` + `dotnet build -c Release`; analyzers + warnings are
   errors (`Directory.Build.props`). SDK from `global.json`.
2. **Format** - `dotnet format --verify-no-changes` (`.editorconfig`) / `ruff format --check`.
3. **Test** - auto-discovers `*Tests.csproj` and runs `dotnet test`; GitHub-hosted runners have
   Docker, so **Testcontainers** integration tests (e.g. real MSSQL) work out of the box. (No
   test project yet => the step is a no-op notice; add one to turn it on.)
4. **Analyzers** - strict Roslyn analyzers run as part of the build.
5. **Dependency CVEs** - `dotnet list package --vulnerable --include-transitive` (fails on a
   match) + optional **Snyk** (skipped without `SNYK_TOKEN`) + **Dependabot** (weekly PRs).
6. **Proto** - `buf lint` + `buf breaking --against .git#branch=main` (crewai only).
7. **Image** - multi-stage `docker build`, **Trivy** image scan (fails on fixable CRITICAL/HIGH),
   **SBOM** via Syft (SPDX-JSON, uploaded as an artifact).
8. **Publish** (main/tags) - push to **GHCR** (`ghcr.io/<owner>/itorchestra-<service>`),
   **Cosign** keyless sign of the digest + `cosign attest` the SBOM.
9. **Deploy** - `helm lint` + `helm template`, then an Environment-gated rollout dev -> staging
   -> prod.

---

## 4. One-time GitHub setup

Run `bash bootstrap/10-cicd.sh` for the checklist. Summary:

- **Environments** `dev` / `staging` / `prod`; add **Required reviewers** on `staging` + `prod`
  (this is the **approval gate**).
- **GHCR**: pushes use the built-in `GITHUB_TOKEN` (`packages: write`) - no extra secret.
- **Cosign**: keyless via GitHub **OIDC** (`id-token: write`) - no keys to manage.
- **Optional secrets**: `SNYK_TOKEN` (enables Snyk); `KUBE_CONFIG` (base64 kubeconfig) to do a
  real deploy.
- **Branch protection** on `main`: require the `gateway` and `crewai` checks.

---

## 5. CD model (dev today; staging/prod scaffolded)

Only the **dev** cluster exists, so CD defaults to **lint + template + (server) dry-run** and is
safe to run everywhere. To perform a **real** deploy:

1. Provide a `KUBE_CONFIG` secret (base64 kubeconfig) for the target environment, **and**
2. set `apply: true` in the caller's deploy job, ideally on a **self-hosted runner** on the VM
   that can reach the cluster.

The deploy uses the generic `itorchestra-service` chart with the per-env values file; the CD
pipeline overrides `image.repository` + `image.tag` with the **signed** image it just published.

---

## 6. Verify

```bash
cd ~/itOrchestra/platform
bash bootstrap/verify-0.11.sh
```

Checks: required files present, all YAML parses, `global.json` pins .NET 10, and - when the tools
are installed - `actionlint`, `buf lint`/`breaking`, `helm lint` (chart x 6 env values) +
`helm template`, and `dotnet format`. Missing tools are **skipped**, so the script is green on a
bare server; install `buf`, `helm`, `actionlint`, and the .NET SDK to exercise every gate
locally.

---

## 7. Adding a new service to the pipeline

1. Add the service's proto dir (if any) to `buf.yaml` `modules`.
2. Create `platform/deploy/<svc>/values-{dev,staging,prod}.yaml`.
3. Copy `gateway.yml` (for .NET) or `crewai.yml` (for Python) to `<svc>.yml`, fix the paths,
   image name, project/context, and namespace.
4. That's it - the reusable workflows + composite action provide the rest.

---

## 8. dev vs prod

| Aspect | dev (this phase) | prod |
|-------|------------------|------|
| Deploy | lint + template + dry-run (scaffold) | real `helm upgrade --install` on a self-hosted runner |
| Approval | optional reviewers | **required reviewers** on staging + prod |
| Registry | GHCR (private/internal) | GHCR or an internal Harbor mirror |
| Signing | Cosign keyless (OIDC) | Cosign keyless + policy admission (verify signatures at deploy) |
| Snyk | optional (token may be unset) | required, with a fail-on-high gate |
| Trivy | fail on fixable CRITICAL/HIGH | fail on CRITICAL/HIGH, periodic re-scan of running images |
```
