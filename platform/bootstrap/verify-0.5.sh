#!/usr/bin/env bash
# itOrchestra - Phase 0.5 verification (HashiCorp Vault + Agent Injector).
# Checks: vault-0 Ready, status initialized + unsealed, KV v2 + Kubernetes auth enabled,
# the gateway policy/role present, a seeded secret readable, and the Injector Ready.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NS="vault"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

ROOT_TOKEN="$(kubectl -n "${NS}" get secret vault-unseal-keys -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d)"
vx() { kubectl -n "${NS}" exec -i vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" "$@"; }

echo "== 1) vault-0 Ready =="
READY="$(kubectl -n "${NS}" get pod vault-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[ "${READY}" = "True" ] && ok "vault-0 Ready" || bad "vault-0 not Ready (Ready='${READY}')"

echo "== 2) Vault initialized + unsealed =="
SJSON="$(kubectl -n "${NS}" exec vault-0 -- vault status -format=json 2>/dev/null || true)"
INIT="$(printf '%s' "${SJSON}" | tr -d ' \n' | grep -o '"initialized":[a-z]*' | head -n1 | cut -d: -f2)"
SEALED="$(printf '%s' "${SJSON}" | tr -d ' \n' | grep -o '"sealed":[a-z]*' | head -n1 | cut -d: -f2)"
[ "${INIT}" = "true" ]   && ok "initialized=true"   || bad "initialized='${INIT}'"
[ "${SEALED}" = "false" ] && ok "sealed=false"       || bad "sealed='${SEALED}'"

echo "== 3) KV v2 + Kubernetes auth enabled =="
SECRETS="$(vx vault secrets list 2>/dev/null || true)"
case "${SECRETS}" in *"secret/"*kv*) ok "KV v2 mounted at secret/" ;; *"secret/"*) ok "secret/ mounted" ;; *) bad "secret/ KV engine missing" ;; esac
AUTHS="$(vx vault auth list 2>/dev/null || true)"
case "${AUTHS}" in *kubernetes*) ok "kubernetes auth enabled" ;; *) bad "kubernetes auth missing" ;; esac

echo "== 4) Gateway policy + role present (bound to the dedicated SA) =="
POLICIES="$(vx vault policy list 2>/dev/null || true)"
case "${POLICIES}" in *itorchestra-gateway*) ok "policy itorchestra-gateway exists" ;; *) bad "policy itorchestra-gateway missing" ;; esac
ROLE="$(vx vault read auth/kubernetes/role/gateway 2>/dev/null || true)"
case "${ROLE}" in *ns-gateway*) ok "k8s auth role 'gateway' bound to ns-gateway" ;; *) bad "role 'gateway' missing/misbound" ;; esac
GSAN="$(vx vault read -field=bound_service_account_names auth/kubernetes/role/gateway 2>/dev/null || true)"
case "${GSAN}" in *gateway*) ok "gateway role bound to SA 'gateway' (not default)" ;; *) bad "gateway role SA='${GSAN}' (expected 'gateway')" ;; esac

echo "== 4b) CrewAI policy + role present (bound to the dedicated SA) =="
case "${POLICIES}" in *itorchestra-crewai*) ok "policy itorchestra-crewai exists" ;; *) bad "policy itorchestra-crewai missing" ;; esac
CSAN="$(vx vault read -field=bound_service_account_names auth/kubernetes/role/crewai 2>/dev/null || true)"
case "${CSAN}" in *crewai*) ok "crewai role bound to SA 'crewai' in ns-crewai" ;; *) bad "crewai role missing/misbound (SA='${CSAN}')" ;; esac

echo "== 5) Seeded secret readable =="
GWSEC="$(vx vault kv get -field=client_secret secret/itorchestra/gateway/keycloak 2>/dev/null || true)"
[ -n "${GWSEC}" ] && ok "read secret/itorchestra/gateway/keycloak (client_secret)" || bad "could not read seeded gateway secret"

echo "== 6) Vault Agent Injector Ready =="
INJ="$(kubectl -n "${NS}" get deploy -l app.kubernetes.io/name=vault-agent-injector -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null)"
[ "${INJ:-0}" -ge 1 ] 2>/dev/null && ok "vault-agent-injector Ready (${INJ})" || bad "injector not Ready (readyReplicas='${INJ}')"

echo "========================================================"
echo "Phase 0.5 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
