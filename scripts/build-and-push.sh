#!/usr/bin/env bash
set -e

AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="602367507570"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
CLUSTER_NAME="dev-lab"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The application repo is checked out next to this one (../app), the same
# place the podman scripts build from. Override with APP_DIR=/path.
APP_DIR="${APP_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)/app}"

if [ ! -d "${APP_DIR}" ]; then
  echo "❌ Error: Could not find the application repo at ${APP_DIR} (set APP_DIR to override)"
  exit 1
fi

echo "========================================================"
echo "🛠️  Building Microservices Docker Images"
echo "========================================================"
echo "• App source:    ${APP_DIR}"
echo "• Target ECR:    ${ECR_REGISTRY}"
echo "========================================================"

SERVICES=("frontend" "order-service" "user-service" "notification-service")

# 1. Build Docker images
for svc in "${SERVICES[@]}"; do
  echo ""
  echo "🔨 Building ${svc}..."
  docker build -t "${ECR_REGISTRY}/${svc}:latest" -t "${svc}:latest" "${APP_DIR}/${svc}"
  echo "✅ Built ${svc}:latest successfully."
done

# 2. Load into KinD if cluster is running
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo ""
  echo "========================================================"
  echo "📦 Loading images into KinD cluster '${CLUSTER_NAME}'..."
  echo "========================================================"
  for svc in "${SERVICES[@]}"; do
    echo "🚚 Loading ${svc} into KinD nodes..."
    kind load docker-image "${ECR_REGISTRY}/${svc}:latest" --name "${CLUSTER_NAME}"
  done
  echo "✅ All images loaded into KinD! Local pods can run immediately."
fi

# 3. AWS ECR Login and Push
echo ""
echo "========================================================"
echo "☁️  Checking AWS ECR Login & Push"
echo "========================================================"

if aws sts get-caller-identity > /dev/null 2>&1; then
  echo "🔑 Authenticating Docker with AWS ECR (${ECR_REGISTRY})..."
  aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

  # ECR tags are immutable and the cloud overlays pin images by the app
  # commit's full SHA (the tag Jenkins uses), so push under that tag, never
  # `latest`. With uncommitted changes no commit describes the image, so
  # refuse rather than push a mislabelled one.
  if [ -n "$(git -C "${APP_DIR}" status --porcelain --untracked-files=no)" ]; then
    echo "❌ ${APP_DIR} has uncommitted changes. Commit them first: the image tag is the commit SHA."
    exit 1
  fi
  APP_SHA="$(git -C "${APP_DIR}" rev-parse HEAD)"
  echo "🚀 Pushing images to ECR as ${APP_SHA}..."
  for svc in "${SERVICES[@]}"; do
    echo "⬆️  Pushing ${svc}..."
    docker tag "${ECR_REGISTRY}/${svc}:latest" "${ECR_REGISTRY}/${svc}:${APP_SHA}"
    docker push "${ECR_REGISTRY}/${svc}:${APP_SHA}"
  done
  echo "🎉 All images pushed to AWS ECR. Pin them with tag ${APP_SHA} in apps/<env>/kustomization.yaml."
else
  echo "⚠️  AWS CLI is not currently authenticated."
  echo ""
  echo "To push to AWS ECR, please log in first by running:"
  echo "  1) aws configure"
  echo "     (Enter your AWS Access Key ID, Secret Access Key, and region '${AWS_REGION}')"
  echo ""
  echo "  2) Run this script again:"
  echo "     ./scripts/build-and-push.sh"
  echo ""
  echo "Note: The images are ALREADY built and loaded into KinD, so your local testing works right now!"
fi
