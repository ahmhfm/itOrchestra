#!/usr/bin/env bash
# itOrchestra - Phase 0.2 verification suite (Linkerd service mesh).
# Checks: control-plane health (linkerd check), control-plane pods Running, and a live
# injection smoke test (a pod in a throwaway namespace comes up 2/2 = app + linkerd-proxy,
# which only happens once linkerd-identity issues its mTLS cert).
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export PATH="${HOME}/.linkerd2/bin:${PATH}"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SMOKE_NS="linkerd-smoke"

echo "== 1) linkerd CLI present =="
if command -v linkerd >/dev/null 2>&1; then
  ok "linkerd CLI: $(linkerd version --client --short 2>/dev/null || echo unknown)"
else
  bad "linkerd CLI not found on PATH (${HOME}/.linkerd2/bin)"
fi

echo "== 2) Control-plane health (linkerd check) =="
if linkerd check >/tmp/linkerd-check.out 2>&1; then
  ok "linkerd check passed"
else
  bad "linkerd check failed (showing last 20 lines)"; tail -n 20 /tmp/linkerd-check.out
fi

echo "== 3) Control-plane pods Running in 'linkerd' =="
NOTRUN="$(kubectl -n linkerd get pods --no-headers 2>/dev/null | grep -cvw Running || true)"
kubectl -n linkerd get pods 2>/dev/null || true
if [ "${NOTRUN:-1}" = "0" ]; then ok "all linkerd control-plane pods Running"; else bad "${NOTRUN} linkerd pod(s) not Running"; fi

echo "== 4) Injection smoke test (pod becomes 2/2 = app + linkerd-proxy) =="
# Throwaway namespace WITHOUT the 'restricted' PodSecurity profile, because Linkerd's
# default proxy-init needs NET_ADMIN/NET_RAW. (Restricted app namespaces require the
# Linkerd CNI plugin instead - see docs/runbook-0.2.md.)
kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${SMOKE_NS}
  annotations:
    linkerd.io/inject: enabled
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke
  namespace: ${SMOKE_NS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: smoke }
  template:
    metadata:
      labels: { app: smoke }
      annotations:
        linkerd.io/inject: enabled
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
EOF

# Retry: the proxy-injector webhook uses failurePolicy=Ignore, so a pod created while the
# injector is momentarily unavailable is admitted UN-injected. If that happens, delete the
# pod and let the Deployment recreate it (the injector then injects the fresh pod).
INJECTED=""; NCONT=""
for attempt in 1 2 3 4 5 6; do
  kubectl -n "${SMOKE_NS}" rollout status deploy/smoke --timeout=60s >/dev/null 2>&1 || true
  POD="$(kubectl -n ${SMOKE_NS} get pods -l app=smoke --field-selector=status.phase=Running -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  [ -z "${POD}" ] && POD="$(kubectl -n ${SMOKE_NS} get pods -l app=smoke -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  NCONT="$(kubectl -n ${SMOKE_NS} get pod ${POD} -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)"
  case " ${NCONT} " in
    *linkerd-proxy*) INJECTED="yes"; break ;;
  esac
  echo "    attempt ${attempt}: proxy not injected yet (containers: ${NCONT:-none}); recreating pod"
  kubectl -n "${SMOKE_NS}" delete pod -l app=smoke --wait=false >/dev/null 2>&1 || true
  sleep 10
done
echo "    smoke pod (${POD:-none}) containers: ${NCONT:-none}"
if [ "${INJECTED}" = "yes" ]; then ok "linkerd-proxy sidecar injected"; else bad "no linkerd-proxy sidecar injected after retries"; fi
kubectl -n "${SMOKE_NS}" wait --for=condition=Ready pod -l app=smoke --timeout=90s >/dev/null 2>&1 || true
READY="$(kubectl -n ${SMOKE_NS} get pod ${POD} -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || true)"
case "${READY}" in
  *"true true"*) ok "smoke pod Ready 2/2 (mTLS identity issued)" ;;
  *)             bad "smoke pod not 2/2 Ready (readiness='${READY:-none}')" ;;
esac
kubectl delete ns "${SMOKE_NS}" --wait=false >/dev/null 2>&1 || true

echo "== 5) (optional) linkerd-viz health =="
if kubectl get ns linkerd-viz >/dev/null 2>&1; then
  if linkerd viz check >/tmp/linkerd-viz-check.out 2>&1; then ok "linkerd viz check passed"; else bad "linkerd viz check failed (see /tmp/linkerd-viz-check.out)"; fi
else
  echo "    linkerd-viz not installed (skip) - run k8s/cluster/linkerd/install-linkerd-viz.sh to enable."
fi

echo "========================================================"
echo "Phase 0.2 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
