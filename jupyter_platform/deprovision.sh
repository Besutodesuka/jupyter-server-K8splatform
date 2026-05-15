#!/usr/bin/env bash
# Admin lifecycle tool for the Jupyter student platform.
#
# The lifecycle controller (provisioning/lifecycle-controller/) handles
# automated suspension. Use this script for:
#   - Manual immediate suspension of one or more environments
#   - Permanent hard-deletion (removes namespace + PVC — data cannot be recovered)
#   - Bulk operations by semester or expiry date
#
# Usage:
#   bash provisioning/student/deprovision.sh [TARGET] [ACTION] [--confirm]
#
# Targets (pick one):
#   --student <id>       Single student (e.g. 007 or 7)
#   --all                All student namespaces (label: platform=jupyter-student)
#   --semester <name>    All students of a semester (e.g. 2025-spring)
#   --expired            Namespaces whose expires-at label is in the past
#
# Actions (pick one):
#   --suspend            Scale StatefulSet to 0 — frees compute, keeps PVC + namespace
#   --delete             Full removal: helm uninstall + kubectl delete namespace
#                        WARNING: this permanently removes the PVC and all student data.
#
# Safety flags:
#   --dry-run            Print what would happen; make no changes (DEFAULT)
#   --confirm            Required to actually execute --suspend or --delete
#
# Examples:
#   # Show which namespaces are expired (safe — dry-run is default)
#   bash provisioning/student/deprovision.sh --expired --suspend
#
#   # Suspend all expired students (frees compute, keeps data)
#   bash provisioning/student/deprovision.sh --expired --suspend --confirm
#
#   # Suspend every student in a semester
#   bash provisioning/student/deprovision.sh --semester 2025-spring --suspend --confirm
#
#   # Hard-delete one student (DESTROYS DATA — interactive confirmation required)
#   bash provisioning/student/deprovision.sh --student 007 --delete --confirm
#
#   # Label existing namespaces that predate lifecycle tracking (one-time migration):
#   kubectl label ns student-007 platform=jupyter-student \
#     semester=2025-spring expires-at=2025-08-31 --overwrite
#
set -euo pipefail

# ── Parse arguments ────────────────────────────────────────────────────────────
TARGET_MODE=""
TARGET_VALUE=""
ACTION=""
DRY_RUN=true
CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --student)   TARGET_MODE="student";  TARGET_VALUE="$2"; shift 2 ;;
    --all)       TARGET_MODE="all";      shift ;;
    --semester)  TARGET_MODE="semester"; TARGET_VALUE="$2"; shift 2 ;;
    --expired)   TARGET_MODE="expired";  shift ;;
    --suspend)   ACTION="suspend";       shift ;;
    --delete)    ACTION="delete";        shift ;;
    --dry-run)   DRY_RUN=true;           shift ;;
    --confirm)   DRY_RUN=false; CONFIRM=true; shift ;;
    --help|-h)
      sed -n '2,45p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validate ───────────────────────────────────────────────────────────────────
if [[ -z "$TARGET_MODE" ]]; then
  echo "Error: target required. Use --student, --all, --semester, or --expired."
  exit 1
fi
if [[ -z "$ACTION" ]]; then
  echo "Error: action required. Use --suspend or --delete."
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "▶ DRY RUN — no changes will be made. Pass --confirm to execute."
  echo ""
fi

# ── Extra gate for irreversible delete ────────────────────────────────────────
if [[ "$ACTION" == "delete" && "$CONFIRM" == "true" ]]; then
  echo "WARNING: --delete with --confirm permanently removes namespaces and PVCs."
  echo "         Student data CANNOT be recovered after this operation."
  echo ""
  read -r -p "Type 'yes' to continue: " CONFIRM_INPUT
  if [[ "$CONFIRM_INPUT" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# ── Resolve target namespaces ─────────────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)

resolve_namespaces() {
  case "$TARGET_MODE" in
    student)
      NUM=$((10#${TARGET_VALUE}))
      if [[ $NUM -lt 1 || $NUM -gt 100 ]]; then
        echo "Error: student ID must be between 1 and 100." >&2; exit 1
      fi
      printf "student-%03d\n" "$NUM"
      ;;
    all)
      kubectl get namespaces -l platform=jupyter-student \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true
      ;;
    semester)
      kubectl get namespaces -l "platform=jupyter-student,semester=${TARGET_VALUE}" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true
      ;;
    expired)
      # Kubernetes label selectors don't support less-than on string values,
      # so we fetch all and filter locally by comparing YYYY-MM-DD strings.
      kubectl get namespaces -l platform=jupyter-student \
        --no-headers -o custom-columns=":metadata.name,:metadata.labels.expires-at" \
        2>/dev/null | while read -r ns expires; do
          if [[ -n "$expires" && "$expires" < "$TODAY" ]]; then
            echo "$ns"
          fi
        done
      ;;
  esac
}

NAMESPACES=$(resolve_namespaces || true)

if [[ -z "$NAMESPACES" ]]; then
  echo "No matching namespaces found. Nothing to do."
  exit 0
fi

NS_COUNT=$(echo "$NAMESPACES" | wc -l | tr -d ' ')
echo "Target namespaces (${NS_COUNT}):"
echo "$NAMESPACES" | sed 's/^/  /'
echo ""
echo "Action: ${ACTION}"
echo ""

# ── Execute ────────────────────────────────────────────────────────────────────
DONE=0
FAILED=0

while IFS= read -r NS; do
  [[ -z "$NS" ]] && continue

  case "$ACTION" in
    # ── Suspend: scale StatefulSet to 0 ───────────────────────────────────────
    suspend)
      STS=$(kubectl get statefulset -n "$NS" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1 || true)

      if [[ -z "$STS" ]]; then
        echo "  SKIP  ${NS}: no StatefulSet found."
        continue
      fi

      CURRENT=$(kubectl get statefulset "$STS" -n "$NS" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

      if [[ "$CURRENT" == "0" ]]; then
        echo "  SKIP  ${NS}/${STS}: already suspended (replicas=0)."
        continue
      fi

      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY   ${NS}/${STS}: would scale 0 (currently ${CURRENT} replica(s))."
      else
        if kubectl scale statefulset "$STS" -n "$NS" --replicas=0; then
          kubectl label namespace "$NS" lifecycle-status=suspended \
            suspended-at="${TODAY}" --overwrite
          echo "  OK    ${NS}/${STS}: suspended. PVC and namespace preserved."
          DONE=$((DONE + 1))
        else
          echo "  ERROR ${NS}/${STS}: scale failed." >&2
          FAILED=$((FAILED + 1))
        fi
      fi
      ;;

    # ── Delete: helm uninstall + kubectl delete namespace ─────────────────────
    delete)
      RELEASE="$NS"   # release name == namespace name by provisioning convention

      if [[ "$DRY_RUN" == "true" ]]; then
        if helm status "$RELEASE" -n "$NS" &>/dev/null 2>&1; then
          echo "  DRY   ${NS}: would run: helm uninstall ${RELEASE} -n ${NS}"
        else
          echo "  DRY   ${NS}: no Helm release found; would skip helm uninstall."
        fi
        echo "  DRY   ${NS}: would run: kubectl delete namespace ${NS}"
        echo "  DRY   ${NS}: NOTE — PVC is removed with the namespace (helm.sh/resource-policy: keep"
        echo "               only protects against 'helm uninstall', not 'kubectl delete namespace')."
      else
        if helm status "$RELEASE" -n "$NS" &>/dev/null 2>&1; then
          echo "  Running: helm uninstall ${RELEASE} -n ${NS}"
          helm uninstall "$RELEASE" -n "$NS" || true
        fi
        echo "  Running: kubectl delete namespace ${NS}"
        if kubectl delete namespace "$NS" --ignore-not-found; then
          echo "  OK    ${NS}: deleted (PVC and all data removed)."
          DONE=$((DONE + 1))
        else
          echo "  ERROR ${NS}: namespace deletion failed." >&2
          FAILED=$((FAILED + 1))
        fi
      fi
      ;;
  esac

done <<< "$NAMESPACES"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run complete. ${NS_COUNT} namespace(s) would be affected."
  echo "Re-run with --confirm to execute."
else
  echo "Done. success=${DONE} failed=${FAILED}."
  [[ "$FAILED" -eq 0 ]] || exit 1
fi
