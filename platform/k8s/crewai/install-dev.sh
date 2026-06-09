#!/usr/bin/env bash
# Deploy the CrewAI multi-agent orchestration service (Phase 0.10, dev).
# Steps: namespace -> app DB login secret -> provision CrewAiDb (+ login + SPs) on the 0.7 AG
#        primary -> config/secret (endpoints + Qdrant key + DB creds) -> Service/Deployment/
#        NetworkPolicy -> mirror endpoint into Vault.
# Idempotent: secrets/passwords generated once and reused; SQL guarded with IF NOT EXISTS.
# Assumes the image itorchestra/crewai:dev is already built+imported (build-and-import-dev.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="ns-crewai"
MSSQL_NS="mssql"
AI_NS="ai"
VAULT_NS="vault"
PRIMARY_POD="mssql-ag-0"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

gen_pw() { echo "Aa1!$(openssl rand -hex 20)"; }

echo "==> [0.10/crewai] Ensuring the '${NS}' namespace (restricted PSA, meshed)"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ns-crewai
  labels:
    name: ns-crewai
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
  annotations:
    linkerd.io/inject: enabled
EOF

echo "==> Ensuring the CrewAI app DB password secret"
if ! kubectl -n "${NS}" get secret crewai-db >/dev/null 2>&1; then
  kubectl -n "${NS}" create secret generic crewai-db --from-literal=app-password="$(gen_pw)"
  echo "    created secret crewai-db"
else
  echo "    secret crewai-db already exists (reuse)"
fi
APP_PW="$(kubectl -n "${NS}" get secret crewai-db -o jsonpath='{.data.app-password}' | base64 -d)"

echo "==> Reading the AG SA password (namespace '${MSSQL_NS}')"
SA_PW="$(kubectl -n "${MSSQL_NS}" get secret mssql-ag-secret -o jsonpath='{.data.sa-password}' | base64 -d 2>/dev/null || true)"
[ -n "${SA_PW}" ] || { echo "    !! could not read mssql-ag-secret (is Phase 0.7 deployed?). Aborting." >&2; exit 1; }

echo "==> Provisioning CrewAiDb + login + stored procedures on the AG primary (${PRIMARY_POD})"
kubectl -n "${MSSQL_NS}" exec -i "${PRIMARY_POD}" -- "${SQLCMD}" -S localhost -U sa -P "${SA_PW}" -C -b \
  -v AppPassword="${APP_PW}" < "${SCRIPT_DIR}/db/01-database-and-login.sql"
kubectl -n "${MSSQL_NS}" exec -i "${PRIMARY_POD}" -- "${SQLCMD}" -S localhost -U sa -P "${SA_PW}" -C -b \
  -d CrewAiDb < "${SCRIPT_DIR}/db/02-schema.sql"
echo "    CrewAiDb ready (stored-procedure surface installed; crewai_app granted EXEC only)"

echo "==> Reading the Qdrant API key (namespace '${AI_NS}')"
QKEY="$(kubectl -n "${AI_NS}" get secret qdrant-apikey -o jsonpath='{.data.api-key}' | base64 -d 2>/dev/null || true)"
[ -n "${QKEY}" ] || echo "    !! Qdrant api-key not found (is Phase 0.9 deployed?). RAG will be unauthenticated."

echo "==> Writing crewai-config (endpoints/models) + crewai-secrets (keys/creds)"
kubectl -n "${NS}" create configmap crewai-config \
  --from-literal=GRPC_PORT="50051" \
  --from-literal=SERVICE_VERSION="0.10-dev" \
  --from-literal=LLM_BASE_URL="http://ollama.${AI_NS}.svc.cluster.local:11434/v1" \
  --from-literal=OLLAMA_BASE_URL="http://ollama.${AI_NS}.svc.cluster.local:11434" \
  --from-literal=CHAT_MODEL="qwen2.5:1.5b" \
  --from-literal=EMBED_MODEL="bge-m3" \
  --from-literal=LLM_TIMEOUT_S="120" \
  --from-literal=MAX_TOKENS="128" \
  --from-literal=USE_CREWAI="false" \
  --from-literal=CREWAI_TELEMETRY_OPT_OUT="true" \
  --from-literal=OTEL_SDK_DISABLED="true" \
  --from-literal=ANONYMIZED_TELEMETRY="False" \
  --from-literal=LITELLM_LOCAL_MODEL_COST_MAP="True" \
  --from-literal=QDRANT_URL="http://qdrant.${AI_NS}.svc.cluster.local:6333" \
  --from-literal=DEFAULT_COLLECTION="knowledge_base" \
  --from-literal=DB_HOST="mssql-ag-primary.${MSSQL_NS}.svc.cluster.local" \
  --from-literal=DB_PORT="1433" \
  --from-literal=DB_NAME="CrewAiDb" \
  --from-literal=DB_USER="crewai_app" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NS}" create secret generic crewai-secrets \
  --from-literal=QDRANT_API_KEY="${QKEY}" \
  --from-literal=DB_PASSWORD="${APP_PW}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Re-applying the AI NetworkPolicy so 'ai' admits ns-crewai (Qdrant/Ollama ingress)"
kubectl apply -f "${SCRIPT_DIR}/../ai/networkpolicy.yaml"

echo "==> Mirroring the CrewAI endpoint + db-password into Vault (secret/itorchestra/shared/crewai)"
# Seeded BEFORE the rollout so the new pod's Vault Agent init container can render db-password into
# /vault/secrets/app.env on its first attempt (the itorchestra-crewai policy grants read on this path).
ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d || true)"
if [ -n "${ROOT_TOKEN}" ]; then
  # Non-fatal: if Vault is sealed/unavailable, warn and continue - the app still boots from the k8s
  # 'crewai-secrets' env fallback (and the Vault Agent will render once Vault is reachable on re-run).
  if ! kubectl -n "${VAULT_NS}" exec -i vault-0 -- env \
    VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" APP_PW="${APP_PW}" sh -s <<'EOSH'
set -e
vault kv put secret/itorchestra/shared/crewai \
  grpc-endpoint="crewai.ns-crewai.svc.cluster.local:50051" \
  proto-package="itorchestra.crewai.v1" \
  db-name="CrewAiDb" \
  db-user="crewai_app" \
  db-host="mssql-ag-primary.mssql.svc.cluster.local,1433" \
  db-password="$APP_PW"
echo "  seeded: secret/itorchestra/shared/crewai (incl. db-password)"
EOSH
  then
    echo "    !! Vault mirror skipped (Vault sealed/unavailable). App falls back to k8s env; re-run after unsealing." >&2
  fi
else
  echo "    !! could not read Vault root token; skipping Vault mirror (Vault Agent will fall back to k8s env)" >&2
fi

echo "==> Applying ServiceAccount, NetworkPolicies, Service, Deployment"
kubectl apply -f "${SCRIPT_DIR}/serviceaccount.yaml"
# NetworkPolicies first so the Vault-egress rule is in place before the rolled pod's Vault Agent
# init container tries to reach Vault (avoids a default-deny race on the first init attempt).
kubectl apply -f "${SCRIPT_DIR}/networkpolicy.yaml"
kubectl apply -f "${SCRIPT_DIR}/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"
# Roll the pod so it always picks up a refreshed config/secret on re-runs.
kubectl -n "${NS}" rollout restart deploy/crewai

echo "==> Waiting for the CrewAI rollout"
kubectl -n "${NS}" rollout status deploy/crewai --timeout=300s

echo "==> CrewAI state:"
kubectl -n "${NS}" get pods,svc -o wide
echo "==> [0.10/crewai] Deploy done (dev)."
echo "    gRPC:      crewai.${NS}.svc.cluster.local:50051  (package itorchestra.crewai.v1)"
echo "    LLM:       ollama.${AI_NS}.svc.cluster.local:11434 (chat qwen2.5:1.5b, embed bge-m3)"
echo "    Vectors:   qdrant.${AI_NS}.svc.cluster.local:6333"
echo "    Audit DB:  CrewAiDb on mssql-ag-primary.${MSSQL_NS}.svc.cluster.local:1433 (SP-only)"
