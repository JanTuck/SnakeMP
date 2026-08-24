# Bun server

Spec-compliant implementation of `docs/SPEC.md`: HTTP surface + socket.io v2
over engine.io v3 websocket transport + 15fps game simulation. Zero npm
dependencies (Bun built-ins only). The canonical repository `client/` tree is
loaded once and served from memory.

## Run

    PORT=3000 SNEK_DEBUG=1 bun run src/main.ts

`PORT` selects the listen port (default 3000). `SNEK_DEBUG=1` enables
`GET /debug/stats`. Works from any cwd; assets are resolved relative to this
folder via `import.meta.dir`.

## Release build

    bun build src/main.ts --outfile dist/main.min.js --target=bun --minify
    PORT=3000 SNEK_DEBUG=1 bun run dist/main.min.js

## Acceptance

    PARITY_BASE=http://127.0.0.1:<port> node ../../benchmarks/parity.js

## Layout

    src/config.ts   constants (board, caps, pickups, heartbeat)
    src/util.ts     ids, colors, username validation, RSS sampling
    src/player.ts   movement, growth, and collision model
    src/game.ts     lobbies + tick loop (transport-agnostic)
    src/assets.ts   shared client tree loaded into memory at startup
    src/main.ts     Bun.serve: HTTP routes, engine.io v3 framing, dispatch
    dist/           minified release artifact
