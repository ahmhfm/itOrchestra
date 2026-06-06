# Runbook - Dev environment: dedicated Ubuntu VM

The development cluster runs on a **dedicated Ubuntu VM**.

**Why a dedicated VM:** an always-on VM gives a production-like, persistent single node:
k3s and every pod keep a single stable uptime, so webhook-dependent flows (such as Linkerd
proxy injection) behave reliably and there are no spurious full-cluster restarts.

> Scope: this is the **dev** profile target. Multi-node **prod** still follows the prod
> scripts/runbooks (real Linux servers). The same IaC under `platform/` runs on both.

## 1. VM specifications (dev)

| Resource | Minimum | Recommended | Notes |
|---|---|---|---|
| vCPU | 4 | 6-8 | Cilium + Longhorn + Linkerd + workloads. |
| RAM | 8 GB | 12-16 GB | Longhorn/observability are memory-hungry. |
| Disk | 60 GB | 100+ GB (SSD) | Longhorn stores replicas under `/var/lib/longhorn`. |
| OS | Ubuntu Server 24.04 LTS | Ubuntu Server 24.04 LTS | Matches the current node image; systemd is PID 1 by default. |
| Firewall | allow intra-VM + LAN | - | Don't block the cluster/pod/service CIDRs or the MetalLB range. |

Take a **VM snapshot** after Phase 0.1 verifies green, and again after 0.2 - rollback is then
instant if an experiment goes wrong.

## 2. Create the VM

Pick any hypervisor. Use **bridged networking** so MetalLB LoadBalancer IPs are reachable from
your host/LAN (NAT works too but needs port-forwarding - see step 4).

- **multipass** (simplest on Windows/macOS):
  ```bash
  multipass launch 24.04 --name itorchestra-dev --cpus 6 --memory 12G --disk 100G --network <bridged-nic>
  multipass shell itorchestra-dev
  ```
- **Hyper-V:** New VM, Gen 2, attach Ubuntu 24.04 ISO, connect to an **External** virtual switch
  (bridged). Disable Secure Boot or select the MS UEFI CA. Assign the resources above.
- **VirtualBox / VMware Workstation:** create the VM, set the network adapter to **Bridged**,
  install Ubuntu Server 24.04.
- **KVM/libvirt:** `virt-install ... --network bridge=br0 ...`.

Set a **stable IP**: either a DHCP reservation for the VM's MAC, or a static netplan address.
Note the VM's IP and `/24` subnet - MetalLB derives its pool from it.

## 3. Base OS prerequisites (inside the VM)

```bash
sudo apt-get update -y
sudo apt-get install -y curl git ca-certificates
# open-iscsi / nfs-common (Longhorn) are installed by k8s/cluster/longhorn/prereqs.sh.
# systemd is already PID 1 on Ubuntu Server - verify:
ps -p 1 -o comm=     # -> systemd
```

No swap changes are required for k3s. Ensure the clock is synced (`timedatectl` -> NTP active).

## 4. Networking & MetalLB

- **Bridged (recommended):** the VM gets a LAN IP (e.g. `192.168.1.50`). `metallb/install.sh`
  auto-detects the primary NIC (via the default route) and renders an L2 pool of
  `x.y.z.240-250`. **Reserve that range** in your router/DHCP so nothing else uses it; LB IPs
  are then reachable from the whole LAN.
- **NAT:** LB IPs live on the VM's internal network only. Reach a service from the host with a
  hypervisor port-forward to the ingress LB IP, or `kubectl port-forward`. Simpler is bridged.

If your LAN `/24` can't spare `.240-.250`, edit the pool: set `PROFILE=prod` and use
`k8s/cluster/metallb/ippool.prod.yaml`, or adjust the range in `metallb/install.sh`.

## 5. Get the platform IaC onto the VM

Clone the monorepo (production-like) rather than sharing the Windows folder:

```bash
cd ~
git clone git@github.com:ahmhfm/itOrchestra.git    # or https://github.com/ahmhfm/itOrchestra.git
cd ~/itOrchestra/platform
```

> All dev runbook paths use `~/itOrchestra/platform` on the VM.

## 6. Bootstrap the cluster

```bash
cd ~/itOrchestra/platform
# files cloned via git are already LF; if you ever copy from Windows, normalize first:
#   sudo apt-get install -y dos2unix && dos2unix bootstrap/*.sh k8s/cluster/*/*.sh

bash bootstrap/00-bootstrap-dev.sh        # Phase 0.1: k3s + Cilium + MetalLB + ingress + Longhorn + ns + netpol
bash bootstrap/01-mesh-dev.sh             # Phase 0.2: Linkerd control plane + viz + verify
```

See [`runbook-0.1.md`](runbook-0.1.md) and [`runbook-0.2.md`](runbook-0.2.md) for the
per-phase manual steps, verification, and teardown.

## 7. Day-2 operations

| Task | Command (on the VM) |
|---|---|
| Cluster status | `sudo systemctl status k3s` ; `kubectl get nodes,pods -A` |
| Restart k3s (rarely needed) | `sudo systemctl restart k3s` |
| Stop / start the env | shut down / power on the **VM** |
| Roll back | restore the VM **snapshot** |
| Access dashboards from host | `linkerd viz dashboard --address 0.0.0.0` then browse `http://<vm-ip>:50750`, or ingress via the MetalLB LB IP |

Because the VM stays running, k3s and all pods keep a single, stable uptime, so Linkerd
injection and other webhook-driven flows behave reliably.
