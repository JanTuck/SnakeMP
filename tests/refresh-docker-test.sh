#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tag_file() {
  local case_dir="$1"
  local image_name="$2"
  printf '%s/state/tags/%s' "$case_dir" "$image_name"
}

seed_tag() {
  local case_dir="$1"
  local image_name="$2"
  local image_id="$3"
  printf '%s\n' "$image_id" >"$(tag_file "$case_dir" "$image_name")"
}

seed_container() {
  local case_dir="$1"
  local image_id="$2"
  printf '%s\n' "$image_id" >"$case_dir/state/container-image"
}

assert_tag() {
  local case_dir="$1"
  local image_name="$2"
  local expected_id="$3"
  local actual_id

  [[ -f "$(tag_file "$case_dir" "$image_name")" ]] ||
    fail "expected image tag $image_name"
  actual_id="$(<"$(tag_file "$case_dir" "$image_name")")"
  [[ "$actual_id" == "$expected_id" ]] ||
    fail "expected $image_name=$expected_id, got $actual_id"
}

assert_no_tag() {
  local case_dir="$1"
  local image_name="$2"
  [[ ! -e "$(tag_file "$case_dir" "$image_name")" ]] ||
    fail "unexpected image tag $image_name"
}

assert_container() {
  local case_dir="$1"
  local expected_id="$2"
  local actual_id

  [[ -f "$case_dir/state/container-image" ]] || fail "expected a running container"
  actual_id="$(<"$case_dir/state/container-image")"
  [[ "$actual_id" == "$expected_id" ]] ||
    fail "expected container image $expected_id, got $actual_id"
}

assert_log_contains() {
  local case_dir="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$case_dir/state/docker.log" ||
    fail "Docker log did not contain: $expected"
}

assert_log_excludes() {
  local case_dir="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$case_dir/state/docker.log"; then
    fail "Docker log unexpectedly contained: $unexpected"
  fi
}

assert_log_order() {
  local case_dir="$1"
  local first="$2"
  local second="$3"
  local first_line
  local second_line

  first_line="$(grep -Fnm1 -- "$first" "$case_dir/state/docker.log" | cut -d: -f1)"
  second_line="$(grep -Fnm1 -- "$second" "$case_dir/state/docker.log" | cut -d: -f1)"
  [[ -n "$first_line" && -n "$second_line" && first_line -lt second_line ]] ||
    fail "expected '$first' before '$second'"
}

setup_case() {
  local name="$1"
  local case_dir="$TEST_ROOT/$name"

  mkdir -p "$case_dir/bin" "$case_dir/servers/zig" "$case_dir/state/tags"
  cp "$REPO_DIR/start-docker.sh" "$REPO_DIR/refresh-docker.sh" \
    "$REPO_DIR/docker-runtime.sh" "$case_dir/"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$case_dir/servers/zig/build-assets.sh"
  chmod +x "$case_dir/servers/zig/build-assets.sh"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': > snek-zig' >"$case_dir/bin/zig"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$case_dir/bin/readelf"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$case_dir/bin/sleep"

  # These single quotes intentionally defer expansion to the generated mock.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'container_image=""' \
    'if [[ -f "$MOCK_DOCKER_STATE/container-image" ]]; then' \
    '  container_image="$(<"$MOCK_DOCKER_STATE/container-image")"' \
    'fi' \
    'if [[ -n "${HEALTH_FAIL_IMAGE_ID:-}" && "$container_image" == "$HEALTH_FAIL_IMAGE_ID" ]]; then' \
    '  exit 22' \
    'fi' \
    'exit 0' >"$case_dir/bin/curl"

  cp "$REPO_DIR/tests/support/mock-docker.sh" "$case_dir/bin/docker"
  chmod +x "$case_dir/bin/"*
  printf '%s\n' "$case_dir"
}

run_refresh() {
  local case_dir="$1"
  shift
  env \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    MOCK_DOCKER_STATE="$case_dir/state" \
    BUILD_IMAGE_ID="${BUILD_IMAGE_ID:-img-new}" \
    BUILD_FAIL_AFTER_TAG="${BUILD_FAIL_AFTER_TAG:-}" \
    HEALTH_FAIL_IMAGE_ID="${HEALTH_FAIL_IMAGE_ID:-}" \
    IMAGE_LS_FAIL_REFERENCE="${IMAGE_LS_FAIL_REFERENCE:-}" \
    TAG_FAIL_AFTER_WRITE_DEST="${TAG_FAIL_AFTER_WRITE_DEST:-}" \
    SNEK_DOCKER_CANDIDATE_IMAGE="snakemp:test-candidate" \
    SNEK_DOCKER_HEALTH_ATTEMPTS=1 \
    SNEK_DOCKER_HEALTH_DELAY=0 \
    "$@" \
    "$case_dir/refresh-docker.sh" refresh
}

run_rollback() {
  local case_dir="$1"
  shift
  env \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    MOCK_DOCKER_STATE="$case_dir/state" \
    HEALTH_FAIL_IMAGE_ID="${HEALTH_FAIL_IMAGE_ID:-}" \
    SNEK_DOCKER_CANDIDATE_IMAGE="snakemp:test-candidate" \
    SNEK_DOCKER_HEALTH_ATTEMPTS=1 \
    SNEK_DOCKER_HEALTH_DELAY=0 \
    "$@" \
    "$case_dir/refresh-docker.sh" rollback
}

run_start() {
  local case_dir="$1"
  shift
  env \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    MOCK_DOCKER_STATE="$case_dir/state" \
    BUILD_IMAGE_ID="${BUILD_IMAGE_ID:-img-new}" \
    SNEK_DOCKER_HEALTH_ATTEMPTS=1 \
    SNEK_DOCKER_HEALTH_DELAY=0 \
    "$@" \
    "$case_dir/start-docker.sh"
}

test_successful_refresh() {
  local case_dir
  case_dir="$(setup_case success)"
  seed_tag "$case_dir" snakemp:local img-old
  seed_container "$case_dir" img-old

  BUILD_IMAGE_ID=img-new run_refresh "$case_dir" >"$case_dir/output" 2>&1 ||
    fail "successful refresh returned failure"

  assert_tag "$case_dir" snakemp:local img-new
  assert_tag "$case_dir" snakemp:rollback img-old
  assert_no_tag "$case_dir" snakemp:test-candidate
  assert_container "$case_dir" img-new
  assert_log_order "$case_dir" "build --tag snakemp:test-candidate" "rm --force snakemp"
  assert_log_order "$case_dir" "run --detach" "image tag snakemp:test-candidate snakemp:local"
  assert_log_contains "$case_dir" "image prune --force --filter label=io.snakemp.runtime=true"
}

test_failed_candidate_restores_previous_image() {
  local case_dir
  local status
  case_dir="$(setup_case failed-candidate)"
  seed_tag "$case_dir" snakemp:local img-old
  seed_container "$case_dir" img-old

  set +e
  BUILD_IMAGE_ID=img-new HEALTH_FAIL_IMAGE_ID=img-new \
    run_refresh "$case_dir" >"$case_dir/output" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail "unhealthy candidate unexpectedly succeeded"
  assert_tag "$case_dir" snakemp:local img-old
  assert_no_tag "$case_dir" snakemp:rollback
  assert_no_tag "$case_dir" snakemp:test-candidate
  assert_container "$case_dir" img-old
  assert_log_order "$case_dir" "rm --force snakemp" "image rm snakemp:test-candidate"
  assert_log_order "$case_dir" "image rm snakemp:test-candidate" "--env PORT=9687 img-old"
  grep -Fq "Previous SnakeMP container restored" "$case_dir/output" ||
    fail "failed refresh did not report automatic restoration"
}

test_failed_candidate_preserves_existing_rollback() {
  local case_dir
  local status
  case_dir="$(setup_case preserved-rollback)"
  seed_tag "$case_dir" snakemp:local img-current
  seed_tag "$case_dir" snakemp:rollback img-known-good
  seed_container "$case_dir" img-current

  set +e
  BUILD_IMAGE_ID=img-new HEALTH_FAIL_IMAGE_ID=img-new \
    run_refresh "$case_dir" >"$case_dir/output" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail "unhealthy candidate unexpectedly succeeded"
  assert_tag "$case_dir" snakemp:local img-current
  assert_tag "$case_dir" snakemp:rollback img-known-good
  assert_no_tag "$case_dir" snakemp:test-candidate
  assert_container "$case_dir" img-current
}

test_rollback_needs_no_zig_and_promotes_verified_image() {
  local case_dir
  case_dir="$(setup_case rollback)"
  seed_tag "$case_dir" snakemp:local img-bad
  seed_tag "$case_dir" snakemp:rollback img-good
  seed_container "$case_dir" img-bad

  run_rollback "$case_dir" ZIG_BIN=missing-zig >"$case_dir/output" 2>&1 ||
    fail "rollback returned failure"

  assert_tag "$case_dir" snakemp:local img-good
  assert_tag "$case_dir" snakemp:rollback img-good
  assert_container "$case_dir" img-good
  assert_log_excludes "$case_dir" "build --tag"
  assert_log_order "$case_dir" "run --detach" "image tag img-good snakemp:local"
  assert_log_contains "$case_dir" "image prune --force --filter label=io.snakemp.runtime=true"
}

test_unhealthy_rollback_restores_current_image() {
  local case_dir
  local status
  case_dir="$(setup_case failed-rollback)"
  seed_tag "$case_dir" snakemp:local img-current
  seed_tag "$case_dir" snakemp:rollback img-unhealthy
  seed_container "$case_dir" img-current

  set +e
  HEALTH_FAIL_IMAGE_ID=img-unhealthy \
    run_rollback "$case_dir" ZIG_BIN=missing-zig >"$case_dir/output" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail "unhealthy rollback unexpectedly succeeded"
  assert_tag "$case_dir" snakemp:local img-current
  assert_tag "$case_dir" snakemp:rollback img-unhealthy
  assert_container "$case_dir" img-current
  grep -Fq "Previous SnakeMP container restored" "$case_dir/output" ||
    fail "failed rollback did not report automatic restoration"
}

test_candidate_tag_collision_is_non_destructive() {
  local case_dir
  local status
  case_dir="$(setup_case collision)"
  seed_tag "$case_dir" snakemp:local img-old
  seed_tag "$case_dir" snakemp:test-candidate img-user
  seed_container "$case_dir" img-old

  set +e
  BUILD_IMAGE_ID=img-new run_refresh "$case_dir" >"$case_dir/output" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail "candidate tag collision unexpectedly succeeded"
  assert_tag "$case_dir" snakemp:test-candidate img-user
  assert_tag "$case_dir" snakemp:local img-old
  assert_container "$case_dir" img-old
  assert_log_excludes "$case_dir" "build --tag"
  assert_log_excludes "$case_dir" "image prune"
}

test_candidate_inspection_failure_is_non_destructive() {
  local case_dir
  local status
  case_dir="$(setup_case inspect-failure)"
  seed_tag "$case_dir" snakemp:local img-old
  seed_container "$case_dir" img-old

  set +e
  IMAGE_LS_FAIL_REFERENCE=snakemp:test-candidate \
    run_refresh "$case_dir" >"$case_dir/output" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail "candidate inspection failure unexpectedly succeeded"
  assert_tag "$case_dir" snakemp:local img-old
  assert_no_tag "$case_dir" snakemp:test-candidate
  assert_container "$case_dir" img-old
  assert_log_excludes "$case_dir" "build --tag"
  assert_log_excludes "$case_dir" "image prune"
}

test_failed_build_cleans_exported_candidate_tag() {
  local case_dir
  local status
  case_dir="$(setup_case failed-build)"
  seed_tag "$case_dir" snakemp:local img-old
  seed_container "$case_dir" img-old

  set +e
  BUILD_FAIL_AFTER_TAG=1 run_refresh "$case_dir" >"$case_dir/output" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail "failed candidate build unexpectedly succeeded"
  assert_tag "$case_dir" snakemp:local img-old
  assert_no_tag "$case_dir" snakemp:test-candidate
  assert_container "$case_dir" img-old
  assert_log_excludes "$case_dir" "rm --force snakemp"
  assert_log_contains "$case_dir" "image prune --force --filter label=io.snakemp.runtime=true"
}

test_failed_tag_restore_skips_prune() {
  local case_dir
  local status
  case_dir="$(setup_case failed-tag-restore)"
  seed_tag "$case_dir" snakemp:local img-current
  seed_tag "$case_dir" snakemp:rollback img-known-good
  seed_container "$case_dir" img-current

  set +e
  TAG_FAIL_AFTER_WRITE_DEST=snakemp:local \
    run_refresh "$case_dir" >"$case_dir/output" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail "failed promotion tag unexpectedly succeeded"
  assert_tag "$case_dir" snakemp:local img-current
  assert_tag "$case_dir" snakemp:rollback img-known-good
  assert_container "$case_dir" img-current
  assert_log_excludes "$case_dir" "image prune"
  grep -Fq "Stable Docker tags were not fully restored; skipping image prune" \
    "$case_dir/output" || fail "failed tag restore did not suppress pruning"
}

test_concurrent_refresh_is_non_destructive() {
  local case_dir
  local lock_file
  local status
  case_dir="$(setup_case concurrent-refresh)"
  lock_file="$case_dir/deploy.lock"
  seed_tag "$case_dir" snakemp:local img-old
  seed_container "$case_dir" img-old

  exec 8>"$lock_file"
  flock --nonblock 8 || fail "test could not acquire deployment lock"
  set +e
  BUILD_IMAGE_ID=img-new run_refresh "$case_dir" \
    SNEK_DOCKER_LOCK_FILE="$lock_file" \
    SNEK_DOCKER_LOCK_WAIT_SECONDS=0 >"$case_dir/output" 2>&1
  status=$?
  set -e
  flock --unlock 8
  exec 8>&-

  [[ $status -eq 75 ]] || fail "concurrent refresh returned $status instead of 75"
  assert_tag "$case_dir" snakemp:local img-old
  assert_no_tag "$case_dir" snakemp:test-candidate
  assert_container "$case_dir" img-old
  [[ ! -s "$case_dir/state/docker.log" ]] ||
    fail "contended refresh mutated Docker state"
  grep -Fq "Another SnakeMP Docker deployment still holds" "$case_dir/output" ||
    fail "contended refresh did not explain how to retry"
}

test_concurrent_start_is_non_destructive() {
  local case_dir
  local lock_file
  local status
  case_dir="$(setup_case concurrent-start)"
  lock_file="$case_dir/deploy.lock"
  seed_tag "$case_dir" snakemp:local img-old
  seed_container "$case_dir" img-old

  exec 8>"$lock_file"
  flock --nonblock 8 || fail "test could not acquire deployment lock"
  set +e
  BUILD_IMAGE_ID=img-new run_start "$case_dir" \
    SNEK_DOCKER_LOCK_FILE="$lock_file" \
    SNEK_DOCKER_LOCK_WAIT_SECONDS=0 >"$case_dir/output" 2>&1
  status=$?
  set -e
  flock --unlock 8
  exec 8>&-

  [[ $status -eq 75 ]] || fail "concurrent start returned $status instead of 75"
  assert_tag "$case_dir" snakemp:local img-old
  assert_container "$case_dir" img-old
  [[ ! -s "$case_dir/state/docker.log" ]] ||
    fail "contended start mutated Docker state"
}

test_successful_refresh
test_failed_candidate_restores_previous_image
test_failed_candidate_preserves_existing_rollback
test_rollback_needs_no_zig_and_promotes_verified_image
test_unhealthy_rollback_restores_current_image
test_candidate_tag_collision_is_non_destructive
test_candidate_inspection_failure_is_non_destructive
test_failed_build_cleans_exported_candidate_tag
test_failed_tag_restore_skips_prune
test_concurrent_refresh_is_non_destructive
test_concurrent_start_is_non_destructive

echo "refresh-docker tests passed"
