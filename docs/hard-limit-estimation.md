# Hard Limit Estimation — K8s CPU & RAM

## Goal

Find the minimum CPU and RAM that each pod can run under without degrading under load.
This gives the `requests` floor and informs `limits` for production sizing.

---

## Pod Inventory

| Pod | Image | Role |
|---|---|---|
| `postgres` | `postgres:15` | Coursework DB, ~100k rows |
| `jupyter` | `quay.io/jupyter/scipy-notebook:2024-05-27` | Python 3.10 + pandas/numpy/matplotlib |

Namespace: `jupyter-experiment`

---

## Current Resource Config

```yaml
# postgres
requests: { cpu: 250m,  memory: 512Mi }
limits:   { cpu: 2000m, memory: 2Gi   }

# jupyter
requests: { cpu: 500m,  memory: 1Gi   }
limits:   { cpu: 4000m, memory: 4Gi   }
```

Manifests: `provisioning/experiment/k8s/postgres/04-deployment.yaml`
           `provisioning/experiment/k8s/jupyter/01-deployment.yaml`

---

## Stress Test

**Script:** `provisioning/experiment/scripts/stress_test.py`

**Run:**
```bash
# Option A — inside Jupyter Lab cell
%run /home/jovyan/scripts/stress_test.py

# Option B — kubectl exec
kubectl exec -n jupyter-experiment deploy/jupyter -- \
  python /home/jovyan/scripts/stress_test.py
```

### Workload Scenarios

| # | Scenario | What stresses |
|---|---|---|
| 1 | DB aggregate: avg score by dept (4-table join) | Postgres CPU, buffer pool |
| 2 | DB course stats (5-table join + GROUP BY) | Postgres CPU, sort memory |
| 3 | DB top-students CTE (window + subquery) | Postgres CPU |
| 4 | DB assignment difficulty (STDDEV, HAVING) | Postgres CPU |
| 5 | DB rolling avg (window function, 50k rows) | Postgres RAM (work_mem) |
| 6 | pandas load 100k rows via JDBC | Jupyter RAM |
| 7 | pandas feature engineering + resample | Jupyter CPU |
| 8 | pandas groupby + pivot + corr matrix | Jupyter CPU + RAM |
| 9 | NumPy matmul 1000×1000 | Jupyter CPU (BLAS) |
| 10 | NumPy FFT 100k points | Jupyter CPU |
| 11 | NumPy SVD 500×200 | Jupyter CPU |
| 12 | NumPy eigen 500×500 | Jupyter CPU |
| 13 | NumPy bootstrap CI (2k iterations) | Jupyter CPU |
| 14 | matplotlib 6-panel plot (render to PNG) | Jupyter CPU + RAM |

**Outputs:**
- `/tmp/stress_results.json` — per-scenario elapsed time + RSS delta
- `/tmp/stress_plot.png` — 6-panel visualization of the dataset

---

## Measurement Methods

### Process-level (inside pod)
`psutil` captures RSS before/after each scenario.
Reports: `elapsed_s`, `mem_start_mb`, `mem_end_mb`, `mem_delta_mb`.

Limitation: measures process RSS only, not cgroup throttling.

### Cluster-level (from host)
```bash
# real-time pod utilization
watch kubectl top pods -n jupyter-experiment

# node utilization
watch kubectl top nodes

# check if pod was OOMKilled
kubectl describe pod -n jupyter-experiment <pod-name> | grep -A5 "Last State"

# check CPU throttling (requires metrics-server)
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/jupyter-experiment/pods
```

Requires `metrics-server` deployed on the cluster.

---

## Binary Search Protocol

Use this procedure to find the minimum viable limit for each pod independently.

### Step 1 — Establish baseline

Run stress test with current (generous) limits. Record:
- Peak CPU (millicores) from `kubectl top pods`
- Peak RAM (MiB) from `kubectl top pods`
- `elapsed_s` per scenario from `/tmp/stress_results.json`

### Step 2 — Halve the limit under test

Edit the deployment YAML, apply, wait for rollout, re-run stress test.

```bash
# example: cut jupyter RAM limit to 2Gi
kubectl set resources deployment jupyter \
  -n jupyter-experiment \
  --limits=memory=2Gi

# or edit YAML then:
kubectl apply -f provisioning/experiment/k8s/jupyter/01-deployment.yaml
kubectl rollout status deployment/jupyter -n jupyter-experiment
```

### Step 3 — Evaluate

| Signal | Meaning |
|---|---|
| Pod runs, `kubectl top` shows headroom | Limit is not the bottleneck — cut further |
| Scenarios slow down >2× | Approaching CPU throttle point |
| Pod restarts with `OOMKilled` | RAM limit too low — raise by 25% |
| `CrashLoopBackOff` | Check `kubectl logs` — may be OOM or startup failure |

### Step 4 — Repeat until

CPU: scenario times start increasing significantly (>50% slower) → previous value is the soft floor.
RAM: last limit that did NOT OOMKill → that is the hard floor.

---

## Decision Matrix

```
                  ┌───────────────────────────────────┐
                  │      RAM limit too low?            │
                  │      → OOMKilled in describe pod   │
                  └────────────┬──────────────────────┘
                               │ YES          NO
                               ▼              ▼
                        Raise +25%     Is CPU throttled?
                                       (top shows ~limit,
                                        times increase)
                                            │ YES    NO
                                            ▼        ▼
                                     Raise +10%   Cut in half
                                                  and repeat
```

---

## Expected Baseline Numbers (to fill in after first run)

Run the stress test once with generous limits, then fill this table.

| Metric | postgres | jupyter |
|---|---|---|
| Idle CPU | ___ m | ___ m |
| Peak CPU (stress test) | ___ m | ___ m |
| Idle RAM | ___ Mi | ___ Mi |
| Peak RAM (stress test) | ___ Mi | ___ Mi |
| OOMKill threshold (RAM) | TBD | TBD |
| CPU throttle threshold | TBD | TBD |
| Recommended `requests.cpu` | TBD | TBD |
| Recommended `requests.memory` | TBD | TBD |
| Recommended `limits.cpu` | TBD | TBD |
| Recommended `limits.memory` | TBD | TBD |

---

## Tear Down

```bash
kubectl delete namespace jupyter-experiment
```

Deletes all pods, services, PVC, and secrets.
