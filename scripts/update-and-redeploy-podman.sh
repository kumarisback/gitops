#!/usr/bin/env bash
# Rebuild one or more service images after a code change, load them into the
# running KinD cluster, and restart the matching Deployment so the new code
# actually takes effect.
#
# Rebuilding alone isn't enough: Deployments use imagePullPolicy: IfNotPresent
# with a :latest tag (see apps/local/kustomization.yaml), so a running pod
# won't notice a same-tag image was rebuilt on its own - it has to be
# restarted after the new image is loaded.
#
# Usage:
#   ./scripts/update-and-redeploy-podman.sh                        # all 3 services
#   ./scripts/update-and-redeploy-podman.sh order-service           # just this one
#   ./scripts/update-and-redeploy-podman.sh order-service user-service
set -e

CLUSTER_NAME="dev-lab"
NAMESPACE="development"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="$(cd "${REPO_ROOT}/../app" && pwd)"
ECR_REGISTRY="602367507570.dkr.ecr.us-east-1.amazonaws.com"
ALL_SERVICES=(frontend order-service user-service)

if ! command -v podman > /dev/null 2>&1; then
  echo "❌ Error: podman not found on PATH."
  exit 1
fi

if ! podman info > /dev/null 2>&1; then
  echo "❌ Error: Podman is not running. Start it with: podman machine start"
  exit 1
fi

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "❌ Error: cluster '${CLUSTER_NAME}' doesn't exist. Run start-lab-podman.sh first."
  exit 1
fi

export KIND_EXPERIMENTAL_PROVIDER=podman

if [ "$#" -gt 0 ]; then
  SERVICES=("$@")
else
  SERVICES=("${ALL_SERVICES[@]}")
fi

for svc in "${SERVICES[@]}"; do
  if [ ! -d "${APP_DIR}/${svc}" ]; then
    echo "❌ Error: unknown service '${svc}' (no directory at ${APP_DIR}/${svc})"
    exit 1
  fi
done

for svc in "${SERVICES[@]}"; do
  echo "🔨 Rebuilding ${svc}..."
  podman build -t "${ECR_REGISTRY}/${svc}:latest" -t "${svc}:latest" "${APP_DIR}/${svc}"

  echo "📦 Loading ${svc} into KinD..."
  # kind's `load docker-image` doesn't correctly parse podman's inspect
  # output (kind 0.33.0 / podman 5.8.2) and fails with "not present locally"
  # even though the image exists - `load image-archive` avoids that check.
  tmpfile="$(mktemp -t "${svc}-image.tar")"
  podman save -o "${tmpfile}" "${ECR_REGISTRY}/${svc}:latest"
  kind load image-archive "${tmpfile}" --name "${CLUSTER_NAME}"
  rm -f "${tmpfile}"

  echo "🔄 Restarting ${svc} deployment..."
  kubectl rollout restart "deployment/${svc}" -n "${NAMESPACE}"
  kubectl rollout status "deployment/${svc}" -n "${NAMESPACE}" --timeout=120s

  echo "✅ ${svc} updated and redeployed."
  echo ""
done
