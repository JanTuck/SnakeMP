#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker-runtime.sh
source "$SCRIPT_DIR/docker-runtime.sh"

LOCAL_IMAGE="${SNEK_DOCKER_IMAGE:-snakemp:local}"
ROLLBACK_IMAGE="${SNEK_DOCKER_ROLLBACK_IMAGE:-snakemp:rollback}"
CANDIDATE_IMAGE="${SNEK_DOCKER_CANDIDATE_IMAGE:-snakemp:candidate-$(date +%s)-$$}"

acquire_deployment_lock

image_id() {
  local image_ids

  # `docker image inspect` uses the same non-zero status for "not found" and
  # daemon failures. Listing an exact reference instead gives us three states:
  # found (0), absent (1), and Docker failure (2), so safety checks fail closed.
  if ! image_ids="$(
    docker image ls --quiet --no-trunc --filter "reference=$1"
  )"; then
    return 2
  fi
  if [[ -z "$image_ids" ]]; then
    return 1
  fi
  printf '%s\n' "${image_ids%%$'\n'*}"
}

container_image_id() {
  docker container inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null
}

remove_image_tag() {
  docker image rm "$1" >/dev/null 2>&1
}

restore_image=""
cutover_started=0
candidate_tag_owned=0
completed=0
image_tags_snapshotted=0
original_local_exists=0
original_local_image=""
original_rollback_exists=0
original_rollback_image=""

validate_refresh_image_names() {
  if [[ -z "$LOCAL_IMAGE" || -z "$ROLLBACK_IMAGE" || -z "$CANDIDATE_IMAGE" ]]; then
    echo "Docker image names must not be empty." >&2
    return 2
  fi
  if [[ "$LOCAL_IMAGE" == "$ROLLBACK_IMAGE" ||
        "$CANDIDATE_IMAGE" == "$LOCAL_IMAGE" ||
        "$CANDIDATE_IMAGE" == "$ROLLBACK_IMAGE" ]]; then
    echo "Local, rollback, and candidate Docker image names must be distinct." >&2
    return 2
  fi
}

validate_rollback_settings() {
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

  command -v docker >/dev/null 2>&1 || {
    echo "Docker was not found on PATH." >&2
    return 127
  }
}

ensure_candidate_tag_is_available() {
  local status

  if image_id "$CANDIDATE_IMAGE" >/dev/null; then
    echo "Candidate image tag already exists: $CANDIDATE_IMAGE" >&2
    echo "Choose another SNEK_DOCKER_CANDIDATE_IMAGE or remove it explicitly." >&2
    return 1
  else
    status=$?
    if ((status != 1)); then
      echo "Unable to verify that candidate tag $CANDIDATE_IMAGE is available." >&2
      return "$status"
    fi
  fi
}

prune_failed_runtime_images() {
  if ! prune_snakemp_dangling_images; then
    echo "Warning: unable to prune dangling SnakeMP runtime images." >&2
  fi
}

snapshot_managed_image_tags() {
  local status

  if original_local_image="$(image_id "$LOCAL_IMAGE")"; then
    original_local_exists=1
  else
    status=$?
    if ((status != 1)); then
      echo "Unable to snapshot Docker image tag $LOCAL_IMAGE." >&2
      return "$status"
    fi
  fi
  if original_rollback_image="$(image_id "$ROLLBACK_IMAGE")"; then
    original_rollback_exists=1
  else
    status=$?
    if ((status != 1)); then
      echo "Unable to snapshot Docker image tag $ROLLBACK_IMAGE." >&2
      return "$status"
    fi
  fi
  image_tags_snapshotted=1
}

restore_managed_image_tag() {
  local image_name="$1"
  local originally_existed="$2"
  local original_image="$3"

  if ((originally_existed == 1)); then
    if ! docker image tag "$original_image" "$image_name" >/dev/null; then
      echo "Warning: unable to restore Docker image tag $image_name." >&2
      return 1
    fi
    return 0
  fi

  if image_id "$image_name" >/dev/null; then
    if ! remove_image_tag "$image_name"; then
      echo "Warning: unable to remove newly-created Docker image tag $image_name." >&2
      return 1
    fi
  else
    local status=$?
    if ((status != 1)); then
      echo "Warning: unable to inspect Docker image tag $image_name during restore." >&2
      return "$status"
    fi
  fi
}

restore_managed_image_tags() {
  local restore_failed=0

  if ((image_tags_snapshotted == 0)); then
    return
  fi
  if ! restore_managed_image_tag \
    "$LOCAL_IMAGE" "$original_local_exists" "$original_local_image"; then
    restore_failed=1
  fi
  if ! restore_managed_image_tag \
    "$ROLLBACK_IMAGE" "$original_rollback_exists" "$original_rollback_image"; then
    restore_failed=1
  fi
  return "$restore_failed"
}

restore_after_failure() {
  local failed_status="$1"
  local managed_tags_restored=1

  trap - EXIT INT TERM

  if ((cutover_started == 1)); then
    remove_runtime_container || true

    # Docker will not remove an image's last tag while a container still uses
    # it. Remove the failed container first, then drop only our unique
    # candidate tag. Label-filtered pruning below handles the dangling image.
    if ((candidate_tag_owned == 1)); then
      if ! remove_image_tag "$CANDIDATE_IMAGE"; then
        echo "Warning: unable to remove failed candidate tag $CANDIDATE_IMAGE." >&2
      fi
    fi

    # A refresh changes two stable tags. Restore both snapshots before
    # restarting the prior image so an aborted promotion cannot silently
    # consume an older, known-good rollback.
    if ! restore_managed_image_tags; then
      managed_tags_restored=0
      echo "Stable Docker tags were not fully restored; skipping image prune." >&2
    fi
  fi

  if ((cutover_started == 1)) && [[ -n "$restore_image" ]]; then
    echo "Refresh failed; restoring the previous runtime image..." >&2
    if run_runtime_container "$restore_image" >/dev/null && wait_for_http_health; then
      echo "Previous SnakeMP container restored at http://127.0.0.1:$HOST_PORT/." >&2
    else
      echo "Automatic restore failed; inspect Docker logs before retrying." >&2
      show_runtime_logs
    fi
  elif ((candidate_tag_owned == 1)); then
    # A build failure before cutover or a first deployment without a previous
    # image can still leave a candidate tag behind.
    if ! remove_image_tag "$CANDIDATE_IMAGE"; then
      echo "Warning: unable to remove failed candidate tag $CANDIDATE_IMAGE." >&2
    fi
  fi

  if ((managed_tags_restored == 1 &&
        (candidate_tag_owned == 1 || cutover_started == 1))); then
    prune_failed_runtime_images
  fi
  exit "$failed_status"
}

on_exit() {
  local status=$?
  if ((completed == 0)); then
    restore_after_failure "$status"
  fi
}

normal_refresh() {
  local current_id=""
  local container_id

  validate_docker_settings
  validate_refresh_image_names
  require_http_health_tool
  ensure_candidate_tag_is_available
  snapshot_managed_image_tags

  if container_exists; then
    current_id="$(container_image_id)"
  elif ((original_local_exists == 1)); then
    current_id="$original_local_image"
  elif ((original_rollback_exists == 1)); then
    current_id="$original_rollback_image"
  fi

  # Build while the existing container remains online.
  build_server_binary
  # The candidate tag was proven absent, so cleanup owns it from the moment
  # the build starts. This also covers a lost Docker response after tagging.
  candidate_tag_owned=1
  build_runtime_image "$CANDIDATE_IMAGE"

  restore_image="$current_id"

  cutover_started=1
  remove_runtime_container
  container_id="$(run_runtime_container "$CANDIDATE_IMAGE")"

  if ! wait_for_http_health; then
    echo "Candidate failed its HTTP health check; recent logs:" >&2
    show_runtime_logs
    return 1
  fi

  # Neither stable tag changes until the candidate is serving traffic.
  if [[ -n "$current_id" ]]; then
    docker image tag "$current_id" "$ROLLBACK_IMAGE"
    echo "Saved the current runtime as $ROLLBACK_IMAGE."
  fi
  docker image tag "$CANDIDATE_IMAGE" "$LOCAL_IMAGE"
  completed=1
  if ! remove_image_tag "$CANDIDATE_IMAGE"; then
    echo "Warning: unable to remove promoted candidate tag $CANDIDATE_IMAGE." >&2
  fi
  prune_failed_runtime_images

  echo "SnakeMP refresh succeeded at http://127.0.0.1:$HOST_PORT/."
  echo "Container: $CONTAINER_NAME ($container_id)"
  if image_id "$ROLLBACK_IMAGE" >/dev/null; then
    echo "Rollback: ./refresh-docker.sh rollback"
  else
    echo "No rollback exists yet (this was the first managed deployment)."
  fi
}

rollback_refresh() {
  local rollback_id
  local current_id=""
  local container_id

  # Rollback consumes an existing image and must remain available even when a
  # Zig toolchain is not installed on the recovery host.
  validate_rollback_settings
  validate_refresh_image_names
  require_http_health_tool

  if rollback_id="$(image_id "$ROLLBACK_IMAGE")"; then
    :
  else
    local status=$?
    if ((status == 1)); then
      echo "No rollback image exists at $ROLLBACK_IMAGE." >&2
    else
      echo "Unable to inspect rollback image $ROLLBACK_IMAGE." >&2
    fi
    return "$status"
  fi
  snapshot_managed_image_tags

  if container_exists; then
    current_id="$(container_image_id)"
  elif ((original_local_exists == 1)); then
    current_id="$original_local_image"
  fi

  restore_image="$current_id"
  cutover_started=1
  remove_runtime_container
  container_id="$(run_runtime_container "$rollback_id")"

  if ! wait_for_http_health; then
    echo "Rollback image failed its HTTP health check; recent logs:" >&2
    show_runtime_logs
    return 1
  fi

  # Keep the proven rollback image tagged while making it the default local
  # image. The displaced failed image becomes dangling and is removed only if
  # it bears SnakeMP's runtime label.
  docker image tag "$rollback_id" "$LOCAL_IMAGE"
  completed=1
  prune_failed_runtime_images

  echo "SnakeMP rollback succeeded at http://127.0.0.1:$HOST_PORT/."
  echo "Container: $CONTAINER_NAME ($container_id)"
}

handle_signal() {
  exit "$1"
}

trap on_exit EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

case "${1:-refresh}" in
  refresh)
    normal_refresh
    ;;
  rollback)
    rollback_refresh
    ;;
  *)
    echo "Usage: $0 [refresh|rollback]" >&2
    exit 2
    ;;
esac
