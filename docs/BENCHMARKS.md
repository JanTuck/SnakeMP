# SnakeMP server benchmark report

Generated 2026-08-24T10:37:21.327Z from the exact release artifacts in this repository.

## Test environment

- Hardware: AMD Ryzen 7 5700G with Radeon Graphics; 16 logical CPUs; 30.70 GiB RAM.
- OS: Fedora Linux 44 (Workstation Edition); kernel 7.1.9-200.fc44.x86_64; x64.
- Toolchains: Node v24.18.0; Bun 1.3.14; go version go1.26.6-X:nodwarf5 linux/amd64; rustc 1.97.1 (8bab26f4f 2026-07-14); cargo 1.97.1 (c980f4866 2026-06-30); Zig 0.13.0.
- File-descriptor soft limit: 65,535 for benchmark server and client processes.

## Builds and benchmark architecture

- Node runs the reference entry point directly; compile time is not included in runtime measurements.
- Bun: `bun build --target=bun --minify`. Go: `go build -trimpath -ldflags="-s -w"`. Rust: release profile with opt-level 3, LTO, one codegen unit, abort-on-panic, and stripping. Zig: `-O ReleaseFast -fstrip`.
- `benchmarks/build-release.js` builds all artifacts before any server is started. Reported build time is a warm-cache build and excludes dependency/toolchain download.
- One server runs at a time on loopback. The Node Socket.IO v2 benchmark client uses WebSocket transport only. The same payloads, lobby distribution, durations, and concurrency targets are used for every implementation.
- Server RSS/CPU/thread/FD samples are taken every 200 ms from `/proc`. In-band `/debug/stats` captures idle and phase-specific RSS. Build time is never mixed into runtime data.

## Workload and repetition policy

- Equal 5-second warm-up for every implementation, including Node and Bun JIT/runtime warm-up.
- Three repetitions per baseline, connection-establishment, normal-load, and HTTP phase. Tables aggregate combined samples; connection rates are medians of runs.
- Baseline: idle server, then one joined observer. Normal load: 5, 10, 20, 40, and 80 moving/rejoining bots for 6 seconds per repetition after warm-up.
- Connection establishment is measured separately: 100 WebSocket connections, concurrency 25. Normal-load message rate counts actual `gameTick` messages received by bots, so the metric represents server fan-out rather than a synthetic request loop.
- Stress: protocol cap enforcement, idle WebSocket ramp to 4,000, lobby flood, malformed/oversized input, rapid churn, slow clients, then a 5-second recovery observation.
- The load generator records its own CPU in every normal-load run. It remained well below one full CPU core; values are included below so client saturation is visible.

## Runtime summary

| implementation | conn/s median | connect p50 / p95 / p99 | 80-bot msg/s | tick p50 / p95 / p99 | input p50 / p95 / p99 | idle RSS | 80-bot RSS | peak RSS | peak CPU |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| node | 1,852 | 13.6 ms / 20.3 ms / 20.6 ms | 1,115 | 66.0 ms / 69.0 ms / 69.0 ms | 66.0 ms / 67.0 ms / 67.0 ms | 71.72 MiB | 98.58 MiB | 218.64 MiB | 130.0% |
| bun | 1,923 | 11.3 ms / 20.6 ms / 21.5 ms | 1,118 | 66.0 ms / 67.0 ms / 67.0 ms | 66.0 ms / 67.0 ms / 67.0 ms | 49.39 MiB | 57.80 MiB | 84.14 MiB | 25.0% |
| go | 1,786 | 13.1 ms / 17.7 ms / 18.5 ms | 1,113 | 67.0 ms / 68.0 ms / 68.0 ms | 67.0 ms / 67.0 ms / 68.0 ms | 9.93 MiB | 18.02 MiB | 93.19 MiB | 65.0% |
| rust | 1,266 | 13.8 ms / 27.1 ms / 30.7 ms | 1,108 | 67.0 ms / 67.0 ms / 68.0 ms | 67.0 ms / 67.0 ms / 67.0 ms | 2.66 MiB | 8.48 MiB | 117.89 MiB | 295.0% |
| zig | 1,724 | 12.1 ms / 18.3 ms / 19.5 ms | 1,097 | 67.0 ms / 67.0 ms / 68.0 ms | 67.0 ms / 67.0 ms / 67.0 ms | 620.00 KiB | 7.09 MiB | 135.50 MiB | 288.6% |

## Conclusions and performance winners

**Overall performance winner: Bun.** It had the highest median connection-establishment rate (1,923 connections/s), the highest observed 80-bot message rate (1,118 messages/s), the lowest stress CPU peak (25.0%), fast HTTP responses, zero unexpected failures, and full recovery. Its loaded/stress memory was also much lower than Node while avoiding the thread explosion seen in Rust and Zig.

- **Connection establishment:** bun won at a median 1,923 connections/s.
- **Sustained message fan-out:** bun was narrowly highest at 1,118 received game-tick messages/s. The spread is small because all implementations are deliberately rate-limited by the same 15 Hz game loop.
- **Idle and representative-load memory:** zig used the least idle RSS (620.00 KiB), and zig remained lowest at 80 bots (7.09 MiB).
- **Stress memory:** bun had the lowest sampled stress peak (84.14 MiB).
- **Standalone native binary:** zig was smallest at 476.27 KiB. Bun's 12.88 KiB bundle is smaller but requires the external Bun runtime, so it is not directly comparable to a native executable.
- **Gameplay latency:** effectively a tie. All p95/p99 tick intervals stayed around 67–69 ms, which is the intended 15 Hz cadence; input-to-visible-movement was likewise one tick.
- **Connection capacity:** a tie at the tested ceiling. Every server held 4,000 idle WebSocket connections with zero connection failures; the actual failure point is above the tested practical ceiling.
- **Recovery:** all five remained alive and returned to normal tick cadence. Node and Go retained most of their stress-allocated RSS after five seconds, while Rust and Zig released substantially more; retained RSS alone is not proof of a leak, but longer soak testing would be appropriate.
- **Architecture caveat:** Rust and Zig use two threads per connected transport in these ports. At 4,000 connections they reached roughly 8,000 threads; Bun, Node, and Go scale the same connection count without that thread count, making Bun the safer overall operational choice from this run.

## Load curve

| implementation | bots | msg/s | wire throughput | tick p50 | tick p95 | tick p99 | RSS | load-client CPU peak |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| node | 5 | 70 | 61.41 KiB/s | 66.0 ms | 67.0 ms | 67.0 ms | 79.35 MiB | 0.9% |
| node | 10 | 139 | 203.78 KiB/s | 66.0 ms | 67.0 ms | 67.0 ms | 80.40 MiB | 1.5% |
| node | 20 | 276 | 389.26 KiB/s | 66.0 ms | 67.0 ms | 67.0 ms | 74.82 MiB | 1.7% |
| node | 40 | 559 | 1002.72 KiB/s | 66.0 ms | 67.0 ms | 68.0 ms | 81.19 MiB | 3.4% |
| node | 80 | 1,115 | 1.91 MiB/s | 66.0 ms | 69.0 ms | 69.0 ms | 98.58 MiB | 5.5% |
| bun | 5 | 72 | 65.79 KiB/s | 66.0 ms | 67.0 ms | 67.0 ms | 53.04 MiB | 1.1% |
| bun | 10 | 144 | 231.66 KiB/s | 66.0 ms | 67.0 ms | 67.0 ms | 53.82 MiB | 1.4% |
| bun | 20 | 280 | 408.83 KiB/s | 66.0 ms | 67.0 ms | 67.0 ms | 54.33 MiB | 1.9% |
| bun | 40 | 562 | 1.03 MiB/s | 66.0 ms | 67.0 ms | 67.0 ms | 55.79 MiB | 3.2% |
| bun | 80 | 1,118 | 1.99 MiB/s | 66.0 ms | 67.0 ms | 67.0 ms | 57.80 MiB | 5.4% |
| go | 5 | 70 | 64.34 KiB/s | 67.0 ms | 68.0 ms | 68.0 ms | 14.88 MiB | 1.0% |
| go | 10 | 138 | 221.57 KiB/s | 67.0 ms | 68.0 ms | 68.0 ms | 15.68 MiB | 1.3% |
| go | 20 | 280 | 404.45 KiB/s | 67.0 ms | 68.0 ms | 68.0 ms | 15.89 MiB | 2.2% |
| go | 40 | 560 | 1.01 MiB/s | 67.0 ms | 68.0 ms | 69.0 ms | 16.09 MiB | 3.7% |
| go | 80 | 1,113 | 1.93 MiB/s | 67.0 ms | 68.0 ms | 68.0 ms | 18.02 MiB | 5.6% |
| rust | 5 | 69 | 61.18 KiB/s | 67.0 ms | 67.0 ms | 67.0 ms | 7.59 MiB | 1.1% |
| rust | 10 | 141 | 222.70 KiB/s | 67.0 ms | 67.0 ms | 67.0 ms | 7.72 MiB | 1.4% |
| rust | 20 | 278 | 391.18 KiB/s | 67.0 ms | 67.0 ms | 67.0 ms | 7.80 MiB | 2.0% |
| rust | 40 | 550 | 976.79 KiB/s | 67.0 ms | 67.0 ms | 68.0 ms | 8.03 MiB | 3.4% |
| rust | 80 | 1,108 | 1.91 MiB/s | 67.0 ms | 67.0 ms | 68.0 ms | 8.48 MiB | 5.5% |
| zig | 5 | 72 | 65.40 KiB/s | 67.0 ms | 67.0 ms | 67.0 ms | 2.11 MiB | 1.2% |
| zig | 10 | 141 | 211.77 KiB/s | 67.0 ms | 67.0 ms | 67.0 ms | 2.44 MiB | 1.5% |
| zig | 20 | 282 | 398.69 KiB/s | 67.0 ms | 67.0 ms | 67.0 ms | 3.10 MiB | 2.2% |
| zig | 40 | 559 | 1011.00 KiB/s | 67.0 ms | 67.0 ms | 67.0 ms | 4.45 MiB | 3.4% |
| zig | 80 | 1,097 | 1.88 MiB/s | 67.0 ms | 67.0 ms | 68.0 ms | 7.09 MiB | 6.2% |

## Stress, limits, and recovery

| implementation | player-cap result | highest stable idle connections | approximate failure point | churn failures | survived hostile input | recovery p95 | recovery RSS | recovered |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| node | 99 joined / 21 rejected | 4,000 | >4,000 not established | 0 | yes | 67.0 ms | 216.81 MiB | yes |
| bun | 99 joined / 21 rejected | 4,000 | >4,000 not established | 0 | yes | 67.0 ms | 64.41 MiB | yes |
| go | 99 joined / 21 rejected | 4,000 | >4,000 not established | 0 | yes | 67.0 ms | 92.96 MiB | yes |
| rust | 99 joined / 21 rejected | 4,000 | >4,000 not established | 0 | yes | 67.0 ms | 58.12 MiB | yes |
| zig | 99 joined / 21 rejected | 4,000 | >4,000 not established | 0 | yes | 67.0 ms | 21.16 MiB | yes |

Expected cap rejections are protocol behavior, not benchmark errors. Unexpected HTTP failures, connection failures, timeouts, and crashes are reported in the phase data and server logs under `.scratch/results/`.

## HTTP operation latency

| implementation | operation | p50 | p95 | p99 | failures |
|---|---|---:|---:|---:|---:|
| node | GET / | 9.0 ms | 14.0 ms | 20.0 ms | 0 |
| node | POST /joingame | 7.0 ms | 12.0 ms | 15.0 ms | 0 |
| bun | GET / | 5.0 ms | 9.0 ms | 12.0 ms | 0 |
| bun | POST /joingame | 4.0 ms | 8.0 ms | 11.0 ms | 0 |
| go | GET / | 5.0 ms | 9.0 ms | 12.0 ms | 0 |
| go | POST /joingame | 4.0 ms | 7.0 ms | 10.0 ms | 0 |
| rust | GET / | 5.0 ms | 9.0 ms | 11.0 ms | 0 |
| rust | POST /joingame | 5.0 ms | 9.0 ms | 10.0 ms | 0 |
| zig | GET / | 5.0 ms | 8.0 ms | 12.0 ms | 0 |
| zig | POST /joingame | 4.0 ms | 8.0 ms | 9.0 ms | 0 |

## Static project metrics

| implementation | source LOC | release artifact | clean implementation folder | folder incl. build output | warm-cache build |
|---|---:|---:|---:|---:|---:|
| node | 678 | — | 25.28 KiB | 25.28 KiB | 61.7 ms |
| bun | 907 | 12.88 KiB | 31.89 KiB | 44.77 KiB | 7.4 ms |
| go | 1,673 | 6.18 MiB | 40.07 KiB | 6.40 MiB | 55.8 ms |
| rust | 2,390 | 724.45 KiB | 75.17 KiB | 149.62 MiB | 38.4 ms |
| zig | 2,060 | 476.27 KiB | 75.72 KiB | 128.12 MiB | 5908.6 ms |

Go, Rust, and Zig artifacts are already stripped, so the release-artifact and stripped-binary sizes are identical. Bun reports its minified bundle; Node has no standalone build artifact. Generated client staging, dependency caches, and build output are excluded from clean-folder and LOC totals.

## Caveats and interpretation

- The game intentionally caps active players at 100 and each lobby at 16. The idle-connection break test exercises transport capacity beyond that gameplay cap.
- Loopback removes real network variance; results compare server/runtime overhead on this machine, not internet performance.
- A single Node load-generator process was sufficient at these targets based on recorded client CPU. For substantially larger active-message tests, shard the generator across processes or hosts.
- Message rates count received game ticks across load clients. Other low-rate feed/init/death events are not included, so this is a conservative protocol-message rate.
- No implementation receives implementation-specific warm-up, payloads, or durations. Random spawn/collision timing still introduces ordinary run-to-run variance, which is why repeated runs are aggregated.
- Highest throughput, lowest latency, smallest memory footprint, smallest artifact, and highest connection capacity are separate outcomes; no single “fastest” label is implied.

## Reproduction

```bash
npm ci
ZIG_BIN=/path/to/zig-0.13.0/zig node benchmarks/build-release.js
BENCH_REPETITIONS=3 bash benchmarks/run-benchmarks.sh node bun go rust zig
node benchmarks/report.js node bun go rust zig
```

Run on an otherwise idle Linux machine. Keep the same CPU governor, file-descriptor limit, runtime/compiler versions, and concurrency targets. Raw JSON and logs are intentionally ignored; archive them separately when independently reproducing a run.
