#!/usr/bin/env bash
# Build the app image, load it into kind, then apply RBAC, network policy,
# workloads, and the Kyverno admission policies.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-devsecops}"
IMAGE="${IMAGE:-docker.io/library/portfolio-api:0.1.0}"

echo "==> building app image $IMAGE"
docker build -t "$IMAGE" "$REPO_ROOT"

echo "==> loading image into kind"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

echo "==> applying RBAC (namespace, service accounts, roles)"
kubectl apply -f "$REPO_ROOT/rbac/"

echo "==> applying Kyverno admission policies"
kubectl apply -f "$REPO_ROOT/policy/"

echo "==> applying NetworkPolicies (default-deny + allowlists)"
kubectl apply -f "$REPO_ROOT/network/"

echo "==> applying workload"
kubectl apply -f "$REPO_ROOT/workloads/"

echo "==> sealing and applying the app secret"
"$REPO_ROOT/scripts/seal-secret.sh"

echo "==> waiting for rollout"
kubectl -n portfolio rollout status deployment/portfolio-app --timeout=180s

echo "Deploy complete."
echo "Next: scripts/verify.sh"
