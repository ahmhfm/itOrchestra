# Skill: Hangfire (Background Jobs)

## Purpose
Run scheduled, recurring, delayed, and continuation jobs in a durable, observable, and replayable way.

## Architecture Role
Hangfire jobs run in **Worker Service pods** (`Microsoft.Extensions.Hosting`-based hosts), not inside Web API pods. Each microservice owns its Hangfire jobs and stores them in **its own MSSQL database** under the dedicated `[hangfire]` schema — the only allowed non-application schema in a service database.

## Rules

1. Hangfire jobs run in **Worker Service pods only** — never in Web API pods.
2. Storage is **MSSQL** using `Hangfire.SqlServer`, schema `hangfire`, inside the **same database** as the owning service.
3. Each microservice has its **own Hangfire server**, queues, and dashboard. **No shared Hangfire cluster across services.**
4. **Idempotency** is mandatory — every job must be safe to retry.
5. **CancellationToken** flows into every job method (Hangfire injects `IJobCancellationToken`).
6. **Correlation Id** persisted as a job parameter and re-applied to log scope on execution.
7. **Dashboard** secured by Keycloak JWT (or admin policy) — never anonymous.
8. **No business logic in `Program.cs`** — jobs are methods on registered services resolved via DI.

## Best Practices

- Recurring jobs registered at startup via `RecurringJob.AddOrUpdate(...)` with stable ids (`<aggregate>:<job>`).
- Delayed/Continuation jobs scheduled from command handlers using `IBackgroundJobClient`.
- Map slow jobs to dedicated queues (`reports`, `imports`, `notifications`) to isolate latency.
- Configure retry policy explicitly (`[AutomaticRetry]`).
- Use Hangfire filters for cross-cutting concerns (logging, tracing, correlation).
- Keep job methods small; delegate to application services.

## Anti-Patterns

| Don't | Do |
|---|---|
| Run Hangfire inside the Web API pod | Worker Service pods only |
| Share one Hangfire DB across services | One Hangfire schema per service DB |
| Put SQL inside a job method | Call a SP via ADO.NET |
| Throw exceptions for expected errors | Use `Result<T>` and log; retry only transient |
| Schedule jobs without a stable job id | Always use `RecurringJob.AddOrUpdate(id, ...)` |
| Expose dashboard publicly | Behind YARP + Keycloak auth |
| Skip idempotency checks | Always idempotent |
| Long-running jobs with no checkpoint | Persist progress; resume on retry |

## Security Requirements

- Dashboard guarded by `IDashboardAuthorizationFilter` validating Keycloak JWT or role.
- Dashboard reachable only behind YARP with `/admin/hangfire/*` route — not exposed publicly without auth.
- Job arguments must not contain secrets or PII; use references (ids) and load the data inside the job.
- Hangfire MSSQL login uses **least-privilege** on the `hangfire` schema only.

## Performance Guidelines

- Default worker count: `Environment.ProcessorCount * 2`; tune per service.
- Use separate queues for long jobs to prevent blocking short jobs.
- Hangfire `JobExpirationTimeout` ~ 7 days for visibility; archive older history.
- Avoid mega-arguments (Hangfire serializes arguments to MSSQL JSON).
- Monitor queue depth and processing time via OpenTelemetry custom metrics.

## Example Implementations

### Worker Service host (Program.cs)

```csharp
var builder = Host.CreateApplicationBuilder(args);

builder.Services.Configure<HangfireOptions>(builder.Configuration.GetSection("Hangfire"));
builder.Services.AddSerilogLogging();
builder.Services.AddAdoNet();
builder.Services.AddApplicationServices();
builder.Services.AddOpenTelemetryInstrumentation();

builder.Services.AddHangfire((sp, cfg) =>
{
    var options = sp.GetRequiredService<IOptions<HangfireOptions>>().Value;
    cfg.UseSqlServerStorage(options.ConnectionString, new SqlServerStorageOptions
    {
        SchemaName                          = "hangfire",
        PrepareSchemaIfNecessary            = true,
        QueuePollInterval                   = TimeSpan.FromSeconds(5),
        SlidingInvisibilityTimeout          = TimeSpan.FromMinutes(5),
        UseRecommendedIsolationLevel        = true,
        DisableGlobalLocks                  = true
    });
    cfg.UseSerilogLogProvider();
});

builder.Services.AddHangfireServer(o =>
{
    o.Queues       = new[] { "default", "notifications", "reports" };
    o.WorkerCount  = Environment.ProcessorCount * 2;
    o.ServerName   = $"orders-worker-{Environment.MachineName}";
});

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var registrar = scope.ServiceProvider.GetRequiredService<RecurringJobsRegistrar>();
    registrar.RegisterAll();
}

await app.RunAsync();
```

### Recurring jobs registration

```csharp
public sealed class RecurringJobsRegistrar(IRecurringJobManager mgr)
{
    public void RegisterAll()
    {
        mgr.AddOrUpdate<IDailyReportJob>(
            recurringJobId: "orders:daily-report",
            methodCall:     j => j.RunAsync(CancellationToken.None),
            cronExpression: "0 2 * * *",
            options:        new RecurringJobOptions { TimeZone = TimeZoneInfo.Utc });

        mgr.AddOrUpdate<IOutboxDrainJob>(
            "orders:outbox-drain",
            j => j.RunAsync(CancellationToken.None),
            Cron.Minutely,
            new RecurringJobOptions { TimeZone = TimeZoneInfo.Utc });
    }
}
```

### A job

```csharp
public interface IDailyReportJob { Task RunAsync(CancellationToken ct); }

public sealed class DailyReportJob(
    IDbConnectionFactory factory,
    ILogger<DailyReportJob> logger)
    : IDailyReportJob
{
    [AutomaticRetry(Attempts = 3, DelaysInSeconds = new[] { 30, 120, 300 })]
    public async Task RunAsync(CancellationToken ct)
    {
        await using var conn = factory.Create();
        await conn.OpenAsync(ct);

        await using var cmd = new SqlCommand("sp_Orders_Generate_DailyReport", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 300
        };
        cmd.Parameters.Add(new SqlParameter("@RunDate", SqlDbType.Date) { Value = DateTime.UtcNow.Date });
        await cmd.ExecuteNonQueryAsync(ct);

        logger.LogInformation("Daily report job completed at {Timestamp}", DateTime.UtcNow);
    }
}
```

### Dashboard auth

```csharp
public sealed class HangfireKeycloakAuthFilter : IDashboardAuthorizationFilter
{
    public bool Authorize(DashboardContext context)
    {
        var http = context.GetHttpContext();
        return http.User.Identity?.IsAuthenticated == true
               && http.User.IsInRole("hangfire-admin");
    }
}

// In Program.cs (Worker or a small admin Web app):
app.UseHangfireDashboard("/admin/hangfire", new DashboardOptions
{
    Authorization = new[] { new HangfireKeycloakAuthFilter() },
    IsReadOnlyFunc = ctx => !ctx.GetHttpContext().User.IsInRole("hangfire-operator")
});
```

## Integration Rules

- **DI:** services used by jobs registered as `Scoped`; Hangfire creates a scope per job invocation.
- **Outbox:** the outbox-drain job reads the `outbox` table (written inside the SP transaction) and publishes events to Redis Streams.
- **Observability:** a Hangfire filter sets `Activity.Current` from the job's stored `traceparent` parameter so OpenTelemetry spans connect job execution to the originating request.
- **Polly:** transient retries inside the job (DB, gRPC); Hangfire's `[AutomaticRetry]` covers process-level failures.
- **Cancellation:** prefer `IJobCancellationToken` and pass its `.ShutdownToken` to async methods.

## Checklist

- [ ] Hangfire hosted in a Worker Service pod (not in API).
- [ ] Schema `hangfire` configured inside the service's own DB.
- [ ] Recurring jobs registered with stable ids.
- [ ] `[AutomaticRetry]` configured deliberately.
- [ ] Job methods idempotent.
- [ ] CancellationToken honored.
- [ ] Correlation Id flows through.
- [ ] Dashboard secured.
- [ ] No business logic in `Program.cs`.
- [ ] Queue separation for long-running jobs.
- [ ] OpenTelemetry traces from jobs visible.

## Related

- [`background-workers.md`](./background-workers.md)
- [`mssql.md`](./mssql.md)
- [`redis-streams.md`](./redis-streams.md)
- [`opentelemetry.md`](./opentelemetry.md)
- [`../examples/hangfire-job.md`](../examples/hangfire-job.md)
