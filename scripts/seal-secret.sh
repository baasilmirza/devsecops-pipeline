#!/usr/bin/env bash
# Seal secrets/app-secret.example.yaml with the in-cluster controller's public
# key and apply the result. The sealed output is safe to commit (it is
# gitignored here because it is bound to this cluster's keypair).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/secrets/app-secret.example.yaml"
OUT="$REPO_ROOT/secrets/sealed-secret.yaml"

echo "==> sealing $SRC -> $OUT"
kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  --format yaml \
  < "$SRC" > "$OUT"

echo "==> applying sealed secret"
kubectl apply -f "$OUT"

echo "==> verifying the controller decrypted it"
kubectl get secret portfolio-app -n portfolio
