# Student Provisioning Portal

Each student types their ID into a browser form and gets their own isolated JupyterLab environment — dedicated namespace, hard resource limits, persistent storage, and network isolation.

---

## Deploy

```bash
# Start minikube (skip if already running)
minikube start

# Deploy the portal (minikube auto-detected)
bash provisioning/student/deploy.sh

# k3s / bare metal
bash provisioning/student/deploy.sh --storage-class local-path

# Tear down and redeploy from scratch
bash provisioning/student/deploy.sh --reset
```

Then access the portal:
```bash
kubectl port-forward -n jupyter-platform svc/provisioner 8080:80
# → http://localhost:8080/
```

The portal pod downloads kubectl and helm at startup — allow ~60 s before it becomes ready.

---

## Change Resource Limits

Edit once, apply everywhere:

```bash
# Change the hard CPU and RAM cap for every student pod
bash provisioning/student/set-limits.sh --cpu 2 --memory 4Gi

# Also change storage quota
bash provisioning/student/set-limits.sh --cpu 1 --memory 2Gi --storage 5Gi

# Apply new limits to already-provisioned students too
bash provisioning/student/set-limits.sh --cpu 1 --memory 2Gi --upgrade-all
```

The script patches `chart/values.yaml`, regenerates the in-cluster ConfigMaps, and restarts the provisioner. New students see the new limits immediately. Existing students need `--upgrade-all` to pick up the change.

**Where the values live:** [chart/values.yaml](chart/values.yaml)

```yaml
resources:
  limits:
    cpu: "1"       # ← change this
    memory: "2Gi"  # ← and this
  requests:
    cpu: "250m"
    memory: "512Mi"
```

Both the per-pod limit and the namespace-level quota ceiling are derived from these two fields — there is no second place to update.

---

## How It Works

```
Browser → POST /cgi-bin/provision.cgi
               │
               ▼
  provision.cgi (running in jupyter-platform)
  ├─ validates student ID (1–100)
  ├─ helm upgrade --install student-<id> /helm/student-chart
  │     creates: ResourceQuota, LimitRange, NetworkPolicies,
  │              RBAC, PVC, StatefulSet, Service
  └─ returns HTML page → JS polls /student/<id>/lab/api → auto-redirect

NGINX proxy: /student/<id>/* → jupyter-service-<id>.student-<id>:8888
```

Re-submitting the same ID is idempotent — `helm status` short-circuits provisioning and returns "Welcome back!".

---

## Helm Operations

```bash
# All provisioned students
helm list -A

# Values used for a specific student
helm get values student-007 -n student-007

# Full revision history
helm history student-007 -n student-007

# Roll back a broken student environment
helm rollback student-007 -n student-007

# Upgrade one student's image without changing anything else
helm upgrade student-007 /helm/student-chart \
  --reuse-values \
  --set image=quay.io/jupyter/scipy-notebook:2024-10-07 \
  -n student-007

# Delete one student (keeps PVC data)
helm uninstall student-007 -n student-007
kubectl delete namespace student-007
```

---

## Per-Student Kubernetes Objects

Each `student-<id>` namespace contains:

| Object | Purpose |
|---|---|
| ResourceQuota | Hard namespace ceiling — 1 CPU, 2 Gi RAM, 10 Gi storage, 5 pods |
| LimitRange | Auto-injects limits on pods that omit them; rejects pods exceeding the max |
| NetworkPolicy ×5 | Default-deny ingress; allow same-namespace, NGINX, DNS, and Postgres egress |
| ServiceAccount + RBAC | Student can only get/exec/port-forward in their own namespace |
| PVC (10 Gi) | Persistent workspace at `/home/jovyan/work`, survives pod eviction |
| StatefulSet | JupyterLab pod, re-attaches to the same PVC on reschedule |
| Service (ClusterIP) | Internal endpoint that NGINX proxies to |

---

## File Structure

```
provisioning/student/
  deploy.sh          ← deploy or redeploy the portal
  set-limits.sh      ← change resource limits in one command
  chart/             ← Helm chart (single source of truth)
    Chart.yaml
    values.yaml      ← edit limits here
    templates/       ← resourcequota, limitrange, statefulset, etc.
  k8s/
    00-namespace.yaml
    01-serviceaccount.yaml
    02-clusterrole.yaml
    03-clusterrolebinding.yaml
    04-configmap-nginx.yaml
    05-configmap-html.yaml
    06-configmap-cgi.yaml    ← provision.cgi (calls helm upgrade --install)
    07-deployment.yaml       ← provisioner pod (nginx + fcgiwrap + kubectl + helm)
    08-service.yaml          ← NodePort 30080
```

ConfigMaps for the Helm chart (`helm-chart-meta`, `helm-chart-templates`) are generated from `chart/` at deploy time — not stored as static files. Running `deploy.sh` or `set-limits.sh` always keeps them in sync.

---

## Shared Database

Every student pod can connect to the shared PostgreSQL database via the `DATABASE_URL` environment variable:

```
postgresql://courseuser:coursepass123@postgres-service.jupyter-experiment.svc.cluster.local:5432/coursedb
```

Requires the experiment environment to be running:

```bash
bash provisioning/experiment/run.sh
```
