#!/usr/bin/env bash
# Pause the local lab (stop cluster node containers, keep all data) when
# running Podman instead of Docker. Thin wrapper around with-podman.sh, which
# already shims docker -> podman for the existing stop-lab.sh (default mode:
# pause, not delete - see stop-lab.sh).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/with-podman.sh" stop "$@"
