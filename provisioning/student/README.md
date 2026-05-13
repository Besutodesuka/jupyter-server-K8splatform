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
  │     • kubectl apply: Namespace + ResourceQuota + LimitRange
  │       + NetworkPolicies + RBAC + PVC + StatefulSet + Service
  │     • returns result page with auto-redirect
  └─ proxies /student/<id>/* → JupyterLab pod in student-<id> namespace
```

If the student's namespace already exists, provisioning is skipped and the URL is returned immediately (idempotent — safe to re-submit).

---

## Quick Start

**Prerequisites:** `kubectl` configured against your cluster, `local-path` StorageClass available (bundled with k3s).

```bash
# 1. Deploy the portal (run once)
bash provisioning/student/deploy.sh

# 2. Open the printed URL in a browser, e.g.:
#    http://<node-ip>:30080/

# 3. Or port-forward if NodePort isn't reachable:
kubectl port-forward -n jupyter-platform svc/provisioner 8080:80
#    → http://localhost:8080/
```

The portal pod installs `nginx`, `fcgiwrap`, and `kubectl` at startup (~30 s). It is ready when `deploy.sh` exits.

---

## Per-Student Resources

Each namespace `student-<id>` contains:

| Object | Name | Purpose |
|---|---|---|
| Namespace | `student-<id>` | Isolation boundary |
| ResourceQuota | `student-quota` | Hard ceiling: 1 CPU, 2 Gi RAM, 10 Gi storage, 5 pods |
| LimitRange | `student-limits` | Auto-injects limits on pods that don't specify them |
| NetworkPolicy ×3 | `default-deny-ingress`, `allow-same-namespace`, `allow-nginx-ingress` | Blocks cross-namespace traffic; only NGINX can reach port 8888 |
| NetworkPolicy ×2 | `allow-egress-dns`, `allow-egress-postgres` | Allows DNS resolution and access to the shared Postgres DB |
| ServiceAccount | `student-<id>` | Identity for the Jupyter pod |
| Role + RoleBinding | `student-role` | Student can get/exec/port-forward pods in their own namespace only |
| PVC | `jupyter-workspace-<id>` | 10 Gi persistent workspace at `/home/jovyan/work` |
| StatefulSet | `jupyter-<id>` | JupyterLab pod; re-attaches to the same PVC if evicted |
| Service (ClusterIP) | `jupyter-service-<id>` | Internal endpoint that NGINX proxies to |

**Resource limits per student:**

| | requests | limits |
|---|---|---|
| CPU | 250m | 1 core |
| RAM | 512 Mi | 2 Gi |
| Storage | — | 10 Gi (quota) |

---

## Hard Limit Enforcement

Two objects work together to enforce hard limits. They operate at different scopes and are both required.

### ResourceQuota — the namespace-level hard wall

`ResourceQuota` caps the **total consumption of the entire namespace**. Even if a student runs multiple pods, the sum of all their containers cannot exceed these values. The Kubernetes API server rejects any pod that would push the namespace over the ceiling — it never gets scheduled.

```yaml
# applied to every student-<id> namespace
spec:
  hard:
    requests.cpu: "500m"
    limits.cpu: "1"          # hard limit: 1 CPU core total for the namespace
    requests.memory: "512Mi"
    limits.memory: "2Gi"     # hard limit: 2 GB RAM total for the namespace
    requests.storage: "10Gi" # hard limit: 10 GB disk total for the namespace
    pods: "5"                # hard limit: max 5 pods in this namespace
```

This is what solves the original problem: one student's runaway process hitting `2Gi` RAM cannot consume memory belonging to any other student — the quota wall stops it at the kernel scheduler level.

**100-student capacity check:**
- 100 × 1 CPU = 100 cores required (node has 32) — hard limits are mandatory, not advisory
- 100 × 2 Gi = 200 Gi RAM required (node has 128 Gi) — same reasoning

Without quotas, a single uncapped student could exhaust the node and crash all 99 others.

### LimitRange — the per-container safety net

`LimitRange` handles a gap that `ResourceQuota` alone cannot close: a pod spec that **declares no resource limits at all**. Without a `LimitRange`, such a pod would be admitted by the quota (it claims 0 usage) and could consume unbounded CPU and RAM.

`LimitRange` solves this in two ways:

```yaml
spec:
  limits:
    - type: Container
      defaultRequest:          # injected into the pod spec if requests are missing
        cpu: "250m"
        memory: "512Mi"
      default:                 # injected into the pod spec if limits are missing
        cpu: "500m"
        memory: "1Gi"
      max:                     # hard per-container ceiling — rejected if exceeded
        cpu: "1"
        memory: "2Gi"
```

- `default` / `defaultRequest` — auto-inject sensible values so the `ResourceQuota` can account for the pod's usage correctly.
- `max` — a hard per-container ceiling. Even if a student writes a pod spec with `limits.memory: 999Gi`, the admission controller rejects it before it reaches the scheduler.

### How they interact at pod scheduling time

```
Student submits a pod (or Jupyter spawns a kernel)
          │
          ▼
  LimitRange admission webhook
  ┌─────────────────────────────────────────────────────┐
  │ Does the container declare resource limits?         │
  │  No  → inject default (cpu: 500m, memory: 1Gi)     │
  │  Yes → enforce max (reject if > 1 CPU or > 2Gi)    │
  └─────────────────────────────────────────────────────┘
          │
          ▼
  ResourceQuota admission webhook
  ┌─────────────────────────────────────────────────────┐
  │ Would this pod push the namespace total over the    │
  │ hard ceiling (1 CPU / 2Gi / 10Gi storage / 5 pods)?│
  │  Yes → reject (pod never scheduled)                 │
  │  No  → admit                                        │
  └─────────────────────────────────────────────────────┘
          │
          ▼
      Pod runs inside student-<id> namespace
```

### Where to change the limits

All three limit values live in one file:

**[`k8s/06-configmap-cgi.yaml`](k8s/06-configmap-cgi.yaml)**

Edit these three blocks and keep them in sync — they must all match:

**Block 1 — ResourceQuota (lines 87–92):** namespace aggregate ceiling

```yaml
hard:
  requests.cpu: "500m"
  limits.cpu: "1"          # ← change this
  requests.memory: "512Mi"
  limits.memory: "2Gi"     # ← change this
  requests.storage: "10Gi" # ← change this
  pods: "5"
```

**Block 2 — LimitRange (lines 103–111):** per-container defaults and ceiling

```yaml
default:
  cpu: "500m"    # ← match limits.cpu above
  memory: "1Gi"  # ← keep at ~50% of limits.memory
defaultRequest:
  cpu: "250m"    # ← keep at ~50% of default.cpu
  memory: "512Mi"
max:
  cpu: "1"       # ← must equal ResourceQuota limits.cpu
  memory: "2Gi"  # ← must equal ResourceQuota limits.memory
```

**Block 3 — StatefulSet resources (lines 289–293):** the Jupyter pod's own limits

```yaml
resources:
  requests:
    cpu: "250m"    # ← match LimitRange defaultRequest.cpu
    memory: "512Mi"
  limits:
    cpu: "1"       # ← must equal ResourceQuota limits.cpu
    memory: "2Gi"  # ← must equal ResourceQuota limits.memory
```

> **Rule:** `ResourceQuota limits.*` = `LimitRange max.*` = `StatefulSet resources.limits.*`
> If the StatefulSet limit is lower than the quota, the quota is redundant.
> If it is higher, the pod is rejected by the quota at scheduling time.

After editing, re-apply the ConfigMap and restart the provisioner pod to pick up the change:

```bash
kubectl apply -f provisioning/student/k8s/06-configmap-cgi.yaml
kubectl rollout restart deployment/provisioner -n jupyter-platform
```

New limits take effect only for **newly provisioned** students. To update an existing student's namespace:

```bash
# Update the quota in-place
kubectl edit resourcequota student-quota -n student-007

# Restart their Jupyter pod to pick up the new StatefulSet limits
kubectl rollout restart statefulset/jupyter-007 -n student-007
```

---

### Where the limits come from

The values (`1 CPU`, `2 Gi`) are not arbitrary. They are measured using the experiment environment:

1. Run the stress test against a single Jupyter pod with generous limits (`4 CPU`, `4 Gi`)
2. Observe peak usage via `kubectl top pods -n jupyter-experiment`
3. Binary-search the limits down until performance degrades (see [`docs/hard-limit-estimation.md`](../../docs/hard-limit-estimation.md))
4. The floor found becomes the `limits.cpu` / `limits.memory` values here

The StatefulSet inside each student namespace is also capped to the same values so the pod's own limits match the quota ceiling exactly — if they were lower the quota would be redundant; if they were higher the pod would be rejected by the quota at scheduling time.

```yaml
# StatefulSet resources — mirrors the quota ceiling
resources:
  requests: { cpu: "250m", memory: "512Mi" }
  limits:   { cpu: "1",    memory: "2Gi" }   # must equal quota hard.limits.*
```

---

## File Structure

```
provisioning/student/
  deploy.sh                     ← run this first
  k8s/
    00-namespace.yaml           portal namespace (jupyter-platform)
    01-serviceaccount.yaml      provisioner ServiceAccount
    02-clusterrole.yaml         permissions: namespaces, quotas, policies, StatefulSets
    03-clusterrolebinding.yaml  binds ClusterRole to provisioner SA
    04-configmap-nginx.yaml     nginx.conf (dynamic upstream + CGI location)
    05-configmap-html.yaml      index.html — the student form
    06-configmap-cgi.yaml       provision.cgi — bash CGI script
    07-deployment.yaml          alpine pod: nginx + fcgiwrap + kubectl
    08-service.yaml             NodePort 30080
```

---

## Accessing Jupyter

After submitting the form, the portal page auto-redirects when JupyterLab is ready (~2 min on first launch while pip packages install). Subsequent visits are instant.

Direct URL pattern:
```
http://<node-ip>:30080/student/007/lab
```

---

## Admin Operations

```bash
# Watch all student namespaces
watch kubectl get namespaces -l app=jupyter-platform

# Watch all student pods across namespaces
kubectl get pods -A -l app=jupyter-platform

# Check a student's quota usage
kubectl describe resourcequota -n student-007

# Check a student's pod status
kubectl get pods -n student-007

# Check for OOMKill
kubectl describe pod -n student-007 -l student=007 | grep -A5 "Last State"

# Delete one student environment (cascades all objects including PVC)
kubectl delete namespace student-007

# Tear down the entire portal
kubectl delete namespace jupyter-platform
```

---

## Shared Database

Every Jupyter pod has access to the shared PostgreSQL database from the experiment environment:

```
postgresql://courseuser:coursepass123@postgres-service.jupyter-experiment.svc.cluster.local:5432/coursedb
```

Available as the `DATABASE_URL` environment variable inside each Jupyter pod. The database must be running in the `jupyter-experiment` namespace — see [`provisioning/experiment/run.sh`](../experiment/run.sh).

---

## Dependency: Experiment Environment

The shared Postgres dataset must be deployed before students can run DB queries:

```bash
bash provisioning/experiment/run.sh
```

The portal itself works without this (students can still use Jupyter for Python/NumPy work), but `DATABASE_URL` connections will fail until Postgres is up.
