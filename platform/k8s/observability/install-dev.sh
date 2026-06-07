#!/usr/bin/env bash
# Deploy the central Observability stack (Phase 0.8) into the 'observability' namespace:
#   - OpenSearch (single-node, security disabled in dev) ......... logs store
#   - Tempo (grafana/tempo single-binary) ........................ traces store
#   - kube-prometheus-stack (Prometheus + Grafana + AlertManager
#     + node-exporter + kube-state-metrics) ...................... metrics + dashboards + alerts
#   - OpenTelemetry Collector (contrib) .......................... OTLP ingest -> Tempo/Prom/OpenSearch
# Grafana is exposed through YARP at /grafana (the gateway image is rebuilt with the new route).
# Grafana admin creds + stack endpoints are mirrored into Vault.
#
# Out of the Linkerd mesh (dev), consistent with the other data stores.
# Idempotent: secrets are generated once; helm/manifests re-apply cleanly on re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="observability"
VAULT_NS="vault"

# Chart versions float to latest by default (override to pin in prod). The resolved
# versions are printed after install.
KPS_CHART_VERSION="${KPS_CHART_VERSION:-}"
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-}"
OTEL_CHART_VERSION="${OTEL_CHART_VERSION:-}"

ver_arg() { [ -n "$1" ] && printf -- "--version %s" "$1" || true; }
gen_pw() { openssl rand -hex 24; }

# Wait until >=1 pod matches the label selector, then for all of them to be Ready.
wait_ready() {
  local sel="$1" timeout="${2:-420s}"
  for _ in $(seq 1 60); do
    [ "$(kubectl -n "${NS}" get pod -l "${sel}" --no-headers 2>/dev/null | wc -l)" -ge 1 ] && break
    sleep 5
  done
  kubectl -n "${NS}" wait --for=condition=Ready pod -l "${sel}" --timeout="${timeout}"
}

echo "==> [0.8/observability] Ensuring the 'observability' namespace (baseline PSA, out of mesh)"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    name: observability
    pod-security.kubernetes.io/enforce: baseline
  annotations:
    linkerd.io/inject: disabled
EOF

echo "==> Ensuring kernel vm.max_map_count >= 262144 (OpenSearch requirement)"
if [ "$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)" -lt 262144 ]; then
  sudo sysctl -w vm.max_map_count=262144
  echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-opensearch.conf >/dev/null
  echo "    set vm.max_map_count=262144 (persisted to /etc/sysctl.d/99-opensearch.conf)"
else
  echo "    vm.max_map_count already >= 262144 (skip)"
fi

echo "==> Ensuring the grafana-admin Secret"
if ! kubectl -n "${NS}" get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n "${NS}" create secret generic grafana-admin \
    --from-literal=admin-user="admin" \
    --from-literal=admin-password="$(gen_pw)"
  echo "    created secret grafana-admin"
else
  echo "    secret grafana-admin already exists (skip)"
fi

echo "==> Adding Helm repos"
# Retry the index fetch: a transient network blip would otherwise leave a repo unregistered
# and fail the install. --force-update refreshes the URL if the repo name already exists.
add_repo() {
  for i in 1 2 3; do
    helm repo add "$1" "$2" --force-update >/dev/null 2>&1 && return 0
    echo "    retry helm repo add $1 ($i/3)"; sleep 3
  done
  echo "    !! failed to add Helm repo '$1' ($2)" >&2; return 1
}
add_repo prometheus-community https://prometheus-community.github.io/helm-charts
add_repo grafana              https://grafana.github.io/helm-charts
add_repo open-telemetry       https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update prometheus-community grafana open-telemetry >/dev/null

echo "==> Deploying OpenSearch (logs store)"
kubectl apply -f "${SCRIPT_DIR}/opensearch/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/opensearch/statefulset.yaml"
kubectl -n "${NS}" rollout status statefulset/opensearch --timeout=420s

echo "==> Deploying Tempo (traces store)"
helm upgrade --install tempo grafana/tempo \
  --namespace "${NS}" $(ver_arg "${TEMPO_CHART_VERSION}") \
  -f "${SCRIPT_DIR}/tempo/values.yaml"
wait_ready "app.kubernetes.io/name=tempo"

echo "==> Deploying kube-prometheus-stack (Prometheus + Grafana + AlertManager)"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace "${NS}" $(ver_arg "${KPS_CHART_VERSION}") \
  -f "${SCRIPT_DIR}/prometheus/values.yaml"
wait_ready "app.kubernetes.io/name=prometheus"
wait_ready "app.kubernetes.io/name=alertmanager"
wait_ready "app.kubernetes.io/name=grafana"

echo "==> Applying sample SLO alert rules"
kubectl apply -f "${SCRIPT_DIR}/prometheus/slo-alerts.yaml"

echo "==> Deploying the OpenTelemetry Collector (OTLP ingest)"
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace "${NS}" $(ver_arg "${OTEL_CHART_VERSION}") \
  -f "${SCRIPT_DIR}/otel-collector/values.yaml"
wait_ready "app.kubernetes.io/name=opentelemetry-collector"

echo "==> Opening gateway egress to Grafana (observability:3000)"
kubectl apply -f "${SCRIPT_DIR}/gateway-egress.yaml"

echo "==> Rebuilding the gateway image with the /grafana route, then restarting it"
bash "${ROOT}/gateway/build-and-import-dev.sh"
kubectl -n ns-gateway rollout restart deploy/gateway
kubectl -n ns-gateway rollout status  deploy/gateway --timeout=180s

echo "==> Mirroring Grafana creds + stack endpoints into Vault (secret/itorchestra/shared/observability)"
GF_USER="$(kubectl -n "${NS}" get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d)"
GF_PW="$(kubectl   -n "${NS}" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  kubectl -n "${VAULT_NS}" exec -i vault-0 -- env \
    VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
    GF_USER="${GF_USER}" GF_PW="${GF_PW}" \
    sh -s <<'EOSH'
set -e
vault kv put secret/itorchestra/shared/observability \
  grafana-admin-user="$GF_USER" \
  grafana-admin-password="$GF_PW" \
  otlp-grpc-endpoint="otel-collector.observability.svc.cluster.local:4317" \
  otlp-http-endpoint="http://otel-collector.observability.svc.cluster.local:4318" \
  tempo-endpoint="http://tempo.observability.svc.cluster.local:3100" \
  prometheus-endpoint="http://kps-prometheus.observability.svc.cluster.local:9090" \
  opensearch-endpoint="http://opensearch.observability.svc.cluster.local:9200"
echo "  seeded: secret/itorchestra/shared/observability"
EOSH
else
  echo "    !! could not read Vault root token (sealed? Phase 0.5?); skipping Vault mirror" >&2
fi

echo "==> Observability state:"
kubectl -n "${NS}" get pods,svc,pvc -o wide
echo "==> Resolved chart versions:"
helm -n "${NS}" list

echo "==> [0.8/observability] Deploy done."
echo "    Grafana via YARP:   https://<gateway-external-ip>/grafana/   (login: admin / see secret)"
echo "    Grafana password:   kubectl -n ${NS} get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo "    OTLP endpoint:      otel-collector.observability.svc.cluster.local:4317 (gRPC) / :4318 (HTTP)"
