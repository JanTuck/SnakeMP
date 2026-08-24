# SnakeMP Zig server specification

This document describes the maintained Zig server and canonical browser client.
Socket.IO, Engine.IO, and the old JSON tick protocol are not part of the active
transport.

## Runtime and ownership model

- The simulation runs at **15 Hz**, one tick every **66.67 ms**.
- A single edge-triggered Linux epoll reactor owns listening, HTTP parsing,
  WebSocket framing, connection lifetime, and nonblocking socket writes.
- Game workers are allocated adaptively. A worker owns up to **128 lobbies** by
  default, processes them sequentially each tick, and uses a 128 KiB stack plus
  a retained per-tick arena. Each additional block of 128 lobbies creates
  another worker; empty excess workers are removed again.
- Each lobby has a mutex, private PRNG, stable insertion-ordered player map, and
  retained snapshot buffer. The lock order is lobby, connection membership,
  then connection output, which prevents player/connection use-after-free while
  the reactor and game workers run concurrently.
- Ready sockets use direct nonblocking writes. Per-connection output storage is
  retained and copied into only when the socket applies backpressure.

The worker packing threshold is configurable with `SNEK_LOBBIES_PER_WORKER`.
The default of 128 was validated at 750 active lobbies: six game workers held
the 15 Hz cadence with a per-lobby tick p99 of 0.244 ms.

## Board and movement

- Board: 1920 x 960 logical pixels.
- Cell: 16 pixels, so the board is 120 x 60 cells.
- A snake is stored as ordered cells, head first, and moves one cell per tick.
- A stationary snake (no accepted direction yet) does not move or die.
- Input is a queue of at most two turns. A new turn is rejected if it repeats
  or reverses the last queued/applied direction. One queued turn is applied per
  tick.

## Lobbies and capacity

- Lobby ids are created by `POST /generateid` as
  `id-<base36-random><base36-time>`.
- Lobby `12345` always exists and is never deleted.
- Other empty lobbies are reaped after 60 seconds by default. Override the
  lifecycle test/deployment value with `SNEK_LOBBY_IDLE_MS`.
- Default global capacity is 100 players (`SNEK_MAX_PLAYERS`).
- Default lobby capacity is 16 players (`SNEK_MAX_PLAYERS_PER_LOBBY`). Snapshot
  v1 has a one-byte player count, but the canonical browser deliberately
  enforces the tested 16-player lobby bound; do not raise the per-lobby value
  without changing and testing both protocol peers.
- Full-server rejection is `game_error: "Server is full, try again later"`.
- Full-lobby rejection is `game_error: "This game is full"`.

At 12,000 players the tested configuration used 750 lobbies of 16 players and
`SNEK_MAX_PLAYERS=12000`; the default production cap remains conservative.

## Join and connection lifecycle

The join fields are UTF-8 byte strings in client binary packet type 1. The
username is trimmed, must be 4..16 Unicode code points, accepts ASCII letters,
digits, underscore, hyphen, and space, and permits valid non-ASCII code points.
Invalid data produces
`["game_error","Invalid username"]`; an unknown lobby produces
`["game_error","That game does not exist any more"]`.

On success the server:

1. sends `init` with scale and food to the joining connection;
2. creates the player at a random free cell;
3. marks the lobby roster dirty;
4. sends a `join` feed event to lobby members;
5. sends the new roster before the next binary snapshot.

A socket may join again after its player dies. Closing a socket atomically
detaches and frees the player before the file descriptor and retained buffers
are destroyed.

## Raw WebSocket protocol

The endpoint is `GET /ws` with a standard RFC 6455 version-13 upgrade. The
server sends standard WebSocket ping frames every 20 seconds and closes a peer
that has not answered within 15 seconds. Client frames must be masked. Partial
HTTP requests and fragmented WebSocket messages are accumulated; invalid,
unmasked, oversized, or structurally inconsistent input is rejected without
reading outside validated bounds.

There is no Socket.IO/Engine.IO envelope. Hot client messages and world
snapshots are WebSocket binary frames. Infrequent server control messages are
compact JSON arrays in WebSocket text frames.

### Client-to-server binary packets

All byte lengths below are unsigned bytes.

```text
join:
  type:u8 = 1
  lobby_utf8_bytes:u8
  username_utf8_bytes:u8
  lobby:[u8; lobby_utf8_bytes]
  username:[u8; username_utf8_bytes]

input:
  type:u8 = 2
  direction:u8  // 0 up, 1 down, 2 left, 3 right
```

The join frame length must be exactly `3 + lobby_bytes + username_bytes`, both
fields must be non-empty, and each is limited to 255 UTF-8 bytes by the packet.
The input frame must be exactly two bytes. Unknown packet types/directions and
client text messages have no game effect.

### Server-to-client JSON control events

Each event is one JSON array whose first element is the event name:

```json
["id", "base64url-connection-id"]
["init", {"scale": 16, "food": {"x": 0, "y": 0}}]
["r", [["id", "displayName", "#rrggbb"]]]
["updateFood", {"x": 0, "y": 0}]
["death", 12]
["game_error", "message"]
["feed", {"type": "join", "who": "name"}]
```

The `r` roster is sent only when membership changes. Snapshot player rows use
the same insertion order, eliminating per-tick ids, names, colors, keys, and
object nesting. Feed types are `join`, `death`, `golden`, `drop-incoming`, and
`drop-open`, with only the fields needed by that event.

### Server-to-client binary snapshot v1

All multibyte fields are **little-endian**. Coordinates are one-byte grid-cell
indices and the browser multiplies them by 16. No native Zig struct, padding,
pointer, or uninitialized byte crosses the wire.

```text
magic:[u8;2] = "SN"
version:u8 = 1
player_count:u8

repeat player_count times:
  score:i32
  body_length:u16
  cell_count:u16
  repeat cell_count times: x_cell:u8, y_cell:u8

bonus_count:u8
repeat bonus_count times: x_cell:u8, y_cell:u8

drop_count:u8
repeat drop_count times: x_cell:u8, y_cell:u8, ttl_ms:u16

golden_present:u8  // 0 or 1
if 1: x_cell:u8, y_cell:u8, ttl_ms:u16
```

The client checks magic, version, roster/player agreement, all section counts,
remaining length before every read, gameplay bounds (16 players, 7,200 cells,
12 bonus apples, two drops), golden presence, and exact end-of-frame alignment.
Malformed or truncated snapshots are ignored.

Drop ids are intentionally absent: the browser renders position and TTL and
never consumes the server's internal drop id. TTL values are clamped to
`0..65535`; game TTLs are lower than this bound.

## Tick order

For each lobby, under its ownership lock:

1. expire drops and the golden apple;
2. schedule drops (12-20 s, at most two) and a golden apple (25-40 s, one);
3. reap disconnected players;
4. for each player in insertion order: resolve wall/self and player collisions,
   food/pickups, one queued turn, growth, then movement;
5. send a roster if membership changed;
6. serialize one binary snapshot and broadcast the same immutable bytes to all
   remaining lobby connections.

Food gives one point and one segment of pending growth. A golden apple gives
three points and one growth. A crate gives two points, two growth, and spawns up
to four bonus apples, capped at 12. Drops live 25 seconds and golden apples 12.
A free cell contains no snake, food, bonus apple, drop, or golden apple.

## HTTP

- `GET /` and `/index.html`: landing page
- `GET /game/:id`: game page if the lobby exists, otherwise `302 /`
- `GET /game.html`: `302 /` (lobby gate)
- `POST /generateid`: create lobby and `303 /game/<id>`
- `POST /joingame`: URL-encoded or JSON `gameId`, then a valid-game redirect or
  `303 /?error=unknown-game`
- `/css/*`, `/js/*`, `/img/*`, and `/vendor/gsap.min.js`: compile-time embedded
  canonical client assets
- `GET /debug/stats`: available only with `SNEK_DEBUG=1`; includes RSS,
  connections, players, worker packing, network/frame counters, input timing,
  and per-lobby tick/serialization/wire statistics

Responses include `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
and `Referrer-Policy: no-referrer`, and do not expose an `x-powered-by` header.
