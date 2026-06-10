variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the dev cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to use (empty = current-context)."
  type        = string
  default     = ""
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

# Pinned chart versions (verified 2026-06; bump deliberately). See platform rule on no floating deps.
variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (app v3.4.x)."
  type        = string
  default     = "9.5.20"
}

variable "eso_namespace" {
  type    = string
  default = "external-secrets"
}

variable "eso_chart_version" {
  description = "external-secrets Helm chart version."
  type        = string
  default     = "2.6.0"
}

variable "gitops_repo_url" {
  description = "Git repo ArgoCD syncs from. If PRIVATE, add repo credentials to ArgoCD first."
  type        = string
  default     = "https://github.com/ahmhfm/itOrchestra.git"
}

variable "gitops_target_revision" {
  description = "Git revision the App-of-Apps root tracks (dev = main)."
  type        = string
  default     = "main"
}

variable "gitops_apps_path" {
  description = "Repo path with the child Application manifests."
  type        = string
  default     = "platform/gitops/apps"
}
