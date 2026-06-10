variable "argocd_namespace" {
  description = "Namespace where ArgoCD runs (the Application/AppProject objects live here)."
  type        = string
  default     = "argocd"
}

variable "repo_url" {
  description = "Git repository URL ArgoCD syncs from."
  type        = string
}

variable "target_revision" {
  description = "Git revision (branch/tag) the App-of-Apps root tracks."
  type        = string
  default     = "main"
}

variable "apps_path" {
  description = "Repo path containing the child Application manifests (recursed)."
  type        = string
  default     = "platform/gitops/apps"
}
