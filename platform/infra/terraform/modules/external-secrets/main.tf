# External Secrets Operator (ESO). It reconciles (Cluster)SecretStore + ExternalSecret CRs into
# native Kubernetes Secrets, pulling the actual values from HashiCorp Vault. This is the GitOps-safe
# secrets path: only references live in Git; the secret material stays in Vault.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  wait    = true
  timeout = 600

  # Install the CRDs with the chart so the Vault ClusterSecretStore (synced by ArgoCD) has its API.
  set {
    name  = "installCRDs"
    value = "true"
  }
}
