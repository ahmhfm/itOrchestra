# Runbook - Phase 0.6: Redis (Cache + Streams)

This runbook covers deploying **Redis** - the platform's in-memory layer for caching, dynamic
configuration, and **Streams** (events / eventual consistency / Sagas). Redis is **the first
read source** (Cache-Aside); **MSSQL is the source of truth** and Redis can be flushed without
data loss for cached data. Streams data is made durable via AOF.

> Prerequisites: Phases 0.1-0.5 healthy (cluster, Longhorn StorageClass, Vault running - the
> Redis password is mirrored into Vault KV).

## Scope of 0.6 (dev)

Implemented now:

- **Single-node Redis 8** (`redis:8.8.0`) StatefulSet, non-root (uid 999), `protected-mode`.
- **AOF persistence** (`appendonly yes`, `appendfsync everysec`) + periodic RDB snapshots on a
  2Gi **Longhorn** PVC.
- **AUTH** required (`--requirepass` from the `redis-auth` Secret).
- **Eviction** `maxmemory 384mb` / `volatile-lru`: only keys with a TTL (cache entries) are
  evicted; Streams (no TTL) are never evicted.
- **Guardrails**: `FLUSHALL` / `FLUSHDB` disabled (rename to "").
- **Out of the Linkerd mesh** (shared infra): the `redis` namespace is annotated
  `linkerd.io/inject: disabled`.
- **Internal only**: headless `redis` Service; clients use `redis.redis.svc.cluster.local:6379`.
  No LoadBalancer, no YARP route.
- **Vault mirror**: the password is written to `secret/itorchestra/shared/redis`
  (`host`, `port`, `password`, ready-made `connection-string`).

Deferred: TLS at transport, per-service **ACL users** (least privilege), HA (Sentinel/Cluster),
and password rotation from Vault without restart (done as services onboard / in prod).

## Decisions (this environment)

- **Hand-rolled StatefulSet** (official image) - consistent with the Keycloak MSSQL approach,
  full control, no Bitnami licensing churn.
- **Persistent (AOF + RDB on Longhorn)** - Streams need durability across restarts.
- **Out of mesh + AUTH** in dev; **TLS + ACL** in prod (per `redis.md`).

## Deploy (dev)

```bash
cd ~/itOrchestra/platform
# only if files were copied from Windows: dos2unix bootstrap/*.sh k8s/redis/*.sh
bash bootstrap/05-redis-dev.sh
```

This runs `k8s/redis/install-dev.sh` (ensure secret -> apply ConfigMap/Service/StatefulSet ->
wait rollout -> mirror password into Vault) then `bootstrap/verify-0.6.sh`.

## Verify

```bash
bash bootstrap/verify-0.6.sh        # expect: 8 passed, 0 failed
```

Checks: redis-0 Ready; no linkerd-proxy (out of mesh); AUTH enforced (unauthenticated PING
rejected, authenticated PING -> PONG); `appendonly=yes`; a SET/GET roundtrip; an XADD/XLEN
Streams roundtrip; and the password mirrored into Vault KV matches.

## Operate

```bash
# Password (DEV ONLY):
kubectl -n redis get secret redis-auth -o jsonpath='{.data.password}' | base64 -d; echo

# Interactive CLI inside the pod:
kubectl -n redis exec -it redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning'

# From your laptop (port-forward):
kubectl -n redis port-forward svc/redis 6379:6379
redis-cli -a <password> -p 6379 ping

# Read the connection string from Vault (what services consume):
kubectl -n vault exec -it vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN=<root-token> vault kv get secret/itorchestra/shared/redis
```

### How a service consumes Redis (later phases)

The connection string comes from Vault (Agent-injected file). In .NET, register a singleton
`IConnectionMultiplexer` and use `IDistributedCache` for cache-aside + `IOptionsMonitor`
backing; use Streams for events. See `ai/skills/redis.md` and `ai/skills/redis-streams.md`.

App namespaces (default-deny) will need an egress NetworkPolicy to `redis/redis:6379` - added
per service when it onboards.

## Teardown (dev)

```bash
kubectl -n redis delete statefulset redis
kubectl -n redis delete svc redis
kubectl -n redis delete configmap redis-config
kubectl -n redis delete pvc -l app=redis        # deletes the Longhorn PVC (all data: cache + streams)
kubectl -n redis delete secret redis-auth
```

> Deleting the PVC destroys all Redis data (cache is rebuildable from MSSQL; Streams data is
> lost). The Vault secret `secret/itorchestra/shared/redis` is left in place.
