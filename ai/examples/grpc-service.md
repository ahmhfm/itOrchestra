# Example: End-to-End gRPC Service

Concrete reference implementation of a complete internal gRPC service: contract, server, client, and resilience.

> All rules in [`../skills/grpc.md`](../skills/grpc.md) and [`../skills/linkerd.md`](../skills/linkerd.md) apply.

## Scenario

The Checkout Service calls the Orders Service synchronously to fetch order details and to create an order on behalf of a user.

## 1. Contract — `orders.proto`

```proto
syntax = "proto3";

package orders.v1;
option csharp_namespace = "itOrchestra.Orders.V1";

import "google/protobuf/timestamp.proto";
import "google/protobuf/empty.proto";

service Orders {
  rpc GetOrderById   (GetOrderByIdRequest)   returns (OrderResponse);
  rpc CreateOrder    (CreateOrderRequest)    returns (CreateOrderResponse);
  rpc CancelOrder    (CancelOrderRequest)    returns (google.protobuf.Empty);
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

message CreateOrderRequest {
  string tenant_id      = 1;
  string customer_id    = 2;
  string idempotency_key = 3;
  repeated Item items   = 4;

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

## 2. Server (Orders Service)

### Project setup

```xml
<ItemGroup>
  <PackageReference Include="Grpc.AspNetCore" Version="*" />
  <PackageReference Include="Grpc.AspNetCore.Server.Reflection" Version="*" />
  <Protobuf Include="Protos/orders.proto" GrpcServices="Server" />
</ItemGroup>
```

### Program.cs

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Configuration.AddVaultSecrets("/vault/secrets");

builder.Services.AddSerilogLogging();
builder.Services.AddOpenTelemetryInstrumentation();
builder.Services.AddAdoNet();
builder.Services.AddApplicationServices();
builder.Services.AddKeycloakAuth(builder.Configuration);

builder.Services.AddAuthorization(o =>
{
    o.FallbackPolicy = new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build();
});

builder.Services.AddGrpc(o =>
{
    o.EnableDetailedErrors    = false;
    o.MaxReceiveMessageSize   = 4 * 1024 * 1024;
});

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();
app.MapGrpcService<OrdersGrpcService>();
if (app.Environment.IsDevelopment())
    app.MapGrpcReflectionService();

app.Run();
```

### Service implementation

```csharp
[Authorize]
public sealed class OrdersGrpcService(
    IMediator mediator,
    ILogger<OrdersGrpcService> logger)
    : Orders.OrdersBase
{
    public override async Task<OrderResponse> GetOrderById(
        GetOrderByIdRequest request, ServerCallContext context)
    {
        EnsureGuid(request.TenantId, "tenant_id");
        EnsureGuid(request.OrderId,  "order_id");

        var tenantId = Guid.Parse(request.TenantId);
        var orderId  = Guid.Parse(request.OrderId);

        var dto = await mediator.Send(new GetOrderByIdQuery(tenantId, orderId), context.CancellationToken);
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

    public override async Task<CreateOrderResponse> CreateOrder(
        CreateOrderRequest request, ServerCallContext context)
    {
        EnsureGuid(request.TenantId,        "tenant_id");
        EnsureGuid(request.CustomerId,      "customer_id");
        EnsureGuid(request.IdempotencyKey,  "idempotency_key");

        var cmd = new CreateOrderCommand(
            Guid.Parse(request.TenantId),
            Guid.Parse(request.CustomerId),
            request.Items.Select(i => new OrderItem(i.Sku, i.Quantity, (decimal)i.UnitPrice)).ToList(),
            Guid.Parse(request.IdempotencyKey));

        var result = await mediator.Send(cmd, context.CancellationToken);
        if (!result.IsSuccess) throw result.Error.ToRpcException();

        return new CreateOrderResponse { OrderId = result.Value.ToString() };
    }

    public override async Task<Empty> CancelOrder(CancelOrderRequest request, ServerCallContext context)
    {
        EnsureGuid(request.TenantId, "tenant_id");
        EnsureGuid(request.OrderId,  "order_id");

        var cmd = new CancelOrderCommand(
            Guid.Parse(request.TenantId), Guid.Parse(request.OrderId), request.Reason);
        var result = await mediator.Send(cmd, context.CancellationToken);
        if (!result.IsSuccess) throw result.Error.ToRpcException();
        return new Empty();
    }

    private static void EnsureGuid(string value, string field)
    {
        if (!Guid.TryParse(value, out _))
            throw new RpcException(new Status(StatusCode.InvalidArgument, $"Invalid {field}"));
    }
}
```

## 3. Client (Checkout Service)

### Reference the contracts package

```xml
<ItemGroup>
  <PackageReference Include="itOrchestra.Orders.Contracts.V1.Grpc" Version="1.0.*" />
  <PackageReference Include="Grpc.Net.ClientFactory" Version="*" />
</ItemGroup>
```

### DI registration

```csharp
builder.Services.AddGrpcClient<Orders.OrdersClient>(o =>
{
    o.Address = new Uri(builder.Configuration["Services:Orders:GrpcUrl"]!);   // http://orders-grpc.itorchestra-orders.svc.cluster.local
})
.ConfigureChannel(o =>
{
    o.MaxRetryAttempts = 0;
})
.AddInterceptor<JwtForwardingInterceptor>()
.AddPolicyHandler((sp, _) => GrpcPolicies.Retry())
.AddPolicyHandler((sp, _) => GrpcPolicies.Timeout());

builder.Services.AddSingleton<JwtForwardingInterceptor>();
```

### JWT forwarding interceptor

```csharp
public sealed class JwtForwardingInterceptor(IHttpContextAccessor accessor) : Interceptor
{
    public override AsyncUnaryCall<TRes> AsyncUnaryCall<TReq, TRes>(
        TReq request, ClientInterceptorContext<TReq, TRes> context,
        AsyncUnaryCallContinuation<TReq, TRes> continuation)
    {
        var token = accessor.HttpContext?.Request.Headers["Authorization"].FirstOrDefault();
        if (!string.IsNullOrEmpty(token))
        {
            var headers = context.Options.Headers ?? new Metadata();
            headers.Add("Authorization", token);
            var newOpts = context.Options.WithHeaders(headers);
            context = new ClientInterceptorContext<TReq, TRes>(context.Method, context.Host, newOpts);
        }
        return continuation(request, context);
    }
}
```

### Usage in Checkout application service

```csharp
public sealed class CheckoutService(
    Orders.OrdersClient ordersClient,
    ILogger<CheckoutService> logger)
{
    public async Task<Guid> PlaceOrderAsync(Guid tenantId, Guid customerId,
        IReadOnlyList<CheckoutItem> items, Guid idempotencyKey, CancellationToken ct)
    {
        var request = new CreateOrderRequest
        {
            TenantId       = tenantId.ToString(),
            CustomerId     = customerId.ToString(),
            IdempotencyKey = idempotencyKey.ToString()
        };
        foreach (var i in items)
        {
            request.Items.Add(new CreateOrderRequest.Types.Item
            {
                Sku       = i.Sku,
                Quantity  = i.Quantity,
                UnitPrice = (double)i.UnitPrice
            });
        }

        var deadline = DateTime.UtcNow.AddSeconds(3);
        try
        {
            var resp = await ordersClient.CreateOrderAsync(request, deadline: deadline, cancellationToken: ct);
            return Guid.Parse(resp.OrderId);
        }
        catch (RpcException ex) when (ex.StatusCode == StatusCode.AlreadyExists)
        {
            logger.LogInformation("Idempotent retry returned existing order.");
            throw;   // caller will pick this up via mediator pipeline
        }
    }
}
```

## 4. Linkerd configuration

```yaml
apiVersion: policy.linkerd.io/v1beta1
kind: Server
metadata:
  name: orders-grpc
  namespace: itorchestra-orders
spec:
  podSelector:
    matchLabels: { app: orders-grpc }
  port: 8081
  proxyProtocol: gRPC
---
apiVersion: policy.linkerd.io/v1beta1
kind: ServerAuthorization
metadata:
  name: orders-grpc-allow-checkout
  namespace: itorchestra-orders
spec:
  server:
    name: orders-grpc
  client:
    meshTLS:
      serviceAccounts:
        - name: checkout
          namespace: itorchestra-checkout
```

## What this example demonstrates

- **Internal-only** gRPC: never exposed via YARP.
- **JWT** forwarded automatically; both services validate it.
- **Linkerd mTLS** between the two pods is automatic; declared by an explicit allow policy.
- **Polly retry + timeout** at the client; **gRPC built-in retry disabled**.
- **Deadline** set on every call.
- **Errors** mapped to correct gRPC `StatusCode` values.
- **No reflection** in production.

## Related

- [`../skills/grpc.md`](../skills/grpc.md)
- [`../skills/linkerd.md`](../skills/linkerd.md)
- [`../skills/polly-resilience.md`](../skills/polly-resilience.md)
- [`../skills/keycloak.md`](../skills/keycloak.md)
- [`adonet-sp-call.md`](./adonet-sp-call.md)
