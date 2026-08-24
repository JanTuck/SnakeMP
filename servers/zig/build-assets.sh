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

# A browser module graph is cached by its full URL. Stamp one content-derived
# revision into the entry pages and every nested import so a rolling deploy can
# never combine a new renderer with an older dependency from the module map.
ASSET_REV="$({
    cd "$REPO_DIR"
    find client -type f -print0 | sort -z | xargs -0 sha256sum
} | sha256sum | cut -c1-16)"

while IFS= read -r -d '' file; do
    sed -i "s/__SNEK_ASSET_REV__/$ASSET_REV/g" "$file"
done < <(find "$STAGE_DIR" -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' \) -print0)

if grep -R -q '__SNEK_ASSET_REV__' "$STAGE_DIR"; then
    echo "asset revision placeholder survived staging" >&2
    exit 1
fi
