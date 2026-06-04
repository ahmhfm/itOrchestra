# Skill: Redis (Cache + Dynamic Configuration)

## Purpose
Provide a fast, in-memory layer for caching, dynamic configuration, and feature flags. Redis is **the first read source** for these concerns; MSSQL is the source of truth.

## Architecture Role
Shared infrastructure (out of mesh; TLS at transport). Every service reads configuration and hot data from Redis using cache-aside; writes invalidate the cache via events.

## Rules

1. Redis is **mandatory** for runtime configuration and frequently-accessed read data.
2. **Cache-Aside Pattern** for all reads: try cache → on miss, load from MSSQL (via SP) → write back to cache.
3. **MSSQL is the source of truth.** Redis can be flushed at any time without data loss.
4. **Configuration data** flows: write to MSSQL `AppConfig` → publish invalidation event on Redis Streams → consumers update local `IOptionsMonitor<T>`.
5. Use the official **`StackExchange.Redis`** client; do not roll your own.
6. **No business logic in Redis.** Treat it as a cache, not a database.
7. **Connection multiplexer is a singleton** per service.
8. **Authentication required** (ACL + password from Vault); TLS in production.

## Best Practices

- Key naming: `{service}:{aggregate}:{id}:{shape}` (e.g., `orders:order:{guid}:summary`).
- TTLs always set; no permanent keys without explicit reason.
- Use **Hashes** for structured records (cheaper than serializing JSON).
- Use **Sorted Sets** for leaderboards, time-ordered data.
- Use **Streams** for events (see [`redis-streams.md`](./redis-streams.md)).
- Use **Lua scripts** for atomic read-modify-write where appropriate.
- Pipeline commands for batch operations.
- Use `IDistributedCache` from `Microsoft.Extensions.Caching.StackExchangeRedis` for `IOptionsMonitor` + simple key/value caching.

## Anti-Patterns

| Don't | Do |
|---|---|
| Treat Redis as primary store | MSSQL is the source of truth |
| `KEYS *` in production | `SCAN` (cursor-based) |
| `FLUSHALL` (ever) | Targeted `DEL` with explicit reason |
| Long-running blocking ops on shared instance | Run on a dedicated replica or use async commands |
| Store secrets in Redis | Vault is the only secrets store |
| Cache without TTL | Always set TTL |
| New `ConnectionMultiplexer` per call | Singleton, reuse |

## Security Requirements

- TLS-only in production. Self-signed certificates trusted via explicit CA chain.
- ACL users per service with **least-privilege** command sets (`+@read +@hash +@list -@dangerous`).
- Passwords come from Vault; rotation does not require service restart (Vault Agent + reload).
- Network policy: only service Pods can reach Redis; admin access via bastion.
- No PII unmasked in Redis values. Mask or tokenize before storing.

## Performance Guidelines

- Median network latency to Redis < 1 ms inside cluster.
- Use `MGET` / `MSET` for batch reads/writes.
- Avoid mega-keys (> 100 KB single value).
- Use Redis Cluster for shard scale; hashtags (`{...}`) to keep related keys together.
- Use `EXPIRE` instead of polling for TTL.
- Monitor `INFO memory` + `INFO clients` + slowlog.

## Example Implementations

### DI registration (cache-aside helper)

```csharp
builder.Services.AddSingleton<IConnectionMultiplexer>(_ =>
{
    var cs = builder.Configuration["Redis:ConnectionString"]!;   // from Vault
    return ConnectionMultiplexer.Connect(cs);
});

builder.Services.AddStackExchangeRedisCache(o =>
{
    o.Configuration = builder.Configuration["Redis:ConnectionString"];
    o.InstanceName  = "orders:";
});

builder.Services.AddSingleton<ICacheService, RedisCacheService>();
```

### Cache-Aside service

```csharp
public interface ICacheService
{
    Task<T?> GetOrSetAsync<T>(string key, Func<CancellationToken, Task<T?>> loader,
                              TimeSpan ttl, CancellationToken ct);
    Task RemoveAsync(string key, CancellationToken ct);
}

public sealed class RedisCacheService(IConnectionMultiplexer mux, ILogger<RedisCacheService> log) : ICacheService
{
    public async Task<T?> GetOrSetAsync<T>(string key,
        Func<CancellationToken, Task<T?>> loader, TimeSpan ttl, CancellationToken ct)
    {
        var db = mux.GetDatabase();
        var cached = await db.StringGetAsync(key);
        if (cached.HasValue)
        {
            try { return JsonSerializer.Deserialize<T>(cached!); }
            catch (Exception ex) { log.LogWarning(ex, "Cache deserialize failed for {Key}", key); }
        }

        var fresh = await loader(ct);
        if (fresh is null) return default;

        var payload = JsonSerializer.SerializeToUtf8Bytes(fresh);
        await db.StringSetAsync(key, payload, ttl);
        return fresh;
    }

    public Task RemoveAsync(string key, CancellationToken ct) =>
        mux.GetDatabase().KeyDeleteAsync(key);
}
```

### Configuration source via Redis + MSSQL

```csharp
public sealed class AppConfigOptions
{
    public required Dictionary<string, string> Values { get; init; }
}

public sealed class AppConfigSource(ICacheService cache, IDbConnectionFactory factory)
{
    public Task<AppConfigOptions> LoadAsync(CancellationToken ct) =>
        cache.GetOrSetAsync<AppConfigOptions>(
            key: "config:appsettings",
            loader: async _ =>
            {
                await using var conn = factory.Create();
                await conn.OpenAsync(ct);
                await using var cmd = new SqlCommand("sp_Config_Get_AppSettings", conn)
                { CommandType = CommandType.StoredProcedure };

                await using var r = await cmd.ExecuteReaderAsync(ct);
                var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                while (await r.ReadAsync(ct)) dict[r.GetString(0)] = r.GetString(1);
                return new AppConfigOptions { Values = dict };
            },
            ttl: TimeSpan.FromMinutes(5),
            ct: ct)!;
}
```

## Integration Rules

- Reads always hit Redis first (Cache-Aside).
- Writes go to MSSQL via SP, then publish an `invalidate:{key}` event on Redis Streams; consumers `DEL` the affected key.
- For feature flags, use `Microsoft.FeatureManagement` backed by an `IFeatureDefinitionProvider` that reads from Redis (with MSSQL fallback).
- Hangfire uses its own MSSQL schema, not Redis (this is intentional — durability of jobs matters more than speed). See [`hangfire.md`](./hangfire.md).

## Checklist

- [ ] Connection multiplexer is a singleton.
- [ ] All keys carry a TTL.
- [ ] Cache-aside used for reads; events used for invalidation.
- [ ] TLS to Redis enabled.
- [ ] ACL user with least privilege per service.
- [ ] No PII unmasked.
- [ ] Slowlog and memory monitored.
- [ ] `SCAN` instead of `KEYS`.

## Related

- [`redis-streams.md`](./redis-streams.md)
- [`mssql.md`](./mssql.md)
- [`vault.md`](./vault.md)
