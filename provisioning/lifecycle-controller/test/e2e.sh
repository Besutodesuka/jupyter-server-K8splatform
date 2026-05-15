#!/usr/bin/env bash
# End-to-end test for the lifecycle controller running on minikube.
#
# What it tests:
#   1. Active namespace — controller does NOT suspend it
#   2. Expired namespace — controller DOES suspend it (scales StatefulSet to 0)
#   3. Idempotency  — re-labelling an already-suspended namespace changes nothing
#   4. Non-student namespace — controller ignores it entirely
#
# Prerequisites:
#   - minikube running with the lifecycle controller deployed
#   - kubectl configured for minikube
#   - helm available
#
# Usage:
#   bash provisioning/lifecycle-controller/test/e2e.sh
set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}  $*"; }
fail() { echo -e "${RED}FAIL${NC}  $*"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}INFO${NC}  $*"; }

FAILURES=0
CHART_DIR="$(cd "$(dirname "$0")/../../student/chart" && pwd)"

# ── Cleanup helper ─────────────────────────────────────────────────────────────
cleanup_ns() {
  local ns="$1"
  kubectl delete namespace "$ns" --ignore-not-found --wait=false 2>/dev/null || true
}

# ── Wait for StatefulSet replicas ─────────────────────────────────────────────
# wait_replicas <namespace> <sts-name> <expected-replicas> <timeout-secs>
wait_replicas() {
  local ns="$1" sts="$2" expected="$3" timeout="$4"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    actual=$(kubectl get statefulset "$sts" -n "$ns" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "-1")
    if [[ "$actual" == "$expected" ]]; then return 0; fi
    sleep 2; elapsed=$((elapsed + 2))
  done
  return 1
}

# ── Wait for namespace label ───────────────────────────────────────────────────
# wait_label <namespace> <label-key> <expected-value> <timeout-secs>
wait_label() {
  local ns="$1" key="$2" expected="$3" timeout="$4"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    actual=$(kubectl get namespace "$ns" \
      -o "jsonpath={.metadata.labels.$key}" 2>/dev/null || echo "")
    if [[ "$actual" == "$expected" ]]; then return 0; fi
    sleep 2; elapsed=$((elapsed + 2))
  done
  return 1
}

# ── Provision a minimal student namespace (no Helm, direct YAML) ───────────────
provision_test_ns() {
  local ns="$1" expires_at="$2"
  kubectl create namespace "$ns" --dry-run=client -o yaml \
    | kubectl apply -f -
  kubectl label namespace "$ns" \
    platform=jupyter-student \
    student-id=e2e \
    semester=e2e-test \
    "expires-at=${expires_at}" \
    --overwrite

  # Create a minimal StatefulSet so the controller has something to scale.
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: jupyter-e2e
  namespace: ${ns}
spec:
  replicas: 1
  serviceName: jupyter-e2e
  selector:
    matchLabels:
      app: jupyter-e2e
  template:
    metadata:
      labels:
        app: jupyter-e2e
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "sleep 3600"]
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════"
echo " Lifecycle Controller — E2E Tests"
echo "══════════════════════════════════════════════════"
echo ""

# ── Verify controller is running ───────────────────────────────────────────────
info "Checking lifecycle-controller deployment ..."
if ! kubectl get deployment lifecycle-controller -n jupyter-platform \
     -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
  echo -e "${RED}ERROR${NC}: lifecycle-controller is not ready. Run: bash provisioning/lifecycle-controller/deploy.sh"
  exit 1
fi
info "Controller is running."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: Active namespace — must NOT be suspended
# ══════════════════════════════════════════════════════════════════════════════
T1_NS="e2e-active-$(date +%s)"
info "[Test 1] Active namespace should NOT be suspended ..."
cleanup_ns "$T1_NS"

provision_test_ns "$T1_NS" "2099-12-31"

# Wait 8 seconds and verify the namespace is still active.
sleep 8
STATUS=$(kubectl get namespace "$T1_NS" \
  -o jsonpath='{.metadata.labels.lifecycle-status}' 2>/dev/null || echo "")
REPLICAS=$(kubectl get statefulset jupyter-e2e -n "$T1_NS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "-1")

if [[ -z "$STATUS" && "$REPLICAS" == "1" ]]; then
  pass "[Test 1] Active namespace not suspended (status='${STATUS}', replicas=${REPLICAS})"
else
  fail "[Test 1] Active namespace was incorrectly suspended (status='${STATUS}', replicas=${REPLICAS})"
fi
cleanup_ns "$T1_NS"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: Expired namespace — must be suspended (StatefulSet → 0, label set)
# ══════════════════════════════════════════════════════════════════════════════
T2_NS="e2e-expired-$(date +%s)"
info "[Test 2] Expired namespace should be suspended ..."
cleanup_ns "$T2_NS"

provision_test_ns "$T2_NS" "2020-01-01"

info "  Waiting up to 30s for controller to suspend ..."
if wait_replicas "$T2_NS" "jupyter-e2e" "0" 30; then
  pass "[Test 2a] StatefulSet scaled to 0"
else
  fail "[Test 2a] StatefulSet NOT scaled to 0 within 30s"
fi

if wait_label "$T2_NS" "lifecycle-status" "suspended" 15; then
  pass "[Test 2b] Namespace labeled lifecycle-status=suspended"
else
  fail "[Test 2b] lifecycle-status label not set within 15s"
fi

TODAY=$(date +%Y-%m-%d)
if wait_label "$T2_NS" "suspended-at" "$TODAY" 5; then
  pass "[Test 2c] Namespace labeled suspended-at=${TODAY}"
else
  fail "[Test 2c] suspended-at label incorrect or missing"
fi
cleanup_ns "$T2_NS"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: Idempotency — re-label already-suspended namespace, labels stable
# ══════════════════════════════════════════════════════════════════════════════
T3_NS="e2e-idem-$(date +%s)"
info "[Test 3] Already-suspended namespace should stay stable ..."
cleanup_ns "$T3_NS"

kubectl create namespace "$T3_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$T3_NS" \
  platform=jupyter-student \
  expires-at=2020-01-01 \
  lifecycle-status=suspended \
  suspended-at=2020-01-02 \
  --overwrite

sleep 8

SUSPENDED_AT=$(kubectl get namespace "$T3_NS" \
  -o jsonpath='{.metadata.labels.suspended-at}' 2>/dev/null || echo "")

if [[ "$SUSPENDED_AT" == "2020-01-02" ]]; then
  pass "[Test 3] suspended-at label unchanged (idempotent)"
else
  fail "[Test 3] suspended-at was overwritten to '${SUSPENDED_AT}' (expected 2020-01-02)"
fi
cleanup_ns "$T3_NS"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: Non-student namespace — controller must ignore it
# ══════════════════════════════════════════════════════════════════════════════
T4_NS="e2e-other-$(date +%s)"
info "[Test 4] Non-student namespace should be ignored ..."
cleanup_ns "$T4_NS"

kubectl create namespace "$T4_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$T4_NS" purpose=other expires-at=2020-01-01 --overwrite

sleep 8

STATUS=$(kubectl get namespace "$T4_NS" \
  -o jsonpath='{.metadata.labels.lifecycle-status}' 2>/dev/null || echo "")

if [[ -z "$STATUS" ]]; then
  pass "[Test 4] Non-student namespace ignored (no lifecycle-status label)"
else
  fail "[Test 4] Controller unexpectedly suspended non-student namespace (status='${STATUS}')"
fi
cleanup_ns "$T4_NS"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════"
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e " ${GREEN}All E2E tests passed.${NC}"
else
  echo -e " ${RED}${FAILURES} test(s) failed.${NC}"
fi
echo "══════════════════════════════════════════════════"
echo ""

exit "$FAILURES"
