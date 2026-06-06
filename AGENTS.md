# itOrchestra — Agent Context

Persistent project context for AI agents. Keep this file accurate and up to date.

## Repository & Git identity

| Item | Value |
|------|-------|
| Topology | Single **monorepo** — application code and infrastructure (`platform/`) live together as normal folders |
| Local path (dev machine) | `D:\itOrchestra\` |
| Remote (`origin`) | `git@github.com:ahmhfm/itOrchestra.git` (SSH) |
| Default branch | `main` (tracks `origin/main`) |
| Commit identity | `ahmhfm` <`ahmhfm1@hotmail.com`> |
| First commit | `Chore: Initialize monorepo with platform IaC and solution root` |

- `platform/` is a **normal tracked folder** — NOT a Git submodule and NOT a separate repository.
- The planning docs in `itOrchestra plan/` live **outside** this repository (separate docs location).

## AI engineering ruleset (`ai/`)

This repo ships a modular engineering ruleset under `ai/`, activated for every session via
the always-on Cursor rule `.cursor/rules/ai-engineering-system.mdc`.

**Loading protocol (every task):**
1. Core role: `ai/core/system-prompt.md` (Senior .NET 10 Architect).
2. Always consult `ai/constraints/forbidden-patterns.md` before writing/reviewing code.
3. Load only the relevant skill files via the routing table in `ai/core/system-prompt.md`
   (open on demand; do not inline). See `ai/README.md` for the full index.

## Git conventions

- Atomic commits may span both application code and `platform/` infrastructure changes.
- Per-service **independent deployment** is achieved via path-filtered CI pipelines, not by splitting repositories.
- **Never commit secrets**: `kubeconfig`, `*.kubeconfig`, `k3s.yaml`, `*.pfx`, `*.key`, `*.crt`, `*.env`, `appsettings.*.local.json`, `secrets.json`. Secrets come from HashiCorp Vault (Phase 0.5).
- Shell (`*.sh`) and YAML (`*.yaml`/`*.yml`) files must use **LF** line endings (enforced via `.gitattributes`) so they run on Linux.
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

## Dev environment (Ubuntu VM)

- Single-node K3s `v1.35.5+k3s1` on a dedicated **Ubuntu Server 24.04** VM; node name `itorchestra-dev`.
- Run `kubectl`/`helm`/`git` on the VM as the normal user. `KUBECONFIG=$HOME/.kube/config`.
- Provision the VM per [`platform/docs/runbook-vm-setup.md`](platform/docs/runbook-vm-setup.md); `systemd` is PID 1 by default and `/` is shared at boot (no extra mount drop-in needed).
- To stop/start the env: power off / power on the VM (snapshots enable instant rollback).
- Default StorageClass: `itorchestra-longhorn`. Ingress LoadBalancer IP (dev): `10.178.95.240`.

See `platform/README.md` and `platform/docs/runbook-0.1.md` for the full infrastructure runbook.
