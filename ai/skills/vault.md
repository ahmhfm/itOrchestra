# Skill: HashiCorp Vault (Secrets Management)

## Purpose
Centralized, audited, dynamic secrets management for every workload. Source of truth for all credentials, certificates, and configuration secrets.

## Architecture Role
The single secrets store. Connection strings (MSSQL, Redis), API keys, signing keys, OAuth client secrets, TLS certificates — all live in Vault. Workloads retrieve secrets at runtime via **Vault Agent Injector** or **Vault CSI**.

## Rules

1. **No secret** is committed to Git, `appsettings.json` (production), Docker image, or shell history.
2. **Vault is the only production secrets source.** Local dev uses `dotnet user-secrets`.
3. **Dynamic secrets** preferred (MSSQL credentials minted per workload, TTL ≤ 1 hour).
4. **Static secrets** rotated automatically (where supported); audited on access.
5. **App reads secrets as files** mounted by Vault Agent, exposed to .NET via `IConfiguration` providers.
6. **Approle / Kubernetes auth** for workload-to-Vault authentication; never use root tokens.
7. **Least privilege**: each workload's Vault role grants only what it needs.
8. **Audit logs** sent to OpenSearch and reviewed.

## Best Practices

- Mount secrets via Vault Agent Injector annotations on the Pod spec — the agent writes files to `/vault/secrets/`.
- Configure .NET to watch the mounted file and reload `IOptionsMonitor<T>` on change.
- Use **database engine** for dynamic MSSQL credentials.
- Use **PKI engine** for short-lived TLS certificates (Linkerd integration via cert-manager).
- Use **transit engine** for encryption-as-a-service when applications need crypto without holding keys.
- Use **versioned KV v2** for static secrets (with rotation policy).

## Anti-Patterns

| Don't | Do |
|---|---|
| Put a secret in `appsettings.Production.json` | Vault-injected file + reload |
| Mount Kubernetes Secret with raw data | Vault Agent / CSI |
| Long-lived static MSSQL credentials | Dynamic credentials, TTL ≤ 1h |
| Single Vault token for the whole cluster | Per-workload Approle |
| Root token in CI | CI uses a scoped Approle with short TTL |
| Print secret values in logs | Mask everywhere |
| Hardcode Vault address in image | Inject via environment |

## Security Requirements

- HTTPS only. Mutual TLS where possible.
- Audit log enabled, forwarded to OpenSearch (immutable index).
- Vault sealed by default; unseal keys split via Shamir's Secret Sharing.
- Auto-unseal via cloud KMS / HSM in production.
- Token TTLs short; renew often.
- Vault Agent Injector pinned to a known version; signed image.
- Workload identity via Kubernetes auth method: ServiceAccount JWT bound to Vault role.

## Performance Guidelines

- Vault Agent caches secrets; renewals happen in the background, not on the request path.
- Reload `IOptionsMonitor` only on file change (no polling).
- For high-throughput services, pre-warm tokens at startup.

## Example Implementations

### Pod annotations (Vault Agent Injector)

```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "orders-api"
    vault.hashicorp.com/agent-inject-secret-db: "database/creds/orders"
    vault.hashicorp.com/agent-inject-template-db: |
      {{- with secret "database/creds/orders" -}}
      ConnectionStrings__Orders=Server=mssql.itorchestra.internal,1433;Database=Orders;User Id={{ .Data.username }};Password={{ .Data.password }};Encrypt=true;TrustServerCertificate=false;
      {{- end }}
    vault.hashicorp.com/agent-inject-secret-redis: "kv/data/orders/redis"
    vault.hashicorp.com/agent-inject-template-redis: |
      {{- with secret "kv/data/orders/redis" -}}
      Redis__ConnectionString={{ .Data.data.connection_string }}
      {{- end }}
    vault.hashicorp.com/agent-inject-secret-keycloak: "kv/data/orders/keycloak"
    vault.hashicorp.com/agent-inject-template-keycloak: |
      {{- with secret "kv/data/orders/keycloak" -}}
      Keycloak__ClientSecret={{ .Data.data.client_secret }}
      {{- end }}
```

### .NET Configuration provider (file-based, watched)

```csharp
public static class VaultConfigExtensions
{
    public static IConfigurationBuilder AddVaultSecrets(this IConfigurationBuilder cfg, string mountPath = "/vault/secrets")
    {
        if (!Directory.Exists(mountPath)) return cfg;

        foreach (var file in Directory.EnumerateFiles(mountPath))
        {
            cfg.AddKeyPerFile(directoryPath: Path.GetDirectoryName(file)!, optional: true);
        }
        return cfg;
    }
}

// Program.cs
builder.Configuration.AddVaultSecrets("/vault/secrets");
```

### Reading via IOptionsMonitor (reload on change)

```csharp
public sealed class DatabaseOptions
{
    public required string Orders { get; init; }
}

builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection("ConnectionStrings"));

public sealed class DbConnectionFactory(IOptionsMonitor<DatabaseOptions> options) : IDbConnectionFactory
{
    public SqlConnection Create() => new(options.CurrentValue.Orders);
}
```

### Vault policy (HCL)

```hcl
# orders-api policy
path "database/creds/orders" {
  capabilities = ["read"]
}

path "kv/data/orders/redis" {
  capabilities = ["read"]
}

path "kv/data/orders/keycloak" {
  capabilities = ["read"]
}

path "transit/encrypt/orders" {
  capabilities = ["update"]
}

path "transit/decrypt/orders" {
  capabilities = ["update"]
}
```

### Kubernetes auth role binding

```bash
vault write auth/kubernetes/role/orders-api \
  bound_service_account_names=orders-api \
  bound_service_account_namespaces=itorchestra-orders \
  policies=orders-api \
  ttl=1h
```

## Integration Rules

- **MSSQL** dynamic creds rotate every hour; Vault Agent renews and rewrites the file; .NET reloads on file change.
- **Redis** TLS connection strings stored as KV v2; updated by ops via Vault UI / CLI.
- **Keycloak** client secrets in KV v2; rotated quarterly.
- **TLS certificates** for non-Linkerd services issued by Vault PKI; renewed by cert-manager.
- **CI/CD** runners use Approle with TTL ≤ 1h; tokens revoked after pipeline ends.

## Checklist

- [ ] No secrets in Git or images.
- [ ] Pod annotated for Vault Agent.
- [ ] Vault role scoped to least privilege.
- [ ] Secrets mounted as files; `IOptionsMonitor` reload wired.
- [ ] Dynamic credentials used where supported.
- [ ] Audit log forwarded to OpenSearch.
- [ ] Auto-unseal via KMS in production.
- [ ] Vault Agent image pinned + signed.

## Related

- [`mssql.md`](./mssql.md)
- [`keycloak.md`](./keycloak.md)
- [`kubernetes.md`](./kubernetes.md)
- [`../core/security.md`](../core/security.md)
