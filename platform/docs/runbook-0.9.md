# Runbook - Phase 0.9: AI Layer (Qdrant + vLLM + Ollama)

Internal AI platform for Retrieval-Augmented Generation (RAG). Everything runs **inside the
cluster**; no data or inference request ever leaves the environment.

- **Qdrant** - 3-node vector database cluster; the RAG store.
- **vLLM** - GPU inference, OpenAI-compatible API; chat model `Qwen2.5-1.5B-Instruct`.
- **Ollama** - CPU inference; embedding model `bge-m3` (1024-dim, multilingual incl. Arabic).

Namespace: `ai` (baseline PSA, **out of the Linkerd mesh** in dev, consistent with the other
data stores).

---

## 1. Architecture

```
              (microservice namespaces: ns-identity / ns-assets / ns-discovery)
                                   |  (NetworkPolicy-allowed only)
        embeddings (bge-m3)        v            chat (OpenAI API)         vectors
   +----------------------+   +---------------------+   +------------------------------+
   |  Ollama  (CPU)       |   |   vLLM  (GPU)       |   |   Qdrant cluster (3 nodes)   |
   |  :11434 /api/embed   |   |   :8000 /v1/...     |   |   :6333 REST / :6334 gRPC    |
   |  model: bge-m3       |   |   Qwen2.5-1.5B       |   |   5 collections, repl=2      |
   +----------------------+   +---------------------+   +------------------------------+
            \_______________________ /metrics ________________________/
                                   |
                          Prometheus (Phase 0.8)  <- ServiceMonitors (vLLM, Qdrant)
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

## 3. Key decisions (dev)

- **vLLM (GPU) for chat, Ollama (CPU) for embeddings.** The dev GPU is **6 GB** - just enough for
  Qwen2.5-1.5B + KV cache. Running embeddings on CPU keeps the GPU dedicated to generation.
- **bge-m3 (1024 dims)** as the embedding model: multilingual, strong on Arabic, which fixes the
  vector size for every collection.
- **Internal only.** No `LoadBalancer`, no `NodePort`, no YARP route. AI is reachable only from
  the microservice namespaces (and Prometheus for `/metrics`) via NetworkPolicies.
- **API keys.** Qdrant requires an `api-key` header; vLLM requires `Authorization: Bearer`. Both
  keys are generated once and mirrored to Vault.
- **One-time model pull.** vLLM downloads Qwen weights from HuggingFace and Ollama pulls bge-m3
  on first start. This is a *provisioning* fetch (like pulling a container image), not runtime
  data egress. The `allow-https-egress-for-model-pull` NetworkPolicy permits it; prod removes
  this rule and uses an internal mirror.

## 4. Prerequisites

- Phases 0.1-0.8 healthy (cluster + Longhorn, Vault unsealed, kube-prometheus-stack for
  ServiceMonitors).
- An **NVIDIA GPU** on the node, with **nvidia-container-toolkit** installed on the host so K3s
  registers the NVIDIA container runtime. Verify:

```bash
nvidia-smi
kubectl describe node <node> | grep nvidia.com/gpu   # should show >= 1 after the device plugin
```

If `nvidia.com/gpu` is `0`, install the toolkit on the host and restart K3s, then re-run the
installer (it deploys the device plugin and fails early with guidance if no GPU is found).

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

`verify-0.9.sh` checks: `ai` out of mesh; node advertises a GPU; Qdrant 3/3 + vLLM + Ollama
Ready; all 5 collections present; Qdrant cluster mode enabled; **live chat** (vLLM `200`) and
**live embedding** (Ollama bge-m3); no `LoadBalancer`/`NodePort` + `default-deny` present;
ServiceMonitors present; Vault mirror matches.

## 7. Using the AI layer (from a service)

Read endpoints + keys from Vault (`secret/itorchestra/shared/ai`): `qdrant-endpoint`,
`qdrant-api-key`, `vllm-endpoint`, `vllm-api-key`, `ollama-endpoint`, `chat-model`,
`embedding-model`, `embedding-dims`. The `ai-models-catalog` ConfigMap mirrors the same info.

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

Chat (vLLM, OpenAI-compatible):

```bash
curl -s http://vllm.ai.svc.cluster.local:8000/v1/chat/completions \
  -H "Authorization: Bearer $VLLM_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-1.5b-instruct","messages":[{"role":"user","content":"..."}]}'
```

> Per the project rules, services integrate with the AI layer over **HTTP with Polly** resilience
> policies (retry / timeout / circuit breaker) and a **Correlation-Id** header.

## 8. Observability

- vLLM exposes Prometheus metrics at `/metrics` (request counts, latency, token throughput, GPU
  cache usage); Qdrant at `:6333/metrics`. Both are scraped via the ServiceMonitors and visible
  in the Phase 0.8 Grafana/Prometheus.
- Both `/metrics` endpoints are exempt from API-key auth (Qdrant exempts `/metrics` + health;
  vLLM only guards `/v1/*`), so Prometheus needs no credentials.

## 9. Consumption controls & rate limiting

- A namespace **ResourceQuota** caps total CPU/RAM and the single GPU; a **LimitRange** supplies
  per-container defaults. No workload can starve the node.
- **Request rate limiting** is enforced by the *callers* (Polly + an internal AI BFF/aggregator),
  not by a public gateway - the AI layer is never fronted by YARP. Document/implement per-caller
  limits in the consuming services.

## 10. Troubleshooting

- **vLLM Pending** -> `kubectl -n ai describe pod -l app=vllm`. Usually `Insufficient
  nvidia.com/gpu`: the device plugin isn't running or the host lacks nvidia-container-toolkit.
- **vLLM CrashLoop on CUDA/driver** -> the `vllm/vllm-openai:latest` image may need a newer CUDA
  driver than the host. Pin the image to a tag matching your driver in `vllm/deployment.yaml`.
- **vLLM OOM (GPU)** -> 6 GB is tight; lower `--gpu-memory-utilization` or `--max-model-len`, or
  use a smaller model.
- **First start is slow** -> model weights download on first run (startupProbe allows ~20 min for
  vLLM). Watch: `kubectl -n ai logs -f deploy/vllm`.
- **Ollama bge-m3 missing** -> re-run the pull: `kubectl -n ai exec deploy/ollama -- ollama pull bge-m3`.
- **Collections Job failing** -> check Qdrant is Ready and the api-key secret matches:
  `kubectl -n ai logs job/qdrant-collections-init`.
- **ServiceMonitors not scraped** -> ensure Phase 0.8 is installed (CRDs) and the Qdrant Service
  carries `app.kubernetes.io/name: qdrant` (the ServiceMonitor selector).

## 11. Teardown (dev)

```bash
helm -n ai uninstall qdrant
kubectl delete -f k8s/ai/vllm/ -f k8s/ai/ollama/ --ignore-not-found
kubectl -n ai delete job qdrant-collections-init --ignore-not-found
kubectl delete -f k8s/ai/networkpolicy.yaml -f k8s/ai/servicemonitors.yaml \
  -f k8s/ai/models-catalog.yaml -f k8s/ai/resourcequota.yaml --ignore-not-found
kubectl delete ns ai            # also removes PVCs (vllm-hf-cache, ollama-models, qdrant data)
# device plugin (optional): kubectl delete -f k8s/ai/gpu/nvidia-device-plugin.yaml
```
