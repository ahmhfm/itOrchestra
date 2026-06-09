#!/usr/bin/env bash
# itOrchestra - Phase 0.10 verification (CrewAI multi-agent orchestration).
# Checks: ns-crewai meshed (linkerd-proxy injected); pod Ready; strict external isolation
# (no LoadBalancer/NodePort); endpoint mirrored into Vault; and the full gRPC flow exercised
# in-pod (Health, ListAgents=7, approval-gated SubmitTask -> PENDING_APPROVAL, ApproveAction ->
# EXECUTED, audit read-back, RAG Query). Stored-procedure-only audit is implied by the flow.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="ns-crewai"
VAULT_NS="vault"
SMOKE="${SCRIPT_DIR}/../k8s/crewai/scripts/grpc_smoke.py"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# Pick a Running pod (a prior rollout may leave a terminated/Completed pod around).
POD="$(kubectl -n "${NS}" get pod -l app=crewai --field-selector=status.phase=Running -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"

echo "== 1) ns-crewai is meshed (linkerd-proxy injected) =="
# Linkerd may inject the proxy as a native sidecar (initContainers w/ restartPolicy=Always),
# so check both container lists.
C="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.containers[*].name} {.spec.initContainers[*].name}' 2>/dev/null)"
case " ${C} " in *linkerd-proxy*) ok "linkerd-proxy injected (in mesh)" ;; *) bad "no linkerd-proxy (expected meshed)" ;; esac

echo "== 2) CrewAI pod Ready + dedicated ServiceAccount =="
R="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[ "${R}" = "True" ] && ok "crewai pod Ready" || bad "crewai pod not Ready (status='${R}')"
SA="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)"
[ "${SA}" = "crewai" ] && ok "runs as dedicated ServiceAccount 'crewai' (not default)" || bad "pod SA='${SA}' (expected 'crewai')"

echo "== 3) Strict external isolation =="
EXT="$(kubectl -n "${NS}" get svc -o jsonpath='{range .items[*]}{.spec.type}{"\n"}{end}' 2>/dev/null | grep -E 'LoadBalancer|NodePort' || true)"
[ -z "${EXT}" ] && ok "no LoadBalancer/NodePort Service (internal only)" || bad "external Service type found: ${EXT}"
kubectl -n "${NS}" get networkpolicy default-deny-all >/dev/null 2>&1 && ok "default-deny NetworkPolicy present" || bad "default-deny NetworkPolicy missing"

echo "== 4) Endpoint mirrored into Vault =="
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  EP="$(kubectl -n "${VAULT_NS}" exec -i vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${ROOT_TOKEN}" \
        vault kv get -field=grpc-endpoint secret/itorchestra/shared/crewai 2>/dev/null | tr -d '\r')"
  [ "${EP}" = "crewai.ns-crewai.svc.cluster.local:50051" ] && ok "Vault secret/itorchestra/shared/crewai matches" \
        || bad "Vault endpoint mismatch ('${EP}')"
else
  bad "could not read Vault root token (Phase 0.5?)"
fi

echo "== 5) gRPC flow (in-pod: Health / ListAgents / approval / audit / RAG) =="
if [ -z "${POD}" ]; then
  bad "no crewai pod to exec into"
else
  OUT="$(kubectl -n "${NS}" exec -i "${POD}" -c crewai -- python - < "${SMOKE}" 2>&1)"
  echo "${OUT}" | grep -E '^\s*\[(PASS|FAIL)\]' || true
  TOT="$(echo "${OUT}" | grep -E '^TOTALS ' | tail -n1)"
  if [ -n "${TOT}" ]; then
    PASS=$((PASS + $(echo "${TOT}" | awk '{print $2}')))
    FAIL=$((FAIL + $(echo "${TOT}" | awk '{print $3}')))
  else
    bad "in-pod gRPC smoke test did not complete"
    echo "${OUT}" | tail -n 20
  fi
fi

echo "========================================================"
echo "Phase 0.10 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
