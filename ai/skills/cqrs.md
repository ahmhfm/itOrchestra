# Skill: CQRS (Command Query Responsibility Segregation)

## Purpose
Separate write workflows from read workflows so each can be optimized independently. Implemented with **MediatR** (no ORM dependency) over **ADO.NET Stored Procedures**.

## Architecture Role
CQRS lives inside the application services layer of a microservice. Controllers (REST) and gRPC service methods dispatch a Command or Query to MediatR; handlers call SPs through ADO.NET.

## Rules

1. **Commands** mutate state and return only a minimal result (`Guid` of new entity, `Result.Success`, etc.). Never return read models.
2. **Queries** are read-only and return read models / DTOs. They must not mutate state.
3. Each Command/Query has **exactly one** handler.
4. Handlers call **dedicated Stored Procedures** — write SPs for commands, read SPs / Views for queries.
5. **Validation** runs as a MediatR `IPipelineBehavior<,>` (FluentValidation).
6. **Logging + Tracing + Metrics** run as pipeline behaviors.
7. **Idempotency** for commands handled via an `IdempotencyKey` in the command (stored in DB or Redis).
8. No ORM. No inline SQL. See [`mssql.md`](./mssql.md).

## Best Practices

- Place commands/queries beside their handlers (`Application/Orders/CreateOrder/`).
- Use `record` for command/query types.
- Use `Result<T>` for expected business failures, `RpcException` / domain exceptions for unexpected failures.
- Separate read SPs from write SPs in MSSQL — read SPs can be optimized with `WITH (NOEXPAND)` views, write SPs handle transactions.
- One Command = one transaction (handled inside the SP).
- Heavy reads cached in **Redis** with cache-aside + event-driven invalidation.

## Anti-Patterns

| Don't | Do |
|---|---|
| Command returns a full DTO of the entity | Return only `Guid`/`Result` and re-query if UI needs the data |
| Query mutates state | Queries are pure reads |
| Reuse SPs for both read and write | Separate SPs per concern |
| Hardcode validation in the handler | Validation pipeline behavior |
| Skip idempotency on `CreateX` commands | Always have an idempotency key |
| Bypass MediatR by injecting handlers directly | Always go through `IMediator.Send` |
| Use MediatR `INotification` for cross-service events | Use **Redis Streams** for cross-service; `INotification` is intra-process only |

## Security Requirements

- Authorization runs as a pipeline behavior or in the controller layer **before** dispatch. The handler assumes the caller is authorized.
- Multi-tenant: the command/query carries `TenantId` (sourced from the validated JWT), and the SP filters by it.
- Audit: each command emits an audit log entry via a pipeline behavior.

## Performance Guidelines

- Read SPs can return multiple result sets in one call to reduce round trips (e.g., header + lines).
- Use `CommandBehavior.SequentialAccess` for streaming large rows.
- For read-heavy queries, cache the result in Redis keyed by `(SP, params)`; invalidate on write.
- Use SQL Server Indexed Views for hot read shapes.

## Example Implementations

### Folder layout (per aggregate)

```
/Application
  /Orders
    /CreateOrder
      CreateOrderCommand.cs
      CreateOrderCommandHandler.cs
      CreateOrderCommandValidator.cs
    /CancelOrder
      ...
    /GetOrderById
      GetOrderByIdQuery.cs
      GetOrderByIdQueryHandler.cs
    /ListOrders
      ...
/Infrastructure
  /Pipeline
    ValidationBehavior.cs
    LoggingBehavior.cs
    TracingBehavior.cs
    AuthorizationBehavior.cs
```

### Command + Handler

```csharp
public sealed record CreateOrderCommand(
    Guid TenantId,
    Guid CustomerId,
    IReadOnlyList<OrderItem> Items,
    Guid IdempotencyKey) : IRequest<Result<Guid>>;

public sealed record OrderItem(string Sku, int Quantity, decimal UnitPrice);

public sealed class CreateOrderCommandHandler(
    IDbConnectionFactory factory,
    ILogger<CreateOrderCommandHandler> logger)
    : IRequestHandler<CreateOrderCommand, Result<Guid>>
{
    public async Task<Result<Guid>> Handle(CreateOrderCommand cmd, CancellationToken ct)
    {
        await using var conn = factory.Create();
        await conn.OpenAsync(ct);

        // Idempotency check via a dedicated SP
        await using (var idemCmd = new SqlCommand("sp_Orders_TryClaim_IdempotencyKey", conn)
        {
            CommandType = CommandType.StoredProcedure
        })
        {
            idemCmd.Parameters.Add(new SqlParameter("@TenantId",        SqlDbType.UniqueIdentifier) { Value = cmd.TenantId });
            idemCmd.Parameters.Add(new SqlParameter("@IdempotencyKey",  SqlDbType.UniqueIdentifier) { Value = cmd.IdempotencyKey });
            var existing = (await idemCmd.ExecuteScalarAsync(ct)) as Guid?;
            if (existing.HasValue) return Result<Guid>.Success(existing.Value);
        }

        // Insert via write SP using a TVP
        await using var sp = new SqlCommand("sp_Orders_Insert_Order", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        sp.Parameters.Add(new SqlParameter("@TenantId",   SqlDbType.UniqueIdentifier) { Value = cmd.TenantId });
        sp.Parameters.Add(new SqlParameter("@CustomerId", SqlDbType.UniqueIdentifier) { Value = cmd.CustomerId });
        sp.Parameters.Add(BuildItemsTvp(cmd.Items));
        var orderIdParam = new SqlParameter("@OrderId", SqlDbType.UniqueIdentifier)
        {
            Direction = ParameterDirection.Output
        };
        sp.Parameters.Add(orderIdParam);

        await sp.ExecuteNonQueryAsync(ct);

        var orderId = (Guid)orderIdParam.Value!;
        logger.LogInformation("Order {OrderId} created for tenant {TenantId}", orderId, cmd.TenantId);
        return Result<Guid>.Success(orderId);
    }

    private static SqlParameter BuildItemsTvp(IReadOnlyList<OrderItem> items)
    {
        var table = new DataTable();
        table.Columns.Add("Sku",       typeof(string));
        table.Columns.Add("Quantity",  typeof(int));
        table.Columns.Add("UnitPrice", typeof(decimal));
        foreach (var it in items) table.Rows.Add(it.Sku, it.Quantity, it.UnitPrice);

        return new SqlParameter("@Items", SqlDbType.Structured)
        {
            TypeName = "dbo.OrderItemTvp",
            Value    = table
        };
    }
}
```

### Query + Handler

```csharp
public sealed record GetOrderByIdQuery(Guid TenantId, Guid OrderId) : IRequest<OrderDto?>;

public sealed class GetOrderByIdQueryHandler(IDbConnectionFactory factory)
    : IRequestHandler<GetOrderByIdQuery, OrderDto?>
{
    public async Task<OrderDto?> Handle(GetOrderByIdQuery q, CancellationToken ct)
    {
        await using var conn = factory.Create();
        await conn.OpenAsync(ct);

        await using var cmd = new SqlCommand("sp_Orders_Get_OrderById", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.Add(new SqlParameter("@OrderId",  SqlDbType.UniqueIdentifier) { Value = q.OrderId });
        cmd.Parameters.Add(new SqlParameter("@TenantId", SqlDbType.UniqueIdentifier) { Value = q.TenantId });

        await using var r = await cmd.ExecuteReaderAsync(CommandBehavior.SingleRow, ct);
        if (!await r.ReadAsync(ct)) return null;
        return new OrderDto(
            r.GetGuid(0), r.GetGuid(1), r.GetString(2),
            r.GetDecimal(3), r.GetDateTime(4));
    }
}
```

### MediatR DI + pipeline

```csharp
builder.Services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssemblyContaining<Program>();
    cfg.AddOpenBehavior(typeof(ValidationBehavior<,>));
    cfg.AddOpenBehavior(typeof(AuthorizationBehavior<,>));
    cfg.AddOpenBehavior(typeof(TracingBehavior<,>));
    cfg.AddOpenBehavior(typeof(LoggingBehavior<,>));
});
```

## Integration Rules

- Controllers / gRPC service methods call `IMediator.Send(command, ct)`; do not inject handlers directly.
- Use the **Outbox pattern** for events that must be published as a side-effect of a write transaction: command handler inserts into an `outbox` table inside the SP transaction; a Worker drains the outbox into Redis Streams. See [`redis-streams.md`](./redis-streams.md).
- Cache invalidation: write handlers publish a Redis Streams event; read caches listen and evict.

## Checklist

- [ ] Commands return minimal result types (no full read models).
- [ ] Queries are read-only.
- [ ] Each handler calls only the SPs it owns; no cross-service DB calls.
- [ ] Validation, authorization, logging, tracing wired as pipeline behaviors.
- [ ] Commands carry idempotency keys.
- [ ] Outbox used for side-effect events.
- [ ] No business logic in MediatR pipeline behaviors except cross-cutting concerns.

## Related

- [`mssql.md`](./mssql.md)
- [`redis-streams.md`](./redis-streams.md)
- [`redis.md`](./redis.md)
- [`webapi.md`](./webapi.md)
- [`grpc.md`](./grpc.md)
