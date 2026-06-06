# Runbook - Phase 0.1: Kubernetes Cluster (K3s)

This runbook covers installing, verifying, and tearing down the itOrchestra Kubernetes
foundation. The **dev** path runs on a single **Ubuntu VM** node (see
[`runbook-vm-setup.md`](runbook-vm-setup.md) to provision it); the **prod** path runs on real
multi-node Linux servers.

## Stack

| Concern | Choice | Why K3s defaults are disabled |
|---|---|---|
| Distribution | K3s (dev), K3s/RKE2 (prod) | - |
| CNI + NetworkPolicy | Cilium | `--flannel-backend=none --disable-network-policy` |
| Ingress | ingress-nginx | `--disable=traefik` |
| LoadBalancer | MetalLB (L2) | `--disable=servicelb` |
| Storage | Longhorn | needs `open-iscsi` on every node |

## Prerequisites (dev / Ubuntu VM)

1. A dedicated **Ubuntu Server 24.04 VM** provisioned per
   [`runbook-vm-setup.md`](runbook-vm-setup.md) (systemd is PID 1 by default;
   verify with `ps -p 1 -o comm=` -> `systemd`).
2. `curl` and `git` installed; the repo cloned at `~/itOrchestra` (run everything from
   `~/itOrchestra/platform`).
3. A stable VM IP (DHCP reservation or static) on a `/24` whose `.240-.250` range can be
   reserved for MetalLB.

> Files cloned via git already use LF endings. Only if you copy them from Windows do you need
> to normalize: `dos2unix bootstrap/*.sh k8s/cluster/*/*.sh` (or `sed -i 's/\r$//' ...`).

## One-shot install (dev)

```bash
cd ~/itOrchestra/platform
bash bootstrap/00-bootstrap-dev.sh
```

This runs, in order: K3s server -> kubectl/helm -> Cilium -> MetalLB -> ingress-nginx ->
Longhorn -> namespaces -> NetworkPolicies -> verification.

## Manual step-by-step (dev)

```bash
cd ~/itOrchestra/platform
export KUBECONFIG=$HOME/.kube/config

bash k8s/cluster/k3s/install-server-dev.sh      # 1. K3s (node NotReady until CNI)
bash bootstrap/install-tools.sh                 # 2. kubectl + helm
bash k8s/cluster/cilium/install-cilium.sh       # 3. Cilium  (node -> Ready)
PROFILE=dev bash k8s/cluster/metallb/install.sh # 4. MetalLB (auto-detect VM subnet)
bash k8s/cluster/ingress-nginx/install.sh       # 5. ingress-nginx (LB IP)
bash k8s/cluster/longhorn/prereqs.sh            # 6a. open-iscsi
LONGHORN_REPLICAS=1 bash k8s/cluster/longhorn/install.sh  # 6b. Longhorn (default SC)
kubectl apply -f k8s/namespaces/namespaces.yaml          # 7. namespaces
kubectl apply -f k8s/network-policies/default-deny.yaml  # 8a. deny all
kubectl apply -f k8s/network-policies/allow-dns.yaml     # 8b. allow DNS
bash bootstrap/verify-0.1.sh                    # 9. verify
```

## Verification

`bootstrap/verify-0.1.sh` checks:

- Node `Ready`.
- Cilium DaemonSet ready (and `cilium status` if the CLI is present).
- ingress-nginx has an `EXTERNAL-IP` from MetalLB and answers HTTP (404 default backend = healthy path).
- A default StorageClass exists (`itorchestra-longhorn`) and a 1Gi PVC reaches `Bound`.
- Default-deny works: a pod in `ns-assets` cannot reach a service in `ns-identity`, while DNS still resolves.

## Production notes

- First control-plane node:
  `sudo K3S_TOKEN=<vault-token> k8s/cluster/k3s/install-server-prod.sh --init`
- Extra control-plane nodes:
  `sudo K3S_TOKEN=<vault-token> K3S_SERVER_URL=https://<node1>:6443 k8s/cluster/k3s/install-server-prod.sh --join`
- Workers:
  `sudo K3S_TOKEN=<vault-token> K3S_SERVER_URL=https://<vip>:6443 k8s/cluster/k3s/install-agent-prod.sh`
- Set Longhorn replicas to 3 (`LONGHORN_REPLICAS=3`) and edit `metallb/ippool.prod.yaml` to a
  reserved LAN range outside DHCP scope.
- Run `cilium/install-cilium.sh` once from any control-plane node; consider enabling
  `kubeProxyReplacement: true` after validating on the production kernel.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Node stuck `NotReady` | CNI not installed yet -> run Cilium install. |
| `cilium` pods CrashLoop | Kernel eBPF feature missing -> keep `kubeProxyReplacement: false` (already default). |
| ingress EXTERNAL-IP `<pending>` | MetalLB pool not in node L2 segment -> re-run `metallb/install.sh` (re-detects the primary NIC). |
| LB IP not reachable from your host | Use **bridged** VM networking so LB IPs sit on the LAN; with **NAT**, port-forward from the host or use `kubectl port-forward`. See [`runbook-vm-setup.md`](runbook-vm-setup.md) section 4. |
| PVC stuck `Pending` | `open-iscsi`/`iscsid` not running -> re-run `longhorn/prereqs.sh`. |
| `\r` / `bad interpreter` errors | CRLF line endings (only if files were copied from Windows) -> `dos2unix bootstrap/*.sh k8s/cluster/*/*.sh`. |

## Teardown (dev)

```bash
bash bootstrap/teardown-dev.sh   # runs k3s-uninstall.sh and removes kubeconfig
```
