# Pattern: API Template (REST + gRPC pair)

Canonical templates for the REST and gRPC surfaces of a microservice. Use whenever you add an endpoint to either surface.

## REST endpoint template

Every endpoint follows this anatomy:

1. **Route** under `/api/v{n}/<resource>`.
2. **`[Authorize(Policy = "...")]`** with the role required.
3. **Request DTO** as a `record`.
4. **Validation** in a FluentValidation `IValidator<TRequest>`.
5. **Dispatch** to a MediatR Command or Query.
6. **Response DTO** as a `record` (never a domain entity).
7. **ProblemDetails** for errors via a global exception handler.

### Skeleton

```csharp
[ApiController]
[ApiVersion("1.0")]
[Route("api/v{version:apiVersion}/orders")]
[Authorize(Policy = "OrdersWriter")]
public sealed class OrdersController(IMediator mediator) : ControllerBase
{
    [HttpPost]
    [ProducesResponseType(typeof(CreateOrderResponse), StatusCodes.Status201Created)]
    [ProducesResponseType(typeof(ValidationProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<CreateOrderResponse>> Create(
        [FromBody] CreateOrderRequest request,
        [FromHeader(Name = "Idempotency-Key")] Guid idempotencyKey,
        CancellationToken ct)
    {
        var tenantId = User.GetTenantId();
        var cmd      = new CreateOrderCommand(tenantId, request.CustomerId, request.Items, idempotencyKey);
        var result   = await mediator.Send(cmd, ct);
        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById),
                              new { orderId = result.Value, version = "1.0" },
                              new CreateOrderResponse(result.Value))
            : result.Error.ToActionResult();
    }

    [HttpGet("{orderId:guid}")]
    [Authorize(Policy = "OrdersReader")]
    [ProducesResponseType(typeof(OrderResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<OrderResponse>> GetById(Guid orderId, CancellationToken ct)
    {
        var tenantId = User.GetTenantId();
        var dto      = await mediator.Send(new GetOrderByIdQuery(tenantId, orderId), ct);
        return dto is null ? NotFound() : Ok(dto);
    }
}
```

### DTOs

```csharp
public sealed record CreateOrderRequest(
    Guid CustomerId,
    IReadOnlyList<OrderItemRequest> Items);

public sealed record OrderItemRequest(string Sku, int Quantity, decimal UnitPrice);

public sealed record CreateOrderResponse(Guid OrderId);

public sealed record OrderResponse(
    Guid Id,
    Guid CustomerId,
    string Status,
    decimal TotalAmount,
    DateTime CreatedAt);
```

### Validator

```csharp
public sealed class CreateOrderRequestValidator : AbstractValidator<CreateOrderRequest>
{
    public CreateOrderRequestValidator()
    {
        RuleFor(x => x.CustomerId).NotEmpty();
        RuleFor(x => x.Items)
            .NotEmpty()
            .Must(items => items.Count <= 100).WithMessage("Max 100 items per order.");
        RuleForEach(x => x.Items).SetValidator(new OrderItemRequestValidator());
    }
}

public sealed class OrderItemRequestValidator : AbstractValidator<OrderItemRequest>
{
    public OrderItemRequestValidator()
    {
        RuleFor(x => x.Sku).NotEmpty().MaximumLength(64);
        RuleFor(x => x.Quantity).GreaterThan(0);
        RuleFor(x => x.UnitPrice).GreaterThanOrEqualTo(0);
    }
}
```

### Global exception handler

```csharp
public sealed class GlobalExceptionHandler(ILogger<GlobalExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext context, Exception ex, CancellationToken ct)
    {
        var (status, title) = ex switch
        {
            ValidationException     => (StatusCodes.Status400BadRequest, "Validation failed"),
            NotFoundException       => (StatusCodes.Status404NotFound,   "Not found"),
            ConflictException       => (StatusCodes.Status409Conflict,   "Conflict"),
            UnauthorizedException   => (StatusCodes.Status403Forbidden,  "Forbidden"),
            _                       => (StatusCodes.Status500InternalServerError, "Unexpected error")
        };

        logger.LogError(ex, "Unhandled exception {Title}", title);

        context.Response.StatusCode = status;
        await context.Response.WriteAsJsonAsync(new ProblemDetails
        {
            Type   = $"https://itorchestra.com/errors/{status}",
            Title  = title,
            Status = status,
            Detail = status >= 500 ? "Please try again later." : ex.Message,
            Instance = context.Request.Path
        }, cancellationToken: ct);
        return true;
    }
}
```

## gRPC service template

Mirror of the REST endpoint, with gRPC-native errors.

### Skeleton

```csharp
[Authorize]
public sealed class OrdersGrpcService(IMediator mediator) : Orders.OrdersBase
{
    public override async Task<OrderResponse> GetOrderById(
        GetOrderByIdRequest request, ServerCallContext context)
    {
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
        var tenantId = Guid.Parse(request.TenantId);
        var cmd = new CreateOrderCommand(
            TenantId:       tenantId,
            CustomerId:     Guid.Parse(request.CustomerId),
            Items:          request.Items.Select(i => new OrderItem(i.Sku, i.Quantity, (decimal)i.UnitPrice)).ToList(),
            IdempotencyKey: Guid.Parse(request.IdempotencyKey));

        var result = await mediator.Send(cmd, context.CancellationToken);
        if (!result.IsSuccess) throw result.Error.ToRpcException();

        return new CreateOrderResponse { OrderId = result.Value.ToString() };
    }
}
```

### Error mapping (REST ↔ gRPC)

| Domain Error | REST | gRPC |
|---|---|---|
| Validation | 400 Bad Request | `InvalidArgument` |
| Not Found | 404 Not Found | `NotFound` |
| Conflict / Idempotency mismatch | 409 Conflict | `AlreadyExists` |
| Forbidden | 403 Forbidden | `PermissionDenied` |
| Unauthenticated | 401 Unauthorized | `Unauthenticated` |
| Unexpected | 500 Internal Server Error | `Internal` |

## Required cross-cutting

- **JWT validation** at the controller / gRPC service (see [`../skills/keycloak.md`](../skills/keycloak.md)).
- **Correlation Id** propagated via middleware / interceptor.
- **OpenTelemetry** auto-instrumentation enabled.
- **Polly** policies attached to outbound calls.

## Checklist (per endpoint)

- [ ] `[Authorize(Policy = "...")]` with explicit policy.
- [ ] Request and response are `record` DTOs (not entities).
- [ ] Validation rule defined in a `Validator`.
- [ ] Returns the right HTTP / gRPC status on failure.
- [ ] Idempotency key required for state-changing operations.
- [ ] Controller is thin; logic in MediatR handler.
- [ ] No SQL in the controller.
- [ ] Tested with unit + integration tests.
- [ ] OpenAPI / Protobuf contract published.

## Related

- [`microservice-template.md`](./microservice-template.md)
- [`../skills/webapi.md`](../skills/webapi.md)
- [`../skills/grpc.md`](../skills/grpc.md)
- [`../skills/cqrs.md`](../skills/cqrs.md)
