#!/usr/bin/env bash
set -e

CLUSTER_NAME="dev-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "🚀 Starting DevOps Local Lab..."

# 1. Check Docker daemon
if ! docker info > /dev/null 2>&1; then
  echo "❌ Error: Docker is not running. Please start Docker Desktop first."
  exit 1
fi

# 2. Check if cluster exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "ℹ️  Cluster '${CLUSTER_NAME}' already exists."
  # Check if containers are stopped and start them
  STOPPED_NODES=$(docker ps -a -q -f name="${CLUSTER_NAME}" -f status=exited)
  if [ -n "${STOPPED_NODES}" ]; then
    echo "▶️  Resuming stopped cluster nodes..."
    docker start $(docker ps -a -q -f name="${CLUSTER_NAME}")
    echo "⏳ Waiting for cluster nodes to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=60s
  else
    echo "✅ Cluster '${CLUSTER_NAME}' is already running."
  fi
else
  echo "📦 Creating KinD cluster '${CLUSTER_NAME}' from kind-config.yaml..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${REPO_ROOT}/kind-config.yaml"
fi

# Set context
kubectl config use-context "kind-${CLUSTER_NAME}"

# 3. Ensure local gp3 StorageClass exists (maps AWS gp3 requests to local-path)
echo "💾 Ensuring local gp3 StorageClass exists..."
kubectl apply -f "${REPO_ROOT}/local-setup/gp3-storageclass.yaml" > /dev/null 2>&1

# 4. Ensure ArgoCD is installed using server-side apply
echo "🐙 Ensuring ArgoCD is installed..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=180s || true

# 5. Ensure local NGINX Ingress is installed for frontend/API routing
echo "🌐 Ensuring local NGINX Ingress Controller is installed..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml > /dev/null
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

# 6. Load locally built application images into KinD
echo "📦 Loading local application images into KinD..."
ECR_REGISTRY="602367507570.dkr.ecr.us-east-1.amazonaws.com"
for service in frontend order-service user-service; do
  image="${ECR_REGISTRY}/${service}:latest"
  if docker image inspect "${image}" > /dev/null 2>&1; then
    kind load docker-image "${image}" --name "${CLUSTER_NAME}" > /dev/null
    echo "  Loaded ${service}"
  else
    echo "  ⚠️  Missing ${image}; run ./scripts/build-and-push.sh first."
  fi
done

# 7. Restore the local-only Secret when the ignored file exists
if [ -f "${REPO_ROOT}/apps/local/app-secrets.env" ]; then
  echo "🔐 Restoring local app Secret..."
  kubectl create namespace development --dry-run=client -o yaml | kubectl apply -f - > /dev/null
  kubectl create secret generic app-secrets \
    --namespace development \
    --from-env-file="${REPO_ROOT}/apps/local/app-secrets.env" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
else
  echo "⚠️  Missing apps/local/app-secrets.env; services requiring MongoDB will not start."
fi

# 8. Restore the local Argo app-of-apps
echo "🚀 Applying local Argo root application..."
kubectl apply -f "${REPO_ROOT}/bootstrap/root-app-local.yaml" > /dev/null

# 9. Retrieve admin password
echo "🔑 Retrieving ArgoCD initial admin password..."
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "admin")

echo ""
echo "========================================================"
echo "🎉 DevOps Local Lab is READY!"
echo "========================================================"
echo "• Kubernetes Context: kind-${CLUSTER_NAME}"
echo "• Nodes:"
kubectl get nodes
echo ""
echo "• ArgoCD Username:    admin"
echo "• ArgoCD Password:    ${ARGOCD_PASS}"
echo ""
echo "• Frontend URL:       http://localhost"
echo ""
echo "To open ArgoCD in your browser, run in a terminal:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "  Then open https://localhost:8443"
echo ""
echo "To enable local frontend/API routing, install NGINX Ingress once:"
echo "  (already installed by this script)"
echo ""
echo "To deploy your local apps and monitoring stack via ArgoCD:"
echo "  (root-app-local is applied automatically by this script)"
echo "========================================================"
