#!/usr/bin/env bash
# Build and deploy the lifecycle controller to a minikube cluster.
#
# Prerequisites:
#   - Docker running
#   - minikube running (minikube start)
#   - kubectl configured to point at minikube
#   - jupyter-platform namespace must exist (run provisioning/student/deploy.sh first)
#
# Usage:
#   bash provisioning/lifecycle-controller/deploy.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "▶ [1/3] Building lifecycle-controller Docker image ..."
docker build -t lifecycle-controller:latest "$DIR"
echo "  Image built."

echo "▶ [2/3] Loading image into minikube ..."
minikube image load lifecycle-controller:latest
echo "  Image loaded."

echo "▶ [3/3] Applying Kubernetes manifests ..."
for f in "$DIR/k8s"/0[0-9]-*.yaml; do
  kubectl apply -f "$f"
  echo "  applied $(basename "$f")"
done

kubectl rollout status deployment/lifecycle-controller -n jupyter-platform --timeout=120s

echo ""
echo "════════════════════════════════════════════════════════"
echo " LIFECYCLE CONTROLLER"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  Status:   kubectl get deployment lifecycle-controller -n jupyter-platform"
echo "  Logs:     kubectl logs -n jupyter-platform -l app=lifecycle-controller -f"
echo "  Suspended: kubectl get ns -l lifecycle-status=suspended"
echo ""
echo "  Admin CLI:"
echo "    bash provisioning/student/deprovision.sh --expired --suspend          # dry-run"
echo "    bash provisioning/student/deprovision.sh --expired --suspend --confirm # execute"
echo "════════════════════════════════════════════════════════"
