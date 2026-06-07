#!/usr/bin/env bash
# Deploy the AI layer (Phase 0.9) into the 'ai' namespace:
#   - Qdrant ............ 3-node vector DB cluster (RAG store), API-key protected
#   - 5 collections ..... knowledge_base / past_incidents / policies / scripts / device_profiles
#                         (bge-m3 = 1024 dims, Cosine, 2 shards, replication_factor 2)
#   - vLLM .............. GPU inference, OpenAI-compatible, Qwen2.5-1.5B-Instruct (chat)
#   - Ollama ........... CPU embeddings, bge-m3
#   - Models Catalog, ResourceQuota/LimitRange, NetworkPolicies, ServiceMonitors
# Fully internal (no LoadBalancer, no YARP). Endpoints + API keys mirrored into Vault.
#
# Out of the Linkerd mesh (dev). Idempotent: secrets generated once; manifests/helm re-apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"          # .../platform/k8s
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="ai"
VAULT_NS="vault"
QDRANT_CHART_VERSION="${QDRANT_CHART_VERSION:-}"

ver_arg() { [ -n "$1" ] && printf -- "--version %s" "$1" || true; }
gen_key() { openssl rand -hex 32; }

wait_ready() {
  local sel="$1" timeout="${2:-600s}"
  for _ in $(seq 1 60); do
    [ "$(kubectl -n "${NS}" get pod -l "${sel}" --no-headers 2>/dev/null | wc -l)" -ge 1 ] && break
    sleep 5
  done
  kubectl -n "${NS}" wait --for=condition=Ready pod -l "${sel}" --timeout="${timeout}"
}

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

echo "==> Enabling GPU scheduling (NVIDIA device plugin + RuntimeClass)"
kubectl apply -f "${SCRIPT_DIR}/gpu/nvidia-device-plugin.yaml"
echo "    waiting for the node to advertise nvidia.com/gpu ..."
GPU_OK=""
for _ in $(seq 1 24); do
  CAP="$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '\n' | sort -rn | head -1)"
  if [ -n "${CAP:-}" ] && [ "${CAP}" != "0" ]; then GPU_OK="${CAP}"; break; fi
  sleep 5
done
if [ -z "${GPU_OK}" ]; then
  echo "" >&2
  echo "!! No 'nvidia.com/gpu' resource is available on any node." >&2
  echo "   Install nvidia-container-toolkit on the HOST so K3s registers the NVIDIA runtime," >&2
  echo "   then re-run. Check:  kubectl describe node <node> | grep nvidia.com/gpu" >&2
  exit 1
fi
echo "    GPU available (allocatable nvidia.com/gpu=${GPU_OK})"

echo "==> Ensuring API-key Secrets (qdrant-apikey, vllm-apikey)"
for s in qdrant vllm; do
  if ! kubectl -n "${NS}" get secret "${s}-apikey" >/dev/null 2>&1; then
    kubectl -n "${NS}" create secret generic "${s}-apikey" --from-literal=api-key="$(gen_key)"
    echo "    created secret ${s}-apikey"
  else
    echo "    secret ${s}-apikey already exists (skip)"
  fi
done

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

echo "==> Deploying Ollama (CPU embeddings) and pulling bge-m3"
kubectl apply -f "${SCRIPT_DIR}/ollama/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/ollama/deployment.yaml"
kubectl -n "${NS}" rollout status deploy/ollama --timeout=300s
echo "    pulling bge-m3 (one-time, ~2.2GB) ..."
kubectl -n "${NS}" exec deploy/ollama -- ollama pull bge-m3

echo "==> Deploying vLLM (GPU chat inference)"
kubectl apply -f "${SCRIPT_DIR}/vllm/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/vllm/deployment.yaml"
echo "    first start downloads Qwen2.5-1.5B-Instruct + loads onto GPU (can take several minutes) ..."
kubectl -n "${NS}" rollout status deploy/vllm --timeout=1200s

echo "==> Applying Models Catalog, NetworkPolicies, ServiceMonitors"
kubectl apply -f "${SCRIPT_DIR}/models-catalog.yaml"
kubectl apply -f "${SCRIPT_DIR}/networkpolicy.yaml"
kubectl apply -f "${SCRIPT_DIR}/servicemonitors.yaml" || \
  echo "    (ServiceMonitor CRD missing? deploy Phase 0.8 first; non-fatal)"

echo "==> Mirroring AI endpoints + keys into Vault (secret/itorchestra/shared/ai)"
QDRANT_KEY="$(kubectl -n "${NS}" get secret qdrant-apikey -o jsonpath='{.data.api-key}' | base64 -d)"
VLLM_KEY="$(kubectl   -n "${NS}" get secret vllm-apikey   -o jsonpath='{.data.api-key}' | base64 -d)"
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  kubectl -n "${VAULT_NS}" exec -i vault-0 -- env \
    VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
    QDRANT_KEY="${QDRANT_KEY}" VLLM_KEY="${VLLM_KEY}" \
    sh -s <<'EOSH'
set -e
vault kv put secret/itorchestra/shared/ai \
  qdrant-endpoint="http://qdrant.ai.svc.cluster.local:6333" \
  qdrant-grpc="qdrant.ai.svc.cluster.local:6334" \
  qdrant-api-key="$QDRANT_KEY" \
  vllm-endpoint="http://vllm.ai.svc.cluster.local:8000/v1" \
  vllm-api-key="$VLLM_KEY" \
  ollama-endpoint="http://ollama.ai.svc.cluster.local:11434" \
  chat-model="qwen2.5-1.5b-instruct" \
  embedding-model="bge-m3" \
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

echo "==> [0.9/ai] Deploy done."
echo "    Qdrant (REST):  http://qdrant.ai.svc.cluster.local:6333  (header: api-key)"
echo "    vLLM (OpenAI):  http://vllm.ai.svc.cluster.local:8000/v1 (Authorization: Bearer)"
echo "    Ollama embed:   http://ollama.ai.svc.cluster.local:11434/api/embed  (model: bge-m3)"
echo "    Keys/endpoints: vault kv get secret/itorchestra/shared/ai"
