# All three providers target the EXISTING dev cluster via the local kubeconfig (Terraform does not
# create the K3s cluster in dev - that stays in the imperative bootstrap until 0.13.3 adds a cluster
# module for fresh environments). pathexpand handles the leading "~".
locals {
  kubeconfig = pathexpand(var.kubeconfig_path)
}

provider "kubernetes" {
  config_path    = local.kubeconfig
  config_context = var.kube_context != "" ? var.kube_context : null
}

provider "helm" {
  kubernetes {
    config_path    = local.kubeconfig
    config_context = var.kube_context != "" ? var.kube_context : null
  }
}

provider "kubectl" {
  config_path      = local.kubeconfig
  config_context   = var.kube_context != "" ? var.kube_context : null
  load_config_file = true
}
