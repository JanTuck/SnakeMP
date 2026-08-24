'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const dockerfile = fs.readFileSync(path.join(root, 'Dockerfile'), 'utf8');
const runtime = fs.readFileSync(path.join(root, 'docker-runtime.sh'), 'utf8');
const start = fs.readFileSync(path.join(root, 'start-docker.sh'), 'utf8');
const refresh = fs.readFileSync(path.join(root, 'refresh-docker.sh'), 'utf8');

assert.match(dockerfile, /^FROM scratch\s*$/m, 'runtime image must remain scratch-based');
assert.doesNotMatch(dockerfile, /^RUN\b/m, 'Dockerfile must not compile or install anything');
assert.match(dockerfile, /^COPY .*servers\/zig\/snek-zig \/snek-zig\s*$/m, 'Dockerfile must only package the host-built server');
assert.match(dockerfile, /^EXPOSE 9687\/tcp\s*$/m, 'runtime image must document port 9687');
assert.match(dockerfile, /io\.snakemp\.runtime="true"/, 'runtime images need a scoped pruning label');

for (const source of [start, refresh]) {
  assert.match(source, /source "\$SCRIPT_DIR\/docker-runtime\.sh"/, 'entrypoints must share one Docker runtime implementation');
  assert.match(source, /acquire_deployment_lock/, 'entrypoints must take the shared deployment lock before mutating Docker state');
}
assert(
  start.indexOf('acquire_deployment_lock') < start.indexOf('build_server_binary'),
  'start must lock before compiling or mutating Docker state',
);
assert(
  refresh.indexOf('acquire_deployment_lock') < refresh.indexOf('docker image inspect'),
  'refresh and rollback must lock before their first Docker operation',
);
assert.match(runtime, /command -v flock/, 'deployment locking must fail clearly when flock is unavailable');
assert.match(runtime, /flock --wait "\$DEPLOY_LOCK_WAIT_SECONDS" 9/, 'deployment locking must use one bounded, clearly announced wait');
assert.match(runtime, /SNEK_DOCKER_LOCK_FILE/, 'deployment lock path must be configurable for isolated hosts');
assert.match(runtime, /--publish "\$HOST_PORT:\$CONTAINER_PORT"/, 'container must publish the configurable host port');
assert.match(runtime, /--read-only/, 'container filesystem must remain read-only');
assert.match(runtime, /--cap-drop ALL/, 'container must drop Linux capabilities');
assert.match(runtime, /--security-opt no-new-privileges/, 'container must prevent privilege escalation');
assert.match(runtime, /docker image prune --force --filter "label=\$SNAKEMP_IMAGE_LABEL"/, 'pruning must be limited to labeled dangling SnakeMP images');

const candidateBuild = refresh.indexOf('build_runtime_image "$CANDIDATE_IMAGE"');
const firstCutover = refresh.indexOf('cutover_started=1', candidateBuild);
const candidateHealth = refresh.indexOf('if ! wait_for_http_health', firstCutover);
const promotion = refresh.indexOf('docker image tag "$CANDIDATE_IMAGE" "$LOCAL_IMAGE"', candidateHealth);
assert(candidateBuild >= 0 && firstCutover > candidateBuild, 'candidate must build before cutover starts');
assert(candidateHealth > firstCutover && promotion > candidateHealth, 'candidate must pass HTTP health before promotion');
assert.match(refresh, /trap on_exit EXIT/, 'failed refreshes must trigger restore cleanup');
assert.match(refresh, /run_runtime_container "\$restore_image"[^\n]*&& wait_for_http_health/, 'failed cutovers must restore and health-check the old image');
assert.match(refresh, /rollback\)\s*\n\s*rollback_refresh/, 'explicit rollback mode must remain available');

console.log('Docker contract test passed (serialized runtime-only deployment, hardened launch, health-gated promotion, scoped prune, and rollback)');
