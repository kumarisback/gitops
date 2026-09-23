#!/usr/bin/env bash
# Run the existing docker-based lab scripts (start-lab.sh, stop-lab.sh,
# clean-lab.sh, build-and-push.sh) unmodified, against Podman instead of
# Docker.
#
# Those scripts call the literal `docker` command; Podman on macOS doesn't
# install a `docker` binary by default. This wrapper puts a `docker -> podman`
# symlink at the front of PATH for the duration of one script's run (the same
# trick the official podman-docker compatibility package uses), and sets
# KIND_EXPERIMENTAL_PROVIDER=podman so `kind` itself provisions cluster nodes
# via Podman too - see https://kind.sigs.k8s.io/docs/user/rootless/#podman
#
# Usage:
#   ./scripts/with-podman.sh start                  # runs start-lab.sh
#   ./scripts/with-podman.sh stop [clean]           # runs stop-lab.sh
#   ./scripts/with-podman.sh clean [--yes]          # runs clean-lab.sh
#   ./scripts/with-podman.sh build-and-push         # runs build-and-push.sh
#
# Requires `podman machine start` to already be running, plus `kind` and
# `kubectl` on PATH (not installed by this script).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v podman > /dev/null 2>&1; then
  echo "❌ Error: podman not found on PATH."
  exit 1
fi

if ! podman info > /dev/null 2>&1; then
  echo "❌ Error: Podman is not running. Start it with: podman machine start"
  exit 1
fi

TARGET="${1:-}"
shift || true

case "${TARGET}" in
  start)          REAL_SCRIPT="${SCRIPT_DIR}/start-lab.sh" ;;
  stop)           REAL_SCRIPT="${SCRIPT_DIR}/stop-lab.sh" ;;
  clean)          REAL_SCRIPT="${SCRIPT_DIR}/clean-lab.sh" ;;
  build-and-push) REAL_SCRIPT="${SCRIPT_DIR}/build-and-push.sh" ;;
  *)
    echo "Usage: $0 {start|stop|clean|build-and-push} [args...]"
    exit 1
    ;;
esac

echo "🦭 Running '${TARGET}' with Podman (KIND_EXPERIMENTAL_PROVIDER=podman)..."

SHIM_DIR="$(mktemp -d)"
trap 'rm -rf "${SHIM_DIR}"' EXIT
ln -s "$(command -v podman)" "${SHIM_DIR}/docker"

export PATH="${SHIM_DIR}:${PATH}"
export KIND_EXPERIMENTAL_PROVIDER=podman

exec "${REAL_SCRIPT}" "$@"
