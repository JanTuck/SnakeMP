#!/usr/bin/env bash
# Full benchmark + stress suite for every Snek server implementation.
# Usage: ./benchmarks/run-benchmarks.sh <name> [<name> ...]
#   names: node | zig | rust | go | bun
# Results land in .scratch/results/<name>.* plus .scratch/{bench,stress}-<name>.json
set -u
cd "$(dirname "$0")/.."
mkdir -p .scratch/results
ulimit -n 65535 2>/dev/null || true
REPO="$(pwd)"

if (( $# == 0 )); then
  set -- node bun go rust zig
fi

start_server() { # name port cmd...
  local name="$1" port="$2"; shift 2
  env PORT="$port" SNEK_DEBUG=1 "$@" > ".scratch/results/$name.server.log" 2>&1 &
  echo $!
}

wait_ready() { # port
  local port="$1"
  for _ in $(seq 1 150); do
    if node -e "require('http').get('http://127.0.0.1:$port/',(r)=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

run_suite() { # name port cmd...
  local name="$1" port="$2"; shift 2
  echo "===== SUITE $name (port $port) ====="
  local spid mpid
  spid=$(start_server "$name" "$port" "$@") || return 1
  if ! wait_ready "$port"; then
    echo "$name: FAILED TO START"; cat ".scratch/results/$name.server.log"; kill "$spid" 2>/dev/null; return 1
  fi
  echo "$name: up (pid $spid), sampling..."
  node benchmarks/sample-metrics.js "$spid" ".scratch/results/$name.metrics.json" 200 &
  mpid=$!

  PARITY_BASE="http://127.0.0.1:$port" node benchmarks/parity.js > ".scratch/results/$name.parity.log" 2>&1
  echo "$name: parity rc=$? ($(tail -1 ".scratch/results/$name.parity.log"))"

  BENCH_BASE="http://127.0.0.1:$port" BENCH_NAME="$name" node benchmarks/bench.js > ".scratch/results/$name.bench.log" 2>&1
  echo "$name: bench done (rc=$?)"
  sleep 2
  STRESS_BASE="http://127.0.0.1:$port" STRESS_NAME="$name" node benchmarks/stress.js > ".scratch/results/$name.stress.log" 2>&1
  echo "$name: stress done (rc=$?)"

  sleep 1
  kill -INT "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
  kill -TERM "$spid" 2>/dev/null
  for _ in $(seq 1 20); do kill -0 "$spid" 2>/dev/null || break; sleep 0.2; done
  kill -KILL "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  echo "$name: stopped. metrics: $(cat ".scratch/results/$name.metrics.json" 2>/dev/null | tr '\n' ' ')"
}

size_report() { # name dir
  local name="$1" dir="$2"
  {
    echo "=== $name size report ==="
    bash "$REPO/benchmarks/collect-metrics.sh" "$dir" "$name" || true
    if [ "$name" = "node" ]; then
      echo "-- node server footprint: repo incl node_modules, excl .scratch and the port folders --"
      du -sh "$REPO/servers/node" 2>/dev/null
      echo "-- node_modules alone --"; du -sh "$REPO/node_modules" 2>/dev/null
      echo "-- reference server LOC --"
      wc -l "$REPO/servers/node/app.js" "$REPO"/servers/node/src/*.js | tail -1
    fi
  } > ".scratch/results/$name.sizes.txt" 2>&1
}

for name in "$@"; do
  case "$name" in
    node) run_suite node 4000 node "$REPO/servers/node/app.js"; size_report node "$REPO/servers/node" ;;
    bun)  run_suite bun  4101 bun run "$REPO/servers/bun/dist/main.min.js"; size_report bun "$REPO/servers/bun" ;;
    go)   run_suite go   4102 "$REPO/servers/go/snek-go"; size_report go "$REPO/servers/go" ;;
    rust) run_suite rust 4103 "$REPO/servers/rust/target/release/snek-rust"; size_report rust "$REPO/servers/rust" ;;
    zig)  run_suite zig  4104 "$REPO/servers/zig/snek-zig"; size_report zig "$REPO/servers/zig" ;;
    *) echo "unknown suite: $name" ;;
  esac
done
echo "ALL REQUESTED SUITES DONE"
