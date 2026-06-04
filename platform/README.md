# itOrchestra Platform - Phase 0 (Shared Infrastructure)

This folder contains the Infrastructure-as-Code for the itOrchestra shared platform
("المرحلة 0 : تأسيس البنية التحتية المشتركة / Phase 0: Platform Foundation").

It is built incrementally, one step at a time, following the project plan
(`itOrchestra plan/Software Engineering/Final Plan/Project Plan AR|EN .docx`).

## Current status

| Step | Component | Status |
|------|-----------|--------|
| 0.1 | Kubernetes cluster (K3s / RKE2) + CNI + Storage + Ingress + LB + Namespaces + NetworkPolicies | Done (dev) |
| 0.2 | Linkerd service mesh | Not started |
| 0.3 | YARP API Gateway | Not started |
| 0.4 | Keycloak | Not started |
| 0.5 | HashiCorp Vault | Not started |
| 0.6 | Redis (Cache + Streams) | Not started |
| ... | ... | ... |

## Two deployment profiles

Every component ships with two profiles so the same repo serves local development and production:

- **dev** - a single-node K3s cluster running inside **WSL2** on a developer machine.
  Replica counts are reduced to 1, storage replicas are 1, and MetalLB uses the WSL subnet.
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

### Quick start (dev, inside WSL2)

```bash
cd /mnt/d/itOrchestra/platform
# normalize line endings (in case files were saved from Windows) then run
sed -i 's/\r$//' bootstrap/00-bootstrap-dev.sh k8s/**/*.sh
bash bootstrap/00-bootstrap-dev.sh
```

See [`docs/runbook-0.1.md`](docs/runbook-0.1.md) for step-by-step manual instructions,
verification commands, and teardown.

## Conventions (from the project rules)

- One namespace per microservice; namespaces are labelled `name=<ns>` for NetworkPolicy
  selectors and annotated `linkerd.io/inject: enabled` (mesh installed in 0.2).
- Application namespaces enforce the Pod Security `restricted` profile.
- NetworkPolicies are **default-deny** (ingress + egress); only DNS is allowed by default,
  everything else must be explicitly opened per service.
- No secrets in Git - secrets come from Vault (step 0.5). The `.gitignore` blocks kubeconfig.
