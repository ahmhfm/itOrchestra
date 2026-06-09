#!/usr/bin/env bash
# itOrchestra - Phase 0.3 verification (YARP API Gateway, dev).
# Checks: gateway pod Ready + meshed, MetalLB external IP assigned, HTTPS /healthz 200,
# and the edge correlation-id header on responses.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="ns-gateway"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 1) Gateway pod Ready + linkerd-proxy injected =="
POD="$(kubectl -n "${NS}" get pods -l app=gateway -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
if [ -z "${POD}" ]; then
  bad "no gateway pod found"
else
  READY="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  # edge-26 injects the proxy as a native sidecar (initContainers).
  INIT="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null)"
  [ "${READY}" = "True" ] && ok "pod ${POD} Ready" || bad "pod ${POD} not Ready (Ready='${READY}')"
  case " ${INIT} " in
    *linkerd-proxy*) ok "linkerd-proxy sidecar injected" ;;
    *) bad "no linkerd-proxy sidecar (containers: ${INIT})" ;;
  esac
  SA="$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)"
  [ "${SA}" = "gateway" ] && ok "runs as dedicated ServiceAccount 'gateway' (not default)" || bad "pod SA='${SA}' (expected 'gateway')"
fi

echo "== 2) LoadBalancer external IP assigned (MetalLB) =="
IP="$(kubectl -n "${NS}" get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
if [ -n "${IP}" ]; then ok "external IP: ${IP}"; else bad "no external IP on svc/gateway"; fi

echo "== 3) HTTPS /healthz returns 200 =="
if [ -n "${IP}" ]; then
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://${IP}/healthz" --max-time 10 2>/dev/null)"
  [ "${CODE}" = "200" ] && ok "GET https://${IP}/healthz -> 200" || bad "healthz returned '${CODE}'"

  echo "== 4) Edge correlation-id header present =="
  CID="$(curl -sk -D - -o /dev/null "https://${IP}/" --max-time 10 2>/dev/null | grep -i '^x-correlation-id:' || true)"
  [ -n "${CID}" ] && ok "response carries X-Correlation-Id" || bad "missing X-Correlation-Id header"
else
  bad "skipping HTTP checks (no external IP)"
fi

echo "========================================================"
echo "Phase 0.3 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
