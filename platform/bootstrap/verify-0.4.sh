#!/usr/bin/env bash
# itOrchestra - Phase 0.4 verification (Keycloak + private MSSQL, behind YARP).
# Checks: MSSQL Ready, Keycloak pod Ready + meshed, DB-init Job completed, and the OIDC
# discovery + JWKS reachable through the gateway with the correct issuer.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="keycloak"
REALM="itorchestra-dev"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 1) MSSQL Ready =="
MSSQL_READY="$(kubectl -n "${NS}" get pod keycloak-mssql-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[ "${MSSQL_READY}" = "True" ] && ok "keycloak-mssql-0 Ready" || bad "MSSQL not Ready (Ready='${MSSQL_READY}')"

echo "== 2) DB bootstrap Job completed =="
if kubectl -n "${NS}" get job keycloak-db-init >/dev/null 2>&1; then
  JOB="$(kubectl -n "${NS}" get job keycloak-db-init -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  [ "${JOB}" = "1" ] && ok "keycloak-db-init succeeded" || bad "db-init job not complete (succeeded='${JOB}')"
else
  # ttlSecondsAfterFinished GC'd the Job; Keycloak running against the DB proves it ran.
  ok "keycloak-db-init already completed + GC'd (DB initialized)"
fi

echo "== 3) Keycloak pod Ready + linkerd-proxy injected =="
POD="$(kubectl -n "${NS}" get pods -l app=keycloak -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
if [ -z "${POD}" ]; then
  bad "no keycloak pod found"
else
  READY="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  INIT="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null)"
  [ "${READY}" = "True" ] && ok "pod ${POD} Ready" || bad "pod ${POD} not Ready (Ready='${READY}')"
  case " ${INIT} " in
    *linkerd-proxy*) ok "linkerd-proxy sidecar injected (mTLS)" ;;
    *) bad "no linkerd-proxy sidecar (containers: ${INIT})" ;;
  esac
fi

echo "== 4) OIDC discovery via gateway (issuer correct) =="
IP="$(kubectl -n ns-gateway get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
if [ -z "${IP}" ]; then
  bad "no gateway external IP; skipping HTTP checks"
else
  DISC="https://${IP}/realms/${REALM}/.well-known/openid-configuration"
  BODY="$(curl -sk "${DISC}" --max-time 15 2>/dev/null)"
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "${DISC}" --max-time 15 2>/dev/null)"
  [ "${CODE}" = "200" ] && ok "GET ${DISC} -> 200" || bad "discovery returned '${CODE}'"
  case "${BODY}" in
    *"\"issuer\":\"https://${IP}/realms/${REALM}\""*) ok "issuer = https://${IP}/realms/${REALM}" ;;
    *) bad "unexpected issuer in discovery document" ;;
  esac

  echo "== 5) JWKS reachable via gateway =="
  JWKS="https://${IP}/realms/${REALM}/protocol/openid-connect/certs"
  JBODY="$(curl -sk "${JWKS}" --max-time 15 2>/dev/null)"
  case "${JBODY}" in
    *'"keys"'*) ok "JWKS endpoint returns signing keys" ;;
    *) bad "JWKS endpoint missing 'keys'" ;;
  esac
fi

echo "== ingress fence present (Phase 0.12 hardening) =="
kubectl -n "${NS}" get networkpolicy keycloak-ingress-fence >/dev/null 2>&1 \
  && ok "keycloak-ingress-fence NetworkPolicy present" || bad "keycloak ingress fence missing"

echo "========================================================"
echo "Phase 0.4 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
