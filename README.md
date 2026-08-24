# SnakeMP

SnakeMP is a multiplayer snake game with one browser client and one production
server: a Linux-native Zig epoll reactor with raw WebSockets, compact binary
input, and versioned binary world snapshots. The former Node.js, Bun, Rust, and
Go servers have been retired; their benchmark history remains in
[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).

## Architecture

```text
client/       canonical browser UI and native WebSocket client
servers/zig/  Zig HTTP, WebSocket, simulation, and serialization server
benchmarks/   optional Node.js parity, load, wire, and memory test drivers
docs/         protocol specification and measured performance history
```

One edge-triggered epoll reactor owns connections and HTTP/WebSocket I/O. Game
workers are created only when a lobby gains a player and process up to 128
active lobbies each by default. At 12,000 players in 750 lobbies this is six game
workers, not 750 threads.

The hot path no longer uses Socket.IO, Engine.IO, or JSON snapshots. Browser
inputs are two small binary packet types and each 15 Hz world update is a
bounds-checked binary snapshot. JSON is reserved for infrequent control events
such as initialization, roster changes, errors, and the activity feed.

## Build and run

Production requires Zig and Linux; Node.js is not needed to build or run the
server. The build uses the newest `zig` on `PATH`, or `ZIG_BIN` when explicitly
set.

```bash
bash servers/zig/build-assets.sh
(cd servers/zig && zig build-exe -O ReleaseFast -fstrip src/main.zig \
  -femit-bin=snek-zig --cache-dir .zig-cache --global-cache-dir .zig-global-cache)
PORT=3000 servers/zig/snek-zig
```

Useful runtime overrides are:

- `SNEK_MAX_PLAYERS` (default `100`)
- `SNEK_MAX_PLAYERS_PER_LOBBY` (default and supported browser value `16`)
- `SNEK_MAX_LOBBIES` (default `4096`, including the permanent default lobby)
- `SNEK_LOBBIES_PER_WORKER` (default `128`)
- `SNEK_LOBBY_IDLE_MS` (default `60000`)
- `SNEK_DEBUG=1` to expose local benchmark statistics at `/debug/stats`

`POST /generateid` returns `503 Service Unavailable` while the configured lobby
capacity is full; idle non-default lobbies free slots when they are reaped.

## Development and verification

Node.js is only an optional dependency for the development harnesses. Install
it when running the commands below; it is not part of the deployed server.

```bash
npm install
npm run check
npm run parity
npm run test:memory
npm run test:lobbies
npm run bench:http-pipeline
node benchmarks/wire-format-bench.js
```

The raw protocol, worker ownership rules, HTTP routes, and safety bounds are in
[`docs/SPEC.md`](docs/SPEC.md). The 12,000-player scaling run, accelerated
lifecycle memory test, CPU guidance, wire microbenchmark, and historical Bun
comparison are in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).
