#!/usr/bin/env bash
# Podman-native "start the local lab" script.
#
# Unlike scripts/with-podman.sh start (which just shims docker -> podman and
# runs the existing start-lab.sh), this one also builds the three service
# images with `podman build` and loads them into the kind cluster first, so
# a single run gets you from nothing to a fully running lab - no separate
# build-and-push step, and no "Missing image" warnings.
set -e

CLUSTER_NAME="dev-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="$(cd "${REPO_ROOT}/../app" && pwd)"
ECR_REGISTRY="602367507570.dkr.ecr.us-east-1.amazonaws.com"
SERVICES=(frontend order-service user-service)

if ! command -v podman > /dev/null 2>&1; then
  echo "❌ Error: podman not found on PATH."
  exit 1
fi

if ! podman info > /dev/null 2>&1; then
  echo "❌ Error: Podman is not running. Start it with: podman machine start"
  exit 1
fi

export KIND_EXPERIMENTAL_PROVIDER=podman

echo "🔨 Building service images with podman..."
for svc in "${SERVICES[@]}"; do
  echo "  Building ${svc}..."
  podman build -t "${ECR_REGISTRY}/${svc}:latest" -t "${svc}:latest" "${APP_DIR}/${svc}"
done

# If the cluster doesn't exist yet, create it now so `kind load` below has
# somewhere to load into (start-lab.sh, run afterwards, will just find it
# already there and skip straight past cluster creation).
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "📦 Creating KinD cluster '${CLUSTER_NAME}' from kind-config.yaml..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${REPO_ROOT}/kind-config.yaml"
fi

echo "📦 Loading images into KinD..."
# kind's `load docker-image` subcommand checks image presence in a way that
# doesn't correctly parse podman's inspect output (kind 0.33.0 / podman
# 5.8.2), and fails with "not present locally" even though the image exists.
# `load image-archive` sidesteps that check entirely by taking a tarball.
for svc in "${SERVICES[@]}"; do
  tmpfile="$(mktemp -t "${svc}-image.tar")"
  podman save -o "${tmpfile}" "${ECR_REGISTRY}/${svc}:latest"
  kind load image-archive "${tmpfile}" --name "${CLUSTER_NAME}"
  rm -f "${tmpfile}"
  echo "  Loaded ${svc}"
done

echo "▶️  Handing off to start-lab.sh for the rest of the setup..."
exec "${SCRIPT_DIR}/with-podman.sh" start
