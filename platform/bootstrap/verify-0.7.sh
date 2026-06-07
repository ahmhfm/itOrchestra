#!/usr/bin/env bash
# itOrchestra - Phase 0.7 verification (SQL Server Always On AG, clusterless / read-scale).
# Checks: both replicas Ready, out of mesh, AG exists with 2 replicas, the secondary is
# CONNECTED + SYNCHRONIZED, and the demo database (platformref) replicated to the secondary.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="mssql"
AG="ag1"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SA_PW="$(kubectl -n "${NS}" get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' 2>/dev/null | base64 -d)"
scal() { kubectl -n "${NS}" exec -i "$1" -- "${SQLCMD}" -S localhost -U sa -P "${SA_PW}" -C -b -h -1 -W -Q "SET NOCOUNT ON; $2" 2>/dev/null | tr -d '\r' | head -n1; }

echo "== 1) Both replicas Ready =="
for n in 0 1; do
  R="$(kubectl -n "${NS}" get pod "mssql-ag-${n}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [ "${R}" = "True" ] && ok "mssql-ag-${n} Ready" || bad "mssql-ag-${n} not Ready (Ready='${R}')"
done

echo "== 2) Out of mesh (no linkerd-proxy) =="
C="$(kubectl -n "${NS}" get pod mssql-ag-0 -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null)"
case " ${C} " in *linkerd-proxy*) bad "linkerd-proxy injected" ;; *) ok "no linkerd-proxy (out of mesh)" ;; esac

echo "== 3) Availability Group exists =="
AGN="$(scal mssql-ag-0 "SELECT COUNT(*) FROM sys.availability_groups WHERE name='${AG}'")"
[ "${AGN}" = "1" ] && ok "AG '${AG}' present on primary" || bad "AG '${AG}' missing (count='${AGN}')"

echo "== 4) Two replicas configured =="
REPLICAS="$(scal mssql-ag-0 "SELECT COUNT(*) FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ar.group_id=ag.group_id WHERE ag.name='${AG}'")"
[ "${REPLICAS}" = "2" ] && ok "2 replicas in AG" || bad "expected 2 replicas (got '${REPLICAS}')"

echo "== 5) Secondary CONNECTED + SYNCHRONIZED (retry up to ~60s) =="
SYNC=""; CONN=""
for i in $(seq 1 12); do
  CONN="$(scal mssql-ag-0 "SELECT COUNT(*) FROM sys.dm_hadr_availability_replica_states WHERE is_local=0 AND connected_state_desc='CONNECTED'")"
  SYNC="$(scal mssql-ag-0 "SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states WHERE is_local=0 AND synchronization_state_desc='SYNCHRONIZED'")"
  { [ "${CONN}" = "1" ] && [ "${SYNC}" -ge 1 ] 2>/dev/null; } && break
  sleep 5
done
[ "${CONN}" = "1" ] && ok "secondary replica CONNECTED" || bad "secondary not connected (count='${CONN}')"
[ "${SYNC}" -ge 1 ] 2>/dev/null && ok "database SYNCHRONIZED on secondary" || bad "no SYNCHRONIZED db (count='${SYNC}')"

echo "== 6) Demo database replicated to the secondary =="
DBSTATE=""
for i in $(seq 1 12); do
  DBSTATE="$(scal mssql-ag-1 "SELECT state_desc FROM sys.databases WHERE name='platformref'")"
  [ "${DBSTATE}" = "ONLINE" ] && break
  sleep 5
done
[ "${DBSTATE}" = "ONLINE" ] && ok "platformref ONLINE on secondary (replicated)" || bad "platformref not online on secondary (state='${DBSTATE}')"

echo "========================================================"
echo "Phase 0.7 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
