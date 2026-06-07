#!/usr/bin/env bash
# itOrchestra - Phase 0.9 verification (AI layer, dev/CPU profile: Qdrant + Ollama).
# Checks: ai namespace out of mesh; Qdrant 3/3 + Ollama Ready; the 5 RAG collections exist;
# Qdrant cluster enabled; live chat (Ollama qwen2.5:1.5b) + embedding (Ollama bge-m3, 1024-dim);
# strict external isolation (no LoadBalancer/NodePort + default-deny); Qdrant ServiceMonitor
# present; endpoints/key mirrored into Vault.
# (vLLM/GPU is the production path and is not deployed here, so it is not verified.)
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="ai"
VAULT_NS="vault"
CHAT_MODEL="${CHAT_MODEL:-qwen2.5:1.5b}"
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

echo "== 2) Component pods Ready =="
RR="$(kubectl -n "${NS}" get statefulset qdrant -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${RR:-0}" = "3" ] && ok "Qdrant cluster 3/3 replicas Ready" || bad "Qdrant readyReplicas='${RR}' (expected 3)"
check_ready "app=ollama" "Ollama"

echo "== 3-6) In-cluster probes (collections / cluster / chat / embeddings) =="
QKEY="$(kubectl -n "${NS}" get secret qdrant-apikey -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d)"
# A first chat call cold-loads the model on CPU (can take a while), so we warm it up (result
# ignored) before the measured call. Output is captured via 'kubectl logs' - NOT the run -i
# attach stream - to avoid losing early output to the attach race.
PROBE='
echo "===COLLECTIONS==="; curl -s -H "api-key: $QKEY" http://qdrant.ai.svc.cluster.local:6333/collections; echo
echo "===CLUSTER===";     curl -s -H "api-key: $QKEY" http://qdrant.ai.svc.cluster.local:6333/cluster; echo
curl -s -o /dev/null --max-time 240 -H "Content-Type: application/json" -d "{\"model\":\"'"${CHAT_MODEL}"'\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" http://ollama.ai.svc.cluster.local:11434/v1/chat/completions || true
echo "===CHAT===";        curl -s --max-time 120 -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d "{\"model\":\"'"${CHAT_MODEL}"'\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":5}" http://ollama.ai.svc.cluster.local:11434/v1/chat/completions; echo
echo "===EMBED===";       curl -s --max-time 120 -H "Content-Type: application/json" -d "{\"model\":\"bge-m3\",\"input\":\"test embedding\"}" http://ollama.ai.svc.cluster.local:11434/api/embed; echo
echo "===DONE==="
'
POD="verify-ai-$$"
kubectl -n "${NS}" run "${POD}" --restart=Never --image=curlimages/curl:8.11.1 \
  --env QKEY="${QKEY}" --command -- sh -c "${PROBE}" >/dev/null 2>&1 || true
kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD}" --timeout=360s >/dev/null 2>&1 || true
OUT="$(kubectl -n "${NS}" logs "${POD}" 2>/dev/null || true)"
kubectl -n "${NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true

echo "-- collections --"
MISS=""
for c in knowledge_base past_incidents policies scripts device_profiles; do
  echo "${OUT}" | grep -q "\"${c}\"" || MISS="${MISS} ${c}"
done
[ -z "${MISS}" ] && ok "all 5 collections present" || bad "missing collections:${MISS}"

echo "-- cluster --"
echo "${OUT}" | grep -q '"status":"enabled"' && ok "Qdrant cluster mode enabled" || bad "Qdrant cluster not enabled"

echo "-- chat (Ollama ${CHAT_MODEL}) --"
echo "${OUT}" | sed -n '/===CHAT===/,/===EMBED===/p' | grep -q '200' && ok "chat completion -> 200" || bad "chat completion failed"

echo "-- embeddings (Ollama bge-m3) --"
echo "${OUT}" | sed -n '/===EMBED===/,/===DONE===/p' | grep -q '"embeddings"' && ok "bge-m3 embedding returned" || bad "embedding failed"

echo "== 7) Strict external isolation =="
EXPOSED="$(kubectl -n "${NS}" get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name} {end}{range .items[?(@.spec.type=="NodePort")]}{.metadata.name} {end}' 2>/dev/null)"
[ -z "${EXPOSED// /}" ] && ok "no LoadBalancer/NodePort Service in ai (internal only)" || bad "externally exposed Service(s): ${EXPOSED}"
kubectl -n "${NS}" get networkpolicy default-deny-all >/dev/null 2>&1 && ok "default-deny NetworkPolicy present" || bad "default-deny NetworkPolicy missing"

echo "== 8) Qdrant ServiceMonitor present =="
kubectl -n "${NS}" get servicemonitor qdrant >/dev/null 2>&1 && ok "ServiceMonitor qdrant present" || bad "ServiceMonitor qdrant missing (Phase 0.8 CRDs installed?)"

echo "== 9) AI endpoints/key mirrored into Vault =="
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
