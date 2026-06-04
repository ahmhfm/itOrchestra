# Deployment Checklist

Run through this checklist before promoting a service to **staging** and again before **production**. Block the deploy on any unchecked item.

## Service code

- [ ] All unit tests pass locally and in CI.
- [ ] Integration tests pass with Testcontainers MSSQL + Redis.
- [ ] No `EntityFramework*`, `Dapper`, or other ORM package references.
- [ ] No inline SQL anywhere; every `SqlCommand` uses `CommandType.StoredProcedure`.
- [ ] Every endpoint has `[Authorize(Policy = "...")]` (or documented `[AllowAnonymous]`).
- [ ] Idempotency key parameter present on `Create`/`Update` commands.
- [ ] Polly policies attached to outbound HTTP/gRPC/MSSQL.
- [ ] OpenTelemetry instrumentation registered.
- [ ] `CancellationToken` flows through async chains.
- [ ] Logging redacts secrets, tokens, PII.

## Database

- [ ] Migration scripts checked in under `db/`.
- [ ] Migrations run as a Kubernetes Job before the API rolls.
- [ ] New SPs reviewed for plans; cover indexes added if needed.
- [ ] `SET NOCOUNT ON` and `SET XACT_ABORT ON` on every transactional SP.
- [ ] Triggers, if added, write only to immutable `audit.*` tables.
- [ ] MSSQL login `<service>_app` has only `GRANT EXEC` on procedures.
- [ ] Row-Level Security policies applied for tenant-scoped tables.
- [ ] Outbox schema (`outbox.OutboxEvents`) and drain SP present.

## Contracts

- [ ] REST OpenAPI document generated and reviewed.
- [ ] gRPC `.proto` lint passed; `buf breaking` against main passed.
- [ ] Contract NuGet packages versioned (semver) and published.
- [ ] Consumers updated to the new contract version (if breaking — must be deferred via deprecation).

## Container

- [ ] Dockerfile uses a pinned base image (`mcr.microsoft.com/dotnet/aspnet:10.0-azurelinux3.0`).
- [ ] Container runs as non-root.
- [ ] Image scanned with Trivy (no `High`/`Critical`).
- [ ] Image signed with Cosign.
- [ ] Image pushed with immutable tag (semver + git SHA).
- [ ] SBOM uploaded.

## Kubernetes manifests / Helm

- [ ] Namespace annotated `linkerd.io/inject: enabled`.
- [ ] Three Deployments (api, grpc, worker) — or two if api+grpc merged — defined.
- [ ] Each container has resource `requests` and `limits`.
- [ ] Each container has `livenessProbe`, `readinessProbe`, and where needed `startupProbe`.
- [ ] `securityContext`: `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`.
- [ ] ServiceAccount per Deployment (dedicated identity).
- [ ] HPA configured (min ≥ 2, sensible max, target CPU 60%).
- [ ] PodDisruptionBudget defined for `minAvailable`.
- [ ] NetworkPolicy default-deny + explicit allow.
- [ ] Linkerd `Server` and `ServerAuthorization` per service.
- [ ] `topologySpreadConstraints` to spread replicas across nodes.

## Configuration & Secrets

- [ ] Vault role created and bound to the workload's ServiceAccount.
- [ ] Vault Agent annotations on the Pod for each required secret.
- [ ] No secret values in Git or in the Helm chart.
- [ ] `IOptionsMonitor<T>` wired to reload on Vault file change.
- [ ] Non-secret config in `appsettings.json` / ConfigMap; overlays per env.

## Identity

- [ ] Keycloak client registered for this service.
- [ ] Roles defined (`<service>.read`, `<service>.write`, etc.).
- [ ] Required groups have been assigned the roles in staging.
- [ ] Service-to-service client credentials issued for outbound calls.

## Gateway & Mesh

- [ ] YARP route added for `/api/v{n}/<service>/*` (external traffic only).
- [ ] YARP rate-limit policy assigned per route.
- [ ] No internal-to-internal call routed through YARP.
- [ ] Linkerd policy allows the expected client ServiceAccounts.

## Observability

- [ ] OTLP endpoint configured.
- [ ] Service emits a baseline of metrics (`http.server.request.duration`, `rpc.server.duration`, `db.client.operation.duration`).
- [ ] Custom metrics for business KPIs registered under the service's `Meter` name.
- [ ] Grafana dashboard checked in for this service.
- [ ] Alerts checked in (error rate, latency p95, outbox lag, queue depth).
- [ ] Log queries documented in the runbook.

## Background workers

- [ ] Hangfire runs in the Worker pod, not the API pod.
- [ ] Hangfire schema (`hangfire`) inside the service's own DB.
- [ ] Recurring jobs registered with stable ids.
- [ ] Stream consumers (BackgroundService) registered.
- [ ] Outbox drain job scheduled.
- [ ] Dashboard secured by Keycloak role.

## Argo CD / GitOps

- [ ] Argo CD Application resource committed.
- [ ] Auto-sync, prune, self-heal enabled (per environment policy).
- [ ] Sync waves correct (DB migration job → API → Worker).

## Pre-production validation

- [ ] Smoke tests pass against `/health/ready`.
- [ ] E2E test pack passes in staging.
- [ ] Dashboard signals green for 1 hour.
- [ ] On-call runbook published with: known errors, dashboard links, common SP names, escalation contacts.

## Production cut-over

- [ ] Pre-deploy comms posted to the team channel.
- [ ] Rollout window agreed.
- [ ] Rollback plan reviewed (Argo CD revert + DB forward-only note).
- [ ] Post-deploy verification scheduled.

## Related

- [`security-checklist.md`](./security-checklist.md)
- [`../workflows/deployment-workflow.md`](../workflows/deployment-workflow.md)
- [`../workflows/new-microservice-workflow.md`](../workflows/new-microservice-workflow.md)
- [`../skills/kubernetes.md`](../skills/kubernetes.md)
