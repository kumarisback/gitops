# GitOps Repository (ArgoCD)

This repository is the GitOps source of truth for all Kubernetes workloads, platform add-ons, and microservices. It utilizes a highly scalable **App-of-Apps** pattern.

## Architecture Structure

```text
Gitops/
├── bootstrap/
│   ├── root-app.yaml         # The master application that ArgoCD tracks first
│   └── projects/             # App-of-Apps definitions (dev.yaml, prod.yaml, platform.yaml)
│
├── platform/                 # Cluster add-ons (External Secrets Operator, AWS LB Controller)
│
└── apps/                     # Your actual microservices
    ├── dev/
    ├── staging/
    └── prod/
```

## How It Works (The Automation Bridge)

This repository works in tandem with our Terraform repository:
1. Terraform provisions the EKS cluster and automatically installs ArgoCD.
2. Terraform applies `bootstrap/root-app.yaml` to the cluster.
3. ArgoCD reads `root-app.yaml`, which tells it to look at the `bootstrap/projects/` folder.
4. ArgoCD deploys the `platform` (installing the External Secrets Operator) and your environments (`dev`, `staging`, `prod`).
5. **External Secrets Operator** securely reaches out to AWS Systems Manager (SSM) to grab the RDS endpoints created by Terraform, injecting them directly into your microservices.

## End-to-End Deployment Flow

Because we have a fully automated pipeline, **you do not need to run kubectl commands manually.**

### 1. Initial Cluster Bootstrap
Run your Jenkins pipeline for the `terraform` repository. Once Terraform says "Apply Complete", ArgoCD is alive and pulling from this GitOps repo instantly.

### 2. Deploying a New Microservice or Update
To deploy a new version of your application or add a new service:
1. Update your Kubernetes manifests or Kustomize files in `apps/dev/` (e.g., updating a docker image tag).
2. Commit and push your changes:
   ```bash
   git add apps/dev/
   git commit -m "feat: update frontend image to v2"
   git push origin main
   ```
3. **That's it.** ArgoCD will detect the git push within 3 minutes (or instantly via webhooks) and automatically synchronize the cluster state. Your pods will cycle, and the new version will be live.
