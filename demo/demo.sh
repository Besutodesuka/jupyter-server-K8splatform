#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  Platform Demo Script
#  Self-Service Provisioning + Lifecycle Management
#
#  Usage:
#    bash demo/demo.sh           # run all scenes interactively
#    bash demo/demo.sh --reset   # clean up demo namespaces and exit
#
#  Requirements:
#    - minikube running with lifecycle-controller deployed
#    - Run from repo root: /home/sk09/workspace/k8s/jupyter-server-K8splatform
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

CHART_DIR="provisioning/student/chart"
DEMO_ID="099"
DEMO_NS="student-${DEMO_ID}"

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
banner() {
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

scene() {
  echo ""
  echo -e "${BOLD}${YELLOW}▶ SCENE $*${NC}"
  echo ""
}

narrate() {
  echo -e "${DIM}# $*${NC}"
}

pause() {
  echo ""
  echo -e "${GREEN}[Press ENTER to continue]${NC}"
  read -r
}

run() {
  # Print the command in bold then execute it
  echo -e "${BOLD}\$ $*${NC}"
  eval "$*"
  echo ""
}

ok() { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${CYAN}ℹ $*${NC}"; }

# ── Reset mode ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--reset" ]]; then
  echo "Cleaning up demo namespace ${DEMO_NS} ..."
  helm uninstall "student-${DEMO_ID}" -n "${DEMO_NS}" 2>/dev/null || true
  kubectl delete namespace "${DEMO_NS}" --ignore-not-found --wait=false
  kubectl delete pvc "jupyter-workspace-${DEMO_ID}" -n "${DEMO_NS}" --ignore-not-found 2>/dev/null || true
  echo "Done."
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT CHECK
# ══════════════════════════════════════════════════════════════════════════════
banner "PRE-FLIGHT CHECK"

narrate "Verify the lifecycle-controller is running before we start"
run "kubectl get deployment lifecycle-controller -n jupyter-platform"

narrate "Verify the demo namespace does not already exist"
if kubectl get namespace "${DEMO_NS}" &>/dev/null; then
  echo -e "${RED}⚠  ${DEMO_NS} already exists. Run:  bash demo/demo.sh --reset${NC}"
  exit 1
fi
ok "${DEMO_NS} does not exist — clean slate confirmed"

# ══════════════════════════════════════════════════════════════════════════════
#  DEMO PART 1 — SELF-SERVICE PROVISIONING
# ══════════════════════════════════════════════════════════════════════════════
banner "PART 1 — SELF-SERVICE PROVISIONING"

info "We will provision student-099 using one Helm command."
info "Watch how fast 11 isolated Kubernetes objects appear."
pause

# ── Scene 1: Show existing students ──────────────────────────────────────────
scene "1/6 — Current state (before provisioning)"

narrate "Show all existing student namespaces on the cluster"
run "kubectl get namespaces | grep student || echo '(no student namespaces yet)'"

narrate "Show the lifecycle-controller is watching in the background"
run "kubectl get pods -n jupyter-platform -l app=lifecycle-controller"

pause

# ── Scene 2: Provision ───────────────────────────────────────────────────────
scene "2/6 — Provision student-099 (one command)"

narrate "This single Helm command creates the namespace, quota, network"
narrate "policies, RBAC, PVC, and Jupyter StatefulSet — all in one shot."
echo ""

run "time helm upgrade --install student-${DEMO_ID} ${CHART_DIR} \
  --set studentId=${DEMO_ID} \
  --set semester=2026-spring \
  --set expiresAt=2026-08-31 \
  --set storageClassName=standard \
  --namespace ${DEMO_NS} \
  --wait=false"

ok "Provisioning complete"
pause

# ── Scene 3: Show all 11 objects ─────────────────────────────────────────────
scene "3/6 — Verify: 11 Kubernetes objects created"

narrate "Every object that makes this environment isolated and production-grade"
run "kubectl get statefulset,service,pvc,resourcequota,limitrange,networkpolicy,rolebinding \
  -n ${DEMO_NS}"

pause

# ── Scene 4: Show ResourceQuota ──────────────────────────────────────────────
scene "4/6 — Verify: Resource isolation enforced"

narrate "Hard ceiling: student-099 cannot use more than 1 CPU and 1Gi RAM"
narrate "Any pod that exceeds this is rejected by the API server before scheduling"
run "kubectl describe resourcequota student-quota -n ${DEMO_NS}"

pause

# ── Scene 5: Show NetworkPolicy ──────────────────────────────────────────────
scene "5/6 — Verify: Network isolation (5 rules)"

narrate "Default-deny blocks all traffic. Only these explicit rules are allowed."
run "kubectl get networkpolicy -n ${DEMO_NS}"

pause

# ── Scene 6: Show lifecycle labels ───────────────────────────────────────────
scene "6/6 — Verify: Lifecycle labels stamped on namespace"

narrate "The Helm chart stamped expires-at automatically."
narrate "This is what the lifecycle-controller reads to know when to suspend."
run "kubectl get namespace ${DEMO_NS} \
  -o custom-columns=\
'NAMESPACE:.metadata.name,\
PLATFORM:.metadata.labels.platform,\
SEMESTER:.metadata.labels.semester,\
EXPIRES:.metadata.labels.expires-at,\
STATUS:.metadata.labels.lifecycle-status'"

ok "Part 1 complete — student-099 is fully provisioned and isolated"

# ══════════════════════════════════════════════════════════════════════════════
#  DEMO PART 2 — LIFECYCLE MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════
banner "PART 2 — LIFECYCLE MANAGEMENT"

info "We will simulate a semester ending by changing the expires-at label."
info "Watch the controller suspend the namespace in under 1 second."
echo ""
echo -e "${YELLOW}TIP: Open a second terminal and run:${NC}"
echo -e "${BOLD}  kubectl logs -n jupyter-platform -l app=lifecycle-controller -f${NC}"
pause

# ── Scene 7: Confirm pod is running ──────────────────────────────────────────
scene "7/10 — Confirm Jupyter pod is running (replicas=1)"

narrate "The StatefulSet is running — student can access JupyterLab right now"
run "kubectl get statefulset jupyter-${DEMO_ID} -n ${DEMO_NS} \
  -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'"

pause

# ── Scene 8: Confirm status is empty ─────────────────────────────────────────
scene "8/10 — Confirm lifecycle-status is empty (active)"

run "kubectl get namespace ${DEMO_NS} \
  -o jsonpath='expires-at    = {.metadata.labels.expires-at}{\"\\n\"}lifecycle-status = {.metadata.labels.lifecycle-status}{\"\\n\"}'"

narrate "lifecycle-status is empty = namespace is active and running"
pause

# ── Scene 9: THE KEY MOMENT — trigger expiry ─────────────────────────────────
scene "9/10 — Trigger semester end (watch controller react)"

narrate "Changing expires-at to a past date simulates the semester ending."
narrate "The controller watches all namespaces via Kubernetes API events."
narrate "It will detect this change and suspend immediately — no cron, no wait."
echo ""
echo -e "${RED}${BOLD}>>> Watch the controller logs now <<<${NC}"
echo ""

T_START=$(date +%s%3N)
run "kubectl label namespace ${DEMO_NS} expires-at=2020-01-01 --overwrite"

narrate "Measuring time until suspension..."
SUSPENDED=0
for i in $(seq 1 30); do
  STATUS=$(kubectl get namespace "${DEMO_NS}" \
    -o jsonpath='{.metadata.labels.lifecycle-status}' 2>/dev/null || echo "")
  if [[ "$STATUS" == "suspended" ]]; then
    T_END=$(date +%s%3N)
    ELAPSED_MS=$(( T_END - T_START ))
    SUSPENDED=1
    break
  fi
  sleep 0.5
done

if [[ $SUSPENDED -eq 1 ]]; then
  ok "Controller suspended ${DEMO_NS} in ${ELAPSED_MS}ms"
else
  echo -e "${RED}Timeout waiting for suspension (check controller logs)${NC}"
fi

pause

# ── Scene 10: Show results ────────────────────────────────────────────────────
scene "10/10 — Verify suspension results"

narrate "Check 1: StatefulSet scaled to 0 — pod deleted, CPU and RAM freed"
run "kubectl get statefulset jupyter-${DEMO_ID} -n ${DEMO_NS} \
  -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'"

echo ""
narrate "Check 2: Namespace labels updated by controller"
run "kubectl get namespace ${DEMO_NS} \
  -o custom-columns=\
'NAMESPACE:.metadata.name,\
EXPIRES:.metadata.labels.expires-at,\
STATUS:.metadata.labels.lifecycle-status,\
SUSPENDED_AT:.metadata.labels.suspended-at'"

echo ""
narrate "Check 3: PVC still exists — student data is SAFE (soft-delete)"
run "kubectl get pvc -n ${DEMO_NS}"

echo ""
narrate "Check 4: Controller audit log (last 5 lines)"
run "kubectl logs -n jupyter-platform -l app=lifecycle-controller --tail=5"

# ══════════════════════════════════════════════════════════════════════════════
#  CLEANUP
# ══════════════════════════════════════════════════════════════════════════════
banner "CLEANUP"

echo -e "Run the following to remove the demo namespace:"
echo -e "${BOLD}  bash demo/demo.sh --reset${NC}"
echo ""
echo -e "Or keep it for further exploration:"
echo -e "${DIM}  kubectl get all -n ${DEMO_NS}${NC}"
echo ""

ok "Demo complete."
