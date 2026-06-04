# Skill: gRPC (Internal Service-to-Service)

## Purpose
Define how microservices talk to each other **synchronously** inside the cluster. gRPC over HTTP/2 with Protobuf is the only sanctioned sync inter-service protocol.

## Architecture Role
The internal RPC layer. Every microservice exposes a gRPC API for sibling services. This API is **never** reachable from outside the cluster and **never** passes through YARP. Linkerd handles transport (mTLS, retries, observability).

## Rules

1. **`.proto` files are the single source of truth** for inter-service contracts.
2. Each service has its own gRPC package: `<aggregate>.v<n>` (e.g., `orders.v1`).
3. Generated stubs are produced at build time by `Grpc.Tools`; **never hand-edit** generated files.
4. gRPC is for **internal traffic only**. Never expose a gRPC endpoint through YARP for external clients.
5. Service-to-service calls always go **direct pod-to-pod**, mediated by Linkerd mTLS — not through any gateway.
6. Backward-compatible Protobuf evolution: never renumber, never remove fields; deprecate then retire after consumers upgrade.
7. JWT propagated in gRPC **metadata** (`authorization: Bearer <token>`). Validated at every service.
8. Errors return correct gRPC `StatusCode` + rich `Status` details; never throw raw exceptions across the wire.

## Best Practices

- One `.proto` file per logical area; keep files focused (one service per file).
- Use `google.protobuf.Timestamp`, `Duration`, `Empty` from well-known types.
- Use `optional` for nullable scalars (Protobuf 3.15+).
- Use `repeated` carefully; for very large lists, prefer server-streaming.
- Naming: `Get`, `List`, `Create`, `Update`, `Delete`, `Reserve`, `Cancel` (verbs first in the method name).
- Add a `correlation_id` field to every request **or** rely on gRPC metadata header `x-correlation-id`. Prefer metadata.
- Deadlines on every client call (3–5 seconds for fast reads, longer for batch).
- Compression: enable `gzip` for payloads > 4 KB (configurable per call).

## Anti-Patterns

| Don't | Do |
|---|---|
| Expose gRPC externally via YARP | gRPC is internal only |
| Use gRPC-Web for browser-to-service | Browser → YARP → REST |
| Reuse the same Protobuf message for REST DTO | Separate contract surfaces |
| Renumber field tags | Deprecate, never renumber |
| Throw `Exception` from a service method | Throw `RpcException(new Status(...))` |
| Long-poll over unary | Use server-streaming |
| Singleton gRPC client without channel reuse | Register via `AddGrpcClient<T>` |
| Skip deadline on client call | Always set `DeadlineAfter` |

## Security Requirements

- mTLS is automatic between meshed pods (Linkerd). Verify your service has the `linkerd.io/inject: enabled` annotation.
- JWT propagated as metadata, validated by `Grpc.AspNetCore.Server` middleware (same Keycloak issuer/audience).
- `[Authorize]` policies on every gRPC service method.
- Never include secrets or full PII in gRPC trailers.
- Reflection endpoint disabled in production (`MapGrpcReflectionService()` only in dev profile).

## Performance Guidelines

- Reuse `GrpcChannel` per target service; injected via `IGrpcClientFactory`.
- Use **client-side load balancing** via DNS resolver + round-robin policy (Linkerd handles the rest).
- Avoid chatty patterns; design coarse-grained methods (`GetOrderWithItems` instead of `GetOrder` + 10 `GetItem`).
- For batch reads, use a single `List<Id>` request rather than N round trips.
- Server-streaming for events / progress; client-streaming for uploads.

## Example Implementations

### `.proto` contract

```proto
syntax = "proto3";

package orders.v1;
option csharp_namespace = "itOrchestra.Orders.V1";

import "google/protobuf/timestamp.proto";
import "google/protobuf/empty.proto";

service Orders {
  rpc GetOrderById       (GetOrderByIdRequest)       returns (OrderResponse);
  rpc ListOrdersForUser  (ListOrdersForUserRequest)  returns (stream OrderResponse);
  rpc CreateOrder        (CreateOrderRequest)        returns (CreateOrderResponse);
  rpc CancelOrder        (CancelOrderRequest)        returns (google.protobuf.Empty);
}

message GetOrderByIdRequest {
  string order_id  = 1;
  string tenant_id = 2;
}

message OrderResponse {
  string order_id    = 1;
  string customer_id = 2;
  string status      = 3;
  double total       = 4;
  google.protobuf.Timestamp created_at = 5;
}

message ListOrdersForUserRequest {
  string customer_id = 1;
  string tenant_id   = 2;
}

message CreateOrderRequest {
  string tenant_id    = 1;
  string customer_id  = 2;
  repeated Item items = 3;

  message Item {
    string sku        = 1;
    int32  quantity   = 2;
    double unit_price = 3;
  }
}

message CreateOrderResponse {
  string order_id = 1;
}

message CancelOrderRequest {
  string order_id  = 1;
  string tenant_id = 2;
  string reason    = 3;
}
```

### Server (ASP.NET Core)

```csharp
[Authorize]
public sealed class OrdersGrpcService(
    IOrderQueryService queries,
    IOrderCommandService commands,
    ILogger<OrdersGrpcService> logger)
    : Orders.OrdersBase
{
    public override async Task<OrderResponse> GetOrderById(
        GetOrderByIdRequest request, ServerCallContext context)
    {
        var orderId  = Guid.Parse(request.OrderId);
        var tenantId = Guid.Parse(request.TenantId);

        var dto = await queries.GetAsync(orderId, tenantId, context.CancellationToken);
        if (dto is null)
            throw new RpcException(new Status(StatusCode.NotFound, "Order not found"));

        return new OrderResponse
        {
            OrderId    = dto.Id.ToString(),
            CustomerId = dto.CustomerId.ToString(),
            Status     = dto.Status,
            Total      = (double)dto.TotalAmount,
            CreatedAt  = Timestamp.FromDateTime(dto.CreatedAt.ToUniversalTime())
        };
    }
}
```

### Server registration (Program.cs)

```csharp
builder.Services.AddGrpc(o =>
{
    o.EnableDetailedErrors = false;        // never true in prod
    o.MaxReceiveMessageSize = 4 * 1024 * 1024; // 4 MB
});

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o => { /* same Keycloak settings as REST */ });

var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();
app.MapGrpcService<OrdersGrpcService>();
```

### Client (typed)

```csharp
// Program.cs
builder.Services.AddGrpcClient<Orders.OrdersClient>(o =>
{
    o.Address = new Uri(builder.Configuration["Services:Orders:GrpcUrl"]!);
})
.AddPolicyHandler(GrpcPolicies.Retry())   // see ../skills/polly-resilience.md
.AddPolicyHandler(GrpcPolicies.Timeout());

// Usage
public sealed class OrderEnricher(Orders.OrdersClient ordersClient)
{
    public async Task<OrderResponse> EnrichAsync(Guid orderId, Guid tenantId, string jwt, CancellationToken ct)
    {
        var metadata = new Metadata { { "Authorization", $"Bearer {jwt}" } };
        var deadline = DateTime.UtcNow.AddSeconds(3);

        return await ordersClient.GetOrderByIdAsync(
            new GetOrderByIdRequest { OrderId = orderId.ToString(), TenantId = tenantId.ToString() },
            headers: metadata,
            deadline: deadline,
            cancellationToken: ct);
    }
}
```

## Integration Rules

- **Linkerd** handles mTLS, retries, timeouts, and metrics at the transport level. Application-level Polly handles app retries (idempotency-aware).
- **gRPC API ≠ REST API.** A service has both, with different shapes. REST contains user-facing concepts; gRPC contains finer-grained internal operations.
- **`.proto` versioning:** publish a NuGet package of generated stubs per service (`itOrchestra.Orders.Contracts.V1`). Consumers reference the NuGet package — they do not include the `.proto` directly.
- **Breaking-change detection** in CI using `buf breaking` or `protolint`.
- **Observability:** `Grpc.Net.Client` and `Grpc.AspNetCore.Server` produce OpenTelemetry traces and metrics automatically when instrumentation is registered. See [`opentelemetry.md`](./opentelemetry.md).

## Checklist

- [ ] `.proto` file added to a Contracts project with stable package name.
- [ ] Field numbers never renumbered.
- [ ] Generated client published as NuGet (or referenced via SourceLink).
- [ ] Server method has `[Authorize]`.
- [ ] Errors mapped to correct `StatusCode` (NotFound, InvalidArgument, FailedPrecondition, Internal).
- [ ] Client call has `Deadline` set.
- [ ] Polly Retry + Timeout configured on the client.
- [ ] Linkerd injection annotation present on the Pod.
- [ ] OpenTelemetry traces emit `rpc.system=grpc`.
- [ ] No reflection endpoint in production.

## Related

- [`linkerd.md`](./linkerd.md)
- [`webapi.md`](./webapi.md)
- [`polly-resilience.md`](./polly-resilience.md)
- [`opentelemetry.md`](./opentelemetry.md)
- [`../examples/grpc-service.md`](../examples/grpc-service.md)
