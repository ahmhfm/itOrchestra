output "namespace" {
  description = "Namespace ArgoCD was installed into."
  value       = helm_release.argocd.namespace
}
