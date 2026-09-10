#!/usr/bin/env bash
# Delete the local kind cluster. Nothing here costs money or touches AWS.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-devsecops}"

echo "==> deleting kind cluster '$CLUSTER_NAME'"
kind delete cluster --name "$CLUSTER_NAME"

echo "==> remaining kind clusters:"
kind get clusters || true

echo "Teardown complete."
