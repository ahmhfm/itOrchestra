# Skill: Redis Streams (Asynchronous Inter-Service Messaging)

## Purpose
Define the asynchronous event-driven communication mechanism between microservices. Used for events, eventual consistency propagation, and Saga steps.

## Architecture Role
The async message bus. Producers (typically Worker Services or command handlers via Outbox) publish events; consumers (Worker Service Pods) read via consumer groups, process idempotently, and ack.

## Rules

1. **Redis Streams** is the only sanctioned async messaging mechanism for inter-service events.
2. Every event is **immutable** and **versioned**: stream name = `<aggregate>.<event>.v<n>` (e.g., `orders.order_created.v1`).
3. **Consumer Groups** per service: `<service>-<purpose>` (e.g., `inventory-reservations`).
4. **Idempotent consumption** is mandatory: every event has an `event_id` (UUID); consumers persist processed ids to deduplicate.
5. **Acknowledge (`XACK`)** only after successful processing.
6. **Dead-letter** stream for failed events after N retries: `<service>.deadletter.v1`.
7. **Outbox pattern** for events that must align with a DB write transaction.
8. **Schema** of every event documented in the producing service's contracts package.

## Best Practices

- Use `StackExchange.Redis` `IDatabase.StreamAdd/Read/Acknowledge/Claim`.
- Consumers read with `XREADGROUP` + `>` for new messages; pending entries handled with explicit ids.
- Run multiple consumer instances per group for horizontal scale; Redis distributes pending entries.
- Use `XPENDING` periodically to detect stuck consumers; reclaim with `XCLAIM` after idle threshold.
- Use a fixed-size `MAXLEN ~ N` retention or `MINID` time-based retention to bound memory.
- Compose larger events from smaller fields rather than huge JSON payloads.

## Anti-Patterns

| Don't | Do |
|---|---|
| Mutate the event after publishing | Events are immutable |
| Skip idempotency | Always dedupe by `event_id` |
| Auto-ack before processing | Ack after side-effects succeed |
| Use Pub/Sub for important events | Pub/Sub does not retain — use Streams |
| Catch and swallow errors silently | Move to DLQ; alert ops |
| Cross-service direct DB write in a consumer | Call the owning service's gRPC or update only your own DB |
| Build a "shared events" library used by everyone | Each producing service owns its events |

## Security Requirements

- Redis ACL user per consumer with scoped commands (`+@stream +@read -@dangerous`).
- TLS to Redis.
- Payloads must not contain unmasked PII; tokenize.
- Producer / consumer auth identity stamped in the event header.

## Performance Guidelines

- Batch reads with `count: 100`.
- Keep payload < 4 KB; for larger documents, store in object storage and reference by URL.
- Avoid hot streams without partitioning — use multiple streams for high-throughput aggregates.
- Monitor `XLEN` and consumer lag.

## Example Implementations

### Event envelope

```csharp
public sealed record EventEnvelope<T>(
    Guid    EventId,
    string  EventType,
    string  Version,
    DateTime OccurredAt,
    Guid    TenantId,
    string  CorrelationId,
    T       Payload);

public sealed record OrderCreated(
    Guid OrderId, Guid CustomerId, decimal Total);
```

### Publisher (Outbox-friendly)

```csharp
public interface IEventPublisher
{
    Task PublishAsync<T>(string stream, EventEnvelope<T> envelope, CancellationToken ct);
}

public sealed class RedisStreamPublisher(IConnectionMultiplexer mux) : IEventPublisher
{
    public Task PublishAsync<T>(string stream, EventEnvelope<T> envelope, CancellationToken ct)
    {
        var db = mux.GetDatabase();
        var entries = new[]
        {
            new NameValueEntry("event_id",       envelope.EventId.ToString()),
            new NameValueEntry("event_type",     envelope.EventType),
            new NameValueEntry("version",        envelope.Version),
            new NameValueEntry("occurred_at",    envelope.OccurredAt.ToString("O")),
            new NameValueEntry("tenant_id",      envelope.TenantId.ToString()),
            new NameValueEntry("correlation_id", envelope.CorrelationId),
            new NameValueEntry("payload",        JsonSerializer.Serialize(envelope.Payload))
        };
        return db.StreamAddAsync(stream, entries, maxLength: 1_000_000, useApproximateMaxLength: true);
    }
}
```

### Consumer (IHostedService)

```csharp
public sealed class OrderCreatedConsumer(
    IConnectionMultiplexer mux,
    IInventoryReservationService reservations,
    ILogger<OrderCreatedConsumer> logger)
    : BackgroundService
{
    private const string Stream  = "orders.order_created.v1";
    private const string Group   = "inventory-reservations";
    private readonly string _consumer = $"inventory-{Environment.MachineName}";

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var db = mux.GetDatabase();
        await EnsureGroupAsync(db);

        while (!ct.IsCancellationRequested)
        {
            var entries = await db.StreamReadGroupAsync(
                Stream, Group, _consumer, ">", count: 50);

            foreach (var entry in entries)
            {
                var eventId = Guid.Parse(entry["event_id"]!);
                try
                {
                    if (await reservations.AlreadyProcessedAsync(eventId, ct))
                    {
                        await db.StreamAcknowledgeAsync(Stream, Group, entry.Id);
                        continue;
                    }

                    var payload = JsonSerializer.Deserialize<OrderCreated>(entry["payload"]!)!;
                    await reservations.ReserveAsync(payload, eventId, ct);
                    await db.StreamAcknowledgeAsync(Stream, Group, entry.Id);
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Failed to process event {EventId}", eventId);
                    // Polly-retried within ReserveAsync; if it bubbles, leave unacked
                    // so XPENDING / XCLAIM can retry, ultimately routing to DLQ.
                }
            }

            if (entries.Length == 0)
                await Task.Delay(TimeSpan.FromMilliseconds(200), ct);
        }
    }

    private async Task EnsureGroupAsync(IDatabase db)
    {
        try { await db.StreamCreateConsumerGroupAsync(Stream, Group, "0-0", createStream: true); }
        catch (RedisServerException ex) when (ex.Message.Contains("BUSYGROUP")) { /* already exists */ }
    }
}
```

### Outbox + Publisher worker

A separate consumer reads the `outbox` table (written inside the SP transaction) and publishes to Redis Streams, marking the row as published. This guarantees at-least-once delivery aligned with the DB transaction.

## Integration Rules

- Publishers are usually Worker Services that drain an `outbox` table populated by command handlers.
- Consumers run in Worker Service Pods (Generic Host + `BackgroundService`).
- All consumers honor `CancellationToken` for graceful shutdown.
- Failures → retry via Polly inside the handler; persistent failures → DLQ stream.
- Saga steps: each step publishes the next event; on failure, publish a compensation event.

## Checklist

- [ ] Stream name versioned and aligned to the contract package.
- [ ] Consumer group named `<service>-<purpose>`.
- [ ] Idempotency check (event id) before processing.
- [ ] `XACK` only after success.
- [ ] DLQ stream defined and observed.
- [ ] Polly retry policy around side-effects.
- [ ] `MAXLEN` or `MINID` retention configured.
- [ ] Producer uses Outbox if alignment with DB transaction is required.
- [ ] OpenTelemetry span emitted around consume + publish.

## Related

- [`redis.md`](./redis.md)
- [`background-workers.md`](./background-workers.md)
- [`polly-resilience.md`](./polly-resilience.md)
- [`cqrs.md`](./cqrs.md)
- [`opentelemetry.md`](./opentelemetry.md)
