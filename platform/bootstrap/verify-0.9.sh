#!/usr/bin/env bash
# itOrchestra - Phase 0.9 verification (AI layer: Qdrant + vLLM + Ollama).
# Checks: ai namespace out of mesh; node advertises a GPU; Qdrant 3/3 + vLLM + Ollama Ready;
# the 5 RAG collections exist; Qdrant cluster enabled; live chat inference (vLLM) + embedding
# (Ollama bge-m3, 1024-dim); strict external isolation (no LoadBalancer/NodePort + default-deny);
# ServiceMonitors present; endpoints/keys mirrored into Vault.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="ai"
VAULT_NS="vault"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

ready_by_label() {
  local name
  name="$(kubectl -n "${NS}" get pod -l "$1" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
  [ -n "${name}" ] || { echo "NOPOD"; return; }
  kubectl -n "${NS}" get pod "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}
check_ready() { local r; r="$(ready_by_label "$1")"; [ "${r}" = "True" ] && ok "$2 Ready" || bad "$2 not Ready (status='${r}')"; }

echo "== 1) ai namespace out of mesh (no linkerd-proxy) =="
C="$(kubectl -n "${NS}" get pod qdrant-0 -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)"
case " ${C} " in *linkerd-proxy*) bad "linkerd-proxy injected" ;; *) ok "no linkerd-proxy (out of mesh)" ;; esac

echo "== 2) Node advertises a GPU =="
CAP="$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '\n' | sort -rn | head -1)"
[ -n "${CAP:-}" ] && [ "${CAP}" != "0" ] && ok "nvidia.com/gpu allocatable=${CAP}" || bad "no nvidia.com/gpu on any node"

echo "== 3) Component pods Ready =="
RR="$(kubectl -n "${NS}" get statefulset qdrant -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${RR:-0}" = "3" ] && ok "Qdrant cluster 3/3 replicas Ready" || bad "Qdrant readyReplicas='${RR}' (expected 3)"
check_ready "app=vllm"   "vLLM"
check_ready "app=ollama" "Ollama"

echo "== 4-7) In-cluster probes (collections / cluster / vLLM chat / embeddings) =="
QKEY="$(kubectl -n "${NS}" get secret qdrant-apikey -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d)"
VKEY="$(kubectl -n "${NS}" get secret vllm-apikey   -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d)"
PROBE='
set -e
echo "===COLLECTIONS==="; curl -s -H "api-key: $QKEY" http://qdrant.ai.svc.cluster.local:6333/collections; echo
echo "===CLUSTER===";     curl -s -H "api-key: $QKEY" http://qdrant.ai.svc.cluster.local:6333/cluster; echo
echo "===VMODELS===";     curl -s -H "Authorization: Bearer $VKEY" http://vllm.ai.svc.cluster.local:8000/v1/models; echo
echo "===VCHAT===";       curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $VKEY" -H "Content-Type: application/json" -d "{\"model\":\"qwen2.5-1.5b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":5}" http://vllm.ai.svc.cluster.local:8000/v1/chat/completions; echo
echo "===EMBED===";       curl -s -H "Content-Type: application/json" -d "{\"model\":\"bge-m3\",\"input\":\"test embedding\"}" http://ollama.ai.svc.cluster.local:11434/api/embed; echo
echo "===DONE==="
'
OUT="$(kubectl -n "${NS}" run verify-ai-$$ --rm -i --restart=Never --image=curlimages/curl:8.11.1 \
  --env QKEY="${QKEY}" --env VKEY="${VKEY}" --command -- sh -c "${PROBE}" 2>/dev/null || true)"

echo "-- collections --"
MISS=""
for c in knowledge_base past_incidents policies scripts device_profiles; do
  echo "${OUT}" | grep -q "\"${c}\"" || MISS="${MISS} ${c}"
done
[ -z "${MISS}" ] && ok "all 5 collections present" || bad "missing collections:${MISS}"

echo "-- cluster --"
echo "${OUT}" | grep -q '"status":"enabled"' && ok "Qdrant cluster mode enabled" || bad "Qdrant cluster not enabled"

echo "-- vLLM --"
echo "${OUT}" | grep -q 'qwen2.5-1.5b-instruct' && ok "vLLM serves qwen2.5-1.5b-instruct" || bad "vLLM model not listed"
echo "${OUT}" | sed -n '/===VCHAT===/,/===EMBED===/p' | grep -q '200' && ok "vLLM chat completion -> 200" || bad "vLLM chat completion failed"

echo "-- embeddings --"
echo "${OUT}" | sed -n '/===EMBED===/,/===DONE===/p' | grep -q '"embeddings"' && ok "Ollama bge-m3 embedding returned" || bad "Ollama embedding failed"

echo "== 8) Strict external isolation =="
EXPOSED="$(kubectl -n "${NS}" get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name} {end}{range .items[?(@.spec.type=="NodePort")]}{.metadata.name} {end}' 2>/dev/null)"
[ -z "${EXPOSED// /}" ] && ok "no LoadBalancer/NodePort Service in ai (internal only)" || bad "externally exposed Service(s): ${EXPOSED}"
kubectl -n "${NS}" get networkpolicy default-deny-all >/dev/null 2>&1 && ok "default-deny NetworkPolicy present" || bad "default-deny NetworkPolicy missing"

echo "== 9) ServiceMonitors present =="
kubectl -n "${NS}" get servicemonitor vllm   >/dev/null 2>&1 && ok "ServiceMonitor vllm present"   || bad "ServiceMonitor vllm missing"
kubectl -n "${NS}" get servicemonitor qdrant >/dev/null 2>&1 && ok "ServiceMonitor qdrant present" || bad "ServiceMonitor qdrant missing"

echo "== 10) AI endpoints/keys mirrored into Vault =="
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  VK="$(kubectl -n "${VAULT_NS}" exec -i vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
    vault kv get -field=qdrant-api-key secret/itorchestra/shared/ai 2>/dev/null || true)"
  [ -n "${VK}" ] && [ "${VK}" = "${QKEY}" ] && ok "Vault secret/itorchestra/shared/ai matches" || bad "Vault ai secret missing/mismatch"
else
  bad "could not read Vault root token (sealed? Phase 0.5?)"
fi

echo "========================================================"
echo "Phase 0.9 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
