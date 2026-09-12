#!/usr/bin/env bash
set -e

AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="602367507570"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
CLUSTER_NAME="dev-lab"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEVOPS_DIR="${WORKSPACE_ROOT}/Devops"

if [ ! -d "${DEVOPS_DIR}" ]; then
  echo "❌ Error: Could not find Devops directory at ${DEVOPS_DIR}"
  exit 1
fi

echo "========================================================"
echo "🛠️  Building Microservices Docker Images"
echo "========================================================"
echo "• Devops source: ${DEVOPS_DIR}"
echo "• Target ECR:    ${ECR_REGISTRY}"
echo "========================================================"

SERVICES=("frontend" "order-service" "user-service")

# 1. Build Docker images
for svc in "${SERVICES[@]}"; do
  echo ""
  echo "🔨 Building ${svc}..."
  docker build -t "${ECR_REGISTRY}/${svc}:latest" -t "${svc}:latest" "${DEVOPS_DIR}/${svc}"
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

  echo "🚀 Pushing images to ECR..."
  for svc in "${SERVICES[@]}"; do
    echo "⬆️  Pushing ${svc}..."
    docker push "${ECR_REGISTRY}/${svc}:latest"
  done
  echo "🎉 All images pushed to AWS ECR successfully!"
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
