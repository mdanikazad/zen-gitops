# Session 2 Agenda — GitOps with ArgoCD + Helm
**Duration:** 2.5 hours | **Format:** Concept → Demo → Hands-on lab

---

## Overview

| # | Topic | Type | Time |
|---|---|---|---|
| 1 | Pain points of native K8s deployments | Discussion | 15 min |
| 2 | Why ArgoCD? GitOps principles | Concept | 15 min |
| 3 | ArgoCD features | Concept | 10 min |
| 4 | ArgoCD components (architecture) | Concept | 10 min |
| 5 | NGINX Ingress — how external traffic reaches services | Concept + demo | 15 min |
| 6 | **Lab 2 — Execute** | Hands-on | 45 min |
| 7 | External Secrets Operator | Concept + demo | 20 min |
| — | Q&A + Wrap-up | — | 10 min |

---

## 1. Pain Points of Native K8s Deployments (15 min)

**Context:** In Lab 1 you deployed 9 services using raw `kubectl apply`. What was painful?

### What you did manually — the count

| Task | Effort |
|---|---|
| Files applied | 11 (namespace, rbac, 9 services) |
| Resources created | ~40 (Deployments, Services, ConfigMaps, SAs, Pods) |
| Secrets created by hand | 2 (typed passwords directly into terminal) |
| Environments covered | 1 (dev only) |

Now multiply by 3 environments (dev, qa, prod) and 9 services:

- **27 deployments** to maintain
- A new Docker image ships every week → update `image:` in 9 `deployment.yaml` files by hand
- Change a readiness probe timeout → edit 9 files
- Who changed the replica count in prod last Tuesday? → no audit trail
- Prod and dev configs slowly diverge → nobody notices until it breaks in prod

### The five problems

| Problem | Real consequence |
|---|---|
| **No audit trail** | Can't answer "who changed this?" in a production incident |
| **Config drift** | Dev and prod diverge silently; "works on dev" bug in prod |
| **Manual secret management** | Passwords typed into terminals, stored in base64 etcd |
| **No rollback mechanism** | To undo a bad deploy, re-type the old values manually |
| **Doesn't scale** | 9 services is manageable; 50 services across 5 environments is not |

**Transition:** GitOps + Helm + ArgoCD solve all five.

---

## 2. Why ArgoCD? GitOps Principles (15 min)

**GitOps in one sentence:** Git is the single source of truth for what should run in your cluster. You change Git; an operator (ArgoCD) makes the cluster match.

### The 4 GitOps principles

| Principle | Before GitOps | After GitOps |
|---|---|---|
| **Declarative** | `kubectl scale --replicas=3` | `replicaCount: 3` in a values file, merged via PR |
| **Versioned** | Nobody knows who changed replicas | `git log envs/prod/values-auth-service.yaml` |
| **Pulled automatically** | CI pushes to cluster (blast radius: full cluster) | ArgoCD pulls from Git (blast radius: scoped per app) |
| **Continuously reconciled** | Drift is invisible until something breaks | ArgoCD detects and optionally reverts drift within 3 min |

### Why ArgoCD over alternatives?

| Tool | Model | Best for |
|---|---|---|
| **ArgoCD** | Pull-based, Kubernetes-native, rich UI | Kubernetes-first teams, multi-env, visibility |
| **Flux** | Pull-based, CLI-only, lighter footprint | Teams that prefer minimal tooling |
| **Jenkins** | Push-based from CI | Legacy pipelines; ArgoCD complements it, not replaces |
| **Helm directly** | Push-based (`helm upgrade`) | No GitOps — manual trigger, no reconciliation |

**ArgoCD's key advantage:** the reconciliation loop. ArgoCD continuously watches the cluster and reverts drift. Jenkins upgrades; it doesn't watch.

---

## 3. ArgoCD Features (10 min)

| Feature | What it does | Where you'll see it today |
|---|---|---|
| **Automated sync** | Applies Git changes to the cluster automatically | Dev apps sync on every push |
| **Self-heal** | Reverts manual cluster changes back to Git state | Demo: scale a deployment manually, watch ArgoCD revert it |
| **Prune** | Deletes K8s resources that were removed from Git | Remove a service from Git → ArgoCD deletes it from cluster |
| **Diff view** | Shows exactly what would change before syncing | UI: orange lines = live, green lines = desired |
| **Sync history + rollback** | Every sync linked to a Git commit; one-click rollback | History tab in the app detail view |
| **AppProject RBAC** | Who can deploy to which namespace/environment | pharma project: dev team can't touch prod |
| **Resource health** | Aggregates pod/deployment/service health into one status | Healthy / Progressing / Degraded |
| **Helm + Kustomize native** | Renders templates server-side; no `helm install` needed | ArgoCD runs `helm template` internally every 3 min |
| **Multi-cluster** | One ArgoCD can manage many clusters | Not in today's lab, but this is how prod teams run it |

### ArgoCD UI walkthrough — where to find each feature

Open the ArgoCD UI (`https://<argocd-server>`) and navigate to any application (e.g., `auth-service-dev-raw`).

**App list view**

```
Apps screen → each tile shows:
  ● Synced / OutOfSync badge     ← did the cluster drift from Git?
  ● Healthy / Degraded badge     ← are pods actually running?
  ● Last sync timestamp + commit SHA
```

**App detail view — three key tabs**

| Tab | What to look at | Feature demonstrated |
|---|---|---|
| **Summary** | Sync Policy section | Toggle Auto-Sync, Self-Heal, Prune |
| **Diff** | Orange = live state, Green = desired (Git) | What ArgoCD will change on next sync |
| **History & Rollback** | Every row = one sync tied to a Git commit | Click "Rollback" → cluster reverts to that SHA |

**Self-heal in the UI**

```
App detail → Summary tab → Sync Policy panel
  ✅ Auto-Sync       ← enabled = ArgoCD syncs on every Git push
  ✅ Self Heal       ← enabled = manual cluster changes get reverted
  ✅ Prune Resources ← enabled = resources removed from Git get deleted
```

**Prune demo — live in the UI**

1. Remove one manifest from Git, push the commit
2. App goes **OutOfSync** — the resource tile turns orange with a trash icon
3. Without `prune: true`: ArgoCD marks it OutOfSync but leaves the resource alive
4. With `prune: true`: ArgoCD deletes it — tile disappears from the app graph

**Sync Options button**

Top-right of app detail → "Sync" → modal shows checkboxes:
- **Prune** — delete orphaned resources this sync only
- **Force** — replace resources (useful if immutable field changed)
- **Dry Run** — compute the diff without applying it (safe preview)
- **Apply Only** — skip pre/post sync hooks

**App graph / resource tree**

The visual tree on the App detail page shows every K8s object that belongs to this Application:
```
Application
└── Deployment: auth-service
    └── ReplicaSet
        └── Pod (green = Healthy, yellow = Progressing, red = Degraded)
└── Service: auth-service
└── ConfigMap: auth-service-config
```
Click any node → live YAML on the right, Events tab below.

---

## 4. ArgoCD Components (10 min)

```
┌─────────────────────────────────────────────────────────────┐
│  ArgoCD (argocd namespace)                                   │
│                                                             │
│  ┌─────────────────┐   ┌─────────────────────────────────┐  │
│  │  argocd-server  │   │  argocd-repo-server             │  │
│  │                 │   │                                 │  │
│  │  - REST + gRPC  │   │  - Clones Git repos             │  │
│  │    API          │   │  - Renders Helm/Kustomize       │  │
│  │  - Web UI       │   │  - Caches rendered manifests    │  │
│  │  - argocd CLI   │   │  - Diffs desired vs live        │  │
│  └─────────────────┘   └─────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────┐   ┌────────────────────────┐  │
│  │  application-controller  │   │  argocd-dex-server     │  │
│  │                          │   │                        │  │
│  │  - Reconciliation loop   │   │  - SSO / OIDC connector│  │
│  │  - Watches cluster state │   │  - GitHub/Google login │  │
│  │  - Triggers sync         │   │  (optional in labs)    │  │
│  │  - Reports health        │   └────────────────────────┘  │
│  └──────────────────────────┘                               │
│                                                             │
│  ┌──────────────────────────┐   ┌────────────────────────┐  │
│  │  argocd-redis            │   │  argocd-notifications  │  │
│  │  - State cache           │   │  - Slack/email alerts  │  │
│  └──────────────────────────┘   └────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
            │ watches (poll every 3 min or webhook)
            ▼
    zen-gitops repo (GitHub)
            │ compares desired manifests with live cluster
            ▼
    EKS Cluster  →  dev / qa / prod namespaces
```

### Two core objects to understand

**AppProject** — security boundary
```yaml
spec:
  sourceRepos:    # which Git repos are allowed
  destinations:  # which namespaces ArgoCD can deploy to
  clusterResourceWhitelist:  # which resource types are allowed
```

**Application** — the sync definition
```yaml
spec:
  source:
    repoURL: https://github.com/your-org/zen-gitops
    path: lab2/manifests/auth-service    # or helm-charts + valueFiles
  destination:
    namespace: dev
  syncPolicy:
    automated:
      prune: true     # delete resources removed from Git
      selfHeal: true  # revert manual cluster changes
```

---

## 5. NGINX Ingress — How External Traffic Reaches Services (15 min)

**The problem:** All microservices use `ClusterIP` — they are only reachable inside the cluster. We need one stable external entry point.

### Traffic flow

```
Browser / curl
     │
     ▼
AWS LoadBalancer  (ELB — created automatically when you install NGINX Ingress)
     │
     ▼
NGINX Ingress Controller Pod  (ingress-nginx namespace)
     │  reads Ingress rules from Kubernetes API
     │
     ├── path: /        →  pharma-ui:80
     │
     └── path: /api     →  api-gateway:8080
```

### The two Ingress rules in this project

**pharma-ui** — serves the React frontend at `/`
```yaml
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: pharma-ui
                port:
                  number: 80
```

**api-gateway** — routes all API calls at `/api`
```yaml
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-gateway
                port:
                  number: 8080
```

### How pharma-ui talks to backend microservices

The React frontend is a **browser app** — it never talks directly to supplier, auth, or order services from inside the cluster. Every API call goes out through the browser, hits the LoadBalancer, and is routed by NGINX.

```
Browser (React SPA)
     │
     │  fetch("/api/suppliers")        ← relative URL, no hardcoded host
     │  fetch("/api/orders")
     │  fetch("/api/auth/login")
     ▼
AWS LoadBalancer  (same LB, same IP as the UI)
     │
     ▼
NGINX Ingress Controller
     │  path: /api  →  api-gateway:8080
     ▼
api-gateway  (Spring Boot)
     │  routes by sub-path:
     ├── /api/suppliers   →  supplier-service:8080   (ClusterIP)
     ├── /api/orders      →  order-service:8080       (ClusterIP)
     ├── /api/auth        →  auth-service:8080        (ClusterIP)
     └── /api/products    →  product-service:8080     (ClusterIP)
```

**Key points:**
- `pharma-ui` uses **relative URLs** (e.g., `/api/suppliers`) — it never needs to know the cluster-internal hostname of supplier-service
- NGINX strips `/api` (or passes it through) and forwards to `api-gateway`
- `api-gateway` routes to individual services using **Kubernetes DNS**: `http://supplier-service.dev.svc.cluster.local:8080`
- Services below `api-gateway` are pure `ClusterIP` — no Ingress, unreachable from outside

**Microservice-to-microservice calls (server-side only)**

When `api-gateway` (or `order-service`) calls another service, it uses the cluster DNS name directly — it never leaves the cluster:

```
api-gateway pod
  → http://supplier-service:8080/suppliers      (same namespace, short name works)
  → http://auth-service.dev.svc.cluster.local   (cross-namespace, full FQDN)
```

**Why this matters for GitOps:** The `api-gateway` routing rules (Spring Cloud Gateway routes or Nginx config) live in the service's `ConfigMap` or `application.yaml` — those are in Git, versioned, and synced by ArgoCD like everything else.

### Common Ingress error codes

| Code | Meaning | Cause | Fix |
|---|---|---|---|
| 404 | No Ingress rule matched | Missing ingress.yaml, wrong path | Check `kubectl get ingress -n dev` |
| 502 | NGINX reached pod, got bad response | Wrong targetPort in Service | Check `kubectl get endpoints -n dev` |
| 503 | NGINX has no upstream | Pod failing readiness, no endpoints | Check `kubectl get endpoints` — should not be `<none>` |

**Verify today:**
```bash
kubectl get ingress -n dev          # see both ingress rules
kubectl get svc -n ingress-nginx    # get the LoadBalancer EXTERNAL-IP
curl http://<EXTERNAL-IP>/          # pharma-ui
curl http://<EXTERNAL-IP>/api/actuator/health   # api-gateway
```

---

## 6. Lab 2 — Execute (45 min)

Follow `lab2/LAB2-GUIDE.md`. Instructor walks through Part 1 (Day 2 — ArgoCD with raw manifests) live; students replicate.

### Checkpoints

| Checkpoint | Command | Expected |
|---|---|---|
| ArgoCD pods running | `kubectl get pods -n argocd` | All `1/1 Running` |
| AppProject created | `argocd proj list` | `pharma` listed |
| auth-service synced | `argocd app get auth-service-dev-raw` | `STATUS: Synced` |
| All 9 apps running | `argocd app list` | 9 apps, all Synced/Healthy |
| pharma-ui accessible | `curl http://<LB>/` | HTML response (not 404) |
| Drift demo works | Scale to 3, watch ArgoCD detect OutOfSync | Status changes within 3 min |

### Key moment — drift demo

```bash
kubectl scale deployment auth-service --replicas=3 -n dev
# Wait ~3 minutes (or: argocd app get auth-service-dev-raw to force refresh)
argocd app diff auth-service-dev-raw
# Shows: replicas: 1 (desired) vs 3 (live)
argocd app sync auth-service-dev-raw
kubectl get pods -n dev  # back to 1 pod
```

> **This is the core GitOps insight.** The cluster converged back to what Git said — not what a human decided at 2am.

---

## 7. External Secrets Operator (20 min)

### Why secrets can't live in Git or be manually created

| Method | Problem |
|---|---|
| Commit to Git | Git history is permanent — leaked password is permanently retrievable |
| `kubectl create secret` | No audit trail, no rotation, cluster rebuild requires someone to re-type passwords |
| Base64 in a YAML file | Base64 is NOT encryption; anyone with `kubectl get secret` reads it |

### The ESO model — 3 objects, no secrets in Git

```
AWS Secrets Manager  (/pharma/dev/db-credentials → {username, password})
        │
        │  GetSecretValue (via IRSA — no static AWS credentials)
        ▼
ClusterSecretStore   (tells ESO: connect to AWS, region us-east-1, use this SA)
        │
        │  watches
        ▼
ExternalSecret       (tells ESO: fetch /pharma/dev/db-credentials → create K8s Secret db-credentials)
        │
        │  creates/refreshes every 1h
        ▼
K8s Secret: db-credentials  (DB_USERNAME, DB_PASSWORD, SPRING_DATASOURCE_*)
        │
        │  envFrom: secretRef
        ▼
auth-service Pod     (reads DB_PASSWORD as environment variable)
```

### IRSA — why no static AWS keys

EKS injects a short-lived JWT into the ESO pod. ESO exchanges it with AWS STS → gets temporary credentials (15-60 min TTL). Nothing is stored. If the cluster is compromised, there are no keys to steal.

```bash
# Verify IRSA annotation is present on the ESO service account
kubectl get sa external-secrets -n external-secrets \
  -o jsonpath='{.metadata.annotations}'
# Expected: eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/pharma-dev-eso-role
```

### The manifests are already in this repo — this is the GitOps way

```
k8s/external-secrets/
├── cluster-secret-store.yaml      ← ClusterSecretStore (AWS connector)
├── dev-external-secrets.yaml      ← ExternalSecrets for dev namespace
├── qa-external-secrets.yaml       ← ExternalSecrets for qa namespace
└── prod-external-secrets.yaml     ← ExternalSecrets for prod namespace
```

These files contain **only paths** (`/pharma/dev/db-credentials`), never values. Safe to commit to Git. Applying them via ArgoCD or `kubectl apply` is the complete GitOps-compliant secret setup — no passwords ever touch the terminal.

### Demo

```bash
# 1. Apply from Git (the GitOps way)
kubectl apply -f k8s/external-secrets/cluster-secret-store.yaml
kubectl apply -f k8s/external-secrets/dev-external-secrets.yaml

# 2. Watch them sync
kubectl get externalsecret -n dev -w
# NAME             STATUS        READY
# db-credentials   SecretSynced  True
# jwt-secret       SecretSynced  True

# 3. Confirm K8s Secret was materialized
kubectl get secret db-credentials -n dev
kubectl get secret db-credentials -n dev \
  -o jsonpath='{.data.DB_USERNAME}' | base64 -d && echo
# pharmaadmin
```

---

## Q&A + Wrap-up (10 min)

### What you built today

```
EKS Cluster
└── dev namespace — 9 services, GitOps-managed, auto-sync via ArgoCD

ArgoCD
└── pharma AppProject → 9 Applications watching lab2/manifests/

Secrets
└── ESO pulls from AWS Secrets Manager → K8s Secrets materialize automatically
```

### Questions to check understanding

1. What does ArgoCD do when `selfHeal: true` and someone manually scales a deployment?
2. Why does pharma-ui get a 404 if the Ingress resource is missing?
3. What is the difference between a ClusterSecretStore and an ExternalSecret?
4. Why can't we just put `DB_PASSWORD` in a ConfigMap?
5. What happens to prod sync when you push a change to `envs/prod/` in Git?

### Homework

1. Fork zen-gitops, complete Lab 2 Part 1 (day2-raw) on your own cluster
2. Simulate drift on 3 different services and observe ArgoCD's response
3. Install ESO, apply the manifests from `k8s/external-secrets/`, verify sync
4. Answer in your own words: "How does a secret get from AWS Secrets Manager into a running pod?" (5-layer explanation)
