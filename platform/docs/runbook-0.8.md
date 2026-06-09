# Runbook - Phase 0.8: Observability (OpenTelemetry + Tempo + Prometheus + Grafana + OpenSearch)

This runbook covers deploying the **central observability stack**: one place to watch traces,
metrics, and logs across every service and infrastructure component, with SLO alerts and
end-to-end request tracing via the `X-Correlation-Id` / W3C `traceparent` flow.

> Prerequisites: Phases 0.1-0.7 healthy (cluster + Longhorn, **gateway** running, **Vault**
> running and **unsealed**), and a container builder (docker/nerdctl) on the VM for the gateway
> rebuild.
> **Resource note:** this stack is memory-hungry (OpenSearch + Prometheus + Grafana +
> AlertManager + Tempo + Collector). On top of MSSQL AG (~6 GiB) + Keycloak + Vault + Redis it
> can push a single VM hard - give the VM several GiB of headroom (16 GiB+ recommended). If pods
> stay `Pending`/`OOMKilled`, raise the VM memory or trim limits in the values files.

## Architecture

```
   services (.NET) ──OTLP──▶ OpenTelemetry Collector ──▶ Tempo        (traces)
   YARP / Hangfire / gRPC                │            ──▶ Prometheus  (metrics, scraped :8889)
                                         │            ──▶ OpenSearch  (logs)
   Linkerd proxies ───4191(/metrics)────▶ Prometheus
   node-exporter + kube-state-metrics ──▶ Prometheus
                                         ▼
                                      Grafana  ──(via YARP /grafana)──▶ operators
                                         │
                                   AlertManager  ──▶ SLO alerts
```

## Scope of 0.8 (dev)

Implemented now:

- **OpenSearch** (`opensearchproject/opensearch:2.19.1`) - single-node logs/search store, the
  **security plugin disabled** (plaintext HTTP 9200, internal only), Longhorn PVC, out of mesh.
- **Tempo** (`grafana/tempo` single-binary) - trace store, OTLP receivers (4317/4318), Longhorn PVC.
- **kube-prometheus-stack** (release `kps`) - Prometheus (3d retention, Longhorn PVC), Grafana,
  AlertManager, node-exporter, kube-state-metrics, the Prometheus Operator.
- **OpenTelemetry Collector** (contrib, release `otel-collector`) - OTLP ingest with **tail
  sampling** (100% errors + slow, 10% rest) and sensitive-header **redaction**; exports traces
  -> Tempo, metrics -> Prometheus (`:8889`), logs -> OpenSearch.
- **Prometheus scrape**: the OTel Collector + **Linkerd** data-plane proxies (port 4191).
- **Grafana datasources**: Prometheus (default) + Tempo + OpenSearch, with trace->logs linking.
- **Sample SLO alerts** (`PrometheusRule itorchestra-slo`): `TargetDown`, `HighRequestErrorRate`,
  `HighRequestLatencyP95`.
- **Grafana through YARP** at `/grafana` (gateway image rebuilt with the route; egress opened).
- **Vault mirror**: `secret/itorchestra/shared/observability` (Grafana creds + stack endpoints).

Deferred: mTLS on the OTLP path (mesh the namespace), OpenSearch security plugin + TLS +
Keycloak roles, Grafana **Keycloak OIDC** SSO, pinned chart versions, long-term retention,
real AlertManager receivers (email/Slack/PagerDuty), and per-service dashboards (added as each
service is onboarded). No .NET services emit telemetry yet, so the traces/logs pipelines are
**wired and ready** but empty until later phases.

## Decisions (this environment)

- **Full stack + OpenSearch for logs** (chosen) - unifies logs and later search/analytics in
  one store; Loki was the lighter alternative.
- **Out of the mesh (dev)** - avoids opaque-port complexity for server-speaks-first stores and
  cross-namespace scraping; the OTLP app->Collector hop is plaintext in-cluster (prod meshes it).
- **Grafana via YARP** - operators reach Grafana only through the single public entry point; no
  separate LoadBalancer/Ingress.
- **Central Prometheus supersedes** the `linkerd-viz` bundled Prometheus (0.2).

## Deploy (dev)

```bash
cd ~/itOrchestra/platform
# only if files were copied from Windows: dos2unix bootstrap/*.sh k8s/observability/*.sh
bash bootstrap/07-observability-dev.sh
```

The installer: ensures the namespace + `vm.max_map_count` + the `grafana-admin` secret -> adds
Helm repos -> deploys OpenSearch -> Tempo -> kube-prometheus-stack -> SLO rules -> the OTel
Collector -> opens gateway egress -> **rebuilds + restarts the gateway** with the `/grafana`
route -> mirrors creds/endpoints into Vault. It is idempotent.

> Chart versions are **pinned** in the installer (`kube-prometheus-stack 86.2.0`, `tempo 1.24.4`,
> `opentelemetry-collector 0.158.1`) for reproducible installs. To move deliberately, override the
> env var: `KPS_CHART_VERSION=… TEMPO_CHART_VERSION=… OTEL_CHART_VERSION=… bash bootstrap/07-observability-dev.sh`.

## Verify

```bash
bash bootstrap/verify-0.8.sh
```

Checks: namespace out of mesh; OpenSearch / Tempo / Prometheus / AlertManager / Grafana / OTel
Collector pods Ready; OpenSearch cluster health green/yellow; the SLO `PrometheusRule` loaded;
the Collector's OTLP port exposed; **Grafana reachable through YARP** (`/grafana/api/health` ->
200); and the Vault mirror matches the Grafana secret.

## Operate

```bash
# Grafana admin password (DEV ONLY):
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Open Grafana (through the gateway):  https://<gateway-external-ip>/grafana/   (login: admin / <pw>)
IP=$(kubectl -n ns-gateway get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo "https://$IP/grafana/"

# Prometheus / AlertManager (no YARP route; port-forward for ad-hoc access):
kubectl -n observability port-forward svc/kps-prometheus   9090:9090
kubectl -n observability port-forward svc/kps-alertmanager 9093:9093

# OpenSearch cluster health:
kubectl -n observability exec opensearch-0 -- curl -s localhost:9200/_cluster/health | tr ',' '\n'

# Send a test trace/metric/log later via the OTLP endpoint:
#   otel-collector.observability.svc.cluster.local:4317 (gRPC)  /  :4318 (HTTP)
```

### How services wire into this (later phases)

Each .NET service calls `AddOpenTelemetryInstrumentation()` (see `ai/skills/opentelemetry.md`),
exporting OTLP to `otel-collector.observability.svc.cluster.local:4317`. The OTLP endpoint comes
from Vault (`secret/itorchestra/shared/observability`). Serilog ships logs via
`Serilog.Sinks.OpenTelemetry` so they share the span/correlation context. Grafana dashboards are
published per service; SLO thresholds in `prometheus/slo-alerts.yaml` are extended per service.

## Troubleshooting

- **OpenSearch CrashLoop / `max virtual memory areas` error** - the node's `vm.max_map_count`
  is too low; the installer sets it, but re-run `sudo sysctl -w vm.max_map_count=262144` if needed.
- **Collector CrashLoop** - usually an exporter/processor schema mismatch for the installed
  contrib version (e.g. the `opensearch` exporter's `logs_index`). Check
  `kubectl -n observability logs deploy/otel-collector` and adjust `otel-collector/values.yaml`.
- **`/grafana` 502 from YARP** - the gateway egress policy or the rebuilt image didn't apply;
  re-run the install (it restarts the gateway), and confirm `kps-grafana` is Ready.
- **Pods `Pending`** - insufficient memory/CPU on the VM; raise VM resources or trim limits.

## Teardown (dev)

```bash
helm -n observability uninstall otel-collector kps tempo
kubectl -n observability delete -f k8s/observability/opensearch/statefulset.yaml
kubectl -n observability delete -f k8s/observability/opensearch/service.yaml
kubectl -n observability delete pvc --all          # destroys metrics/traces/logs data
kubectl -n observability delete secret grafana-admin
kubectl -n ns-gateway delete -f k8s/observability/gateway-egress.yaml
```

> Removing the `/grafana` route requires rebuilding the gateway from the prior `appsettings.json`.
> The Vault secret `secret/itorchestra/shared/observability` is left in place.
