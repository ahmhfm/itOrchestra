# Architecture (Core)

High-level architecture map. Load this when reasoning about cross-cutting decisions, new services, or end-to-end request flow.

## Topology

```
                     EXTERNAL CLIENTS
   (WPF / MAUI / Browser / Mobile / 3rd-party APIs)
                          |
                          | HTTPS + JWT (REST/JSON)
                          v
                +---------------------+
                |  YARP API Gateway   |   (single public entry)
                +---------------------+
                          |
                          | mTLS via Linkerd
                          v
        +----------------------------------------+
        |        Kubernetes Cluster (K3s/RKE2)   |
        |                                        |
        |  +-----------------+  REST  +-----+    |
        |  | Service A WebAPI|<------>|     |    |
        |  +-----------------+        |     |    |
        |  | Service A gRPC  |<------>|     |    |
        |  +-----------------+ Linkerd|     |    |
        |  | Service A Worker|        |Linke|    |
        |  +-----------------+        |  rd |    |
        |       |        ^            |     |    |
        |       v        |            |     |    |
        |  +-----------+ |            |     |    |
        |  | MSSQL DB-A| |            |     |    |
        |  +-----------+ |            |     |    |
        |                |            |     |    |
        |  +-----------------+   gRPC |     |    |
        |  | Service B WebAPI|<------>|     |    |
        |  | Service B gRPC  |        |     |    |
        |  | Service B Worker|        |     |    |
        |  +-----------------+        +-----+    |
        |       |                                |
        |  +-----------+                         |
        |  | MSSQL DB-B|                         |
        |  +-----------+                         |
        +----------------------------------------+
                          |
              (events)    | Redis Streams
                          v
              +---------------------+
              |  Redis (Cache+Bus)  |
              +---------------------+

Out-of-mesh shared infrastructure (TLS at transport):
- Keycloak (Identity)
- HashiCorp Vault (Secrets)
- OpenSearch (Search & Analytics)
- Qdrant (Vector DB for AI)
- Tempo + Grafana (Observability)
- Ollama / vLLM (AI Inference)
```

## Layered responsibilities

| Layer | Responsibility | Tech |
|---|---|---|
| Edge | TLS termination, JWT validation, routing, rate limiting | YARP |
| Service mesh | mTLS, retries, timeouts, golden metrics for ALL pod-to-pod traffic | Linkerd |
| Sync inter-service | Strongly-typed contracts, low latency | gRPC + Protobuf |
| Async inter-service | Events, eventual consistency, Saga steps | Redis Streams |
| Application | Business workflow orchestration | C# services (.NET 10) |
| Data access | Call SPs only | ADO.NET (Microsoft.Data.SqlClient) |
| Persistence | All SQL logic | MSSQL Stored Procs / Views / Functions / Triggers |
| Cache + Config (runtime) | Hot reads, feature flags | Redis |
| Identity | SSO, JWT issuance, RBAC | Keycloak |
| Secrets | Connection strings, keys | HashiCorp Vault |
| Background | Scheduled / delayed / recurring jobs | Hangfire in Worker Service pods |
| Observability | Traces + metrics + logs unified | OpenTelemetry → Tempo → Grafana |

## End-to-end request lifecycle (external read)

1. Client sends `HTTPS GET /api/v1/orders/{id}` with `Authorization: Bearer <JWT>`.
2. Ingress / Load Balancer → YARP.
3. YARP terminates TLS, validates JWT against Keycloak issuer/audience, applies rate limit, injects `X-Correlation-Id`, routes to Orders Service.
4. Linkerd sidecar in YARP pod encrypts (mTLS) and forwards to Orders Service pod.
5. Orders Service Controller re-validates JWT (defense in depth), calls Orders Service application service.
6. Application service calls `IDbConnectionFactory` to obtain `SqlConnection`, executes `sp_Orders_Get_OrderById` via ADO.NET (CommandType.StoredProcedure, SqlParameter).
7. If Customer details are needed, Orders Service calls Customers Service gRPC method (over Linkerd mTLS), passing Correlation Id in gRPC metadata.
8. Customers Service executes `sp_Customers_Get_CustomerById` and returns a Protobuf message.
9. Orders Service composes the DTO, returns 200 OK.
10. Response flows back through Linkerd → YARP → Client.
11. Spans for every hop are exported via OpenTelemetry → Tempo; logs land in Grafana with the same Correlation Id.

## End-to-end async event lifecycle (write + propagation)

1. Client posts an order through YARP → Orders Service REST API.
2. Orders Service executes `sp_Orders_Insert_Order` inside a SP transaction.
3. On success, the service publishes `orders.order_created.v1` to Redis Streams.
4. Inventory Service Worker Pod (stream consumer) reads the event, executes `sp_Inventory_Reserve_Stock`, and emits `inventory.stock_reserved.v1`.
5. Notifications Service Worker Pod consumes the event and enqueues a Hangfire job to send the customer email.
6. Each step is idempotent (idempotency key per event id).
7. Failures trigger Saga compensation events.

## Decision tree: where does logic go?

- Pure SQL (joins, aggregations, set-based work) → **Stored Procedure**.
- Data integrity rule that must hold regardless of caller → **Trigger or constraint**.
- Reusable side-effect-free calculation in SQL → **UDF**.
- Cross-table read shape used by many queries → **View / Indexed View**.
- Business workflow (calls multiple services, validates external state) → **C# application service**.
- Cross-cutting (auth, logging, retries) → **DI-registered service + Polly + Linkerd**.

## Related

- [`security.md`](./security.md)
- [`coding-standards.md`](./coding-standards.md)
- [`../patterns/microservice-template.md`](../patterns/microservice-template.md)
- [`../skills/mssql.md`](../skills/mssql.md)
