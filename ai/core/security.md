# Security (Core)

Zero Trust principles applied to every layer. Load when implementing auth, data exposure, infrastructure, or doing a security review.

## Core principle

**Never trust, always verify.** Every request — internal or external, automated or human — is authenticated, authorized, encrypted, and logged.

## Identity

- **Keycloak** is the single source of identity. No service implements its own login.
- Tokens are **JWT** (RS256), short-lived (≤ 15 minutes), with refresh tokens stored client-side only.
- Required claims: `sub`, `iss`, `aud`, `exp`, `iat`, `roles`, `tenant_id` (where applicable).
- Token validation happens **twice** for external traffic:
  1. **YARP** — first defense at the edge (`iss`, `aud`, signature, `exp`).
  2. **Target service** — defense in depth (re-validates same fields, plus `roles`).

## Authorization

- `[Authorize]` is the **default** on every controller and gRPC service. `[AllowAnonymous]` requires explicit, reviewed justification.
- Role checks at the boundary; never inside data access.
- For multi-tenant data, enforce `tenant_id` filtering inside Stored Procedures (parameter, not interpolated).
- Row-Level Security predicates in MSSQL for tenant isolation.

## Transport

- **External traffic (Internet → YARP):** HTTPS only, TLS 1.3 preferred. HSTS enabled. Modern cipher suites.
- **Internal traffic (Pod ↔ Pod):** automatic **mTLS via Linkerd**, certificates rotated every 24h.
- **Out-of-mesh internal traffic** (Vault, Keycloak, Redis, OpenSearch, Qdrant): TLS at the transport level, certificates pinned where supported.

## Secrets

- **HashiCorp Vault** is the only production source of secrets.
- Never store secrets in `appsettings.json`, environment variables baked into images, Git, or wikis.
- Local dev uses `dotnet user-secrets` only.
- See [`../skills/vault.md`](../skills/vault.md).

## Database security

- Each service has **its own MSSQL login** with permissions only on its own database.
- Permissions: `GRANT EXEC` on Stored Procedures only. **No** `SELECT/INSERT/UPDATE/DELETE` granted directly on tables.
- Row-Level Security for tenant isolation.
- Auditing via Triggers + an immutable audit schema.
- Backup encryption + Transparent Data Encryption (TDE).

## Inter-service trust

- Service-to-service calls carry the original user's JWT (forwarded as gRPC metadata), preserving identity through the chain.
- Where a worker initiates a call without a user (e.g., a scheduled job), it uses a **service-account JWT** from Keycloak — scoped narrowly.
- Never trust the source pod identity alone; always validate JWT + mTLS.

## Input validation

- Validate at the boundary: REST controller, gRPC service method, message handler.
- Use FluentValidation or DataAnnotations + Model State.
- Never trust client-side validation.
- Reject and log unknown fields.

## Output safety

- DTOs only — never expose internal entities or full domain models.
- Never log secrets, tokens, full request bodies, or PII (use field-level masking).
- ProblemDetails for REST errors must not leak internal stack traces.
- gRPC Status details must not include sensitive context.

## Rate limiting and abuse protection

- **YARP** applies per-IP and per-token rate limits at the edge.
- Circuit breakers (Polly) at the application layer for outbound calls.
- Quotas for high-cost endpoints (file upload, AI inference) tracked in Redis.

## Logging and audit

- Every authenticated request logs: timestamp, `sub`, `tenant_id`, action, target, outcome, Correlation Id.
- Audit logs go to an append-only sink (OpenSearch with index lifecycle) and are immutable.
- Failed auth attempts emit a metric (alerting > 5 / minute per IP).

## Container & cluster hardening

- Run containers as **non-root** with read-only filesystems where possible.
- Drop all Linux capabilities; add back only what is needed.
- Use Pod Security Standards (`restricted` profile).
- Network Policies: by default, deny all; allow only declared service-to-service paths.
- Secrets injected via Vault Agent sidecar — never via Kubernetes Secrets in plain YAML.

## Dependency hygiene

- `dotnet list package --vulnerable` in CI; build fails on `Critical` or `High`.
- Snyk + Dependabot for libraries; Trivy for container images.
- Renovate / Dependabot weekly schedule, with security PRs auto-merged after green CI.

## Secrets-in-CI

- CI runners pull secrets from Vault via short-lived tokens — never long-lived static credentials.
- No secret values printed in logs.

## Review and enforcement

- See [`../checklists/security-checklist.md`](../checklists/security-checklist.md) for the per-PR review checklist.
- See [`../constraints/security-enforcement.md`](../constraints/security-enforcement.md) for the bans and required controls.

## Forbidden patterns (quick list)

- JWT in URL query strings.
- Bearer tokens logged or stored at rest.
- Wildcard CORS in production.
- Self-signed certificates trusted globally.
- Direct DB access by another service.
- Hardcoded admin tokens, bypass headers, or "magic" parameters.
- `[AllowAnonymous]` on data-touching endpoints.
