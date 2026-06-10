variable "namespace" {
  description = "Namespace ArgoCD is installed into."
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "Pinned argo-cd Helm chart version (argoproj/argo-helm)."
  type        = string
}

variable "values_yaml" {
  description = "Optional extra chart values as a YAML string."
  type        = string
  default     = ""
}
