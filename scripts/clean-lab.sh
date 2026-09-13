#!/usr/bin/env bash
set -e

CLUSTER_NAME="dev-lab"

if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
  echo "This will permanently delete the KinD cluster '${CLUSTER_NAME}', including all Pods, Secrets, PVCs, and local data."
  printf "Type DELETE to continue: "
  read -r confirmation
  if [ "$confirmation" != "DELETE" ]; then
    echo "Cancelled."
    exit 0
  fi
fi

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Deleting KinD cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "Cluster deleted. Repository files and ignored local secret files were not changed."
else
  echo "KinD cluster '${CLUSTER_NAME}' does not exist."
fi
