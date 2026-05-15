#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  Live Watch Panel — run this in a second terminal while demo.sh runs
#  Shows namespace labels + StatefulSet replicas updating in real-time
# ══════════════════════════════════════════════════════════════════════════════

DEMO_NS="${1:-student-099}"

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

while true; do
  clear
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  LIVE WATCH — ${DEMO_NS}   $(date '+%H:%M:%S')${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  # Namespace labels
  echo -e "${BOLD}Namespace Labels:${NC}"
  EXPIRES=$(kubectl get namespace "${DEMO_NS}" \
    -o jsonpath='{.metadata.labels.expires-at}' 2>/dev/null || echo "—")
  STATUS=$(kubectl get namespace "${DEMO_NS}" \
    -o jsonpath='{.metadata.labels.lifecycle-status}' 2>/dev/null || echo "—")
  SUSPENDED_AT=$(kubectl get namespace "${DEMO_NS}" \
    -o jsonpath='{.metadata.labels.suspended-at}' 2>/dev/null || echo "—")

  echo -e "  expires-at       = ${YELLOW}${EXPIRES}${NC}"

  if [[ "$STATUS" == "suspended" ]]; then
    echo -e "  lifecycle-status = ${RED}${BOLD}${STATUS}${NC}"
    echo -e "  suspended-at     = ${RED}${SUSPENDED_AT}${NC}"
  else
    echo -e "  lifecycle-status = ${GREEN}${STATUS:-active (empty)}${NC}"
    echo -e "  suspended-at     = ${STATUS:-—}"
  fi

  echo ""

  # StatefulSet replicas
  echo -e "${BOLD}StatefulSet:${NC}"
  REPLICAS=$(kubectl get statefulset -n "${DEMO_NS}" \
    -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo "—")

  if [[ "$REPLICAS" == "0" ]]; then
    echo -e "  spec.replicas    = ${RED}${BOLD}0  ← suspended${NC}"
  elif [[ "$REPLICAS" == "1" ]]; then
    echo -e "  spec.replicas    = ${GREEN}${BOLD}1  ← running${NC}"
  else
    echo -e "  spec.replicas    = ${YELLOW}${REPLICAS}${NC}"
  fi

  echo ""

  # PVC status
  echo -e "${BOLD}PVC (student data):${NC}"
  PVC=$(kubectl get pvc -n "${DEMO_NS}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  PVC_STATUS=$(kubectl get pvc -n "${DEMO_NS}" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

  if [[ -n "$PVC" ]]; then
    echo -e "  ${PVC}  ${GREEN}${PVC_STATUS}${NC}  ← data preserved"
  else
    echo -e "  (none)"
  fi

  echo ""
  echo -e "${BOLD}Controller Logs (last 4):${NC}"
  kubectl logs -n jupyter-platform -l app=lifecycle-controller \
    --tail=4 2>/dev/null \
    | grep --color=never -E "suspended|active|error|INFO|WARN" \
    | sed 's/^/  /'

  echo ""
  echo -e "${CYAN}Refreshing every 1s — Ctrl+C to stop${NC}"
  sleep 1
done
