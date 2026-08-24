#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker-runtime.sh
source "$SCRIPT_DIR/docker-runtime.sh"

IMAGE_NAME="${SNEK_DOCKER_IMAGE:-snakemp:local}"

acquire_deployment_lock
validate_docker_settings
build_server_binary
build_runtime_image "$IMAGE_NAME"

if container_exists; then
  echo "Replacing existing container $CONTAINER_NAME..."
  remove_runtime_container
fi

container_id="$(run_runtime_container "$IMAGE_NAME")"

if command -v curl >/dev/null 2>&1; then
  if ! wait_for_http_health; then
    echo "Container failed its HTTP smoke check; recent logs:" >&2
    show_runtime_logs
    remove_runtime_container >/dev/null 2>&1 || true
    exit 1
  fi
else
  echo "curl is unavailable; skipping the host-side HTTP smoke check."
fi

echo "SnakeMP is running at http://127.0.0.1:$HOST_PORT/"
echo "Container: $CONTAINER_NAME ($container_id)"
echo "Stop it with: docker stop $CONTAINER_NAME"
