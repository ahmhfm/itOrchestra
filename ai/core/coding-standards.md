# Coding Standards (Core)

C# 14 on .NET 10. Load when writing new code, refactoring, or doing a code review.

## Project setup

- Target framework: `net10.0` (`net10.0-windows` for WPF).
- `Nullable` enabled. `TreatWarningsAsErrors` set to true.
- `ImplicitUsings` enabled (except in tests).
- `EnableNETAnalyzers`, `AnalysisLevel` = `latest`.
- `global.json` pins the SDK to a `10.0.x` band.
- Central package management via `Directory.Packages.props`.

## Naming

| Element | Convention | Example |
|---|---|---|
| Class, record, struct | PascalCase | `OrderService` |
| Method, property | PascalCase | `GetOrderByIdAsync` |
| Interface | `I` + PascalCase | `IOrderRepository` |
| Local variable, parameter | camelCase | `orderId` |
| Private field | `_camelCase` | `_dbConnectionFactory` |
| Constant | PascalCase | `DefaultPageSize` |
| Stored Procedure | `sp_Module_Action_Entity` | `sp_Orders_Get_OrderById` |
| gRPC service | `<Aggregate>Service` | `OrdersService` |
| Protobuf package | `<aggregate>.v<n>` | `orders.v1` |
| Event topic | `<aggregate>.<event>.v<n>` | `orders.order_created.v1` |

## Language features to prefer

- File-scoped namespaces.
- Primary constructors for DI-only classes.
- Collection expressions (`[ ... ]`).
- `record` for DTOs and value objects.
- `required` members for non-nullable construction guarantees.
- Pattern matching (`is`, `switch` expressions).
- `async`/`await` on all I/O; no `.Result`, no `.Wait()`, no `Task.Run` for I/O wrapping.

## Async

- Public method names that are async end with `Async`.
- `CancellationToken` is the **last parameter** on every async method that touches I/O.
- Use `ConfigureAwait(false)` only in library code that does not touch UI. App code does not need it on .NET 10.
- Never `await Task.WhenAll` without observing exceptions.

## DI

- Constructor injection only. No `IServiceProvider.GetService<T>()` inside business code.
- Lifetimes:
  - `Singleton` — stateless, thread-safe, shared (configuration providers, IDbConnectionFactory).
  - `Scoped` — per-request handlers, application services, MediatR handlers.
  - `Transient` — lightweight stateless utilities only.
- `SqlConnection` is **never** singleton; obtain a fresh connection per call via the factory.

## Data access (summary)

- Only ADO.NET via `Microsoft.Data.SqlClient`.
- `CommandType.StoredProcedure` always.
- `using` for every `SqlConnection`, `SqlCommand`, `SqlDataReader`.
- Open connections as late as possible; close as early as possible (`using` handles this).
- Always pass `SqlParameter` with explicit `SqlDbType` and `Size` for strings.
- See [`../skills/mssql.md`](../skills/mssql.md) for full rules.

## Error handling

- `try/catch` at boundaries only: controllers, gRPC service methods, Hangfire job entry methods, message consumers.
- Inside services and helpers, do not catch unless you can add meaningful context.
- Re-throw with `throw;` (preserves stack), not `throw ex`.
- Convert known business failures to typed results (`Result<T>`) or thrown domain exceptions; map to REST 400/404/409 or gRPC `InvalidArgument`/`NotFound`/`FailedPrecondition`.
- Never expose stack traces, EF/SQL exception text, or internal class names to clients.

## Logging

- Structured logging via Serilog + `Microsoft.Extensions.Logging`.
- Log levels:
  - `Trace`, `Debug` — dev-only.
  - `Information` — business events (request handled, job started/completed).
  - `Warning` — recoverable anomalies (retry succeeded after failure).
  - `Error` — failed operations.
  - `Critical` — process integrity threatened.
- Required fields on every log line: `CorrelationId`, `ServiceName`, `Operation`, plus structured payload.
- Never log secrets, tokens, full request bodies, raw PII.

## Performance

- Avoid `IEnumerable<T>` when materialization is implicit; prefer `List<T>` or `IReadOnlyList<T>`.
- Use `Span<T>` / `Memory<T>` for hot paths that touch buffers.
- Avoid LINQ in hot paths; allocations are not free.
- Prefer pooled `HttpClient` via `IHttpClientFactory`; prefer pooled `GrpcChannel` via DI.

## Testing

- xUnit + NSubstitute.
- Naming: `MethodUnderTest_Scenario_ExpectedResult`.
- One arrange-act-assert per test.
- Integration tests use Testcontainers for MSSQL.
- gRPC integration tests use the in-memory test server.
- No `Thread.Sleep` in tests; use `TaskCompletionSource` or polling with timeout.

## Code organization

- One public type per file (`OrderService.cs`).
- Folder layout per project:
  ```
  /Controllers      // REST controllers (Web API project)
  /Grpc             // gRPC service implementations
  /Application      // Application services, MediatR handlers
  /Domain           // Domain types, value objects, results
  /Data             // ADO.NET repositories (call SPs only)
  /Contracts        // Public DTOs, Protobuf-generated types (linked)
  /Infrastructure   // Cross-cutting (logging, telemetry, vault, etc.)
  ```

## Tooling

- `dotnet format` runs in CI; PR fails on diff.
- `.editorconfig` enforces braces, spacing, `using` order.
- StyleCop analyzers enabled, ruleset shared via `Directory.Build.props`.

## Comments

- Comment only what is non-obvious (intent, trade-offs, references).
- No narration ("// increment counter").
- XML doc comments on public APIs and `[Authorize]` policies.

## Anti-patterns (banned in code review)

- `static` mutable state outside of `readonly` constants.
- Catch-all `catch (Exception)` that swallows.
- `async void` (except event handlers).
- Magic strings / numbers — extract constants or config.
- "God classes" (>500 lines, >7 dependencies) — split.
- Public setters on aggregate roots — use methods/records with `init`.
