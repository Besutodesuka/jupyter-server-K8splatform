#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORAGE_CLASS="${STORAGE_CLASS:-standard}"

echo "==> Deploying monitoring stack (node-exporter + Prometheus + Grafana)"
echo "    StorageClass: ${STORAGE_CLASS}"
echo ""

# Patch storageClassName before applying if non-standard
if [[ "${STORAGE_CLASS}" != "standard" ]]; then
  sed -i.bak "s/storageClassName: standard/storageClassName: ${STORAGE_CLASS}/g" \
    "${SCRIPT_DIR}/05-prometheus-deployment.yaml" \
    "${SCRIPT_DIR}/07-grafana-deployment.yaml"
fi

echo "--- namespace"
kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"

echo "--- RBAC"
kubectl apply -f "${SCRIPT_DIR}/01-rbac.yaml"

echo "--- node-exporter DaemonSet"
kubectl apply -f "${SCRIPT_DIR}/02-node-exporter-daemonset.yaml"

echo "--- kube-state-metrics"
kubectl apply -f "${SCRIPT_DIR}/03-kube-state-metrics.yaml"

echo "--- Prometheus config"
kubectl apply -f "${SCRIPT_DIR}/04-prometheus-config.yaml"

echo "--- Prometheus deployment"
kubectl apply -f "${SCRIPT_DIR}/05-prometheus-deployment.yaml"

echo "--- Grafana config"
kubectl apply -f "${SCRIPT_DIR}/06-grafana-config.yaml"

echo "--- Grafana deployment"
kubectl apply -f "${SCRIPT_DIR}/07-grafana-deployment.yaml"

echo ""
echo "==> Waiting for rollouts..."
kubectl rollout status daemonset/node-exporter    -n monitoring --timeout=120s
kubectl rollout status deployment/kube-state-metrics -n monitoring --timeout=120s
kubectl rollout status deployment/prometheus      -n monitoring --timeout=120s
kubectl rollout status deployment/grafana         -n monitoring --timeout=120s

echo ""
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")
echo "==> Stack ready:"
echo "    Prometheus : http://${NODE_IP}:30090"
echo "    Grafana    : http://${NODE_IP}:30030  (admin / admin)"
echo ""
echo "    Or port-forward:"
echo "    kubectl port-forward -n monitoring svc/prometheus 9090:9090"
echo "    kubectl port-forward -n monitoring svc/grafana    3000:3000"
