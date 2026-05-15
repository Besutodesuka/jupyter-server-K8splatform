#!/usr/bin/env bash
# Automated Provisioning + Lifecycle Management — Proof-of-Concept Experiment
#
# Measures:
#   - Time to provision isolated student sandboxes via Helm
#   - Kubernetes objects created per student (quota, RBAC, network isolation)
#   - Lifecycle controller reaction time (label change → StatefulSet suspended)
#   - Resource reclaimed after suspension
#
# Usage:
#   bash provisioning/lifecycle-controller/test/experiment.sh 2>&1 | tee experiment-output.txt
set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/../../student/chart" && pwd)"
REPORT_FILE="$(cd "$(dirname "$0")/../../.." && pwd)/EXPERIMENT_REPORT.md"

# Students provisioned during this experiment
ACTIVE_STUDENTS=(094 095)        # expires 2099 — stays running
EXPIRED_STUDENTS=(091 092 093)   # expires 2020 — will be suspended
ALL_STUDENTS=("${EXPIRED_STUDENTS[@]}" "${ACTIVE_STUDENTS[@]}")

# ── Colours ──────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
step()    { echo -e "${YELLOW}▶${NC} $*"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }

# ── Helpers ──────────────────────────────────────────────────────────────────
ns_object_count() {
  local ns="$1"
  kubectl get all,resourcequota,limitrange,networkpolicy,rolebinding \
    -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

ns_cpu_requests() {
  # Sum spec.containers[].resources.requests.cpu across all running pods in ns
  kubectl get pods -n "$1" -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
total_m = 0
for pod in data.get('items', []):
    for c in pod.get('spec', {}).get('containers', []):
        req = c.get('resources', {}).get('requests', {}).get('cpu', '0')
        if req.endswith('m'):
            total_m += int(req[:-1])
        else:
            total_m += int(float(req) * 1000)
print(f'{total_m}m')
" 2>/dev/null || echo "0m"
}

ns_mem_requests() {
  kubectl get pods -n "$1" -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
total_mi = 0
for pod in data.get('items', []):
    for c in pod.get('spec', {}).get('containers', []):
        req = c.get('resources', {}).get('requests', {}).get('memory', '0')
        if req.endswith('Mi'):
            total_mi += int(req[:-2])
        elif req.endswith('Gi'):
            total_mi += int(float(req[:-2]) * 1024)
        elif req.endswith('Ki'):
            total_mi += int(req[:-2]) // 1024
print(f'{total_mi}Mi')
" 2>/dev/null || echo "0Mi"
}

wait_suspended() {
  local ns="$1" timeout="${2:-60}" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    status=$(kubectl get ns "$ns" \
      -o jsonpath='{.metadata.labels.lifecycle-status}' 2>/dev/null || echo "")
    [[ "$status" == "suspended" ]] && return 0
    sleep 1; elapsed=$((elapsed + 1))
  done
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
section "PHASE 0 — Baseline"
# ═══════════════════════════════════════════════════════════════════════════════

T0=$(date +%s)
BASELINE_NS=$(kubectl get ns --no-headers 2>/dev/null | grep '^student-' | wc -l | tr -d ' ')
BASELINE_CPU=0
BASELINE_MEM=0

for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^student-'); do
  cpu_raw=$(kubectl get pods -n "$ns" -o json 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
t=0
for p in d.get('items',[]):
  for c in p.get('spec',{}).get('containers',[]):
    r=c.get('resources',{}).get('requests',{}).get('cpu','0')
    t += int(r[:-1]) if r.endswith('m') else int(float(r)*1000)
print(t)" 2>/dev/null || echo 0)
  BASELINE_CPU=$((BASELINE_CPU + cpu_raw))

  mem_raw=$(kubectl get pods -n "$ns" -o json 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
t=0
for p in d.get('items',[]):
  for c in p.get('spec',{}).get('containers',[]):
    r=c.get('resources',{}).get('requests',{}).get('memory','0')
    if r.endswith('Mi'): t+=int(r[:-2])
    elif r.endswith('Gi'): t+=int(float(r[:-2])*1024)
print(t)" 2>/dev/null || echo 0)
  BASELINE_MEM=$((BASELINE_MEM + mem_raw))
done

echo "  Existing student namespaces : ${BASELINE_NS}"
echo "  Aggregate CPU requests      : ${BASELINE_CPU}m"
echo "  Aggregate memory requests   : ${BASELINE_MEM}Mi"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
section "PHASE 1 — Automated Provisioning (5 students)"
# ═══════════════════════════════════════════════════════════════════════════════

declare -A PROVISION_TIMES
declare -A OBJECT_COUNTS

STORAGE_CLASS="standard"   # minikube default

for ID in "${ALL_STUDENTS[@]}"; do
  NS="student-${ID}"
  step "Provisioning ${NS} ..."

  # Clean up any leftover from a previous run
  helm uninstall "student-${ID}" -n "$NS" 2>/dev/null || true
  kubectl delete namespace "$NS" --ignore-not-found --wait=false 2>/dev/null || true
  sleep 1

  T_START=$(date +%s%3N)
  helm upgrade --install "student-${ID}" "$CHART_DIR" \
    --set studentId="${ID}" \
    --set storageClassName="${STORAGE_CLASS}" \
    --namespace "$NS" \
    --create-namespace \
    --wait=false \
    2>/dev/null
  T_END=$(date +%s%3N)

  ELAPSED_MS=$(( T_END - T_START ))
  PROVISION_TIMES[$ID]="${ELAPSED_MS}ms"
  ok "  ${NS} provisioned in ${ELAPSED_MS}ms"
done

echo ""
step "Waiting 10s for objects to settle ..."
sleep 10

# Count objects per student namespace
for ID in "${ALL_STUDENTS[@]}"; do
  NS="student-${ID}"
  CNT=$(ns_object_count "$NS")
  OBJECT_COUNTS[$ID]="$CNT"
  echo "  ${NS}: ${CNT} Kubernetes objects"
done

# ═══════════════════════════════════════════════════════════════════════════════
section "PHASE 2 — Isolation Verification"
# ═══════════════════════════════════════════════════════════════════════════════

step "ResourceQuota enforced per namespace:"
for ID in "${ALL_STUDENTS[@]}"; do
  NS="student-${ID}"
  QUOTA=$(kubectl get resourcequota student-quota -n "$NS" \
    -o jsonpath='{.spec.hard}' 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(f'{k}={v}' for k,v in sorted(d.items())))" \
    || echo "not found")
  echo "  ${NS}: ${QUOTA}"
done

echo ""
step "NetworkPolicies per namespace:"
for ID in "${ALL_STUDENTS[@]}"; do
  NS="student-${ID}"
  NETPOL=$(kubectl get networkpolicy -n "$NS" --no-headers 2>/dev/null \
    | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
  echo "  ${NS}: ${NETPOL}"
done

echo ""
step "RBAC: student role verbs (proving API-level isolation):"
for ID in "${ALL_STUDENTS[@]}"; do
  NS="student-${ID}"
  ROLE=$(kubectl get role student-role -n "$NS" \
    -o jsonpath='{.rules[*].verbs}' 2>/dev/null \
    | tr -d '[]"' | tr ' ' ',' | sed 's/,,*/,/g' | sed 's/^,//' | sed 's/,$//')
  echo "  ${NS}: allowed verbs = [${ROLE}]"
done

echo ""
step "Resource requests after provisioning:"
POST_PROVISION_CPU=0
POST_PROVISION_MEM=0
ALL_NS_NOW=$(kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^student-' | wc -l | tr -d ' ')

for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^student-'); do
  cpu_raw=$(kubectl get pods -n "$ns" -o json 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
t=0
for p in d.get('items',[]):
  for c in p.get('spec',{}).get('containers',[]):
    r=c.get('resources',{}).get('requests',{}).get('cpu','0')
    t += int(r[:-1]) if r.endswith('m') else int(float(r)*1000)
print(t)" 2>/dev/null || echo 0)
  POST_PROVISION_CPU=$((POST_PROVISION_CPU + cpu_raw))

  mem_raw=$(kubectl get pods -n "$ns" -o json 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
t=0
for p in d.get('items',[]):
  for c in p.get('spec',{}).get('containers',[]):
    r=c.get('resources',{}).get('requests',{}).get('memory','0')
    if r.endswith('Mi'): t+=int(r[:-2])
    elif r.endswith('Gi'): t+=int(float(r[:-2])*1024)
print(t)" 2>/dev/null || echo 0)
  POST_PROVISION_MEM=$((POST_PROVISION_MEM + mem_raw))
done

echo "  Total student namespaces    : ${ALL_NS_NOW}"
echo "  Aggregate CPU requests      : ${POST_PROVISION_CPU}m  (was ${BASELINE_CPU}m)"
echo "  Aggregate memory requests   : ${POST_PROVISION_MEM}Mi (was ${BASELINE_MEM}Mi)"
echo "  CPU added by 5 new students : $((POST_PROVISION_CPU - BASELINE_CPU))m"
echo "  Mem added by 5 new students : $((POST_PROVISION_MEM - BASELINE_MEM))Mi"

# ═══════════════════════════════════════════════════════════════════════════════
section "PHASE 3 — Lifecycle: Semester-End Simulation"
# ═══════════════════════════════════════════════════════════════════════════════

step "Setting PAST expiry (2020-01-01) on students 091, 092, 093 ..."
for ID in "${EXPIRED_STUDENTS[@]}"; do
  NS="student-${ID}"
  kubectl label namespace "$NS" expires-at=2020-01-01 --overwrite
  echo "  ${NS}: expires-at=2020-01-01"
done

step "Keeping FUTURE expiry (2099-12-31) on students 094, 095 ..."
for ID in "${ACTIVE_STUDENTS[@]}"; do
  NS="student-${ID}"
  # These already have the future date from helm install, just confirm
  EXPIRY=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.expires-at}' 2>/dev/null || echo "missing")
  echo "  ${NS}: expires-at=${EXPIRY}"
done

echo ""
step "Lifecycle controller watch event fired — measuring suspension latency ..."
echo ""

declare -A SUSPEND_LATENCY_S
T_LABEL=$(date +%s)

for ID in "${EXPIRED_STUDENTS[@]}"; do
  NS="student-${ID}"
  T_WAIT_START=$(date +%s)
  if wait_suspended "$NS" 60; then
    T_WAIT_END=$(date +%s)
    LATENCY=$(( T_WAIT_END - T_WAIT_START ))
    SUSPEND_LATENCY_S[$ID]="${LATENCY}s"
    REPLICAS=$(kubectl get statefulset "jupyter-${ID}" -n "$NS" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    ok "  ${NS} suspended in ${LATENCY}s (StatefulSet replicas=${REPLICAS})"
  else
    SUSPEND_LATENCY_S[$ID]="timeout"
    echo "  TIMEOUT waiting for ${NS} to be suspended"
  fi
done

echo ""
step "Verifying ACTIVE namespaces are NOT suspended (10s check):"
sleep 10
for ID in "${ACTIVE_STUDENTS[@]}"; do
  NS="student-${ID}"
  STATUS=$(kubectl get ns "$NS" \
    -o jsonpath='{.metadata.labels.lifecycle-status}' 2>/dev/null || echo "")
  REPLICAS=$(kubectl get statefulset "jupyter-${ID}" -n "$NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  if [[ -z "$STATUS" || "$STATUS" != "suspended" ]]; then
    ok "  ${NS}: lifecycle-status='${STATUS:-active}' replicas=${REPLICAS} (CORRECT — not suspended)"
  else
    echo "  ERROR: ${NS} was incorrectly suspended!"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════
section "PHASE 4 — Resource Reclamation"
# ═══════════════════════════════════════════════════════════════════════════════

POST_SUSPEND_CPU=0
POST_SUSPEND_MEM=0

for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^student-'); do
  cpu_raw=$(kubectl get pods -n "$ns" -o json 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
t=0
for p in d.get('items',[]):
  for c in p.get('spec',{}).get('containers',[]):
    r=c.get('resources',{}).get('requests',{}).get('cpu','0')
    t += int(r[:-1]) if r.endswith('m') else int(float(r)*1000)
print(t)" 2>/dev/null || echo 0)
  POST_SUSPEND_CPU=$((POST_SUSPEND_CPU + cpu_raw))

  mem_raw=$(kubectl get pods -n "$ns" -o json 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
t=0
for p in d.get('items',[]):
  for c in p.get('spec',{}).get('containers',[]):
    r=c.get('resources',{}).get('requests',{}).get('memory','0')
    if r.endswith('Mi'): t+=int(r[:-2])
    elif r.endswith('Gi'): t+=int(float(r[:-2])*1024)
print(t)" 2>/dev/null || echo 0)
  POST_SUSPEND_MEM=$((POST_SUSPEND_MEM + mem_raw))
done

echo "  After suspension:"
echo "    CPU requests : ${POST_SUSPEND_CPU}m"
echo "    Mem requests : ${POST_SUSPEND_MEM}Mi"
echo "  Freed by suspension:"
echo "    CPU freed    : $((POST_PROVISION_CPU - POST_SUSPEND_CPU))m"
echo "    Mem freed    : $((POST_PROVISION_MEM - POST_SUSPEND_MEM))Mi"

# ═══════════════════════════════════════════════════════════════════════════════
section "PHASE 5 — Final State Snapshot"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "  Namespace              Status           Replicas  Expires-At"
echo "  ─────────────────────────────────────────────────────────────"

for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^student-' | sort); do
  LC=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.lifecycle-status}' 2>/dev/null || echo "—")
  EXP=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.expires-at}' 2>/dev/null || echo "—")
  ID="${ns#student-}"
  STS_NAME="jupyter-${ID}"
  REP=$(kubectl get statefulset "$STS_NAME" -n "$ns" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "—")
  printf "  %-22s %-16s %-9s %s\n" "$ns" "${LC:-active}" "$REP" "$EXP"
done

T_END=$(date +%s)
TOTAL_S=$(( T_END - T0 ))

echo ""
echo "  Total experiment duration: ${TOTAL_S}s"

# ═══════════════════════════════════════════════════════════════════════════════
section "PHASE 6 — Cleanup Test Environment"
# ═══════════════════════════════════════════════════════════════════════════════

step "Hard-deleting experiment namespaces (091-095) ..."
for ID in "${ALL_STUDENTS[@]}"; do
  NS="student-${ID}"
  helm uninstall "student-${ID}" -n "$NS" 2>/dev/null || true
  kubectl delete namespace "$NS" --ignore-not-found --wait=false 2>/dev/null || true
  echo "  deleted ${NS}"
done
ok "Cleanup initiated."

# ═══════════════════════════════════════════════════════════════════════════════
# Emit structured data for report generation
# ═══════════════════════════════════════════════════════════════════════════════
cat > /tmp/experiment_data.env <<EOF
BASELINE_NS=${BASELINE_NS}
BASELINE_CPU=${BASELINE_CPU}
BASELINE_MEM=${BASELINE_MEM}
ALL_NS_NOW=${ALL_NS_NOW}
POST_PROVISION_CPU=${POST_PROVISION_CPU}
POST_PROVISION_MEM=${POST_PROVISION_MEM}
POST_SUSPEND_CPU=${POST_SUSPEND_CPU}
POST_SUSPEND_MEM=${POST_SUSPEND_MEM}
CPU_ADDED=$((POST_PROVISION_CPU - BASELINE_CPU))
MEM_ADDED=$((POST_PROVISION_MEM - BASELINE_MEM))
CPU_FREED=$((POST_PROVISION_CPU - POST_SUSPEND_CPU))
MEM_FREED=$((POST_PROVISION_MEM - POST_SUSPEND_MEM))
TOTAL_S=${TOTAL_S}
PROVISION_TIME_091=${PROVISION_TIMES[091]:-N/A}
PROVISION_TIME_092=${PROVISION_TIMES[092]:-N/A}
PROVISION_TIME_093=${PROVISION_TIMES[093]:-N/A}
PROVISION_TIME_094=${PROVISION_TIMES[094]:-N/A}
PROVISION_TIME_095=${PROVISION_TIMES[095]:-N/A}
SUSPEND_LAT_091=${SUSPEND_LATENCY_S[091]:-N/A}
SUSPEND_LAT_092=${SUSPEND_LATENCY_S[092]:-N/A}
SUSPEND_LAT_093=${SUSPEND_LATENCY_S[093]:-N/A}
OBJECT_CNT_091=${OBJECT_COUNTS[091]:-N/A}
OBJECT_CNT_092=${OBJECT_COUNTS[092]:-N/A}
OBJECT_CNT_093=${OBJECT_COUNTS[093]:-N/A}
OBJECT_CNT_094=${OBJECT_COUNTS[094]:-N/A}
OBJECT_CNT_095=${OBJECT_COUNTS[095]:-N/A}
EOF

echo ""
echo "  Data written to /tmp/experiment_data.env"
echo "  Report will be generated at: ${REPORT_FILE}"
