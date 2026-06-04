# Skill: OpenTelemetry (Observability)

## Purpose
Unified instrumentation for traces, metrics, and logs across every service. Enables end-to-end visibility from the WPF/MAUI client through YARP, Linkerd, microservices, MSSQL, Redis, and Hangfire.

## Architecture Role
The instrumentation layer baked into every .NET 10 process. Emits OTLP to a cluster-local **OpenTelemetry Collector**, which forwards traces to **Tempo**, metrics to **Prometheus**, and logs to **Loki/OpenSearch**, all visualized in **Grafana**.

## Rules

1. Every service registers OpenTelemetry **traces + metrics + logs** at startup.
2. **W3C Trace Context** is the only correlation standard; `traceparent` propagates everywhere.
3. **Correlation Id** (`X-Correlation-Id`) is always injected at YARP if missing, propagated through gRPC metadata and Redis Streams entries.
4. **No secrets, no tokens, no full PII** in span attributes or log payloads.
5. **Sampling** policy declared explicitly (parent-based, tail sampling at the collector for errors and latency outliers).
6. **Health metrics** (`http.server.request.duration`, `rpc.server.duration`, `db.client.operation.duration`) emitted by built-in instrumentation libraries.
7. **Custom spans** for business operations using `ActivitySource`.
8. **Custom metrics** for business KPIs using `Meter`.

## Best Practices

- Use a single `ActivitySource` per service named `itOrchestra.<Service>`.
- Use a single `Meter` per service named `itOrchestra.<Service>`.
- Add semantic attributes from the OpenTelemetry conventions (`http.method`, `db.system`, `rpc.system`, `messaging.system`).
- Add a small set of custom dimensions: `tenant_id`, `operation`, `service.version`.
- Keep cardinality bounded — never put a `user_id`, `order_id`, or other unbounded value as a metric dimension (use span attributes instead).
- Export logs via Serilog `Serilog.Sinks.OpenTelemetry` so they share span context.

## Anti-Patterns

| Don't | Do |
|---|---|
| Log a JWT or full request body | Mask / omit |
| Add `user_id` to metric dimensions | Use span attribute (no aggregation across users) |
| Manually wrap calls already instrumented | Rely on the built-in instrumentation |
| Sample 1% on errors | Use tail sampling: 100% on errors, lower on success |
| Two `ActivitySource` names per service | One per service |
| Hardcode OTLP endpoints | Use environment / Vault config |
| Skip metrics for a "simple" service | Every service emits the baseline |

## Security Requirements

- OTLP endpoint authenticated (mTLS) when collector is out-of-mesh; inside the mesh, Linkerd handles it.
- Tail sampler runs in the collector; the collector strips known sensitive headers (`Authorization`, `Cookie`, `Set-Cookie`) from spans before forwarding.
- Loggers configured with destructuring policies that mask `password`, `token`, `secret`, `pan`, `iban`, `ssn` field names.
- PII redaction policy enforced by a Serilog enricher + collector processor.

## Performance Guidelines

- Use AOT-friendly source generators for log messages (`LoggerMessage`).
- Trace sampling: parent-based head sampler at ~10% for normal traffic; tail sampler keeps all error/latency traces.
- Avoid synchronous flushing — let the SDK batch.
- Bound queue sizes; drop oldest on overflow (logged once).

## Example Implementations

### DI registration

```csharp
public static class TelemetryExtensions
{
    public static IServiceCollection AddOpenTelemetryInstrumentation(this IServiceCollection services)
    {
        var serviceName    = Assembly.GetEntryAssembly()!.GetName().Name!;
        var serviceVersion = Assembly.GetEntryAssembly()!.GetName().Version!.ToString();

        services.AddOpenTelemetry()
            .ConfigureResource(r => r
                .AddService(serviceName: serviceName, serviceVersion: serviceVersion)
                .AddAttributes(new KeyValuePair<string, object>[]
                {
                    new("deployment.environment", Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Production")
                }))
            .WithTracing(t => t
                .AddAspNetCoreInstrumentation()
                .AddGrpcClientInstrumentation()
                .AddHttpClientInstrumentation()
                .AddSqlClientInstrumentation(o =>
                {
                    o.SetDbStatementForStoredProcedure = true;
                    o.RecordException = true;
                })
                .AddSource("itOrchestra.Orders")
                .AddOtlpExporter())
            .WithMetrics(m => m
                .AddAspNetCoreInstrumentation()
                .AddHttpClientInstrumentation()
                .AddRuntimeInstrumentation()
                .AddProcessInstrumentation()
                .AddMeter("itOrchestra.Orders")
                .AddOtlpExporter());

        services.AddLogging(b =>
        {
            b.AddOpenTelemetry(o =>
            {
                o.IncludeFormattedMessage = true;
                o.IncludeScopes           = true;
                o.AddOtlpExporter();
            });
        });

        return services;
    }
}
```

### Custom span (business operation)

```csharp
public sealed class CheckoutService(ActivitySource activitySource, /* ... */ )
{
    private static readonly ActivitySource Source = new("itOrchestra.Orders");

    public async Task<Guid> CheckoutAsync(Guid orderId, Guid tenantId, CancellationToken ct)
    {
        using var activity = Source.StartActivity("orders.checkout");
        activity?.SetTag("tenant_id", tenantId);
        activity?.SetTag("order_id",  orderId);

        try
        {
            // ... business work ...
            activity?.SetStatus(ActivityStatusCode.Ok);
            return orderId;
        }
        catch (Exception ex)
        {
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);
            throw;
        }
    }
}
```

### Custom metric

```csharp
public sealed class OrdersMetrics
{
    public static readonly Meter Meter = new("itOrchestra.Orders");
    public static readonly Counter<long>   OrdersCreated  = Meter.CreateCounter<long>("orders.created.count");
    public static readonly Histogram<double> CheckoutLatency = Meter.CreateHistogram<double>("orders.checkout.latency.ms");
}
```

### Correlation Id middleware

```csharp
public sealed class CorrelationIdMiddleware(RequestDelegate next)
{
    public async Task Invoke(HttpContext context)
    {
        var corr = context.Request.Headers["X-Correlation-Id"].FirstOrDefault()
                   ?? Guid.NewGuid().ToString("N");
        context.Response.Headers["X-Correlation-Id"] = corr;
        using (LogContext.PushProperty("CorrelationId", corr))
        {
            await next(context);
        }
    }
}
```

## Integration Rules

- **YARP** propagates `traceparent` and `X-Correlation-Id` automatically (via transform).
- **gRPC** clients/servers propagate `traceparent` in metadata via the built-in instrumentation.
- **Redis Streams** producers add `traceparent` as an entry field; consumers reconstruct the parent context.
- **Hangfire** jobs attach to the parent span via a custom job filter that reads `traceparent` from job metadata.
- **MSSQL** SP calls produce client spans via `OpenTelemetry.Instrumentation.SqlClient`.

## Checklist

- [ ] `AddOpenTelemetryInstrumentation` called in every service.
- [ ] Traces, metrics, logs exported via OTLP.
- [ ] Sampling configured (head + tail).
- [ ] Sensitive headers/fields scrubbed.
- [ ] Correlation Id middleware registered.
- [ ] Custom `ActivitySource` + `Meter` named with the service.
- [ ] Span events for retries / fallbacks (from Polly).
- [ ] `db.statement` carries the SP name (no parameters).
- [ ] Grafana dashboards published per service.
- [ ] Alerts wired to SLOs.

## Related

- [`../core/architecture.md`](../core/architecture.md)
- [`yarp.md`](./yarp.md)
- [`linkerd.md`](./linkerd.md)
- [`hangfire.md`](./hangfire.md)
- [`polly-resilience.md`](./polly-resilience.md)
