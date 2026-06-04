# Security Checklist

Run this checklist on every PR and again before promoting to production. Block on any unchecked item.

## Identity & Tokens

- [ ] No service implements its own login or token issuance.
- [ ] JWT bearer authentication configured against Keycloak (Authority + Audience set).
- [ ] `ValidateIssuer`, `ValidateAudience`, `ValidateLifetime`, `ValidateIssuerSigningKey` all `true`.
- [ ] `ClockSkew` ≤ 30 seconds.
- [ ] Token TTL ≤ 15 minutes.
- [ ] Refresh-token rotation enabled in Keycloak.
- [ ] MFA enabled for admin roles.
- [ ] No JWT in URL or logs.

## Authorization

- [ ] `[Authorize(Policy = "...")]` on every endpoint.
- [ ] Fallback policy in DI requires authenticated user.
- [ ] Any `[AllowAnonymous]` has a documented justification.
- [ ] Roles defined in Keycloak; no role tables in service DBs.
- [ ] Multi-tenant SPs accept `@TenantId` and filter by it.
- [ ] Row-Level Security policies applied to tenant tables.

## Secrets

- [ ] No secrets in Git (gitleaks pass).
- [ ] No secrets in container images (Trivy config scan pass).
- [ ] No secrets in `appsettings.Production.json` or environment values baked into images.
- [ ] Vault role scoped to least privilege.
- [ ] Pod annotated for Vault Agent injection.
- [ ] `IOptionsMonitor` reload on Vault file change.
- [ ] Dynamic MSSQL credentials enabled (TTL ≤ 1h).

## Data Access

- [ ] No EF / Dapper / ORM packages referenced.
- [ ] No inline SQL in any `.cs` file.
- [ ] All `SqlCommand` set to `CommandType.StoredProcedure`.
- [ ] All inputs as `SqlParameter` with explicit `SqlDbType` and `Size`.
- [ ] `using` on every ADO.NET disposable.
- [ ] No `SELECT *`; explicit column list.
- [ ] No cross-database / Linked Server references.
- [ ] MSSQL login has only `GRANT EXEC` on procedures.
- [ ] Audit triggers in place for sensitive tables (`audit.*`).

## Transport

- [ ] HTTPS-only at the edge (HSTS + redirect).
- [ ] TLS 1.3 preferred, 1.2 minimum.
- [ ] Linkerd injection enabled on every workload namespace.
- [ ] mTLS verified (`linkerd check --proxy`).
- [ ] CORS allow-list per route (no wildcards in prod).

## Input / Output

- [ ] FluentValidation rule per request DTO.
- [ ] Unknown fields rejected by JSON deserializer.
- [ ] Output uses DTOs (records); no domain entities leaked.
- [ ] Error responses use ProblemDetails with no stack traces.
- [ ] gRPC errors map to correct `StatusCode`; no leaks of internal text.

## Network

- [ ] NetworkPolicy default-deny in the service namespace.
- [ ] Explicit allow rules for required egress (MSSQL, Redis, OTLP, Vault, Keycloak, siblings).
- [ ] Service is `ClusterIP` only (not `NodePort` / `LoadBalancer`).
- [ ] No `hostNetwork: true`.

## Container / Pod Security

- [ ] Pod Security Standard `restricted` enforced.
- [ ] `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`.
- [ ] All Linux capabilities dropped.
- [ ] `seccompProfile: RuntimeDefault`.
- [ ] Image pinned to digest; signed by Cosign.
- [ ] Trivy scan passed (no `High`/`Critical`).

## Inter-Service Trust

- [ ] gRPC server methods carry `[Authorize]`.
- [ ] JWT forwarded as gRPC metadata; consumer services validate it.
- [ ] Worker outbound calls use Keycloak client-credentials tokens.
- [ ] Linkerd `Server` and `ServerAuthorization` constrain who can call this service.

## Background & Messaging

- [ ] Hangfire dashboard secured by Keycloak role.
- [ ] Recurring job ids are stable.
- [ ] Idempotency enforced on stream consumers (dedupe by `event_id`).
- [ ] Dead-letter stream defined and observed.
- [ ] No PII / secrets in event payloads.

## Logging & Audit

- [ ] Structured logging via Serilog → OTLP.
- [ ] No JWTs / secrets / unmasked PII logged.
- [ ] Correlation Id propagated across REST, gRPC, Redis Streams, Hangfire.
- [ ] Audit logs forwarded to OpenSearch in an immutable index.
- [ ] Failed-auth metric + alert (> 5/min/IP).

## Dependencies & Supply Chain

- [ ] `dotnet list package --vulnerable` clean.
- [ ] Snyk / Dependabot clean (no `High`/`Critical`).
- [ ] SBOM generated and stored.
- [ ] License allow-list passes.
- [ ] Renovate keeping minor/patch versions current.

## CI / CD

- [ ] Branch protection requires reviewers + green checks.
- [ ] CI runner uses Vault Approle (TTL ≤ 1h).
- [ ] Production deploys go via Argo CD (no manual `kubectl`).

## Security Tests

- [ ] Negative test: anonymous request → 401.
- [ ] Negative test: wrong role → 403.
- [ ] Negative test: malformed JWT → 401.
- [ ] Negative test: cross-tenant access blocked.
- [ ] Idempotency replay returns same result with no side-effects.

## Pen-test items (periodic)

- [ ] OWASP ASVS Level 2 controls reviewed.
- [ ] DAST scan against staging (ZAP / Burp).
- [ ] Image signature verification proven in admission.

## Related

- [`deployment-checklist.md`](./deployment-checklist.md)
- [`../core/security.md`](../core/security.md)
- [`../constraints/security-enforcement.md`](../constraints/security-enforcement.md)
- [`../constraints/forbidden-patterns.md`](../constraints/forbidden-patterns.md)
