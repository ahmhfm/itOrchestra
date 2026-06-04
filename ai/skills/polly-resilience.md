# Skill: Polly (Resilience Policies)

## Purpose
Apply consistent, observable resilience patterns (retry, circuit breaker, timeout, bulkhead, fallback, hedging) to all outbound calls.

## Architecture Role
The C# application-level resilience layer. Lives **alongside** Linkerd-level retries — Linkerd protects against transport faults; Polly protects against application failures (timeouts, exceptions, business retries with idempotency).

## Rules

1. Every outbound call uses Polly: **HTTP** (`IHttpClientFactory`), **gRPC** clients, **MSSQL** (ADO.NET), **Redis**, **Keycloak**.
2. **Retry** only for **idempotent** calls — reads, idempotent writes (with idempotency key).
3. **Circuit Breaker** on every external dependency.
4. **Timeout** on every call (no infinite waits).
5. Polly policies registered via `Microsoft.Extensions.Resilience` (`AddResilienceHandler`) or `Polly.Extensions.Http`.
6. Retries use **exponential backoff with jitter**.
7. **Bulkhead** to bound concurrency on each external dependency.
8. **Polly events** emitted as OpenTelemetry span events (`retry`, `circuit-broken`, `timeout`).

## Best Practices

- Define a small set of named policies in a static helper class; reuse across services.
- Separate **Per-Try Timeout** (inside retry loop) from **Outer Timeout** (entire call budget).
- Use **Predicate** to retry only specific exceptions / status codes / SQL error numbers.
- Pair Polly retries with **idempotency keys** for writes.
- Log retry attempts with attempt number, wait duration, reason.
- Combine policies with `Policy.Wrap(...)` (outer → inner: Bulkhead → Timeout → Retry → CircuitBreaker → Action).

## Anti-Patterns

| Don't | Do |
|---|---|
| Retry non-idempotent POSTs without idempotency key | Add `Idempotency-Key`, then retry |
| Catch `Exception` and retry everything | Narrow predicate |
| No timeout on `HttpClient` | Always `Timeout` policy + `Per-Try Timeout` |
| Retry forever | Bounded attempts + budget |
| Apply circuit breaker per-call (new each time) | Singleton policy instance per dependency |
| Hide failures with fallback returning empty data | Use fallbacks only for degraded mode; surface errors |
| Use `Task.Delay` for backoff manually | Let Polly handle waits |

## Security Requirements

- Retry-After honored from server responses.
- No secret in retry context / span events.
- Avoid sending the same payload to a malicious endpoint on a retry — Polly does not target this, but circuit breakers cap exposure.

## Performance Guidelines

- Exponential backoff with full jitter: `wait = base * 2^attempt * random(0, 1)`.
- Cap total retry budget (`MaxAttempts ≤ 3` for user-facing, `5` for background).
- Combine with **bulkhead** to bound concurrency (e.g., 50 concurrent calls to Keycloak).

## Example Implementations

### Static policy factory

```csharp
public static class PollyPolicies
{
    public static IAsyncPolicy<HttpResponseMessage> HttpRetry => HttpPolicyExtensions
        .HandleTransientHttpError()
        .WaitAndRetryAsync(
            retryCount: 3,
            sleepDurationProvider: (attempt, _) =>
                TimeSpan.FromMilliseconds(200 * Math.Pow(2, attempt))
                + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 200)),
            onRetry: (outcome, delay, attempt, ctx) =>
            {
                ctx["retry.attempt"] = attempt;
                Activity.Current?.AddEvent(new ActivityEvent("polly.retry",
                    tags: new ActivityTagsCollection
                    {
                        { "attempt", attempt },
                        { "delay.ms", delay.TotalMilliseconds }
                    }));
            });

    public static IAsyncPolicy<HttpResponseMessage> HttpCircuitBreaker => HttpPolicyExtensions
        .HandleTransientHttpError()
        .CircuitBreakerAsync(
            handledEventsAllowedBeforeBreaking: 5,
            durationOfBreak: TimeSpan.FromSeconds(30));

    public static IAsyncPolicy<HttpResponseMessage> HttpTimeout => Policy
        .TimeoutAsync<HttpResponseMessage>(TimeSpan.FromSeconds(3));
}
```

### Wiring to a typed HttpClient

```csharp
builder.Services.AddHttpClient<IOrdersApi, OrdersApi>(c =>
{
    c.BaseAddress = new Uri(builder.Configuration["Api:Orders"]!);
})
.AddPolicyHandler(PollyPolicies.HttpTimeout)
.AddPolicyHandler(PollyPolicies.HttpRetry)
.AddPolicyHandler(PollyPolicies.HttpCircuitBreaker);
```

### gRPC client resilience

```csharp
builder.Services.AddGrpcClient<Orders.OrdersClient>(o =>
{
    o.Address = new Uri(builder.Configuration["Services:Orders:GrpcUrl"]!);
})
.ConfigureChannel(o =>
{
    o.MaxRetryAttempts = 0;   // disable gRPC built-in retry; use Polly
})
.AddPolicyHandler((sp, _) => Policy
    .Handle<RpcException>(ex => IsTransient(ex.StatusCode))
    .WaitAndRetryAsync(3, attempt =>
        TimeSpan.FromMilliseconds(200 * Math.Pow(2, attempt))));

static bool IsTransient(StatusCode code) => code is
    StatusCode.Unavailable or StatusCode.DeadlineExceeded or StatusCode.ResourceExhausted;
```

### ADO.NET retry around `OpenAsync` / `ExecuteAsync`

```csharp
public sealed class SqlResilience
{
    private static readonly int[] TransientSqlErrors =
        { 40197, 40501, 40613, 49918, 49919, 49920, 4060, 233, 64, 10928, 10929 };

    public static AsyncPolicy Policy { get; } = Polly.Policy
        .Handle<SqlException>(ex => ex.Errors.Cast<SqlError>().Any(e => TransientSqlErrors.Contains(e.Number)))
        .WaitAndRetryAsync(3, attempt =>
            TimeSpan.FromMilliseconds(100 * Math.Pow(2, attempt)));
}

// Usage
await SqlResilience.Policy.ExecuteAsync(async () =>
{
    await using var conn = factory.Create();
    await conn.OpenAsync(ct);
    /* ... */
});
```

### Bulkhead

```csharp
public static IAsyncPolicy KeycloakBulkhead { get; } = Policy
    .BulkheadAsync(maxParallelization: 50, maxQueuingActions: 100);
```

## Integration Rules

- Polly + Linkerd: **both** active. Linkerd handles transport-level retry (network flap). Polly handles application-level retry (status code / SQL error number / domain exception).
- Polly events surfaced as **OpenTelemetry span events**, not just logs.
- Polly **fallback** policies should not silently return empty data — flag the response as degraded and emit a metric.

## Checklist

- [ ] Timeout policy on every outbound call.
- [ ] Retry only for idempotent operations.
- [ ] Idempotency key on retried writes.
- [ ] Circuit breaker per external dependency.
- [ ] Bulkhead for high-concurrency targets.
- [ ] Exponential backoff with jitter.
- [ ] Retry-After honored when present.
- [ ] Span events for retries / breaks / timeouts.
- [ ] Metrics for failure rate per dependency.

## Related

- [`webapi.md`](./webapi.md)
- [`grpc.md`](./grpc.md)
- [`mssql.md`](./mssql.md)
- [`redis.md`](./redis.md)
- [`opentelemetry.md`](./opentelemetry.md)
