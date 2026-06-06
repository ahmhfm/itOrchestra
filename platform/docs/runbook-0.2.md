# Runbook - Phase 0.2: Linkerd Service Mesh

This runbook covers installing, verifying, and tearing down the Linkerd service mesh on top
of the Phase 0.1 cluster. Linkerd provides automatic **mTLS**, transparent **retries/timeouts**,
**load balancing**, and **golden metrics** for all meshed pod-to-pod traffic (gRPC and HTTP).

> Prerequisite: Phase 0.1 is installed and **healthy** (`bash bootstrap/verify-0.1.sh` passes).

## Stack

| Concern | Choice | Notes |
|---|---|---|
| Mesh | Linkerd (edge channel = free OSS) | Buoyant publishes paid "stable" builds; edge is the free CNCF channel. |
| Prereq CRDs | Gateway API (`v1.2.1`) | Recent Linkerd requires the Gateway API CRDs before install; `install-linkerd-dev.sh` applies them. |
| Dev install | `linkerd` CLI, auto-generated certs | Simplest; no external PKI needed. |
| Prod install | Helm (`linkerd-crds` + `linkerd-control-plane`) + cert-manager | Externally managed trust anchor (Vault). |
| Identity | Per-pod, derived from the ServiceAccount | mTLS certs auto-rotated (~24h). |
| Observability | `linkerd-viz` (dev: bundled Prometheus) | Replaced by the central observability stack later. |

## One-shot install (dev)

```bash
cd ~/itOrchestra/platform
# only if files were copied from Windows: dos2unix bootstrap/*.sh k8s/cluster/linkerd/*.sh
bash bootstrap/01-mesh-dev.sh            # set INSTALL_VIZ=false to skip the dashboard
```

This runs, in order: linkerd CLI -> `linkerd check --pre` -> CRDs -> control plane ->
rollout wait -> `linkerd check` -> (optional) linkerd-viz -> Phase 0.2 verification.

## Manual step-by-step (dev)

```bash
cd ~/itOrchestra/platform
export KUBECONFIG=$HOME/.kube/config

bash k8s/cluster/linkerd/install-linkerd-dev.sh   # 1. CLI + Gateway API CRDs + Linkerd CRDs + control plane (auto certs)
bash k8s/cluster/linkerd/install-linkerd-viz.sh   # 2. (optional) dashboard + golden metrics
bash bootstrap/verify-0.2.sh                      # 3. verify
```

The CLI installs to `~/.linkerd2/bin`; the scripts add it to `PATH`. To use `linkerd`
directly in your shell: `export PATH="$HOME/.linkerd2/bin:$PATH"`.

## Verification

`bootstrap/verify-0.2.sh` checks:

- `linkerd` CLI present.
- `linkerd check` passes (control-plane health, certs, API).
- All pods in the `linkerd` namespace are `Running`.
- **Injection smoke test:** a pod in a throwaway namespace comes up **2/2** (`app` +
  `linkerd-proxy`) - which only succeeds after `linkerd-identity` issues its mTLS cert.
- (optional) `linkerd viz check` if `linkerd-viz` is installed.

Useful ad-hoc commands:

```bash
linkerd check                 # control-plane health
linkerd viz dashboard &       # web dashboard (if viz installed)
linkerd viz stat deploy -A    # success-rate / latency / RPS per deployment
```

## IMPORTANT: two follow-ups before meshing real workloads

Phase 0.2 installs the **control plane only**. Two items must be handled when the first real
service is deployed into the `restricted` application namespaces (`ns-gateway`, `ns-identity`,
`ns-assets`, `ns-discovery`):

1. **`restricted` PodSecurity vs. proxy-init.** Linkerd's default `proxy-init` init-container
   needs `NET_ADMIN`/`NET_RAW`, which the `restricted` profile forbids - injected pods would be
   **rejected by admission**. The fix is the **Linkerd CNI plugin** (the iptables setup moves to
   a CNI chained after Cilium), so meshed pods stay `restricted`-compliant. Install it before the
   first workload lands in those namespaces. (The dev smoke test uses a non-restricted throwaway
   namespace precisely to avoid this.)

2. **Default-deny vs. mesh traffic.** The app namespaces are default-deny (only DNS egress is
   open). A meshed pod's proxy must reach the `linkerd` control plane (identity/destination/
   policy) and be reachable on its inbound proxy port. Add an `allow-linkerd` NetworkPolicy per
   app namespace (egress to the `linkerd` namespace + the proxy admin/inbound ports) alongside
   the service-specific allow rules.

## Production notes

- Use `k8s/cluster/linkerd/install-linkerd-prod.sh` (Helm + `step`-bootstrapped certs).
- The **trust anchor** (root CA) is long-lived and stored in **Vault**; the **issuer**
  (intermediate) is short-lived and rotated by **cert-manager**. Never commit any `*.key`.
- Install with `highAvailability=true` (multiple control-plane replicas + anti-affinity).
- Install the **Linkerd CNI plugin** chained with Cilium (required for `restricted` namespaces).
- Pin a specific channel/version; gate `linkerd.io/inject: enabled` in CI (e.g. Kyverno).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `linkerd check --pre` warns about k8s version | edge tracks recent k8s; warnings are usually benign in dev. Pin a known-good `LINKERD2_VERSION` if install fails. |
| Injected pod stuck `Init` / `CreateContainerError` in an app namespace | `restricted` PSA rejecting `proxy-init` -> install the Linkerd CNI plugin (see follow-up #1). |
| Meshed pod cannot reach its peers in a default-deny namespace | missing `allow-linkerd` NetworkPolicy (see follow-up #2). |
| `linkerd check` fails on certificates | dev auto-certs expired (1y) -> re-run `install-linkerd-dev.sh`; prod -> check cert-manager. |
| Proxy not injected | namespace/pod missing `linkerd.io/inject: enabled`, or proxy-injector webhook not Ready (`kubectl -n linkerd get pods`). |
| `linkerd` CLI not found | `export PATH="$HOME/.linkerd2/bin:$PATH"`. |
| Smoke test pod stays 1/1 (no proxy) even though `linkerd check` is green | The proxy-injector webhook is `failurePolicy: Ignore`; if the API server can't reach the injector at pod-creation time the pod is admitted **un-injected**. Common right after a cluster restart. Re-create the pod once the injector is reachable (`kubectl -n <ns> delete pod -l <sel>`), or client-side inject: `linkerd inject deploy.yaml \| kubectl apply -f -`. |

## Teardown (dev)

```bash
export PATH="$HOME/.linkerd2/bin:$PATH"
linkerd viz uninstall | kubectl delete -f -    # if viz was installed
linkerd uninstall      | kubectl delete -f -   # removes control plane + CRDs
```
