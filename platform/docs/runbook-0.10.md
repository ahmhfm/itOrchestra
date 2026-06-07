# Runbook 0.10 - CrewAI multi-agent orchestration

Phase 0.10 deploys **CrewAI** as a standalone, internal **gRPC service** that coordinates seven
agents to produce grounded, policy-checked, fully audited IT-operations decisions. It is the
first real *application* service in the platform and the first consumer of the 0.9 AI layer.

> **Architecture note (Python vs. .NET).** The platform rules mandate .NET 10 + ADO.NET +
> stored procedures. CrewAI, however, is a **Python-only** framework, so this one service is
> written in Python. It still honors the spirit of the data rules: **all SQL lives in the
> database** and the app only **calls stored procedures** (the DB user has `EXEC` rights and no
> table access). Other services remain .NET and consume CrewAI over gRPC.

---

## 1. What gets deployed (dev profile)

| Piece | Detail |
|------|--------|
| Service | `crewai` Deployment in `ns-crewai` (restricted PSA, **meshed** / Linkerd mTLS) |
| API | gRPC `itorchestra.crewai.v1.CrewOrchestrator` on `:50051`, ClusterIP only |
| LLM backend | Ollama (0.9), chat `qwen2.5:1.5b` via the OpenAI-compatible surface |
| RAG | Qdrant (0.9), per-agent default collection (e.g. Security -> `past_incidents`) |
| Audit DB | `CrewAiDb` on the 0.7 AG primary, **stored-procedures only**, `crewai_app` = `EXEC` only |
| Secrets | endpoint mirrored to Vault `secret/itorchestra/shared/crewai` |

### The seven agents

`Orchestrator` (routes tasks), `Security`, `Performance`, `Patch`, `PowerShell`, `Policy`,
`Compliance`. Each has a role/goal/backstory, a tool set, a default RAG collection, and a slice
of the permissions matrix. See `crewai/app/agents.py` and `crewai/app/permissions.py`.

### Permissions matrix (auto vs. approval)

Resolution order: exact action -> verb prefix (`patch.*`) -> agent default -> **global default
= APPROVAL** (fail-safe). Read-only verbs (`read.kb`, `query.rag`, `analyze`, `assess`,
`scan.*`, `evaluate.policy`, `check.compliance`, ...) are **AUTO** (advisory). Mutating verbs
(`patch.apply`, `powershell.run`, `isolate.host`, `policy.enforce`, `remediate*`, `tune.config`,
`reboot`, ...) are **APPROVAL**. Outcomes:

- **AUTO** -> `ADVISORY` (recommendation only; nothing changed)
- **APPROVAL** -> `PENDING_APPROVAL` (parked; needs `ApproveAction`); approve flips it to `EXECUTED`
- **DENY** -> `REJECTED`

> In dev, action tools are **safe stubs** - even an approved action does not touch a real system,
> because the owning services (assets/discovery/...) don't exist yet. The status model and audit
> trail are real; the side effects are deferred to those services' gRPC APIs.

---

## 2. Prerequisites

- Phases 0.1-0.9 healthy: mesh + Longhorn, **Vault unsealed**, the **0.7 AG** (`mssql-ag-0`
  primary) and the **0.9 AI layer** (Qdrant + Ollama Ready, models pulled).
- `docker` or `nerdctl` on the VM to build the image.
- RAM headroom: the image build pulls crewai + deps; the running pod is light (the heavy LLM
  work happens in the `ai` namespace).

---

## 3. Deploy

```bash
cd ~/itOrchestra/platform
bash bootstrap/09-crewai-dev.sh
```

This runs three steps:

1. `crewai/build-and-import-dev.sh` - builds `itorchestra/crewai:dev` (generates the gRPC stubs
   from `proto/crewai.proto`) and imports it into K3s containerd.
2. `k8s/crewai/install-dev.sh` - ensures `ns-crewai`; generates the `crewai_app` DB password;
   provisions `CrewAiDb` + login + stored procedures on the AG primary (`db/01-*.sql`,
   `db/02-schema.sql`); writes `crewai-config` + `crewai-secrets`; applies Service/Deployment/
   NetworkPolicies; mirrors the endpoint into Vault.
3. `bootstrap/verify-0.10.sh`.

Re-runs are idempotent (passwords reused, SQL guarded with `IF NOT EXISTS`, config re-applied,
pod rolled).

---

## 4. Verify

```bash
bash bootstrap/verify-0.10.sh
```

Checks: `ns-crewai` meshed (linkerd-proxy injected); pod Ready; no LoadBalancer/NodePort +
default-deny present; Vault endpoint mirrored; and the **in-pod gRPC flow** (Health, ListAgents=7,
approval-gated `SubmitTask` -> `PENDING_APPROVAL`, `ApproveAction` -> `EXECUTED`, `GetDecision`
audit read-back, RAG `Query`). The gRPC flow runs inside the pod via `k8s/crewai/scripts/
grpc_smoke.py` (dials `localhost:50051`, reusing the in-image stubs).

> The first `SubmitTask`/`Query` triggers a CPU LLM generation and can take tens of seconds; the
> smoke client uses a generous deadline.

---

## 5. Consuming the service (other itOrchestra services)

The contract is `crewai/proto/crewai.proto` (`package itorchestra.crewai.v1`). .NET services
generate a typed client from this `.proto` and dial
`crewai.ns-crewai.svc.cluster.local:50051` over Linkerd (mTLS, retries, load balancing handled by
the mesh; layer Polly on top for app-level policies). Key RPCs:

- `SubmitTask(agent, prompt, action, target, collection, idempotency_key, requested_by)` ->
  `TaskDecision { decision_id, status, requires_approval, rationale, sources[] }`
- `Query(question, collection, top_k)` -> `QueryResponse { answer, sources[] }`
- `ListPendingApprovals` / `ApproveAction` / `RejectAction`
- `GetDecision(decision_id)` (audit read-back) / `ListAgents` / `Health`

Pass a correlation id via gRPC metadata `x-correlation-id`; it is stored on every decision and
echoed back. (JWT validation is **deferred** in dev - see dev vs prod.)

### Manual probe

```bash
POD=$(kubectl -n ns-crewai get pod -l app=crewai -o jsonpath='{.items[-1:].metadata.name}')
kubectl -n ns-crewai exec -it "$POD" -c crewai -- python - <<'PY'
import grpc, crewai_pb2 as pb, crewai_pb2_grpc as g
s = g.CrewOrchestratorStub(grpc.insecure_channel("localhost:50051"))
print(s.Health(pb.HealthRequest(), timeout=30))
d = s.SubmitTask(pb.SubmitTaskRequest(prompt="Is host web01 missing critical patches?",
                                      action="scan.patches", agent=pb.AgentKind.Value("PATCH")), timeout=300)
print(d.status, d.requires_approval, d.rationale[:200])
PY
```

---

## 6. Audit trail (stored procedures only)

`CrewAiDb` tables: `dbo.AiDecision`, `dbo.AiDecisionSource` (RAG citations), `dbo.AiApproval`.
Access is exclusively via `sp_CrewAi_*` (insert decision, add source, get decision/sources, list
pending, set approval). The `crewai_app` login has `GRANT EXECUTE ON SCHEMA::dbo` and **no table
rights**, so inline DML is impossible by construction. Inspect as `sa` from the AG primary:

```bash
SA=$(kubectl -n mssql get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d)
kubectl -n mssql exec -i mssql-ag-0 -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA" -C \
  -d CrewAiDb -Q "EXEC dbo.sp_CrewAi_Approval_ListPending @Limit=20;"
```

---

## 7. Troubleshooting

- **Pod not Ready / CrashLoop** - `kubectl -n ns-crewai logs deploy/crewai -c crewai`. Common
  causes: DB login failed (check `crewai-secrets` `DB_PASSWORD` matches the `crewai_app` login),
  Qdrant/Ollama unreachable (check the `ai` NetworkPolicy includes `ns-crewai`).
- **Sidecar never gets identity** - confirm `allow-linkerd-egress` exists in `ns-crewai`
  (default-deny would otherwise block the proxy reaching the control plane).
- **`SubmitTask`/`Query` times out** - CPU generation is slow. Dev already defaults to
  `USE_CREWAI=false` (a single direct LLM call, capped at `MAX_TOKENS=256`, `LLM_TIMEOUT_S=240`);
  lower `MAX_TOKENS` further or raise `LLM_TIMEOUT_S` if the node is heavily loaded. The full
  CrewAI crew loop (`USE_CREWAI=true`) issues several LLM calls and is only practical on GPU/prod.
- **Empty `sources[]`** - expected in a fresh cluster: the 0.9 collections start empty, so RAG
  returns no grounding and the agent reasons cautiously. Ingest documents to populate them.
- **DB provisioning failed** - ensure `mssql-ag-0` is the primary and the SA password is correct;
  the AG-add step is best-effort (the DB is usable on the primary even if AG membership is
  deferred).

---

## 8. dev vs prod

| Aspect | dev (this phase) | prod |
|-------|------------------|------|
| Auth | internal + NetworkPolicy only (JWT deferred) | **Keycloak JWT** validated on every gRPC call |
| Reasoning | direct single LLM call (`USE_CREWAI=false`) | full CrewAI crew loop (`USE_CREWAI=true`) |
| LLM | Ollama CPU `qwen2.5:1.5b` | vLLM on GPU, larger models |
| Audit DB | `CrewAiDb` on the shared 0.7 AG instance | CrewAI's **own** private DB instance |
| Action tools | safe stubs (no real changes) | **gRPC calls to the owning services** |
| Image | `:dev`, `IfNotPresent` | pinned digest, internal registry |
| Resilience | mesh defaults | Polly (retry/timeout/circuit-breaker) on top of Linkerd |

Layout: `crewai/` (Python service + proto + Dockerfile), `k8s/crewai/` (SQL, manifests, smoke
client, installer), `bootstrap/09-crewai-dev.sh`, `bootstrap/verify-0.10.sh`.
