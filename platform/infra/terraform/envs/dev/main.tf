# Phase 0.12.1 - dev IaC control plane. Terraform's scope is bootstrap ONLY:
#   1. ArgoCD  (GitOps engine)
#   2. External Secrets Operator (Vault-backed secrets for GitOps)
#   3. The App-of-Apps root + AppProject (handoff to GitOps for everything else)
# The Vault k8s-auth role ESO uses is seeded by k8s/vault/install-dev.sh (run by 12-iac-dev.sh).

module "argocd" {
  source        = "../../modules/argocd"
  namespace     = var.argocd_namespace
  chart_version = var.argocd_chart_version
}

module "external_secrets" {
  source        = "../../modules/external-secrets"
  namespace     = var.eso_namespace
  chart_version = var.eso_chart_version
}

module "gitops_bootstrap" {
  source           = "../../modules/gitops-bootstrap"
  argocd_namespace = var.argocd_namespace
  repo_url         = var.gitops_repo_url
  target_revision  = var.gitops_target_revision
  apps_path        = var.gitops_apps_path

  # ArgoCD CRDs must exist before we register the AppProject/Application.
  depends_on = [module.argocd]
}
