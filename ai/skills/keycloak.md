# Skill: Keycloak (Identity & Access Management)

## Purpose
Provide centralized identity for users and services: SSO, JWT issuance, OAuth 2.0 / OIDC flows, role and permission management.

## Architecture Role
The single identity provider. Every authenticated request — external or internal — carries a JWT minted by Keycloak. Validated at YARP and re-validated at each service.

## Rules

1. **Keycloak is the only identity provider.** No service implements its own login or token issuance.
2. **JWT only**, RS256, short-lived (≤ 15 minutes). Refresh tokens stored client-side.
3. **One realm per environment** (`itorchestra-dev`, `itorchestra-staging`, `itorchestra-prod`).
4. **Clients defined per audience:** `api-gateway` (public confidential client), `wpf-app`, `maui-app`, plus internal service-to-service clients.
5. **Roles** defined in Keycloak; never in service databases.
6. **JWT validation** happens twice for external traffic: at YARP, then at each service.
7. **Service-to-service** calls use **client credentials** grant; the resulting token is treated like any other JWT.
8. **No secrets in JWT** — never put PII or sensitive claims that should not be exposed to the client.

## Best Practices

- Use **`Authority`** = realm URL; auto-discover via `.well-known/openid-configuration`.
- Validate `iss`, `aud`, signature, `exp`, and required custom claims (`tenant_id`, `roles`).
- For browser flows, use **Authorization Code + PKCE**.
- For confidential apps with no human, use **client_credentials**.
- For mobile/desktop, use **Authorization Code + PKCE** (no implicit, no resource-owner password).
- Use **token exchange** (RFC 8693) to switch from user token to a service-account token for downstream calls when scope must change.
- Configure short token TTL + refresh tokens with rotation enabled.

## Anti-Patterns

| Don't | Do |
|---|---|
| Re-implement login per service | Always Keycloak |
| Long-lived access tokens (1 day+) | Max 15 minutes |
| Mix Basic Auth and JWT | JWT only for prod |
| Send JWT in URL | Authorization header only |
| Skip `aud` validation | Always validate audience |
| Trust client-provided claims without validation | Always re-validate at the service |
| Hardcode signing keys | Auto-discover from JWKS |

## Security Requirements

- **HTTPS only** for any Keycloak endpoint.
- **Clock skew** tolerance ≤ 30 seconds.
- **JWKS** cached and refreshed every hour (or on signature failure).
- **Required claims** (presence + value):
  - `iss` matches the realm URL.
  - `aud` includes the service's audience.
  - `exp` in the future.
  - `sub` non-empty.
  - `tenant_id` present where applicable.
  - `roles` array present.
- **Audit** every authentication event (success and failure) at Keycloak + at the service.
- **MFA** enabled by default for administrative users; configurable per realm role.
- **Account lockout** after N failed attempts.

## Performance Guidelines

- Cache JWKS in memory; reload async on key rotation.
- Use connection pooling against Keycloak for client_credentials flows.
- Pre-issue service tokens (cached) with refresh 1 minute before `exp`.

## Example Implementations

### Web API JWT validation

```csharp
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.Authority = builder.Configuration["Keycloak:Authority"];   // https://kc.itorchestra.com/realms/itorchestra-prod
        o.Audience  = builder.Configuration["Keycloak:Audience"];    // orders-api
        o.RequireHttpsMetadata = true;
        o.TokenValidationParameters = new()
        {
            ValidateIssuer           = true,
            ValidateAudience         = true,
            ValidateLifetime         = true,
            ValidateIssuerSigningKey = true,
            ClockSkew                = TimeSpan.FromSeconds(30),
            NameClaimType            = "preferred_username",
            RoleClaimType            = "roles"
        };
        o.MapInboundClaims = false;
    });

builder.Services.AddAuthorization(o =>
{
    o.AddPolicy("OrdersReader", p => p.RequireRole("orders.read"));
    o.AddPolicy("OrdersWriter", p => p.RequireRole("orders.write"));
});
```

### gRPC propagation

```csharp
public sealed class JwtForwardingInterceptor(IHttpContextAccessor http) : Interceptor
{
    public override AsyncUnaryCall<TRes> AsyncUnaryCall<TReq, TRes>(
        TReq request, ClientInterceptorContext<TReq, TRes> context,
        AsyncUnaryCallContinuation<TReq, TRes> continuation)
    {
        var token = http.HttpContext?.Request.Headers["Authorization"].FirstOrDefault();
        if (!string.IsNullOrEmpty(token))
        {
            var headers = context.Options.Headers ?? new Metadata();
            headers.Add("Authorization", token);
            var newOptions = context.Options.WithHeaders(headers);
            context = new ClientInterceptorContext<TReq, TRes>(
                context.Method, context.Host, newOptions);
        }
        return continuation(request, context);
    }
}
```

### Service-to-service (client_credentials)

```csharp
public sealed class KeycloakTokenClient(HttpClient http, IOptions<KeycloakClientOptions> opts)
{
    private (string AccessToken, DateTime ExpiresAt)? _cached;
    private readonly SemaphoreSlim _lock = new(1, 1);

    public async Task<string> GetServiceTokenAsync(CancellationToken ct)
    {
        if (_cached is { } v && v.ExpiresAt > DateTime.UtcNow.AddSeconds(60))
            return v.AccessToken;

        await _lock.WaitAsync(ct);
        try
        {
            if (_cached is { } again && again.ExpiresAt > DateTime.UtcNow.AddSeconds(60))
                return again.AccessToken;

            var o = opts.Value;
            using var req = new HttpRequestMessage(HttpMethod.Post, $"{o.Authority}/protocol/openid-connect/token")
            {
                Content = new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["grant_type"]    = "client_credentials",
                    ["client_id"]     = o.ClientId,
                    ["client_secret"] = o.ClientSecret    // sourced from Vault
                })
            };
            using var resp = await http.SendAsync(req, ct);
            resp.EnsureSuccessStatusCode();

            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
            var token   = doc.RootElement.GetProperty("access_token").GetString()!;
            var seconds = doc.RootElement.GetProperty("expires_in").GetInt32();
            _cached = (token, DateTime.UtcNow.AddSeconds(seconds));
            return token;
        }
        finally { _lock.Release(); }
    }
}
```

## Integration Rules

- **YARP** validates JWT first; configured with same authority/audience.
- **Service** also validates JWT (defense in depth).
- **gRPC** clients forward the inbound `Authorization` header to downstream services.
- **Worker / Hangfire** jobs that initiate outbound calls use a service-account JWT obtained via `KeycloakTokenClient`.
- **Mobile / Desktop** clients use OIDC + PKCE; tokens stored in OS secure storage.

## Checklist

- [ ] Single realm per environment.
- [ ] Authority + audience configured per service.
- [ ] Token TTL ≤ 15 minutes.
- [ ] Refresh tokens rotated on use.
- [ ] Required claims validated.
- [ ] `[Authorize]` default; policies declared per resource.
- [ ] Service-to-service uses client_credentials.
- [ ] MFA enabled for admins.
- [ ] Account lockout configured.
- [ ] Audit logs forwarded to OpenSearch.

## Related

- [`vault.md`](./vault.md)
- [`yarp.md`](./yarp.md)
- [`webapi.md`](./webapi.md)
- [`grpc.md`](./grpc.md)
- [`../core/security.md`](../core/security.md)
