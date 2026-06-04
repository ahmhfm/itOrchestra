# Skill: Kubernetes (K3s / RKE2 Orchestration)

## Purpose
Define how every workload is deployed, scaled, and operated. Kubernetes is the only sanctioned runtime for non-client workloads (Web API, gRPC, Workers, YARP, observability stack).

## Architecture Role
The cluster layer. Hosts every service, Linkerd, YARP, Vault Agent injectors, observability collectors, and supporting infrastructure. Distributions: **K3s** (edge / smaller envs) or **RKE2** (production).

## Rules

1. **Per-service namespace.** Each microservice lives in its own namespace (`itorchestra-orders`, `itorchestra-customers`).
2. **Each namespace** has Linkerd injection enabled.
3. **API pod and Worker pod** are **separate Deployments** even when from the same service.
4. **Resource requests + limits** declared for every container.
5. **Probes:** `livenessProbe`, `readinessProbe`, `startupProbe` on every container.
6. **Pod Security:** `restricted` profile by default.
7. **NetworkPolicy:** default-deny inbound + outbound; allow explicit.
8. **Secrets** never as raw Kubernetes Secrets in Git — pulled by Vault Agent sidecars / CSI.
9. **HPA** configured for every stateless workload.
10. **PDB** (PodDisruptionBudget) for every workload with replicas > 1.

## Best Practices

- Use **Helm charts** per service; chart values templated for environments.
- Use **Kustomize** overlays for environment-specific tweaks.
- Use **`spec.topologySpreadConstraints`** to spread replicas across nodes.
- Use **Argo CD** or **Flux** for GitOps deployment.
- Use **Renovate** to keep image digests current.
- Use **Cilium**/**Calico** network policies; combine with Linkerd policies for app-layer auth.
- Sign images with **Cosign**; cluster admission controller verifies signatures.

## Anti-Patterns

| Don't | Do |
|---|---|
| Run a service without resource limits | Always declare requests + limits |
| Mount a Secret directly from `data:` in a manifest | Use Vault Agent / Vault CSI |
| Use `latest` tag | Pin to a digest (`sha256:...`) |
| Share one namespace across many services | One namespace per service |
| Skip probes | Liveness + readiness + (often) startup |
| Run as root | `runAsNonRoot: true` |
| Allow `hostNetwork: true` for the application | Almost never; only for infra agents |
| Manage state in Pod local storage | Externalize to MSSQL/Redis |

## Security Requirements

- Pod Security Standard: `restricted` profile enforced by admission policy.
- Containers run with: `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, all Linux capabilities dropped.
- Workload identity: dedicated **ServiceAccount** per Deployment.
- Linkerd injection annotated on the namespace.
- NetworkPolicies: default-deny; explicit allow per destination.
- Secrets from Vault only.
- Container images scanned (Trivy) and signed (Cosign).

## Performance Guidelines

- Resource requests sized from real load tests; limits = request × 1.5–2.
- HPA target: CPU 60% (most apps), with min ≥ 2, max ≥ 10.
- Use `topologySpreadConstraints` to avoid all replicas on one node.
- Node pools sized for typical workload mix; spot/preemptible for stateless workloads where SLA allows.
- Cluster autoscaler enabled.

## Example Implementations

### Deployment + Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: itorchestra-orders
  labels:
    app: orders-api
    role: api
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 25%, maxUnavailable: 0 }
  selector:
    matchLabels: { app: orders-api }
  template:
    metadata:
      labels: { app: orders-api, role: api }
      annotations:
        linkerd.io/inject: enabled
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "orders-api"
        vault.hashicorp.com/agent-inject-secret-db: "database/creds/orders"
        vault.hashicorp.com/agent-inject-template-db: |
          {{ with secret "database/creds/orders" -}}
          ConnectionStrings__Orders=Server=mssql.itorchestra.internal,1433;Database=Orders;User Id={{ .Data.username }};Password={{ .Data.password }};Encrypt=true;TrustServerCertificate=false;
          {{- end }}
    spec:
      serviceAccountName: orders-api
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: app
          image: registry.itorchestra.com/orders-api@sha256:abcd...   # pinned digest
          ports:
            - { name: http, containerPort: 8080 }
            - { name: grpc, containerPort: 8081 }
          env:
            - name: ASPNETCORE_URLS
              value: "http://+:8080;http://+:8081"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
          envFrom:
            - configMapRef: { name: orders-api-config }
          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { cpu: "1",  memory: 512Mi }
          readinessProbe:
            httpGet: { path: /health/ready, port: http }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /health/live, port: http }
            periodSeconds: 10
          startupProbe:
            httpGet: { path: /health/live, port: http }
            failureThreshold: 30
            periodSeconds: 2
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: orders-api }
---
apiVersion: v1
kind: Service
metadata:
  name: orders-api
  namespace: itorchestra-orders
spec:
  selector: { app: orders-api }
  ports:
    - { name: http, port: 80,  targetPort: http }
    - { name: grpc, port: 81,  targetPort: grpc }
  type: ClusterIP
```

### HPA + PDB

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: orders-api
  namespace: itorchestra-orders
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: orders-api
  minReplicas: 3
  maxReplicas: 12
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 60 }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: orders-api
  namespace: itorchestra-orders
spec:
  minAvailable: 2
  selector:
    matchLabels: { app: orders-api }
```

### Default-deny NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: itorchestra-orders
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-yarp-and-meshed
  namespace: itorchestra-orders
spec:
  podSelector:
    matchLabels: { app: orders-api }
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { name: itorchestra-gateway }
        - namespaceSelector:
            matchLabels: { linkerd: enabled }
  egress:
    - to:
        - namespaceSelector: { matchLabels: { name: itorchestra-data } }
      ports:
        - { protocol: TCP, port: 1433 }
    - to:
        - namespaceSelector: { matchLabels: { name: itorchestra-cache } }
      ports:
        - { protocol: TCP, port: 6379 }
```

## Integration Rules

- **GitOps** is the only deployment path to production (Argo CD / Flux).
- **Vault Agent Injector** mounts secrets as files; the app reads them through standard configuration providers.
- **Linkerd**: namespace injection annotation; mesh policy declared per workload.
- **Observability**: cluster-wide OTLP collector deployed in `observability` namespace.
- **Backups**: MSSQL backed up via Velero + native MSSQL snapshots; PV snapshots scheduled.

## Checklist

- [ ] Namespace created per service; `linkerd.io/inject: enabled`.
- [ ] Deployment with pinned image digest.
- [ ] Resource requests + limits set.
- [ ] Probes (liveness, readiness, startup) on every container.
- [ ] `securityContext` follows `restricted` profile.
- [ ] ServiceAccount per workload, scoped Vault role.
- [ ] HPA + PDB configured.
- [ ] NetworkPolicy default-deny + explicit allow.
- [ ] Helm chart + values per environment.
- [ ] Image signed with Cosign and scanned with Trivy.
- [ ] Argo CD application defined.

## Related

- [`linkerd.md`](./linkerd.md)
- [`vault.md`](./vault.md)
- [`../checklists/deployment-checklist.md`](../checklists/deployment-checklist.md)
- [`../workflows/deployment-workflow.md`](../workflows/deployment-workflow.md)
