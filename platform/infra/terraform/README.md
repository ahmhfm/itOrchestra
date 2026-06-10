# itOrchestra IaC (Terraform) - Phase 0.13

Terraform's role in itOrchestra is **bootstrap only**. It does not manage application/component state
in-cluster; it stands up the GitOps control plane and then hands off to ArgoCD, which reconciles
everything else from Git.

```
infra/terraform/
  modules/
    argocd/             # installs ArgoCD (argo-cd Helm chart)
    external-secrets/   # installs External Secrets Operator (Vault-backed secrets for GitOps)
    gitops-bootstrap/   # registers the App-of-Apps root Application + AppProject
  envs/
    dev/                # the dev cluster root module (this VM)
```

## What `terraform apply` does (dev)

1. Installs **ArgoCD** (`argo-cd` chart, pinned in `envs/dev/variables.tf`).
2. Installs the **External Secrets Operator** (`external-secrets` chart, pinned).
3. Creates the **`itorchestra` AppProject** and the **`itorchestra-root`** App-of-Apps Application,
   which syncs `platform/gitops/apps/` (recursed) from this Git repo.

Everything after that - the Vault `ClusterSecretStore`, and (in later sub-steps) every platform
component and microservice - is delivered by ArgoCD from `platform/gitops/`.

## Scope boundary

| Layer | Owner |
|---|---|
| K3s cluster, CNI, storage, LoadBalancer (dev) | imperative `bootstrap/*.sh` (wrapped, retired later); a Terraform cluster module lands in 0.13.3 for fresh envs |
| ArgoCD + ESO + App-of-Apps root | **Terraform (this dir)** |
| In-cluster components & services | **ArgoCD / GitOps** (`platform/gitops/`) |
| Secret material | **Vault** (ESO reads it; never in Git) |

## Run (dev)

```bash
# one-shot (seeds the ESO Vault role, then init+apply, then verify):
bash bootstrap/12-iac-dev.sh

# or manually:
cd infra/terraform/envs/dev
terraform init
terraform apply
```

After apply:

```bash
terraform -chdir=infra/terraform/envs/dev output          # admin-password / UI hints
kubectl -n argocd get applications                         # root + children
```

## Notes

- **Providers** (`hashicorp/helm ~> 2.17`, `hashicorp/kubernetes ~> 2.35`, `gavinbunney/kubectl
  ~> 1.19`) target the existing cluster via your local kubeconfig. Commit `.terraform.lock.hcl`.
- **State**: local in dev. To share/persist, switch `backend.tf` to the in-cluster MinIO (Phase
  0.12) as an S3 backend - instructions are inline in that file.
- **Private repo**: if `ahmhfm/itOrchestra` is private, add ArgoCD repo credentials before the root
  app can sync (see the note in `bootstrap/12-iac-dev.sh`).
- **Chart versions** are pinned (no floating deps); bump deliberately via the `*_chart_version`
  variables.
- Staging / Prod / DR roots are templated from `envs/dev` in sub-step 0.13.5.
