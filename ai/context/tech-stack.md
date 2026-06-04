# Tech Stack

Complete inventory of every technology used in the platform, grouped by concern, with the role and the linked skill file.

## Runtime & Languages

| Tech | Version | Role | Skill |
|---|---|---|---|
| .NET | 10 (LTS) | Application runtime | — |
| C# | 14 | Language | [`../core/coding-standards.md`](../core/coding-standards.md) |
| ASP.NET Core | 10 | Web hosting (Web API, MVC, gRPC) | [`../skills/webapi.md`](../skills/webapi.md), [`../skills/mvc.md`](../skills/mvc.md), [`../skills/grpc.md`](../skills/grpc.md) |
| .NET Generic Host | 10 | Worker Service runtime | [`../skills/background-workers.md`](../skills/background-workers.md) |

## Client Frameworks

| Tech | Role | Skill |
|---|---|---|
| WPF | Windows desktop | [`../skills/wpf.md`](../skills/wpf.md) |
| .NET MAUI | macOS / Linux / iOS / Android | [`../skills/maui.md`](../skills/maui.md) |
| CommunityToolkit.Mvvm | MVVM source generators | both above |

## Data

| Tech | Role | Skill |
|---|---|---|
| MSSQL (SQL Server) | Primary persistence; all SQL logic lives here | [`../skills/mssql.md`](../skills/mssql.md) |
| `Microsoft.Data.SqlClient` | ADO.NET driver (only data-access API) | [`../skills/mssql.md`](../skills/mssql.md) |
| DbUp / RoundhousE | Schema migrations | [`../skills/mssql.md`](../skills/mssql.md) |

## Communication

| Tech | Role | Skill |
|---|---|---|
| YARP | External API Gateway (REST) | [`../skills/yarp.md`](../skills/yarp.md) |
| gRPC + Protobuf | Internal sync service-to-service | [`../skills/grpc.md`](../skills/grpc.md) |
| Linkerd | Service mesh (mTLS, retries, observability) | [`../skills/linkerd.md`](../skills/linkerd.md) |
| Redis Streams | Async inter-service events | [`../skills/redis-streams.md`](../skills/redis-streams.md) |

## Caching & Config

| Tech | Role | Skill |
|---|---|---|
| Redis | Cache + dynamic configuration | [`../skills/redis.md`](../skills/redis.md) |
| `Microsoft.Extensions.Caching.StackExchangeRedis` | Distributed cache | [`../skills/redis.md`](../skills/redis.md) |
| `Microsoft.FeatureManagement` | Feature flags backed by Redis/MSSQL | [`../skills/redis.md`](../skills/redis.md) |

## Identity & Secrets

| Tech | Role | Skill |
|---|---|---|
| Keycloak | IAM, JWT, OAuth2 / OIDC | [`../skills/keycloak.md`](../skills/keycloak.md) |
| HashiCorp Vault | Secrets store, dynamic credentials | [`../skills/vault.md`](../skills/vault.md) |

## Background & Messaging

| Tech | Role | Skill |
|---|---|---|
| Hangfire (MSSQL storage) | Scheduled / recurring / delayed jobs | [`../skills/hangfire.md`](../skills/hangfire.md) |
| Redis Streams + Consumer Groups | Async events | [`../skills/redis-streams.md`](../skills/redis-streams.md) |

## Resilience

| Tech | Role | Skill |
|---|---|---|
| Polly + `Microsoft.Extensions.Resilience` | Retries, circuit breakers, timeouts, bulkheads | [`../skills/polly-resilience.md`](../skills/polly-resilience.md) |

## Observability

| Tech | Role | Skill |
|---|---|---|
| OpenTelemetry (.NET) | Traces + metrics + logs | [`../skills/opentelemetry.md`](../skills/opentelemetry.md) |
| Serilog | Structured logging (OTLP sink) | [`../core/coding-standards.md`](../core/coding-standards.md) |
| Tempo | Distributed tracing backend | [`../skills/opentelemetry.md`](../skills/opentelemetry.md) |
| Prometheus | Metrics scraping | [`../skills/opentelemetry.md`](../skills/opentelemetry.md) |
| Loki / OpenSearch | Log aggregation | [`../skills/opentelemetry.md`](../skills/opentelemetry.md) |
| Grafana | Unified visualization & alerting | [`../skills/opentelemetry.md`](../skills/opentelemetry.md) |

## Orchestration & Infra

| Tech | Role | Skill |
|---|---|---|
| Kubernetes (K3s / RKE2) | Workload runtime | [`../skills/kubernetes.md`](../skills/kubernetes.md) |
| Helm | Chart packaging | [`../skills/kubernetes.md`](../skills/kubernetes.md) |
| Kustomize | Environment overlays | [`../skills/kubernetes.md`](../skills/kubernetes.md) |
| Argo CD / Flux | GitOps controller | [`../workflows/deployment-workflow.md`](../workflows/deployment-workflow.md) |
| Cilium / Calico | CNI + NetworkPolicies | [`../skills/kubernetes.md`](../skills/kubernetes.md) |
| Cosign | Image signing | [`../skills/kubernetes.md`](../skills/kubernetes.md) |
| Kyverno / OPA Gatekeeper | Admission policies | [`../constraints/security-enforcement.md`](../constraints/security-enforcement.md) |

## Search & AI

| Tech | Role | Notes |
|---|---|---|
| OpenSearch | Full-text search + analytics | Optional per service |
| Qdrant | Vector database (RAG, semantic search) | Optional |
| Ollama / vLLM | Local LLM inference | Optional |
| CrewAI | Multi-agent orchestration | Optional |

## Testing

| Tech | Role |
|---|---|
| xUnit | Unit testing |
| NSubstitute | Mocking |
| Testcontainers | Real MSSQL/Redis in integration tests |
| Reqnroll (SpecFlow successor) | BDD acceptance |

## DevSecOps

| Tech | Role |
|---|---|
| GitHub Actions / GitLab CI | Pipelines |
| Trivy | Container vulnerability scanning |
| Snyk / Dependabot | Dependency scanning |
| gitleaks / truffleHog | Secret scanning |
| `dotnet-sbom-tool` | SBOM generation |
| Terraform | Cloud infrastructure as code |

## Forbidden technologies (explicit list)

| Tech | Why |
|---|---|
| EF / EF Core / Dapper / NHibernate / LINQ-to-SQL | ADO.NET-only policy |
| Service Fabric / WCF | Replaced by gRPC + Kubernetes |
| MSMQ | Replaced by Redis Streams |
| Quartz.NET as primary scheduler | Replaced by Hangfire |
| Azure SQL Edge in production paths | Use full MSSQL |
| Cookie auth on external REST APIs | JWT only |

## Related

- [`glossary.md`](./glossary.md)
- [`../core/architecture.md`](../core/architecture.md)
- [`../core/system-prompt.md`](../core/system-prompt.md)
