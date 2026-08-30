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
inputs use five small, bounds-checked binary packet types and each 15 Hz world
update is a bounds-checked binary snapshot. JSON is reserved for infrequent
control events such as initialization, roster changes, errors, the activity
feed, and chat.

Lobby creators choose one immutable ruleset. **Classical** is apples-only;
**Arcade** keeps the golden-apple and supply-drop game and adds length-funded
boost, collectible remains, feasts, leader bounties, kill streaks, danger
cues, and a short wreckage focus.

Chat uses each player's roster color. Unfocused play shows a Minecraft-like
bottom-left stream that fades away without an opaque chat panel; focusing the
input reveals the latest 100 messages of scrollable session history. The idle
stream shows at most five messages. An eliminated player remains a lobby
spectator and may keep chatting until retry or disconnect.

The authoritative playfield is 2048 x 1152 logical pixels: 128 x 72 square
cells at 16 pixels per cell. Its exact 16:9 shape maps directly to 720p,
1080p, and 1440p displays. The browser preserves the legacy full-viewport
presentation at other window shapes, so every visible edge remains the real
collision boundary rather than a decorative extension or hidden crop.

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

### Minimal Docker runtime

[`start-docker.sh`](start-docker.sh) builds the asset-embedded static Zig
executable on the host, builds a runtime-only `scratch` image, starts it as an
unprivileged user, and verifies the root HTTP route. The Dockerfile deliberately
does not compile the application or contain a compiler, shell, package manager,
source tree, or separate web assets.

```bash
./start-docker.sh
# http://127.0.0.1:9687/
```

For a transactional, health-gated update, use `./refresh-docker.sh`. The current
container stays online while the host builds the Zig binary and a uniquely
tagged candidate image. At cutover, the current image is retained as
`snakemp:rollback`; the candidate becomes `snakemp:local` only after its root
HTTP check passes. A failed candidate is removed and the prior image is started
and health-checked automatically.

```bash
./refresh-docker.sh
./refresh-docker.sh rollback
```

Explicit rollback needs Docker and the retained image, not a Zig toolchain. It
promotes `snakemp:rollback` only after the replacement container passes the same
check; failure restores the displaced runtime. Successful and failed refreshes
remove the exact temporary candidate tag and prune only dangling images carrying
SnakeMP's runtime label. Unrelated Docker images are never pruned.

The script replaces a running container with the configured name and leaves the
new container running in the background. Its optional overrides are:

- `ZIG_BIN` for a non-default Zig executable
- `SNEK_DOCKER_IMAGE` (default `snakemp:local`)
- `SNEK_DOCKER_CONTAINER` (default `snakemp`)
- `SNEK_DOCKER_PORT` for the published host port (default `9687`)

For example, `SNEK_DOCKER_PORT=8080 ./start-docker.sh` publishes host port 8080
to the server's fixed container port 9687. The image serves HTTP and WebSockets;
terminate HTTPS at a reverse proxy and forward it to that port. Runtime
`SNEK_*` capacity overrides listed below are passed through when set in the
script's environment.

Useful runtime overrides are:

- `SNEK_MAX_PLAYERS` for retained lobby identities: active players plus
  game-over chat members (default `100`)
- `SNEK_MAX_PLAYERS_PER_LOBBY` (default and supported browser value `16`)
- `SNEK_MAX_LOBBIES` (default `4096`, including the permanent default lobby)
- `SNEK_LOBBIES_PER_WORKER` (default `128`)
- `SNEK_LOBBY_IDLE_MS` (default `1800000`, keeping an empty waiting room alive for 30 minutes)
- `SNEK_DEBUG=1` to expose local benchmark statistics at `/debug/stats`

`POST /generateid` returns `503 Service Unavailable` while the configured lobby
capacity is full; idle non-default lobbies free slots when they are reaped.

## Discovery and invites

Quick Join is an explicit `POST /quickjoin`. Passwordless lobbies are listed
automatically until their selected capacity is full; adding a password keeps a
lobby private. Redirect selection is
read-only and intentionally race-tolerant: it reserves no seat, and the final
WebSocket join authoritatively checks per-lobby and process-wide retained-member
capacity.

Every game join dialog exposes the canonical `/game/<encoded-lobby-id>` URL.
Share uses the platform share sheet when available and otherwise copies the
same link; Copy falls back from the Clipboard API to legacy copy and finally a
selected URL for manual copying. Lobby passwords are deliberately shared
separately and never placed in the invite URL.

The landing header reads `GET /status` for live active-player and lobby totals.
The cache-disabled JSON is refreshed every 15 seconds; the compact counters
show loading, retrying, and last-known states instead of replacing a good value
with an error.

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
npm run bench:lobby-reap
npm run bench:player-container
node benchmarks/wire-format-bench.js
```

The raw protocol, worker ownership rules, HTTP routes, and safety bounds are in
[`docs/SPEC.md`](docs/SPEC.md). The 12,000-player scaling run, accelerated
lifecycle memory test, CPU guidance, wire microbenchmark, and historical Bun
comparison are in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).
