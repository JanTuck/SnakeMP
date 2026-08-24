# Go server

The Go implementation uses `net/http` and a small WebSocket/Engine.IO transport.
`main.go` owns HTTP routes, `ws.go` transport framing, `hub.go` the lobby world,
and `player.go` player movement/collision behavior.

Before building, `build-assets.sh` stages the canonical shared client into the
ignored `internal/generated/client/` tree required by `//go:embed`.

```bash
bash servers/go/build-assets.sh
cd servers/go
go build -trimpath -ldflags='-s -w' -o snek-go .
PORT=3000 SNEK_DEBUG=1 ./snek-go
```
