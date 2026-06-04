# Skill: ASP.NET 10 Core MVC (Web UI)

## Purpose
Define how server-rendered web pages are built when an HTML UI is required (admin portals, internal dashboards, customer-facing forms that need SEO and server rendering).

## Architecture Role
A web UI host. Pages are server-rendered with Razor. The MVC app is itself a client of the platform: it calls backend services through **YARP API Gateway** (REST) for data. It does **not** access MSSQL directly and does **not** share Stored Procedures.

## Rules

1. **Strict Model-View-Controller** separation. Controllers are thin; Views are presentation; Models/ViewModels are explicit.
2. **No business logic** in Controllers — call application services via DI.
3. **No direct database access.** Data comes from backend Web APIs via YARP.
4. **ViewModels** for every view; never bind directly to entities or service DTOs from another team.
5. **Tag Helpers** only — no legacy `Html.*` helpers.
6. **Anti-Forgery Tokens** required on every state-changing form.
7. **Authentication** is OIDC against Keycloak (cookie + bearer hybrid acceptable for browser sessions).
8. **`[Authorize]`** by default; `[AllowAnonymous]` only with documented reason.

## Best Practices

- Layout in `_Layout.cshtml`; partials for repeated fragments.
- Use ViewComponents for self-contained, reusable UI blocks with their own logic.
- Use `IValidator<T>` (FluentValidation) for view-model validation.
- Use `IUrlHelper` and named routes — never concatenate URLs.
- Use Razor Pages **only** when a page maps 1:1 to a URL with no complex routing — otherwise MVC.
- Use `IHttpClientFactory` for outbound calls to YARP.

## Anti-Patterns

| Don't | Do |
|---|---|
| `ViewBag` / `ViewData` for typed data | Strongly-typed ViewModels |
| HTML in Controllers | Razor Views |
| Inline JavaScript with secrets | Server-render config; pass via data-attributes (no secrets) |
| DB calls in Controllers | Backend Web API via YARP |
| Skip Anti-Forgery on POST | Always include `@Html.AntiForgeryToken()` or `[ValidateAntiForgeryToken]` |
| Static service references | DI everywhere |

## Security Requirements

- HTTPS only; HSTS middleware enabled.
- Cookie authentication with `HttpOnly`, `Secure`, `SameSite=Lax` (or `Strict` for non-OIDC flows).
- CSRF tokens on every state-changing endpoint.
- Content Security Policy (CSP) header set; no inline scripts without a nonce.
- X-Frame-Options: DENY (or CSP `frame-ancestors`).
- Input validation server-side regardless of client-side.
- Output encoding by default in Razor; never call `@Html.Raw(...)` without explicit safety review.
- File uploads: scan with `ClamAV` sidecar or external service before persisting.

## Performance Guidelines

- Response compression (`Brotli` then `gzip`) enabled.
- Static files served with long `Cache-Control` + content hash.
- Razor view compilation on; `PrecompileViews` in publish profile.
- Avoid synchronous I/O in views (`@await` for async ViewComponents).
- Server-side caching for hot views via `[ResponseCache]` or distributed cache (Redis).

## Example Implementations

### Program.cs

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Services
    .AddControllersWithViews()
    .AddJsonOptions(o => o.JsonSerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase);

builder.Services
    .AddAuthentication(o =>
    {
        o.DefaultScheme        = CookieAuthenticationDefaults.AuthenticationScheme;
        o.DefaultChallengeScheme = OpenIdConnectDefaults.AuthenticationScheme;
    })
    .AddCookie(o =>
    {
        o.Cookie.HttpOnly = true;
        o.Cookie.SecurePolicy = CookieSecurePolicy.Always;
        o.Cookie.SameSite = SameSiteMode.Lax;
    })
    .AddOpenIdConnect(o =>
    {
        o.Authority      = builder.Configuration["Keycloak:Authority"];
        o.ClientId       = builder.Configuration["Keycloak:ClientId"];
        o.ClientSecret   = builder.Configuration["Keycloak:ClientSecret"];
        o.ResponseType   = "code";
        o.SaveTokens     = true;
        o.GetClaimsFromUserInfoEndpoint = true;
    });

builder.Services.AddAuthorization();
builder.Services.AddAntiforgery();
builder.Services.AddHttpClient<IOrdersApi, OrdersApi>(c =>
{
    c.BaseAddress = new Uri(builder.Configuration["Api:BaseUrl"]!);
})
.AddPolicyHandler(HttpPolicies.Retry())
.AddPolicyHandler(HttpPolicies.CircuitBreaker());

builder.Services.AddOpenTelemetryInstrumentation();

var app = builder.Build();

app.UseHsts();
app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();
app.UseAntiforgery();

app.MapControllerRoute("default", "{controller=Home}/{action=Index}/{id?}");

app.Run();
```

### Thin Controller

```csharp
[Authorize(Policy = "OrdersReader")]
public sealed class OrdersController(IOrdersApi api) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(CancellationToken ct)
    {
        var rows = await api.ListAsync(ct);
        var vm   = new OrdersIndexViewModel(rows);
        return View(vm);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [Authorize(Policy = "OrdersWriter")]
    public async Task<IActionResult> Cancel(Guid id, [FromForm] string reason, CancellationToken ct)
    {
        await api.CancelAsync(id, reason, ct);
        TempData["Success"] = "Order cancelled.";
        return RedirectToAction(nameof(Index));
    }
}
```

### ViewModel + View

```csharp
public sealed record OrdersIndexViewModel(IReadOnlyList<OrderRow> Orders);
public sealed record OrderRow(Guid Id, string Status, decimal Total);
```

```cshtml
@model OrdersIndexViewModel
@{ ViewData["Title"] = "Orders"; }
<table class="table">
    <thead><tr><th>Id</th><th>Status</th><th>Total</th></tr></thead>
    <tbody>
    @foreach (var o in Model.Orders)
    {
        <tr>
            <td>@o.Id</td>
            <td>@o.Status</td>
            <td>@o.Total.ToString("N2")</td>
        </tr>
    }
    </tbody>
</table>
```

## Integration Rules

- **Outbound:** REST to YARP only. Never call internal services directly or use gRPC from MVC.
- **Auth:** OIDC against Keycloak. Cookie session for the browser, ID/access tokens persisted server-side (`SaveTokens=true`) and forwarded to backend APIs as `Authorization: Bearer`.
- **Observability:** OpenTelemetry ASP.NET Core instrumentation; outgoing HTTP traces correlated by `X-Correlation-Id`.
- **Configuration:** non-secret in `appsettings.json`; secrets injected from Vault via `VaultSharp` at startup.

## Checklist

- [ ] MVC strict separation (no business code in Controllers or Views).
- [ ] ViewModels for every view; no raw entities or DTOs leaked.
- [ ] `[ValidateAntiForgeryToken]` on every state-changing action.
- [ ] `[Authorize]` (policy) by default; `[AllowAnonymous]` justified.
- [ ] CSP, HSTS, XFO headers set.
- [ ] All outbound API calls via `IHttpClientFactory` + Polly.
- [ ] No direct DB references.
- [ ] OpenTelemetry registered.
- [ ] Cookies marked `HttpOnly`, `Secure`, `SameSite`.

## Related

- [`webapi.md`](./webapi.md)
- [`yarp.md`](./yarp.md)
- [`keycloak.md`](./keycloak.md)
- [`../core/security.md`](../core/security.md)
