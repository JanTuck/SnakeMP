#!/usr/bin/env bash

# Shared by start-docker.sh and refresh-docker.sh. This file is sourced; both
# callers enable strict mode before loading it.

SERVER_DIR="$SCRIPT_DIR/servers/zig"
SERVER_BINARY="$SERVER_DIR/snek-zig"

ZIG_COMMAND="${ZIG_BIN:-zig}"
CONTAINER_NAME="${SNEK_DOCKER_CONTAINER:-snakemp}"
HOST_PORT="${SNEK_DOCKER_PORT:-9687}"
CONTAINER_PORT=9687
SNAKEMP_IMAGE_LABEL="io.snakemp.runtime=true"
DEPLOY_LOCK_FILE="${SNEK_DOCKER_LOCK_FILE:-${TMPDIR:-/tmp}/snakemp-docker-${UID}.lock}"
DEPLOY_LOCK_WAIT_SECONDS="${SNEK_DOCKER_LOCK_WAIT_SECONDS:-300}"

acquire_deployment_lock() {
  command -v flock >/dev/null 2>&1 || {
    echo "flock is required to serialize SnakeMP Docker deployments." >&2
    echo "Install util-linux (for example: apt install util-linux) and retry." >&2
    return 127
  }

  case "$DEPLOY_LOCK_WAIT_SECONDS" in
    ''|*[!0-9]*)
      echo "SNEK_DOCKER_LOCK_WAIT_SECONDS must be a non-negative integer." >&2
      return 2
      ;;
  esac

  if [[ -z "$DEPLOY_LOCK_FILE" ]]; then
    echo "SNEK_DOCKER_LOCK_FILE must not be empty." >&2
    return 2
  fi

  if ! exec 9>"$DEPLOY_LOCK_FILE"; then
    echo "Unable to open the Docker deployment lock: $DEPLOY_LOCK_FILE" >&2
    echo "Set SNEK_DOCKER_LOCK_FILE to a writable path and retry." >&2
    return 1
  fi

  echo "Waiting up to ${DEPLOY_LOCK_WAIT_SECONDS}s for Docker deployment lock: $DEPLOY_LOCK_FILE"
  if ! flock --wait "$DEPLOY_LOCK_WAIT_SECONDS" 9; then
    echo "Another SnakeMP Docker deployment still holds $DEPLOY_LOCK_FILE." >&2
    echo "Wait for it to finish, or increase SNEK_DOCKER_LOCK_WAIT_SECONDS." >&2
    return 75
  fi
}

validate_docker_settings() {
  case "$HOST_PORT" in
    ''|*[!0-9]*)
      echo "SNEK_DOCKER_PORT must be an integer from 1 to 65535." >&2
      return 2
      ;;
  esac

  if ((HOST_PORT < 1 || HOST_PORT > 65535)); then
    echo "SNEK_DOCKER_PORT must be an integer from 1 to 65535." >&2
    return 2
  fi

  command -v "$ZIG_COMMAND" >/dev/null 2>&1 || {
    echo "Zig was not found. Install it or set ZIG_BIN to its executable." >&2
    return 127
  }
  command -v docker >/dev/null 2>&1 || {
    echo "Docker was not found on PATH." >&2
    return 127
  }
}

require_http_health_tool() {
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required for a health-gated Docker refresh." >&2
    return 127
  }
}

build_server_binary() {
  echo "Building the asset-embedded Zig server..."
  bash "$SERVER_DIR/build-assets.sh"
  (
    cd "$SERVER_DIR" || exit
    "$ZIG_COMMAND" build-exe -O ReleaseFast -fstrip src/main.zig \
      -femit-bin=snek-zig \
      --cache-dir .zig-cache \
      --global-cache-dir .zig-global-cache
  )

  # A scratch image can only execute a self-contained ELF.
  if command -v readelf >/dev/null 2>&1 && readelf -l "$SERVER_BINARY" | grep -q 'INTERP'; then
    echo "The Zig server is dynamically linked; refusing to package it in scratch." >&2
    return 1
  fi
}

build_runtime_image() {
  local image_name="$1"
  echo "Building runtime-only image $image_name..."
  docker build --tag "$image_name" "$SCRIPT_DIR"
}

container_exists() {
  docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

remove_runtime_container() {
  if container_exists; then
    docker rm --force "$CONTAINER_NAME" >/dev/null
  fi
}

run_runtime_container() {
  local image_name="$1"
  local -a docker_args=(
    run --detach --rm
    --name "$CONTAINER_NAME"
    --publish "$HOST_PORT:$CONTAINER_PORT"
    --read-only
    --cap-drop ALL
    --security-opt no-new-privileges
  )
  local variable_name

  for variable_name in \
    SNEK_MAX_PLAYERS \
    SNEK_MAX_PLAYERS_PER_LOBBY \
    SNEK_MAX_LOBBIES \
    SNEK_LOBBIES_PER_WORKER \
    SNEK_LOBBY_IDLE_MS \
    SNEK_DEBUG; do
    if [[ -v "$variable_name" ]]; then
      docker_args+=(--env "$variable_name")
    fi
  done

  docker_args+=(--env "PORT=$CONTAINER_PORT" "$image_name")
  docker "${docker_args[@]}"
}

wait_for_http_health() {
  local attempts="${SNEK_DOCKER_HEALTH_ATTEMPTS:-50}"
  local delay="${SNEK_DOCKER_HEALTH_DELAY:-0.1}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl --fail --silent --output /dev/null "http://127.0.0.1:$HOST_PORT/"; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

show_runtime_logs() {
  if container_exists; then
    docker logs "$CONTAINER_NAME" >&2 || true
  fi
}

prune_snakemp_dangling_images() {
  # docker image prune only considers dangling images by default. The label
  # filter further limits deletion to runtime images created from our
  # Dockerfile; unrelated local images are never considered.
  docker image prune --force --filter "label=$SNAKEMP_IMAGE_LABEL" >/dev/null
}
