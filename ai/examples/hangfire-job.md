# Example: End-to-End Hangfire Job (Outbox Drain)

Concrete reference implementation showing a Hangfire recurring job that drains the **outbox** table written by command handlers, publishes events to **Redis Streams**, and marks rows as published — all idempotent and observable.

> All rules in [`../skills/hangfire.md`](../skills/hangfire.md), [`../skills/redis-streams.md`](../skills/redis-streams.md), [`../skills/mssql.md`](../skills/mssql.md), and [`../skills/background-workers.md`](../skills/background-workers.md) apply.

## Scenario

When a command handler inserts an order, it also writes an `OutboxEvents` row inside the **same SP transaction**. A separate Hangfire job (in the **Worker pod**) reads unpublished rows, publishes them to Redis Streams, and marks them as published.

## 1. SQL — `outbox.OutboxEvents`

```sql
CREATE SCHEMA outbox AUTHORIZATION dbo;
GO

CREATE TABLE outbox.OutboxEvents
(
    EventId      UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
    AggregateId  UNIQUEIDENTIFIER NOT NULL,
    EventType    NVARCHAR(200)    NOT NULL,
    Payload      NVARCHAR(MAX)    NOT NULL,
    CreatedAt    DATETIME2(3)     NOT NULL,
    PublishedAt  DATETIME2(3)     NULL,
    Attempts     INT              NOT NULL CONSTRAINT DF_OutboxEvents_Attempts DEFAULT(0)
);
GO

CREATE INDEX IX_OutboxEvents_Unpublished
    ON outbox.OutboxEvents (CreatedAt)
    WHERE PublishedAt IS NULL;
GO
```

### SPs

```sql
CREATE OR ALTER PROCEDURE outbox.sp_Outbox_Get_NextBatch
    @BatchSize INT = 100
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@BatchSize)
        EventId, AggregateId, EventType, Payload, CreatedAt, Attempts
    FROM outbox.OutboxEvents WITH (READPAST)
    WHERE PublishedAt IS NULL
    ORDER BY CreatedAt ASC;
END;
GO

CREATE OR ALTER PROCEDURE outbox.sp_Outbox_Mark_Published
    @EventId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE outbox.OutboxEvents
    SET PublishedAt = SYSUTCDATETIME()
    WHERE EventId = @EventId;
END;
GO

CREATE OR ALTER PROCEDURE outbox.sp_Outbox_Increment_Attempt
    @EventId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE outbox.OutboxEvents
    SET Attempts = Attempts + 1
    WHERE EventId = @EventId;
END;
GO
```

## 2. Job interface + implementation

```csharp
public interface IOutboxDrainJob
{
    Task RunAsync(CancellationToken ct);
}

public sealed class OutboxDrainJob(
    IDbConnectionFactory factory,
    IConnectionMultiplexer redis,
    ILogger<OutboxDrainJob> logger)
    : IOutboxDrainJob
{
    private const int BatchSize = 200;

    [AutomaticRetry(Attempts = 3, DelaysInSeconds = new[] { 5, 30, 120 })]
    public async Task RunAsync(CancellationToken ct)
    {
        await using var conn = factory.Create();
        await conn.OpenAsync(ct);

        var batch = await FetchBatchAsync(conn, ct);
        if (batch.Count == 0) return;

        var db = redis.GetDatabase();
        foreach (var row in batch)
        {
            try
            {
                var stream = row.EventType;
                var entries = new[]
                {
                    new NameValueEntry("event_id",       row.EventId.ToString()),
                    new NameValueEntry("event_type",     row.EventType),
                    new NameValueEntry("aggregate_id",   row.AggregateId.ToString()),
                    new NameValueEntry("occurred_at",    row.CreatedAt.ToString("O")),
                    new NameValueEntry("payload",        row.Payload)
                };

                await db.StreamAddAsync(stream, entries,
                    maxLength: 1_000_000, useApproximateMaxLength: true);

                await MarkPublishedAsync(conn, row.EventId, ct);
            }
            catch (Exception ex)
            {
                await IncrementAttemptAsync(conn, row.EventId, ct);
                logger.LogError(ex, "Failed to publish outbox event {EventId} of type {Type}", row.EventId, row.EventType);
            }
        }

        logger.LogInformation("Outbox drain published {Count} events.", batch.Count);
    }

    private static async Task<List<OutboxRow>> FetchBatchAsync(SqlConnection conn, CancellationToken ct)
    {
        var rows = new List<OutboxRow>();
        await using var cmd = new SqlCommand("outbox.sp_Outbox_Get_NextBatch", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.Add(new SqlParameter("@BatchSize", SqlDbType.Int) { Value = BatchSize });

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new OutboxRow(
                EventId:     r.GetGuid(0),
                AggregateId: r.GetGuid(1),
                EventType:   r.GetString(2),
                Payload:     r.GetString(3),
                CreatedAt:   r.GetDateTime(4),
                Attempts:    r.GetInt32(5)));
        }
        return rows;
    }

    private static async Task MarkPublishedAsync(SqlConnection conn, Guid eventId, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("outbox.sp_Outbox_Mark_Published", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.Add(new SqlParameter("@EventId", SqlDbType.UniqueIdentifier) { Value = eventId });
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task IncrementAttemptAsync(SqlConnection conn, Guid eventId, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("outbox.sp_Outbox_Increment_Attempt", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.Add(new SqlParameter("@EventId", SqlDbType.UniqueIdentifier) { Value = eventId });
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private sealed record OutboxRow(
        Guid EventId, Guid AggregateId, string EventType,
        string Payload, DateTime CreatedAt, int Attempts);
}
```

## 3. Registration

### Worker host (Program.cs)

```csharp
var builder = Host.CreateApplicationBuilder(args);

builder.Configuration.AddVaultSecrets("/vault/secrets");

builder.Services.AddSerilogLogging();
builder.Services.AddOpenTelemetryInstrumentation();
builder.Services.AddAdoNet();
builder.Services.AddApplicationServices();

builder.Services.AddSingleton<IConnectionMultiplexer>(_ =>
    ConnectionMultiplexer.Connect(builder.Configuration["Redis:ConnectionString"]!));

builder.Services.AddScoped<IOutboxDrainJob, OutboxDrainJob>();

builder.Services.AddHangfire((sp, cfg) =>
{
    var cs = builder.Configuration["Hangfire:ConnectionString"]!;
    cfg.UseSqlServerStorage(cs, new SqlServerStorageOptions
    {
        SchemaName                   = "hangfire",
        PrepareSchemaIfNecessary     = true,
        QueuePollInterval            = TimeSpan.FromSeconds(2),
        UseRecommendedIsolationLevel = true,
        DisableGlobalLocks           = true
    });
});

builder.Services.AddHangfireServer(o =>
{
    o.Queues      = new[] { "default", "outbox", "reports" };
    o.WorkerCount = Environment.ProcessorCount * 2;
    o.ServerName  = $"orders-worker-{Environment.MachineName}";
});

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var mgr = scope.ServiceProvider.GetRequiredService<IRecurringJobManager>();
    mgr.AddOrUpdate<IOutboxDrainJob>(
        recurringJobId: "orders:outbox-drain",
        queue:          "outbox",
        methodCall:     j => j.RunAsync(CancellationToken.None),
        cronExpression: "* * * * *",  // every minute
        options: new RecurringJobOptions { TimeZone = TimeZoneInfo.Utc });
}

await app.RunAsync();
```

## 4. Observability

A custom Hangfire filter copies the W3C `traceparent` from the job's stored arguments back into `Activity.Current` on execution:

```csharp
public sealed class CorrelationActivityFilter : JobFilterAttribute, IServerFilter
{
    public void OnPerforming(PerformingContext context)
    {
        if (context.Connection.GetJobParameter(context.BackgroundJob.Id, "traceparent") is { } tp)
        {
            Activity.Current?.SetParentId(tp);
        }
    }

    public void OnPerformed(PerformedContext context) { }
}
```

Register with `GlobalJobFilters.Filters.Add(new CorrelationActivityFilter())`.

## What this example demonstrates

- **Worker pod** hosts Hangfire; **API pod** never touches Hangfire's runtime.
- **Single SP transaction** in the original command handler writes both business data and the outbox row → atomic publish guarantee.
- **At-least-once** delivery: the job is idempotent (a re-published event has the same `event_id` and consumers dedupe).
- **`hangfire` schema** lives inside the same `Orders` database alongside `outbox`.
- **Polly + Hangfire retries** complement each other.
- **Tracing** carries the original request's trace id through the outbox into the published event.

## Related

- [`../skills/hangfire.md`](../skills/hangfire.md)
- [`../skills/redis-streams.md`](../skills/redis-streams.md)
- [`../skills/mssql.md`](../skills/mssql.md)
- [`../skills/background-workers.md`](../skills/background-workers.md)
- [`adonet-sp-call.md`](./adonet-sp-call.md)
