# Skill: ASP.NET 10 Core Web API (External REST)

## Purpose
Define how external-facing REST APIs are designed, implemented, and protected. These APIs sit **behind YARP** and are consumed by WPF, MAUI, browsers, mobile, and third-party clients.

## Architecture Role
The public face of each microservice. Translates HTTP requests into application service calls, applies edge concerns (validation, mapping, status codes), and returns JSON DTOs. Never the place for business logic or SQL.

## Rules

1. Each microservice exposes **exactly one** REST API surface, versioned via URL segment (`/api/v1`, `/api/v2`).
2. Controllers are **thin**: validate, call application service, map result to ActionResult. No business logic.
3. **DTOs only** in request/response. No internal entities, no full domain models.
4. **`[Authorize]` by default** on every controller. `[AllowAnonymous]` requires a documented reason.
5. Errors return **ProblemDetails** with stable `type` URIs (no stack traces).
6. The REST surface is **independent** from the gRPC surface — different endpoints, different DTOs.
7. **External clients access this REST API only through YARP**; the service is not directly exposed to the internet.
8. JWT validation runs **at the service**, even though YARP already validated (defense in depth).

## Best Practices

- Use **minimal APIs** for very small services and tightly bounded endpoints; use **controllers** when more than 3 endpoints exist or when filters/conventions are needed.
- Use record types for DTOs: `public sealed record OrderResponse(Guid Id, string Status, decimal Total);`.
- Use `IValidator<T>` (FluentValidation) registered in DI; reject 400 with field-level details.
- Use `Results.Problem(...)` or `Problem(...)` extension for consistent error responses.
- Use `IHttpClientFactory` for any outbound HTTP (for non-gRPC calls — to AI inference, Vault, etc.).
- Apply **rate limiting** at YARP first, then app-level only for expensive endpoints.
- Use response compression (`Brotli`) and HTTPS Redirection middleware enabled.

## Anti-Patterns

| Don't | Do |
|---|---|
| Open `SqlConnection` in a controller | Inject an application service |
| Map exceptions to status codes inside the controller | Use a global exception middleware producing ProblemDetails |
| Expose `OrderEntity` directly | Map to `OrderResponse` DTO |
| Return raw strings or anonymous objects | Use typed records |
| Re-implement auth per controller | Use `[Authorize(Policy = "...")]` and policy handlers |
| Skip versioning ("we'll add it later") | Version from day one: `/api/v1` |
| Catch and return 200 with `{ error: ... }` | Use HTTP status codes correctly |

## Security Requirements

- `[Authorize]` default; minimum role/scope per endpoint declared in `[Authorize(Policy = "...")]`.
- Validate JWT `iss`, `aud`, signature, `exp`, plus required claims (`sub`, `tenant_id`, `roles`).
- Anti-Forgery for cookie-based clients (rare here; mostly bearer tokens).
- CORS: strict allow-list, never `*` in production.
- Use `[ApiController]` to get automatic 400 on invalid model state.
- All endpoints require HTTPS (handled by Kubernetes Ingress + YARP).
- Idempotency keys (`Idempotency-Key` header) required on POST/PUT for money-moving or external side-effects.
- See [`../core/security.md`](../core/security.md).

## Performance Guidelines

- Avoid synchronous I/O on the controller thread; everything `async`.
- Use `Response Caching` middleware only for true static responses.
- Use streaming responses (`IAsyncEnumerable<T>`) for large payloads.
- Avoid heavy serialization — prefer `System.Text.Json` source generators.
- Trim allocations in hot paths (no LINQ if it's a hot path).

## Example Implementations

### Program.cs (Web API)

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Services
    .AddControllers()
    .AddJsonOptions(o =>
    {
        o.JsonSerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
        o.JsonSerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
    });

builder.Services.AddProblemDetails();
builder.Services.AddApiVersioning(o =>
{
    o.DefaultApiVersion = new ApiVersion(1, 0);
    o.AssumeDefaultVersionWhenUnspecified = true;
    o.ReportApiVersions = true;
});

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.Authority = builder.Configuration["Keycloak:Authority"];
        o.Audience  = builder.Configuration["Keycloak:Audience"];
        o.RequireHttpsMetadata = true;
    });

builder.Services.AddAuthorization();
builder.Services.AddOpenTelemetryInstrumentation();   // see ../skills/opentelemetry.md
builder.Services.AddSerilogLogging();
builder.Services.AddApplicationServices();             // app layer DI
builder.Services.AddAdoNet();                          // IDbConnectionFactory + Polly
builder.Services.AddGrpcClients();                     // typed gRPC clients
builder.Services.AddHealthChecks();

var app = builder.Build();

app.UseSerilogRequestLogging();
app.UseExceptionHandler();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.MapHealthChecks("/health");

app.Run();
```

### Thin controller

```csharp
[ApiController]
[ApiVersion("1.0")]
[Route("api/v{version:apiVersion}/orders")]
[Authorize(Policy = "OrdersReader")]
public sealed class OrdersController(IOrderQueryService orders) : ControllerBase
{
    [HttpGet("{orderId:guid}")]
    [ProducesResponseType(typeof(OrderResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<OrderResponse>> GetById(Guid orderId, CancellationToken ct)
    {
        var tenantId = User.GetTenantId();
        var result = await orders.GetAsync(orderId, tenantId, ct);
        return result is null ? NotFound() : Ok(result);
    }
}
```

### DTO + Request

```csharp
public sealed record OrderResponse(
    Guid Id,
    Guid CustomerId,
    string Status,
    decimal TotalAmount,
    DateTime CreatedAt);

public sealed record CreateOrderRequest(
    Guid CustomerId,
    IReadOnlyList<OrderItemRequest> Items);

public sealed record OrderItemRequest(string Sku, int Quantity, decimal UnitPrice);
```

## Integration Rules

- **YARP** routes external traffic to this API; the API itself is registered as a Kubernetes Service of type `ClusterIP` (not exposed externally). See [`yarp.md`](./yarp.md).
- **Authentication** uses Keycloak JWT bearer; the service does not implement any login flow. See [`keycloak.md`](./keycloak.md).
- **Outbound** calls to other services go to their **gRPC** API via Linkerd, not to their REST API. See [`grpc.md`](./grpc.md).
- **Data access** uses ADO.NET + Stored Procedures only. See [`mssql.md`](./mssql.md).
- **Observability:** OpenTelemetry auto-instrumentation for ASP.NET Core enabled. See [`opentelemetry.md`](./opentelemetry.md).
- **Resilience:** Outbound HTTP/gRPC clients wrapped in Polly. See [`polly-resilience.md`](./polly-resilience.md).

## Checklist

- [ ] `[ApiController]` applied.
- [ ] URL versioned (`/api/v1`).
- [ ] `[Authorize]` (with policy) on every endpoint, or `[AllowAnonymous]` with justification.
- [ ] Returns DTOs (records), never entities.
- [ ] Inputs validated (FluentValidation or DataAnnotations + ModelState).
- [ ] Errors mapped to ProblemDetails by the global handler.
- [ ] No `SqlConnection` in the controller.
- [ ] Correlation Id is read from middleware and added to log scope.
- [ ] HealthCheck endpoint exposed (`/health`).
- [ ] OpenAPI / Swagger document generated and exposed only behind YARP admin route.

## Related

- [`mvc.md`](./mvc.md)
- [`grpc.md`](./grpc.md)
- [`yarp.md`](./yarp.md)
- [`../patterns/api-template.md`](../patterns/api-template.md)
- [`../core/security.md`](../core/security.md)
