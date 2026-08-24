#!/usr/bin/env bash
# Full benchmark + stress suite for the maintained Snek servers.
# Usage: ./benchmarks/run-benchmarks.sh <name> [<name> ...]
#   name: zig
# Results land in .scratch/results/<name>.* plus .scratch/{bench,stress}-<name>.json
set -u
cd "$(dirname "$0")/.."
mkdir -p .scratch/results
ulimit -n 65535 2>/dev/null || true
REPO="$(pwd)"
ACTIVE_SERVER_PID=""
ACTIVE_METRICS_PID=""

cleanup_suite() {
  local pid
  pid="$ACTIVE_METRICS_PID"
  ACTIVE_METRICS_PID=""
  if [[ -n "$pid" ]]; then
    kill -INT "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  pid="$ACTIVE_SERVER_PID"
  ACTIVE_SERVER_PID=""
  if [[ -n "$pid" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

trap cleanup_suite EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( $# == 0 )); then
  set -- zig
fi

start_server() { # name port cmd...
  local name="$1" port="$2"; shift 2
  env PORT="$port" SNEK_DEBUG=1 "$@" > ".scratch/results/$name.server.log" 2>&1 &
  ACTIVE_SERVER_PID=$!
}

wait_ready() { # port pid
  local port="$1" pid="$2"
  for _ in $(seq 1 150); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    if node -e "require('http').get('http://127.0.0.1:$port/',(r)=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))" 2>/dev/null; then
      kill -0 "$pid" 2>/dev/null && return 0
      return 1
    fi
    sleep 0.2
  done
  return 1
}

run_phase() { # name phase port cmd... -- phase-command...
  local name="$1" phase="$2" port="$3"; shift 3
  local server_cmd=()
  while (( $# > 0 )) && [[ "$1" != "--" ]]; do
    server_cmd+=("$1")
    shift
  done
  shift
  local spid mpid rc
  cleanup_suite
  if ! start_server "$name.$phase" "$port" "${server_cmd[@]}"; then
    echo "$name/$phase: FAILED TO START"
    cleanup_suite
    return 1
  fi
  spid="$ACTIVE_SERVER_PID"
  if ! wait_ready "$port" "$spid"; then
    echo "$name/$phase: FAILED TO START"
    cat ".scratch/results/$name.$phase.server.log"
    cleanup_suite
    return 1
  fi
  echo "$name/$phase: up (pid $spid), sampling..."
  node benchmarks/sample-metrics.js "$spid" ".scratch/results/$name.$phase.metrics.json" 200 &
  mpid=$!
  ACTIVE_METRICS_PID="$mpid"

  "$@" > ".scratch/results/$name.$phase.log" 2>&1
  rc=$?
  cleanup_suite
  echo "$name/$phase: rc=$rc"
  return "$rc"
}

run_suite() { # name port cmd...
  local name="$1" port="$2"; shift 2
  local server_cmd=("$@")
  local rc suite_rc=0
  echo "===== SUITE $name (port $port) ====="

  run_phase "$name" parity "$port" "${server_cmd[@]}" -- env PARITY_BASE="http://127.0.0.1:$port" node benchmarks/parity.js
  rc=$?
  (( rc == 0 )) || suite_rc=1

  run_phase "$name" bench "$port" "${server_cmd[@]}" -- env BENCH_BASE="http://127.0.0.1:$port" BENCH_NAME="$name" node benchmarks/bench.js
  rc=$?
  (( rc == 0 )) || suite_rc=1

  run_phase "$name" stress "$port" "${server_cmd[@]}" -- env STRESS_BASE="http://127.0.0.1:$port" STRESS_NAME="$name" node benchmarks/stress.js
  rc=$?
  (( rc == 0 )) || suite_rc=1

  return "$suite_rc"
}

size_report() { # name dir
  local name="$1" dir="$2"
  {
    echo "=== $name size report ==="
    bash "$REPO/benchmarks/collect-metrics.sh" "$dir" "$name" || true
  } > ".scratch/results/$name.sizes.txt" 2>&1
}

overall_rc=0
for name in "$@"; do
  case "$name" in
    zig)
      run_suite zig 4104 "$REPO/servers/zig/snek-zig"
      rc=$?
      size_report zig "$REPO/servers/zig"
      if (( rc != 0 && overall_rc == 0 )); then overall_rc="$rc"; fi
      ;;
    *)
      echo "unknown suite: $name" >&2
      overall_rc=2
      ;;
  esac
done
if (( overall_rc == 0 )); then
  echo "ALL REQUESTED SUITES DONE"
else
  echo "ONE OR MORE REQUESTED SUITES FAILED (rc=$overall_rc)" >&2
fi
exit "$overall_rc"
