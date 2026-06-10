# ArgoCD install (GitOps control plane). Bootstrap-only: Terraform installs the controller; ArgoCD
# itself then reconciles everything else in the cluster from Git (App-of-Apps). Community chart.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  # Wait for the core workloads to be Ready so a follow-up App-of-Apps apply finds the CRDs/API.
  wait    = true
  timeout = 900

  # Optional extra values (rendered YAML). Empty by default - chart defaults are fine for dev.
  values = length(var.values_yaml) > 0 ? [var.values_yaml] : []
}
