# Monitoring — Prometheus + Grafana for Multi-Tenant Jupyter Platform

Covers: metrics collected, deployment, and how to test each project requirement.

---

## Architecture

```
Every Node
  └── node-exporter (DaemonSet, hostNetwork, port 9100)
        │  hardware: CPU, RAM, disk, network (node health only)
        ▼
  Prometheus (monitoring namespace)
  ├── scrapes node-exporter via kubernetes node SD → node:9100
  ├── scrapes kube-state-metrics → quota/pod/namespace state
  ├── scrapes cAdvisor via K8s API proxy → per-container CPU/RAM (all namespaces)
  ├── evaluates recording rules every 30s  (namespace:quota_*_used_ratio)
  └── fires alerts                          (quota near-limit, OOMKill, orphans)
        │
        ▼
  Grafana (monitoring namespace)
  ├── "Multi-Tenant Overview"   — all students at a glance (home dashboard)
  └── "Student Drill-Down"      — single student deep-dive ($namespace variable)
```

No changes are required to student namespaces. node-exporter uses `hostNetwork` and cAdvisor is proxied through the Kubernetes API server — neither is blocked by student-namespace NetworkPolicies.

### Single-node design note

All student pods run on one node. Monitoring granularity comes from **three layers**:

| Layer | Source | Granularity |
|---|---|---|
| Node health | node-exporter | Whole machine — "is the node dying?" |
| Per-student usage | cAdvisor (via API proxy) | Per container/namespace — "who is using what?" |
| Quota state | kube-state-metrics | Per namespace — "who is near/at their limit?" |

node-exporter does not attach to pods. It is a per-node DaemonSet. On a single-node cluster exactly one node-exporter pod runs and covers the whole machine. cAdvisor (served by kubelet) is scraped through the Kubernetes API server (`kubernetes.default.svc:443/api/v1/nodes/<node>/proxy/metrics/cadvisor`) and automatically reports metrics for every container on that node, labeled by `namespace`, `pod`, and `container` — giving per-student visibility with zero per-namespace configuration.

---

## Component Versions

| Component | Image |
|---|---|
| node-exporter | `prom/node-exporter:v1.8.1` |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.12.0` |
| Prometheus | `prom/prometheus:v2.52.0` |
| Grafana | `grafana/grafana:10.4.3` |

---

## Metrics Collected

### Node-level — from node-exporter DaemonSet

| Metric | Purpose |
|---|---|
| `node_cpu_seconds_total{mode="idle"}` | Node CPU utilization. `1 - rate(idle[5m])` = CPU used % |
| `node_memory_MemAvailable_bytes` | Available RAM on the node |
| `node_memory_MemTotal_bytes` | Total node RAM; ratio = memory pressure |
| `node_filesystem_avail_bytes` | Disk space available per mount |
| `node_filesystem_size_bytes` | Disk capacity per mount |
| `node_network_receive_bytes_total` | Inbound traffic per interface |
| `node_network_transmit_bytes_total` | Outbound traffic per interface |
| `node_load1` / `node_load5` / `node_load15` | System load averages |

**Maps to requirement**: *Administrative Oversight* (node health), *Isolation Validation* (node pressure confirms limits prevented bleed-through).

### Namespace/Object-level — from kube-state-metrics

kube-state-metrics is configured with `--resources=namespaces,pods,resourcequotas,limitranges,persistentvolumeclaims,statefulsets,deployments,daemonsets` — only the object types relevant to this platform are collected.

| Metric | Purpose |
|---|---|
| `kube_resourcequota{type="hard"}` | Hard ceiling for each namespace (CPU, RAM, storage, pods) |
| `kube_resourcequota{type="used"}` | Currently consumed quota |
| `kube_limitrange` | LimitRange defaults + max per container |
| `kube_pod_status_phase` | Pod phase: Running/Pending/Failed |
| `kube_pod_status_ready` | Whether pod is ready (1=up, 0=down) |
| `kube_pod_container_status_restarts_total` | Restart count per container |
| `kube_pod_container_status_last_terminated_reason` | `OOMKilled` when memory limit hit |
| `kube_namespace_created` | Namespace age — used to detect orphans |
| `kube_namespace_labels` | Namespace label set |
| `kube_pod_container_resource_requests` | Per-container resource requests (used in drill-down) |
| `kube_pod_container_resource_limits` | Per-container resource limits (used in drill-down) |

**Maps to requirements**: *Strict Multi-Tenancy* (quota hard values), *Isolation Validation* (quota exhaustion = API blocks pods, OOMKill = kernel enforced cgroup), *Lifecycle Management* (orphan detection via namespace age + no running pods).

### Container-level — from cAdvisor (via K8s API proxy)

| Metric | Purpose |
|---|---|
| `container_cpu_usage_seconds_total` | Actual CPU consumed per container |
| `container_memory_working_set_bytes` | Actual RAM in use (excludes reclaimable cache) |
| `container_memory_rss` | Resident set size — what OOM killer sees |
| `container_fs_reads_bytes_total` | Container disk read I/O |
| `container_fs_writes_bytes_total` | Container disk write I/O |

**Maps to requirements**: *Administrative Oversight* (identify high-usage workloads), *Isolation Validation* (actual usage vs limit shows quota is effective).

### Pre-computed recording rules

These recording rules fire every 30 s and are used by both alerts and Grafana panels. The expressions use a defensive `or ... * 0` pattern so namespaces with zero usage still appear in queries rather than being absent:

| Rule | Expression |
|---|---|
| `namespace:quota_cpu_used_ratio` | `(kube_resourcequota{resource="limits.cpu",type="used"} or kube_resourcequota{resource="limits.cpu",type="hard"}*0) / kube_resourcequota{resource="limits.cpu",type="hard"}` |
| `namespace:quota_memory_used_ratio` | same pattern for `limits.memory` |
| `namespace:quota_storage_used_ratio` | same pattern for `requests.storage` |
| `namespace:quota_pods_used_ratio` | same pattern for `pods` |

---

## Prometheus Configuration

| Setting | Value |
|---|---|
| `scrape_interval` | 15s |
| `evaluation_interval` | 15s |
| `external_labels.cluster` | `jupyter-k8s-platform` |
| TSDB retention | 15 days |
| PVC size | 10 Gi |
| Hot-reload | `--web.enable-lifecycle` |

---

## Deployment

### Prerequisites

- `kubectl` pointing at target cluster
- `monitoring` namespace does not exist yet

### StorageClass

| Cluster | StorageClass |
|---|---|
| minikube | `standard` (default) |
| k3s | `local-path` |

```bash
# minikube (default)
bash monitoring/deploy.sh

# k3s
STORAGE_CLASS=local-path bash monitoring/deploy.sh
```

`deploy.sh` applies all manifests in order, waits for rollouts, then prints the node IP and NodePort URLs. Takes ~2 min on first run (image pull).

### Verify everything is up

```bash
kubectl get pods -n monitoring
# Expected:
#   grafana-...             1/1  Running
#   kube-state-metrics-...  1/1  Running
#   node-exporter-...       1/1  Running   ← one per node
#   prometheus-...          1/1  Running
```

### Access

```bash
# NodePort (if accessible)
#   Prometheus : http://<node-ip>:30090
#   Grafana    : http://<node-ip>:30030  (admin / admin)

# Port-forward (always works)
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
kubectl port-forward -n monitoring svc/grafana    3000:3000 &
```

Grafana opens on the Multi-Tenant Overview dashboard by default (`GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH`). Anonymous access is disabled.

---

## Tear down

```bash
kubectl delete namespace monitoring
```

---

## Testing Each Requirement

### 1. Strict Multi-Tenancy — Quota hard limits enforced

**What to verify:** namespace quota blocks pods that would exceed the ceiling.

```bash
# Provision two students
curl -s -X POST http://localhost:8080/cgi-bin/provision.cgi -d "student_id=10"
curl -s -X POST http://localhost:8080/cgi-bin/provision.cgi -d "student_id=11"

# Check quota objects exist with correct hard values
kubectl describe resourcequota student-quota -n student-10
kubectl describe resourcequota student-quota -n student-11
```

**Trigger the limit** by attempting to create a pod that exceeds the quota:

```bash
# student-10 has quota: pods=5, limits.cpu=1, limits.memory=2Gi
# Try to create a 6th pod — should be rejected
kubectl run overload --image=nginx --limits='cpu=100m,memory=100Mi' -n student-10
kubectl run overload2 --image=nginx --limits='cpu=100m,memory=100Mi' -n student-10
kubectl run overload3 --image=nginx --limits='cpu=100m,memory=100Mi' -n student-10
kubectl run overload4 --image=nginx --limits='cpu=100m,memory=100Mi' -n student-10
# The above may fail quota.pods before CPU/memory limit

# Or exhaust CPU: student already has 1 CPU limit, try to add more
kubectl run cpu-hog --image=nginx --limits='cpu=500m,memory=100Mi' -n student-10
# Expected: Error: exceeded quota: student-quota, requested: limits.cpu=500m, used: limits.cpu=1, limited: limits.cpu=1
```

**Observe in Prometheus:**
```promql
# Current quota usage per namespace
kube_resourcequota{namespace=~"student-.*", type="used"}

# Ratio — anything >= 1.0 means hard limit hit
namespace:quota_cpu_used_ratio{namespace="student-10"}
```

**Observe in Grafana:** Open "CPU Quota Usage % per Student" timeseries. student-10 line turns red at >80%, reaches 100%.

---

### 2. Automated Provisioning — Verify sandboxes get quota + storage + network

```bash
# After provisioning student-42:
kubectl get resourcequota  -n student-42
kubectl get limitrange     -n student-42
kubectl get networkpolicy  -n student-42
kubectl get pvc            -n student-42
kubectl get statefulset    -n student-42

# Should show: student-quota, student-limits, 5 policies, 1 PVC, 1 StatefulSet
```

**Observe in Grafana:** New namespace appears in all quota charts within 30 s of provisioning.

---

### 3. Isolation Validation — Quota breach in one namespace does not impact neighbors

**Goal:** Hammer student-10, confirm student-11 is unaffected.

```bash
# Step 1: stress student-10's Jupyter pod
kubectl exec -n student-10 \
  $(kubectl get pod -n student-10 -l student=10 -o name) -- \
  python3 -c "
import numpy as np
while True:
    np.linalg.svd(np.random.rand(2000, 2000))
" &

# Step 2: watch resource usage on both
watch -n2 "kubectl top pods -n student-10; echo '---'; kubectl top pods -n student-11"

# Step 3: confirm student-10 hits its limit (CPU throttled or OOMKilled)
kubectl describe pod -n student-10 -l student=10 | grep -A5 "Last State"

# Step 4: confirm student-11 pod is still responsive
kubectl exec -n student-11 \
  $(kubectl get pod -n student-11 -l student=11 -o name) -- \
  python3 -c "import time; print('alive', time.time())"
```

**Observe in Prometheus:**
```promql
# Confirm student-10 CPU is capped at its limit
rate(container_cpu_usage_seconds_total{namespace="student-10", container!=""}[1m])

# Confirm student-11 CPU is unaffected (still near idle)
rate(container_cpu_usage_seconds_total{namespace="student-11", container!=""}[1m])

# Check alert fired for student-10
ALERTS{alertname="TenantCpuQuotaNearLimit", namespace="student-10"}
```

**Observe in Grafana:** In the overview, student-10 CPU timeseries turns red; student-11 remains green. "Quota Hard Limits Hit" stat counter increments. In the drill-down (select `student-10`), the "CPU Over Time" panel shows actual usage hitting the limit line.

**Observe OOMKill isolation:**
```bash
# Force OOM in student-10
kubectl exec -n student-10 \
  $(kubectl get pod -n student-10 -l student=10 -o name) -- \
  python3 -c "x = ' ' * (3 * 1024 ** 3)"  # 3 GB > 2 Gi limit

# Pod restarts; student-11 unaffected
kubectl get pod -n student-10 -l student=10
kubectl get pod -n student-11 -l student=11
```

```promql
# OOMKill confirmed
kube_pod_container_status_last_terminated_reason{reason="OOMKilled", namespace="student-10"}
```

---

### 4. Administrative Oversight — Centralized dashboards

#### Multi-Tenant Overview (admin view)

Open Grafana → "Jupyter Platform — Multi-Tenant Overview" (loads as home dashboard).

| Panel | Type | What it shows |
|---|---|---|
| Active Students | stat | Count of namespaces with at least one Running pod |
| Node CPU % | stat | Whole-machine CPU utilization |
| Node RAM % | stat | Whole-machine memory utilization |
| Quota Hard Limits Hit | stat | Namespaces currently at ceiling (API blocks new pods) |
| OOMKilled (last 1h) | stat | Containers killed by kernel memory enforcement |
| Orphaned Namespaces | stat | Provisioned but idle >1h — candidates for cleanup |
| CPU Quota Usage % per Student | timeseries | Quota ratio per namespace over time |
| Memory Quota Usage % per Student | timeseries | Memory quota ratio per namespace over time |
| Namespace Health — Pod Ready per Student | timeseries | 1 = pod ready, 0 = pod down per namespace |
| Actual CPU per Student (millicores) | timeseries | cAdvisor real CPU per namespace |
| Actual Memory per Student (MiB) | timeseries | cAdvisor real RAM per namespace |
| Top 10 CPU Consumers (millicores) | table | Noisy neighbor ranking — namespace + pod by CPU |
| Top 10 Memory Consumers (MiB) | table | Noisy neighbor ranking — namespace + pod by memory |
| Storage Quota Usage % per Student | bargauge | Disk consumption per tenant |

#### Student Drill-Down (per-student view)

Open Grafana → "Jupyter Platform — Student Drill-Down". Select a namespace from the **Student Namespace** dropdown.

| Panel | Type | What it shows |
|---|---|---|
| CPU Actual (millicores) | stat | Current snapshot of real CPU usage |
| Memory Actual (MiB) | stat | Current snapshot of real memory usage |
| CPU Quota % | gauge | How close to hard CPU limit |
| Memory Quota % | gauge | How close to hard memory limit |
| CPU Over Time — actual vs request vs limit | timeseries | Trend + headroom before throttle |
| Memory Over Time — actual vs request vs limit | timeseries | Trend + headroom before OOMKill |
| Pod Restarts | stat | Crash loop indicator |
| OOMKilled | stat | Whether memory limit was ever hit |
| Storage Quota % | gauge | Disk usage for this student |

**CLI alternative:**
```bash
# Quota usage for all student namespaces at a glance
kubectl get resourcequota -A | grep student-

# High-usage pods across all namespaces (requires metrics-server)
kubectl top pods -A --sort-by=cpu | head -20
kubectl top pods -A --sort-by=memory | head -20
```

---

### 5. Lifecycle Management — Orphaned namespace detection and cleanup

**Detect orphans via Prometheus:**
```promql
# Namespaces older than 1h with no running pods
(
  kube_namespace_labels{namespace=~"student-.*"}
  unless on(namespace)
  kube_pod_status_phase{phase="Running", namespace=~"student-.*"}
) * on(namespace) group_left() (
  (time() - kube_namespace_created{namespace=~"student-.*"}) > 3600
)
```

**Detect orphans via kubectl:**
```bash
# List all student namespaces
kubectl get ns | grep student-

# For each namespace, check if any running pods exist
for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep '^student-'); do
  count=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  age=$(kubectl get ns "$ns" -o jsonpath='{.metadata.creationTimestamp}')
  echo "$ns  running=$count  created=$age"
done
```

**Cleanup orphaned environments:**
```bash
# Remove a specific student's environment
helm uninstall student-007 -n student-007
kubectl delete namespace student-007

# Bulk cleanup: remove all namespaces with no running pods
for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep '^student-'); do
  running=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$running" == "0" ]]; then
    release="student-${ns#student-}"
    echo "Removing orphan: $ns"
    helm uninstall "$release" -n "$ns" 2>/dev/null || true
    kubectl delete namespace "$ns"
  fi
done
```

**Observe in Grafana:** "Orphaned Namespaces" stat panel increments. Alert `OrphanedStudentNamespace` fires in Prometheus after 1 h idle.

---

## Alerting Rules Summary

| Alert | Condition | Severity | Maps to requirement |
|---|---|---|---|
| `TenantCpuQuotaNearLimit` | Namespace CPU quota >80% for 5m | warning | Administrative Oversight |
| `TenantMemoryQuotaNearLimit` | Namespace memory quota >80% for 5m | warning | Administrative Oversight |
| `TenantQuotaHardLimitReached` | CPU or memory quota ratio ≥ 1.0 for 1m | critical | Isolation Validation |
| `ContainerOOMKilled` | Container has restarts and last termination reason is OOMKilled | warning | Isolation Validation |
| `OrphanedStudentNamespace` | No running pods, namespace age >1h | info | Lifecycle Management |
| `NodeMemoryPressure` | Node memory utilization >90% for 5m | critical | Administrative Oversight |

View firing alerts: `http://localhost:9090/alerts`

---

## Resource Allocations

| Component | CPU request | CPU limit | Memory request | Memory limit |
|---|---|---|---|---|
| node-exporter | 50m | 250m | 64Mi | 128Mi |
| kube-state-metrics | 50m | 250m | 64Mi | 256Mi |
| prometheus | 200m | 1000m | 512Mi | 1Gi |
| grafana | 100m | 500m | 256Mi | 512Mi |

---

## File Reference

```
monitoring/
  00-namespace.yaml             monitoring namespace (label: kubernetes.io/metadata.name=monitoring)
  01-rbac.yaml                  ServiceAccounts + ClusterRoles for Prometheus and kube-state-metrics
  02-node-exporter-daemonset.yaml   DaemonSet (hostNetwork + hostPID) + headless Service (port 9100)
  03-kube-state-metrics.yaml    Deployment + Service (ports 8080/8081); filtered --resources list
  04-prometheus-config.yaml     ConfigMap: prometheus.yml + recording rules + alerting rules
  05-prometheus-deployment.yaml PVC (10Gi) + Deployment (15d retention) + NodePort Service (30090)
  06-grafana-config.yaml        ConfigMaps: datasource + dashboard provider + two dashboard JSONs
                                  (multi-tenant-overview.json + student-drilldown.json)
  07-grafana-deployment.yaml    PVC (2Gi) + Deployment + NodePort Service (30030)
  deploy.sh                     One-shot deploy script; accepts STORAGE_CLASS env var
```
