# GitOps Deployment Guide (ArgoCD)

Welcome! This repository controls exactly what applications and services are running inside our Kubernetes clusters.

If you have already run the **Terraform** repository, ArgoCD is currently watching this repository. Any changes you push to the `main` branch here will be automatically deployed to the cluster within 3 minutes. **You do not need to run `kubectl apply`.**

---

## Repository Structure

- `apps/`: Contains the actual microservices (Frontend, Order Service, etc.) broken down by environment (`dev`, `staging`, `prod`).
- `platform/`: Contains cluster-level add-ons (like the External Secrets Operator which securely pulls database passwords from AWS).
- `bootstrap/`: The App-of-Apps master configurations that tell ArgoCD to deploy everything above.

---

## Step 1: Deploying a New Service Version (Updating an Image Tag)

As a developer, your most common task will be updating an application to deploy a new feature. We use `Kustomize` to manage image tags securely.

Let's say your CI/CD pipeline built a new Docker image for the frontend: `602367507570.dkr.ecr.us-east-1.amazonaws.com/frontend:v2.0.0` and you want to deploy it to the `dev` environment.

1. Open the file: `apps/dev/kustomization.yaml`
2. Scroll to the bottom where you see the `images:` block.
3. Update the `newTag` value for your specific service.

**Before:**
```yaml
images:
  - name: 602367507570.dkr.ecr.us-east-1.amazonaws.com/frontend
    newTag: "latest"
```

**After:**
```yaml
images:
  - name: 602367507570.dkr.ecr.us-east-1.amazonaws.com/frontend
    newTag: "v2.0.0"  # <-- Update this line
```

4. Commit and push your changes to GitHub:
   ```bash
   git add apps/dev/kustomization.yaml
   git commit -m "deploy: update frontend to v2.0.0 in dev"
   git push origin main
   ```

**That's it!** ArgoCD will detect this change and smoothly roll out the new `v2.0.0` pods while terminating the old ones.

---

## Step 2: Adding a Brand New Microservice

If you created a completely new microservice (e.g., `payment-service`) and want to deploy it to the cluster:

1. **Create the Base Manifests**:
   Navigate to `apps/base/` and create a new folder for your service.
   ```bash
   mkdir apps/base/payment-service
   ```
   Inside this folder, add your standard Kubernetes YAML files (`deployment.yaml`, `service.yaml`) and a `kustomization.yaml` that includes them.

2. **Include the Base Service**:
   Open `apps/base/kustomization.yaml` and add your new folder to the resources list:
   ```yaml
   resources:
     - frontend
     - order-service
     - user-service
     - payment-service # <-- Add this line
   ```

3. **Set the Image Tag for Environments**:
   Open `apps/dev/kustomization.yaml` (and staging/prod) and add your new service to the `images:` list:
   ```yaml
   images:
     - name: 602367507570.dkr.ecr.us-east-1.amazonaws.com/payment-service
       newTag: "v1.0.0"
   ```

4. **Commit and Push**:
   ```bash
   git add apps/
   git commit -m "feat: add payment-service to cluster"
   git push origin main
   ```
   ArgoCD will immediately deploy your new microservice across the environments.
