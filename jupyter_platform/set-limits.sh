#!/usr/bin/env bash
# Change the hard CPU/memory/storage limit for all student Jupyter pods.
#
# Usage:
#   bash provisioning/student/set-limits.sh --cpu <val> --memory <val> [options]
#
# Options:
#   --cpu <val>       CPU hard limit per pod  (e.g. 1, 500m, 2)
#   --memory <val>    RAM hard limit per pod  (e.g. 2Gi, 1Gi, 512Mi)
#   --storage <val>   Disk quota per student  (e.g. 10Gi, 5Gi)   [optional]
#   --upgrade-all     Apply new limits to all already-provisioned students via helm upgrade
#
# Examples:
#   bash provisioning/student/set-limits.sh --cpu 2 --memory 4Gi
#   bash provisioning/student/set-limits.sh --cpu 500m --memory 1Gi --storage 5Gi --upgrade-all
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="$DIR/chart/values.yaml"

# ── Parse arguments ────────────────────────────────────────────────────────────
CPU=""
MEMORY=""
STORAGE=""
UPGRADE_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)         CPU="$2";     shift 2 ;;
    --memory)      MEMORY="$2";  shift 2 ;;
    --storage)     STORAGE="$2"; shift 2 ;;
    --upgrade-all) UPGRADE_ALL=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$CPU" && -z "$MEMORY" && -z "$STORAGE" ]]; then
  echo "Error: at least one of --cpu, --memory, or --storage is required."
  echo "Usage: bash set-limits.sh --cpu <val> --memory <val> [--storage <val>] [--upgrade-all]"
  exit 1
fi

# ── Patch chart/values.yaml in-place ──────────────────────────────────────────
echo "▶ Updating chart/values.yaml ..."

if [[ -n "$CPU" ]]; then
  # Replace both the pod limit and (if present) any old quota.limitsCpu line
  sed -i "s|^    cpu: .*  # limits|    cpu: \"${CPU}\"  # limits|" "$VALUES" 2>/dev/null || true
  # Generic replacement for the limits.cpu line under resources.limits
  python3 - "$VALUES" "$CPU" <<'PYEOF'
import sys, re

path, val = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()

in_resources = in_limits = False
new_lines = []
for line in lines:
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if stripped.startswith("resources:"):
        in_resources = True
    elif in_resources and indent <= 0 and stripped and not stripped.startswith("#"):
        in_resources = False
        in_limits = False
    if in_resources and stripped.startswith("limits:"):
        in_limits = True
    elif in_resources and in_limits and indent <= 2 and stripped and not stripped.startswith("cpu:") and not stripped.startswith("memory:") and not stripped.startswith("#"):
        in_limits = False
    if in_resources and in_limits and stripped.startswith("cpu:"):
        line = " " * indent + f'cpu: "{val}"\n'
    new_lines.append(line)

with open(path, "w") as f:
    f.writelines(new_lines)
PYEOF
  echo "  resources.limits.cpu → ${CPU}"
fi

if [[ -n "$MEMORY" ]]; then
  python3 - "$VALUES" "$MEMORY" <<'PYEOF'
import sys, re

path, val = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()

in_resources = in_limits = False
new_lines = []
for line in lines:
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if stripped.startswith("resources:"):
        in_resources = True
    elif in_resources and indent <= 0 and stripped and not stripped.startswith("#"):
        in_resources = False
        in_limits = False
    if in_resources and stripped.startswith("limits:"):
        in_limits = True
    elif in_resources and in_limits and indent <= 2 and stripped and not stripped.startswith("cpu:") and not stripped.startswith("memory:") and not stripped.startswith("#"):
        in_limits = False
    if in_resources and in_limits and stripped.startswith("memory:"):
        line = " " * indent + f'memory: "{val}"\n'
    new_lines.append(line)

with open(path, "w") as f:
    f.writelines(new_lines)
PYEOF
  echo "  resources.limits.memory → ${MEMORY}"
fi

if [[ -n "$STORAGE" ]]; then
  sed -i "s|^  storage: \".*\"|  storage: \"${STORAGE}\"|" "$VALUES"
  sed -i "/^quota:/,/^[^ ]/ s|  storage: \".*\"|  storage: \"${STORAGE}\"|" "$VALUES"
  echo "  quota.storage / storage → ${STORAGE}"
fi

echo ""
echo "  New values.yaml limits section:"
grep -A6 "^resources:" "$VALUES" | sed 's/^/    /'
echo ""

# ── Sync ConfigMaps from updated chart ────────────────────────────────────────
echo "▶ Syncing Helm chart ConfigMaps ..."

kubectl create configmap helm-chart-meta \
  -n jupyter-platform \
  --from-file=Chart.yaml="$DIR/chart/Chart.yaml" \
  --from-file=values.yaml="$DIR/chart/values.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap helm-chart-templates \
  -n jupyter-platform \
  --from-file=resourcequota.yaml="$DIR/chart/templates/resourcequota.yaml" \
  --from-file=limitrange.yaml="$DIR/chart/templates/limitrange.yaml" \
  --from-file=networkpolicies.yaml="$DIR/chart/templates/networkpolicies.yaml" \
  --from-file=serviceaccount.yaml="$DIR/chart/templates/serviceaccount.yaml" \
  --from-file=rbac.yaml="$DIR/chart/templates/rbac.yaml" \
  --from-file=pvc.yaml="$DIR/chart/templates/pvc.yaml" \
  --from-file=statefulset.yaml="$DIR/chart/templates/statefulset.yaml" \
  --from-file=service.yaml="$DIR/chart/templates/service.yaml" \
  --from-file=namespace.yaml="$DIR/chart/templates/namespace.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ConfigMaps updated."

# ── Restart provisioner to pick up new chart ──────────────────────────────────
echo "▶ Restarting provisioner ..."
kubectl rollout restart deployment/provisioner -n jupyter-platform
kubectl rollout status deployment/provisioner -n jupyter-platform --timeout=120s
echo "  Provisioner ready. New students will get the updated limits."

# ── Optional: bulk upgrade existing students ──────────────────────────────────
if [[ "$UPGRADE_ALL" == "true" ]]; then
  echo ""
  echo "▶ Upgrading all existing student releases ..."
  UPGRADED=0
  for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep '^student-' || true); do
    ID="${ns#student-}"
    echo "  helm upgrade student-${ID} -n ${ns} ..."
    helm upgrade "student-${ID}" /helm/student-chart \
      --set "studentId=${ID}" \
      --reuse-values \
      -n "$ns" 1>/dev/null
    UPGRADED=$((UPGRADED + 1))
  done
  echo "  Upgraded ${UPGRADED} student release(s)."
fi

echo ""
echo "Done. New limits take effect for newly provisioned students immediately."
[[ "$UPGRADE_ALL" == "false" ]] && echo "Run with --upgrade-all to apply to existing students too."
