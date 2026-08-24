# SnakeMP Zig server specification

This document describes the maintained Zig server and canonical browser client.
Socket.IO, Engine.IO, and the old JSON tick protocol are not part of the active
transport.

## Runtime and ownership model

- The simulation runs at **15 Hz**, one tick every **66.67 ms**.
- A single edge-triggered Linux epoll reactor owns listening, HTTP parsing,
  WebSocket framing, connection lifetime, and nonblocking socket writes.
- The listener owns `TCP_NODELAY`, inherited by accepted Linux sockets. Accepted
  descriptors are never duplicated; final close therefore removes their epoll
  registrations without a separate delete syscall.
- Game workers are allocated lazily and adaptively. Empty lobbies own no game
  thread. A worker owns up to **128 active lobbies** by default, processes them
  sequentially each tick, and uses a 128 KiB stack plus a retained per-tick
  arena. Empty lobbies are detached during the next maintenance cycle, and an
  empty worker is stopped immediately.
- Each lobby has a mutex, private PRNG, stable insertion-ordered player pointer
  list, and retained snapshot buffer. The cross-thread lock order is worker,
  lobby, connection membership, then connection output, which prevents
  player/connection use-after-free while the reactor and game workers run
  concurrently.
- Ready sockets use direct nonblocking writes. Per-connection output storage is
  retained and copied into only when the socket applies backpressure. Consumed
  queue prefixes are compacted incrementally, oversized idle descriptor arrays
  are released, and WebSocket queues are bounded by both four MiB of live bytes
  and 4,096 live items. Coalesced HTTP pipelines batch up to 64 queued segments
  per `writev`; standalone responses retain the direct-write path.

The worker packing threshold is configurable with `SNEK_LOBBIES_PER_WORKER`.
The default of 128 was validated at 750 active lobbies: six game workers held
the 15 Hz cadence with a per-lobby tick p99 of 0.244 ms.

## Board and movement

- Board: 2048 x 1152 logical pixels, an exact 16:9 playfield that maps directly
  to 1280 x 720, 1920 x 1080, and 2560 x 1440 displays. The browser maps the
  complete board to the viewport at other aspect ratios; it never crops or
  extends the authoritative collision area.
- Cell: 16 logical pixels, so the board is 128 x 72 square cells (9,216 total).
- A snake is stored as ordered cells, head first, and moves one cell per tick.
- A stationary snake (no accepted direction yet) does not move or die.
- Input is a queue of at most two turns. A new turn is rejected if it repeats
  or reverses the last queued/applied direction. One queued turn is applied per
  tick.

## Lobbies and capacity

- Lobby ids are created by `POST /generateid` as
  `id-<base36-random><base36-time>`.
- The creator may set an exact UTF-8 password of at most 64 bytes and may make
  the lobby classical. Passwords are stored only as salted SHA-256 digests and
  compared with the standard library's timing-safe primitive. Classical mode
  is immutable for the lobby lifetime and disables drops, bonus apples, and
  golden apples.
- Lobby `12345` always exists and is never deleted.
- At most 4096 lobbies exist by default, including `12345`
  (`SNEK_MAX_LOBBIES`). At capacity, `POST /generateid` returns HTTP 503 without
  allocating an id or lobby; reaping an idle lobby frees a slot.
- Other empty lobbies are reaped after 60 seconds by default. Override the
  lifecycle test/deployment value with `SNEK_LOBBY_IDLE_MS`.
- Default global capacity is 100 players (`SNEK_MAX_PLAYERS`).
- Default lobby capacity is 16 players (`SNEK_MAX_PLAYERS_PER_LOBBY`). Snapshot
  v4 has a five-bit player count, but the canonical browser deliberately
  enforces the tested 16-player lobby bound; do not raise the per-lobby value
  without changing and testing both protocol peers.
- Full-server rejection is `game_error: "Server is full, try again later"`.
- Full-lobby rejection is `game_error: "This game is full"`.

At 12,000 players the tested configuration used 750 lobbies of 16 players and
`SNEK_MAX_PLAYERS=12000`; the default production cap remains conservative.

## Join and connection lifecycle

The join fields are UTF-8 byte strings in client binary packet type 1. The
username is trimmed, must be 1..64 Unicode code points and at most 255 UTF-8 bytes, accepts ASCII letters,
digits, underscore, hyphen, and space, and permits valid non-ASCII code points.
Invalid data produces
`["game_error","Invalid username"]`; an unknown lobby or failed password
authentication produces the same generic
`["game_error","That game does not exist any more"]` response.

On success the server:

1. creates and commits the player at a random free cell;
2. sends `init` with scale, food, and the lobby's classical-mode flag to the
   joining connection;
3. marks the lobby roster dirty;
4. sends a `join` feed event to lobby members;
5. sends the new roster before the next binary snapshot.

A socket may join again after its player dies. Closing a socket atomically
detaches and frees the player before the file descriptor and retained buffers
are destroyed.

## Raw WebSocket protocol

The endpoint is `GET /ws` with a standard RFC 6455 version-13 upgrade. The
server sends standard WebSocket ping frames every 20 seconds and closes a peer
that has not answered within 15 seconds. The HTTP/1.1 upgrade requires exact
comma-delimited header tokens and a base64 key that decodes to 16 bytes. Client
frames must be masked. Partial HTTP requests are accumulated, while fragmented
messages are deliberately unsupported under the bounded application protocol.
Reserved bits, non-canonical lengths, malformed close payloads, invalid UTF-8,
unmasked frames, and oversized or structurally inconsistent input are rejected
without reading outside validated bounds. A valid client Close is serialized
after every earlier server frame and atomically seals publication, so no data
frame can be queued after the Close reply.

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
  password_utf8_bytes:u8
  lobby:[u8; lobby_utf8_bytes]
  username:[u8; username_utf8_bytes]
  password:[u8; password_utf8_bytes]

input:
  type:u8 = 2
  direction:u8  // 0 up, 1 down, 2 left, 3 right

visibility hint:
  type:u8 = 3
  visible:u8  // 0 hidden, 1 visible
```

The join frame is `[1,lobby_len,username_len,password_len,lobby,username,password]`
and its length must be exactly `4 + lobby_bytes + username_bytes + password_bytes`.
Lobby and username must be non-empty and are limited to 255 UTF-8 bytes;
password is exact (not trimmed), may be empty, and is limited to 64 UTF-8 bytes.
Input and visibility frames must be exactly two bytes. Directions are absolute;
the server rejects repeated/reversing turns and owns the two-turn queue. The
visibility hint changes snapshot delivery cadence, never authoritative
simulation. Unknown packet types/directions and valid client text messages have
no game effect.

### Server-to-client JSON control events

Each event is one JSON array whose first element is the event name:

```json
["id", "base64url-connection-id"]
["init", {"scale": 16, "food": {"x": 0, "y": 0}, "classical": false}]
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

### Server-to-client binary snapshot v4

All multibyte fields are **little-endian**. Coordinates are one-byte grid-cell
indices and the browser multiplies them by 16. No native Zig struct, padding,
pointer, or uninitialized byte crosses the wire.

```text
header:
  magic:[u8;2] = "SN"
  version:u8 = 4
  sequence:u16
  kind_and_players:u8
    // bit 7: 0 keyframe, 1 dependent delta
    // bits 0..4: player count (0..16)
    // bits 5..6: reserved and zero

keyframe player, repeated player_count times:
  score:i32
  encoded_cells:u16       // low 15 bits count; bit 15 selects packed body
  if packed:
    head_x_cell:u8, head_y_cell:u8
    segment_directions:ceil((cell_count - 1) / 4) bytes
      // four 2-bit directions per byte: up, down, left, right
  otherwise:
    repeat cell_count times: x_cell:u8, y_cell:u8

delta player, repeated player_count times:
  flags:u8
    // bits 0..1: unchanged, shifted, shifted-and-grown (3 is invalid)
    // bit 2: score:i32 follows
    // bits 3..4: new-head direction for shifted/grown rows
    // bits 5..7: reserved and zero
  if score bit: score:i32

world:u8
  // bits 0..3: bonus count (0..12)
  // bits 4..5: drop count (0..2)
  // bit 6: golden present
  // bit 7: reserved and zero

repeat bonus_count times: x_cell:u8, y_cell:u8

repeat drop_count times: x_cell:u8, y_cell:u8, ttl_ms:u16

if golden present: x_cell:u8, y_cell:u8, ttl_ms:u16
```

A keyframe is complete and resets sequence continuity. A delta is accepted only
when its sequence is the wrapping next `u16` after the client's last accepted
sequence; the former explicit base field was exactly redundant with this check.
Moving delta rows reconstruct the new head as one adjacent cell in the encoded
direction; the existing body shifts behind it.
The server emits a keyframe at least every 30 snapshots, whenever membership or
an unsupported transition invalidates history, and when a client returns from
hidden-document throttling. This bounds recovery without per-client snapshots.

The client checks magic, version, header/world reserved bits, sequence
relationship, roster/player agreement, flags and packed-body padding, all
section counts, remaining length
before every read, gameplay bounds (16 players, 9,216 cells, 12 bonus apples,
two drops), golden presence, and exact end-of-frame alignment. Malformed,
truncated, or out-of-sequence snapshots are ignored without mutating game
state.

Drops have no identity allocation: the game and browser consume only position
and TTL. TTL values are clamped to `0..65535`; game TTLs are lower than this
bound.

## Tick order

For each lobby, under its ownership lock:

1. expire drops and the golden apple (skipped in classical mode);
2. schedule drops (12-20 s, at most two) and a golden apple (25-40 s, one;
   skipped in classical mode);
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
- `POST /generateid`: URL-encoded optional `password` and `classical` checkbox;
  create the lobby and return `303 /game/<id>`. Invalid or oversized passwords
  return HTTP 400 without creating a lobby.
- `POST /joingame`: URL-encoded or JSON `gameId` and optional `password`, then
  an authenticated-game redirect or `303 /?error=unknown-game`. Missing/wrong
  credentials deliberately use the same response as an unknown lobby id.
- `/css/*`, `/js/*`, and `/img/*`: compile-time embedded
  canonical client assets
- `GET /debug/stats`: available only with `SNEK_DEBUG=1`; includes RSS,
  connections, players, worker packing, network/frame counters, input timing,
  and per-lobby tick/serialization/wire statistics

Responses include `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
and `Referrer-Policy: no-referrer`, and do not expose an `x-powered-by` header.
