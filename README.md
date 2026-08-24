# SnakeMP

SnakeMP is one multiplayer snake server implemented five ways against one
observable protocol. Node is the reference implementation; Bun, Go, Rust, and
Zig are independent ports that serve the same embedded browser client.

## Repository layout

```text
client/       canonical browser client and vendored browser bundles
docs/         protocol specification and benchmark report
servers/
  node/       Socket.IO reference implementation
  bun/        Bun HTTP/WebSocket implementation
  go/         idiomatic net/http implementation
  rust/       std TCP/WebSocket server with typed serde wire payloads
  zig/        standard-library server pinned to Zig 0.13
benchmarks/   parity, load, stress, metrics, and report tooling
```

The client exists only once in source control. Go and Zig stage it into ignored
generated directories before compiling because their embedding mechanisms do
not permit files outside the package root. Rust embeds `client/` directly at
compile time. Bun loads the shared tree into memory at startup. Node serves it
from its canonical location.

## Build and verify

Install the root Node dependencies, Bun, Go, Rust, and Zig 0.13.0. Then run:

```bash
npm run build
npm run check
npm run parity
```

If Zig 0.13 is not your default `zig`, set `ZIG_BIN`:

```bash
ZIG_BIN=/path/to/zig-0.13.0/zig npm run build:zig
```

`npm run parity` starts every release implementation in turn and runs the same
black-box HTTP, Socket.IO, lifecycle, validation, isolation, and movement checks.

## Benchmark

```bash
npm run build
BENCH_REPETITIONS=3 bash benchmarks/run-benchmarks.sh node bun go rust zig
node benchmarks/report.js node bun go rust zig
```

Raw results are written under ignored `.scratch/`; the checked-in methodology
and latest results live in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).
