#!/usr/bin/env bash
# Deploy the Jupyter Student Portal (NGINX + CGI provisioner).
# Run this once before any students access the system.
#
# Usage:  bash provisioning/student/deploy.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "▶ Applying portal manifests ..."
for f in "$DIR/k8s"/0*.yaml; do
  echo "  kubectl apply -f $(basename "$f")"
  kubectl apply -f "$f"
done

echo ""
echo "▶ Waiting for provisioner pod to be ready ..."
kubectl wait --for=condition=ready pod \
  -l app=provisioner \
  -n jupyter-platform \
  --timeout=120s

# Discover access URL
NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
  2>/dev/null || echo "localhost")

echo ""
echo "════════════════════════════════════════════════════════"
echo " PORTAL READY"
echo "════════════════════════════════════════════════════════"
echo ""
echo " Student portal:"
echo "   http://${NODE_IP}:30080/"
echo ""
echo " Or port-forward:"
echo "   kubectl port-forward -n jupyter-platform svc/provisioner 8080:80"
echo "   → http://localhost:8080/"
echo ""
echo " Useful commands:"
echo "   # Watch all student namespaces"
echo "   watch kubectl get namespaces -l app=jupyter-platform"
echo ""
echo "   # Check a student's quota"
echo "   kubectl describe resourcequota -n student-007"
echo ""
echo "   # Watch all student pods"
echo "   kubectl get pods -A -l app=jupyter-platform"
echo ""
echo "   # Tear down portal only"
echo "   kubectl delete namespace jupyter-platform"
echo ""
echo "   # Tear down a student"
echo "   kubectl delete namespace student-007"
echo "════════════════════════════════════════════════════════"
