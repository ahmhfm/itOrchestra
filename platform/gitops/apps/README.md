# App-of-Apps children (Phase 0.12.2)

`itorchestra-root` (registered by Terraform in 0.13.1) recurses this directory. Every
`Application` here is a child the root reconciles from Git. Ordering between children is driven
by the `argocd.argoproj.io/sync-wave` annotation (lowest wave first), **not** by file name; the
numeric file prefixes are only a human reading aid.

## Adoption policy (safe by default)

The platform was originally installed imperatively (`k8s/<comp>/install-dev.sh`). We are adopting
those live resources into GitOps **without disruption**:

- Children start with **manual sync** (no `automated` / `prune` / `selfHeal`). ArgoCD computes the
  diff and shows `Synced` / `OutOfSync` but never mutates the cluster until a human syncs.
- `ServerSideApply=true` makes adoption of kubectl-/Helm-applied objects clean (no
  `last-applied-configuration` conflict).
- Once a wave is confirmed to diff cleanly against live, auto-sync (`prune` + `selfHeal`) is
  enabled for it in a later step (0.13.6 drift detection).

Stateful and imperative-coupled components (Vault, MSSQL, Redis, OpenSearch, Qdrant, Keycloak)
stay manual the longest, because their bootstrap also performs imperative side-effects that GitOps
does not own (secret generation, Vault seeding, model pulls, collection init, image rebuilds).

## Sync-wave plan

| Wave | Child Application            | Source                              | Status |
|------|------------------------------|-------------------------------------|--------|
| -10  | `platform-namespaces`        | `k8s/namespaces` (manifests)        | done (auto-sync: selfHeal, no prune) |
|  -9  | `platform-network-policies`  | `k8s/network-policies` (manifests)  | done (auto-sync: selfHeal + prune)   |
|  -8  | `platform-storage-class`     | `k8s/cluster/longhorn` (SC only)    | done (StorageClass only; Longhorn chart adopted later) |
|  -7  | `ingress-nginx`              | helm 4.11.3 + repo values (multi-src) | adopting (manual; webhook caBundle ignored) |
|  -7  | MetalLB pool                 | n/a                                 | **deferred in dev** - the pool is auto-detected from the VM NIC at runtime (`metallb/install.sh`); the repo `ippool.dev.yaml` is only an example and does NOT match the live `10.178.95.240-250` pool. GitOps-ifying it would break the LB IP. Revisit with a static per-env pool in 0.13.5. |
|  -5  | `platform-secrets`           | `gitops/components/secrets` (ESO)   | done   |
|   0  | data stores (vault/redis/mssql/opensearch/qdrant) | helm + manifests | todo (manual) |
|   5  | `keycloak`                   | `k8s/keycloak` (manifests)          | todo (manual) |
|  10  | `observability`              | helm multi-source + manifests       | todo (manual) |
|  15  | `ai` (ollama)                | helm + manifests                    | todo (manual) |
|  20  | `gateway` / `crewai`         | `k8s/gateway` / `k8s/crewai`        | todo   |

Helm-backed components are modeled as ArgoCD multi-source Applications: the upstream chart at a
**pinned** version + the repo's `values.yaml` as a second source. Imperative bootstrap steps remain
as scripts/Jobs and are documented per component.
