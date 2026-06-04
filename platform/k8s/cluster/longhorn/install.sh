#!/usr/bin/env bash
# Install Longhorn via Helm and make itOrchestra's StorageClass the cluster default.
# Idempotent. Run prereqs.sh first (open-iscsi).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="longhorn-system"
CHART_VERSION="${LONGHORN_VERSION:-1.7.2}"
REPLICAS="${LONGHORN_REPLICAS:-1}"     # dev=1, prod=3
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "==> [0.1/longhorn] Installing Longhorn ${CHART_VERSION} (replicas=${REPLICAS})"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found." >&2; exit 1; }

helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update longhorn >/dev/null

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"
# Longhorn needs privileged pods (host mounts, iscsi).
kubectl label ns "${NS}" name="${NS}" --overwrite >/dev/null
kubectl label ns "${NS}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

helm upgrade --install longhorn longhorn/longhorn \
  --namespace "${NS}" \
  --version "${CHART_VERSION}" \
  --set persistence.defaultClass=false \
  --set defaultSettings.defaultReplicaCount="${REPLICAS}" \
  --set csi.attacherReplicaCount=1 \
  --set csi.provisionerReplicaCount=1 \
  --set csi.resizerReplicaCount=1 \
  --set csi.snapshotterReplicaCount=1 \
  --set longhornUI.replicas=1 \
  --wait --timeout 10m

echo "==> Waiting for Longhorn manager to be Ready"
kubectl -n "${NS}" rollout status ds/longhorn-manager --timeout=300s || true

# Make our explicit class the single default (unset K3s local-path default if present).
if kubectl get storageclass local-path >/dev/null 2>&1; then
  kubectl annotate storageclass local-path \
    storageclass.kubernetes.io/is-default-class- --overwrite >/dev/null 2>&1 || true
fi
# Apply itorchestra-longhorn with the requested replica count rendered in.
sed "s/numberOfReplicas: \"1\"/numberOfReplicas: \"${REPLICAS}\"/" \
  "${SCRIPT_DIR}/storageclass.yaml" | kubectl apply -f -

echo "==> StorageClasses:"
kubectl get storageclass
echo "==> [0.1/longhorn] Done."
