# Runbook - Phase 0.3: YARP API Gateway

This runbook covers building, deploying, verifying and tearing down the **YARP API Gateway** -
the single public entry point for the whole platform. All external client traffic enters here;
YARP terminates TLS, routes to service REST APIs, and enforces edge concerns (rate limiting,
CORS, correlation-id, header sanitization). It is **never** on the internal service-to-service
path (that is gRPC over Linkerd).

> Prerequisites: Phase 0.1 + 0.2 healthy, and the **mesh CNI follow-up** below applied so a
> meshed pod can run in the `restricted` `ns-gateway` namespace.

## Scope of 0.3 (dev skeleton)

Implemented now: TLS termination, declarative routing (empty until services exist), per-IP rate
limiting, CORS allow-list, correlation-id injection/propagation, inbound header sanitization,
health endpoints, Linkerd mesh membership, exposed via MetalLB `LoadBalancer`.

Deferred: **JWT validation** (needs Keycloak, Phase 0.4) and **OTLP trace export** (needs the
observability stack). Serilog already captures TraceId/SpanId; W3C `traceparent` propagates
through YARP by default.

## Mesh CNI follow-up (one-time, completes Phase 0.2 follow-up #1)

`ns-gateway` enforces `restricted` PodSecurity, which forbids the `NET_ADMIN`/`NET_RAW`
capabilities Linkerd's default `proxy-init` needs. The fix is the **Linkerd CNI plugin** chained
after Cilium, so the iptables setup happens in the CNI instead of a privileged init-container.

```bash
export PATH="$HOME/.linkerd2/bin:$PATH"; export KUBECONFIG="$HOME/.kube/config"

# 1) Let Cilium chain a second plugin and write the explicit [cilium-cni, linkerd-cni] chain.
kubectl apply -f k8s/cluster/cilium/cni-chain-configmap.yaml
helm upgrade cilium cilium/cilium -n kube-system --version 1.16.5 --reuse-values \
  --set cni.exclusive=false --set cni.customConf=true --set cni.configMap=cni-configuration \
  --set socketLB.hostNamespaceOnly=true --wait

# 2) Install the linkerd-cni DaemonSet, then switch the control plane to CNI mode.
linkerd install-cni | kubectl apply -f -
kubectl -n linkerd-cni rollout status ds/linkerd-cni
linkerd upgrade --linkerd-cni-enabled | kubectl apply -f -
kubectl -n linkerd rollout restart deploy/linkerd-destination deploy/linkerd-identity deploy/linkerd-proxy-injector
linkerd check
```

> Why `cni.customConf`: with `cni.exclusive=false` alone, the Cilium agent keeps reconciling its
> conflist back to Cilium-only and strips the `linkerd-cni` plugin the DaemonSet appends. Feeding
> Cilium an explicit chain ConfigMap makes `[cilium-cni, linkerd-cni]` its desired state, ending
> the tug-of-war that otherwise leaves new pods without Linkerd iptables (the
> `linkerd-network-validator` init-container then fails with `Connection refused`).

Validate a restricted, meshed pod comes up `2/2` with **no** `linkerd-init` (only
`linkerd-network-validator` + `linkerd-proxy` init-containers).

## Build + deploy (dev)

The image is built locally and imported into K3s' containerd - no registry needed. A container
builder (`docker` or `nerdctl`) must be installed on the VM.

```bash
cd ~/itOrchestra/platform
export KUBECONFIG="$HOME/.kube/config"

# one-shot: build image -> import into K3s -> deploy -> verify
bash bootstrap/02-gateway-dev.sh
```

Or step by step:

```bash
bash gateway/build-and-import-dev.sh      # docker build + 'k3s ctr images import'
bash k8s/gateway/install-dev.sh           # self-signed TLS secret + NetworkPolicies + Service + Deployment
bash bootstrap/verify-0.3.sh              # checks pod, MetalLB IP, HTTPS /healthz, correlation id
```

## Verification

`bootstrap/verify-0.3.sh` checks:

- Gateway pod is `Ready` and has the `linkerd-proxy` sidecar (meshed).
- MetalLB assigned an external IP to `svc/gateway`.
- `GET https://<ip>/healthz` returns `200` (self-signed cert -> use `curl -k`).
- Responses carry an `X-Correlation-Id` header.

Useful ad-hoc commands:

```bash
kubectl -n ns-gateway get pods,svc -o wide
IP=$(kubectl -n ns-gateway get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -k https://$IP/                       # gateway info JSON
linkerd viz stat deploy -n ns-gateway      # golden metrics for the gateway
```

## Configuration

- **Routes/clusters**: `gateway/appsettings.json` -> `ReverseProxy` section (declarative). Each
  microservice adds a versioned route (`/api/v1/<svc>/{**catch-all}`) pointing at its in-cluster
  Service DNS name; Linkerd mTLS secures the hop automatically.
- **TLS**: dev uses a self-signed PKCS12 in the `gateway-tls` Secret. Prod terminates with a
  real certificate (cert-manager) and the password comes from Vault.
- **CORS**: `Cors:AllowedOrigins` (allow-list; never `*`).
- **Rate limits**: per-IP 60/min default; `sensitive` policy 10/min for login-type routes.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod `ErrImageNeverPull` | image not imported. Re-run `gateway/build-and-import-dev.sh`; confirm with `sudo k3s ctr images ls \| grep gateway`. |
| Pod stuck `Init` with validator `Connection refused` | Linkerd CNI not applied to the pod -> see the mesh CNI follow-up; confirm `linkerd-cni` is in `/etc/cni/net.d/05-cilium.conflist` and stays there. |
| Pod rejected by PodSecurity | container `securityContext` not `restricted`-compliant (runAsNonRoot, drop ALL caps, seccomp RuntimeDefault, no privilege escalation). |
| No external IP on `svc/gateway` | MetalLB pool exhausted/misconfigured (Phase 0.1); check `kubectl -n metallb-system get ipaddresspool`. |
| `/healthz` times out | NetworkPolicy missing -> ensure `allow-gateway-ingress` (port 8443) and `allow-linkerd-*` are applied. |
| TLS handshake fails | `gateway-tls` Secret missing or password mismatch; recreate via `install-dev.sh`. |

## Production notes

- At least 2 replicas + HPA (CPU 60%); anti-affinity across nodes.
- Real TLS cert (cert-manager); password and any secrets from Vault.
- JWT validation enabled (Keycloak issuer/audience) once Phase 0.4 lands; add the auth policies
  per route. Validate JWT at the edge AND at each service (defense in depth).
- Build/push the image to a registry (GHCR/Harbor) with Cosign signing instead of local import.
- Tighten `allow-linkerd-egress` to the specific control-plane ports (8080/8086/8090).

## Teardown (dev)

```bash
kubectl -n ns-gateway delete deploy/gateway svc/gateway secret/gateway-tls
kubectl -n ns-gateway delete networkpolicy allow-gateway-ingress
```
