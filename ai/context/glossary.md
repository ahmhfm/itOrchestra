# Glossary

Project-specific terminology. When in doubt, refer here before using a term in code or documentation.

## A

- **ADO.NET** — The only sanctioned data-access API on .NET 10 in this platform, used through `Microsoft.Data.SqlClient`. See [`../skills/mssql.md`](../skills/mssql.md).
- **Aggregate** — Domain-Driven Design unit of consistency. Each aggregate is owned by exactly one microservice.
- **Anti-Forgery Token** — Server-issued token validated on state-changing requests, used by MVC.
- **API Gateway** — The single public ingress point. In this platform: **YARP**.
- **Argo CD** — GitOps controller that syncs Helm releases from Git to the cluster.

## B

- **BackgroundService** — Base class for `IHostedService` in .NET, used inside Worker pods for stream consumers and periodic workers.
- **Bounded Context** — DDD term; corresponds 1:1 to a microservice in this platform.
- **Bulkhead** — Polly policy that bounds concurrency to a dependency, isolating failures.

## C

- **Canary** — Deployment strategy that routes a small percentage of traffic to a new version before full roll-out.
- **Circuit Breaker** — Polly policy that opens after a threshold of failures, preventing cascading failures.
- **Cosign** — Tool used to sign container images cryptographically.
- **Correlation Id** — Per-request identifier (`X-Correlation-Id`) propagated through all logs, spans, and events.
- **CQRS** — Command/Query Responsibility Segregation. Implemented with MediatR.

## D

- **Database-per-Service** — Strict rule: each microservice has its own MSSQL database; no cross-service DB reads.
- **DLQ (Dead-Letter Queue)** — Redis Stream `<service>.deadletter.v1` where unprocessable events end up.
- **DPAPI** — Windows Data Protection API; used in WPF to encrypt tokens at rest.
- **DTO (Data Transfer Object)** — Public-facing shape of data. Never a domain entity.

## E

- **Event Envelope** — Versioned wrapper carrying `event_id`, `event_type`, `version`, `occurred_at`, `tenant_id`, `correlation_id`, and `payload`.
- **Eventually Consistent** — Most cross-service data flows are eventually consistent via Redis Streams.

## F

- **FluentValidation** — The validation library used in commands, queries, and DTOs.

## G

- **gRPC** — Internal service-to-service synchronous protocol. Never exposed externally. See [`../skills/grpc.md`](../skills/grpc.md).
- **GitOps** — Deployment model where Git is the source of truth; controllers reconcile cluster to Git.

## H

- **Hangfire** — Durable background-job framework. Hosted in Worker pods only. See [`../skills/hangfire.md`](../skills/hangfire.md).
- **HPA (Horizontal Pod Autoscaler)** — Kubernetes resource scaling replicas based on metrics.
- **HSTS** — HTTP Strict Transport Security header set by YARP.

## I

- **Idempotency Key** — Caller-supplied UUID (`Idempotency-Key` header / command field) that makes retries safe.
- **Indexed View** — Materialized view in MSSQL used for hot read aggregations.
- **`IOptionsMonitor<T>`** — .NET 10 abstraction for hot-reloading configuration; used to pick up Vault changes.

## J

- **JWT (JSON Web Token)** — Bearer tokens issued by Keycloak. Validated at YARP and at every service.

## K

- **K3s / RKE2** — Lightweight / production-grade Kubernetes distributions used as the runtime.
- **Keycloak** — The single identity provider for the platform.
- **Kyverno** — Policy controller used to enforce admission rules.

## L

- **Linkerd** — Service mesh; provides mTLS, retries, observability between meshed pods.

## M

- **MAUI** — .NET Multi-platform App UI for non-Windows clients (macOS, Linux, iOS, Android). See [`../skills/maui.md`](../skills/maui.md).
- **MediatR** — In-process message dispatcher used for CQRS.
- **mTLS** — Mutual TLS; automatic between Linkerd-meshed pods.
- **MSSQL** — Microsoft SQL Server. The only relational database. All SQL lives here.

## N

- **NetworkPolicy** — Kubernetes resource implementing namespace-scoped firewall rules.

## O

- **OIDC (OpenID Connect)** — Authentication protocol layered on OAuth 2.0. Used against Keycloak.
- **OpenTelemetry (OTel)** — The instrumentation standard. Exports OTLP to a collector. See [`../skills/opentelemetry.md`](../skills/opentelemetry.md).
- **OpenSearch** — Search and analytics store used for audit logs.
- **Outbox** — Pattern: events written to a DB table inside the same transaction as the business write; drained by a worker.

## P

- **PDB (PodDisruptionBudget)** — Kubernetes resource bounding voluntary disruptions.
- **PKCE** — OAuth 2.0 extension for public clients; mandatory for WPF/MAUI logins.
- **Polly** — The resilience library used for retries, circuit breakers, timeouts, bulkheads, hedging.
- **Protobuf** — Wire format for gRPC.

## Q

- **Qdrant** — Vector database used by the AI layer (RAG, semantic search).

## R

- **RBAC** — Role-based access control; roles defined in Keycloak; enforced at services.
- **Reqnroll** — BDD framework (SpecFlow successor) used for executable specifications.
- **Redis** — In-memory data store used for cache + Streams + light counters.
- **Redis Streams** — Async messaging primitive used for inter-service events.
- **Result\<T\>** — Functional result type encoding success/failure; used by application handlers.
- **Row-Level Security (RLS)** — MSSQL feature filtering rows based on session context. Used for multi-tenant isolation.

## S

- **Saga** — Long-running transaction implemented as a sequence of events and compensations.
- **Serilog** — Structured-logging library; outputs via OpenTelemetry OTLP.
- **Skill** — A modular rule file under `ai/skills/<topic>.md` loaded on demand based on the task.
- **SP / Stored Procedure** — The only allowed place for SQL.
- **System Prompt** — The always-loaded core file: [`../core/system-prompt.md`](../core/system-prompt.md).

## T

- **Tempo** — Distributed-tracing backend; receives spans from the OTel collector.
- **Tenant** — A logical customer or organization; isolated by `tenant_id` in tokens and SP parameters.
- **Testcontainers** — Library for running real dependencies (MSSQL, Redis) in integration tests.
- **Trivy** — Container/image vulnerability scanner.
- **TVP (Table-Valued Parameter)** — MSSQL parameter type for passing tables; used for batch operations.

## U

- **UDT (User-Defined Type)** — MSSQL type; backs TVPs.

## V

- **Vault** — HashiCorp Vault, the secrets store. See [`../skills/vault.md`](../skills/vault.md).
- **vLLM** — Optional alternative LLM inference engine alongside Ollama.

## W

- **WAF (Web Application Firewall)** — In front of YARP for OWASP-style protections.
- **WPF** — Windows Presentation Foundation. Windows desktop client framework. See [`../skills/wpf.md`](../skills/wpf.md).
- **Worker Service** — A .NET host without HTTP serving; runs Hangfire and stream consumers. See [`../skills/background-workers.md`](../skills/background-workers.md).

## X

- **XACT_ABORT** — MSSQL setting forced ON in every transactional SP.

## Y

- **YARP** — Yet Another Reverse Proxy. The platform's API Gateway. See [`../skills/yarp.md`](../skills/yarp.md).

## Z

- **Zero Trust Architecture (ZTA)** — Security model where every request is authenticated, authorized, encrypted, and logged.

## Related

- [`tech-stack.md`](./tech-stack.md)
- [`../core/architecture.md`](../core/architecture.md)
