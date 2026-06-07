# Runbook - Phase 0.7: SQL Server Always On Availability Group (reference)

This runbook covers deploying a **reference** SQL Server 2022 **Always On Availability Group**
- the reusable high-availability database pattern. It is a **clusterless / read-scale** AG
(`CLUSTER_TYPE = NONE`): two replicas replicate over certificate-authenticated mirroring
endpoints with automatic seeding, and failover is **manual**. Per the platform's
Database-per-Service rule, each microservice later instantiates its **own** AG-backed instance
with its own private database; this phase establishes and proves the pattern.

> Prerequisites: Phases 0.1-0.6 healthy (cluster, Longhorn StorageClass, Vault running).
> Resource note: each SQL Server replica needs **>= 2 GiB RAM**; two replicas + the existing
> Keycloak MSSQL means ~6 GiB just for SQL - make sure the VM has headroom.

## Scope of 0.7 (dev)

Implemented now:

- **Two SQL Server 2022 replicas** (`mssql-ag-0` = initial primary, `mssql-ag-1` = secondary)
  as a StatefulSet, non-root (uid 10001), Longhorn PVCs, **out of the Linkerd mesh**.
- **HADR enabled** via a mounted `mssql.conf` (`hadr.hadrenabled = 1`).
- **Clusterless AG `ag1`** (`CLUSTER_TYPE = NONE`, `SYNCHRONOUS_COMMIT`, `SEEDING_MODE = AUTOMATIC`,
  `FAILOVER_MODE = MANUAL`, secondary `ALLOW_CONNECTIONS = ALL` for read-scale).
- **Certificate-authenticated mirroring endpoints** on port 5022 (shared `dbm_certificate`
  generated on the primary, backed up, and restored on the secondary).
- **Demo database** `platformref` added to the AG (proves automatic seeding + replication).
- **Service entry points**: `mssql-ag-primary` (RW, pinned to `mssql-ag-0`),
  `mssql-ag-secondary` (RO, pinned to `mssql-ag-1`), plus the headless `mssql-ag`.
- **Vault mirror**: `secret/itorchestra/shared/mssql-ag` (SA user/password + RW/RO connection
  strings).

Deferred: automatic failover (DH2i / Pacemaker), a real listener/VIP, real TLS certs,
per-service logins (EXEC-on-SPs only), Row-Level Security, and 3+ replicas across nodes.

## Decisions (this environment)

- **Real 2-replica AG now** (clusterless read-scale), **manual** failover - feasible on a
  single-node dev cluster without a cluster manager.
- **Out of the mesh** - DB traffic (TDS 1433 + AG endpoint 5022) is plain TCP; the architecture
  secures it with TLS at transport. Meshing would need opaque-ports for both and complicates
  replication.
- **Reference pattern** - per-service AG-backed instances reuse these manifests/scripts.

## Deploy (dev)

```bash
cd ~/itOrchestra/platform
# only if files were copied from Windows: dos2unix bootstrap/*.sh k8s/mssql-ag/*.sh
bash bootstrap/06-mssql-ag-dev.sh
```

The installer: ensures secrets -> applies ConfigMap/Services/StatefulSet -> waits for both
replicas -> on the primary creates the master key + `dbm_certificate` (and backs it up) ->
transfers the cert to the secondary -> creates the mirroring endpoint + certificate login on
both -> creates the AG on the primary -> joins it on the secondary -> adds `platformref` to the
AG -> mirrors connection details into Vault. It is idempotent (guarded with `IF NOT EXISTS`).

## Verify

```bash
bash bootstrap/verify-0.7.sh        # expect: 8 passed, 0 failed
```

Checks: both replicas Ready; out of mesh; AG `ag1` exists with 2 replicas; the secondary is
`CONNECTED` and a database is `SYNCHRONIZED`; and `platformref` is `ONLINE` on the secondary.

## Operate

```bash
# SA password (DEV ONLY):
kubectl -n mssql get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d; echo

# AG dashboard query (on the primary):
SA=$(kubectl -n mssql get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d)
kubectl -n mssql exec -it mssql-ag-0 -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA" -C \
  -Q "SELECT ag.name, ar.replica_server_name, ars.role_desc, ars.connected_state_desc, drs.synchronization_state_desc
      FROM sys.availability_groups ag
      JOIN sys.availability_replicas ar ON ag.group_id=ar.group_id
      JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id=ars.replica_id
      LEFT JOIN sys.dm_hadr_database_replica_states drs ON ars.replica_id=drs.replica_id;"
```

### Manual failover (dev)

Clusterless AGs have no automatic failover. To promote the secondary:

```bash
SA=$(kubectl -n mssql get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d)
# On the target (mssql-ag-1): force failover (allow potential data loss only if needed).
kubectl -n mssql exec -it mssql-ag-1 -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA" -C \
  -Q "ALTER AVAILABILITY GROUP [ag1] FAILOVER;"     # or FORCE_FAILOVER_ALLOW_DATA_LOSS if primary is down
# Repoint the RW Service to the new primary:
kubectl -n mssql patch svc mssql-ag-primary -p '{"spec":{"selector":{"app":"mssql-ag","statefulset.kubernetes.io/pod-name":"mssql-ag-1"}}}'
```

### How a service consumes this (later phases)

Each service gets its **own** AG-backed instance (copy `k8s/mssql-ag/` with a service-specific
name/namespace), its own private database + login (`EXEC` on Stored Procedures only), and a
**Vault-sourced** connection string (`ApplicationIntent=ReadOnly` for read replicas). All SQL
lives in the database (SPs/Views/Functions); the app uses ADO.NET only. See `ai/skills/mssql.md`.

## Teardown (dev)

```bash
kubectl -n mssql delete statefulset mssql-ag
kubectl -n mssql delete svc mssql-ag mssql-ag-primary mssql-ag-secondary
kubectl -n mssql delete configmap mssql-ag-conf
kubectl -n mssql delete pvc -l app=mssql-ag      # deletes both replicas' data (AG + platformref)
kubectl -n mssql delete secret mssql-ag-secret
```

> Deleting the PVCs destroys the AG and all databases on it. The Vault secret
> `secret/itorchestra/shared/mssql-ag` is left in place.
