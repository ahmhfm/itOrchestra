variable "namespace" {
  description = "Namespace the External Secrets Operator is installed into."
  type        = string
  default     = "external-secrets"
}

variable "chart_version" {
  description = "Pinned external-secrets Helm chart version."
  type        = string
}
