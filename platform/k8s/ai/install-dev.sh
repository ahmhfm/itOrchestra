#!/usr/bin/env bash
# Deploy the AI layer (Phase 0.9) into the 'ai' namespace - DEV (CPU) profile:
#   - Qdrant ............ 3-node vector DB cluster (RAG store), API-key protected
#   - 5 collections ..... knowledge_base / past_incidents / policies / scripts / device_profiles
#                         (bge-m3 = 1024 dims, Cosine, 2 shards, replication_factor 2)
#   - Ollama ........... CPU inference, serves BOTH chat (qwen2.5:1.5b) and embeddings (bge-m3)
# Fully internal (no LoadBalancer, no YARP). Endpoints + Qdrant key mirrored into Vault.
#
# NOTE: this dev VM has no NVIDIA GPU, so we run the LLM on CPU via Ollama. The vLLM (GPU)
# manifests under vllm/ + gpu/ are the PRODUCTION path (deploy them on GPU nodes); they are
# intentionally NOT applied here. See docs/runbook-0.9.md.
#
# Out of the Linkerd mesh (dev). Idempotent: secrets generated once; manifests/helm re-apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"          # .../platform/k8s
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="ai"
VAULT_NS="vault"
QDRANT_CHART_VERSION="${QDRANT_CHART_VERSION:-}"
CHAT_MODEL="${CHAT_MODEL:-qwen2.5:1.5b}"
EMBED_MODEL="${EMBED_MODEL:-bge-m3}"

ver_arg() { [ -n "$1" ] && printf -- "--version %s" "$1" || true; }
gen_key() { openssl rand -hex 32; }

echo "==> [0.9/ai] Ensuring the 'ai' namespace (baseline PSA, out of mesh)"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ai
  labels:
    name: ai
    pod-security.kubernetes.io/enforce: baseline
  annotations:
    linkerd.io/inject: disabled
EOF

echo "==> Applying consumption controls (ResourceQuota + LimitRange)"
kubectl apply -f "${SCRIPT_DIR}/resourcequota.yaml"

echo "==> Ensuring Qdrant API-key Secret"
if ! kubectl -n "${NS}" get secret qdrant-apikey >/dev/null 2>&1; then
  kubectl -n "${NS}" create secret generic qdrant-apikey --from-literal=api-key="$(gen_key)"
  echo "    created secret qdrant-apikey"
else
  echo "    secret qdrant-apikey already exists (skip)"
fi

echo "==> Adding Helm repo (qdrant)"
add_repo() {
  for i in 1 2 3; do
    helm repo add "$1" "$2" --force-update >/dev/null 2>&1 && return 0
    echo "    retry helm repo add $1 ($i/3)"; sleep 3
  done
  echo "    !! failed to add Helm repo '$1' ($2)" >&2; return 1
}
add_repo qdrant https://qdrant.github.io/qdrant-helm
helm repo update qdrant >/dev/null

echo "==> Deploying Qdrant (3-node cluster)"
helm upgrade --install qdrant qdrant/qdrant \
  --namespace "${NS}" $(ver_arg "${QDRANT_CHART_VERSION}") \
  -f "${SCRIPT_DIR}/qdrant/values.yaml"
kubectl -n "${NS}" rollout status statefulset/qdrant --timeout=600s

echo "==> Ensuring the 5 RAG collections"
kubectl -n "${NS}" delete job qdrant-collections-init --ignore-not-found
kubectl apply -f "${SCRIPT_DIR}/qdrant/collections-init.yaml"
kubectl -n "${NS}" wait --for=condition=complete job/qdrant-collections-init --timeout=300s

echo "==> Deploying Ollama (CPU: chat + embeddings)"
kubectl apply -f "${SCRIPT_DIR}/ollama/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/ollama/deployment.yaml"
kubectl -n "${NS}" rollout status deploy/ollama --timeout=300s
echo "    pulling embedding model '${EMBED_MODEL}' (one-time, ~2.2GB) ..."
kubectl -n "${NS}" exec deploy/ollama -- ollama pull "${EMBED_MODEL}"
echo "    pulling chat model '${CHAT_MODEL}' (one-time, ~1GB) ..."
kubectl -n "${NS}" exec deploy/ollama -- ollama pull "${CHAT_MODEL}"

echo "==> Applying Models Catalog and NetworkPolicies"
kubectl apply -f "${SCRIPT_DIR}/models-catalog.yaml"
kubectl apply -f "${SCRIPT_DIR}/networkpolicy.yaml"
# Qdrant ships its own ServiceMonitor (metrics.serviceMonitor.enabled). Ollama has no native
# Prometheus endpoint, so there is no AI-LLM ServiceMonitor in the dev/CPU profile.

echo "==> Mirroring AI endpoints + key into Vault (secret/itorchestra/shared/ai)"
QDRANT_KEY="$(kubectl -n "${NS}" get secret qdrant-apikey -o jsonpath='{.data.api-key}' | base64 -d)"
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  kubectl -n "${VAULT_NS}" exec -i vault-0 -- env \
    VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
    QDRANT_KEY="${QDRANT_KEY}" CHAT_MODEL="${CHAT_MODEL}" EMBED_MODEL="${EMBED_MODEL}" \
    sh -s <<'EOSH'
set -e
vault kv put secret/itorchestra/shared/ai \
  qdrant-endpoint="http://qdrant.ai.svc.cluster.local:6333" \
  qdrant-grpc="qdrant.ai.svc.cluster.local:6334" \
  qdrant-api-key="$QDRANT_KEY" \
  llm-engine="ollama" \
  llm-endpoint="http://ollama.ai.svc.cluster.local:11434" \
  llm-openai-endpoint="http://ollama.ai.svc.cluster.local:11434/v1" \
  chat-model="$CHAT_MODEL" \
  embedding-model="$EMBED_MODEL" \
  embedding-dims="1024"
echo "  seeded: secret/itorchestra/shared/ai"
EOSH
else
  echo "    !! could not read Vault root token (sealed? Phase 0.5?); skipping Vault mirror" >&2
fi

echo "==> AI layer state:"
kubectl -n "${NS}" get pods,svc,pvc -o wide
echo "==> Resolved chart versions:"
helm -n "${NS}" list

echo "==> [0.9/ai] Deploy done (dev/CPU profile)."
echo "    Qdrant (REST):  http://qdrant.ai.svc.cluster.local:6333  (header: api-key)"
echo "    Ollama chat:    http://ollama.ai.svc.cluster.local:11434/v1/chat/completions  (model: ${CHAT_MODEL})"
echo "    Ollama embed:   http://ollama.ai.svc.cluster.local:11434/api/embed            (model: ${EMBED_MODEL})"
echo "    Keys/endpoints: vault kv get secret/itorchestra/shared/ai"
echo "    (vLLM/GPU manifests under vllm/ + gpu/ are the production path; not deployed in dev.)"
