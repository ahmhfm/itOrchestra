#!/usr/bin/env bash
# itOrchestra - Phase 0.1 verification suite.
# Checks node Ready, Cilium, MetalLB+ingress LB IP, Longhorn default SC + PVC Bound,
# and default-deny isolation between namespaces (with DNS still working).
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 1) Node Ready =="
if kubectl get nodes --no-headers 2>/dev/null | grep -qw Ready; then
  kubectl get nodes -o wide; ok "node is Ready"
else bad "node not Ready"; fi

echo "== 2) Cilium running =="
if kubectl -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null | grep -qE '^[1-9]'; then
  ok "cilium DaemonSet ready"
else bad "cilium not ready"; fi
command -v cilium >/dev/null 2>&1 && cilium status --wait --wait-duration 30s 2>/dev/null | head -n 12 || true

echo "== 3) MetalLB + ingress-nginx LoadBalancer IP =="
EXT_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [ -n "${EXT_IP}" ]; then
  ok "ingress LB IP assigned: ${EXT_IP}"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://${EXT_IP}/" || echo 000)"
  # ingress-nginx default backend returns 404 -> proves LB + controller path works.
  if [ "${CODE}" = "404" ] || [ "${CODE}" = "200" ]; then ok "ingress reachable (HTTP ${CODE})"; else bad "ingress not reachable (HTTP ${CODE})"; fi
else bad "no LB IP on ingress-nginx"; fi

echo "== 4) Longhorn default StorageClass + PVC Bound =="
DEF_SC="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
echo "    default StorageClass: ${DEF_SC:-<none>}"
[ -n "${DEF_SC}" ] && ok "a default StorageClass exists" || bad "no default StorageClass"
cat <<'EOF' | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: verify-pvc
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }
EOF
for i in $(seq 1 30); do
  PH="$(kubectl -n default get pvc verify-pvc -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${PH}" = "Bound" ] && break; sleep 3
done
[ "${PH:-}" = "Bound" ] && ok "verify-pvc Bound" || bad "verify-pvc not Bound (phase=${PH:-none})"
kubectl -n default delete pvc verify-pvc --wait=false >/dev/null 2>&1 || true

echo "== 5) Default-deny isolation (ns-assets -> ns-identity blocked, DNS ok) =="
# ns-assets / ns-identity enforce the PodSecurity 'restricted' profile, so the probe
# pods need a hardened securityContext (runAsNonRoot + RuntimeDefault seccomp + drop ALL
# caps + no privilege escalation), otherwise admission rejects them.
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: np-target
  namespace: ns-identity
  labels: { app: np-target }
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: np-target
      image: hashicorp/http-echo
      args: ["-text=hello", "-listen=:5678"]
      ports: [{ containerPort: 5678 }]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
---
apiVersion: v1
kind: Service
metadata:
  name: np-target
  namespace: ns-identity
spec:
  selector: { app: np-target }
  ports: [{ port: 5678, targetPort: 5678 }]
---
apiVersion: v1
kind: Pod
metadata:
  name: np-probe
  namespace: ns-assets
  labels: { app: np-probe }
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: np-probe
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
EOF
kubectl -n ns-identity wait --for=condition=Ready pod/np-target --timeout=90s >/dev/null 2>&1 || true
kubectl -n ns-assets   wait --for=condition=Ready pod/np-probe  --timeout=90s >/dev/null 2>&1 || true
# DNS should still resolve (allow-dns.yaml), but TCP to the other ns should time out.
DNS_OUT="$(kubectl -n ns-assets exec np-probe -- nslookup -timeout=3 kubernetes.default.svc.cluster.local 2>/dev/null | tail -n 3 || true)"
echo "${DNS_OUT}" | grep -qi 'Address' && ok "DNS resolves from ns-assets (allow-dns works)" || bad "DNS broken from ns-assets"
if kubectl -n ns-assets exec np-probe -- wget -T 5 -qO- http://np-target.ns-identity.svc.cluster.local:5678 >/dev/null 2>&1; then
  echo "    cross-ns probe result: REACHED (unexpected)"
  bad "cross-namespace traffic NOT denied"
else
  echo "    cross-ns probe result: BLOCKED (wget timed out)"
  ok "cross-namespace traffic denied by default"
fi
kubectl -n ns-identity delete pod np-target --wait=false >/dev/null 2>&1 || true
kubectl -n ns-identity delete svc np-target --wait=false >/dev/null 2>&1 || true
kubectl -n ns-assets   delete pod np-probe  --wait=false >/dev/null 2>&1 || true

echo "========================================================"
echo "Phase 0.1 verification: ${PASS} passed, ${FAIL} failed."
echo "========================================================"
[ "${FAIL}" -eq 0 ]
