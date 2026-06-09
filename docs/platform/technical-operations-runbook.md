# itOrchestra Platform — Technical Operations Runbook

> Consolidated operations reference for the itOrchestra shared platform (Phase 0, steps 0.1–0.12).
> Source of truth for day-to-day operations: architecture, CI/CD, Helm, namespaces, RBAC, network
> policy, secrets, backup/DR, deployment, operations, and troubleshooting.
>
> Per-step detail lives in `platform/docs/runbook-0.X.md`; this document is the cross-cutting view.
> **Profile:** everything below describes the **dev** profile (single-node K3s on one Ubuntu VM).
> Each section ends with the **prod** delta where it differs.

---

## Table of Contents

1. [Architecture Diagram](#1-architecture-diagram)
2. [GitHub Actions Workflows](#2-github-actions-workflows)
3. [Helm Charts Inventory](#3-helm-charts-inventory)
4. [Kubernetes Namespaces](#4-kubernetes-namespaces)
5. [RBAC & Service Accounts](#5-rbac--service-accounts)
6. [Network Policies](#6-network-policies)
7. [Secrets Management](#7-secrets-management)
8. [Backup Strategy](#8-backup-strategy)
9. [Disaster Recovery Plan](#9-disaster-recovery-plan)
10. [Deployment Procedures](#10-deployment-procedures)
11. [Operational Procedures](#11-operational-procedures)
12. [Troubleshooting Guide](#12-troubleshooting-guide)

---

## 1. Architecture Diagram

External clients enter **only** through the YARP API Gateway (single public entry point, TLS
terminated at the edge via MetalLB LoadBalancer). Inside the cluster, service-to-service traffic
is gRPC over **Linkerd** mTLS; shared data stores sit **out of the mesh** and are reached
in-cluster only. Asynchronous flows use **Redis Streams**. All secrets come from **Vault**.

```mermaid
flowchart TB
  client["External clients<br/>(browser / WPF / MAUI / 3rd-party)"]

  subgraph edge["Edge (public)"]
    mlb["MetalLB LoadBalancer<br/>10.178.95.241:443"]
    gw["YARP API Gateway<br/>ns-gateway (meshed)<br/>TLS · routing · rate-limit · CORS · correlation-id"]
  end

  subgraph mesh["Linkerd mesh (mTLS, in-cluster)"]
    crewai["CrewAI orchestration<br/>ns-crewai · gRPC :50051<br/>itorchestra.crewai.v1"]
    future["ns-identity / ns-assets / ns-discovery<br/>(reserved, not yet deployed)"]
    kc["Keycloak (IAM)<br/>keycloak ns (meshed) :8080"]
  end

  subgraph data["Shared data stores (out of mesh, internal-only)"]
    vault["Vault<br/>vault ns :8200 (Raft)"]
    redis["Redis 8<br/>redis ns :6379 (AOF)"]
    mssql["MSSQL Always On AG<br/>mssql ns :1433 / :5022"]
    kcdb["keycloak-mssql<br/>keycloak ns :1433"]
  end

  subgraph ai["AI layer (out of mesh, internal-only)"]
    qdrant["Qdrant 3-node<br/>ai ns :6333/:6334"]
    ollama["Ollama (CPU)<br/>ai ns :11434"]
  end

  subgraph obs["Observability (out of mesh)"]
    otel["OTel Collector :4317/:4318"]
    tempo["Tempo (traces)"]
    prom["Prometheus + AlertManager"]
    osearch["OpenSearch (logs)"]
    graf["Grafana :3000"]
  end

  subgraph bk["Backup & DR (backup ns, out of mesh)"]
    velero["Velero + node-agent (kopia FSB)"]
    minio["MinIO S3 — bytes on VM hostPath<br/>/srv/itorchestra/backups/minio"]
  end

  client -->|HTTPS+JWT| mlb --> gw
  gw -->|/realms /admin /grafana| kc
  gw -->|/grafana :3000| graf
  gw -.->|future REST routes| future
  gw -->|gRPC mTLS| crewai

  crewai -->|gRPC RAG / LLM| qdrant
  crewai --> ollama
  crewai -->|TDS :1433 (SP-only)| mssql
  crewai -->|Agent token :8200| vault
  kc --> kcdb

  velero --> minio
  velero -. backup hooks .-> mssql
  velero -. SAVE .-> redis

  classDef store fill:#eef,stroke:#88a;
  class vault,redis,mssql,kcdb,qdrant,ollama store;
```

**Key invariants**
- External traffic enters only via YARP; no microservice is exposed directly (ClusterIP + no YARP route = unreachable from outside).
- Internal sync calls are gRPC over Linkerd mTLS; data stores are out of mesh and secured by AUTH/TLS at transport.
- Each microservice owns its private database (Database-per-Service). All SQL lives in stored procedures; the app calls SPs via ADO.NET (or, for crewai, a thin Python client) — never inline SQL.
- Redis is the cache-aside first read source + Streams bus; MSSQL is the source of truth.

**prod delta:** multi-node K3s/RKE2 (HA control plane), data stores meshed with `opaque-ports`, OpenSearch/Grafana fronted by Keycloak OIDC, off-cluster object storage for backups.

---

## 2. GitHub Actions Workflows

Location: `.github/workflows/` + one composite action `.github/actions/image-supply-chain/` +
`.github/dependabot.yml`. The model is **reusable workflows** (`workflow_call`) invoked by thin
per-service **caller** workflows.

| Workflow | Type | Trigger | What it does |
|---|---|---|---|
| `ci-dotnet.yml` | Reusable | `workflow_call` | `dotnet restore` → `dotnet format --verify-no-changes` (**strict gate**) → strict build (Roslyn analyzers + warnings-as-errors via `Directory.Build.props`, SDK pinned by `global.json`) → tests (auto-discovered `*Tests.csproj`, Testcontainers-ready) → `dotnet list package --vulnerable` (+ optional Snyk) |
| `ci-python.yml` | Reusable | `workflow_call` | `ruff` format/lint (**strict gate**) → dependency install → tests → pip vulnerability scan |
| `ci-proto.yml` | Reusable | `workflow_call` | `buf lint` + `buf breaking` (**strict gate**) on `.proto` contracts |
| `cd-helm.yml` | Reusable | `workflow_call` | `helm lint` + `helm template` + server **dry-run** (safe scaffold); real rollout via `helm upgrade --install` when `DEPLOY_RUNNER` var + `KUBE_CONFIG` secret are set; env-gated `dev → staging → prod` |
| `gateway.yml` | Caller | PR / push `main` / tag `v*` | `.NET` CI → image supply-chain → CD (gateway) |
| `crewai.yml` | Caller | PR / push `main` / tag `v*` | Python CI + proto CI → image supply-chain → CD (crewai) |

**Composite action `image-supply-chain`** (on push to `main` / tag `v*`): multi-stage **Docker
build** → **Trivy** image scan → push to **GHCR** → **Cosign** keyless signing (GitHub OIDC) →
**Syft SBOM** generated and attested to the image.

**Gates & environments**
- Strict gates that fail the build: `dotnet format` / `ruff` formatting, `buf breaking`, build warnings-as-errors.
- GitHub **Environments** `dev` / `staging` / `prod`; `staging` and `prod` require reviewer approval (deployment protection rules).
- **Dependabot** opens weekly PRs across GitHub Actions, NuGet, pip, and Docker base images.

**Validate locally / one-time setup checklist:**
```bash
cd ~/itOrchestra/platform
bash bootstrap/10-cicd.sh        # validates assets + prints the GitHub setup checklist
bash bootstrap/verify-0.11.sh
```

**prod delta:** require reviewers on staging/prod, enforce Snyk + Cosign signature verification at admission, mirror images into an internal Harbor, deploy for real from a self-hosted runner with cluster access.

---

## 3. Helm Charts Inventory

All third-party charts are **version-pinned** in their installers (reproducible installs; no
`latest` drift). Each version is overridable via the noted env var.

| Component | Chart | Version | Namespace | Meshed | Override env | Installer |
|---|---|---|---|---|---|---|
| Cilium (CNI + NetworkPolicy) | `cilium/cilium` | `1.16.5` | kube-system | n/a | `CILIUM_VERSION` | `k8s/cluster/cilium/install-cilium.sh` |
| MetalLB (LoadBalancer) | `metallb/metallb` | `0.14.9` | metallb-system | n/a | `METALLB_VERSION` | `k8s/cluster/metallb/install.sh` |
| ingress-nginx | `ingress-nginx/ingress-nginx` | `4.11.3` | ingress-nginx | n/a | `INGRESS_NGINX_VERSION` | `k8s/cluster/ingress-nginx/install.sh` |
| Longhorn (storage) | `longhorn/longhorn` | `1.7.2` | longhorn-system | no | `LONGHORN_VERSION` | `k8s/cluster/longhorn/install.sh` |
| Linkerd (CRDs + control plane) | `linkerd/*` | `edge` channel | linkerd / linkerd-viz | n/a | `LINKERD_CHANNEL` | `k8s/cluster/linkerd/install-linkerd-*.sh` |
| HashiCorp Vault | `hashicorp/vault` | `0.32.0` (Vault 1.21.2, vault-k8s 1.7.2) | vault | no | `CHART_VERSION` | `k8s/vault/install-dev.sh` |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | `86.2.0` | observability | no | `KPS_CHART_VERSION` | `k8s/observability/install-dev.sh` |
| Tempo | `grafana/tempo` | `1.24.4` | observability | no | `TEMPO_CHART_VERSION` | `k8s/observability/install-dev.sh` |
| OpenTelemetry Collector | `open-telemetry/opentelemetry-collector` | `0.158.1` | observability | no | `OTEL_CHART_VERSION` | `k8s/observability/install-dev.sh` |
| Qdrant | `qdrant/qdrant` | `1.18.2` | ai | no | `QDRANT_CHART_VERSION` | `k8s/ai/install-dev.sh` |
| Velero | `vmware-tanzu/velero` | `12.0.2` (Velero 1.18.1) | backup | no | `VELERO_CHART_VERSION` | `k8s/backup/install-dev.sh` |

**Not Helm (raw manifests / images):** OpenSearch (StatefulSet), Redis (`redis:8.8.0`), MSSQL AG
(`mssql/server:2022`), Keycloak (`quay.io/keycloak/keycloak:26.6.3`), Ollama, MinIO
(`minio/minio` RELEASE-pinned), and the generic application chart `platform/charts/itorchestra-service`.

`verify-0.8` / `verify-0.9` assert the deployed chart matches the pin.

**prod delta:** pin every image digest too; mirror charts/images into an internal registry; replace dev raw manifests with hardened/HA variants.

---

## 4. Kubernetes Namespaces

| Namespace | Purpose | Pod Security | Linkerd | Notes |
|---|---|---|---|---|
| `ns-gateway` | YARP API Gateway (edge) | restricted | meshed | only namespace behind the MetalLB LoadBalancer |
| `ns-crewai` | CrewAI orchestration (gRPC) | restricted | meshed | internal-only; consumes ai + mssql + vault |
| `ns-identity` | reserved microservice | restricted | meshed | not yet deployed |
| `ns-assets` | reserved microservice | restricted | meshed | not yet deployed |
| `ns-discovery` | reserved microservice | restricted | meshed | not yet deployed |
| `keycloak` | Keycloak IAM + private MSSQL | baseline | meshed | reached only via YARP |
| `vault` | HashiCorp Vault (Raft) + Agent Injector | baseline | **not meshed** | sidecar breaks API-server→webhook TLS |
| `redis` | Redis cache + Streams | baseline | **not meshed** | AUTH; out of mesh by design |
| `mssql` | SQL Server Always On AG | baseline | **not meshed** | TDS/AG secured by TLS at transport |
| `ai` | Qdrant + Ollama | baseline | **not meshed** | internal-only, NetworkPolicy-fenced |
| `observability` | OTel/Tempo/Prometheus/Grafana/OpenSearch | **privileged** | **not meshed** | node-exporter needs hostNetwork/hostPath |
| `backup` | Velero + MinIO | **privileged** | **not meshed** | node-agent host-mounts kubelet pods dir |
| `linkerd`, `linkerd-viz` | service mesh control plane | — | — | installed in 0.2 |
| `kube-system`, `metallb-system`, `ingress-nginx`, `longhorn-system` | cluster infra | — | — | from 0.1 |

Convention: every namespace carries `name=<ns>` and `kubernetes.io/metadata.name=<ns>` labels used
by NetworkPolicy selectors.

**prod delta:** mesh `keycloak`-adjacent data stores and `observability` with `opaque-ports`; tighten the `baseline` infra namespaces toward `restricted` where the workload allows.

---

## 5. RBAC & Service Accounts

**Principle: least privilege + distinct identity.** Each workload runs under its **own dedicated
ServiceAccount** (never the namespace `default` SA). These SAs carry **no Role/RoleBinding** — the
services never call the Kubernetes API, so they hold **zero cluster RBAC**. The SA exists purely to
give each workload a distinct identity for **Vault Kubernetes-auth**, auditing, and policy scoping.

| Workload | Namespace | ServiceAccount | `automountServiceAccountToken` | Cluster RBAC | Vault k8s-auth role |
|---|---|---|---|---|---|
| gateway | ns-gateway | `gateway` | true | none | `gateway` → policy `itorchestra-gateway` |
| crewai | ns-crewai | `crewai` | true | none | `crewai` → policy `itorchestra-crewai` |

- `automountServiceAccountToken: true` is kept on because the **Vault Agent** uses the SA token to log in to Vault.
- The generic chart `itorchestra-service` creates a dedicated SA by default (`serviceAccount.create: true`); the helper derives the name from the release fullname.
- Operator/CI access to the cluster uses kubeconfig credentials (out of band), not workload SAs.

**Verify:**
```bash
bash bootstrap/verify-0.3.sh    # asserts gateway pod runs as SA 'gateway'
bash bootstrap/verify-0.10.sh   # asserts crewai pod runs as SA 'crewai'
bash bootstrap/verify-0.5.sh    # asserts Vault roles bound to the dedicated SAs
```

**prod delta:** if a workload ever needs the K8s API, grant a **narrow Role** (namespaced, specific verbs/resources) bound to its dedicated SA — never a ClusterRole unless unavoidable. Add per-namespace restore RBAC for backup operators.

---

## 6. Network Policies

**Model:** application namespaces are **default-deny** (ingress + egress); only DNS is open by
default, everything else is explicitly allowed per service. Shared data-store / infra namespaces
are **ingress-fenced** (default-deny ingress; egress left open so they can reach the K8s API / DNS /
their own DBs).

**Meshed source → out-of-mesh destination:** the source Linkerd proxy dials the destination's real
app port (no `4143` hop). **Meshed → meshed:** the source proxy dials the destination proxy inbound
`4143`.

| Namespace | Fence policy | Allowed ingress |
|---|---|---|
| `ns-crewai` | `default-deny-all` + allow-list | DNS; Linkerd control plane; linkerd-viz scrape `4191`; egress→ai (6333/6334/11434), mssql (1433), **vault (8200)**; gRPC ingress `50051` from consuming service namespaces |
| `ns-gateway` | default-deny + egress allows | egress→keycloak (`4143`/`8080`), observability Grafana (`3000`); ingress on `443` |
| `vault` | `vault-ingress-fence` | intra-namespace (Raft 8201 + injector); `:8200` from `ns-crewai`, `ns-gateway` |
| `redis` | `redis-ingress-fence` | intra-namespace only (no network consumer yet) |
| `mssql` | `mssql-ingress-fence` | intra-namespace (HADR 5022 + TDS); `:1433` from `ns-crewai` |
| `keycloak` | `keycloak-ingress-fence` | intra-namespace (→ keycloak-mssql 1433); `:4143`/`:8080` from `ns-gateway`; `:4191` from `linkerd-viz` |
| `observability` | `observability-ingress-fence` | intra-namespace (Grafana↔Prometheus/Tempo/OpenSearch, Collector→OpenSearch/Tempo); `:3000` from `ns-gateway` |
| `ai` | `default-deny-all` + allow-list | from microservice namespaces (Qdrant 6333/6334, Ollama 11434) + Prometheus scrape |

`kubectl exec`, kubelet probes, and the prometheus-operator admission webhook are **host-sourced**
(node / API-server) and are not gated by NetworkPolicy under Cilium's default (no host firewall).

**Verify each fence exists:** `verify-0.4` (keycloak), `verify-0.5` (vault), `verify-0.6` (redis),
`verify-0.7` (mssql), `verify-0.8` (observability).

**Adding a new consumer** (e.g. service X needs Redis): add an **egress** rule on `ns-X` to `redis:6379`
**and** an **ingress** allow on the `redis-ingress-fence` for `ns-X`; both sides are required.

**prod delta:** add egress fences on the data-store namespaces too; enable Cilium host firewall and explicitly allow the API-server/kubelet; consider Linkerd `Server`/`AuthorizationPolicy` for L7 authz.

---

## 7. Secrets Management

**Vault is the only production secrets source.** No secrets in Git (`.gitignore` blocks kubeconfig
and key material). MSSQL is the source of truth for business data; Vault is the source of truth for
secrets; Redis is the cache-aside first read source for config/hot data.

**Vault KV v2 layout (`secret/itorchestra/...`):**

| Path | Contents | Seeded by |
|---|---|---|
| `keycloak/admin`, `keycloak/db` | Keycloak admin + DB creds | 0.4/0.5 |
| `gateway/keycloak` | gateway's Keycloak client secret | 0.5 |
| `shared/redis` | Redis password | 0.6 |
| `shared/mssql-ag` | SA password + connection strings | 0.7 |
| `shared/observability` | Grafana admin + stack endpoints | 0.8 |
| `shared/ai` | Qdrant API key + LLM endpoints | 0.9 |
| `shared/crewai` | gRPC endpoint + DB creds (incl. `db-password`) | 0.10/0.12 |
| `shared/backup` | MinIO S3 endpoint + access keys | 0.12 |

**Runtime consumption — Vault Agent Injector (preferred):** pods carry `vault.hashicorp.com/agent-*`
annotations; the agent logs in with the pod's dedicated SA (k8s-auth role → least-privilege policy)
and renders secret files under `/vault/secrets/` **before** the app starts.

- **crewai** is wired end-to-end: renders `/vault/secrets/app.env` (`DB_PASSWORD` + `QDRANT_API_KEY`) read by `app/config.py`, which **falls back** to the k8s `crewai-secrets` env if the file is absent (CD/Helm path or Vault unavailable). The agent runs as uid `10001` so the app can read the file.
- **gateway**: its only runtime secret today is the TLS `.pfx` password (the cert file is a k8s Secret), so Vault-runtime wiring is deferred until it gains a Vault-resident secret (JWT/OIDC client secret); the `gateway` Vault role/policy already exist.
- The generic chart exposes `podAnnotations` so any service opts in the same way via `values-<env>.yaml`.

**Seeding (out of band):** install scripts read source material and write it into Vault via
`kubectl exec vault-0 -- vault kv put ...` (not over the network — not NetworkPolicy-gated).

**prod delta:** HA Raft with real TLS, KMS auto-unseal, split Shamir keys, **no** persisted root token, secret rotation, and (optionally) meshed Vault with `opaque-ports`. Dev keeps a single Shamir key + persisted root token in `vault/vault-unseal-keys` for convenience only.

---

## 8. Backup Strategy

**Stack:** Velero (cluster resources + PV data via kopia **File System Backup**) targeting an
in-cluster **MinIO** S3 endpoint whose bytes live on the **VM host disk** (`hostPath`
`/srv/itorchestra/backups/minio`, `reclaimPolicy: Retain`) — so backups survive loss of Longhorn or
the entire cluster. Namespace `backup` (privileged PSA, out of mesh).

**What is backed up:** namespaces `vault`, `redis`, `mssql`, `keycloak`, `ai`, `observability`,
`ns-gateway`, `ns-crewai` — resources **and** PV data (FSB opt-out model: every pod volume unless
excluded).

**Application consistency (Velero pre-hooks, run inside the pod just before the volume copy):**
- **MSSQL** (`mssql-ag-0` only): `EXEC master.dbo.sp_Maint_Backup_AllDatabases` — a `COPY_ONLY`, checksummed, compressed `.bak` per ONLINE user DB on the data PVC (the SQL stays in a stored procedure, per the platform rule). `COPY_ONLY` so the diff/log chain is undisturbed.
- **Redis**: `SAVE` flushes a fresh `dump.rdb` (AOF already on) before the copy.
- **Vault**: no exec hook (a raft snapshot needs a token); `/vault/data` raft store is captured by FSB. For a guaranteed-consistent Vault backup, run `vault operator raft snapshot save` (see DR).

**Schedule:** `daily-full` at `01:00`, `ttl: 168h` (7-day retention). Endpoint mirrored to Vault at
`secret/itorchestra/shared/backup`.

**Install / verify:**
```bash
cd ~/itOrchestra/platform
bash bootstrap/11-backup-dev.sh
bash bootstrap/verify-0.12.sh                 # RUN_BACKUP=1 to add a live backup+restore smoke
```

**On-demand backup:**
```bash
velero backup create manual-$(date +%s) --from-schedule daily-full -n backup
velero backup get -n backup
```

**prod delta:** off-cluster object storage (dedicated MinIO/S3 box or NFS appliance), encrypted backups, more frequent schedules + longer retention, per-namespace restore RBAC, periodic restore drills, scheduled `vault operator raft snapshot`, and MSSQL log backups for true point-in-time recovery.

---

## 9. Disaster Recovery Plan

> Full procedures in `platform/docs/runbook-0.12.md`. Summary below. Velero CLI talks to the
> `backup` namespace; MinIO bytes persist on the VM host disk even if the cluster is destroyed.

**A) Restore a single namespace**
```bash
velero backup get -n backup
velero restore create --from-backup <backup-name> --include-namespaces <ns> -n backup
velero restore describe <restore-name> -n backup --details
```

**B) MSSQL database restore** (from the `.bak` captured on the data PVC / restored volume)
```bash
kubectl -n mssql exec -it mssql-ag-0 -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PW" -C \
  -Q "RESTORE DATABASE [<db>] FROM DISK=N'/var/opt/mssql/backups/<db>.bak' WITH REPLACE, RECOVERY"
# Re-add the database to the AG if it was an AG member (see runbook-0.7.md).
```

**C) Vault restore** (Raft snapshot — the guaranteed-consistent path)
```bash
# Backup (do this on a schedule in prod):
kubectl -n vault exec -it vault-0 -- vault operator raft snapshot save /tmp/vault.snap
# Restore into a fresh Vault:
kubectl -n vault exec -i  vault-0 -- vault operator raft snapshot restore - < vault.snap
```

**D) Full cluster rebuild** (cluster/Longhorn lost; backup bytes survive on `hostPath`)
1. Reprovision the VM/K3s (`docs/runbook-vm-setup.md` + `bootstrap/00-bootstrap-dev.sh` through 0.1).
2. Re-deploy the `backup` layer pointing MinIO at the **surviving** `/srv/itorchestra/backups/minio` (the PV uses `Retain`, so the bucket is intact): `bash bootstrap/11-backup-dev.sh`.
3. `velero backup get -n backup` should list the prior backups from the recovered bucket.
4. Restore namespaces in dependency order: `vault` → `mssql`/`redis`/`keycloak` → `ai`/`observability` → `ns-gateway`/`ns-crewai`.
5. Unseal Vault (or restore its raft snapshot), then re-run service installers to reconcile config that lives outside backups.

**RPO/RTO (dev):** RPO ≈ 24h (daily schedule); RTO bounded by restore + re-seed time. **prod:** tighten RPO with frequent schedules + log backups; rehearse RTO via restore drills.

---

## 10. Deployment Procedures

**A) Bootstrap order (dev, one VM)** — the canonical sequence is encoded in `bootstrap/`:

| Step | Script | Brings up |
|---|---|---|
| 0.1 | `bootstrap/00-bootstrap-dev.sh` | K3s + Cilium + Longhorn + ingress-nginx + MetalLB + namespaces + base NetworkPolicies |
| 0.2 | `bootstrap/01-mesh-dev.sh` | Linkerd (+ CNI plugin, viz) |
| 0.3 | `bootstrap/02-gateway-dev.sh` | YARP gateway |
| 0.4 | `bootstrap/03-keycloak-dev.sh` | Keycloak + private MSSQL |
| 0.5 | `bootstrap/04-vault-dev.sh` | Vault + Agent Injector |
| 0.6 | `bootstrap/05-redis-dev.sh` | Redis |
| 0.7 | `bootstrap/06-mssql-ag-dev.sh` | MSSQL Always On AG |
| 0.8 | `bootstrap/07-observability-dev.sh` | OTel/Tempo/Prometheus/Grafana/OpenSearch |
| 0.9 | `bootstrap/08-ai-dev.sh` | Qdrant + Ollama |
| 0.10 | `bootstrap/09-crewai-dev.sh` | CrewAI orchestration |
| 0.11 | `bootstrap/10-cicd.sh` | CI/CD validation + setup checklist |
| 0.12 | `bootstrap/11-backup-dev.sh` | Velero + MinIO backup layer |

Each `bootstrap/0X-*.sh` runs the relevant `k8s/<component>/install-dev.sh` then `bootstrap/verify-0.X.sh`. All installers are **idempotent** (safe to re-run).

**B) Application deployment (CD via Helm).** Services are deployed by the generic chart
`platform/charts/itorchestra-service` with per-env values at `platform/deploy/<service>/values-<env>.yaml`.
The `cd-helm.yml` workflow runs `helm lint` + `helm template` + dry-run by default; set the
`DEPLOY_RUNNER` repo variable + `KUBE_CONFIG` secret to enable real `helm upgrade --install` through
`dev → staging → prod` (staging/prod gated by Environment reviewers). Images are GHCR-hosted,
Cosign-signed, SBOM-attested.

**C) Rebuilding a dev image** (when service code changes, before re-running its installer):
```bash
bash <service>/build-and-import-dev.sh      # e.g. crewai/build-and-import-dev.sh, gateway/build-and-import-dev.sh
```

**prod delta:** real CD on a self-hosted runner with cluster access; signature verification at admission; HPA + PodDisruptionBudgets; blue/green or canary via Linkerd traffic split.

---

## 11. Operational Procedures

**Vault — unseal / read root token (dev):**
```bash
kubectl -n vault exec -it vault-0 -- vault operator unseal "$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.unseal-key}' | base64 -d)"
kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.root-token}' | base64 -d; echo
```

**Vault UI / Grafana / Qdrant (no external exposure — use port-forward):**
```bash
kubectl -n vault port-forward svc/vault 8200:8200
kubectl -n backup port-forward svc/minio 9001:9001     # MinIO console
# Grafana is reachable through YARP at https://<gateway-ip>/grafana
```

**MSSQL AG — manual failover (clusterless; no automatic listener):**
1. Promote the secondary on `mssql-ag-1` (see `runbook-0.7.md` for the `ALTER AVAILABILITY GROUP ... FAILOVER` steps).
2. Repoint the `mssql-ag-primary` Service selector to the new primary pod:
```bash
kubectl -n mssql patch svc mssql-ag-primary -p '{"spec":{"selector":{"app":"mssql-ag","statefulset.kubernetes.io/pod-name":"mssql-ag-1"}}}'
```

**Scale a stateless service:** `kubectl -n <ns> scale deploy/<svc> --replicas=N` (or set `replicas` in `values-<env>.yaml` and let CD roll it).

**Rotate a secret:** update it in Vault (`vault kv put ...`), then restart the consumer so the Agent re-renders: `kubectl -n <ns> rollout restart deploy/<svc>`.

**Run an on-demand backup / list backups:**
```bash
velero backup create manual-$(date +%s) --from-schedule daily-full -n backup
velero backup get -n backup
```

**Re-mesh / un-mesh a workload:** set the namespace/pod `linkerd.io/inject` annotation, then
`kubectl -n <ns> rollout restart <workload>` to recreate the pod with/without the proxy.

**Health snapshot:**
```bash
kubectl get pods -A | grep -vE 'Running|Completed'      # anything unhealthy
linkerd check                                            # mesh health
for v in 0.3 0.4 0.5 0.6 0.7 0.8 0.9 0.10 0.12; do bash bootstrap/verify-$v.sh || echo "FAILED $v"; done
```

---

## 12. Troubleshooting Guide

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| Pod stuck `Init:` with a `vault-agent-init` container | Agent can't reach Vault (NetworkPolicy / role / Vault sealed) | `kubectl -n <ns> logs <pod> -c vault-agent-init` | ensure `allow-egress-to-vault` + vault ingress fence allow the ns on `:8200`; confirm the k8s-auth role binds the pod's SA; unseal Vault |
| `/vault/secrets/app.env` empty / app uses old creds | Vault KV key missing or rendered empty | `kubectl -n <ns> exec <pod> -c <app> -- cat /vault/secrets/app.env` | seed the key in Vault; the loader ignores empty values and falls back to the k8s Secret env |
| Data store unreachable from a service after fencing | missing ingress allow on the store **or** egress allow on the consumer | `kubectl -n <store-ns> get netpol`; `kubectl -n <svc-ns> get netpol` | add **both** the store ingress allow and the consumer egress allow for the port |
| `verify-0.6` fails `Out of mesh` (Redis has `linkerd-proxy`) | namespace `linkerd.io/inject` drifted to `enabled` | `kubectl get ns redis -o jsonpath='{.metadata.annotations.linkerd\.io/inject}'` | `kubectl annotate ns redis linkerd.io/inject=disabled --overwrite && kubectl -n redis rollout restart statefulset/redis` |
| Grafana 502 through YARP | gateway egress to `observability:3000` missing, or fence blocks it | `kubectl -n observability get netpol observability-ingress-fence -o yaml` | ensure `:3000` allowed from `ns-gateway` and the gateway egress rule exists |
| Keycloak OIDC fails through gateway | keycloak fence missing `4143`/`8080` from `ns-gateway`, or wrong `KC_HOSTNAME` | `verify-0.4`; check `keycloak-ingress-fence` | re-apply `k8s/keycloak/networkpolicy.yaml`; confirm `KC_HOSTNAME` = gateway URL |
| `helm repo add` silently failed in an installer | transient network / repo cache | re-run the installer (it uses `--force-update`) | — |
| CD job only dry-runs | `DEPLOY_RUNNER` var / `KUBE_CONFIG` secret not set | check GitHub repo settings | set them (and Environment reviewers) to enable real rollout |
| MSSQL secondary not `SYNCHRONIZED` | seeding/endpoint cert issue | `verify-0.7`; query `sys.dm_hadr_*` | see `runbook-0.7.md` (re-create mirroring endpoints / re-seed) |
| Backup `PartiallyFailed` | a pre-hook failed (hooks are `onError: Continue`) | `velero backup describe <name> -n backup --details`; `velero backup logs <name> -n backup` | fix the hook target (e.g. install `sp_Maint_Backup_AllDatabases`); re-run backup |

**General triage flow:** `kubectl get events -A --sort-by=.lastTimestamp | tail` → identify the
namespace → `kubectl -n <ns> describe pod <pod>` → container logs (`-c <container>` incl. injected
`linkerd-proxy` / `vault-agent`) → `kubectl -n <ns> get netpol` → the matching `verify-0.X.sh`.

---

*Maintained alongside the per-step runbooks in `platform/docs/`. Update this file whenever a new
service/namespace, Helm chart, Vault path, NetworkPolicy, or backup target is added.*
