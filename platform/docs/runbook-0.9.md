# Runbook - Phase 0.9: AI Layer (Qdrant + Ollama; vLLM/GPU for prod)

Internal AI platform for Retrieval-Augmented Generation (RAG). Everything runs **inside the
cluster**; no data or inference request ever leaves the environment.

- **Qdrant** - 3-node vector database cluster; the RAG store.
- **Ollama** - CPU inference; serves **both** the chat LLM (`qwen2.5:1.5b`) and the embedding
  model `bge-m3` (1024-dim, multilingual incl. Arabic).
- **vLLM** - GPU inference, OpenAI-compatible API; chat model `Qwen2.5-1.5B-Instruct`. This is the
  **production** path and requires an NVIDIA GPU node - **it is NOT deployed in dev** (this VM has
  no GPU). The manifests live under `vllm/` + `gpu/` for the prod profile.

> **Profiles.** The dev VM has **no GPU**, so the chat LLM runs on CPU via Ollama alongside the
> embedding model. In production the chat LLM moves to **vLLM on a GPU node** (larger models:
> Llama 3 / Qwen 2.5 / Mixtral); Ollama can stay for embeddings or be replaced by a GPU embedder.

Namespace: `ai` (baseline PSA, **out of the Linkerd mesh** in dev, consistent with the other
data stores).

---

## 1. Architecture

```
              (microservice namespaces: ns-identity / ns-assets / ns-discovery)
                                   |  (NetworkPolicy-allowed only)
        chat + embeddings          v                                  vectors
   +------------------------------------+        +------------------------------+
   |  Ollama  (CPU)                     |        |   Qdrant cluster (3 nodes)   |
   |  :11434 /v1/chat/completions       |        |   :6333 REST / :6334 gRPC    |
   |  :11434 /api/embed                 |        |   5 collections, repl=2      |
   |  chat: qwen2.5:1.5b | embed: bge-m3|        |   /metrics (chart Svc Mon)   |
   +------------------------------------+        +------------------------------+
                                                            |
                                              Prometheus (Phase 0.8) <- ServiceMonitor (Qdrant)

   prod/GPU path (not in dev):  vLLM :8000 /v1/...  serving Qwen2.5-1.5B-Instruct on an NVIDIA node
```

RAG flow: a service embeds text with **bge-m3** (Ollama), upserts/searches vectors in **Qdrant**,
then calls **vLLM** (Qwen2.5) with the retrieved context for grounded answers.

## 2. Collections

Created idempotently by the `qdrant-collections-init` Job. All use the bge-m3 vector shape:

| Collection | Purpose | size | distance | shards | replication |
|---|---|---|---|---|---|
| `knowledge_base`  | general knowledge      | 1024 | Cosine | 2 | 2 |
| `past_incidents`  | historical incidents   | 1024 | Cosine | 2 | 2 |
| `policies`        | policies & procedures  | 1024 | Cosine | 2 | 2 |
| `scripts`         | scripts                | 1024 | Cosine | 2 | 2 |
| `device_profiles` | device profiles        | 1024 | Cosine | 2 | 2 |

`replication_factor=2` means a collection survives the loss of one Qdrant peer. On a single-node
dev VM the three peers share one machine, so replication is **nominal** (no real HA) - prod
spreads peers across real nodes.

## 3. Key decisions (dev/CPU)

- **No GPU on the dev VM** (`lspci` shows no NVIDIA card), so the chat LLM runs on **CPU via
  Ollama** alongside the embedding model. vLLM/GPU is the production path (`vllm/` + `gpu/`),
  not deployed here.
- **Ollama serves both** `qwen2.5:1.5b` (chat) and `bge-m3` (embeddings). bge-m3 (1024 dims) is
  multilingual, strong on Arabic, and fixes the vector size for every collection.
- **Internal only.** No `LoadBalancer`, no `NodePort`, no YARP route. AI is reachable only from
  the microservice namespaces (and Prometheus for Qdrant `/metrics`) via NetworkPolicies.
- **API key.** Qdrant requires an `api-key` header (generated once, mirrored to Vault). Ollama
  has no built-in auth and is protected by NetworkPolicy fencing only (internal).
- **One-time model pull.** Ollama pulls bge-m3 + qwen2.5:1.5b on first provisioning. This is a
  *provisioning* fetch (like pulling a container image), not runtime data egress. The
  `allow-https-egress-for-model-pull` NetworkPolicy permits it; prod removes this rule and uses
  an internal mirror.

## 4. Prerequisites

- Phases 0.1-0.8 healthy (cluster + Longhorn, Vault unsealed, kube-prometheus-stack so the
  Qdrant chart's ServiceMonitor is picked up).
- **No GPU required** for the dev/CPU profile. (For the production vLLM path you need an NVIDIA
  GPU node with **nvidia-container-toolkit** on the host so K3s registers the NVIDIA runtime,
  then apply `gpu/nvidia-device-plugin.yaml` and the `vllm/` manifests.)

## 5. Deploy

```bash
cd ~/itOrchestra/platform
bash bootstrap/08-ai-dev.sh        # install + verify
# or individually:
bash k8s/ai/install-dev.sh
bash bootstrap/verify-0.9.sh
```

The installer is idempotent: API-key secrets are generated once; Helm/manifests re-apply
cleanly; the collections Job is deleted+recreated each run and is itself idempotent.

## 6. Verify

`verify-0.9.sh` checks: `ai` out of mesh; Qdrant 3/3 + Ollama Ready; all 5 collections present;
Qdrant cluster mode enabled; **live chat** (Ollama `qwen2.5:1.5b` -> `200`) and **live embedding**
(Ollama `bge-m3`); no `LoadBalancer`/`NodePort` + `default-deny` present; Qdrant ServiceMonitor
present; Vault mirror matches.

## 7. Using the AI layer (from a service)

Read endpoints + key from Vault (`secret/itorchestra/shared/ai`): `qdrant-endpoint`,
`qdrant-api-key`, `llm-endpoint`, `llm-openai-endpoint`, `chat-model`, `embedding-model`,
`embedding-dims`. The `ai-models-catalog` ConfigMap mirrors the same info.

Embed (Ollama):

```bash
curl -s http://ollama.ai.svc.cluster.local:11434/api/embed \
  -d '{"model":"bge-m3","input":"how do I reset a switch port"}'
```

Search Qdrant (REST):

```bash
curl -s http://qdrant.ai.svc.cluster.local:6333/collections/knowledge_base/points/search \
  -H "api-key: $QDRANT_KEY" -H 'Content-Type: application/json' \
  -d '{"vector":[/* 1024 floats */],"limit":5,"with_payload":true}'
```

Chat (Ollama, OpenAI-compatible):

```bash
curl -s http://ollama.ai.svc.cluster.local:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:1.5b","messages":[{"role":"user","content":"..."}]}'
```

> Per the project rules, services integrate with the AI layer over **HTTP with Polly** resilience
> policies (retry / timeout / circuit breaker) and a **Correlation-Id** header. In production the
> chat endpoint becomes the vLLM service (`Authorization: Bearer`), read from the same Vault path.

## 8. Observability

- Qdrant exposes Prometheus metrics at `:6333/metrics`, scraped via the chart's ServiceMonitor
  (exempt from the API key) and visible in the Phase 0.8 Grafana/Prometheus.
- Ollama has no native Prometheus endpoint, so there are no LLM metrics in the dev/CPU profile.
  The production vLLM path exposes rich `/metrics` (request counts, latency, token throughput,
  GPU cache) via the `vllm` ServiceMonitor.

## 9. Consumption controls & rate limiting

- A namespace **ResourceQuota** caps total CPU/RAM (add the GPU quota for the vLLM path); a
  **LimitRange** supplies per-container defaults. No workload can starve the node.
- **Request rate limiting** is enforced by the *callers* (Polly + an internal AI BFF/aggregator),
  not by a public gateway - the AI layer is never fronted by YARP. Document/implement per-caller
  limits in the consuming services.

## 10. Troubleshooting

- **Chat is slow** -> expected: `qwen2.5:1.5b` runs on CPU here. Fine for verification/RAG dev,
  not for load. Move chat to vLLM on a GPU node for production throughput.
- **Ollama model missing** -> re-pull: `kubectl -n ai exec deploy/ollama -- ollama pull bge-m3`
  (or `qwen2.5:1.5b`). List loaded models: `kubectl -n ai exec deploy/ollama -- ollama list`.
- **Ollama OOM / evicted** -> two models resident is heavy; lower `OLLAMA_KEEP_ALIVE`, set
  `OLLAMA_MAX_LOADED_MODELS=1`, or raise the memory limit in `ollama/deployment.yaml`.
- **Collections Job failing** -> check Qdrant is Ready and the api-key secret matches:
  `kubectl -n ai logs job/qdrant-collections-init`.
- **Qdrant ServiceMonitor not scraped** -> ensure Phase 0.8 is installed (Prometheus Operator
  CRDs) before deploying the Qdrant chart (which creates the ServiceMonitor).
- **Production vLLM Pending** -> `kubectl -n ai describe pod -l app=vllm`: usually `Insufficient
  nvidia.com/gpu` (device plugin not running or host lacks nvidia-container-toolkit). CUDA
  CrashLoop -> pin `vllm/vllm-openai` to a tag matching the host driver.

## 11. Teardown (dev)

```bash
helm -n ai uninstall qdrant
kubectl delete -f k8s/ai/ollama/ --ignore-not-found
kubectl -n ai delete job qdrant-collections-init --ignore-not-found
kubectl delete -f k8s/ai/networkpolicy.yaml \
  -f k8s/ai/models-catalog.yaml -f k8s/ai/resourcequota.yaml --ignore-not-found
kubectl delete ns ai            # also removes PVCs (ollama-models, qdrant data)
```
