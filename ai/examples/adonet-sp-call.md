# Example: End-to-End ADO.NET Stored Procedure Call

Concrete reference implementation showing the **complete chain** for a read and a write against MSSQL through a Stored Procedure, including the SQL, the C# repository, the application service, and the controller.

> All rules in [`../skills/mssql.md`](../skills/mssql.md) apply.

## Scenario

Use case: an authenticated user creates an order, then fetches it by id.

## 1. SQL (deployed via DbUp migration)

### `sp_Orders_Get_OrderById.sql`

```sql
CREATE OR ALTER PROCEDURE dbo.sp_Orders_Get_OrderById
    @OrderId   UNIQUEIDENTIFIER,
    @TenantId  UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        o.OrderId,
        o.CustomerId,
        o.Status,
        o.TotalAmount,
        o.CreatedAt
    FROM dbo.Orders AS o
    WHERE o.OrderId  = @OrderId
      AND o.TenantId = @TenantId;
END;
GO
```

### `dbo.OrderItemTvp` (user-defined type, once)

```sql
CREATE TYPE dbo.OrderItemTvp AS TABLE
(
    Sku       NVARCHAR(64)  NOT NULL,
    Quantity  INT           NOT NULL,
    UnitPrice DECIMAL(18,4) NOT NULL
);
GO
```

### `sp_Orders_Insert_Order.sql`

```sql
CREATE OR ALTER PROCEDURE dbo.sp_Orders_Insert_Order
    @TenantId       UNIQUEIDENTIFIER,
    @CustomerId     UNIQUEIDENTIFIER,
    @Items          dbo.OrderItemTvp READONLY,
    @IdempotencyKey UNIQUEIDENTIFIER,
    @OrderId        UNIQUEIDENTIFIER OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRAN;

        DECLARE @Existing UNIQUEIDENTIFIER;
        SELECT @Existing = OrderId
        FROM dbo.OrderIdempotencyKeys
        WHERE TenantId = @TenantId AND IdempotencyKey = @IdempotencyKey;

        IF @Existing IS NOT NULL
        BEGIN
            SET @OrderId = @Existing;
            COMMIT TRAN;
            RETURN;
        END

        SET @OrderId = NEWSEQUENTIALID();

        INSERT INTO dbo.Orders (OrderId, TenantId, CustomerId, Status, TotalAmount, CreatedAt)
        SELECT
            @OrderId,
            @TenantId,
            @CustomerId,
            'Pending',
            SUM(i.Quantity * i.UnitPrice),
            SYSUTCDATETIME()
        FROM @Items AS i;

        INSERT INTO dbo.OrderItems (OrderItemId, OrderId, Sku, Quantity, UnitPrice)
        SELECT NEWSEQUENTIALID(), @OrderId, i.Sku, i.Quantity, i.UnitPrice
        FROM @Items AS i;

        INSERT INTO dbo.OrderIdempotencyKeys (TenantId, IdempotencyKey, OrderId, CreatedAt)
        VALUES (@TenantId, @IdempotencyKey, @OrderId, SYSUTCDATETIME());

        INSERT INTO outbox.OutboxEvents (EventId, AggregateId, EventType, Payload, CreatedAt)
        VALUES (NEWID(), @OrderId, 'orders.order_created.v1',
                (SELECT @OrderId AS order_id, @CustomerId AS customer_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                SYSUTCDATETIME());

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        THROW;
    END CATCH
END;
GO
```

## 2. Connection factory (singleton)

```csharp
public interface IDbConnectionFactory { SqlConnection Create(); }

public sealed class SqlServerConnectionFactory(IOptionsMonitor<DatabaseOptions> options) : IDbConnectionFactory
{
    public SqlConnection Create() => new(options.CurrentValue.Orders);
}

public sealed class DatabaseOptions { public required string Orders { get; init; } }
```

DI registration:

```csharp
builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection("ConnectionStrings"));
builder.Services.AddSingleton<IDbConnectionFactory, SqlServerConnectionFactory>();
```

## 3. Repository (calls SPs only)

```csharp
public interface IOrdersRepository
{
    Task<OrderDto?> GetByIdAsync(Guid orderId, Guid tenantId, CancellationToken ct);
    Task<Guid> CreateAsync(Guid tenantId, Guid customerId,
                           IReadOnlyList<OrderItem> items, Guid idempotencyKey,
                           CancellationToken ct);
}

public sealed class OrdersRepository(IDbConnectionFactory factory) : IOrdersRepository
{
    public async Task<OrderDto?> GetByIdAsync(Guid orderId, Guid tenantId, CancellationToken ct)
    {
        await using var conn = factory.Create();
        await SqlResilience.Policy.ExecuteAsync(async () => await conn.OpenAsync(ct));

        await using var cmd = new SqlCommand("sp_Orders_Get_OrderById", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.Add(new SqlParameter("@OrderId",  SqlDbType.UniqueIdentifier) { Value = orderId });
        cmd.Parameters.Add(new SqlParameter("@TenantId", SqlDbType.UniqueIdentifier) { Value = tenantId });

        await using var r = await cmd.ExecuteReaderAsync(CommandBehavior.SingleRow, ct);
        if (!await r.ReadAsync(ct)) return null;

        return new OrderDto(
            Id:          r.GetGuid(0),
            CustomerId:  r.GetGuid(1),
            Status:      r.GetString(2),
            TotalAmount: r.GetDecimal(3),
            CreatedAt:   r.GetDateTime(4));
    }

    public async Task<Guid> CreateAsync(Guid tenantId, Guid customerId,
        IReadOnlyList<OrderItem> items, Guid idempotencyKey, CancellationToken ct)
    {
        await using var conn = factory.Create();
        await SqlResilience.Policy.ExecuteAsync(async () => await conn.OpenAsync(ct));

        await using var cmd = new SqlCommand("sp_Orders_Insert_Order", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.Add(new SqlParameter("@TenantId",   SqlDbType.UniqueIdentifier) { Value = tenantId });
        cmd.Parameters.Add(new SqlParameter("@CustomerId", SqlDbType.UniqueIdentifier) { Value = customerId });
        cmd.Parameters.Add(BuildItemsTvp(items));
        cmd.Parameters.Add(new SqlParameter("@IdempotencyKey", SqlDbType.UniqueIdentifier) { Value = idempotencyKey });
        var outParam = new SqlParameter("@OrderId", SqlDbType.UniqueIdentifier)
        {
            Direction = ParameterDirection.Output
        };
        cmd.Parameters.Add(outParam);

        await cmd.ExecuteNonQueryAsync(ct);
        return (Guid)outParam.Value!;
    }

    private static SqlParameter BuildItemsTvp(IReadOnlyList<OrderItem> items)
    {
        var t = new DataTable();
        t.Columns.Add("Sku",       typeof(string));
        t.Columns.Add("Quantity",  typeof(int));
        t.Columns.Add("UnitPrice", typeof(decimal));
        foreach (var i in items) t.Rows.Add(i.Sku, i.Quantity, i.UnitPrice);
        return new SqlParameter("@Items", SqlDbType.Structured)
        {
            TypeName = "dbo.OrderItemTvp",
            Value    = t
        };
    }
}
```

## 4. MediatR handlers (CQRS)

See [`../skills/cqrs.md`](../skills/cqrs.md) — handlers call the repository methods above. No SQL appears anywhere in C#.

## 5. Controller

```csharp
[ApiController]
[ApiVersion("1.0")]
[Route("api/v{version:apiVersion}/orders")]
[Authorize(Policy = "OrdersWriter")]
public sealed class OrdersController(IMediator mediator) : ControllerBase
{
    [HttpPost]
    public async Task<ActionResult<CreateOrderResponse>> Create(
        [FromBody] CreateOrderRequest request,
        [FromHeader(Name = "Idempotency-Key")] Guid idempotencyKey,
        CancellationToken ct)
    {
        var cmd = new CreateOrderCommand(User.GetTenantId(), request.CustomerId, request.Items, idempotencyKey);
        var result = await mediator.Send(cmd, ct);
        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById),
                new { orderId = result.Value, version = "1.0" },
                new CreateOrderResponse(result.Value))
            : result.Error.ToActionResult();
    }

    [HttpGet("{orderId:guid}")]
    [Authorize(Policy = "OrdersReader")]
    public async Task<ActionResult<OrderResponse>> GetById(Guid orderId, CancellationToken ct)
    {
        var dto = await mediator.Send(new GetOrderByIdQuery(User.GetTenantId(), orderId), ct);
        return dto is null ? NotFound() : Ok(dto);
    }
}
```

## What this example demonstrates

- **No inline SQL anywhere in C#.**
- **Single transaction** wrapping all writes inside the SP, including the outbox row that will publish the `orders.order_created.v1` event.
- **Idempotency** enforced by `OrderIdempotencyKeys` table; same `Idempotency-Key` returns the same `OrderId`.
- **TVP** for batch insert of items.
- **Output parameter** to return the new `OrderId` in a single round trip.
- **`using`** on every disposable; **`CommandType.StoredProcedure`** on every command.
- **Tenant isolation** via `@TenantId` from the validated JWT.
- **Polly** wrapping connection open + execute for transient SQL errors.

## Related

- [`../skills/mssql.md`](../skills/mssql.md)
- [`../skills/cqrs.md`](../skills/cqrs.md)
- [`../patterns/api-template.md`](../patterns/api-template.md)
- [`hangfire-job.md`](./hangfire-job.md)
- [`grpc-service.md`](./grpc-service.md)
