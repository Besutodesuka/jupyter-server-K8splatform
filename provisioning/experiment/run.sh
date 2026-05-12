#!/usr/bin/env bash
# Deploys the experiment, seeds data, and prints access info.
# Usage: bash run.sh [--skip-data]  (--skip-data skips the 100k row generation)
set -euo pipefail

NAMESPACE=jupyter-experiment
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S="$DIR/k8s"
SCRIPTS="$DIR/scripts"
SKIP_DATA=false

for arg in "$@"; do [[ "$arg" == "--skip-data" ]] && SKIP_DATA=true; done

# ── deploy ────────────────────────────────────────────────────────────────────
echo "▶ Applying manifests ..."
kubectl apply -f "$K8S/namespace.yaml"
kubectl apply -f "$K8S/postgres/"
kubectl apply -f "$K8S/jupyter/"

# ── wait for pods ─────────────────────────────────────────────────────────────
echo "▶ Waiting for postgres pod ..."
kubectl wait --for=condition=ready pod \
  -l app=postgres -n "$NAMESPACE" --timeout=120s

echo "▶ Waiting for jupyter pod ..."
kubectl wait --for=condition=ready pod \
  -l app=jupyter -n "$NAMESPACE" --timeout=180s

# ── seed data ─────────────────────────────────────────────────────────────────
if [[ "$SKIP_DATA" == "false" ]]; then
  echo "▶ Port-forwarding postgres (localhost:5432) ..."
  kubectl port-forward -n "$NAMESPACE" svc/postgres-service 5432:5432 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  sleep 4  # let port-forward settle

  echo "▶ Installing generator dependencies ..."
  pip install psycopg2-binary faker --quiet

  echo "▶ Generating 100k rows (this takes ~2-3 min) ..."
  python "$SCRIPTS/generate_data.py" \
    --host localhost --port 5432 \
    --db coursedb --user courseuser --password coursepass123

  kill $PF_PID 2>/dev/null || true
  trap - EXIT
fi

# ── copy stress test into jupyter pod ─────────────────────────────────────────
echo "▶ Copying stress_test.py into Jupyter pod ..."
JUPYTER_POD=$(kubectl get pod -n "$NAMESPACE" -l app=jupyter \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$JUPYTER_POD" -- mkdir -p /home/jovyan/scripts
kubectl cp "$SCRIPTS/stress_test.py" \
  "$NAMESPACE/$JUPYTER_POD:/home/jovyan/scripts/stress_test.py"

# ── access info ───────────────────────────────────────────────────────────────
NODE_PORT=$(kubectl get svc jupyter-service -n "$NAMESPACE" \
  -o jsonpath='{.spec.ports[0].nodePort}')

echo ""
echo "════════════════════════════════════════════════════════"
echo " EXPERIMENT READY"
echo "════════════════════════════════════════════════════════"
echo ""
echo " Jupyter Lab (NodePort):"
echo "   http://localhost:${NODE_PORT}"
echo ""
echo " Or port-forward:"
echo "   kubectl port-forward -n $NAMESPACE svc/jupyter-service 8888:8888"
echo "   → http://localhost:8888"
echo ""
echo " Run stress test:"
echo "   In Jupyter cell:  %run /home/jovyan/scripts/stress_test.py"
echo "   kubectl exec -n $NAMESPACE $JUPYTER_POD -- \\"
echo "     python /home/jovyan/scripts/stress_test.py"
echo ""
echo " Watch utilization:"
echo "   watch kubectl top pods -n $NAMESPACE"
echo "   watch kubectl top nodes"
echo ""
echo " Tear down:"
echo "   kubectl delete namespace $NAMESPACE"
echo "════════════════════════════════════════════════════════"
