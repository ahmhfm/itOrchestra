# Skill: Linkerd (Service Mesh)

## Purpose
Provide automatic mTLS, retries, timeouts, traffic shaping, and golden metrics for **all pod-to-pod traffic** inside the Kubernetes cluster.

## Architecture Role
The transport layer for every internal call (gRPC and HTTP/JSON, sync or async client connections that stay inside the mesh). Linkerd runs as a sidecar (`linkerd-proxy`) injected automatically into meshed namespaces.

## Rules

1. **Every workload** with internal traffic carries the annotation `linkerd.io/inject: enabled`.
2. **Linkerd mTLS is always on** between meshed pods. Plaintext is rejected.
3. **Linkerd policies** (`Server`, `ServerAuthorization`, `HTTPRoute`) are part of the deployment manifests, not afterthoughts.
4. **Application-level retries** (Polly) handle business idempotency; Linkerd retries handle transient transport faults — both layers configured deliberately.
5. **No service** bypasses the mesh for internal traffic (no direct `ClusterIP` skip via host networking).
6. **External traffic** does NOT use Linkerd directly — it enters via YARP, then Linkerd takes over for the hop from YARP to the service.
7. **Telemetry** (Prometheus metrics) and **traces** (W3C `traceparent`) emitted by the proxy are scraped/forwarded.
8. **mTLS certificate rotation** every 24h, automatically.

## Best Practices

- Use **Server** + **ServerAuthorization** to declare which client identities can call which servers.
- Use **HTTPRoute** for path-based routing and per-route timeouts.
- Use **TrafficSplit** for canary deployments / progressive rollout.
- Monitor `linkerd viz` dashboards / Grafana for golden metrics: success rate, latency, RPS.
- Set conservative retry budgets at the mesh level (Linkerd-default budgets are usually fine).
- Use **traffic policies** to deny inbound by default; allow explicitly.

## Anti-Patterns

| Don't | Do |
|---|---|
| Disable mTLS for "debugging" | Use `linkerd viz tap` instead |
| Mix meshed and unmeshed pods in the same `Deployment` | All replicas meshed |
| Rely on Linkerd retries for non-idempotent calls | Combine with idempotency keys |
| Bypass Linkerd for performance | The overhead is negligible; never bypass |
| Manually generate identity certs | Linkerd manages identity automatically |
| Use Service IPs in client config | Use Kubernetes Service DNS |
| Open NodePorts for internal services | Internal services are `ClusterIP` only |

## Security Requirements

- Linkerd identity is **derived from the Service Account** of the Pod; treat service accounts as the unit of trust.
- **Server / ServerAuthorization** resources define a positive allow-list per service.
- **mTLS not negotiable** — proxies refuse plaintext meshed connections.
- Linkerd control plane runs in a dedicated namespace with restricted access (`linkerd`, `linkerd-viz`).
- Trust anchor + issuer certificates managed by `cert-manager` or rotated manually following the documented runbook.

## Performance Guidelines

- Linkerd proxy adds < 1 ms p50 latency in typical traffic.
- HTTP/2 connection reuse handled by the proxy automatically.
- For very high RPS services, monitor `linkerd-proxy` CPU; tune `proxy.cores`.
- Disable Linkerd injection on jobs that do not need it (one-off CLI jobs) to save resources.

## Example Implementations

### Namespace + workload injection

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: itorchestra-orders
  annotations:
    linkerd.io/inject: enabled
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: itorchestra-orders
spec:
  replicas: 3
  selector:
    matchLabels: { app: orders-api }
  template:
    metadata:
      labels: { app: orders-api }
      annotations:
        linkerd.io/inject: enabled
    spec:
      serviceAccountName: orders-api
      containers:
        - name: app
          image: registry.itorchestra.com/orders-api:1.0.0
          ports:
            - name: http
              containerPort: 8080
            - name: grpc
              containerPort: 8081
          readinessProbe:
            httpGet: { path: /health/ready, port: 8080 }
          livenessProbe:
            httpGet: { path: /health/live, port: 8080 }
```

### Server + ServerAuthorization (deny by default; allow explicit)

```yaml
apiVersion: policy.linkerd.io/v1beta1
kind: Server
metadata:
  name: orders-grpc
  namespace: itorchestra-orders
spec:
  podSelector:
    matchLabels: { app: orders-api }
  port: grpc
  proxyProtocol: gRPC
---
apiVersion: policy.linkerd.io/v1beta1
kind: ServerAuthorization
metadata:
  name: orders-grpc-allow-checkout
  namespace: itorchestra-orders
spec:
  server:
    name: orders-grpc
  client:
    meshTLS:
      serviceAccounts:
        - name: checkout-api
          namespace: itorchestra-checkout
```

### HTTPRoute (per-route timeout)

```yaml
apiVersion: policy.linkerd.io/v1beta3
kind: HTTPRoute
metadata:
  name: orders-rest
  namespace: itorchestra-orders
spec:
  parentRefs:
    - name: orders-http
      kind: Server
      group: policy.linkerd.io
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1/orders
      timeouts:
        request: 3s
        backendRequest: 2s
```

## Integration Rules

- **YARP Pod** is meshed; YARP-to-service hop uses Linkerd mTLS automatically.
- **Workers (Hangfire / consumers)** are meshed for any HTTP/gRPC they make to siblings; Redis/MSSQL endpoints are TLS at the transport (not via Linkerd, since they sit out-of-mesh).
- **Observability:** Linkerd metrics are scraped by Prometheus → Grafana; traces propagated via W3C headers and exported via OpenTelemetry collector.
- **CI deployments** ensure `linkerd.io/inject: enabled` is present (gated by a policy controller — e.g., Kyverno).

## Checklist

- [ ] Namespace annotated with `linkerd.io/inject: enabled`.
- [ ] All replicas show 2/2 containers (app + proxy).
- [ ] `Server` resources declared per service port.
- [ ] `ServerAuthorization` allow-lists per client SA.
- [ ] Default-deny in place at the namespace level.
- [ ] HTTPRoute timeouts configured.
- [ ] mTLS validated via `linkerd check --proxy`.
- [ ] Golden metrics visible in Grafana.
- [ ] Trust anchor rotation runbook documented.

## Related

- [`grpc.md`](./grpc.md)
- [`yarp.md`](./yarp.md)
- [`kubernetes.md`](./kubernetes.md)
- [`opentelemetry.md`](./opentelemetry.md)
- [`../core/security.md`](../core/security.md)
