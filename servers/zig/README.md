# Zig server

The only production SnakeMP server. It is a standard-library-only Linux binary
that serves the embedded browser client, accepts raw RFC 6455 WebSockets at
`/ws`, consumes fixed binary join/input packets, and broadcasts versioned
binary world snapshots.

Socket.IO, Engine.IO, Node.js, Bun, Rust, and Go are not runtime dependencies.

## Build

Use the newest installed Zig (validated with 0.16.0):

```bash
./build-assets.sh
zig build-exe -O ReleaseFast -fstrip src/main.zig -femit-bin=snek-zig \
  --cache-dir .zig-cache --global-cache-dir .zig-global-cache
```

`build-assets.sh` stages the canonical repository `client/` into ignored
`src/generated/client/` files consumed by `@embedFile`. Do not edit the staged
copy.

## Run

```bash
PORT=3000 ./snek-zig
```

Environment variables:

| Variable | Default | Purpose |
|---|---:|---|
| `PORT` | `3000` | HTTP and WebSocket listen port |
| `SNEK_DEBUG` | unset | Set to `1` for `/debug/stats` |
| `SNEK_MAX_PLAYERS` | `100` | Global retained-identity cap: active snakes plus game-over chat spectators; 12k test used `12000` |
| `SNEK_MAX_PLAYERS_PER_LOBBY` | `16` | Lobby cap; canonical binary-v5 browser is tested at 16 |
| `SNEK_MAX_LOBBIES` | `4096` | Generated-lobby resource cap, including the permanent default lobby |
| `SNEK_LOBBIES_PER_WORKER` | `128` | Game-worker packing threshold |
| `SNEK_LOBBY_IDLE_MS` | `60000` | Empty non-default lobby lifetime |

`POST /generateid` returns `503 Service Unavailable` at `SNEK_MAX_LOBBIES`;
idle non-default lobbies free capacity when the maintenance loop reaps them.

For the runtime-only Docker image, run `./start-docker.sh` from the repository
root. The script builds the static Zig executable on the host, packages no
compiler or source tree, and publishes HTTP/WebSockets on
`http://127.0.0.1:9687` by default. The Dockerfile itself does not build the
server.

`./refresh-docker.sh` keeps the current container online while it builds a
unique candidate, saves the current image as `snakemp:rollback`, health-checks
the candidate after cutover, and only then promotes it to `snakemp:local`. A
failed refresh restores and checks the previous runtime; explicit
`./refresh-docker.sh rollback` performs the same guarded promotion without
requiring Zig. Cleanup is label-scoped to dangling SnakeMP runtime images.

Lobby discovery is opt-in: `publicTarget=0` is unlisted, 2..16 advertises an
open lobby until its target is reached, and passworded lobbies are always
unlisted. `POST /quickjoin` performs a read-only, race-tolerant redirect; it
reserves no seat, while the WebSocket join remains the sole capacity authority.
The cache-disabled `GET`/`HEAD /status` returns
`{"players":<active>,"lobbies":<retained>}` for the landing header, whose
compact counters refresh every 15 seconds and retain the last good values while
retrying.

The worker pool is lazy: empty generated lobbies use no game threads. Once
players join, up to 128 active lobbies share one worker, 129..256 use two, and
750 use six. Each worker has a 128 KiB stack and a reusable per-tick arena. The
network side remains one edge-triggered epoll reactor regardless of lobby
count. Empty lobbies detach on the next maintenance cycle and their now-empty
workers stop immediately, before lobby-id reaping.

Game-over identities keep chat membership under the same process-wide capacity
as active snakes. Their binary snapshots stop at the spectating cutoff; a lobby
containing only chat spectators then releases its game worker. Retry assigns a
worker again before the replacement snake becomes visible.

## Source layout

- `src/main.zig` - process lifecycle, epoll reactor, HTTP routing, connection
  ownership, adaptive worker orchestration, lobby simulation, and broadcasts
- `src/config.zig` - protocol, game, safety, timing, and default tuning constants
- `src/model.zig` - player, lobby, connection, turn queue, and movement state
- `src/websocket.zig` - WebSocket header generation and fixed binary client
  packet validation
- `src/snapshot.zig` - little-endian binary snapshot v5 keyframe/delta encoder
  with explicit clamps and no native-struct wire casts
- `src/json.zig` - infrequent JSON control-event construction and escaping
- `src/text.zig` - username, URI, form, and small JSON-field validation helpers
- `src/assets_manifest.zig` - compile-time embedded public-asset manifest
- `src/generated/client/` - ignored staged build input from canonical `client/`

See [`../../docs/SPEC.md`](../../docs/SPEC.md) for the exact packet layouts and
ownership rules.

## Hot-path design

- Direct nonblocking `writev` is used when a socket is ready; bytes are copied
  into a retained connection buffer only under backpressure.
- One immutable lobby snapshot is built into a retained buffer and fanned out
  to every member.
- Roster identity is an infrequent JSON control event; 15 Hz snapshots contain
  only scores, lengths, cell coordinates, bounded objective/remains state, and
  TTLs. Classical and Arcade v1 omit the Arcade v2 extension entirely.
- Lobby mode is immutable: Classical is apples-only, Arcade v1 preserves the
  established golden-apple/supply-drop rules, and Arcade v2 adds boost,
  remains, feasts, bounties, streaks, danger cues, and a wreckage focus.
- Chat messages are single-line validated UTF-8 with fixed byte/scalar bounds
  and a per-connection token bucket. In every mode, a dead player may chat
  while only its bounded identity is retained as a spectator; no dead-player
  snake allocation is kept alive. Browser
  scrollback is a 100-message session ring; idle play shows and fades only the
  latest five.
- Client frames are unmasked in place after complete-frame bounds validation.
- Partial HTTP/WebSocket input is retained until complete; caps reject oversized
  headers, bodies, frames, connection queues, and aggregate input.
- Lobby/member/output mutex ordering makes disconnect, death, rejoin, and
  concurrent fan-out safe without giving game workers ownership of file
  descriptor lifetime.

At 12,000 stationary players in 750 lobbies, the server used six game workers,
20.39 MiB RSS, 115.18% CPU, and maintained 66.675/68.225/69.359 ms client
cadence p50/p95/p99 with zero sampled disconnects. Full methodology and CPU/
network guidance are in [`../../docs/BENCHMARKS.md`](../../docs/BENCHMARKS.md).

## Verify

Zig-only checks do not require Node.js:

```bash
./build-assets.sh
zig fmt --check src/*.zig
zig test src/main.zig --cache-dir .zig-cache --global-cache-dir .zig-global-cache
```

The browser parity, load, wire microbenchmark, and accelerated lifecycle tests
use Node.js only as a development harness:

```bash
cd ../..
npm install
npm run parity
npm run test:memory
npm run test:lobbies
node benchmarks/wire-format-bench.js
cd servers/zig && zig run -O ReleaseFast bench_snapshot.zig
cd servers/zig && zig run -O ReleaseFast bench_tick_scratch.zig
```
