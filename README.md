# GitOps Repository

This repository is the GitOps source of truth for deploying applications and platform components to Kubernetes.

## What is included

- Root application manifest for Argo CD or similar GitOps tooling
- Application manifests for AWS load balancer controller and external secrets integration
- Folder structure for managing cluster-level and application-level deployments

## Main folders

- apps/ — application and platform manifests applied by GitOps
- root-app.yaml — top-level application entry for GitOps reconciliation

## How it works

1. GitOps tooling watches this repository.
2. Changes pushed to the repo are detected automatically.
3. Kubernetes resources are reconciled to match the desired state in Git.

## Typical use

Use this repository to manage:

- application deployments
- ingress and networking controllers
- secret management integrations
- cluster add-ons and platform services

This is a clean way to keep infrastructure and application state version-controlled and auditable.

