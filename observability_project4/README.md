# Fluent Bit → Elastic Cloud Setup

## 1. Create Elasticsearch on Elastic Cloud

1. Go to <https://cloud.elastic.co/> and sign in
2. Click **Create deployment** → choose **Elasticsearch**
3. Select cloud provider **GCP**, region **us-central1**
4. Note the **Cloud endpoint** after creation:
   ```
   https://my-elasticsearch-project-be5821.es.us-central1.gcp.elastic.cloud:443
   ```

---

## 2. Create an API Key

1. In your deployment, go to **Security → API Keys → Create API key**
2. Name it `fluent-bit-dev`, set no expiry
3. Copy the **Encoded** value (base64 format):
   ```
   Y2xZRzc1NEJhZjZzUnhfam0wdHo6bExaQjdqQUw4aGJtbzFCdEp0SEh6UQ==
   ```

---

## 3. Create the Kubernetes Secret

```bash
kubectl create secret generic fluent-bit-elastic-credentials \
  --namespace dev \
  --from-literal=api_key='Y2xZRzc1NEJhZjZzUnhfam0wdHo6bExaQjdqQUw4aGJtbzFCdEp0SEh6UQ==' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify:
```bash
kubectl get secret fluent-bit-elastic-credentials -n dev
```

---

## 4. Update the Elasticsearch Host

Edit `envs/dev/values-fluent-bit.yaml`:
```yaml
elasticsearch:
  host: my-elasticsearch-project-be5821.es.us-central1.gcp.elastic.cloud
  port: 443
  tls: true
  credentialsSecret: fluent-bit-elastic-credentials
```

---

## 5. Apply Fluent Bit Manifests

```bash
kubectl apply -f k8s/fluent-bit/secret.yaml
kubectl apply -f k8s/fluent-bit/rbac.yaml
kubectl apply -f k8s/fluent-bit/configmap.yaml
kubectl apply -f k8s/fluent-bit/daemonset.yaml
```

Verify pods are running:
```bash
kubectl get pods -n dev -l app=fluent-bit
kubectl logs -n dev -l app=fluent-bit --tail=30
```

---

## 6. Deploy via ArgoCD (GitOps path)

```bash
# Apply the ArgoCD project first
kubectl apply -f argocd/projects/pharma-project.yaml

# Apply the Application
kubectl apply -f observability_project4/fluent-bit-app.yaml

# Watch sync status
argocd app get fluent-bit-dev
```

---

## Verify Logs in Elastic Cloud

- Go to **Elastic Cloud → Discover**
- Search index pattern: `dev-service-*` or `<service-name>-YYYY.MM.DD`
- You should see logs within ~1 minute of pods starting
