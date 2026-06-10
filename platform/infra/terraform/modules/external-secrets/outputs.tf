output "namespace" {
  description = "Namespace ESO was installed into (the ClusterSecretStore SA lives here)."
  value       = helm_release.external_secrets.namespace
}
