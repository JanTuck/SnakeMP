# SnakeMP

SnakeMP is a multiplayer snake game with one canonical browser client and two
maintained servers: an aggressively optimized Zig implementation and an
idiomatic Go implementation. The previous Node.js, Bun, and Rust servers were
retired after their benchmark history was preserved in `docs/BENCHMARKS.md`.

## Repository layout

```text
client/       canonical browser client and vendored browser bundles
docs/         protocol specification and benchmark history
servers/
  go/         net/http implementation
  zig/        Linux epoll implementation on the newest installed Zig
benchmarks/   parity, wire-format, load, stress, and metrics tooling
```

Go and Zig stage `client/` into ignored generated directories before compiling
so there is only one tracked client source tree.

## Build and verify

The production Zig server has no Node.js dependency. Install Node.js only for
the parity/load drivers, plus Go if you want to build the secondary server.
The build uses the `zig` found on `PATH`; set `ZIG_BIN` only to select a newer
installed binary.

```bash
npm install
npm run build
npm run check
npm run parity
```

Run Zig directly with:

```bash
bash servers/zig/build-assets.sh
(cd servers/zig && zig build-exe -O ReleaseFast -fstrip src/main.zig \
  -femit-bin=snek-zig --cache-dir .zig-cache --global-cache-dir .zig-global-cache)
PORT=3000 SNEK_DEBUG=1 servers/zig/snek-zig
```

## Benchmark

```bash
node benchmarks/wire-format-bench.js
BENCH_REPETITIONS=3 bash benchmarks/run-benchmarks.sh zig
```

Raw measurements are written beneath ignored `.scratch/`. The methodology,
before/after measurements, and historical Bun comparison are in
[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).
