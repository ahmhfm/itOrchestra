output "argocd_namespace" {
  value = module.argocd.namespace
}

output "external_secrets_namespace" {
  value = module.external_secrets.namespace
}

output "root_application" {
  value = module.gitops_bootstrap.root_application_name
}

output "argocd_admin_password_hint" {
  description = "How to read the initial ArgoCD admin password."
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

output "argocd_ui_hint" {
  description = "How to reach the ArgoCD UI in dev (port-forward; YARP route comes later)."
  value       = "kubectl -n ${var.argocd_namespace} port-forward svc/argocd-server 8081:443"
}
