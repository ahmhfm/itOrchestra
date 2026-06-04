# Runbook - Phase 0.1: Kubernetes Cluster (K3s)

This runbook covers installing, verifying, and tearing down the itOrchestra Kubernetes
foundation. The **dev** path runs on a single WSL2 node; the **prod** path runs on real
multi-node Linux servers.

## Stack

| Concern | Choice | Why K3s defaults are disabled |
|---|---|---|
| Distribution | K3s (dev), K3s/RKE2 (prod) | - |
| CNI + NetworkPolicy | Cilium | `--flannel-backend=none --disable-network-policy` |
| Ingress | ingress-nginx | `--disable=traefik` |
| LoadBalancer | MetalLB (L2) | `--disable=servicelb` |
| Storage | Longhorn | needs `open-iscsi` on every node |

## Prerequisites (dev / WSL2)

1. WSL2 with **systemd enabled** (`/etc/wsl.conf` -> `[boot]\nsystemd=true`, then `wsl --shutdown`).
   Verify: `ps -p 1 -o comm=` prints `systemd`.
2. Run everything from inside WSL at `/mnt/d/itOrchestra/platform`.
3. Normalize line endings if files were edited on Windows:
   ```bash
   cd /mnt/d/itOrchestra/platform
   sed -i 's/\r$//' bootstrap/*.sh k8s/cluster/*/*.sh
   ```

## One-shot install (dev)

```bash
cd /mnt/d/itOrchestra/platform
bash bootstrap/00-bootstrap-dev.sh
```

This runs, in order: K3s server -> kubectl/helm -> Cilium -> MetalLB -> ingress-nginx ->
Longhorn -> namespaces -> NetworkPolicies -> verification.

## Manual step-by-step (dev)

```bash
cd /mnt/d/itOrchestra/platform
export KUBECONFIG=$HOME/.kube/config

bash k8s/cluster/k3s/install-server-dev.sh      # 1. K3s (node NotReady until CNI)
bash bootstrap/install-tools.sh                 # 2. kubectl + helm
bash k8s/cluster/cilium/install-cilium.sh       # 3. Cilium  (node -> Ready)
PROFILE=dev bash k8s/cluster/metallb/install.sh # 4. MetalLB (auto-detect WSL subnet)
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
| `cilium` pods CrashLoop in WSL | Kernel eBPF feature missing -> keep `kubeProxyReplacement: false` (already default). |
| ingress EXTERNAL-IP `<pending>` | MetalLB pool not in node L2 segment -> re-run `metallb/install.sh` (re-detects eth0). |
| PVC stuck `Pending` | `open-iscsi`/`iscsid` not running -> re-run `longhorn/prereqs.sh`. |
| Longhorn manager `CreateContainerError`: `path "/var/lib/longhorn/" is mounted on "/" but it is not a shared mount` | WSL2 mounts `/` with **private** propagation. `install-server-dev.sh` installs a k3s drop-in (`/etc/systemd/system/k3s.service.d/10-rshared-mount.conf`) that runs `mount --make-rshared /` before k3s starts. If you hit this on an existing cluster, create that drop-in, `systemctl daemon-reload`, `systemctl restart k3s`, then delete the stuck `longhorn-manager` pod so the DaemonSet recreates it. |
| LB IP not reachable from Windows host | WSL NAT - enable mirrored networking in `.wslconfig` (dev-only; not required inside WSL). |
| `\r` / `bad interpreter` errors | CRLF line endings -> run the `sed` normalize command above. |
| k3s service restart loop (all pods restart ~every 2 min; kine "client connection is closing"; repeated "Starting kubelet") | Usually a wedged WSL state, not the config. From Windows: `wsl --shutdown`, wait ~10s, reopen WSL (systemd + k3s start clean). Then `journalctl -u k3s -n 300 --no-pager` to confirm the loop is gone and capture any genuine exit reason before adding more workloads. |
| WSL/shell becomes unresponsive to all commands | `wsl --shutdown` from Windows PowerShell, then reopen. Re-export `KUBECONFIG=/root/.kube/config` and resume. |

## Teardown (dev)

```bash
bash bootstrap/teardown-dev.sh   # runs k3s-uninstall.sh and removes kubeconfig
```
