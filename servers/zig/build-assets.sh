#!/usr/bin/env bash
# Stage the canonical shared client beneath the Zig package so @embedFile can
# include it without treating tracked copies as implementation source.
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SERVER_DIR/../.." && pwd)"
STAGE_DIR="$SERVER_DIR/src/generated/client"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$REPO_DIR/client/." "$STAGE_DIR/"
