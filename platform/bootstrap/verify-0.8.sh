#!/usr/bin/env bash
# itOrchestra - Phase 0.8 verification (central Observability stack).
# Checks: namespace out of mesh; OpenSearch / Tempo / Prometheus / AlertManager / Grafana /
# OTel Collector pods Ready; OpenSearch cluster health not red; SLO rules loaded; Grafana
# reachable through YARP at /grafana; and the stack creds/endpoints mirrored into Vault.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="observability"
GW_NS="ns-gateway"
VAULT_NS="vault"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

ready_by_label() {
  local name
  name="$(kubectl -n "${NS}" get pod -l "$1" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
  [ -n "${name}" ] || { echo "NOPOD"; return; }
  kubectl -n "${NS}" get pod "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}
check_ready() { # <label> <friendly>
  local r; r="$(ready_by_label "$1")"
  [ "${r}" = "True" ] && ok "$2 Ready" || bad "$2 not Ready (status='${r}')"
}

echo "== 1) observability out of mesh (no linkerd-proxy) =="
C="$(kubectl -n "${NS}" get pod opensearch-0 -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null)"
case " ${C} " in *linkerd-proxy*) bad "linkerd-proxy injected" ;; *) ok "no linkerd-proxy (out of mesh)" ;; esac

echo "== 2) Component pods Ready =="
check_ready "app=opensearch"                            "OpenSearch"
check_ready "app.kubernetes.io/name=tempo"              "Tempo"
check_ready "app.kubernetes.io/name=prometheus"         "Prometheus"
check_ready "app.kubernetes.io/name=alertmanager"       "AlertManager"
check_ready "app.kubernetes.io/name=grafana"            "Grafana"
check_ready "app.kubernetes.io/name=opentelemetry-collector" "OTel Collector"
check_ready "app.kubernetes.io/name=prometheus-node-exporter" "node-exporter (node metrics)"

echo "== 3) OpenSearch cluster health (green/yellow) =="
HEALTH="$(kubectl -n "${NS}" exec opensearch-0 -- curl -s "http://localhost:9200/_cluster/health" 2>/dev/null || true)"
case "${HEALTH}" in
  *'"status":"green"'*|*'"status":"yellow"'*) ok "OpenSearch cluster health OK (single-node => yellow)" ;;
  *'"status":"red"'*) bad "OpenSearch cluster health RED" ;;
  *) bad "could not read OpenSearch cluster health ('${HEALTH}')" ;;
esac

echo "== 4) SLO alert rules loaded =="
RULES="$(kubectl -n "${NS}" get prometheusrule itorchestra-slo -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
[ "${RULES}" = "itorchestra-slo" ] && ok "PrometheusRule itorchestra-slo present" || bad "SLO PrometheusRule missing"

echo "== 5) OTel Collector OTLP service exposed =="
PORTS="$(kubectl -n "${NS}" get svc otel-collector -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || true)"
case " ${PORTS} " in *" 4317 "*) ok "OTLP gRPC port 4317 exposed" ;; *) bad "OTLP 4317 not exposed (ports='${PORTS}')" ;; esac

echo "== 6) Grafana reachable through YARP (/grafana) =="
IP="$(kubectl -n "${GW_NS}" get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
if [ -n "${IP}" ]; then
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://${IP}/grafana/api/health" --max-time 10 2>/dev/null)"
  [ "${CODE}" = "200" ] && ok "GET https://${IP}/grafana/api/health -> 200" || bad "/grafana/api/health returned '${CODE}'"
else
  bad "no gateway external IP (skipping YARP check)"
fi

echo "== 7) Stack creds/endpoints mirrored into Vault =="
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  VPW="$(kubectl -n "${VAULT_NS}" exec -i vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
    vault kv get -field=grafana-admin-password secret/itorchestra/shared/observability 2>/dev/null || true)"
  GFPW="$(kubectl -n "${NS}" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)"
  [ -n "${VPW}" ] && [ "${VPW}" = "${GFPW}" ] && ok "Vault secret/itorchestra/shared/observability matches" || bad "Vault observability secret missing/mismatch"
else
  bad "could not read Vault root token (sealed? Phase 0.5?)"
fi

echo "========================================================"
echo "Phase 0.8 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
