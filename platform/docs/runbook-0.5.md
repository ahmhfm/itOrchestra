# Runbook - Phase 0.5: HashiCorp Vault (Secrets Management)

This runbook covers deploying **HashiCorp Vault** - the single source of truth for every
credential, connection string, OAuth client secret, and key in the platform. Workloads never
read secrets from Git, `appsettings.json` (prod), or raw Kubernetes Secrets; they fetch them at
runtime from Vault via the **Agent Injector** (files under `/vault/secrets/`) authenticated by
the **Kubernetes auth** method (ServiceAccount JWT -> Vault role -> least-privilege policy).

> Prerequisites: Phases 0.1-0.4 healthy (cluster, Longhorn StorageClass, Linkerd, YARP,
> Keycloak), plus `helm` installed on the VM. Vault is reached only in-cluster.

## Scope of 0.5 (dev)

Implemented now:

- **Vault server** (chart `0.32.0` / Vault `1.21.2`) standalone with **integrated Raft storage**
  on a 2Gi **Longhorn** PVC (persistent across restarts). Listener `tls_disable` (dev),
  `disable_mlock = true`, `service_registration "kubernetes"`.
- **Vault Agent Injector** (`vault-k8s 1.7.2`) - the mutating webhook that injects secret files
  into annotated app pods.
- **Initialize + unseal** automated (1 Shamir key, threshold 1 - **dev only**); the unseal key
  and root token are stored in the `vault/vault-unseal-keys` Kubernetes Secret for convenience.
- **KV v2** secrets engine at `secret/` and the **Kubernetes auth** method enabled.
- **Seeded secrets** (migrated from the Phase 0.4 Kubernetes Secrets):
  - `secret/itorchestra/keycloak/admin`  -> `username`, `password`
  - `secret/itorchestra/keycloak/db`     -> `sa-password`, `kc-password`
  - `secret/itorchestra/gateway/keycloak` -> `client_secret`
- **Sample least-privilege policy + role**: policy `itorchestra-gateway` (read-only on
  `secret/data/itorchestra/gateway/*`) bound by k8s-auth role `gateway` to ServiceAccount
  `default` in `ns-gateway`.

Deferred: dynamic **database** credentials (MSSQL engine, TTL <= 1h), **PKI** + **transit**
engines, audit-log export to OpenSearch, and wiring services to consume Vault via Injector
annotations (done per service from 0.7+).

## Decisions (this environment)

- **Storage = Raft + Longhorn PVC** (persistent), single node. Prod = HA Raft (3/5 nodes).
- **Not exposed publicly**: ClusterIP only, no LoadBalancer, **no YARP route**. The UI/CLI is
  reached with `kubectl port-forward`. A secrets store must never be on the public path.
- **Out of the Linkerd mesh in dev**: the `vault` namespace is annotated
  `linkerd.io/inject: disabled`. A sidecar on the Injector (an admission webhook) breaks
  API-server -> webhook TLS calls, and meshing complicates Raft (8201) + the unseal/health flow.
  Meshed app pods still reach Vault in-cluster. **Prod** meshes Vault with
  `config.linkerd.io/opaque-ports: "8201"` and skip-inbound-ports for the webhook.
- **TLS**: `tls_disable` on the listener in dev (in-cluster only). Prod terminates real TLS
  (Vault PKI / cert-manager).

## Deploy (dev)

```bash
cd ~/itOrchestra/platform
# only if files were copied from Windows: dos2unix bootstrap/*.sh k8s/vault/*.sh
bash bootstrap/04-vault-dev.sh
```

This runs `k8s/vault/install-dev.sh` (helm install -> wait Running -> init/unseal ->
enable KV v2 + k8s auth -> seed secrets -> policy/role) then `bootstrap/verify-0.5.sh`.

### Manual equivalent

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
kubectl annotate namespace vault linkerd.io/inject=disabled --overwrite
helm upgrade --install vault hashicorp/vault -n vault --version 0.32.0 \
  -f k8s/vault/values.yaml

# wait for vault-0 to be Running (NotReady until unsealed), then:
kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=1 -key-threshold=1
kubectl -n vault exec -it vault-0 -- vault operator unseal <unseal-key>
```

## Verify

```bash
bash bootstrap/verify-0.5.sh        # expect: 8 passed, 0 failed
```

Checks: vault-0 Ready; `initialized=true` + `sealed=false`; KV v2 + Kubernetes auth enabled;
policy `itorchestra-gateway` + role `gateway` present; a seeded secret is readable; the Agent
Injector deployment is Ready.

## Operate

```bash
# Open the UI/CLI locally (no public exposure):
kubectl -n vault port-forward svc/vault 8200:8200
#   UI:  http://127.0.0.1:8200/ui

# Get the root token (DEV ONLY):
kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.root-token}' | base64 -d; echo

# Read a seeded secret:
export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root-token>
vault kv get secret/itorchestra/gateway/keycloak
```

### How a service consumes Vault (later phases)

Annotate the app pod (the Injector writes files to `/vault/secrets/`):

```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "gateway"
    vault.hashicorp.com/agent-inject-secret-keycloak: "secret/data/itorchestra/gateway/keycloak"
    vault.hashicorp.com/agent-inject-template-keycloak: |
      {{- with secret "secret/data/itorchestra/gateway/keycloak" -}}
      Keycloak__ClientSecret={{ .Data.data.client_secret }}
      {{- end }}
```

.NET reads the mounted files via a key-per-file configuration provider and reloads
`IOptionsMonitor<T>` on change (see `ai/skills/vault.md`).

## After a node/pod restart (Raft persists, but Vault re-seals)

Vault comes back **sealed** after a restart. Re-running the installer unseals it idempotently:

```bash
bash k8s/vault/install-dev.sh      # reuses the stored unseal key, re-unseals, re-applies config
```

## Teardown (dev)

```bash
helm uninstall vault -n vault
kubectl -n vault delete secret vault-unseal-keys --ignore-not-found
kubectl -n vault delete pvc -l app.kubernetes.io/name=vault   # deletes Raft data (Longhorn PVC)
```

> Deleting the PVC destroys all Vault data (keys, secrets, config). The next install starts a
> fresh, uninitialized Vault.
