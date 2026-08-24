#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/servers/zig"
SERVER_BINARY="$SERVER_DIR/snek-zig"

ZIG_COMMAND="${ZIG_BIN:-zig}"
IMAGE_NAME="${SNEK_DOCKER_IMAGE:-snakemp:local}"
CONTAINER_NAME="${SNEK_DOCKER_CONTAINER:-snakemp}"
HOST_PORT="${SNEK_DOCKER_PORT:-9687}"
CONTAINER_PORT=9687

case "$HOST_PORT" in
  ''|*[!0-9]*)
    echo "SNEK_DOCKER_PORT must be an integer from 1 to 65535." >&2
    exit 2
    ;;
esac

if ((HOST_PORT < 1 || HOST_PORT > 65535)); then
  echo "SNEK_DOCKER_PORT must be an integer from 1 to 65535." >&2
  exit 2
fi

command -v "$ZIG_COMMAND" >/dev/null 2>&1 || {
  echo "Zig was not found. Install it or set ZIG_BIN to its executable." >&2
  exit 127
}
command -v docker >/dev/null 2>&1 || {
  echo "Docker was not found on PATH." >&2
  exit 127
}

echo "Building the asset-embedded Zig server..."
bash "$SERVER_DIR/build-assets.sh"
(
  cd "$SERVER_DIR"
  "$ZIG_COMMAND" build-exe -O ReleaseFast -fstrip src/main.zig \
    -femit-bin=snek-zig \
    --cache-dir .zig-cache \
    --global-cache-dir .zig-global-cache
)

# A scratch image can only execute a self-contained ELF. Fail here with a
# useful error if future build flags accidentally introduce a dynamic loader.
if command -v readelf >/dev/null 2>&1 && readelf -l "$SERVER_BINARY" | grep -q 'INTERP'; then
  echo "The Zig server is dynamically linked; refusing to package it in scratch." >&2
  exit 1
fi

echo "Building runtime-only image $IMAGE_NAME..."
docker build --tag "$IMAGE_NAME" "$SCRIPT_DIR"

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "Replacing existing container $CONTAINER_NAME..."
  docker rm --force "$CONTAINER_NAME" >/dev/null
fi

docker_args=(
  run --detach --rm
  --name "$CONTAINER_NAME"
  --publish "$HOST_PORT:$CONTAINER_PORT"
  --read-only
  --cap-drop ALL
  --security-opt no-new-privileges
)

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

docker_args+=(--env "PORT=$CONTAINER_PORT" "$IMAGE_NAME")
container_id="$(docker "${docker_args[@]}")"

if command -v curl >/dev/null 2>&1; then
  healthy=0
  for _ in {1..30}; do
    if curl --fail --silent --output /dev/null \
      "http://127.0.0.1:$HOST_PORT/"; then
      healthy=1
      break
    fi
    sleep 0.1
  done

  if ((healthy == 0)); then
    echo "Container failed its HTTP smoke check; recent logs:" >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
else
  echo "curl is unavailable; skipping the host-side HTTP smoke check."
fi

echo "SnakeMP is running at http://127.0.0.1:$HOST_PORT/"
echo "Container: $CONTAINER_NAME ($container_id)"
echo "Stop it with: docker stop $CONTAINER_NAME"
