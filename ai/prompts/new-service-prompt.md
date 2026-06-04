# Reusable Prompt: Generate a New Microservice

Use this prompt verbatim when asking the AI to scaffold a new microservice. Replace placeholders in `{{ }}`.

---

You are a Senior .NET 10 Architect operating inside the itOrchestra repository. Before writing any code, **load** the following files in order:

1. [`ai/core/system-prompt.md`](../core/system-prompt.md)
2. [`ai/constraints/forbidden-patterns.md`](../constraints/forbidden-patterns.md)
3. [`ai/patterns/microservice-template.md`](../patterns/microservice-template.md)
4. [`ai/skills/mssql.md`](../skills/mssql.md)
5. [`ai/skills/webapi.md`](../skills/webapi.md)
6. [`ai/skills/grpc.md`](../skills/grpc.md)
7. [`ai/skills/cqrs.md`](../skills/cqrs.md)
8. [`ai/skills/hangfire.md`](../skills/hangfire.md)
9. [`ai/skills/redis-streams.md`](../skills/redis-streams.md)
10. [`ai/workflows/new-microservice-workflow.md`](../workflows/new-microservice-workflow.md)

## Inputs

- **Bounded context name:** `{{ ContextName }}` (PascalCase, singular, e.g., `Inventory`).
- **Purpose (one line):** `{{ Purpose }}`.
- **Aggregates owned exclusively by this service:** `{{ AggregateList }}`.
- **External REST endpoints to expose** (resource + verbs): `{{ RestEndpointList }}`.
- **gRPC operations to expose** (method name + request/response shape): `{{ GrpcOperationList }}`.
- **Events produced** (`<aggregate>.<event>.v1` + payload): `{{ EventsProducedList }}`.
- **Events consumed** (stream name + source service): `{{ EventsConsumedList }}`.
- **Sibling services to call** (service + grpc methods): `{{ SiblingCallList }}`.
- **Background jobs needed** (name + schedule): `{{ BackgroundJobsList }}`.

## Requirements

1. Produce the **solution skeleton** matching [`ai/patterns/microservice-template.md`](../patterns/microservice-template.md), including `.csproj` files with the right references.
2. Produce **all SQL** as separate `.sql` files under `db/`:
   - Tables for each aggregate.
   - `dbo.*Tvp` user-defined table types for batch writes.
   - Stored Procedures named `sp_{{ContextName}}_<Action>_<Entity>`.
   - `outbox.OutboxEvents` schema + SPs.
   - `audit.*` schema + triggers for sensitive tables.
   - Row-Level Security policies if multi-tenant.
3. Produce **C# code** following:
   - ADO.NET only — no ORM, no Dapper, no inline SQL.
   - CQRS with MediatR.
   - Thin controllers / gRPC services dispatching to handlers.
   - Polly resilience on all outbound calls (HTTP, gRPC, MSSQL).
   - Vault-injected configuration via `IOptionsMonitor`.
   - OpenTelemetry instrumentation.
4. Produce **deployment manifests** under `deploy/helm/itorchestra-{{contextname-kebab}}/`:
   - Namespace with `linkerd.io/inject: enabled`.
   - Three Deployments (api, grpc, worker) — separate pods.
   - Services (`<svc>-api`, `<svc>-grpc`); no Service for worker.
   - HPA + PDB + ServiceAccount per Deployment.
   - NetworkPolicy default-deny + explicit allow.
   - Linkerd `Server` + `ServerAuthorization`.
   - Argo CD `Application` manifest under `gitops/`.
5. Produce **tests**:
   - Unit tests for each handler.
   - Integration tests with Testcontainers for MSSQL + Redis.
   - One Reqnroll feature per business flow.

## Constraints

- Never inline SQL.
- Never use Entity Framework, Dapper, or any ORM.
- Never expose gRPC externally through YARP.
- Never read another service's database.
- Every endpoint requires `[Authorize(Policy = "...")]`; explain the policy name in the README.
- Every command needs an idempotency key.
- Every consumer needs to dedupe by `event_id`.

## Output format

Produce one tool call per file. For SQL, use `.sql` extension. For Helm, place YAML under `deploy/helm/itorchestra-{{contextname-kebab}}/templates/`. Wrap final output in a short summary listing:

- All files created.
- Roles registered in Keycloak.
- Vault paths required.
- YARP route to add.
- Linkerd policies added.
- Argo CD application path.

## Confirmation

Before writing code, summarize the design you will produce and confirm with me. If any input above is ambiguous, ask a clarifying question first — do not assume.

---

## Related

- [`code-review-prompt.md`](./code-review-prompt.md)
- [`../workflows/new-microservice-workflow.md`](../workflows/new-microservice-workflow.md)
- [`../patterns/microservice-template.md`](../patterns/microservice-template.md)
