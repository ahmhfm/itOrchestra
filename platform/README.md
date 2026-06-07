# itOrchestra Platform - Phase 0 (Shared Infrastructure)

This folder contains the Infrastructure-as-Code for the itOrchestra shared platform
("المرحلة 0 : تأسيس البنية التحتية المشتركة / Phase 0: Platform Foundation").

It is built incrementally, one step at a time, following the project plan
(`itOrchestra plan/Software Engineering/Final Plan/Project Plan AR|EN .docx`).

## Current status

| Step | Component | Status |
|------|-----------|--------|
| 0.1 | Kubernetes cluster (K3s / RKE2) + CNI + Storage + Ingress + LB + Namespaces + NetworkPolicies | Done (dev) |
| 0.2 | Linkerd service mesh (+ Linkerd CNI plugin chained on Cilium for `restricted` namespaces) | Done (dev) - `linkerd check` √, verify-0.2 6/6 |
| 0.3 | YARP API Gateway (TLS, routing, rate limit, CORS, correlation-id; JWT deferred to 0.4) | Done (dev) - verify-0.3 5/5, LoadBalancer 10.178.95.241 |
| 0.4 | Keycloak (IAM) + private MSSQL, behind YARP; realm `itorchestra-dev` imported | Done (dev) - verify-0.4 7/7 |
| 0.5 | HashiCorp Vault (Raft + Longhorn) + Agent Injector; KV v2 + Kubernetes auth; 0.4 secrets seeded | Done (dev) - verify-0.5 8/8 |
| 0.6 | Redis (Cache + Streams) | Not started |
| ... | ... | ... |

## Two deployment profiles

Every component ships with two profiles so the same repo serves local development and production:

- **dev** - a single-node K3s cluster running on a dedicated **Ubuntu VM** (provision it via
  [`docs/runbook-vm-setup.md`](docs/runbook-vm-setup.md)). Replica counts are reduced to 1,
  storage replicas are 1, and MetalLB uses the VM's LAN subnet.
- **prod** - a multi-node **K3s** (or RKE2) cluster on real Linux servers
  (HA control plane + worker nodes), production-sized replicas and storage.

## Step 0.1 - Kubernetes cluster

Stack (confirmed): **K3s** + **Cilium** (CNI) + **Longhorn** (storage) + **ingress-nginx** + **MetalLB** (internal LoadBalancer).

K3s is installed with its bundled components disabled so we control them explicitly:

- `--flannel-backend=none` + `--disable-network-policy` -> Cilium provides CNI + NetworkPolicy.
- `--disable=traefik` -> ingress-nginx provides Ingress.
- `--disable=servicelb` -> MetalLB provides `LoadBalancer` services.

### Layout

```
platform/
  k8s/
    cluster/
      k3s/             K3s install scripts + config (dev/prod)
      cilium/          Cilium CNI install + values
      metallb/         MetalLB install + L2 IP pools (dev/prod)
      ingress-nginx/   ingress-nginx install + values
      longhorn/        open-iscsi prereqs + Longhorn install + StorageClass
    namespaces/        Platform + per-service namespaces (PSA + Linkerd labels)
    network-policies/  Default-deny + allow-DNS NetworkPolicies
  bootstrap/
    00-bootstrap-dev.sh   End-to-end dev installer (runs everything in order)
  docs/
    runbook-0.1.md        Install / verify / teardown runbook
```

### Quick start (dev, on the Ubuntu VM)

```bash
# On the Ubuntu VM (see docs/runbook-vm-setup.md), with the repo cloned at ~/itOrchestra:
cd ~/itOrchestra/platform
bash bootstrap/00-bootstrap-dev.sh
```

See [`docs/runbook-0.1.md`](docs/runbook-0.1.md) for step-by-step manual instructions,
verification commands, and teardown.

## Step 0.2 - Service mesh (Linkerd)

Stack: **Linkerd** (edge channel, free OSS) for automatic **mTLS**, retries/timeouts, load
balancing, and golden metrics on all meshed pod-to-pod traffic. Dev installs via the Linkerd
CLI with auto-generated certs; prod uses Helm + a Vault-managed trust anchor with cert-manager.

```bash
cd ~/itOrchestra/platform
# only if files were copied from Windows: dos2unix bootstrap/*.sh k8s/cluster/linkerd/*.sh
bash bootstrap/01-mesh-dev.sh            # INSTALL_VIZ=false to skip the dashboard
```

Layout: `k8s/cluster/linkerd/` (install scripts: dev CLI, viz, prod Helm),
`bootstrap/01-mesh-dev.sh`, `bootstrap/verify-0.2.sh`.

> Two follow-ups before meshing real workloads in the `restricted` `ns-*` namespaces:
> (1) install the **Linkerd CNI plugin** (chained with Cilium) so injected pods satisfy the
> `restricted` PodSecurity profile; (2) add `allow-linkerd` NetworkPolicies so meshed pods can
> reach the control plane under default-deny. See [`docs/runbook-0.2.md`](docs/runbook-0.2.md).

## Step 0.5 - Secrets (HashiCorp Vault)

Stack: **HashiCorp Vault** (chart `0.32.0` / Vault `1.21.2`) with **integrated Raft storage**
on a Longhorn PVC (persistent), the **Vault Agent Injector** (`vault-k8s 1.7.2`), **KV v2**
and the **Kubernetes auth** method. Vault is reached only in-cluster (ClusterIP); it is never
exposed publicly and never routed through YARP. The UI/CLI is opened via `kubectl port-forward`.

```bash
cd ~/itOrchestra/platform
bash bootstrap/04-vault-dev.sh
```

The installer initializes + unseals Vault (1 key share - **dev only**, stored in
`vault/vault-unseal-keys`), enables KV v2 at `secret/`, enables Kubernetes auth, seeds the
Phase 0.4 secrets (`secret/itorchestra/{keycloak/admin,keycloak/db,gateway/keycloak}`), and
creates a sample least-privilege policy + role (`itorchestra-gateway` -> SA `default` in
`ns-gateway`). Workloads consume secrets at runtime via Agent Injector annotations (files
under `/vault/secrets/`); see [`ai/skills/vault.md`](../ai/skills/vault.md).

> **dev vs prod:** dev runs a single-node Raft with `tls_disable`, a single Shamir key, and a
> persisted root token for convenience, and keeps Vault **out of the mesh** (a Linkerd sidecar
> on the Injector's admission webhook breaks API-server TLS calls). Prod runs an HA Raft
> cluster with real TLS, KMS auto-unseal, split Shamir keys, no persisted root token, and
> meshes Vault with `opaque-ports`/`skip-inbound-ports`.

Layout: `k8s/vault/` (`values.yaml`, `install-dev.sh`), `bootstrap/04-vault-dev.sh`,
`bootstrap/verify-0.5.sh`, [`docs/runbook-0.5.md`](docs/runbook-0.5.md).

## Conventions (from the project rules)

- One namespace per microservice; namespaces are labelled `name=<ns>` for NetworkPolicy
  selectors and annotated `linkerd.io/inject: enabled` (mesh installed in 0.2).
- Application namespaces enforce the Pod Security `restricted` profile.
- NetworkPolicies are **default-deny** (ingress + egress); only DNS is allowed by default,
  everything else must be explicitly opened per service.
- No secrets in Git - secrets come from Vault (step 0.5). The `.gitignore` blocks kubeconfig.
