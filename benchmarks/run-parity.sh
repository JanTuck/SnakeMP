#!/usr/bin/env bash
# Run the same black-box protocol suite against every implementation.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
RESULTS="$REPO/.scratch/results"
mkdir -p "$RESULTS"

wait_ready() {
  local port="$1"
  for _ in $(seq 1 150); do
    if node -e "require('http').get('http://127.0.0.1:$port/',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

run_one() {
  local name="$1" port="$2"
  shift 2
  local pid
  env PORT="$port" SNEK_DEBUG=1 "$@" >"$RESULTS/$name.server.log" 2>&1 &
  pid=$!
  cleanup() {
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }
  trap cleanup RETURN

  if ! wait_ready "$port"; then
    cat "$RESULTS/$name.server.log"
    return 1
  fi
  PARITY_BASE="http://127.0.0.1:$port" node benchmarks/parity.js | tee "$RESULTS/$name.parity.log"
}

if (( $# == 0 )); then
  set -- node bun go rust zig
fi
for name in "$@"; do
  case "$name" in
    node) run_one node 4000 node "$REPO/servers/node/app.js" ;;
    bun) run_one bun 4101 bun run "$REPO/servers/bun/dist/main.min.js" ;;
    go) run_one go 4102 "$REPO/servers/go/snek-go" ;;
    rust) run_one rust 4103 "$REPO/servers/rust/target/release/snek-rust" ;;
    zig) run_one zig 4104 "$REPO/servers/zig/snek-zig" ;;
    *) echo "unknown implementation: $name" >&2; exit 2 ;;
  esac
done
