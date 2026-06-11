# itOrchestra - Canonical Phase Index

Single source of truth for phase numbering. The authoritative roadmap is the project plan
(`itOrchestra plan/Project Development Stages *.md` + the Final Plan doc). This index maps each
canonical phase to the artifacts that implement it in `platform/`, and reconciles a couple of
historical label collisions in the repo (see the Reconciliation notes at the bottom).

## Phase 0 - Platform Foundation

| #        | Title                                   | Status       | Primary artifacts |
|----------|-----------------------------------------|--------------|-------------------|
| 0.1      | On-prem Kubernetes (K3s/Cilium/Longhorn/MetalLB/ingress-nginx, namespaces, default-deny netpol) | done | `k8s/cluster/*`, `k8s/namespaces`, `k8s/network-policies`, `bootstrap/00-bootstrap-dev.sh`, `verify-0.1.sh` |
| 0.2      | Service mesh (Linkerd + viz)            | done         | `k8s/cluster/linkerd/*`, `bootstrap/01-mesh-dev.sh`, `verify-0.2.sh` |
| 0.3      | API Gateway (YARP)                      | done         | `k8s/gateway/*`, `bootstrap/02-gateway-dev.sh`, `verify-0.3.sh` |
| 0.4      | Identity (Keycloak)                     | done         | `k8s/keycloak/*`, `bootstrap/03-keycloak-dev.sh`, `verify-0.4.sh` |
| 0.5      | Secrets (HashiCorp Vault)               | done         | `k8s/vault/*`, `bootstrap/04-vault-dev.sh`, `verify-0.5.sh` |
| 0.6      | Cache (Redis)                           | done         | `k8s/redis/*`, `bootstrap/05-redis-dev.sh`, `verify-0.6.sh` |
| 0.7      | Database (MSSQL Always On AG)           | done         | `k8s/mssql-ag/*`, `bootstrap/06-mssql-ag-dev.sh`, `verify-0.7.sh` |
| 0.8      | Observability (OTel/Tempo/Prometheus/Grafana/OpenSearch) | done | `k8s/observability/*`, `bootstrap/07-observability-dev.sh`, `verify-0.8.sh` |
| 0.9      | AI layer (Qdrant + Ollama/vLLM)         | done         | `k8s/ai/*`, `bootstrap/08-ai-dev.sh`, `verify-0.9.sh` |
| 0.10     | CrewAI multi-agent platform             | done         | `k8s/crewai/*`, `bootstrap/09-crewai-dev.sh`, `verify-0.10.sh` |
| 0.11     | CI/CD pipeline (GitHub Actions)         | done         | `.github/*` / CI assets, `bootstrap/10-cicd.sh`, `verify-0.11.sh` |
| **0.12** | **IaC + Backup/DR + GitOps** (Terraform/Helm/ArgoCD; DR Runbook) | **in progress** | see 0.12.x below |
| 0.13     | Service Scaffolding Template (`dotnet new itorchestra.svc`) | not started | - |
| 0.14     | Shared Building Blocks (internal NuGet libraries) | not started | - |

## Phase 0.12 sub-steps (IaC + Backup/DR + GitOps)

The roadmap's 0.12 ("IaC (Terraform + Helm) ... complete Disaster Recovery Runbook") is an umbrella
that includes the previously-built Backup/DR foundation plus the GitOps control plane.

| #       | Sub-step                                                        | Status        | Artifacts |
|---------|-----------------------------------------------------------------|---------------|-----------|
| 0.12.0  | Backup & DR foundation (MinIO + Velero + daily Schedule + MSSQL backup SP) | done | `k8s/backup/*`, `bootstrap/11-backup-dev.sh`, `verify-0.12.sh`*, `docs/runbook-0.12.md`* |
| 0.12.1  | IaC bootstrap: Terraform installs ArgoCD + ESO + App-of-Apps root + ClusterSecretStore->Vault | done | `infra/terraform/*`, `gitops/components/secrets`, `bootstrap/12-iac-dev.sh`, `verify-0.13.sh`* |
| 0.12.2  | Wrap existing components as ArgoCD Applications + sync-waves (safe adoption) | in progress | `gitops/apps/*` |
| 0.12.3  | Terraform modules for infra (cluster/CNI/storage/LB) for new environments | not started | - |
| 0.12.4  | Harden the per-service Helm chart + platform Umbrella chart (new-client deploy) | not started | - |
| 0.12.5  | Dev/Staging/Prod/DR environments (Kustomize overlays + ApplicationSet generators) | not started | - |
| 0.12.6  | Drift detection (ArgoCD selfHeal + OutOfSync alerts + `terraform plan` in CI) | not started | - |
| 0.12.7  | Full Disaster Recovery Runbook driven by IaC | not started | - |

## Reconciliation notes (historical labels kept for file stability)

The repo predates this index, so two label collisions exist. Files are **not** renamed (they are
stable / security-critical / live-referenced); this index is the authority. `*` marks them above:

1. **`verify-0.13.sh` / "Phase 0.13"** in `bootstrap/12-iac-dev.sh`, `infra/terraform/*`,
   `gitops/*`, `seed-vault-role.sh` historically meant the IaC bootstrap. Canonically that is
   **0.12.1**. New `gitops/apps/*` files use the 0.12.x labels.
2. **"Phase 0.12"** is used for two unrelated things:
   - the **Backup & DR** phase (`verify-0.12.sh`, `11-backup-dev.sh`, `k8s/backup/*`,
     `runbook-0.12.md`) -> canonically **0.12.0**.
   - the **ingress-fence "Phase 0.12 hardening"** comments in `k8s/*/networkpolicy.yaml` and
     `verify-0.4..0.8.sh` -> this is platform security hardening, folded under the 0.12 umbrella.

When in doubt, this index wins over inline file comments.
