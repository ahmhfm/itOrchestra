# GitOps bootstrap: register the single ArgoCD "App-of-Apps" root + its AppProject. After this,
# Terraform never touches in-cluster app state again - ArgoCD reconciles every child Application
# (and thus every platform component) from Git. This is the only Terraform->ArgoCD handoff.
terraform {
  required_providers {
    kubectl = {
      source = "gavinbunney/kubectl"
    }
  }
}

# AppProject scoping which repo/destinations the platform may deploy from. Cluster + namespace
# resource whitelists are wide here because the platform legitimately manages cluster-scoped objects
# (namespaces, CRDs, ClusterSecretStores, etc.); tighten per-tenant projects in later sub-steps.
#
# sourceRepos = "*": this single platform-admin project legitimately deploys from the Git repo AND
# many upstream Helm chart repos (ingress-nginx, longhorn, hashicorp/vault, prometheus-community,
# grafana, open-telemetry, qdrant, ...). Enumerating them is brittle; the wide cluster/namespace
# whitelists already make this an admin project. Per-tenant/service projects (0.12.4+) will be
# locked down to specific repos.
resource "kubectl_manifest" "app_project" {
  validate_schema = false
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "itorchestra"
      namespace = var.argocd_namespace
    }
    spec = {
      description  = "itOrchestra platform delivered via GitOps (Phase 0.12)."
      sourceRepos  = ["*"]
      destinations = [{
        server    = "https://kubernetes.default.svc"
        namespace = "*"
      }]
      clusterResourceWhitelist   = [{ group = "*", kind = "*" }]
      namespaceResourceWhitelist = [{ group = "*", kind = "*" }]
    }
  })
}

# The root Application points at the apps/ directory and recurses, so every child Application file
# committed there is picked up automatically. Self-heal + prune make Git the source of truth.
resource "kubectl_manifest" "root_app" {
  validate_schema = false
  depends_on      = [kubectl_manifest.app_project]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "itorchestra-root"
      namespace  = var.argocd_namespace
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "itorchestra"
      source = {
        repoURL        = var.repo_url
        targetRevision = var.target_revision
        path           = var.apps_path
        directory      = { recurse = true }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.argocd_namespace
      }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  })
}
