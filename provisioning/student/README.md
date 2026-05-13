# Student Provisioning Portal

Self-service system that lets students request their own isolated JupyterLab environment through a browser form. Each student gets a dedicated Kubernetes namespace with hard resource limits, persistent storage, and network isolation — provisioned on demand in under 30 seconds.

---

## How It Works

```
Browser → http://<node>:30080/
           │  student types ID → POST /cgi-bin/provision.cgi
           ▼
  NGINX pod (jupyter-platform)
  ├─ serves the HTML form
  ├─ runs provision.cgi via fcgiwrap
  │     • validates student ID (1–100)
  │     • helm upgrade --install student-<id> /helm/student-chart
  │         → Namespace, ResourceQuota, LimitRange
  │         → 5 NetworkPolicies, RBAC, PVC, StatefulSet, Service
  │     • returns result page with JS auto-redirect
  └─ proxies /student/<id>/* → JupyterLab pod in student-<id> namespace
```

If the student already has a Helm release, provisioning is skipped and the URL is returned immediately (idempotent — safe to re-submit).

---

## Quick Start (minikube)

```bash
# 1. Start minikube (if not already running)
minikube start

# 2. Deploy the portal (run once)
bash provisioning/student/deploy.sh

# 3. Port-forward the portal
kubectl port-forward -n jupyter-platform svc/provisioner 8080:80
#    → http://localhost:8080/
```

The portal pod installs `nginx`, `fcgiwrap`, `kubectl`, and `helm` at startup (~60 s). It is ready when `deploy.sh` exits.

> **StorageClass:** `07-deployment.yaml` sets `STORAGE_CLASS=standard` for minikube.
> Change to `local-path` for k3s (the default on the production server).

---

## Why Helm

Without Helm, the CGI script provisioned each student by generating ~300 lines of YAML inline and piping it to `kubectl apply`. That approach has three critical gaps:

| Problem | Without Helm | With Helm |
|---|---|---|
| **Upgrading Jupyter image** | Edit CGI ConfigMap, re-provision 100 students manually | `helm upgrade` with `--set image=...` — one command per student or looped |
| **Rolling back a broken change** | No history — restore from git, re-apply, hope nothing breaks | `helm rollback student-007` — instant revert to the last working revision |
| **Knowing what's deployed** | `kubectl get ns` gives namespaces only | `helm list -A` shows every student's release name, chart version, and status |
| **Changing limits for future students** | Edit embedded YAML heredoc inside a shell script | Edit `chart/values.yaml` — clean, version-controlled, templated |

Helm wraps all the per-student Kubernetes objects into a single *release*. Every `helm upgrade --install` is atomic: it either succeeds fully or the old state is left intact.

---

## Helm Chart Structure

```
provisioning/student/chart/
  Chart.yaml          chart name and version
  values.yaml         defaults: image, CPU/RAM limits, storage size, StorageClass
  templates/
    resourcequota.yaml
    limitrange.yaml
    networkpolicies.yaml   all 5 network policies in one file
    serviceaccount.yaml
    rbac.yaml              Role + RoleBinding
    pvc.yaml
    statefulset.yaml
    service.yaml
```

`values.yaml` is the **single source of truth** for all resource numbers. Every template references `{{ .Values.* }}` — no hardcoded values inside templates.

The chart files are packaged into two ConfigMaps (`09` and `10`) so the provisioner pod can access them at runtime without a persistent volume. When you edit `chart/`, re-sync and restart to pick up the changes:

```bash
kubectl apply -f provisioning/student/k8s/09-configmap-chart-meta.yaml
kubectl apply -f provisioning/student/k8s/10-configmap-chart-templates.yaml
kubectl rollout restart deployment/provisioner -n jupyter-platform
```

---

## Using Helm to Manage Students

### View all provisioned environments

```bash
# List every student release with status and chart revision
helm list -A

# Filter to student releases only
helm list -A --filter '^student-'
```

### Inspect a single student

```bash
# See what values were used when this student was provisioned
helm get values student-007 -n student-007

# See the full rendered manifest Helm applied
helm get manifest student-007 -n student-007

# See revision history
helm history student-007 -n student-007
```

### Upgrade a single student

```bash
# Give one student more RAM for a heavy assignment
helm upgrade student-007 /helm/student-chart \
  --reuse-values \
  --set resources.limits.memory=4Gi \
  -n student-007

# Change the Jupyter image for one student
helm upgrade student-007 /helm/student-chart \
  --reuse-values \
  --set image=quay.io/jupyter/scipy-notebook:2024-10-07 \
  -n student-007
```

### Roll back a broken student environment

```bash
# Roll back to the previous working revision
helm rollback student-007 -n student-007

# Roll back to a specific revision number
helm history student-007 -n student-007   # find the revision number first
helm rollback student-007 2 -n student-007
```

### Bulk upgrade all students

```bash
# Roll a new Jupyter image to every provisioned student
for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep '^student-'); do
  ID=${ns#student-}
  helm upgrade "student-${ID}" /helm/student-chart \
    --reuse-values \
    --set image=quay.io/jupyter/scipy-notebook:2024-10-07 \
    -n "$ns"
done
```

### Delete a student environment

```bash
# Remove the Helm release (deletes all objects except the namespace itself)
helm uninstall student-007 -n student-007

# Also delete the namespace and PVC
kubectl delete namespace student-007
```

---

## Changing Resource Limits

All limit values live in one file: **[`chart/values.yaml`](chart/values.yaml)**

```yaml
resources:
  limits:
    cpu: "1"        # ← per-pod CPU hard limit
    memory: "2Gi"   # ← per-pod RAM hard limit
  requests:
    cpu: "250m"
    memory: "512Mi"

quota:
  limitsCpu: "1"        # ← namespace aggregate ceiling (must equal resources.limits.cpu)
  limitsMemory: "2Gi"   # ← namespace aggregate ceiling (must equal resources.limits.memory)
  requestsCpu: "500m"
  requestsMemory: "512Mi"
  storage: "10Gi"
  pods: "5"
```

> **Rule:** `quota.limitsCpu` must equal `resources.limits.cpu`, and same for memory.
> If the pod limit is lower than the quota, the quota is redundant.
> If it is higher, the pod will be rejected by the quota at scheduling time.

After editing, sync the ConfigMap and restart the provisioner:

```bash
kubectl apply -f provisioning/student/k8s/09-configmap-chart-meta.yaml
kubectl rollout restart deployment/provisioner -n jupyter-platform
```

New limits apply to **newly provisioned** students. To push the new values to an existing student:

```bash
helm upgrade student-007 /helm/student-chart --set studentId=007 -n student-007
```

Or bulk-upgrade all at once (see [Bulk upgrade](#bulk-upgrade-all-students) above).

---

## Hard Limit Enforcement

Two objects work together inside every student namespace.

### ResourceQuota — namespace-level hard wall

Caps the **total** CPU, RAM, and storage the entire namespace can claim. The API server rejects any pod that would push the namespace over the ceiling — it never gets scheduled.

```yaml
spec:
  hard:
    requests.cpu: "500m"
    limits.cpu: "1"          # 1 CPU core total for the namespace
    requests.memory: "512Mi"
    limits.memory: "2Gi"     # 2 GB RAM total for the namespace
    requests.storage: "10Gi" # 10 GB disk total for the namespace
    pods: "5"                # max 5 pods in this namespace
```

This is what solves the original problem: one student's runaway process hitting `2Gi` RAM cannot consume memory belonging to any other student — the quota wall stops it at the API level.

**100-student capacity check:**
- 100 × 1 CPU = 100 cores required (node has 32) — hard limits are mandatory, not advisory
- 100 × 2 Gi = 200 Gi RAM required (node has 128 Gi) — same reasoning

### LimitRange — per-container safety net

Handles the gap that `ResourceQuota` alone cannot close: a pod spec that **declares no resource limits**. Without a `LimitRange`, such a pod would be admitted by the quota (it claims 0 usage) and could consume unbounded CPU and RAM.

```yaml
spec:
  limits:
    - type: Container
      defaultRequest: { cpu: "250m", memory: "512Mi" }  # injected if requests missing
      default:        { cpu: "500m", memory: "1Gi"   }  # injected if limits missing
      max:            { cpu: "1",    memory: "2Gi"   }  # hard ceiling — rejected if exceeded
```

### How they interact

```
Student submits a pod (or Jupyter spawns a kernel)
          │
          ▼
  LimitRange admission
  ├─ No limits declared? → inject default (cpu: 500m, memory: 1Gi)
  └─ Limits declared?    → reject if > max (1 CPU / 2 Gi)
          │
          ▼
  ResourceQuota admission
  ├─ Would this push namespace total over the ceiling? → reject
  └─ Under ceiling? → admit
          │
          ▼
      Pod scheduled inside student-<id>
```

---

## Per-Student Kubernetes Objects

Each namespace `student-<id>` contains:

| Object | Name | Purpose |
|---|---|---|
| ResourceQuota | `student-quota` | Hard ceiling: 1 CPU, 2 Gi RAM, 10 Gi storage, 5 pods |
| LimitRange | `student-limits` | Auto-injects limits on pods that don't specify them |
| NetworkPolicy ×3 | `default-deny-ingress`, `allow-same-namespace`, `allow-nginx-ingress` | Blocks cross-namespace traffic; only NGINX can reach port 8888 |
| NetworkPolicy ×2 | `allow-egress-dns`, `allow-egress-postgres` | Allows DNS resolution and access to the shared Postgres DB |
| ServiceAccount | `student-<id>` | Identity for the Jupyter pod |
| Role + RoleBinding | `student-role` | Student can get/exec/port-forward pods in their own namespace only |
| PVC | `jupyter-workspace-<id>` | 10 Gi persistent workspace at `/home/jovyan/work` |
| StatefulSet | `jupyter-<id>` | JupyterLab pod; re-attaches to the same PVC if evicted |
| Service (ClusterIP) | `jupyter-service-<id>` | Internal endpoint that NGINX proxies to |

---

## File Structure

```
provisioning/student/
  deploy.sh                          ← run this first
  chart/                             ← Helm chart (canonical source for per-student objects)
    Chart.yaml
    values.yaml                      ← image, resource limits, storage — edit here
    templates/
      resourcequota.yaml
      limitrange.yaml
      networkpolicies.yaml
      serviceaccount.yaml
      rbac.yaml
      pvc.yaml
      statefulset.yaml
      service.yaml
  k8s/
    00-namespace.yaml                portal namespace (jupyter-platform)
    01-serviceaccount.yaml           provisioner ServiceAccount
    02-clusterrole.yaml              permissions: namespaces, quotas, policies, StatefulSets
    03-clusterrolebinding.yaml       binds ClusterRole to provisioner SA
    04-configmap-nginx.yaml          nginx.conf (dynamic upstream + CGI location)
    05-configmap-html.yaml           index.html — the student form
    06-configmap-cgi.yaml            provision.cgi — calls helm upgrade --install
    07-deployment.yaml               alpine pod: nginx + fcgiwrap + kubectl + helm
    08-service.yaml                  NodePort 30080
    09-configmap-chart-meta.yaml     Chart.yaml + values.yaml packaged as ConfigMap
    10-configmap-chart-templates.yaml all chart templates packaged as ConfigMap
```

`chart/` is the source of truth. ConfigMaps `09` and `10` mirror its contents so the provisioner pod can run Helm without a persistent volume. When you edit `chart/`, re-apply both ConfigMaps and restart the provisioner to pick up the change.

---

## Accessing Jupyter

After submitting the form, the portal page polls JupyterLab's API endpoint and auto-redirects when it is ready (~2 min on first launch while pip packages install). Subsequent visits are instant.

```
http://localhost:8080/student/007/lab
```

---

## kubectl Admin Commands

```bash
# Watch all student pods across namespaces
kubectl get pods -A | grep ^student-

# Check a student's quota usage
kubectl describe resourcequota student-quota -n student-007

# Check for OOMKill
kubectl describe pod -n student-007 -l student=007 | grep -A5 "Last State"

# Tear down the entire portal
kubectl delete namespace jupyter-platform
```

---

## Shared Database

Every Jupyter pod can connect to the shared PostgreSQL database from the experiment environment:

```
postgresql://courseuser:coursepass123@postgres-service.jupyter-experiment.svc.cluster.local:5432/coursedb
```

Available as the `DATABASE_URL` environment variable inside each Jupyter pod. The database must be running in the `jupyter-experiment` namespace — see [`provisioning/experiment/run.sh`](../experiment/run.sh).

```bash
bash provisioning/experiment/run.sh
```
