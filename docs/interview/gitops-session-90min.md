# GitOps Interview Prep — 90-Minute Training Session

**Format:** Instructor-led walkthrough. Read the question aloud, let students attempt an answer, then reveal the model answer and discussion points.
**Pace:** ~6–7 minutes per question including student discussion.
**Pre-req:** Students have completed Lab 1 and Lab 2 (ArgoCD, Helm, multi-env deployments).

---

## Session Outline

| Block | Time | Questions | Theme |
|-------|------|-----------|-------|
| A — Foundation | 0:00–0:18 | Q1, Q2 | What is GitOps really |
| B — ArgoCD Behaviour | 0:18–0:40 | Q3, Q4, Q5 | How ArgoCD behaves in practice |
| C — Helm & Config | 0:40–0:55 | Q6, Q7 | Chart design, secrets |
| D — Troubleshooting | 0:55–1:18 | Q8, Q9, Q10 | Live debugging scenarios |
| E — Curveball + Behavioral | 1:18–1:30 | Q11, Q12 | What separates good from great |

---

## Block A — Foundation (18 min)

---

### Q1 — `[7 min]`
> "What are the four principles of GitOps? Give me a real example of each."

**Why this opens the session:** Every other question connects back to these four. If students can't anchor answers here, they'll sound like they're reciting definitions instead of speaking from experience.

**Model answer:**

| Principle | What it means | Real example |
|-----------|--------------|--------------|
| **Declarative** | Describe WHAT, not HOW | Helm values file says `replicas: 3` — we never run `kubectl scale` |
| **Versioned & immutable** | Git is the audit trail | Every image tag change is a commit — `git log` tells you who deployed what and when |
| **Pulled automatically** | Agent inside cluster pulls, CI never pushes | ArgoCD polls GitHub every 3 min — CI pipeline has zero cluster credentials |
| **Continuously reconciled** | Agent detects and corrects drift | Manual `kubectl edit` on prod gets reverted by ArgoCD's selfHeal within minutes |

**Discussion prompt:** "What breaks in your project if you skip the 'pull' principle?" → CI pipeline needs cluster credentials → compromised runner = compromised cluster.

---

### Q2 — `[11 min]`
> "Walk me through exactly how a developer's code change reaches a running pod in production — every step."

**Why this question:** It's the most common opening question in interviews. Students often know the individual pieces but can't narrate the full chain fluently.

**Model answer — the full chain:**

```
1. Developer pushes code to zen-pharma-backend (app repo)

2. GitHub Actions CI triggers:
   - mvn test / npm test
   - docker build -t api-gateway:sha-abc123 .
   - docker push 873135413040.dkr.ecr.us-east-1.amazonaws.com/api-gateway:sha-abc123

3. CI bot opens a PR to zen-gitops repo:
   - Changes envs/dev/values-api-gateway.yaml  →  tag: sha-abc123

4. PR reviewed & merged to main

5. ArgoCD detects change (polls every 3 min or webhook):
   - Compares desired state (git) vs actual state (cluster)
   - Shows dev/api-gateway as OutOfSync

6. ArgoCD syncs (auto for dev):
   - helm upgrade api-gateway ./helm-charts -f envs/dev/values-api-gateway.yaml -n dev
   - Kubernetes rolling update: new pods up → old pods down

7. Pod starts:
   - Pulls image from ECR
   - ESO mounts db-credentials and jwt-secret
   - Spring Boot starts, passes readiness probe at /actuator/health/readiness
   - Pod added to Service endpoints → traffic flows
```

**Key point to emphasise:** CI touches the gitops repo (updates a YAML file). ArgoCD touches the cluster. These are separate, auditable steps — not one big pipeline with cluster access.

---

## Block B — ArgoCD Behaviour (22 min)

---

### Q3 — `[7 min]`
> "ArgoCD shows an app as Synced and Healthy but users are getting 500 errors. How is that possible?"

**Why this question:** Trips up most candidates. They assume ArgoCD's status = application health. It doesn't.

**Model answer:**

`Synced` = Git state matches cluster state. `Healthy` = Kubernetes health checks pass. Neither means the app is functionally working.

**Common real reasons:**
- `/actuator/health` returns 200 (Spring Boot is alive) but DB connection pool is exhausted → every request fails
- App started (pod is Ready) but it's trying to connect to a wrong DB schema — requests fail at runtime
- Rolling update completed but Service endpoints still include a terminating pod
- Config difference between dev and prod values — a wrong env var was promoted, app starts but every request fails

**Lesson:** Always monitor application-level SLOs (error rate, latency) in Grafana separately from ArgoCD status. ArgoCD tells you what's deployed, not whether it works.

---

### Q4 — `[8 min]`
> "You have auto-sync enabled on dev/qa but want manual approval for prod. How do you configure this in ArgoCD without maintaining 27 separate Application YAMLs?"

**Why this question:** Tests practical ArgoCD knowledge (ApplicationSet) and whether they think about operational safety vs speed.

**Model answer — use ApplicationSet with a matrix generator:**

```yaml
generators:
  - matrix:
      generators:
        - list:
            elements:
              - service: api-gateway
              - service: auth-service
              - service: drug-catalog-service
              # ... 6 more
        - list:
            elements:
              - env: dev
                autoSync: "true"
              - env: qa
                autoSync: "true"
              - env: prod
                autoSync: "false"
template:
  metadata:
    name: "{{env}}-{{service}}"
  spec:
    source:
      path: helm-charts
      helm:
        valueFiles:
          - "../../envs/{{env}}/values-{{service}}.yaml"
    syncPolicy:
      automated:
        enabled: "{{autoSync}}"
        selfHeal: true
        prune: true
    destination:
      namespace: "{{env}}"
```

27 Applications from one YAML. Dev/QA auto-sync. Prod is OutOfSync notification only — a human reviews in ArgoCD UI and clicks Sync.

**Additional prod hardening:** CODEOWNERS on `envs/prod/` requiring 2 reviewer approvals, sync windows restricting prod syncs to business hours only.

---

### Q5 — `[7 min]`
> "ArgoCD shows OutOfSync but every time you sync it goes back to OutOfSync immediately. What's happening?"

**Why this question:** Real-world scenario every ArgoCD user hits eventually.

**Model answer — it's a drift loop:**

Something is modifying the resource AFTER ArgoCD applies it, so the actual state never matches the desired state.

**Most common causes:**
1. **HPA modifies `spec.replicas`** — ArgoCD says `replicas: 1`, HPA scales it to 3, ArgoCD sees drift, syncs back to 1, HPA scales back to 3. Loop.
2. **Admission webhook adds annotations** — a mutating webhook injects a sidecar annotation that's not in your manifests.
3. **Kubernetes sets default fields** — e.g., `imagePullPolicy` gets defaulted by the API server.

**Fix — `ignoreDifferences`:**
```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas          # let HPA own this
```

**Teaching moment:** This is why you should never set `spec.replicas` in a Deployment manifest when HPA is managing it. Let HPA own replicas entirely.

---

## Block C — Helm & Config (15 min)

---

### Q6 — `[8 min]`
> "You have 9 microservices — Spring Boot, Node.js, different ports, some need ingress, some don't. How do you use ONE Helm chart for all of them?"

**Why this question:** Tests chart design thinking. Candidates either say "separate chart per service" (wrong) or can explain the generic chart pattern.

**Model answer — what makes our chart generic:**

```yaml
# values.yaml defaults
service:
  port: 8080           # notification-service overrides to 3000

ingress:
  enabled: false       # opt-in — pharma-ui and api-gateway set true
  path: /api

configmap: {}          # free-form key-value map — each service adds its own env vars

envFrom: []            # list of secretRef names — services declare what they need
```

**Per-service override (e.g., notification-service):**
```yaml
# envs/dev/values-notification-service.yaml
fullnameOverride: notification-service
service:
  port: 3000
configmap:
  NODE_ENV: development
  PORT: "3000"
  SMTP_HOST: smtp.example.com
envFrom:
  - secretRef:
      name: db-credentials
```

**What's hardcoded (never overridable):**
Security context: `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `drop: [ALL]`. Non-negotiable in pharma — no values file can turn these off.

**Discussion:** "Why `fullnameOverride`?" → Without it, the release name creates unpredictable resource names (`helm-release-api-gateway`). With it, resources are named exactly `api-gateway` — predictable for DNS, RBAC, and debugging.

---

### Q7 — `[7 min]`
> "How do you pass secrets to pods in a GitOps workflow without putting secret values in Git?"

**Why this question:** Almost every interview asks this. Candidates who say "base64 encode in Git" fail immediately.

**Model answer — three-layer separation:**

```
Git (safe to commit):
  ExternalSecret CRD → references path in AWS Secrets Manager
  values file → references secret NAME, never value

AWS Secrets Manager:
  Actual values: db password, JWT key
  Access controlled via IRSA (IAM role per service account)

Kubernetes:
  ESO syncs Secret object from Secrets Manager
  Pod mounts it via envFrom → secretRef: name: db-credentials
```

**The flow:**
1. ESO reads `ExternalSecret` from Git → "sync `db-credentials` from `arn:aws:secretsmanager:us-east-1:.../pharma/dev/db`"
2. ESO calls Secrets Manager (authenticated via IRSA) → gets actual value
3. ESO creates Kubernetes `Secret` object in the namespace
4. Pod spec: `envFrom: secretRef: name: db-credentials` → env vars injected at runtime

**What NOT to do:** `helm upgrade --set db.password=secret123` → value stored in Helm release history (base64 in a K8s Secret, readable by anyone with `kubectl get secret` access on that namespace).

---

## Block D — Troubleshooting (23 min)

---

### Q8 — `[8 min]`
> "A pod is in CrashLoopBackOff. Give me the exact kubectl commands in order."

**Why this question:** Bread and butter. If they can't answer this fluently, they struggle in real on-call situations.

**Model answer — the exact sequence:**

```bash
# Step 1: See the state and how many restarts
kubectl get pods -n dev -l app=api-gateway

# Step 2: What does Kubernetes think happened?
kubectl describe pod <pod-name> -n dev
# Look at: Events section at bottom — OOMKilled? ImagePullBackOff? probe failed?

# Step 3: Current logs
kubectl logs <pod-name> -n dev

# Step 4: Logs from the previous crash (most important for CrashLoop)
kubectl logs <pod-name> -n dev --previous

# Step 5: If it's an init container issue
kubectl logs <pod-name> -n dev -c <init-container-name>
```

**Common causes + what you see:**

| Symptom in `describe` | Cause | Fix |
|----------------------|-------|-----|
| `OOMKilled` | Memory limit too low | Increase `resources.limits.memory` |
| `Liveness probe failed` | App too slow to start | Increase `initialDelaySeconds` |
| `Back-off pulling image` | Wrong tag or ECR permissions | Check image tag in values file; check IRSA |
| `Error: secret not found` | ESO hasn't synced yet | `kubectl get externalsecret -n dev` |

**For Spring Boot specifically:** 90% of CrashLoop on first deploy = either liveness probe firing before JVM is ready (fix: `initialDelaySeconds: 60`), or DB connection refused (fix: check security group + DB_HOST env var).

---

### Q9 — `[8 min]`
> "NGINX Ingress is returning 404 for all routes. The pods are running and healthy. What do you check?"

**Why this question:** Multi-layer problem. Tests whether they know the difference between a 404 from NGINX vs a 404 from the app.

**Model answer — 404 from NGINX means NGINX has no matching route:**

```bash
# Step 1: Does NGINX know about this Ingress?
kubectl describe ingress api-gateway -n dev
# Look at: Events — did the controller acknowledge it?

# Step 2: Is the Ingress class correct?
kubectl get ingress api-gateway -n dev -o yaml | grep ingressClassName
# Must be: ingressClassName: nginx

# Step 3: Dump the live nginx.conf from inside the pod
kubectl exec -n kube-system <nginx-pod> -- nginx -T | grep -A5 "location /api"
# If your location block is missing — NGINX never picked up the Ingress

# Step 4: Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=ingress-nginx --tail=50
```

**Most common causes:**
1. `ingressClassName` missing or wrong — NGINX controller ignores the Ingress
2. `pathType: Exact` instead of `Prefix` — `/api/drugs` returns 404 if rule only matches `/api` exactly
3. Ingress has a `host:` that doesn't match the request hostname
4. NGINX controller restarted and is mid-sync — wait 30 seconds and retry

**Teaching moment:** In the Zen Pharma project, `pharma-ui` has no `host:` (matches all hosts) and `pathType: Prefix` for `/`. This is intentional — it's the catch-all.

---

### Q10 — `[7 min]`
> "You're mid-deployment on production — 50% of pods are on the new version — and error rate starts climbing. What do you do right now?"

**Why this question:** Tests decision-making under pressure. Most candidates jump straight to rollback. The right answer is: pause first.

**Model answer:**

```bash
# Step 1: PAUSE — don't rollback yet, don't panic
kubectl rollout pause deployment/api-gateway -n prod
# Traffic now splits 50/50 between old and new pods. Status is frozen.

# Step 2: Identify which pods are causing errors
kubectl get pods -n prod -l app=api-gateway -o wide
# See which pods are new (check AGE or image tag)

kubectl logs -n prod <new-pod-name> --tail=50 | grep -i error
```

**Decision tree:**
- **New pods are erroring** → errors are from the new version → rollback:
  ```bash
  kubectl rollout undo deployment/api-gateway -n prod
  # THEN: revert image tag in envs/prod/values-api-gateway.yaml in git
  ```
- **Old pods are erroring** → the deploy wasn't the cause → investigate independently
- **Both are erroring** → something else is wrong (DB, downstream service) → don't rollback

**Critical GitOps detail:** If `selfHeal: true` is on and you do `kubectl rollout undo` without reverting Git, ArgoCD will re-deploy the bad version within minutes. Always update Git to match what you want running.

---

## Block E — Curveball + Behavioral (12 min)

---

### Q11 — `[5 min]` *(quick fire)*
> "GitHub goes down. You have a P0 production fix that must ship in 20 minutes. What do you do?"

**Why this question:** Tests whether they understand GitOps is a process, not a hard dependency.

**Model answer — break glass, document everything:**

1. Check ArgoCD's last cached Git state — if the fix is already cached, trigger sync manually
2. Apply directly: `kubectl set image deployment/api-gateway pharma-service=<hotfix-image> -n prod`
3. Write down exactly what you did and why
4. The moment GitHub is back: open a PR with the same change, merge immediately
5. If ArgoCD `selfHeal` is on — it will fight your kubectl change. Temporarily suspend the Application, apply fix, update Git, unsuspend.

**One-liner answer:** "GitOps is the default workflow, not a cage. In a genuine emergency, kubectl works. The rule is: document it and fix Git immediately after."

---

### Q12 — `[7 min]`
> "Your team lead says: 'ArgoCD is overkill, let's just kubectl apply in CI.' How do you respond?"

**Why this closes the session:** Behavioral question that forces students to defend GitOps with evidence, not religion. This is a real conversation they'll have.

**Model answer — engage, don't dismiss:**

Start by acknowledging the valid concern: "For 2 services with one team, that's probably true. Let me explain why I'd still choose ArgoCD at our scale."

**Evidence-based pushback:**

| Concern | ArgoCD answer |
|---------|---------------|
| "kubectl in CI is simpler" | CI needs cluster credentials. Who manages those secrets? Rotation? Least privilege? ArgoCD has zero cluster credentials leaving the cluster. |
| "It's another tool to maintain" | So is the bash deploy script in your CI pipeline. At least ArgoCD has a UI, audit log, and RBAC built in. |
| "Rollbacks are easy with CI too" | Show me the rollback at 3am when the CI pipeline also has a bug. With GitOps: `git revert` → PR → ArgoCD syncs. |

**Then propose an experiment:** "Let's run both approaches for 60 days on different services. Track: MTTR (time to recover from bad deploy), audit question response time, number of production incidents from deployment. Decide based on data."

**The lesson:** Don't argue for tools — argue for outcomes. And be willing to lose the argument if the data says so.

---

## Wrap-up (2 min)

**Three things to remember from this session:**

1. **GitOps pull model = no cluster credentials in CI.** This one principle explains most of the architecture.

2. **ArgoCD Synced+Healthy ≠ app is working.** Always have application-level monitoring separate from ArgoCD.

3. **In an incident: pause before you act.** `kubectl rollout pause` buys you time to understand before you make things worse.

---

## Quick Reference — Questions by Difficulty

| Level | Questions to focus on |
|-------|----------------------|
| **Must know** (entry/mid) | Q1, Q2, Q7, Q8 |
| **Should know** (mid/senior) | Q3, Q4, Q6, Q9, Q10 |
| **Senior / architect** | Q5, Q11, Q12 |

---

## If You Have Extra Time — Bonus Questions

Pull these from the full question banks as time allows:

- **L3** (`interview-questions.md`) — Liveness vs readiness misconfiguration — common Spring Boot gotcha
- **L6** (`interview-questions.md`) — Zero-downtime DB migration — always impresses interviewers
- **M4** (`interview-questions.md`) — Cut cluster costs by 40% — good for senior roles
- **A2** (`part2.md`) — How ArgoCD detects drift — good depth question
- **H2** (`part2.md`) — `Pending` pod for 10 minutes — scheduler/resource debugging
