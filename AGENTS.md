# itOrchestra — Agent Context

Persistent project context for AI agents. Keep this file accurate and up to date.

## Repository & Git identity

| Item | Value |
|------|-------|
| Topology | Single **monorepo** — application code and infrastructure (`platform/`) live together as normal folders |
| Local path (dev machine) | `D:\itOrchestra\` (mounted at `/mnt/d/itOrchestra` inside WSL2) |
| Remote (`origin`) | `https://github.com/ahmhfm/itOrchestra.git` |
| Default branch | `main` (tracks `origin/main`) |
| Commit identity | `ahmhfm` <`ahmfhm1@hotmail.com`> |
| First commit | `Chore: Initialize monorepo with platform IaC and solution root` |

- `platform/` is a **normal tracked folder** — NOT a Git submodule and NOT a separate repository.
- The planning docs in `itOrchestra plan/` live **outside** this repository (separate docs location).

## Git conventions

- Atomic commits may span both application code and `platform/` infrastructure changes.
- Per-service **independent deployment** is achieved via path-filtered CI pipelines, not by splitting repositories.
- **Never commit secrets**: `kubeconfig`, `*.kubeconfig`, `k3s.yaml`, `*.pfx`, `*.key`, `*.crt`, `*.env`, `appsettings.*.local.json`, `secrets.json`. Secrets come from HashiCorp Vault (Phase 0.5).
- Shell (`*.sh`) and YAML (`*.yaml`/`*.yml`) files must use **LF** line endings (enforced via `.gitattributes`) so they run under WSL/Linux.
- Only create commits when the user explicitly asks.

## Project structure

```
itOrchestra/                <- monorepo root (this file)
  itOrchestra.slnx          <- .NET solution (currently empty)
  .gitignore .gitattributes .editorconfig global.json README.md
  platform/                 <- Infrastructure-as-Code (K8s, bootstrap scripts, Helm values)
  src/  database/  tests/  .github/workflows/   <- added as code arrives
itOrchestra plan/           <- design/planning docs (NOT in this repo)
```

## Current status — Phase 0 (shared infrastructure)

| Step | Component | Status |
|------|-----------|--------|
| 0.1 | K8s cluster: K3s + Cilium (CNI/NetworkPolicy) + MetalLB (LB) + ingress-nginx + Longhorn (storage) + namespaces + NetworkPolicies | **Done (dev)** — verified 8/8 |
| 0.2 | Linkerd service mesh | Not started |
| 0.3 | YARP API Gateway | Not started |
| 0.4 | Keycloak (auth/SSO) | Not started |
| 0.5 | HashiCorp Vault (secrets) | Not started |
| 0.6 | Redis (cache + Streams) | Not started |

## Dev environment (WSL2)

- Single-node K3s `v1.35.5+k3s1` inside WSL2 distro **Ubuntu-24.04**; node name `itorchestra-dev`.
- Run `kubectl`/`helm`/`git` inside WSL. `KUBECONFIG=/root/.kube/config` (root user).
- WSL quirk: a k3s systemd drop-in (`/etc/systemd/system/k3s.service.d/10-rshared-mount.conf`) runs `mount --make-rshared /` before k3s starts — required for Longhorn.
- If the cluster enters a restart loop or WSL hangs: `wsl --shutdown` from Windows, reopen, re-export `KUBECONFIG`.
- Default StorageClass: `itorchestra-longhorn`. Ingress LoadBalancer IP (dev): `172.19.16.240`.

See `platform/README.md` and `platform/docs/runbook-0.1.md` for the full infrastructure runbook.
