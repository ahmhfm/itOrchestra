#!/usr/bin/env bash
# Deploy the reference SQL Server Always On AG (Phase 0.7) into the 'mssql' namespace:
# a two-replica CLUSTERLESS (read-scale) Availability Group with certificate-authenticated
# mirroring endpoints, automatic seeding, and MANUAL failover. A demo database (platformref)
# is added to the AG to prove replication. The SA password is mirrored into Vault KV.
#
# Topology: mssql-ag-0 = initial PRIMARY, mssql-ag-1 = SECONDARY (read-only allowed).
# This is the reusable pattern; each microservice instantiates its own AG-backed instance.
#
# Idempotent: secrets/certs/AG objects are guarded with IF NOT EXISTS and reused on re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="mssql"
VAULT_NS="vault"
AG="ag1"
HEADLESS="mssql-ag.mssql.svc.cluster.local"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

# SQL-Server-complexity-safe password (upper+lower+digit+special, hex tail).
gen_pw() { echo "Aa1!$(openssl rand -hex 20)"; }

echo "==> [0.7/mssql-ag] Ensuring the 'mssql' namespace (baseline PSA, out of mesh)"
# Self-contained: the namespace is also defined in k8s/namespaces/namespaces.yaml, but we
# create it here so this phase runs without re-applying the whole namespaces manifest.
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: mssql
  labels:
    name: mssql
    pod-security.kubernetes.io/enforce: baseline
  annotations:
    linkerd.io/inject: disabled
EOF

echo "==> Ensuring the mssql-ag-secret (SA + cert passwords)"
if ! kubectl -n "${NS}" get secret mssql-ag-secret >/dev/null 2>&1; then
  kubectl -n "${NS}" create secret generic mssql-ag-secret \
    --from-literal=sa-password="$(gen_pw)" \
    --from-literal=cert-password="$(gen_pw)"
  echo "    created secret mssql-ag-secret"
else
  echo "    secret mssql-ag-secret already exists (skip)"
fi
SA_PW="$(kubectl -n "${NS}" get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d)"
CERT_PW="$(kubectl -n "${NS}" get secret mssql-ag-secret -o jsonpath='{.data.cert-password}' | base64 -d)"

echo "==> Applying manifests (ConfigMap, Services, StatefulSet)"
kubectl apply -f "${SCRIPT_DIR}/mssql-conf-configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/statefulset.yaml"

echo "==> Waiting for both replicas to be Ready (first boot pulls the image + inits system DBs)"
kubectl -n "${NS}" rollout status statefulset/mssql-ag --timeout=600s

# Run a T-SQL batch on a pod as sa. Args: <pod> <query> [db]
sqlq() {
  kubectl -n "${NS}" exec -i "$1" -- "${SQLCMD}" -S localhost -U sa -P "${SA_PW}" -C -b -d "${3:-master}" -Q "$2"
}
# Run a scalar query and echo a trimmed single value. Args: <pod> <query>
sqlscalar() {
  kubectl -n "${NS}" exec -i "$1" -- "${SQLCMD}" -S localhost -U sa -P "${SA_PW}" -C -b -h -1 -W -Q "SET NOCOUNT ON; $2" | tr -d '\r' | head -n1
}

echo "==> [PRIMARY] Master key + AG certificate (+ backup to disk)"
sqlq mssql-ag-0 "
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name='##MS_DatabaseMasterKey##')
  CREATE MASTER KEY ENCRYPTION BY PASSWORD = '${CERT_PW}';
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name='dbm_certificate')
BEGIN
  CREATE CERTIFICATE dbm_certificate WITH SUBJECT = 'itOrchestra AG mirroring certificate';
  BACKUP CERTIFICATE dbm_certificate
    TO FILE = '/var/opt/mssql/data/dbm_certificate.cer'
    WITH PRIVATE KEY (FILE = '/var/opt/mssql/data/dbm_certificate.pvk',
                      ENCRYPTION BY PASSWORD = '${CERT_PW}');
END
"

echo "==> Transferring the certificate to the SECONDARY"
kubectl -n "${NS}" exec mssql-ag-0 -- base64 /var/opt/mssql/data/dbm_certificate.cer > /tmp/dbm_certificate.cer.b64
kubectl -n "${NS}" exec mssql-ag-0 -- base64 /var/opt/mssql/data/dbm_certificate.pvk > /tmp/dbm_certificate.pvk.b64
base64 -d /tmp/dbm_certificate.cer.b64 | kubectl -n "${NS}" exec -i mssql-ag-1 -- sh -c 'cat > /var/opt/mssql/data/dbm_certificate.cer'
base64 -d /tmp/dbm_certificate.pvk.b64 | kubectl -n "${NS}" exec -i mssql-ag-1 -- sh -c 'cat > /var/opt/mssql/data/dbm_certificate.pvk'
rm -f /tmp/dbm_certificate.cer.b64 /tmp/dbm_certificate.pvk.b64

echo "==> [SECONDARY] Master key + AG certificate (from file)"
sqlq mssql-ag-1 "
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name='##MS_DatabaseMasterKey##')
  CREATE MASTER KEY ENCRYPTION BY PASSWORD = '${CERT_PW}';
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name='dbm_certificate')
  CREATE CERTIFICATE dbm_certificate
    FROM FILE = '/var/opt/mssql/data/dbm_certificate.cer'
    WITH PRIVATE KEY (FILE = '/var/opt/mssql/data/dbm_certificate.pvk',
                      DECRYPTION BY PASSWORD = '${CERT_PW}');
"

echo "==> [BOTH] Mirroring endpoint + certificate login"
ENDPOINT_SQL="
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name='Hadr_endpoint')
  CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = CERTIFICATE dbm_certificate,
                            ENCRYPTION = REQUIRED ALGORITHM AES);
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='dbm_login')
  CREATE LOGIN dbm_login FROM CERTIFICATE dbm_certificate;
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [dbm_login];
"
sqlq mssql-ag-0 "${ENDPOINT_SQL}"
sqlq mssql-ag-1 "${ENDPOINT_SQL}"

echo "==> Resolving replica server names (@@SERVERNAME)"
P_NAME="$(sqlscalar mssql-ag-0 "SELECT @@SERVERNAME")"
S_NAME="$(sqlscalar mssql-ag-1 "SELECT @@SERVERNAME")"
echo "    primary='${P_NAME}'  secondary='${S_NAME}'"
[ -n "${P_NAME}" ] && [ -n "${S_NAME}" ] || { echo "    !! failed to resolve server names" >&2; exit 1; }

echo "==> [PRIMARY] Creating the Availability Group (CLUSTER_TYPE=NONE)"
sqlq mssql-ag-0 "
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name='${AG}')
  CREATE AVAILABILITY GROUP [${AG}]
    WITH (CLUSTER_TYPE = NONE)
    FOR REPLICA ON
      N'${P_NAME}' WITH (
        ENDPOINT_URL = N'tcp://mssql-ag-0.${HEADLESS}:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)
      ),
      N'${S_NAME}' WITH (
        ENDPOINT_URL = N'tcp://mssql-ag-1.${HEADLESS}:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)
      );
"

echo "==> [SECONDARY] Joining the AG + granting CREATE ANY DATABASE (for auto-seeding)"
sqlq mssql-ag-1 "
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name='${AG}')
BEGIN
  ALTER AVAILABILITY GROUP [${AG}] JOIN WITH (CLUSTER_TYPE = NONE);
  ALTER AVAILABILITY GROUP [${AG}] GRANT CREATE ANY DATABASE;
END
"

echo "==> [PRIMARY] Adding a demo database (platformref) to the AG"
sqlq mssql-ag-0 "
IF DB_ID('platformref') IS NULL
BEGIN
  CREATE DATABASE platformref;
  ALTER DATABASE platformref SET RECOVERY FULL;
END
BACKUP DATABASE platformref TO DISK = N'/var/opt/mssql/data/platformref_seed.bak' WITH FORMAT, INIT;
IF (SELECT group_database_id FROM sys.databases WHERE name='platformref') IS NULL
  ALTER AVAILABILITY GROUP [${AG}] ADD DATABASE [platformref];
"

echo "==> Mirroring AG connection details into Vault (secret/itorchestra/shared/mssql-ag)"
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  kubectl -n "${VAULT_NS}" exec -i vault-0 -- env \
    VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" SA_PW="${SA_PW}" \
    sh -s <<'EOSH'
set -e
vault kv put secret/itorchestra/shared/mssql-ag \
  sa-user="sa" \
  sa-password="$SA_PW" \
  primary-connection-string="Server=mssql-ag-primary.mssql.svc.cluster.local,1433;User Id=sa;Password=$SA_PW;Encrypt=true;TrustServerCertificate=true;" \
  secondary-connection-string="Server=mssql-ag-secondary.mssql.svc.cluster.local,1433;User Id=sa;Password=$SA_PW;ApplicationIntent=ReadOnly;Encrypt=true;TrustServerCertificate=true;"
echo "  seeded: secret/itorchestra/shared/mssql-ag"
EOSH
else
  echo "    !! could not read Vault root token (Phase 0.5?); skipping Vault mirror" >&2
fi

echo "==> AG state:"
kubectl -n "${NS}" get pods,svc,pvc -o wide
echo "==> [0.7/mssql-ag] Deploy done."
echo "    Primary (RW):    mssql-ag-primary.mssql.svc.cluster.local:1433"
echo "    Secondary (RO):  mssql-ag-secondary.mssql.svc.cluster.local:1433"
echo "    SA password:     kubectl -n ${NS} get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d; echo"
