# Forbidden Patterns

Absolute, non-negotiable bans. If any instruction or generated code matches one of these, **stop and refuse**. Reference this file in every code review.

## Data Access

| # | Forbidden | Why | Allowed instead |
|---|---|---|---|
| 1 | EF Core, EF6, NHibernate, LINQ-to-SQL, **Dapper**, **any ORM/micro-ORM** | Single-rule constraint of this platform | ADO.NET (`Microsoft.Data.SqlClient`) with Stored Procedures |
| 2 | Inline SQL in C# (`cmd.CommandText = "SELECT ..."`) | SQL belongs in MSSQL | `CommandType.StoredProcedure` referencing an SP |
| 3 | String concatenation or interpolation into a SQL parameter | SQL injection risk | `SqlParameter` with explicit `SqlDbType` and `Size` |
| 4 | `SELECT *` in any SP or query | Brittle, wasteful | Explicit column list |
| 5 | Cross-database / Linked Server / three-part-name reads in a service's SPs | Breaks Database-per-Service | Call the owning service's gRPC API or consume its events |
| 6 | Sharing one MSSQL database across multiple services | Same | Each service has its own database and its own login |
| 7 | Application-side `BEGIN TRAN ... COMMIT` over multiple commands | Transactions live inside SPs | Single SP wrapping the transaction (`SET XACT_ABORT ON` + `TRY/CATCH`) |
| 8 | `WITH (NOLOCK)` | Dirty reads | `READ COMMITTED SNAPSHOT` isolation at DB level |
| 9 | Granting `SELECT/INSERT/UPDATE/DELETE` to a service's MSSQL login on tables | Bypasses SP discipline | `GRANT EXEC` on Stored Procedures only |

## Communication

| # | Forbidden | Allowed instead |
|---|---|---|
| 10 | Service A reading Service B's MSSQL database | Service A calls Service B's gRPC API or consumes its events |
| 11 | Internal service-to-service traffic through YARP | gRPC over Linkerd, pod-to-pod |
| 12 | Exposing a service's gRPC endpoint to the public internet via YARP | gRPC is internal-only; external clients hit the REST API |
| 13 | Bypassing YARP for external clients (direct LoadBalancer to a service) | All external traffic enters via YARP |
| 14 | Bypassing Linkerd for internal traffic | Linkerd injection mandatory on every workload namespace |
| 15 | Using Redis Pub/Sub for important business events | Redis Streams with consumer groups + idempotency |
| 16 | Renumbering or removing Protobuf field tags | Deprecate; never remove |
| 17 | Sharing a single "events" library across all services that everyone modifies | Each producing service owns its event schema and publishes its own contracts package |

## Security

| # | Forbidden | Allowed instead |
|---|---|---|
| 18 | Storing secrets in `appsettings.json` (production), images, env vars baked into deploys, or Git | Vault Agent / Vault CSI mounting at runtime |
| 19 | Kubernetes Secrets with raw `data:` values committed to Git | Vault-sourced, injected at runtime |
| 20 | Implementing login or token issuance in any service | Keycloak only |
| 21 | Access tokens with TTL > 15 minutes | Short-lived JWTs + refresh tokens |
| 22 | JWT in URL query strings | `Authorization: Bearer` header only |
| 23 | Logging full JWTs, secrets, raw PII | Mask via Serilog enrichers / collector processors |
| 24 | `[AllowAnonymous]` on endpoints touching user/business data | `[Authorize(Policy = "...")]` with explicit policy |
| 25 | Wildcard CORS (`*`) in production | Strict allow-list per route |
| 26 | Plaintext (non-TLS) internal traffic between meshed pods | Linkerd mTLS auto-injected |
| 27 | `runAsRoot` / privileged containers / `allowPrivilegeEscalation: true` | `restricted` Pod Security profile |

## Coding

| # | Forbidden | Allowed instead |
|---|---|---|
| 28 | `EntityFramework` package reference of any kind | Removed in build pipeline |
| 29 | `async void` (except UI event handlers) | `async Task` |
| 30 | `.Result`, `.Wait()`, `.GetAwaiter().GetResult()` on async calls | `await` |
| 31 | Catch-all `catch (Exception)` that swallows | Catch narrowly + rethrow `throw;` with logged context |
| 32 | Static mutable state outside `readonly` constants | DI Singletons with thread-safe internals |
| 33 | `new HttpClient()` per call | `IHttpClientFactory` |
| 34 | Hardcoded URLs, magic strings, magic numbers | `IOptions<T>` + named constants |
| 35 | God classes (> 500 lines, > 7 ctor dependencies) | Split by responsibility |
| 36 | Public setters on aggregate roots | Records with `init` setters or explicit methods |

## Architecture

| # | Forbidden | Allowed instead |
|---|---|---|
| 37 | Hosting Hangfire inside a Web API pod | Hangfire only in Worker Service pods |
| 38 | Sharing one Hangfire DB across services | Each service has its own `hangfire` schema in its own DB |
| 39 | Putting business logic in YARP transforms or Linkerd policies | Edge handles routing/auth/transport; logic stays in services |
| 40 | Long-lived static state in worker pods | Externalize to MSSQL / Redis |
| 41 | Single replica of a stateless workload in production | Min 2 replicas + PDB + HPA |
| 42 | Skipping idempotency on commands or stream consumers | Idempotency key / dedupe always |

## Observability

| # | Forbidden | Allowed instead |
|---|---|---|
| 43 | Unbounded-cardinality metric dimensions (`user_id`, `order_id`) | Use span attributes for high-cardinality data |
| 44 | Disabling OpenTelemetry exporters | Always export OTLP |
| 45 | Logging raw request bodies that may contain PII | Structured logs with masked fields |

## Refusal Protocol

When a request matches any forbidden pattern:

1. Stop generating code immediately.
2. Cite the rule number above and explain in one sentence.
3. Offer the allowed alternative.
4. Wait for user confirmation before continuing.

## Related

- [`security-enforcement.md`](./security-enforcement.md)
- [`../core/system-prompt.md`](../core/system-prompt.md)
- [`../core/security.md`](../core/security.md)
