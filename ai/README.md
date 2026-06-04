# AI Engineering Rules System

This folder is a **modular, skill-based AI engineering workspace** for the itOrchestra .NET 10 platform, optimized for Cursor AI (Claude Opus 4.7) and any other AI coding assistant.

Project-wide entry: [`../AGENTS.md`](../AGENTS.md).

## How it works

Instead of one giant rules file, the system is split into small, focused, on-demand files. The AI always loads the tiny core, then routes to the specific skill files needed for the task.

```
ai/
├── core/                 # always-loaded essentials (system prompt, architecture, security, coding standards)
├── skills/               # one focused file per technology (load on demand)
├── constraints/          # absolute bans + required security controls
├── patterns/             # canonical templates for new code
├── examples/             # complete reference implementations
├── workflows/            # end-to-end procedures
├── prompts/              # reusable prompts (new service, code review)
├── context/              # glossary + tech stack inventory
├── checklists/           # gating checklists for deploy and security
├── mcp/                  # Model Context Protocol server inventory
├── rag/                  # retrieval strategy
└── README.md             # this file
```

## Loading protocol (read this first)

Every AI session must:

1. Load [`core/system-prompt.md`](./core/system-prompt.md) (small, fast).
2. Load [`constraints/forbidden-patterns.md`](./constraints/forbidden-patterns.md) (very small, very important).
3. Based on the task, load only the relevant skill files from the routing table in `core/system-prompt.md`.

## File index

### Core (always-loaded)

- [`core/system-prompt.md`](./core/system-prompt.md) — concise role + skill router.
- [`core/architecture.md`](./core/architecture.md) — high-level topology.
- [`core/security.md`](./core/security.md) — Zero Trust principles.
- [`core/coding-standards.md`](./core/coding-standards.md) — C# 14 / .NET 10 standards.

### Skills (load on demand)

| File | Topic |
|---|---|
| [`skills/webapi.md`](./skills/webapi.md) | ASP.NET 10 Core Web API (external REST) |
| [`skills/mvc.md`](./skills/mvc.md) | ASP.NET 10 Core MVC (Web UI) |
| [`skills/wpf.md`](./skills/wpf.md) | WPF (Windows desktop) |
| [`skills/maui.md`](./skills/maui.md) | .NET MAUI (cross-platform) |
| [`skills/grpc.md`](./skills/grpc.md) | gRPC (internal service-to-service) |
| [`skills/cqrs.md`](./skills/cqrs.md) | CQRS with MediatR |
| [`skills/mssql.md`](./skills/mssql.md) | MSSQL + ADO.NET (the only data access policy) |
| [`skills/redis.md`](./skills/redis.md) | Redis (cache + dynamic config) |
| [`skills/redis-streams.md`](./skills/redis-streams.md) | Redis Streams (async messaging) |
| [`skills/yarp.md`](./skills/yarp.md) | YARP (API Gateway) |
| [`skills/linkerd.md`](./skills/linkerd.md) | Linkerd (service mesh) |
| [`skills/opentelemetry.md`](./skills/opentelemetry.md) | OpenTelemetry (observability) |
| [`skills/hangfire.md`](./skills/hangfire.md) | Hangfire (background jobs) |
| [`skills/background-workers.md`](./skills/background-workers.md) | Worker Service hosts |
| [`skills/kubernetes.md`](./skills/kubernetes.md) | Kubernetes (K3s/RKE2) |
| [`skills/keycloak.md`](./skills/keycloak.md) | Keycloak (IAM, JWT, OIDC) |
| [`skills/vault.md`](./skills/vault.md) | HashiCorp Vault (secrets) |
| [`skills/polly-resilience.md`](./skills/polly-resilience.md) | Polly (resilience patterns) |

### Constraints

- [`constraints/forbidden-patterns.md`](./constraints/forbidden-patterns.md) — absolute bans.
- [`constraints/security-enforcement.md`](./constraints/security-enforcement.md) — mandatory controls.

### Patterns

- [`patterns/microservice-template.md`](./patterns/microservice-template.md) — canonical service layout.
- [`patterns/api-template.md`](./patterns/api-template.md) — REST + gRPC endpoint anatomy.
- [`patterns/wpf-template.md`](./patterns/wpf-template.md) — canonical WPF app layout.

### Examples

- [`examples/adonet-sp-call.md`](./examples/adonet-sp-call.md) — full SP call chain.
- [`examples/grpc-service.md`](./examples/grpc-service.md) — full gRPC service.
- [`examples/hangfire-job.md`](./examples/hangfire-job.md) — outbox-drain Hangfire job.

### Workflows

- [`workflows/new-microservice-workflow.md`](./workflows/new-microservice-workflow.md) — end-to-end procedure to add a service.
- [`workflows/deployment-workflow.md`](./workflows/deployment-workflow.md) — pipeline + GitOps.

### Prompts

- [`prompts/new-service-prompt.md`](./prompts/new-service-prompt.md) — generate a new microservice.
- [`prompts/code-review-prompt.md`](./prompts/code-review-prompt.md) — strict code review pass.

### Context

- [`context/glossary.md`](./context/glossary.md) — project-specific terminology.
- [`context/tech-stack.md`](./context/tech-stack.md) — full tech inventory.

### Checklists

- [`checklists/deployment-checklist.md`](./checklists/deployment-checklist.md) — pre-deploy gates.
- [`checklists/security-checklist.md`](./checklists/security-checklist.md) — per-PR + pre-prod security gates.

### MCP & RAG

- [`mcp/mcp-architecture.md`](./mcp/mcp-architecture.md) — MCP server inventory and tools.
- [`rag/context-retrieval-strategy.md`](./rag/context-retrieval-strategy.md) — how the AI retrieves context.

## Token efficiency notes

The system was designed so that a typical task pulls **2 core files + 2–4 skill files + 0–2 examples**, not the entire ruleset. Total active context is usually **5–7 small files**, keeping prompt size predictable.

| Task | Files loaded | Approx. size |
|---|---|---|
| Add a new endpoint to an existing service | system-prompt + forbidden-patterns + webapi + mssql + cqrs | small |
| Add a new microservice | + microservice-template + new-microservice-workflow | medium |
| Code review | + code-review-prompt + security-enforcement + security-checklist + relevant skill | medium |
| Production incident | + architecture + opentelemetry + linkerd + relevant runbook | medium |

## Maintenance

- Skill files evolve as the platform evolves. Treat them like code: PRs, reviewers, semantic versioning of the rule set.
- New technologies require a new skill file with the **10 standard sections**: Purpose, Architecture Role, Rules, Best Practices, Anti-Patterns, Security, Performance, Example, Integration, Checklist, Related.
- Always cross-link related files using markdown links.

## Quick links

- Project entry: [`../AGENTS.md`](../AGENTS.md)
- Always-load core: [`core/system-prompt.md`](./core/system-prompt.md)
- Bans: [`constraints/forbidden-patterns.md`](./constraints/forbidden-patterns.md)
- Glossary: [`context/glossary.md`](./context/glossary.md)
- Tech stack: [`context/tech-stack.md`](./context/tech-stack.md)
