# itOrchestra GitOps (ArgoCD) - Phase 0.12

ArgoCD is the single source of truth for everything **inside** the cluster. Terraform installs
ArgoCD + ESO and registers one root Application; from there this directory drives the platform.

```
gitops/
  apps/                       # App-of-Apps children (one Application per component/service)
    platform-secrets.yaml     #   -> ESO Vault ClusterSecretStore (the first child)
  components/                 # the actual manifests each child Application points at
    secrets/
      clustersecretstore.yaml # ESO ClusterSecretStore -> Vault (KV v2 @ secret/)
      kustomization.yaml
```

## How it flows

```
Terraform (bootstrap)
   └─ Application: itorchestra-root  (syncs gitops/apps/, recurse=true)
        └─ Application: platform-secrets  (syncs gitops/components/secrets/)
             └─ ClusterSecretStore: vault-backend  (ESO authenticates to Vault via k8s-auth)
```

Add a new component by committing one `Application` file under `apps/` pointing at its manifests
(an existing Helm chart in `platform/charts/`, a `k8s/<svc>` dir, or a `components/` overlay). The
root app picks it up automatically (no Terraform change needed).

## Secrets in GitOps

No secret values live in Git. A service that needs a secret commits an `ExternalSecret` referencing
the `vault-backend` ClusterSecretStore; ESO materializes it into a native Kubernetes Secret from
`secret/itorchestra/*` in Vault. (ExternalSecrets for the existing services are wired in 0.13.2.)

## Conventions (rolling out across 0.13.2+)

- One `Application` per component, `project: itorchestra`, `automated { prune, selfHeal }`.
- **Sync waves** order dependencies (e.g. CRDs/secret-stores before the workloads that use them) via
  `argocd.argoproj.io/sync-wave` annotations.
- Per-environment variants come from ApplicationSet generators (0.13.5), not copy-pasted files.
