#!/usr/bin/env bash
# Collects size/LOC metrics for one Snek server implementation.
# Usage: ./benchmarks/collect-metrics.sh <folder> <name>
set -e
DIR="$1"; NAME="$2"
cd "$(dirname "$0")/.."
echo "=== $NAME ($DIR) ==="
echo "-- source LOC --"
find "$DIR" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.rs' -o -name '*.zig' -o -name '*.go' \) \
  -not -path '*/node_modules/*' -not -path '*/target/*' -not -path '*/.gocache/*' -not -path '*/zig-cache/*' \
  -not -path '*/public/*' -print0 | xargs -0 wc -l | tail -1
echo "-- binary / build artifacts --"
find "$DIR" -type f \( -path '*/target/release/*' -o -path '*/zig-out/*' \) -size +100k -exec ls -la {} \; 2>/dev/null | awk '{print $5, $NF}' | sort -rn | head -3
find "$DIR" -maxdepth 1 -type f -size +100k -exec ls -la {} \; 2>/dev/null | awk '{print $5, $NF}' | sort -rn | head -3
echo "-- folder size (total) --"
du -sh "$DIR" 2>/dev/null
echo "-- folder size (excluding build caches: target, .gocache, zig-cache, zig-out) --"
du -sh --exclude=target --exclude=.gocache --exclude=zig-cache --exclude=zig-out --exclude=.zig-cache --exclude=.zig-global-cache "$DIR" 2>/dev/null
echo "-- node_modules present? --"
[ -d "$DIR/node_modules" ] && du -sh "$DIR/node_modules" || echo "none"
