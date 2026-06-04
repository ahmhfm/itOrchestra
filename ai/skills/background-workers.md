# Skill: Background Workers (Worker Service Hosts)

## Purpose
Define how long-running, non-HTTP processes are hosted. Worker Service pods are the home for: Hangfire servers, Redis Streams consumers, outbox drains, scheduled re-syncs, AI inference workers, and any `IHostedService`.

## Architecture Role
A `Microsoft.Extensions.Hosting.IHost`-based application that runs in a dedicated Kubernetes Deployment, separate from Web API pods. It can scale, restart, and observe independently from the request-handling layer.

## Rules

1. **Each microservice has at least one Worker pod** for background work, regardless of whether it has a Web API.
2. **No HTTP traffic** accepted by a Worker pod by default. Health/metrics endpoints exposed via a minimal HTTP listener if needed.
3. **Graceful shutdown:** every long-running operation honors `CancellationToken` from `IHostApplicationLifetime`.
4. **DI lifetimes** identical to Web API conventions (Singleton/Scoped/Transient).
5. **Connection strings & secrets** loaded from Vault at startup (same as Web API).
6. **Observability** identical to Web API: OpenTelemetry traces + metrics + logs.
7. **No business state stored in the pod** — everything in MSSQL, Redis, or external services. Workers must be horizontally scalable.
8. **Failures** are logged and surfaced via metrics; **never silently swallowed**.

## Best Practices

- Use `Host.CreateApplicationBuilder(args)` (.NET 10 generic host).
- One `IHostedService` per responsibility (Hangfire server, stream consumer, periodic re-sync, etc.).
- Use **named queues / topics** to allow scaling consumers independently.
- For stream consumers, use a single `BackgroundService` per stream group; spin up multiple replicas to distribute pending entries via Redis consumer-group semantics.
- For periodic work that does **not** need Hangfire durability (every 30 seconds, in-memory only), use `PeriodicTimer` inside a `BackgroundService`.

## Anti-Patterns

| Don't | Do |
|---|---|
| Block the host thread with synchronous work | Use `Task.Run`/`await` and `CancellationToken` |
| Catch `OperationCanceledException` and log it as error | Treat it as a normal shutdown signal |
| Mix HTTP serving and background jobs in the same pod | Two pods: API + Worker |
| Store in-process state | Externalize to MSSQL / Redis |
| Run forever without health probes | Expose `/health/live` + `/health/ready` |
| Single-replica Worker that owns critical state | At least 2 replicas + leader election if needed |
| Forget DI scope per work unit | Create a scope per message/job |

## Security Requirements

- Worker pods have a **dedicated Kubernetes ServiceAccount** with its own Vault role.
- Same JWT validation rules apply when a Worker calls a sibling service (service-account token from Keycloak).
- Network policies restrict Worker outbound to declared destinations only (Redis, MSSQL, sibling gRPC, OTLP collector, Vault, Keycloak).
- Linkerd injection enabled.

## Performance Guidelines

- Tune replica count to consumer group throughput needs.
- Use **per-message scope** to avoid memory build-up.
- Avoid blocking `Task.Result`; use `await`.
- Set HPA on consumer-group lag (custom metric) when possible — Hangfire/Redis-Streams need adapter metrics.

## Example Implementations

### Program.cs (Worker host)

```csharp
var builder = Host.CreateApplicationBuilder(args);

builder.Configuration
    .AddVaultSecrets(builder.Configuration["Vault:Address"]!,
                     builder.Configuration["Vault:Role"]!);

builder.Services.AddSerilogLogging();
builder.Services.AddOpenTelemetryInstrumentation();
builder.Services.AddAdoNet();
builder.Services.AddApplicationServices();
builder.Services.AddGrpcClients();

// Hangfire server
builder.Services.AddHangfireFromConfig(builder.Configuration);

// Redis Streams consumers
builder.Services.AddSingleton<IConnectionMultiplexer>(_ =>
    ConnectionMultiplexer.Connect(builder.Configuration["Redis:ConnectionString"]!));
builder.Services.AddHostedService<OrderCreatedConsumer>();
builder.Services.AddHostedService<OutboxDrainBackgroundService>();

// Health on a minimal Kestrel listener
builder.Services.AddHealthChecks();

await using var app = builder.Build();
await app.RunAsync();
```

### Periodic worker (in-memory schedule)

```csharp
public sealed class CacheRefreshWorker(
    ICacheService cache,
    IDbConnectionFactory factory,
    ILogger<CacheRefreshWorker> logger)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(2));
        while (await timer.WaitForNextTickAsync(ct))
        {
            try
            {
                await using var conn = factory.Create();
                await conn.OpenAsync(ct);
                await using var cmd = new SqlCommand("sp_Orders_Get_HotOrderIds", conn)
                { CommandType = CommandType.StoredProcedure };

                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                {
                    var id = r.GetGuid(0);
                    await cache.RemoveAsync($"orders:order:{id}:summary", ct);
                }
            }
            catch (OperationCanceledException) { /* graceful shutdown */ }
            catch (Exception ex)
            {
                logger.LogError(ex, "Cache refresh tick failed");
            }
        }
    }
}
```

### Health server (minimal Kestrel)

```csharp
// In Program.cs, after services are built, mount minimal HTTP
var app = WebApplication.CreateBuilder().Build();
app.MapHealthChecks("/health/live", new HealthCheckOptions
{
    Predicate = _ => false           // only checks self
});
app.MapHealthChecks("/health/ready", new HealthCheckOptions
{
    Predicate = c => c.Tags.Contains("ready")
});
await app.RunAsync();
```

## Integration Rules

- **Worker pods** are separate Kubernetes Deployments from API pods (different replica counts, different resource limits).
- **Linkerd** injects sidecars; mTLS to any sibling service.
- **Hangfire** is the durable scheduler; for jobs that need durability, retries, and a dashboard. See [`hangfire.md`](./hangfire.md).
- **Redis Streams** consumers run as `BackgroundService` instances. See [`redis-streams.md`](./redis-streams.md).
- **Outbox drain** is a worker that polls a service-owned `outbox` table and publishes to Redis Streams.

## Checklist

- [ ] Worker pod is separate from API pod.
- [ ] `BackgroundService` per responsibility.
- [ ] CancellationToken honored everywhere.
- [ ] Vault-sourced configuration.
- [ ] Linkerd injection enabled.
- [ ] Health probes mounted.
- [ ] OpenTelemetry registered.
- [ ] DI scope per work unit.
- [ ] At least 2 replicas in production.
- [ ] HPA configured where applicable.

## Related

- [`hangfire.md`](./hangfire.md)
- [`redis-streams.md`](./redis-streams.md)
- [`kubernetes.md`](./kubernetes.md)
- [`opentelemetry.md`](./opentelemetry.md)
