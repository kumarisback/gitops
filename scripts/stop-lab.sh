#!/usr/bin/env bash
set -e

CLUSTER_NAME="dev-lab"
MODE="${1:-pause}"

if [ "$MODE" = "clean" ] || [ "$MODE" = "--clean" ] || [ "$MODE" = "-c" ]; then
  echo "🧹 Deleting cluster '${CLUSTER_NAME}' completely (0 resources left)..."
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "✅ Cluster deleted. All CPU, RAM, and disk resources freed."
else
  echo "⏸️  Pausing cluster '${CLUSTER_NAME}' nodes to save CPU/battery..."
  RUNNING_NODES=$(docker ps -q -f name="${CLUSTER_NAME}")
  if [ -n "${RUNNING_NODES}" ]; then
    docker stop ${RUNNING_NODES}
    echo "✅ Cluster nodes paused. Zero CPU usage. All data and pods preserved."
    echo "To resume anytime, run: ./scripts/start-lab.sh"
  else
    echo "ℹ️  Cluster nodes are already stopped."
  fi
fi
