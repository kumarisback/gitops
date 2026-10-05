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
    # Right after a restart the API server answers "Forbidden" until its
    # authorizer has loaded, so retry rather than stop on the first error.
    for attempt in $(seq 1 12); do
      if kubectl --context "kind-${CLUSTER_NAME}" wait --for=condition=Ready nodes --all --timeout=60s > /dev/null 2>&1; then
        break
      fi
      if [ "${attempt}" -eq 12 ]; then
        echo "❌ Cluster nodes didn't become ready; check: kubectl --context kind-${CLUSTER_NAME} get nodes"
        exit 1
      fi
      sleep 10
    done
  else
    echo "✅ Cluster '${CLUSTER_NAME}' is already running."
  fi
else
  echo "📦 Creating KinD cluster '${CLUSTER_NAME}' from kind-config.yaml..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${REPO_ROOT}/kind-config.yaml"
fi

# Set context
kubectl config use-context "kind-${CLUSTER_NAME}"

# Download a remote manifest with retries and print the local path.
# kubectl -f URL has no retry, and behind corporate TLS inspection
# raw.githubusercontent.com often times out on the first attempt.
fetch_manifest() {
  local out
  out="$(mktemp)"
  curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --max-time 180 -o "${out}" "$1"
  echo "${out}"
}

# 3. Ensure local gp3 StorageClass exists (maps AWS gp3 requests to local-path)
echo "💾 Ensuring local gp3 StorageClass exists..."
kubectl apply -f "${REPO_ROOT}/local-setup/gp3-storageclass.yaml" > /dev/null 2>&1

# 4. Ensure ArgoCD is installed using server-side apply
echo "🐙 Ensuring ArgoCD is installed..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Same ArgoCD version as the EKS clusters (argo-cd chart 7.7.15 in the tf
# repo), so the lab behaves like them; "stable" changed under us.
ARGOCD_VERSION="v2.13.3"
ARGOCD_MANIFEST="$(fetch_manifest "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml")"
kubectl apply -n argocd --server-side --force-conflicts -f "${ARGOCD_MANIFEST}"

echo "⏳ Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=180s || true

# 5. Ingress controller for frontend/API routing: Traefik (values in
#    local-setup/traefik-values.yaml). Labs created before the switch still
#    run the retired ingress-nginx, which holds host ports 80/443 and leaves a
#    cluster-wide admission webhook that would reject Ingress changes once
#    its pods are gone, so remove all of it from the manifest it came from.
INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml"
if kubectl get namespace ingress-nginx > /dev/null 2>&1; then
  echo "🧹 Removing the retired ingress-nginx controller (replaced by Traefik)..."
  kubectl delete -f "$(fetch_manifest "${INGRESS_NGINX_MANIFEST}")" --ignore-not-found --wait=true > /dev/null
fi
TRAEFIK_CHART_VERSION="41.6.1"
echo "🌐 Ensuring the Traefik ingress controller is installed..."
helm upgrade --install traefik traefik --repo https://traefik.github.io/charts \
  --version "${TRAEFIK_CHART_VERSION}" -n traefik --create-namespace \
  -f "${REPO_ROOT}/local-setup/traefik-values.yaml" --wait --timeout 5m > /dev/null

# 6. Load locally built application images into KinD. start-lab-podman.sh
#    sets SKIP_IMAGE_LOAD=1 because it has already loaded them with
#    `kind load image-archive` (`kind load docker-image` fails under podman).
#    A failed load only warns: with set -e it used to abort before the
#    Secret and root app below were created.
ECR_REGISTRY="602367507570.dkr.ecr.us-east-1.amazonaws.com"
if [ "${SKIP_IMAGE_LOAD:-0}" = "1" ]; then
  echo "⏭️  Skipping image load (SKIP_IMAGE_LOAD=1)."
else
  echo "📦 Loading local application images into KinD..."
  for service in frontend order-service user-service; do
    image="${ECR_REGISTRY}/${service}:latest"
    if docker image inspect "${image}" > /dev/null 2>&1; then
      if kind load docker-image "${image}" --name "${CLUSTER_NAME}" > /dev/null; then
        echo "  Loaded ${service}"
      else
        echo "  ⚠️  Could not load ${image}; under podman use ./scripts/start-lab-podman.sh."
      fi
    else
      echo "  ⚠️  Missing ${image}; run ./scripts/build-and-push.sh first."
    fi
  done
fi

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

# 8. Restore the local Argo app-of-apps. start-lab-podman.sh sets
#    SKIP_ROOT_APP=1 because it deploys with sync-local-stack.rb instead,
#    and an auto-syncing root app would fight that script.
if [ "${SKIP_ROOT_APP:-0}" = "1" ]; then
  echo "⏭️  Skipping local Argo root application (SKIP_ROOT_APP=1)."
else
  # Sync the branch that's checked out (it must be pushed), unless
  # LAB_REVISION names another branch, tag or commit.
  LAB_REVISION="${LAB_REVISION:-$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)}"
  echo "🚀 Applying local Argo root application (revision ${LAB_REVISION})..."
  sed -E "s#^([[:space:]]*(targetRevision|value)): HEAD$#\1: ${LAB_REVISION}#" \
    "${REPO_ROOT}/bootstrap/root-app-local.yaml" | kubectl apply -f - > /dev/null
fi

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
if [ "${SKIP_ROOT_APP:-0}" = "1" ]; then
  echo "Local apps and monitoring stack: deployed by scripts/sync-local-stack.rb"
else
  echo "To deploy your local apps and monitoring stack via ArgoCD:"
  echo "  (root-app-local is applied automatically by this script)"
fi
echo "========================================================"
