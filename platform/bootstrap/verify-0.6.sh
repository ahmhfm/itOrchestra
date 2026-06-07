#!/usr/bin/env bash
# itOrchestra - Phase 0.6 verification (Redis: cache + streams).
# Checks: redis-0 Ready, NOT meshed, AUTH enforced, AOF persistence on, a SET/GET roundtrip,
# a Streams XADD/XLEN roundtrip, and the password mirrored into Vault KV.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="redis"
VAULT_NS="vault"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

PW="$(kubectl -n "${NS}" get secret redis-auth -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
# redis-cli inside the pod, authenticated.
rc() { kubectl -n "${NS}" exec redis-0 -- redis-cli -a "${PW}" --no-auth-warning "$@"; }
# redis-cli with NO password (to prove AUTH is enforced).
rc_noauth() { kubectl -n "${NS}" exec redis-0 -- redis-cli "$@" 2>&1; }

echo "== 1) redis-0 Ready =="
READY="$(kubectl -n "${NS}" get pod redis-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[ "${READY}" = "True" ] && ok "redis-0 Ready" || bad "redis-0 not Ready (Ready='${READY}')"

echo "== 2) Out of mesh (no linkerd-proxy) =="
CONTAINERS="$(kubectl -n "${NS}" get pod redis-0 -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null)"
case " ${CONTAINERS} " in
  *linkerd-proxy*) bad "linkerd-proxy injected (Redis should be out of mesh)" ;;
  *) ok "no linkerd-proxy (Redis out of mesh)" ;;
esac

echo "== 3) AUTH enforced =="
NOAUTH="$(rc_noauth ping)"
case "${NOAUTH}" in *NOAUTH*|*"Authentication required"*) ok "unauthenticated PING rejected (NOAUTH)" ;; *) bad "PING without password not rejected ('${NOAUTH}')" ;; esac
AUTHED="$(rc ping 2>/dev/null)"
[ "${AUTHED}" = "PONG" ] && ok "authenticated PING -> PONG" || bad "authenticated PING failed ('${AUTHED}')"

echo "== 4) AOF persistence enabled =="
AOF="$(rc config get appendonly 2>/dev/null | tr '\n' ' ')"
case "${AOF}" in *yes*) ok "appendonly=yes" ;; *) bad "AOF not enabled ('${AOF}')" ;; esac

echo "== 5) Cache roundtrip (SET/GET with TTL) =="
rc set "verify:0.6:key" "hello" ex 60 >/dev/null 2>&1
VAL="$(rc get "verify:0.6:key" 2>/dev/null)"
[ "${VAL}" = "hello" ] && ok "SET/GET roundtrip ok" || bad "cache roundtrip failed ('${VAL}')"
rc del "verify:0.6:key" >/dev/null 2>&1

echo "== 6) Streams roundtrip (XADD/XLEN) =="
rc xadd "verify:0.6:stream" '*' event "ping" >/dev/null 2>&1
XLEN="$(rc xlen "verify:0.6:stream" 2>/dev/null)"
[ "${XLEN}" -ge 1 ] 2>/dev/null && ok "XADD/XLEN roundtrip ok (len=${XLEN})" || bad "streams roundtrip failed (len='${XLEN}')"
rc del "verify:0.6:stream" >/dev/null 2>&1

echo "== 7) Password mirrored into Vault KV =="
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  VPW="$(kubectl -n "${VAULT_NS}" exec -i vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
    vault kv get -field=password secret/itorchestra/shared/redis 2>/dev/null || true)"
  [ -n "${VPW}" ] && [ "${VPW}" = "${PW}" ] && ok "Vault secret/itorchestra/shared/redis matches" || bad "Vault redis secret missing/mismatch"
else
  bad "could not read Vault root token (Phase 0.5?)"
fi

echo "========================================================"
echo "Phase 0.6 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
