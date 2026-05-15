# Lifecycle Controller

A Kubernetes controller (Go + controller-runtime) that automatically suspends expired student JupyterLab environments on the university platform. It is the automated half of the platform's **Lifecycle Management** requirement — the manual half is `provisioning/student/deprovision.sh`.

---

## The Problem It Solves

Without lifecycle management, student environments created at the start of a semester persist indefinitely. By the time next semester begins, the single 32-core / 128 GB node is still holding idle pods from 100 students who finished months ago. New students cannot be provisioned because there is no quota left. This controller prevents that.

---

## How It Works

```
┌────────────────────────────────────────────────────────────────┐
│                     Kubernetes API Server                      │
└──────────────────────────┬─────────────────────────────────────┘
                           │  Watch stream (Namespace events)
                           ▼
┌──────────────────────────────────────────────────────────────┐
│               Lifecycle Controller (this service)            │
│                                                              │
│  1. WATCH  — subscribes to all Namespace changes cluster-    │
│             wide, filtered to platform=jupyter-student only  │
│                                                              │
│  2. CHECK  — reads expires-at label on each namespace        │
│             • still active → requeue at exact expiry time    │
│             • already suspended → skip (no-op)               │
│             • expired → act                                  │
│                                                              │
│  3. ACT    — if expired and not yet suspended:               │
│             • scale every StatefulSet in the ns to 0         │
│               (JupyterLab pod stops; PVC is untouched)       │
│             • label ns: lifecycle-status=suspended           │
│                                                              │
│  4. REQUEUE — heartbeat every 1 hour as a safety net         │
└──────────────────────────────────────────────────────────────┘
```

**Key properties:**

| Property | Detail |
|---|---|
| Trigger | Immediate on watch event (label change, new namespace) + 1-hour heartbeat |
| Miss recovery | On restart, re-reconciles every student namespace from scratch |
| Soft-delete only | Scales to 0 — PVCs and namespaces are preserved |
| Hard-delete | Admin-triggered via `deprovision.sh --delete` |
| Single replica | No leader election needed; scale action is idempotent |

### Why a Controller and Not a CronJob

A CronJob runs once per night. If a semester ends at 5 PM, idle environments consume RAM until 2 AM. If the job pod crashes, nothing is cleaned until the next night.

A controller receives a **watch event** the moment any namespace label changes. Setting `expires-at=2020-01-01` on a namespace right now causes suspension within seconds. It also re-checks all namespaces on startup, so crashes cause no missed expirations.

---

## Lifecycle Labels

Every student namespace receives these labels at provision time (via the Helm chart's `namespace.yaml` template):

| Label | Example | Set by | Purpose |
|---|---|---|---|
| `platform` | `jupyter-student` | Helm (at provision) | Selects all student namespaces |
| `student-id` | `007` | Helm (at provision) | Identifies individual student |
| `semester` | `2025-spring` | Helm (at provision) | Groups environments by semester |
| `created-at` | `2026-01-15` | Helm (at provision) | Audit trail |
| `expires-at` | `2025-08-31` | Helm (at provision) | **The key field** — controller reads this |
| `lifecycle-status` | `suspended` | Controller (at suspension) | Marks suspended namespaces |
| `suspended-at` | `2026-09-01` | Controller (at suspension) | Records when suspension happened |

Configure `semester` and `expiresAt` in `provisioning/student/chart/values.yaml` before the semester starts.

---

## Repository Layout

```
provisioning/lifecycle-controller/
  main.go                          # Entry point: manager init, scheme registration
  controller/
    namespace_controller.go        # Reconciler: watch → check → suspend
  go.mod / go.sum                  # Go module dependencies
  Dockerfile                       # Multi-stage build → distroless image
  deploy.sh                        # Build image, load into minikube, apply manifests
  k8s/
    01-serviceaccount.yaml         # lifecycle-controller SA in jupyter-platform
    02-clusterrole.yaml            # ClusterRole: watch/patch namespaces + sts/scale
    03-clusterrolebinding.yaml     # Bind ClusterRole to SA
    04-deployment.yaml             # Single-replica controller Deployment

provisioning/student/
  deprovision.sh                   # Admin CLI: manual suspend / hard-delete
  chart/templates/namespace.yaml   # Helm template that stamps lifecycle labels
  chart/values.yaml                # semester + expiresAt defaults (edit each semester)
```

---

## Prerequisites

- minikube running: `minikube start`
- Docker running (for image build)
- Student portal already deployed: `bash provisioning/student/deploy.sh`
  (creates the `jupyter-platform` namespace the controller lives in)

---

## Deploy

```bash
bash provisioning/lifecycle-controller/deploy.sh
```

This does three things:
1. `docker build -t lifecycle-controller:latest .` — builds the Go binary inside a multi-stage Docker build
2. `minikube image load lifecycle-controller:latest` — makes the image available inside minikube without a registry
3. `kubectl apply -f k8s/` — creates the ServiceAccount, ClusterRole, ClusterRoleBinding, and Deployment

The Deployment uses `imagePullPolicy: Never` because the image is local — Kubernetes must not attempt to pull it from a registry.

---

## Verify It Is Running

```bash
# Check the Deployment is healthy
kubectl get deployment lifecycle-controller -n jupyter-platform

# Tail logs (structured JSON in production mode)
kubectl logs -n jupyter-platform -l app=lifecycle-controller -f
```

Expected log output for an active namespace:
```json
{"level":"info","namespace":"student-007","expires-at":"2025-08-31","requeue-in":"1h0m0s","msg":"namespace active"}
```

Expected log output when a namespace is suspended:
```json
{"level":"info","namespace":"student-007","statefulset":"jupyter-007","msg":"scaling StatefulSet to 0"}
{"level":"info","namespace":"student-007","suspended-at":"2026-09-01","msg":"namespace suspended"}
```

---

## Day-to-Day Operations

### See All Student Namespaces and Their Status

```bash
kubectl get ns -l platform=jupyter-student \
  -o custom-columns="NAME:.metadata.name,SEMESTER:.metadata.labels.semester,EXPIRES:.metadata.labels.expires-at,STATUS:.metadata.labels.lifecycle-status"
```

### See Only Suspended Namespaces

```bash
kubectl get ns -l lifecycle-status=suspended
```

### Resume a Suspended Student

```bash
# Scale the StatefulSet back to 1 replica
kubectl scale statefulset jupyter-007 -n student-007 --replicas=1

# Clear the suspended label so the controller does not immediately re-suspend it
# (only do this if you've also extended expires-at first)
kubectl label namespace student-007 lifecycle-status=active expires-at=2026-12-31 --overwrite
```

### Force-Expire a Namespace Now (Test the Controller)

```bash
# Set expires-at to a past date — the controller reacts within seconds via watch
kubectl label namespace student-007 expires-at=2020-01-01 --overwrite

# Watch logs
kubectl logs -n jupyter-platform -l app=lifecycle-controller -f
```

### Manually Trigger the Reconciler for All Namespaces

The controller reconciles automatically. To force an immediate pass, restart the pod:

```bash
kubectl rollout restart deployment/lifecycle-controller -n jupyter-platform
```

---

## Admin CLI: deprovision.sh

The controller handles automated suspension. Use `deprovision.sh` for:
- Immediate manual suspension
- Permanent hard-deletion (removes namespace + PVC — data cannot be recovered)
- Bulk operations by semester

```
bash provisioning/student/deprovision.sh [TARGET] [ACTION] [--confirm]

Targets:
  --student <id>    Single student (e.g. 007 or 7)
  --all             All student namespaces
  --semester <name> All students of a semester (e.g. 2025-spring)
  --expired         Namespaces whose expires-at label is in the past

Actions:
  --suspend   Scale StatefulSet to 0 (keeps PVC + namespace)
  --delete    helm uninstall + kubectl delete namespace (DESTROYS DATA)

Safety:
  --dry-run   Print what would happen (DEFAULT — always safe to run)
  --confirm   Required to execute any mutation
```

### Common Admin Workflows

```bash
# Semester end: preview which namespaces will be suspended
bash provisioning/student/deprovision.sh --expired --suspend

# Semester end: actually suspend all expired environments
bash provisioning/student/deprovision.sh --expired --suspend --confirm

# Suspend an entire semester explicitly
bash provisioning/student/deprovision.sh --semester 2024-fall --suspend --confirm

# Two months after semester: permanently delete all data
bash provisioning/student/deprovision.sh --semester 2024-fall --delete --confirm
# → prompts "Type 'yes' to continue" before proceeding

# Emergency: immediately suspend one student
bash provisioning/student/deprovision.sh --student 007 --suspend --confirm

# Hard-delete one student
bash provisioning/student/deprovision.sh --student 007 --delete --confirm
```

---

## New Semester Setup

At the start of each semester, update the semester name and expiry date before deploying:

```bash
# 1. Edit the defaults in chart/values.yaml
#    Change: semester: "2025-spring" → semester: "2025-fall"
#            expiresAt: "2025-08-31" → expiresAt: "2025-12-20"

# 2. Sync the updated values into the cluster ConfigMap
bash provisioning/student/deploy.sh

# All new students provisioned after this point will carry the new semester labels.
```

---

## Migrating Pre-Lifecycle Namespaces

Namespaces provisioned before this feature was added have no lifecycle labels. The controller ignores them (no `platform=jupyter-student` label). Label them once to bring them under management:

```bash
for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep '^student-'); do
  kubectl label ns "$ns" \
    platform=jupyter-student \
    semester=2025-spring \
    expires-at=2025-08-31 \
    --overwrite
  echo "Labeled $ns"
done
```

After this runs, the controller picks them up on the next watch event or heartbeat.

---

## Architecture Details

### Reconcile Loop (namespace_controller.go)

```
Reconcile(ctx, req) is called when:
  - A namespace with platform=jupyter-student is created or updated
  - The RequeueAfter timer fires for a previously reconciled namespace
  - The controller starts (all cached objects are enqueued)

Inside Reconcile:
  1. Get the Namespace from the informer cache (not a live API call)
  2. Check platform label — skip if not a student namespace
  3. Parse expires-at label — skip with no retry if malformed
  4. Compute threshold = parse(expires-at) + 24h
     (env stays active through the full expires-at day)
  5. If now < threshold:
       requeue in min(time-until-threshold, 1h)
  6. If lifecycle-status == "suspended": requeue in 1h (no-op)
  7. Otherwise (expired + not suspended):
       a. List all StatefulSets in the namespace
       b. For each with replicas > 0: patch replicas to 0
       c. Patch namespace labels: lifecycle-status=suspended, suspended-at=today
       d. Requeue in 1h
```

### RBAC (02-clusterrole.yaml)

| Resource | Verbs | Why |
|---|---|---|
| `namespaces` | get, list, watch, patch | Read expires-at; write lifecycle-status |
| `apps/statefulsets` | get, list, watch, patch | Read replicas; scale to 0 |
| `apps/statefulsets/scale` | get, update, patch | Required subresource for replica patch |
| `events` | create, patch | controller-runtime audit events |

### Scheme Registration (main.go)

```go
_ = corev1.AddToScheme(scheme)   // Namespace
_ = appsv1.AddToScheme(scheme)  // StatefulSet
```

Both must be registered for the controller-runtime client to decode API responses into typed Go structs.

### Image Build (Dockerfile)

```
Stage 1 (golang:1.22-alpine):
  - go mod download (cached layer)
  - go build → /lifecycle-controller (static binary, CGO_ENABLED=0)

Stage 2 (gcr.io/distroless/static:nonroot):
  - Copy binary only
  - No shell, no package manager — minimal attack surface
  - Runs as non-root (uid 65532)
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Controller pod crashes on startup | `kubectl describe pod -n jupyter-platform -l app=lifecycle-controller` — likely RBAC misconfiguration |
| Namespaces not being suspended | `kubectl get ns -l platform=jupyter-student` — confirm labels exist; check logs for "no expires-at label" |
| "unable to patch namespace" errors | Verify ClusterRole has `patch` on `namespaces`; run `kubectl auth can-i patch namespaces --as=system:serviceaccount:jupyter-platform:lifecycle-controller` |
| Image pull error (ErrImageNeverPull) | Image not loaded into minikube — re-run `minikube image load lifecycle-controller:latest` |
| Controller not reacting to label change | Label change may not have matched the predicate — confirm `platform=jupyter-student` label is present |

---

## End-to-End Test

```bash
# 1. Deploy controller
bash provisioning/lifecycle-controller/deploy.sh

# 2. Provision a test student
helm upgrade --install student-099 provisioning/student/chart \
  --set studentId=099 --namespace student-099 --create-namespace

# 3. Confirm lifecycle labels on namespace
kubectl get namespace student-099 --show-labels
# → platform=jupyter-student, semester=2025-spring, expires-at=2025-08-31

# 4. Controller logs should show "namespace active"
kubectl logs -n jupyter-platform -l app=lifecycle-controller | grep student-099

# 5. Force-expire and watch controller react
kubectl label namespace student-099 expires-at=2020-01-01 --overwrite
sleep 5
kubectl get namespace student-099 --show-labels | grep lifecycle-status
# → lifecycle-status=suspended

kubectl get statefulset -n student-099 -o jsonpath='{.items[0].spec.replicas}'
# → 0

# 6. Clean up test student
bash provisioning/student/deprovision.sh --student 099 --delete --confirm
```
