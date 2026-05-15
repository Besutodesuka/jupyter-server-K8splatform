#!/usr/bin/env bash
# Deploy the Jupyter Student Portal.
#
# Usage:
#   bash provisioning/student/deploy.sh [--storage-class <name>] [--reset]
#
# Options:
#   --storage-class <name>   StorageClass for student PVCs (auto-detected if omitted)
#                            minikube → standard   |   k3s → local-path
#   --reset                  Delete the portal namespace first, then redeploy
#
# Examples:
#   bash provisioning/student/deploy.sh
#   bash provisioning/student/deploy.sh --storage-class standard
#   bash provisioning/student/deploy.sh --reset
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ────────────────────────────────────────────────────────────
STORAGE_CLASS=""
RESET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --reset)         RESET=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Auto-detect StorageClass ───────────────────────────────────────────────────
if [[ -z "$STORAGE_CLASS" ]]; then
  if minikube status &>/dev/null; then
    STORAGE_CLASS="standard"
    echo "▶ Detected minikube — using StorageClass: standard"
  else
    STORAGE_CLASS="local-path"
    echo "▶ Non-minikube cluster — using StorageClass: local-path"
  fi
fi

# ── Optional reset ─────────────────────────────────────────────────────────────
if [[ "$RESET" == "true" ]]; then
  echo "▶ [1/5] Deleting existing portal namespace ..."
  kubectl delete namespace jupyter-platform --ignore-not-found
  echo "  Done."
fi

# ── Apply portal infrastructure (manifests 00–08) ─────────────────────────────
echo "▶ [2/5] Applying portal manifests ..."
for f in "$DIR/k8s"/[0-9][0-9]-*.yaml; do
  # Patch StorageClass env var into the provisioner Deployment on the fly
  if [[ "$(basename "$f")" == "07-deployment.yaml" ]]; then
    sed "s/value: \"standard\"/value: \"${STORAGE_CLASS}\"/" "$f" \
      | kubectl apply -f -
    echo "  applied 07-deployment.yaml  (STORAGE_CLASS=${STORAGE_CLASS})"
  else
    kubectl apply -f "$f"
    echo "  applied $(basename "$f")"
  fi
done

# ── Generate Helm chart ConfigMaps from source ─────────────────────────────────
echo "▶ [3/5] Syncing Helm chart ConfigMaps from chart/ ..."

kubectl create configmap helm-chart-meta \
  -n jupyter-platform \
  --from-file=Chart.yaml="$DIR/chart/Chart.yaml" \
  --from-file=values.yaml="$DIR/chart/values.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  synced helm-chart-meta"

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
echo "  synced helm-chart-templates"

# ── Wait for provisioner to be ready ──────────────────────────────────────────
echo "▶ [4/5] Waiting for provisioner pod to be ready (up to 5 min) ..."
kubectl wait --for=condition=ready pod \
  -l app=provisioner \
  -n jupyter-platform \
  --timeout=300s

# ── Print access info ─────────────────────────────────────────────────────────
NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
  2>/dev/null || echo "localhost")

echo ""
echo "▶ [5/5] Portal ready."
echo ""
echo "════════════════════════════════════════════════════════"
echo " STUDENT PORTAL"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  NodePort:     http://${NODE_IP}:30080/"
echo "  Port-forward: kubectl port-forward -n jupyter-platform svc/provisioner 8080:80"
echo "                → http://localhost:8080/"
echo ""
echo "  Current limits (chart/values.yaml):"
grep -A4 "^resources:" "$DIR/chart/values.yaml" | sed 's/^/    /'
echo ""
echo "  Change limits:"
echo "    bash provisioning/student/set-limits.sh --cpu <val> --memory <val>"
echo ""
echo "  Useful commands:"
echo "    helm list -A                                  # all student releases"
echo "    kubectl describe resourcequota -n student-007 # check a student's quota"
echo "    kubectl get pods -A | grep ^student-          # all student pods"
echo "════════════════════════════════════════════════════════"
