# Security Enforcement (Required Controls)

Each control below is **mandatory**. Builds or deployments that fail any control must be blocked.

## 1. Identity & Tokens

| Control | Enforced where | How |
|---|---|---|
| Single identity provider (Keycloak) | All services | No `AddIdentity()` / Identity DB in any service |
| JWT bearer only | All services | `JwtBearerDefaults` configured; no cookie auth on APIs |
| Audience validated | All services | `o.Audience = "<service>"` set; `ValidateAudience = true` |
| Issuer validated | All services | `o.Authority` points to Keycloak realm; `ValidateIssuer = true` |
| Signature validated | All services | `ValidateIssuerSigningKey = true`; JWKS auto-discovered |
| Lifetime validated | All services | `ValidateLifetime = true`; ClockSkew ≤ 30s |
| Token TTL ≤ 15 minutes | Keycloak realm | Realm config + audit |
| Refresh-token rotation | Keycloak realm | "Revoke Refresh Token" enabled |
| MFA for admin roles | Keycloak realm | Required action: configure OTP |

## 2. Authorization

| Control | Enforced where | How |
|---|---|---|
| `[Authorize]` default policy | All services | `FallbackPolicy = RequireAuthenticatedUser()` |
| Policy required per endpoint | Controllers / gRPC services | `[Authorize(Policy = "...")]` |
| Role check by name | Policies | Defined in Keycloak; validated as JWT `roles` claim |
| Tenant filter in every multi-tenant SP | MSSQL | `@TenantId` parameter required |
| Row-Level Security | MSSQL | `CREATE SECURITY POLICY` per tenant table |

## 3. Transport Security

| Control | Enforced where | How |
|---|---|---|
| HTTPS only (external) | YARP | `UseHttpsRedirection`; HSTS header |
| mTLS (internal) | Linkerd | `linkerd.io/inject: enabled` on every namespace |
| TLS to Vault, Keycloak, Redis, MSSQL | All clients | Verified by integration tests + Trivy config scanning |
| TLS 1.3 preferred, 1.2 minimum | Edge | Cipher suite allow-list at LB/Ingress |

## 4. Secrets

| Control | Enforced where | How |
|---|---|---|
| No secrets in Git | Repo | `gitleaks` + `truffleHog` in pre-commit hooks + CI |
| No secrets in container images | CI | Trivy scan + base image policy |
| Vault is the only prod secrets source | All workloads | Pod annotations validated by admission controller (Kyverno) |
| Dynamic MSSQL credentials | Workloads | Vault `database` engine; TTL ≤ 1h |
| Secrets rotated on policy | Vault | Rotation cadence configured per engine |

## 5. Data Protection

| Control | Enforced where | How |
|---|---|---|
| TDE on production MSSQL | DB | `ALTER DATABASE SET ENCRYPTION ON` |
| Backups encrypted | DB / object storage | Native MSSQL backup encryption + KMS |
| PII masked in logs | All apps | Serilog destructuring policies + OTLP collector processor |
| PII tokenized at rest where required | App layer | Vault transit engine |
| Audit triggers on sensitive tables | MSSQL | Triggers writing to immutable `audit.*` schema |

## 6. Network

| Control | Enforced where | How |
|---|---|---|
| NetworkPolicy default-deny | Every namespace | Per-namespace deny-all + explicit allow |
| YARP is the only public ingress | Cluster edge | Ingress controller config + admission policy |
| No NodePorts / hostNetwork | All workloads | Admission policy |
| Linkerd `Server` + `ServerAuthorization` per service | Service namespaces | `linkerd.io/policy.v1beta1` resources |

## 7. Container & Cluster

| Control | Enforced where | How |
|---|---|---|
| Pod Security `restricted` | All namespaces | `pod-security.kubernetes.io/enforce: restricted` |
| `runAsNonRoot` | All pods | Container `securityContext` |
| `readOnlyRootFilesystem` | All pods | Container `securityContext` |
| Drop all Linux capabilities | All pods | Container `securityContext` |
| Image signing required | Cluster admission | Cosign + admission controller |
| Vulnerability scanning required | CI | Trivy (`HIGH/CRITICAL` blocks) |
| Resource requests + limits | All containers | Admission policy |
| Probes (liveness + readiness) | All pods | Admission policy |

## 8. Dependencies

| Control | Enforced where | How |
|---|---|---|
| No vulnerable NuGet packages (`Critical`/`High`) | CI | `dotnet list package --vulnerable` |
| SBOM generated per build | CI | `dotnet-sbom-tool` + artifact upload |
| License allow-list | CI | License scanner gate |
| Renovate / Dependabot weekly | Repo | Schedule + auto-merge security patches |

## 9. CI / CD

| Control | Enforced where | How |
|---|---|---|
| Branch protection | Repo | At least 1 reviewer; status checks pass |
| No long-lived CI credentials | CI | Vault Approle, TTL ≤ 1h |
| Image push only from main / release branches | Registry | Webhook / policy |
| Deployment via GitOps | Cluster | Argo CD / Flux only; manual `kubectl` forbidden in prod |

## 10. Observability for Security

| Control | Enforced where | How |
|---|---|---|
| Failed-auth metric and alert | All services | Custom Meter + Grafana alert (> 5/min/IP) |
| Audit log immutability | OpenSearch | Index lifecycle policy: write-once index per month |
| Security events forwarded to SIEM | Cluster | OTLP → collector → SIEM exporter |

## Block-on-Fail Matrix

| Layer | Tool | Action on failure |
|---|---|---|
| Code | Roslyn analyzers (`Microsoft.CodeAnalysis.NetAnalyzers`) | Build fails |
| Lints | `dotnet format` | Build fails |
| Secrets scan | gitleaks | PR blocked |
| Dep scan | `dotnet list package --vulnerable`, Snyk, Dependabot | PR blocked on High/Critical |
| Container scan | Trivy | Image push blocked on High/Critical |
| Image signing | Cosign | Admission blocks unsigned images |
| Policy | Kyverno / OPA Gatekeeper | Admission rejects non-compliant resources |

## Related

- [`forbidden-patterns.md`](./forbidden-patterns.md)
- [`../core/security.md`](../core/security.md)
- [`../checklists/security-checklist.md`](../checklists/security-checklist.md)
- [`../skills/vault.md`](../skills/vault.md)
- [`../skills/keycloak.md`](../skills/keycloak.md)
- [`../skills/kubernetes.md`](../skills/kubernetes.md)
