# Zig server

A self-contained Zig implementation of docs/SPEC.md: HTTP routes + embedded
static client + socket.io v2 / engine.io v3 websocket transport.
Standard library only; the canonical client is staged into ignored generated
input and embedded into the binary with `@embedFile`.

## Build

    ./build-assets.sh
    zig build-exe -O ReleaseFast -fstrip src/main.zig -femit-bin=snek-zig \
        --cache-dir .zig-cache --global-cache-dir .zig-global-cache

(Use the newest installed Zig. The cache flags keep build caches inside this folder.)

## Run

    PORT=3000 [SNEK_DEBUG=1] ./snek-zig

- `PORT` selects the listen port (default 3000).
- `SNEK_DEBUG=1` enables `GET /debug/stats` for benchmarks.

## Layout

- `src/main.zig` — single-threaded Linux epoll reactor, incremental HTTP and
  WebSocket parsing, compact JSON protocol, HTTP routing, and game loop.
- `src/model.zig` — cache-friendly game and connection state transitions.
- `src/assets_manifest.zig` — comptime table of embedded public assets.
- `src/generated/client/` — ignored build input staged from canonical `client/`.
- `ws_smoke_test.js` — 3-bot smoke test (needs repo node_modules).

## Verify

    PARITY_BASE=http://127.0.0.1:<port> node ../../benchmarks/parity.js
