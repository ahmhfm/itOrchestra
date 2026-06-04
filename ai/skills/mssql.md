# Skill: MSSQL + ADO.NET

## Purpose
Define how all data access, persistence, and business data logic are handled. This is the single source of truth for database interaction rules.

## Architecture Role
MSSQL is the persistence layer for every microservice (Database-per-Service). All SQL lives inside the database; the C# layer only invokes Stored Procedures via ADO.NET (`Microsoft.Data.SqlClient`).

## Rules

1. **No ORM.** No EF, EF Core, Dapper, LINQ-to-SQL, NHibernate. Ever.
2. **No inline SQL** in C# (no `CommandText` set to SQL text, no string concatenation, no interpolation).
3. **CommandType.StoredProcedure** for every `SqlCommand`.
4. **Parameterized** input only via `SqlParameter` with explicit `SqlDbType` and `Size`.
5. **All transactions inside Stored Procedures** using `SET XACT_ABORT ON` + `BEGIN/COMMIT/ROLLBACK TRAN` + `TRY...CATCH`.
6. **All connections via `IDbConnectionFactory`** (DI-registered) — never `new SqlConnection()` inline.
7. **`using` blocks** for `SqlConnection`, `SqlCommand`, `SqlDataReader`.
8. **No `SELECT *`** — explicit column lists only.
9. **Stored Procedure naming:** `sp_Module_Action_Entity` (e.g., `sp_Orders_Get_OrderById`).
10. **One service, one database.** Cross-database joins, Linked Servers, and three-part names referencing another service's DB are forbidden.

## Best Practices

- Return result sets with stable column names; consumers in C# read by ordinal **once** then by ordinal in tight loops.
- For paging, accept `@PageNumber`, `@PageSize`, `@SortColumn`, `@SortDirection` and return total count as a second result set or an `OUTPUT` parameter.
- Use Table-Valued Parameters (TVPs) for batch inserts/updates; declare a User-Defined Table Type once.
- Use `READ COMMITTED SNAPSHOT` isolation at the database level to reduce blocking.
- Use `OUTPUT` clause to return identity values from inserts in a single round trip.
- Wrap multi-statement writes in a single `BEGIN TRAN ... COMMIT TRAN` block.
- Use `NEWID()` / `NEWSEQUENTIALID()` deliberately; sequential is faster for clustered indexes.
- Indexed Views for read-heavy aggregations; rebuild on a schedule.

## Anti-Patterns

| Don't | Do |
|---|---|
| `cmd.CommandText = "SELECT * FROM Orders WHERE Id = " + id;` | `cmd.CommandText = "sp_Orders_Get_OrderById"; cmd.CommandType = StoredProcedure; cmd.Parameters.Add(...);` |
| String-concat SQL in C# | All SQL inside MSSQL only |
| Sharing one SP across services | Each service owns its SPs |
| Opening a long-lived connection | Open per call, close on `using` exit |
| Returning entities directly | Map to DTOs in the application layer |
| Catching exceptions inside the repository to log and swallow | Let them bubble; log at the boundary |
| Doing business workflows in a Trigger | Triggers are for audit + integrity only |

## Security Requirements

- Each service has its **own MSSQL login**; grants are **`EXEC` on Stored Procedures only**. No direct table grants.
- Connection strings come from **HashiCorp Vault** (never `appsettings.json` in production).
- **Row-Level Security** policies enforce tenant isolation inside MSSQL.
- All Stored Procedures that touch tenant data accept `@TenantId` and filter by it; never trust client claim alone — validate the JWT `tenant_id` and pass it from the application layer.
- Audit Triggers write to `audit.*` tables with no `UPDATE`/`DELETE` grants.

## Performance Guidelines

- Always inspect the execution plan for new Stored Procedures. Look for scans where seeks are expected.
- Cover indexes for hot read SPs; include the columns returned to avoid Key Lookups.
- Statistics auto-update enabled; periodic `UPDATE STATISTICS` on volatile tables.
- Avoid implicit conversions in `WHERE` clauses (parameter types must match column types).
- Use `OPTION (RECOMPILE)` sparingly, only on SPs with extreme parameter sniffing problems.
- Use `WITH (NOLOCK)` is forbidden; prefer `READ COMMITTED SNAPSHOT`.
- Set `SET NOCOUNT ON;` at the top of every SP.

## Example Implementations

### Application layer (C#)

```csharp
public sealed class OrdersRepository(IDbConnectionFactory factory) : IOrdersRepository
{
    public async Task<OrderDto?> GetByIdAsync(Guid orderId, Guid tenantId, CancellationToken ct)
    {
        await using var conn = factory.Create();
        await conn.OpenAsync(ct);

        await using var cmd = new SqlCommand("sp_Orders_Get_OrderById", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.Add(new SqlParameter("@OrderId", SqlDbType.UniqueIdentifier) { Value = orderId });
        cmd.Parameters.Add(new SqlParameter("@TenantId", SqlDbType.UniqueIdentifier) { Value = tenantId });

        await using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SingleRow, ct);
        if (!await reader.ReadAsync(ct)) return null;

        return new OrderDto(
            Id: reader.GetGuid(0),
            CustomerId: reader.GetGuid(1),
            Status: reader.GetString(2),
            TotalAmount: reader.GetDecimal(3),
            CreatedAt: reader.GetDateTime(4));
    }
}
```

### Stored Procedure (T-SQL)

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
    WHERE o.OrderId = @OrderId
      AND o.TenantId = @TenantId;
END;
GO
```

### Stored Procedure with transaction

```sql
CREATE OR ALTER PROCEDURE dbo.sp_Orders_Insert_Order
    @TenantId   UNIQUEIDENTIFIER,
    @CustomerId UNIQUEIDENTIFIER,
    @Items      dbo.OrderItemTvp READONLY,
    @OrderId    UNIQUEIDENTIFIER OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRAN;

        SET @OrderId = NEWSEQUENTIALID();

        INSERT INTO dbo.Orders (OrderId, TenantId, CustomerId, Status, CreatedAt)
        VALUES (@OrderId, @TenantId, @CustomerId, 'Pending', SYSUTCDATETIME());

        INSERT INTO dbo.OrderItems (OrderItemId, OrderId, Sku, Quantity, UnitPrice)
        SELECT NEWSEQUENTIALID(), @OrderId, Sku, Quantity, UnitPrice
        FROM @Items;

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        THROW;
    END CATCH
END;
GO
```

## Integration Rules

- DI registration: register `IDbConnectionFactory` as `Singleton`; it reads the connection string from `IOptionsMonitor<DatabaseOptions>` (sourced from Vault).
- Resilience: wrap connection opening and command execution in a **Polly** policy (Retry + Timeout) — see [`polly-resilience.md`](./polly-resilience.md). Retry on transient SQL errors (40197, 40501, 40613, 49918–49920, 4060, 233, 64) only.
- Observability: emit OpenTelemetry spans around each SP call with attributes `db.system=mssql`, `db.statement=<sp_name>`, `db.tenant_id=<tenant>`.
- Migrations: managed by **DbUp** or **RoundhousE**; one migrations runner per service deployed as a Kubernetes Job before the service Pod starts.
- Hangfire stores its data in the `[hangfire]` schema of the service's own database — this is the only place a non-application schema is allowed alongside business data.

## Checklist

- [ ] No inline SQL in any `.cs` file.
- [ ] `CommandType.StoredProcedure` on every command.
- [ ] All inputs as `SqlParameter` with explicit type and size.
- [ ] `using` on every ADO.NET object.
- [ ] SP includes `SET NOCOUNT ON` and `SET XACT_ABORT ON` (when writing).
- [ ] SP transaction has `TRY/CATCH` with `ROLLBACK` and `THROW`.
- [ ] No `SELECT *`.
- [ ] No cross-database / Linked Server references.
- [ ] Tenant filter present where applicable.
- [ ] Execution plan reviewed.
- [ ] Vault-sourced connection string.
- [ ] OpenTelemetry span emitted.

## Related

- [`../core/architecture.md`](../core/architecture.md)
- [`../examples/adonet-sp-call.md`](../examples/adonet-sp-call.md)
- [`polly-resilience.md`](./polly-resilience.md)
- [`vault.md`](./vault.md)
- [`hangfire.md`](./hangfire.md)
