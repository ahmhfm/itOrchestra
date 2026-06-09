# itOrchestra Platform - Phase 0 (Shared Infrastructure)

This folder contains the Infrastructure-as-Code for the itOrchestra shared platform
("المرحلة 0 : تأسيس البنية التحتية المشتركة / Phase 0: Platform Foundation").

It is built incrementally, one step at a time, following the project plan
(`itOrchestra plan/Software Engineering/Final Plan/Project Plan AR|EN .docx`).

## Current status

| Step | Component | Status |
|------|-----------|--------|
| 0.1 | Kubernetes cluster (K3s / RKE2) + CNI + Storage + Ingress + LB + Namespaces + NetworkPolicies | Done (dev) |
| 0.2 | Linkerd service mesh (+ Linkerd CNI plugin chained on Cilium for `restricted` namespaces) | Done (dev) - `linkerd check` √, verify-0.2 6/6 |
| 0.3 | YARP API Gateway (TLS, routing, rate limit, CORS, correlation-id; JWT deferred to 0.4) | Done (dev) - verify-0.3 5/5, LoadBalancer 10.178.95.241 |
| 0.4 | Keycloak (IAM) + private MSSQL, behind YARP; realm `itorchestra-dev` imported | Done (dev) - verify-0.4 7/7 |
| 0.5 | HashiCorp Vault (Raft + Longhorn) + Agent Injector; KV v2 + Kubernetes auth; 0.4 secrets seeded | Done (dev) - verify-0.5 8/8 |
| 0.6 | Redis (Cache + Streams) - single-node StatefulSet, AOF on Longhorn, AUTH, out of mesh; password mirrored to Vault | Done (dev) - verify-0.6 8/8 |
| 0.7 | SQL Server Always On AG - reference 2-replica clusterless (read-scale) AG, cert-auth endpoints, auto-seeding; SA mirrored to Vault | Done (dev) - verify-0.7 8/8 |
| 0.8 | Observability - OpenTelemetry Collector + Tempo + Prometheus + Grafana + AlertManager + OpenSearch; Grafana via YARP; creds mirrored to Vault | Done (dev) - verify-0.8 13/13 |
| 0.9 | AI layer - Qdrant 3-node cluster (5 RAG collections) + Ollama (CPU) serving chat `qwen2.5:1.5b` + embeddings `bge-m3` (no GPU on this VM; vLLM/GPU is the prod path); internal-only, NetworkPolicy-fenced; Qdrant metrics to Prometheus; endpoints/key mirrored to Vault | Done (dev) - verify-0.9 11/11 |
| 0.10 | CrewAI multi-agent orchestration - Python gRPC service (`itorchestra.crewai.v1`), 7 agents (Orchestrator/Security/Performance/Patch/PowerShell/Policy/Compliance) with roles/tasks/tools, Ollama LLM + Qdrant RAG backends, per-agent permissions matrix (auto vs. approval), full audit trail in `CrewAiDb` (0.7 AG, stored-procedures only), meshed + internal-only | Done (dev) - verify-0.10 12/12 |
| 0.11 | CI/CD pipeline (GitHub Actions) - reusable workflows + a supply-chain composite action: restore/format/strict-build/test (Testcontainers) + `dotnet list --vulnerable`/Snyk/Dependabot/Trivy + buf lint/breaking + multi-stage Docker build + push to GHCR + Cosign keyless signing + Syft SBOM + Helm lint/template + env-gated deploy (dev/staging/prod); wired to gateway (.NET) + crewai (Python) | Done (dev) - verify-0.11; both pipelines green end-to-end on `main` (build+test -> image: Trivy/SBOM/GHCR/Cosign -> deploy dev/staging/prod). Hardened: format (`dotnet format`/`ruff`) + `buf breaking` are strict gates; GitHub Environments `dev`/`staging`/`prod` configured with required reviewers on staging/prod (approval gate exercised); CD wired for real rollout via `DEPLOY_RUNNER` var + `KUBE_CONFIG` secret (safe scaffold until set) |
| 0.12 | Backup & DR - Velero (cluster resources + PV data via kopia File System Backup) targeting an in-cluster MinIO S3 endpoint whose bytes live on the VM host disk (`hostPath`, survives Longhorn/cluster loss); app-consistent backup hooks (MSSQL `COPY_ONLY` backup via a stored procedure, Redis `SAVE`); daily Schedule + 7-day retention; endpoint mirrored to Vault; DR runbook (namespace/DB/Vault restore + full rebuild) | Done (dev) - verify-0.12 |
| ... | ... | ... |

## Two deployment profiles

Every component ships with two profiles so the same repo serves local development and production:

- **dev** - a single-node K3s cluster running on a dedicated **Ubuntu VM** (provision it via
  [`docs/runbook-vm-setup.md`](docs/runbook-vm-setup.md)). Replica counts are reduced to 1,
  storage replicas are 1, and MetalLB uses the VM's LAN subnet.
- **prod** - a multi-node **K3s** (or RKE2) cluster on real Linux servers
  (HA control plane + worker nodes), production-sized replicas and storage.

## Step 0.1 - Kubernetes cluster

Stack (confirmed): **K3s** + **Cilium** (CNI) + **Longhorn** (storage) + **ingress-nginx** + **MetalLB** (internal LoadBalancer).

K3s is installed with its bundled components disabled so we control them explicitly:

- `--flannel-backend=none` + `--disable-network-policy` -> Cilium provides CNI + NetworkPolicy.
- `--disable=traefik` -> ingress-nginx provides Ingress.
- `--disable=servicelb` -> MetalLB provides `LoadBalancer` services.

### Layout

```
platform/
  k8s/
    cluster/
      k3s/             K3s install scripts + config (dev/prod)
      cilium/          Cilium CNI install + values
      metallb/         MetalLB install + L2 IP pools (dev/prod)
      ingress-nginx/   ingress-nginx install + values
      longhorn/        open-iscsi prereqs + Longhorn install + StorageClass
    namespaces/        Platform + per-service namespaces (PSA + Linkerd labels)
    network-policies/  Default-deny + allow-DNS NetworkPolicies
  bootstrap/
    00-bootstrap-dev.sh   End-to-end dev installer (runs everything in order)
  docs/
    runbook-0.1.md        Install / verify / teardown runbook
```

### Quick start (dev, on the Ubuntu VM)

```bash
# On the Ubuntu VM (see docs/runbook-vm-setup.md), with the repo cloned at ~/itOrchestra:
cd ~/itOrchestra/platform
bash bootstrap/00-bootstrap-dev.sh
```

See [`docs/runbook-0.1.md`](docs/runbook-0.1.md) for step-by-step manual instructions,
verification commands, and teardown.

## Step 0.2 - Service mesh (Linkerd)

Stack: **Linkerd** (edge channel, free OSS) for automatic **mTLS**, retries/timeouts, load
balancing, and golden metrics on all meshed pod-to-pod traffic. Dev installs via the Linkerd
CLI with auto-generated certs; prod uses Helm + a Vault-managed trust anchor with cert-manager.

```bash
cd ~/itOrchestra/platform
# only if files were copied from Windows: dos2unix bootstrap/*.sh k8s/cluster/linkerd/*.sh
bash bootstrap/01-mesh-dev.sh            # INSTALL_VIZ=false to skip the dashboard
```

Layout: `k8s/cluster/linkerd/` (install scripts: dev CLI, viz, prod Helm),
`bootstrap/01-mesh-dev.sh`, `bootstrap/verify-0.2.sh`.

> Two follow-ups before meshing real workloads in the `restricted` `ns-*` namespaces:
> (1) install the **Linkerd CNI plugin** (chained with Cilium) so injected pods satisfy the
> `restricted` PodSecurity profile; (2) add `allow-linkerd` NetworkPolicies so meshed pods can
> reach the control plane under default-deny. See [`docs/runbook-0.2.md`](docs/runbook-0.2.md).

## Step 0.5 - Secrets (HashiCorp Vault)

Stack: **HashiCorp Vault** (chart `0.32.0` / Vault `1.21.2`) with **integrated Raft storage**
on a Longhorn PVC (persistent), the **Vault Agent Injector** (`vault-k8s 1.7.2`), **KV v2**
and the **Kubernetes auth** method. Vault is reached only in-cluster (ClusterIP); it is never
exposed publicly and never routed through YARP. The UI/CLI is opened via `kubectl port-forward`.

```bash
cd ~/itOrchestra/platform
bash bootstrap/04-vault-dev.sh
```

The installer initializes + unseals Vault (1 key share - **dev only**, stored in
`vault/vault-unseal-keys`), enables KV v2 at `secret/`, enables Kubernetes auth, seeds the
Phase 0.4 secrets (`secret/itorchestra/{keycloak/admin,keycloak/db,gateway/keycloak}`), and
creates a sample least-privilege policy + role (`itorchestra-gateway` -> SA `default` in
`ns-gateway`). Workloads consume secrets at runtime via Agent Injector annotations (files
under `/vault/secrets/`); see [`ai/skills/vault.md`](../ai/skills/vault.md).

> **dev vs prod:** dev runs a single-node Raft with `tls_disable`, a single Shamir key, and a
> persisted root token for convenience, and keeps Vault **out of the mesh** (a Linkerd sidecar
> on the Injector's admission webhook breaks API-server TLS calls). Prod runs an HA Raft
> cluster with real TLS, KMS auto-unseal, split Shamir keys, no persisted root token, and
> meshes Vault with `opaque-ports`/`skip-inbound-ports`.

Layout: `k8s/vault/` (`values.yaml`, `install-dev.sh`), `bootstrap/04-vault-dev.sh`,
`bootstrap/verify-0.5.sh`, [`docs/runbook-0.5.md`](docs/runbook-0.5.md).

## Step 0.6 - Cache + Streams (Redis)

Stack: a single-node **Redis 8** (`redis:8.8.0`) StatefulSet with **AOF persistence** on a
Longhorn PVC (durability for Streams), **AUTH** required, and `volatile-lru` eviction (only
TTL'd cache keys are evicted; Streams are preserved). Redis is shared infra and stays **out of
the Linkerd mesh** (per `redis.md` + the architecture rules); it is internal only (headless
ClusterIP, no LoadBalancer, no YARP). The password lives in the `redis-auth` Secret and is
mirrored into **Vault KV** at `secret/itorchestra/shared/redis` for workloads to consume.

```bash
cd ~/itOrchestra/platform
bash bootstrap/05-redis-dev.sh
```

Redis is **the first read source** for configuration + hot data (Cache-Aside; MSSQL is the
source of truth) and hosts **Streams** for events/Sagas. Apps use `StackExchange.Redis`
(singleton multiplexer) and reach `redis.redis.svc.cluster.local:6379`. See
[`ai/skills/redis.md`](../ai/skills/redis.md).

> **dev vs prod:** dev is a single node with AUTH only and `protected-mode`. Prod runs HA
> (Sentinel or Cluster), **TLS** at transport, per-service **ACL users** (least privilege),
> and rotates the password from Vault without a restart.

Layout: `k8s/redis/` (`configmap.yaml`, `service.yaml`, `statefulset.yaml`, `install-dev.sh`),
`bootstrap/05-redis-dev.sh`, `bootstrap/verify-0.6.sh`,
[`docs/runbook-0.6.md`](docs/runbook-0.6.md).

## Step 0.7 - High-availability database (SQL Server Always On AG)

Stack: a **reference** SQL Server 2022 **Always On Availability Group** - two replicas
(`mssql-ag-0` initial primary, `mssql-ag-1` secondary) forming a **clusterless / read-scale**
AG (`CLUSTER_TYPE = NONE`) with certificate-authenticated mirroring endpoints (port 5022),
**automatic seeding**, and **manual** failover. A demo database (`platformref`) is added to the
AG to prove replication. Out of the Linkerd mesh (DB traffic is secured by TLS at transport);
internal only. The SA password + connection strings are mirrored into **Vault KV**
(`secret/itorchestra/shared/mssql-ag`).

```bash
cd ~/itOrchestra/platform
bash bootstrap/06-mssql-ag-dev.sh
```

This is the **reusable HA pattern** (Database-per-Service): each microservice instantiates its
own AG-backed MSSQL instance with its own private database, own login (EXEC-on-SPs only), and
Vault-sourced connection string. Entry points: `mssql-ag-primary` (read-write) and
`mssql-ag-secondary` (read-only / `ApplicationIntent=ReadOnly`). See
[`ai/skills/mssql.md`](../ai/skills/mssql.md).

> **dev vs prod / limits:** dev runs two replicas on a single node with **manual** failover
> (clusterless AGs have no automatic listener/failover). Each replica needs >= 2 GiB RAM.
> Prod uses 3+ replicas across nodes, an automatic-failover mechanism (DH2i DxEnterprise or
> Pacemaker), real TLS, per-service logins, and a true listener/VIP. After a manual failover
> in dev, repoint the `mssql-ag-primary` Service selector to the new primary pod.

Layout: `k8s/mssql-ag/` (`mssql-conf-configmap.yaml`, `service.yaml`, `statefulset.yaml`,
`install-dev.sh`), `bootstrap/06-mssql-ag-dev.sh`, `bootstrap/verify-0.7.sh`,
[`docs/runbook-0.7.md`](docs/runbook-0.7.md).

## Step 0.8 - Observability (OpenTelemetry + Tempo + Prometheus + Grafana + OpenSearch)

Stack: the central monitoring system. The **OpenTelemetry Collector** (contrib) is the single
OTLP ingest point; it fans telemetry out to **Tempo** (traces), **Prometheus** (metrics), and
**OpenSearch** (logs), all visualized in **Grafana** with **AlertManager** for SLO alerts.
Prometheus also scrapes the **Linkerd** data-plane proxies (golden metrics) and the cluster
(node-exporter + kube-state-metrics). Everything lives in the `observability` namespace, **out
of the Linkerd mesh** in dev (consistent with the other data stores). Grafana is the only piece
exposed to operators, and only **through YARP** at `/grafana`.

```bash
cd ~/itOrchestra/platform
bash bootstrap/07-observability-dev.sh
```

The installer deploys OpenSearch (single-node, security plugin disabled in dev), Tempo and the
kube-prometheus-stack via Helm, applies sample **SLO** alert rules, deploys the Collector
(tail sampling keeps all error/slow traces; sensitive headers are scrubbed before export),
opens gateway egress to Grafana, **rebuilds the gateway image** with the `/grafana` route, and
mirrors the Grafana admin creds + stack endpoints into **Vault KV**
(`secret/itorchestra/shared/observability`). Services emit telemetry to
`otel-collector.observability.svc.cluster.local:4317` (gRPC) / `:4318` (HTTP); the
`X-Correlation-Id` / `traceparent` flow is wired at YARP and propagated through gRPC + Streams +
Hangfire. See [`ai/skills/opentelemetry.md`](../ai/skills/opentelemetry.md).

> **dev vs prod:** dev runs single replicas with short retention on Longhorn PVCs, OpenSearch
> with its **security plugin disabled** (plaintext, internal only), and Grafana's own admin
> login. Prod meshes the namespace for **mTLS on the OTLP path**, enables the OpenSearch
> security plugin with **TLS + Keycloak** roles, fronts Grafana with **Keycloak OIDC**, pins
> chart versions, scales retention/storage, and wires AlertManager receivers (email/Slack/PagerDuty).
> The bundled `linkerd-viz` Prometheus (0.2) is now superseded by this central Prometheus.

Layout: `k8s/observability/` (`opensearch/`, `tempo/values.yaml`,
`prometheus/{values.yaml,slo-alerts.yaml}`, `otel-collector/values.yaml`, `gateway-egress.yaml`,
`install-dev.sh`), `bootstrap/07-observability-dev.sh`, `bootstrap/verify-0.8.sh`,
[`docs/runbook-0.8.md`](docs/runbook-0.8.md).

## Step 0.9 - AI layer (Qdrant + vLLM + Ollama)

A **fully internal** AI platform: nothing is exposed outside the cluster, and inference data
never leaves the environment. **Qdrant** runs as a 3-node cluster (the RAG vector store) with
five collections - `knowledge_base`, `past_incidents`, `policies`, `scripts`, `device_profiles`
(bge-m3 = 1024 dims, Cosine, 2 shards, replication_factor 2). This dev VM has **no GPU**, so
**Ollama** serves **both** the chat LLM (`qwen2.5:1.5b`) and the **bge-m3** embedding model on
CPU. (**vLLM** on an NVIDIA GPU node is the production chat path; its manifests ship under
`vllm/` + `gpu/` but are **not deployed in dev**.) Everything lives in the `ai` namespace, out of
the Linkerd mesh, fenced by **NetworkPolicies** (only the microservice namespaces + Prometheus
may reach it); Qdrant is protected by an **API key**.

```bash
cd ~/itOrchestra/platform
bash bootstrap/08-ai-dev.sh
```

The installer deploys Qdrant via Helm, runs an idempotent Job to create the five collections,
deploys Ollama and pulls `bge-m3` + `qwen2.5:1.5b` (a one-time provisioning fetch), applies the
**Models Catalog**, **ResourceQuota / LimitRange**, and **NetworkPolicies**, and mirrors
endpoints + the Qdrant key into **Vault KV** (`secret/itorchestra/shared/ai`). Qdrant's own
ServiceMonitor (Helm) feeds `/metrics` to the Phase 0.8 Prometheus.

> **dev vs prod:** dev runs the 3 Qdrant peers on one node (replication is nominal) and the chat
> LLM on **CPU via Ollama** (slow but functional), plaintext in-cluster, with one-time HTTPS
> egress to pull model weights. Prod spreads Qdrant across real nodes, pulls weights from an
> **internal mirror** (no internet egress), serves larger models (Llama 3 / Qwen 2.5 / Mixtral)
> on **vLLM/GPU** nodes, meshes the namespace for mTLS, enforces per-caller rate limiting at the
> consuming services (Polly) / an internal AI BFF, and pins all image/chart versions. Integration
> follows the project's "HTTP + Polly resilience" rule.

Layout: `k8s/ai/` (`qdrant/{values.yaml,collections-init.yaml}`,
`ollama/{deployment.yaml,service.yaml}`, `models-catalog.yaml`, `resourcequota.yaml`,
`networkpolicy.yaml`, `install-dev.sh`; plus the prod/GPU path `vllm/{deployment,service}.yaml` +
`gpu/nvidia-device-plugin.yaml`), `bootstrap/08-ai-dev.sh`, `bootstrap/verify-0.9.sh`,
[`docs/runbook-0.9.md`](docs/runbook-0.9.md).

## Step 0.10 - CrewAI multi-agent orchestration

The first real **application service**: a **Python gRPC** service (CrewAI is Python-only) that
orchestrates seven agents - **Orchestrator, Security, Performance, Patch, PowerShell, Policy,
Compliance** - each with a role, goal, tools and a slice of a **permissions matrix**. The
Orchestrator routes a task to the right specialist; the agent grounds its reasoning via **Qdrant
RAG** and the local **Ollama** LLM (0.9), then the matrix decides the outcome: **AUTO** actions
are advisory (read-only), **APPROVAL** actions are parked as `PENDING_APPROVAL` until an explicit
`ApproveAction`, and **DENY** actions are rejected. Action tools are **safe stubs** in dev (the
owning services - assets/discovery/etc. - don't exist yet), so nothing real is ever changed.

Every decision is written to a **full audit trail** in a per-service database **`CrewAiDb`** on
the 0.7 AG, accessed **exclusively through stored procedures** (the `crewai_app` login is granted
`EXEC` only - no table access - enforcing the SP-only rule even from Python). The service is
**meshed** (Linkerd mTLS) and **internal-only** (ClusterIP, NetworkPolicy-fenced, no YARP route);
other itOrchestra services consume it over gRPC (`itorchestra.crewai.v1`).

```bash
cd ~/itOrchestra/platform
bash bootstrap/09-crewai-dev.sh
```

The installer builds + imports the image, provisions `CrewAiDb` (+ login + stored procedures) on
the AG primary, writes config/secrets (Ollama/Qdrant endpoints, Qdrant key, DB creds), deploys
the meshed Deployment/Service/NetworkPolicies, and mirrors the gRPC endpoint into **Vault KV**
(`secret/itorchestra/shared/crewai`). Verification exercises the full flow in-pod (Health,
ListAgents=7, approval-gated SubmitTask -> ApproveAction -> EXECUTED, audit read-back, RAG Query).

> **dev vs prod:** dev defers **JWT** (internal + NetworkPolicy only) and runs CrewAI on the **CPU**
> LLM (slow first call); `CrewAiDb` shares the 0.7 AG **instance** with a dedicated database +
> least-privilege login. Prod validates **Keycloak JWT** on every gRPC call, propagates the
> correlation-id end to end, gives CrewAI its **own** private DB instance, points the LLM backend
> at **vLLM/GPU**, replaces the action stubs with **gRPC calls to the owning services**, and pins
> the image. Resilience follows the "Polly on top of Linkerd" rule.

Layout: `crewai/` (the Python service: `app/{config,db,permissions,agents,tools,crew,service,
main}.py`, `proto/crewai.proto`, `requirements.txt`, `Dockerfile`, `build-and-import-dev.sh`),
`k8s/crewai/` (`db/{01-database-and-login,02-schema}.sql`, `deployment.yaml`, `service.yaml`,
`networkpolicy.yaml`, `scripts/grpc_smoke.py`, `install-dev.sh`), `bootstrap/09-crewai-dev.sh`,
`bootstrap/verify-0.10.sh`, [`docs/runbook-0.10.md`](docs/runbook-0.10.md).

## Step 0.11 - CI/CD pipeline (GitHub Actions)

The **standard build/test/secure/sign/deploy pipeline** every service uses, as **reusable GitHub
Actions workflows** plus one **composite action** for the container supply chain. Each service
adopts it with a ~40-line caller workflow; the two services that exist today - the .NET
**gateway** (0.3) and the Python **crewai** (0.10) - are already wired in.

On a **pull request**: `dotnet restore` -> `dotnet format --verify-no-changes` -> strict build
(Roslyn analyzers + warnings-as-errors via `Directory.Build.props`, SDK pinned by `global.json`)
-> tests (auto-discovered `*Tests.csproj`, **Testcontainers**-ready) -> `dotnet list package
--vulnerable` (+ optional **Snyk**) -> multi-stage **Docker build** -> **Trivy** image scan ->
**Syft SBOM**; for crewai also **`buf lint` + `buf breaking`** on the `.proto` contract. On **push
to `main` / tag `v*`**: the image is pushed to **GHCR**, **Cosign**-signed (keyless, GitHub OIDC)
with the **SBOM attested**, then deployed via the generic `itorchestra-service` **Helm** chart
through **dev -> staging -> prod**, with `staging`/`prod` gated by **GitHub Environment** required
reviewers. **Dependabot** opens weekly dependency/security PRs across Actions, NuGet, pip, Docker.

```bash
cd ~/itOrchestra/platform
bash bootstrap/10-cicd.sh        # validate the assets + print the one-time GitHub setup checklist
```

There is nothing to install into Kubernetes here - the pipeline lives in GitHub Actions. CD
defaults to `helm lint` + `helm template` + server dry-run (safe scaffold); set a `KUBE_CONFIG`
secret and `apply: true` (ideally on a self-hosted runner) for a real rollout.

> **dev vs prod:** dev keeps CD as lint/template/dry-run, makes Snyk + reviewers optional, and
> pushes to a private GHCR. Prod requires reviewers on staging/prod, enforces Snyk + signature
> verification at admission, may mirror images into an internal Harbor, and deploys for real via
> a self-hosted runner with cluster access.

Layout: `.github/workflows/` (`ci-dotnet.yml`, `ci-python.yml`, `ci-proto.yml`, `cd-helm.yml`,
`gateway.yml`, `crewai.yml`), `.github/actions/image-supply-chain/`, `.github/dependabot.yml`,
`buf.yaml`, `Directory.Build.props`, `.editorconfig`, `platform/charts/itorchestra-service/`,
`platform/deploy/<service>/values-<env>.yaml`, `bootstrap/10-cicd.sh`, `bootstrap/verify-0.11.sh`,
[`docs/runbook-0.11.md`](docs/runbook-0.11.md).

## Step 0.12 - Backup & Disaster Recovery (Velero + MinIO)

Stack: **Velero** backs up Kubernetes resources + persistent-volume data (kopia **File System
Backup**) to an in-cluster **MinIO** S3 endpoint whose bytes live on the **VM host disk**
(`hostPath`) - so a backup survives loss of Longhorn or the entire cluster (you never store the
backups on the storage you are backing up). Application consistency is handled by Velero **backup
hooks** that run each engine's own snapshot command just before the volume is copied: **MSSQL**
runs a `COPY_ONLY` backup via a **stored procedure** (`sp_Maint_Backup_AllDatabases` - the SQL
stays inside the database, per the platform rules) and **Redis** runs `SAVE`. A `daily-full`
Schedule keeps 7 days of backups; the endpoint is mirrored into **Vault KV**
(`secret/itorchestra/shared/backup`).

```bash
cd ~/itOrchestra/platform
bash bootstrap/11-backup-dev.sh
```

The DR procedures (restore a namespace, MSSQL DB restore, Vault raft snapshot/restore, and a full
cluster rebuild from the surviving `hostPath` bucket) are in
[`docs/runbook-0.12.md`](docs/runbook-0.12.md).

> **dev vs prod:** dev runs a single MinIO on `hostPath` with one daily schedule and 7-day
> retention. Prod uses **off-cluster** object storage (a dedicated MinIO/S3 box or NFS appliance),
> more frequent schedules + longer retention, encrypted backups, per-namespace restore RBAC,
> periodic **restore drills**, and a scheduled `vault operator raft snapshot` + MSSQL log backups
> for true point-in-time recovery.

Layout: `k8s/backup/` (`namespace.yaml`, `minio/{pv-pvc,deployment,service}.yaml`,
`velero/{values,schedules}.yaml`, `mssql/sp_maint_backup.sql`, `install-dev.sh`),
`bootstrap/11-backup-dev.sh`, `bootstrap/verify-0.12.sh`,
[`docs/runbook-0.12.md`](docs/runbook-0.12.md).

## Conventions (from the project rules)

- One namespace per microservice; namespaces are labelled `name=<ns>` for NetworkPolicy
  selectors and annotated `linkerd.io/inject: enabled` (mesh installed in 0.2).
- Application namespaces enforce the Pod Security `restricted` profile.
- NetworkPolicies are **default-deny** (ingress + egress); only DNS is allowed by default,
  everything else must be explicitly opened per service.
- No secrets in Git - secrets come from Vault (step 0.5). The `.gitignore` blocks kubeconfig.
- Each workload runs under its **own dedicated ServiceAccount** (e.g. `gateway`, `crewai`), never
  the namespace `default` SA. The SAs carry **no** Role/RoleBinding (the services do not call the
  Kubernetes API, so they hold zero cluster RBAC = least privilege); they exist to give each
  workload a distinct identity for **Vault Kubernetes-auth**, auditing, and policy scoping. The
  Vault k8s-auth roles (`gateway`, `crewai`) bind exactly these SAs.
- **Runtime secrets come from Vault via the Agent Injector**, not just k8s Secrets. `crewai` carries
  `vault.hashicorp.com/agent-*` annotations: the agent logs in with the pod's dedicated SA and
  renders `/vault/secrets/app.env` (DB password + Qdrant key) **before** the app starts; the app
  (`config.py`) loads that file and only falls back to the k8s `crewai-secrets` env when it is
  absent (the CD/Helm path or Vault unavailable). The generic chart exposes `podAnnotations` so any
  service can opt in the same way. The gateway's only runtime secret is its TLS `.pfx` password
  (the cert file itself is a k8s Secret), so its Vault-runtime wiring is deferred until it gains a
  Vault-resident secret (JWT/OIDC client secret in a later phase); the `gateway` Vault role/policy
  already exist for that.
