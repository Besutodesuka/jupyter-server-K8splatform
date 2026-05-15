# Jupyter Server — Kubernetes Platform

A multi-tenant JupyterLab platform on Kubernetes where each student gets an isolated, resource-capped environment for coursework.

## Architecture

```mermaid
graph TB
      User(["Student / Admin"])

      subgraph Cluster["Kubernetes Cluster - 1 Bare-Metal Server"]

          subgraph Entry["Entry Layer  (jupyter-platform namespace)"]
              NGINX["NGINX Reverse Proxy\n(in provisioner pod\nNodePort 30080)"]
              CGI["provision.cgi\n(CGI bash + fcgiwrap)"]
              NGINX -->|"POST /cgi-bin/provision.cgi"| CGI
          end

          subgraph SelfService["Self-Service Provisioning"]
              HelmInMem["Helm Chart\n(templates reconstructed\nfrom ConfigMaps at startup)"]
              CGI -->|"helm upgrade --install\n--create-namespace"| HelmInMem
          end

          subgraph ControlPlane["Control Plane (pre-existing k8s components)"]
              KubeAPI["kube-APIServer"]
              Sched["kube-scheduler"]
              CtrlMgr["kube-controller-manager"]
          end

          subgraph RBAC["jupyter-platform ClusterRole"]
              ProvSA["provisioner ServiceAccount\n+ ClusterRoleBinding\n(ns, quota, pvc, rbac, ss, svc)"]
          end

          subgraph StudentNS["Namespace: student-&lt;id&gt;  (up to 100 units)"]
              RQ["ResourceQuota\n1 CPU / 1Gi RAM\n10Gi storage / 5 pods"]
              LimitR["LimitRange\ndefault per container"]
              NP["NetworkPolicy  (5
  rules)\ndefault-deny-ingress\nallow-same-namespace\nallow-nginx-ingress\nallow-egress-dns\nallow-egress-postgres"]
              JupySS["Jupyter Notebook Pod\n(StatefulSet)\nscipy-notebook:2024-05-27\nport 8888"]
              RoleB["RoleBinding\nstudent owns only this NS\n(get/list pods, exec, port-forward)"]
              StudSA["student-&lt;id&gt; ServiceAccount"]
          end

          subgraph SharedNS["jupyter-experiment namespace  (shared)"]
              PG["PostgreSQL\n(Deployment — not StatefulSet)\npostgres:15\nlimits: 2 CPU / 2Gi RAM\ncoursedb / courseuser"]
              PGPVC2["postgres-pvc\n10Gi PVC"]
          end

          subgraph Storage["Persistent Storage"]
              PVC["PersistentVolumeClaim\njupyter-workspace-&lt;id&gt;\n10Gi  •  keep on helm uninstall"]
              SC["StorageClass\nlocal-path (k3s)\n or standard (minikube)\nauto-detected at deploy time"]
          end

          subgraph DaemonSets["DaemonSets  (all nodes incl. control-plane)"]
              NodeExp["node-exporter\n(DaemonSet)\nprom/node-exporter:v1.8.1\nhostNetwork + hostPID\nport 9100"]
          end

          subgraph Observability["Observability  (monitoring namespace  —  Deployments, not StatefulSets)"]
              KSM["kube-state-metrics\n(Deployment) v2.12.0\nnamespaces, pods, quotas,\nlimitranges, PVCs, statefulsets"]
              Prom["Prometheus\n(Deployment) v2.52.0\nNodePort 30090\n10Gi PVC • 15-day retention\nrecording rules + 6 alert rules"]
              Grafana["Grafana\n(Deployment) 10.4.3\nNodePort 30030\nmulti-tenant-overview +\nstudent-drilldown dashboards"]
          end

      end

      User -->|"HTTP form: student_id (1-100)\nNO authentication"| NGINX
      NGINX -->|"/student/&lt;id&gt;/*\nWebSocket proxy → ClusterIP svc"| JupySS

      HelmInMem -->|"creates: NS, RQ, LR, NP\nSA, RoleBinding\nStatefulSet, Service, PVC"| StudentNS

      JupySS --> PVC
      PVC --> SC
      PGPVC2 --> SC

      JupySS -->|"TCP 5432 egress\ncourseuser@coursedb"| PG
      PG --> PGPVC2

      NodeExp -->|"node metrics\nport 9100"| Prom
      KSM -->|"quota / pod / ns metrics\nport 8080"| Prom
      KSM -.->|"watches"| StudentNS
      Prom -->|"auto-provisioned\ndatasource"| Grafana
```

---

## Repository Layout

```
jupyter_platform/        Student provisioning portal
hard_limit_estimation/   Experiment for sizing CPU/RAM hard limits
monitoring/              Prometheus + Grafana observability stack
docs/                    Extended documentation
```

---

## jupyter_platform

A self-service provisioning portal. A student types their ID into a browser form and the platform spins up a fully isolated JupyterLab instance — dedicated namespace, hard resource quotas, persistent storage, and network policies — within seconds.

Each student namespace contains a `ResourceQuota`, `LimitRange`, five `NetworkPolicy` rules, a `PVC`, and a `StatefulSet`. Re-submitting the same ID is idempotent.

See [`jupyter_platform/README.md`](jupyter_platform/README.md) for deploy instructions, how to change resource limits, and Helm operations.

---

## hard_limit_estimation

An experiment used to find the minimum CPU and RAM that Jupyter and Postgres pods can tolerate before degrading under real coursework load. This informs the hard limit values set in `jupyter_platform`.

The experiment runs 14 stress scenarios (heavy SQL joins, pandas feature engineering, NumPy linear algebra, matplotlib rendering) against a seeded 100k-row database, then measures peak RSS and elapsed time at progressively tighter limits using a binary-search protocol.

See [`docs/hard-limit-estimation.md`](docs/hard-limit-estimation.md) for the full methodology and results.

---

## monitoring

A Prometheus + Grafana stack that watches the health and isolation of the platform.

- **node-exporter** (DaemonSet) — whole-node CPU, RAM, disk, network
- **kube-state-metrics** — per-namespace quota usage and pod state
- **cAdvisor** (via kubelet) — per-container actual CPU and RAM

Two pre-built Grafana dashboards are included:

| Dashboard | Purpose |
|---|---|
| Multi-Tenant Overview | All students at a glance — quota usage, noisy neighbours, OOMKills, orphaned namespaces |
| Student Drill-Down | Single student deep-dive with CPU/RAM trend lines and headroom gauges |

Alerting rules fire on quota near-limit (>80%), hard limit hit, OOMKill, node memory pressure (>90%), and orphaned namespaces idle >1 h.

See [`docs/monitoring.md`](docs/monitoring.md) for architecture, metrics reference, and how to test each isolation requirement.

---

## Quick Start

```bash
# 0.start k8s
minikube start
# 1. Start the provisioning portal
bash jupyter_platform/deploy.sh

# 2. Access the student portal
kubectl port-forward -n jupyter-platform svc/provisioner 8080:80
# → http://localhost:8080/

# 3. Deploy monitoring
bash monitoring/deploy.sh

# 4. Access Grafana
kubectl port-forward -n monitoring svc/grafana 3000:3000
# → http://localhost:3000  (admin / admin)
```

---

## Docs

| File | Contents |
|---|---|
| [`docs/hard-limit-estimation.md`](docs/hard-limit-estimation.md) | Stress test methodology, binary-search protocol, result tables |
| [`docs/monitoring.md`](docs/monitoring.md) | Full metrics reference, alerting rules, isolation test procedures |
| [`docs/database.md`](docs/database.md) | Shared PostgreSQL schema used by the experiment |
