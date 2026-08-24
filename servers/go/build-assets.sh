#!/usr/bin/env bash
# Stage the canonical shared client beneath the Go package so //go:embed can
# include it. The generated tree is ignored and recreated for every build.
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SERVER_DIR/../.." && pwd)"
STAGE_DIR="$SERVER_DIR/internal/generated/client"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$REPO_DIR/client/." "$STAGE_DIR/"
