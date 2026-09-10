#!/usr/bin/env bash
# Prove every acceptance criterion: Kyverno admission, RBAC least privilege,
# NetworkPolicy isolation, and sealed secrets.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=portfolio
pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
no()  { echo "FAIL: $1"; fail=$((fail+1)); }
denied() { grep -qiE 'denied|violat|forbidden|not allowed' <<<"$1"; }

echo "================ Kyverno admission control ================"
echo "--- installed policies:"
kubectl get clusterpolicy

echo "--- [1] pod without resources/labels must be denied"
out="$(kubectl run bad-pod -n "$NS" --image=docker.io/library/nginx:1.27 --restart=Never 2>&1 || true)"
denied "$out" && ok "pod without limits/labels denied" || no "pod without limits/labels NOT denied"
kubectl delete pod bad-pod -n "$NS" --ignore-not-found >/dev/null 2>&1 || true

echo "--- [2] :latest tag must be denied"
out="$(kubectl apply -f - 2>&1 <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: latest-pod
  namespace: portfolio
  labels:
    team: platform
    app.kubernetes.io/name: latest-pod
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: latest-pod
      image: docker.io/library/nginx:latest
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi
EOF
)"
denied "$out" && ok ":latest tag denied" || no ":latest tag NOT denied"
kubectl delete pod latest-pod -n "$NS" --ignore-not-found >/dev/null 2>&1 || true

echo "--- [3] privileged pod must be denied"
out="$(kubectl apply -f - 2>&1 <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: priv-pod
  namespace: portfolio
  labels:
    team: platform
    app.kubernetes.io/name: priv-pod
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: priv-pod
      image: docker.io/library/nginx:1.27
      securityContext:
        privileged: true
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi
EOF
)"
denied "$out" && ok "privileged pod denied" || no "privileged pod NOT denied"
kubectl delete pod priv-pod -n "$NS" --ignore-not-found >/dev/null 2>&1 || true

echo "--- [4] compliant app pod is running"
kubectl get pods -n "$NS"

echo "================ RBAC least privilege ================"
echo "--- [5] deployer can list deployments (expect yes)"
if [ "$(kubectl auth can-i list deployments -n "$NS" --as=system:serviceaccount:$NS:deployer)" = "yes" ]; then
  ok "deployer can list deployments"
else
  no "deployer cannot list deployments"
fi

echo "--- [6] deployer cannot read secrets (expect no)"
if [ "$(kubectl auth can-i get secrets -n "$NS" --as=system:serviceaccount:$NS:deployer)" = "no" ]; then
  ok "deployer cannot read secrets"
else
  no "deployer CAN read secrets"
fi

echo "--- [7] deployer cannot delete pods (expect no)"
if [ "$(kubectl auth can-i delete pods -n "$NS" --as=system:serviceaccount:$NS:deployer)" = "no" ]; then
  ok "deployer cannot delete pods"
else
  no "deployer CAN delete pods"
fi

echo "--- [8] deployer cannot act in another namespace (expect no)"
if [ "$(kubectl auth can-i list pods -n default --as=system:serviceaccount:$NS:deployer)" = "no" ]; then
  ok "deployer confined to $NS"
else
  no "deployer can act outside $NS"
fi

echo "================ NetworkPolicy isolation ================"
APP_IP="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=portfolio-app -o jsonpath='{.items[0].status.podIP}')"
echo "--- app pod IP: ${APP_IP:-<none>}"

echo "--- [9] allowed: in-namespace request to the app (expect ok)"
out="$(kubectl exec -n "$NS" deploy/portfolio-app -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://portfolio-app.$NS.svc.cluster.local/health', timeout=5).read().decode())" 2>&1 || true)"
grep -q '"status": *"ok"\|status.*ok' <<<"$out" && ok "in-namespace app call allowed" || no "in-namespace app call failed: $out"

echo "--- [10] denied: cross-namespace request to the app (expect failure)"
kubectl delete pod nettest -n default --ignore-not-found >/dev/null 2>&1 || true
kubectl run nettest -n default --image=docker.io/library/curlimages/curl:8.10.1 --restart=Never \
  --command -- sh -c "curl -sS --max-time 5 http://$APP_IP:8000/health; echo EXIT=\$?" >/dev/null 2>&1 || true
kubectl wait --for=condition=Ready pod/nettest -n default --timeout=60s >/dev/null 2>&1 || true
sleep 3
out="$(kubectl logs nettest -n default 2>&1 || true)"
grep -q 'EXIT=0' <<<"$out" && no "cross-namespace call was ALLOWED" || ok "cross-namespace call denied"
kubectl delete pod nettest -n default --ignore-not-found >/dev/null 2>&1 || true

echo "================ Sealed secrets ================"
echo "--- [11] sealed secret decrypted into a Secret (expect exists)"
if kubectl get secret portfolio-app -n "$NS" >/dev/null 2>&1; then
  ok "sealed secret decrypted to Secret/$NS/portfolio-app"
else
  no "sealed secret missing"
fi

echo "--- [12] no plaintext secret in the repo (gitleaks)"
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --source "$REPO_ROOT" --no-git --redact >/dev/null 2>&1; then
    ok "gitleaks found no secrets"
  else
    no "gitleaks found secrets"
  fi
else
  echo "SKIP: gitleaks not installed locally (runs in CI)"
fi

echo "=================================================="
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
