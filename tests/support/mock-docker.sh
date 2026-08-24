#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="$MOCK_DOCKER_STATE"
mkdir -p "$STATE_DIR/tags"
printf '%s\n' "$*" >>"$STATE_DIR/docker.log"

resolve_image() {
  local reference="$1"
  if [[ -f "$STATE_DIR/tags/$reference" ]]; then
    cat "$STATE_DIR/tags/$reference"
  elif [[ "$reference" == img-* ]]; then
    printf '%s\n' "$reference"
  else
    return 1
  fi
}

case "${1:-} ${2:-}" in
  "container inspect")
    [[ -f "$STATE_DIR/container-image" ]] || exit 1
    if [[ " $* " == *" --format "* ]]; then
      cat "$STATE_DIR/container-image"
    fi
    ;;
  "rm --force")
    rm -f "$STATE_DIR/container-image"
    ;;
  "image ls")
    filter="${!#}"
    reference="${filter#reference=}"
    if [[ -n "${IMAGE_LS_FAIL_REFERENCE:-}" &&
          "$reference" == "$IMAGE_LS_FAIL_REFERENCE" ]]; then
      exit 70
    fi
    [[ -f "$STATE_DIR/tags/$reference" ]] || exit 0
    cat "$STATE_DIR/tags/$reference"
    ;;
  "image tag")
    source_reference="$3"
    destination_reference="$4"
    image_id="$(resolve_image "$source_reference")"
    printf '%s\n' "$image_id" >"$STATE_DIR/tags/$destination_reference"
    if [[ -n "${TAG_FAIL_AFTER_WRITE_DEST:-}" &&
          "$destination_reference" == "$TAG_FAIL_AFTER_WRITE_DEST" ]]; then
      exit 70
    fi
    ;;
  "image rm")
    reference="$3"
    tag_path="$STATE_DIR/tags/$reference"
    [[ -f "$tag_path" ]] || exit 1
    image_id="$(<"$tag_path")"
    matching_tags=0
    for possible_tag in "$STATE_DIR"/tags/*; do
      [[ -f "$possible_tag" ]] || continue
      if [[ "$(<"$possible_tag")" == "$image_id" ]]; then
        ((matching_tags += 1))
      fi
    done
    if [[ $matching_tags -eq 1 && -f "$STATE_DIR/container-image" &&
          "$(<"$STATE_DIR/container-image")" == "$image_id" ]]; then
      exit 1
    fi
    rm -f "$tag_path"
    ;;
  "image prune")
    [[ " $* " == *" --filter label=io.snakemp.runtime=true "* ]] || exit 2
    ;;
  "logs "*)
    printf '%s\n' "mock container log" >&2
    ;;
  "build "*)
    candidate_tag=""
    while (($# > 0)); do
      if [[ "$1" == "--tag" ]]; then
        candidate_tag="$2"
        break
      fi
      shift
    done
    [[ -n "$candidate_tag" ]] || exit 2
    printf '%s\n' "${BUILD_IMAGE_ID:-img-new}" >"$STATE_DIR/tags/$candidate_tag"
    [[ -z "${BUILD_FAIL_AFTER_TAG:-}" ]] || exit 70
    ;;
  "run "*)
    image_reference="${!#}"
    image_id="$(resolve_image "$image_reference")"
    if [[ -n "${RUN_FAIL_IMAGE_ID:-}" && "$image_id" == "$RUN_FAIL_IMAGE_ID" ]]; then
      exit 125
    fi
    printf '%s\n' "$image_id" >"$STATE_DIR/container-image"
    printf 'container-%s\n' "$image_id"
    ;;
  *)
    echo "unsupported mock Docker invocation: $*" >&2
    exit 2
    ;;
esac
