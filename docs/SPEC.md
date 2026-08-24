# Snek server specification (parity target)

All language ports (server-rust, server-zig, server-go, server-bun) implement
this spec. The reference implementation is the Node server in `server/` +
`app.js`. When in doubt, match observable behaviour, not implementation.

## Runtime model

- Game tick: **every 66.67ms (15fps)**. One master timer iterates all lobbies.
- Board: 1920x900 logical units; grid cell = **16px**; grid is **120 x 60** cells.
- Movement: 16px per tick in the current direction. A snake is an array of
  cells `{x, y}` (multiples of 16), index 0 = head.
- A stationary snake (no input yet) does not move and cannot die.

## Lobbies

- `Map<id, lobby>`. Each lobby: own players, food, bonus apples, drops, golden
  apple, drop/golden timers, broadcast room, tick stats.
- Lobby ids: created by `POST /generateid` (`id-<base36 rand><base36 time>`).
- The default lobby `"12345"` always exists and is never deleted.
- Non-default lobbies with 0 players are deleted after **60s** idle.
- Broadcast room name: `lobby:<id>`.

## Player caps

- **100** concurrent players across all lobbies (reject: "Server is full, try again later").
- **16** players per lobby (reject: "This game is full").
- Rejection = `game_error` event with the message; no `init`; player not added.

## Joining

`clientReady` event with args `[username, lobbyId]`:
1. username: string, trimmed length 4..16, charset `^[\p{L}\p{N}_\- ]+$` (unicode).
   Invalid -> `game_error "Invalid username"`.
2. Unknown lobbyId -> `game_error "That game does not exist any more"`.
3. Caps (global first, then lobby) as above.
4. On success emit `init` `{"scale":16,"food":{"x":..,"y":..}}` (to the joining
   socket only), then add the player, join the room, broadcast feed `join`.
- Spawn position: random free cell (not on any snake, not on the food), up to
  100 attempts.
- Colour: random hex from `rcolor`-style generator (any `#rrggbb` is fine).
- **Rejoin on the same socket after death must work** (Retry without reload).

## Input

`keyPress` event with one of `ArrowUp/ArrowDown/ArrowLeft/ArrowRight`:
- Keep a **queue of at most 2** pending turns. Validate each new input against
  the last queued direction (or the applied direction if the queue is empty):
  reject same direction and 180-degree reversals. Apply **one queued turn per
  tick**; leftovers carry over to the next tick.

## Tick order (per lobby)

1. Expire drops/golden past their TTL.
2. Schedule a supply drop (every 12-20s, max 2 alive) and a golden apple
   (every 25-40s, one at a time) at a free cell.
3. Reap disconnected-socket players (announce feed `death`).
4. Per player, in insertion order (skip players already dead this tick):
   a. wall/self collision -> `death` (score) to that socket + feed `death`,
      remove. Continue.
   b. head vs any other snake segment -> both die: `death` to both sockets +
      2 feed `death`. Continue.
   c. head on main food -> +1 score, +1 pending growth, respawn main food
      (not on snakes), broadcast `updateFood {x,y}`.
   d. head on bonus apple -> remove apple, +1/+1.
   e. head on golden -> remove, +3 score, +1 growth, feed `golden`.
   f. head on drop crate -> remove crate, +2 score, +2 growth, spawn up to 4
      bonus apples (cap 12 total), feed `drop-open`.
   g. apply one queued turn, then move (grow by consuming pendingGrowth
     instead of popping the tail).
5. Broadcast `gameTick` (see wire format).

## Growth model

`eat(points = 1, growth = 1)`: score += points; pendingGrowth += growth.
Each tick: if pendingGrowth > 0, keep the tail (pendingGrowth--) else pop it.

## Pickups

- Main food: exactly 1 per lobby, respawns (free cell) when eaten.
- Bonus apples: up to 12, from opened crates, no expiry.
- Drop crate: TTL 25s, blink client-side when ttl < 5000.
- Golden apple: TTL 12s, blink when ttl < 3000.
- "Free cell": not on any snake, main food, bonus apple, drop, or golden.

## Wire protocol (socket.io v2 over engine.io v3, websocket transport)

- Endpoint: `GET /socket.io/?EIO=3&transport=websocket` (HTTP Upgrade).
- Compute `Sec-WebSocket-Accept` = base64(SHA1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).
- After upgrade, immediately send engine.io open frame:
  `0{"sid":"<20+ chars unique>","upgrades":[],"pingInterval":20000,"pingTimeout":15000}`
  followed by socket.io CONNECT frame: `40`.
- Frames are engine.io packets: first byte packet type:
  `0` open, `2` ping, `3` pong, `4` message. A socket.io event is
  `4` + `42` + JSON array: e.g. `42["keyPress","ArrowRight"]`.
- Server MUST send `2` every pingInterval ms; any `3` from the client resets
  the timer. If no pong within pingTimeout, close the connection.
- Server->client events (message frames `42["<event>",<args...>]`):
  `init`, `gameTick`, `updateFood`, `death` (score), `game_error` (message),
  `feed` ({type, who?, score?, apples?, points?}).
- Client->server events: `clientReady` [username, lobbyId], `keyPress` [dir].
- On socket close: remove the player, broadcast feed `death`.

## gameTick payload

```json
{
  "players": [{"id","displayName","color","snake":[{"x","y"}...],"score","bodyLength"}...],
  "bonus": [{"x","y"}...],
  "drops": [{"id","x","y","ttl"}...],
  "golden": {"x","y","ttl"} | null
}
```

## HTTP

- `GET /` -> client/index.html
- `GET /game/:id` -> client/game.html if the lobby exists, else 302 /
- `GET /game.html` -> 302 / (lobby gate)
- `POST /generateid` -> 303 to /game/<new id> (creates lobby)
- `POST /joingame` (form urlencoded gameId) -> 303 /game/<id> or 303 /?error=unknown-game
- Static: /css/*, /js/*, /img/*, /vendor/gsap.min.js, /socket.io/socket.io.js
  (all embedded from client/ + node_modules assets).
- `GET /debug/stats` -> JSON: {"rss": bytes, "uptime": s, "totalPlayers": n,
  "lobbies": [{"id","players","drops","bonus","golden","lastTickMs","avgTickMs","maxTickMs"}...]}
- Security headers on HTTP responses: X-Content-Type-Options: nosniff,
  X-Frame-Options: DENY, Referrer-Policy: no-referrer. No x-powered-by.

## Validation rules

- keyPress values not in the four arrows are ignored.
- clientReady before a successful join: keyPress ignored.
- Non-string username / lobbyId handled without crashing.
