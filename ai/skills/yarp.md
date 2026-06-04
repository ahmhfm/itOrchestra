# Skill: YARP (External API Gateway)

## Purpose
Define the single public entry point for the platform. YARP terminates TLS, validates JWT, routes to service REST APIs, enforces rate limits, and handles cross-cutting edge concerns.

## Architecture Role
The **edge**. All external traffic from clients (WPF, MAUI, browsers, mobile, third parties) enters here. YARP is **never** on the path between two internal services — that is gRPC over Linkerd.

## Rules

1. YARP is the **only** public endpoint exposed by the cluster (via Ingress or LoadBalancer).
2. YARP routes **only** to service **REST APIs**. It never proxies gRPC for external clients.
3. YARP **validates JWT** at the edge (Keycloak issuer/audience, signature, exp).
4. YARP **never contains business logic**. It routes, transforms, protects.
5. **Rate limiting** is applied per IP and per `sub` (token subject).
6. **TLS termination** at YARP; downstream traffic (inside mesh) re-encrypted by Linkerd mTLS.
7. **No internal service** is reachable externally except via YARP.
8. **Routes versioned** by URL prefix (`/api/v1/*`).

## Best Practices

- Configure routes via `appsettings.json` (or Vault-overlaid config); avoid imperative C# for routing where declarative works.
- Use **transforms** to inject `X-Correlation-Id`, propagate `Authorization`, strip dangerous headers.
- Use **destinations** to point at Kubernetes Service DNS names (`http://orders-api.itorchestra-orders.svc.cluster.local`).
- Use **destination health probes** so YARP excludes failing pods.
- Enable **distributed tracing** propagation (W3C `traceparent` header).
- Provide separate route maps for **public** (anonymous-allowed) endpoints (login, health) vs. **authenticated** endpoints.
- Use **session affinity** only when truly required (mostly avoid).

## Anti-Patterns

| Don't | Do |
|---|---|
| Route internal service-to-service traffic through YARP | Use gRPC + Linkerd |
| Implement business logic in a custom transform | Only routing/auth/headers |
| Hardcode JWT secrets in YARP config | Use Vault and reference by name |
| Catch all errors and return 500 | Map to ProblemDetails; let downstream errors surface |
| Run a single YARP instance | At least 2 replicas with HPA |
| Allow wildcard CORS | Strict allow-list per route |
| Skip rate limiting on public endpoints | Always rate-limit at the edge |

## Security Requirements

- **HTTPS only.** HSTS header; HTTP redirected to HTTPS.
- **TLS 1.3** preferred; minimum TLS 1.2.
- **JWT validation** at YARP:
  - Authority (Keycloak realm URL).
  - Audience (`api-gateway`).
  - Required claims (`sub`, `tenant_id`, `roles`).
- **Header sanitization** — strip `X-Forwarded-User`, `X-User-*`, internal-only headers from inbound.
- **CORS** allow-list per route; never `*`.
- **Rate limits**:
  - Anonymous: 60 req/min per IP.
  - Authenticated: 600 req/min per `sub`.
  - Sensitive endpoints (login, password reset): 10 req/min per IP.
- **WAF** in front of YARP (Cloudflare, NGINX with ModSecurity, or Azure Front Door) for OWASP-style protections.

## Performance Guidelines

- At least 2 replicas with HPA targeting CPU 60%.
- `ResponseCompression` enabled (Brotli, gzip).
- HTTP/2 to downstream services.
- `Keep-Alive` enabled; connection pool sized to expected concurrency.
- Avoid per-request allocations in transforms — reuse buffers where possible.

## Example Implementations

### Program.cs

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"))
    .AddTransforms(b =>
    {
        b.AddRequestTransform(ctx =>
        {
            var corr = ctx.HttpContext.Request.Headers["X-Correlation-Id"].FirstOrDefault()
                       ?? Guid.NewGuid().ToString("N");
            ctx.ProxyRequest.Headers.TryAddWithoutValidation("X-Correlation-Id", corr);
            return ValueTask.CompletedTask;
        });

        b.AddResponseTransform(ctx =>
        {
            ctx.HttpContext.Response.Headers["Strict-Transport-Security"]
                = "max-age=63072000; includeSubDomains; preload";
            return ValueTask.CompletedTask;
        });
    });

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.Authority = builder.Configuration["Keycloak:Authority"];
        o.Audience  = "api-gateway";
        o.RequireHttpsMetadata = true;
        o.TokenValidationParameters = new()
        {
            ValidateIssuer           = true,
            ValidateAudience         = true,
            ValidateLifetime         = true,
            ValidateIssuerSigningKey = true,
            ClockSkew                = TimeSpan.FromSeconds(30)
        };
    });

builder.Services.AddAuthorization(o =>
{
    o.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
});

builder.Services.AddRateLimiter(o =>
{
    o.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
    {
        var sub = ctx.User?.Identity?.IsAuthenticated == true
            ? ctx.User.FindFirst("sub")?.Value ?? "anon"
            : ctx.Connection.RemoteIpAddress?.ToString() ?? "anon";
        return RateLimitPartition.GetFixedWindowLimiter(sub, _ => new()
        {
            PermitLimit = 600, Window = TimeSpan.FromMinutes(1), QueueLimit = 0
        });
    });
});

var app = builder.Build();
app.UseHsts();
app.UseHttpsRedirection();
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
app.MapReverseProxy();

app.Run();
```

### appsettings.json (route config)

```json
{
  "ReverseProxy": {
    "Routes": {
      "orders-v1": {
        "ClusterId": "orders-api",
        "Match": { "Path": "/api/v1/orders/{**catch-all}" },
        "AuthorizationPolicy": "default",
        "CorsPolicy": "default",
        "RateLimiterPolicy": "default",
        "Transforms": [
          { "PathPattern": "/api/v1/orders/{**catch-all}" }
        ]
      },
      "auth-public": {
        "ClusterId": "auth-api",
        "Match": { "Path": "/api/v1/auth/{**catch-all}" },
        "AuthorizationPolicy": "anonymous",
        "RateLimiterPolicy": "anonymous"
      }
    },
    "Clusters": {
      "orders-api": {
        "LoadBalancingPolicy": "RoundRobin",
        "HealthCheck": {
          "Active": {
            "Enabled": true,
            "Interval": "00:00:10",
            "Timeout": "00:00:02",
            "Policy": "ConsecutiveFailures",
            "Path": "/health"
          }
        },
        "Destinations": {
          "d1": { "Address": "http://orders-api.itorchestra-orders.svc.cluster.local" }
        }
      },
      "auth-api": {
        "Destinations": {
          "d1": { "Address": "http://auth-api.itorchestra-auth.svc.cluster.local" }
        }
      }
    }
  }
}
```

## Integration Rules

- **JWT** issued by Keycloak; YARP validates and forwards `Authorization: Bearer` downstream unchanged.
- **Correlation Id** injected on missing; propagated in headers.
- **Linkerd** sidecar attached to YARP Pod; downstream traffic gets mTLS automatically.
- **Health checks** hit `/health` of each downstream service.
- **OpenTelemetry**: YARP emits HTTP server + client spans; correlated with `traceparent`.

## Checklist

- [ ] Single public endpoint exposed (Ingress / LoadBalancer → YARP).
- [ ] HTTPS only; HSTS enabled.
- [ ] JWT validated at YARP (issuer + audience + signature).
- [ ] Header sanitization in place.
- [ ] Rate limits configured per route and per token.
- [ ] CORS allow-list configured (no wildcards in prod).
- [ ] Routes versioned (`/api/v1`).
- [ ] Active health probes against downstream `/health`.
- [ ] Linkerd sidecar present.
- [ ] OpenTelemetry traces emitted.
- [ ] No internal-to-internal traffic routed via YARP.

## Related

- [`linkerd.md`](./linkerd.md)
- [`webapi.md`](./webapi.md)
- [`keycloak.md`](./keycloak.md)
- [`../core/security.md`](../core/security.md)
- [`../core/architecture.md`](../core/architecture.md)
