# Runbook 0.12 - Backup & Disaster Recovery (MinIO + Velero)

This phase adds a backup/restore layer to the platform. **Velero** backs up Kubernetes resources
plus persistent-volume data (kopia File System Backup) to an in-cluster **MinIO** S3 endpoint
whose bytes live on the **VM host disk** (`hostPath`) - so a backup survives loss of Longhorn or
the whole cluster. Application consistency for the databases is achieved with Velero **backup
hooks** that run each engine's own snapshot command immediately before the volume is copied.

| Component | Role |
|-----------|------|
| MinIO (`backup` ns) | S3 protocol shim; data on `hostPath` `/srv/itorchestra/backups/minio` |
| Velero server (`backup` ns) | Backup/restore orchestrator; AWS plugin -> MinIO |
| `node-agent` DaemonSet | kopia File System Backup of PV contents |
| `Schedule/daily-full` | 01:00 daily, 7-day retention, app-consistent hooks |
| `sp_Maint_Backup_AllDatabases` | COPY_ONLY MSSQL backup SP (SQL stays in the DB) |

## Install / verify

```bash
cd ~/itOrchestra/platform
bash bootstrap/11-backup-dev.sh
# or, to also run a live backup smoke test (slow):
RUN_BACKUP=1 bash bootstrap/verify-0.12.sh
```

Override defaults via env: `BACKUP_HOSTPATH`, `VELERO_CHART_VERSION`, `MC_IMAGE`.

## What gets backed up

- **Namespaces:** `vault`, `redis`, `mssql`, `keycloak`, `ai`, `observability`, `ns-gateway`, `ns-crewai`.
- **Resources:** all Kubernetes objects in those namespaces (Deployments, StatefulSets, Services,
  Secrets, ConfigMaps, NetworkPolicies, PVCs, ...).
- **Volume data (FSB/kopia):** every pod volume except the auto-skipped ones (secret/configMap/
  hostPath/projected). Includes MSSQL `/var/opt/mssql`, Redis `/data`, Vault `/vault/data`,
  Qdrant, OpenSearch.
- **App-consistent pre-hooks:**
  - **MSSQL** (`mssql-ag-0` only): `EXEC master.dbo.sp_Maint_Backup_AllDatabases` -> writes
    `COPY_ONLY` `.bak` files to `/var/opt/mssql/backups/<db>.bak`, captured by FSB.
  - **Redis:** `SAVE` flushes a fresh `dump.rdb` (AOF is already enabled).

## On-demand backup

```bash
velero backup create manual-$(date +%s) --from-schedule daily-full -n backup
velero backup get -n backup
velero backup describe <name> -n backup --details
```

(No `velero` CLI? `kubectl -n backup get backups.velero.io` shows status; create a `Backup` CR by
hand or install the CLI from the Velero releases page.)

## Disaster-recovery procedures

### A. Restore a single namespace / accidental deletion

```bash
velero restore create --from-backup <backup-name> --include-namespaces ns-crewai -n backup
velero restore describe <restore-name> -n backup --details
```

### B. MSSQL database point-in-time-ish restore

The latest consistent `.bak` per database is on the data volume (and in every Velero backup).
After restoring the `mssql` namespace (or to recover a single DB):

```sql
-- inside mssql-ag-0 (sqlcmd as sa):
RESTORE DATABASE [CrewAiDb] FROM DISK = N'/var/opt/mssql/backups/CrewAiDb.bak' WITH REPLACE, RECOVERY;
```

Then re-add the database to the AG on the primary and let automatic seeding re-hydrate the
secondary (see runbook-0.7.md).

### C. Vault restore

FSB captures `/vault/data` (the Raft store). For a **guaranteed-consistent** Vault backup/restore,
prefer the native snapshot:

```bash
# Backup (run periodically / before risky changes):
ROOT=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.root-token}' | base64 -d)
kubectl -n vault exec -i vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$ROOT \
  vault operator raft snapshot save /vault/data/vault.snap"
# (the snapshot file is then included in the next Velero FSB of /vault/data)

# Restore:
kubectl -n vault exec -i vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$ROOT \
  vault operator raft snapshot restore /vault/data/vault.snap"
```

### D. Full cluster rebuild (worst case)

1. Reinstall the cluster foundation (`bootstrap/00-bootstrap-dev.sh`) and Velero
   (`bootstrap/11-backup-dev.sh`) - the MinIO `hostPath` data is still on the VM disk, so the
   `velero` bucket and its backups are intact.
2. Point Velero at the existing bucket (the install script does this) and list backups:
   `velero backup get -n backup`.
3. Restore namespaces oldest-dependency-first: `vault` -> `redis`/`mssql` -> `keycloak` ->
   `observability`/`ai` -> `ns-gateway`/`ns-crewai`.
4. Re-seal/unseal Vault and re-run the per-phase verify scripts.

> **VM-level DR:** in addition to Velero, the hypervisor VM snapshot (see `runbook-vm-setup.md`)
> remains the fastest whole-node rollback for dev.

## dev vs prod

- **dev:** single MinIO on `hostPath`, one daily schedule, 7-day retention, root MinIO user.
- **prod:** off-cluster object storage (dedicated MinIO/S3 or an NFS/appliance), more frequent
  schedules + longer retention, encrypted backups, per-namespace RBAC for restore, periodic
  restore drills, and a scheduled `vault operator raft snapshot` + MSSQL log backups for true
  point-in-time recovery.

## Teardown

```bash
helm -n backup uninstall velero
kubectl delete ns backup            # keeps the hostPath data (PV reclaimPolicy: Retain)
# To also erase the backups: rm -rf /srv/itorchestra/backups/minio  (on the VM)
```
