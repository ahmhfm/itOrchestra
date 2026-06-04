# Pattern: Microservice Template

Canonical layout and boilerplate for a new microservice. Use this whenever a brand-new service is added to the platform.

## Solution layout

```
src/
  itOrchestra.Orders.Api/                    # ASP.NET 10 Core Web API (external REST)
    Controllers/
    Program.cs
    appsettings.json
    Dockerfile
  itOrchestra.Orders.Grpc/                   # ASP.NET 10 Core gRPC (internal RPC)
    Services/                            # gRPC service implementations
    Program.cs
    Dockerfile
  itOrchestra.Orders.Worker/                 # .NET 10 Worker Service
    HostedServices/                      # BackgroundService consumers
    Jobs/                                # Hangfire job classes
    Program.cs
    Dockerfile
  itOrchestra.Orders.Application/            # MediatR commands/queries + handlers
    Orders/
      CreateOrder/
      GetOrderById/
      ListOrders/
    Pipeline/                            # Validation / Logging / Tracing behaviors
  itOrchestra.Orders.Domain/                 # Pure domain types, results
  itOrchestra.Orders.Data/                   # ADO.NET repositories (call SPs)
    IDbConnectionFactory.cs
    OrdersRepository.cs
  itOrchestra.Orders.Contracts/              # Public types shared with consumers
    Rest/                                # REST request/response records
    Events/                              # Redis Streams event envelopes
  itOrchestra.Orders.Contracts.V1.Grpc/      # Generated gRPC stubs (.proto + Grpc.Tools)
    Protos/
      orders.proto
  itOrchestra.Orders.Infrastructure/         # Cross-cutting: telemetry, vault, polly
db/
  schema/                                # CREATE TABLE
  procedures/                            # sp_Orders_*.sql
  functions/                             # fn_*.sql
  views/                                 # vw_*.sql
  triggers/                              # tr_*.sql
  migrations/                            # DbUp / RoundhousE
deploy/
  helm/itorchestra-orders/
    Chart.yaml
    values.yaml
    templates/
tests/
  itOrchestra.Orders.UnitTests/
  itOrchestra.Orders.IntegrationTests/       # Testcontainers + Reqnroll
```

## Project responsibilities

| Project | Responsibility | Allowed dependencies |
|---|---|---|
| `Api` | REST controllers, DI wiring, middleware | Application, Contracts, Infrastructure |
| `Grpc` | gRPC service classes, DI wiring | Application, Contracts.V1.Grpc, Infrastructure |
| `Worker` | Hangfire host, BackgroundService consumers | Application, Contracts, Infrastructure |
| `Application` | MediatR commands/queries/handlers + pipeline behaviors | Domain, Data, Contracts |
| `Domain` | Records, value objects, `Result<T>` | (none — pure) |
| `Data` | ADO.NET repositories, SP invocations | Domain |
| `Contracts` | DTOs for REST + event envelopes (consumers reference) | Domain |
| `Contracts.V1.Grpc` | Generated Protobuf stubs (consumers reference) | (none) |
| `Infrastructure` | Logging, telemetry, Vault, Polly, Keycloak client | Microsoft.Extensions.* |

**Rule:** API/Grpc/Worker projects all share `Application` + `Domain` + `Data` + `Infrastructure`. They are three different hosts on the same logical service.

## Three deployments per service

| Pod | Purpose | Replicas (min) |
|---|---|---|
| `<service>-api` | HTTP REST surface (behind YARP) | 3 |
| `<service>-grpc` | gRPC surface (internal) | 3 |
| `<service>-worker` | Hangfire + stream consumers + outbox drain | 2 |

REST and gRPC can be merged into a single pod if traffic mix permits, but they remain **separate ports** (8080 HTTP, 8081 gRPC). Recommendation: **start merged**; split only when their scale needs diverge.

## Database

- One database per service: `Orders`, `Customers`, etc.
- One MSSQL login per service: `orders_app`.
- Permissions: `GRANT EXEC` on procedures only.
- Schema layout:
  - `dbo` — business tables, SPs.
  - `audit` — audit history (immutable).
  - `hangfire` — Hangfire tables.
  - `outbox` — outbox pattern.
- Migrations run as a Kubernetes Job before the API pod starts.

## Configuration (Vault-injected)

```
ConnectionStrings:
  Orders:   <from Vault database/creds/orders>
Redis:
  ConnectionString: <from Vault kv/data/orders/redis>
Keycloak:
  Authority: https://kc.itorchestra.com/realms/itorchestra-prod
  Audience:  orders-api
  ClientId:  orders-service
  ClientSecret: <from Vault kv/data/orders/keycloak>
Services:
  Customers:
    GrpcUrl: http://customers-grpc.itorchestra-customers.svc.cluster.local
Hangfire:
  ConnectionString: <same as Orders, separate schema>
OpenTelemetry:
  OtlpEndpoint: http://otel-collector.observability.svc.cluster.local:4317
```

## Standard `Program.cs` skeleton (API)

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Configuration.AddVaultSecrets("/vault/secrets");

builder.Services.AddSerilogLogging();
builder.Services.AddOpenTelemetryInstrumentation();
builder.Services.AddAdoNet();                 // IDbConnectionFactory + Polly
builder.Services.AddApplicationServices();    // MediatR + Application
builder.Services.AddGrpcClients();            // sibling service clients
builder.Services.AddKeycloakAuth(builder.Configuration);
builder.Services.AddAuthorization(o =>
{
    o.FallbackPolicy = new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build();
    o.AddPolicy("OrdersReader", p => p.RequireRole("orders.read"));
    o.AddPolicy("OrdersWriter", p => p.RequireRole("orders.write"));
});

builder.Services.AddControllers();
builder.Services.AddApiVersioning();
builder.Services.AddProblemDetails();
builder.Services.AddHealthChecks().AddSqlServer(/* connection string */);

var app = builder.Build();

app.UseMiddleware<CorrelationIdMiddleware>();
app.UseSerilogRequestLogging();
app.UseExceptionHandler();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.MapHealthChecks("/health/ready", new HealthCheckOptions { Predicate = c => c.Tags.Contains("ready") });
app.MapHealthChecks("/health/live",  new HealthCheckOptions { Predicate = _ => false });

app.Run();
```

## Standard `Program.cs` skeleton (Worker)

See [`../skills/background-workers.md`](../skills/background-workers.md) and [`../skills/hangfire.md`](../skills/hangfire.md).

## Required DI registrations

- `IDbConnectionFactory`
- `IMediator` + open behaviors (`Validation`, `Authorization`, `Tracing`, `Logging`)
- `IHttpClientFactory` (typed clients per outbound API)
- gRPC clients (typed) with Polly handlers
- `IConnectionMultiplexer` (Redis singleton)
- `IEventPublisher` (Redis Streams)
- `KeycloakTokenClient` for service-to-service flows
- `HangfireBackgroundJobClient` (only in Worker pod)

## Required Kubernetes artifacts (per service)

- `Namespace` annotated `linkerd.io/inject: enabled`
- `Deployment` × 3 (api, grpc, worker)
- `Service` × 2 (`<svc>-api` HTTP, `<svc>-grpc` gRPC) — Worker has none
- `HPA` × 3
- `PodDisruptionBudget` × 3
- `ServiceAccount` × 3 (each with its own Vault role)
- `NetworkPolicy` default-deny + explicit allow
- Linkerd `Server` + `ServerAuthorization`
- Argo CD `Application` pointing at the Helm chart

## Required tests

- **Unit:** xUnit + NSubstitute. One arrange-act-assert per test.
- **Integration:** Testcontainers (MSSQL + Redis) running the full SP migration and stream wiring.
- **Contract:** Reqnroll feature files per use case.
- **gRPC:** in-memory test server.

## Steps to scaffold

See [`../workflows/new-microservice-workflow.md`](../workflows/new-microservice-workflow.md).

## Related

- [`api-template.md`](./api-template.md)
- [`wpf-template.md`](./wpf-template.md)
- [`../workflows/new-microservice-workflow.md`](../workflows/new-microservice-workflow.md)
- [`../checklists/deployment-checklist.md`](../checklists/deployment-checklist.md)
