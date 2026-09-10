#!/usr/bin/env bash
# Create the kind cluster and install the security stack: Calico (NetworkPolicy
# enforcement), Kyverno (admission policy), Sealed Secrets (secret management).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-devsecops}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"
KYVERNO_VERSION="${KYVERNO_VERSION:-3.9.0}"
SEALED_SECRETS_VERSION="${SEALED_SECRETS_VERSION:-0.40.0}"

echo "==> creating kind cluster '$CLUSTER_NAME' (Calico, no default CNI)"
kind create cluster --config "$REPO_ROOT/kind/cluster.yaml"

echo "==> installing Calico $CALICO_VERSION (needed for NetworkPolicy)"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=300s

echo "==> installing Kyverno $KYVERNO_VERSION"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version "$KYVERNO_VERSION" \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --wait --timeout 300s

echo "==> installing Sealed Secrets controller $SEALED_SECRETS_VERSION"
kubectl apply -f "https://github.com/bitnami/sealed-secrets/releases/download/v${SEALED_SECRETS_VERSION}/controller.yaml"
kubectl -n kube-system rollout status deployment/sealed-secrets-controller --timeout=300s

echo "Bootstrap complete."
echo "Next: scripts/deploy.sh"
