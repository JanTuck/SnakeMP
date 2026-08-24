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
- A lobby needs a game worker while it has an active snake or an unfinished
  binary death-replay interval. When only game-over chat spectators remain
  after that interval, the lobby releases its worker but keeps text membership;
  Retry assigns a worker again before publishing the replacement player.

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
- The creator may set an exact UTF-8 password of at most 64 bytes and chooses
  one immutable mode. Passwords are stored only as salted SHA-256 digests and
  compared with the standard library's timing-safe primitive.
- **Classical** contains only the main apple. It has no drops, bonus apples,
  golden apples, boost, remains, feasts, bounty, streak, or danger system.
- **Arcade v1** preserves the established game: main/bonus/golden apples and
  supply drops, with no Arcade v2 mechanics.
- **Arcade v2** inherits the Arcade v1 objectives and adds length-funded boost,
  collectible remains, feast periods, leader bounties, credited kill streaks,
  proximity danger cues, and a remains-aware wreckage focus.
- The three names are first-class rulesets, not a version negotiation. Adding
  Arcade v2 never changes Classical or Arcade v1 behavior.
- Lobby `12345` always exists and is never deleted.
- At most 4096 lobbies exist by default, including `12345`
  (`SNEK_MAX_LOBBIES`). At capacity, `POST /generateid` returns HTTP 503 without
  allocating an id or lobby; reaping an idle lobby frees a slot.
- Other empty lobbies are reaped after 60 seconds by default. Override the
  lifecycle test/deployment value with `SNEK_LOBBY_IDLE_MS`.
- Default process-wide capacity is 100 retained lobby identities
  (`SNEK_MAX_PLAYERS`): active snakes and game-over chat spectators use the same
  authoritative counter. Death converts an active identity in place, Retry
  converts it back, and disconnect/eviction releases it. The `/debug/stats`
  player count remains active snakes only.
- Default lobby capacity is 16 players (`SNEK_MAX_PLAYERS_PER_LOBBY`). Snapshot
  v5 has a five-bit player count, but the canonical browser deliberately
  enforces the tested 16-player lobby bound; do not raise the per-lobby value
  without changing and testing both protocol peers.
- A lobby retains at most 16 post-death spectator identities. A seventeenth
  eviction removes the oldest spectator membership but does not close that
  socket or prevent it from joining again. Together with 16 active players,
  this makes the 32-color live identity palette sufficient without reuse. The
  process-wide retained-identity cap may reject new membership before these
  per-lobby limits are reached.
- `publicTarget` is discovery policy, not capacity. Value 0 is unlisted; values
  2..16 advertise an open lobby to Quick Join until its active-snake count
  reaches the target. Retained game-over chat spectators do not make a lobby
  look full. Password-protected lobbies are always stored as unlisted. The
  permanent `12345` lobby is an open Arcade v1 lobby advertised to 16 players.
- Full-server rejection is `game_error: "Server is full, try again later"`.
- Full-lobby rejection is `game_error: "This game is full"`.

At 12,000 players the tested configuration used 750 lobbies of 16 players and
`SNEK_MAX_PLAYERS=12000`; the default production cap remains conservative.

## Join and connection lifecycle

The join fields are UTF-8 byte strings in client binary packet type 1. The
username is trimmed, must be 3..24 Unicode code points and at most 255 UTF-8 bytes, accepts ASCII letters,
digits, underscore, hyphen, and space, and permits valid non-ASCII code points.
At most four code points may be anything other than a Unicode letter; this
includes digits, spaces, combining marks, bidi controls, symbols, and emoji.
Invalid data produces
`["game_error","Invalid username"]`; an unknown lobby or failed password
authentication produces the same generic
`["game_error","That game does not exist any more"]` response.

On success the server:

1. creates and commits the player at a random free cell;
2. sends `init` with scale, food, the immutable mode name, and the retained
   classical compatibility flag to the joining connection;
3. marks the lobby roster dirty;
4. sends a `join` feed event to lobby members;
5. sends the new roster before the next binary snapshot.

A socket may join again after its player dies. In every mode, death removes the
authoritative snake, retains only its bounded identity, and moves the same
connection into a bounded spectator list so Game Over chat stays interactive.
Arcade v2 additionally presents a 3.5-second wreckage focus; Classical and
Arcade v1 retain their established terminal presentation. The spectator stays
in lobby chat until retry, disconnect, or bounded spectator eviction, but its
binary world snapshots stop at the 3.5-second spectating cutoff. Closing a
socket atomically detaches and frees its current player or spectator membership
before the file descriptor and retained buffers are destroyed.

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

boost state:
  type:u8 = 4
  held:u8  // 0 released, 1 held

chat:
  type:u8 = 5
  message:[u8; remaining_frame_bytes]  // validated single-line UTF-8
```

The join frame is `[1,lobby_len,username_len,password_len,lobby,username,password]`
and its length must be exactly `4 + lobby_bytes + username_bytes + password_bytes`.
Lobby and username must be non-empty and are limited to 255 UTF-8 bytes;
password is exact (not trimmed), may be empty, and is limited to 64 UTF-8 bytes.
Input, visibility, and boost frames must be exactly two bytes. Directions are
absolute;
the server rejects repeated/reversing turns and owns the two-turn queue. The
visibility hint changes snapshot delivery cadence, never authoritative
simulation. Boost is a held state, is effective only in Arcade v2, and is reset
when player ownership ends. Unknown packet types/directions and WebSocket text
messages from a client have no game effect.

Packet 5 contains no redundant embedded length: the WebSocket frame is the
exact boundary. Surrounding ASCII spaces are removed; the resulting message
must contain 1..96 Unicode scalar values and at most 160 UTF-8 bytes. Newlines,
tabs, C0/C1 controls, Unicode line/paragraph separators, and bidi embedding,
override, and isolate controls are rejected. Only a current lobby player or
post-death spectator may send. Each connection has a four-token bucket, starts
full, and regains one token every 750 ms; rejected or rate-limited text is not
broadcast.

### Server-to-client JSON control events

Each event is one JSON array whose first element is the event name:

```json
["id", "base64url-connection-id"]
["init", {"scale": 16, "food": {"x": 0, "y": 0}, "mode": "arcade_v2", "classical": false}]
["r", [["id", "displayName", "#rrggbb"]]]
["updateFood", {"x": 0, "y": 0}]
["death", {"score": 12, "focus": {"x": 0, "y": 0}, "spectateMs": 3500}]
["game_error", "message"]
["feed", {"type": "join", "who": "name"}]
["chat", {"id": "connection-id", "who": "name", "color": "#rrggbb", "text": "message"}]
```

The `r` roster is sent only when membership changes. Snapshot player rows use
the same insertion order, eliminating per-tick ids, names, colors, keys, and
object nesting. Every concurrently connected player receives a distinct roster
color; chat renders the sender name in that same color, including while the
sender is a post-death spectator. Feed types include `join`, `death`, `golden`,
`drop-incoming`, `drop-open`, feast, bounty, and streak events, with only the
fields needed by that event.

### Server-to-client binary snapshot v5

All multibyte fields are **little-endian**. Coordinates are one-byte grid-cell
indices and the browser multiplies them by 16. No native Zig struct, padding,
pointer, or uninitialized byte crosses the wire.

```text
header:
  magic:[u8;2] = "SN"
  version:u8 = 5
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
  // bit 7: Arcade v2 extension follows

repeat bonus_count times: x_cell:u8, y_cell:u8

repeat drop_count times: x_cell:u8, y_cell:u8, ttl_ms:u16

if golden present: x_cell:u8, y_cell:u8, ttl_ms:u16

if Arcade v2 extension follows:
  arcade:u8
    // bits 0..5: remains count (0..63)
    // bit 6: feast active
    // bit 7: bounty active

  repeat remains_count times: x_cell:u8, y_cell:u8, ttl_ms:u16

  if feast active: feast_ttl_ms:u16

  if bounty active: bounty_roster_slot:u8
```

A keyframe is complete and resets sequence continuity. A delta is accepted only
when its sequence is the wrapping next `u16` after the client's last accepted
sequence; the former explicit base field was exactly redundant with this check.
Moving delta rows reconstruct the new head as one adjacent cell in the encoded
direction; the existing body shifts behind it.
Classical and Arcade v1 snapshots leave world bit 7 clear and end after the
v4-compatible world body. Arcade v2 sets it and includes the entire bounded
extension in keyframes and deltas. The remains count is six bits and therefore
cannot exceed 63; an active bounty slot must be less than this frame's player
count. TTLs are clamped to `0..65535`.

The server emits a keyframe at least every 30 snapshots, whenever membership or
an unsupported transition invalidates history, and when a client returns from
hidden-document throttling. This bounds recovery without per-client snapshots.

The client checks magic, version, header/world reserved bits, sequence
relationship, roster/player agreement, flags and packed-body padding, all
section counts, remaining length
before every read, gameplay bounds (16 players, 9,216 cells, 12 bonus apples,
two drops, 63 remains), golden/feast/bounty presence and references, and exact
end-of-frame alignment. A frame without the extension explicitly clears prior
Arcade v2 extension state. Malformed,
truncated, or out-of-sequence snapshots are ignored without mutating game
state.

Drops and remains have no identity allocation: the game and browser consume
only position and TTL. Game TTLs are lower than the wire bound.

## Tick order

For each lobby, under its ownership lock:

1. expire mode-specific objectives and remains;
2. schedule mode-specific drops, golden apples, and feast state;
3. reap disconnected players and stop binary fan-out for expired replay state;
4. resolve accepted turns and all players' collision intentions from the same
   pre-movement state, credit body collisions to the body owner, then commit
   deaths without insertion-order advantage;
5. resolve food/remains pickups, growth, ordinary movement, and Arcade v2 boost
   substeps;
6. update the unique qualifying bounty leader and streak state;
7. send a roster if membership changed;
8. serialize one binary snapshot and broadcast the same immutable bytes to all
   active players and spectators whose binary replay interval is unfinished.

Food gives one point and one segment of pending growth. A golden apple gives
three points and one growth. A crate gives two points, two growth, and spawns up
to four bonus apples, capped at 12. Drops live 25 seconds and golden apples 12.
A free cell contains no snake, food, bonus apple, drop, or golden apple.

Arcade v2 remains are lobby-owned bounded values, never references into a dead
snake. On death, the head is excluded and the body is sampled with
`stride = max(3, ceil((length - 1) / 20))`, capped at 20 new remains and 63
live remains per lobby. Normal remains live 15 seconds; remains created during
a feast live 25 seconds. Collecting three remains grants one point and one
pending segment of growth.

Holding boost in Arcade v2 performs one additional fully authoritative movement
substep every second held tick (1.5x movement overall); the substep uses the
same wall, self, player, and pickup rules rather than jumping across cells.
Every 15 active boost ticks pays one unit: pending growth is consumed first,
otherwise one tail cell is removed and becomes a remain. Boost cannot reduce a
snake below five cells.

The first feast is scheduled 60..90 seconds after lobby play begins. A feast
lasts 10 seconds, and the next begins 75..105 seconds after the previous feast
ends. Starting a feast extends existing remains by 10 seconds, capped at 25
seconds from that moment. A bounty exists only for one unique leader with at
least five points. Killing that leader grants score only, clamped to
`1 + floor((leader_score - killer_score) / 5)` in the range 1..5. Ordinary
kills grant no score; credited kills still advance the killer's streak and can
produce feed announcements. Consecutive credited kills belong to one streak
only when each arrives within 15 seconds of the previous credited kill; a later
kill resets the streak to one.

## Browser HUD, chat, and objective safety

- The board remains the full authoritative viewport; replay focus and danger
  cues do not crop it or create a fake collision edge.
- At rest, chat is not a window. The newest five bottom-left messages appear
  over the board and fade out like Minecraft chat.
- Focusing the message input reveals a scrollable panel with the most recent
  100 messages retained during that browser session. Escape returns to the
  fading presentation. Keyboard game controls do not fire while the input has
  focus. Chat remains available on the Game Over/replay state.
- Sender names use their distinct roster colors. Message text is inserted as
  text, never interpreted as HTML.
- The pre-join dialog presents one canonical invite URL derived from the
  current origin and encoded lobby id. Share prefers the Web Share API and
  falls back to Copy; Copy falls back through Clipboard API, legacy browser
  copy, then a selected URL for manual copying. Passwords never enter the URL.
- Authoritative random objectives and newly sampled remains avoid the board
  edge and the reserved HUD, standings/feed, chat, and mute-control regions.
  This applies in all three modes. Translucency is only presentation; it is not
  used to justify hiding a pickup under an interactive overlay.

## HTTP

- `GET /` and `/index.html`: landing page
- `GET /game/:id`: game page if the lobby exists, otherwise `302 /`
- `GET /game.html`: `302 /` (lobby gate)
- `GET` or `HEAD /status`: public, cache-disabled
  `application/json; charset=utf-8` containing
  `{"players":<active-snakes>,"lobbies":<retained-lobbies>}`. The landing
  header requests it with `no-store` every 15 seconds while visible, announces
  loading/retry states, and preserves the last valid totals across failures.
- `POST /quickjoin`: choose an eligible passwordless listed lobby and return
  `303 /game/<id>`, or `303 /?error=no-open-lobby`. Selection is read-only and
  race-tolerant: the redirect neither admits a player nor reserves capacity,
  and the final binary WebSocket join rechecks the lobby and the global retained
  identity cap.
- `POST /generateid`: URL-encoded optional `password` and required `mode` value
  `classical`, `arcade-v1`, or `arcade-v2`; create the immutable-mode lobby and
  return `303 /game/<id>`. Optional `publicTarget` is 0 or 2..16; any password
  forces it to 0. The legacy `classical` checkbox remains accepted for
  compatibility when no `mode` is supplied. Invalid modes, targets, and invalid
  or oversized passwords return HTTP 400 without creating a lobby.
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
