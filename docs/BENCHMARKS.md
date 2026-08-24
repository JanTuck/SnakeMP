# Zig optimization and benchmark report

Measured 2026-08-24 on the same local Linux host and workload used by the
preserved multi-runtime benchmark. The final server was built with the newest
installed compiler, Zig 0.16.0, using `-O ReleaseFast -fstrip`.

## Result

**Overall performance winner: optimized Zig.** Historical Bun remains slightly
better in median connection establishment and sampled peak CPU, but optimized
Zig matches its rate-limited message throughput while using 87.7% fewer bytes
per tick, 89.1% less memory at 4,000 connections, 92.3% less peak RSS, one
thread instead of 12, and slightly better HTTP and connection-tail latency.

The Bun numbers below are the preserved same-machine benchmark history. Bun was
deleted at the user's request, so it was not rerun after the Zig-only compact
wire protocol was introduced. This is an honest historical comparison, not a
claim that the final two binaries were run side by side in this revision.

## Methodology

- WebSocket-only Socket.IO v2 / Engine.IO v3 connections over loopback.
- Three normal-load repetitions after equal 5-second warm-ups.
- Active-player tiers: 5, 10, 20, 40, and 80 bots; 6-second samples per tier.
- Connection test: 100 connections at concurrency 25, repeated three times.
- HTTP test: 300 requests at concurrency 50 per endpoint and repetition.
- One server process at a time; process RSS, CPU, threads, and FDs sampled every
  200 ms. Throughput counts messages actually received by clients.
- Stress suite: caps, 100→4,000 idle connections, 200-lobby flood, oversized
  and malformed traffic, 200 connection churn cycles, throttled clients, and
  five-second recovery. Full final sampled duration was 312.4 seconds.
- Wire candidates were compared for bytes plus 100,000 encode and parse
  iterations before choosing the protocol.

## Zig before and after

| Metric | Zig 0.13 baseline | Zig 0.16 port baseline | Optimized Zig 0.16 |
|---|---:|---:|---:|
| Connection rate, median | 1,724/s | 1,923/s | 1,852/s |
| 80-bot messages | 1,096.5/s | 1,098.7/s | 1,119.4/s |
| 80-bot wire rate | 1.88 MiB/s | 1.87 MiB/s | 231.2 KiB/s |
| Average 80-bot tick | 2,123 B | 2,059.7 B | 267.6 B |
| 80-bot RSS | 7.09 MiB | 72.22 MiB | 1.56 MiB |
| RSS at 4,000 sockets | 132.61 MiB | 2.02 GiB | 6.39 MiB |
| Sampled peak RSS | 135.50 MiB | 2.07 GiB | 6.51 MiB |
| Sampled peak CPU | 288.6% | 185.0% | 30.0% |
| Maximum threads | 8,006 | 8,006 | 1 |

Against the original Zig 0.13 implementation, the final server increased the
median connection rate by 7.4%, reduced 80-bot wire traffic by 88.0%, reduced
4,000-socket RSS and peak RSS by 95.2%, and reduced sampled peak CPU by 89.6%.
The direct Zig 0.16 port exposed an especially severe thread-stack cost; the
reactor reduced its 4,000-socket RSS by 99.7%.

## Wire-format decision

Representative test lobby: 16 players, 18 segments each, three bonus apples,
one drop, and one golden apple.

| JSON layout | Tick bytes | One-time roster | Encode CPU/op | Parse CPU/op |
|---|---:|---:|---:|---:|
| Legacy objects | 7,164 B | — | 21.4 µs | 33.2 µs |
| Compact self-contained arrays | 2,704 B | — | 6.2 µs | 7.9 µs |
| Separate roster + compact tick | **1,952 B** | 785 B | **5.2 µs** | **6.0 µs** |

The winning layout sends `r = [[id,name,color],...]` only when membership
changes. Each `tick` sends scores, body lengths, flattened cell coordinates,
pickups, and TTLs as positional arrays. Coordinates use grid cells rather than
pixel multiples. The result retains all required information without repeating
identity keys or object field names 15 times per second.

Under the real 80-bot load, average tick size fell from the Zig 0.16 baseline's
2,059.7 B to 267.6 B (87.0%). The main lobby's measured Zig serialization cost
at that tier averaged 138.3 µs, while total average tick work was about 0.2 ms.
The compatibility normalizer used by the benchmark client averaged 2.22 µs
(p95 5.27 µs, p99 12.20 µs) after Socket.IO parsing.

## Final load results

| Bots | Messages/s | Run-to-run rates | Wire rate | Avg tick | Tick p50/p95/p99 | RSS | Client CPU peak |
|---:|---:|---|---:|---:|---|---:|---:|
| 5 | 68.6 | 69.5 / 67.0 / 69.2 | 9.23 KiB/s | 137.0 B | 67/68/68 ms | 1.34 MiB | 1.1% |
| 10 | 142.9 | 142.0 / 142.1 / 144.7 | 31.35 KiB/s | 224.0 B | 67/68/68 ms | 1.35 MiB | 1.4% |
| 20 | 277.9 | 273.3 / 275.5 / 285.0 | 49.27 KiB/s | 205.0 B | 67/68/68 ms | 1.38 MiB | 2.1% |
| 40 | 545.6 | 549.8 / 539.2 / 547.8 | 114.54 KiB/s | 259.0 B | 67/68/68 ms | 1.44 MiB | 2.4% |
| 80 | **1,119.4** | 1,114.2 / 1,121.5 / 1,122.7 | 231.20 KiB/s | 267.6 B | 67/68/68 ms | 1.56 MiB | 4.8% |

The 15 Hz loop caps useful fan-out throughput, so stable cadence and resource
cost matter more here than an artificial unbounded request counter.

### Latency

| Measurement | p50 | p95 | p99 | Failures |
|---|---:|---:|---:|---:|
| Connection establishment | 12.15 ms | 17.72 ms | 19.65 ms | 0/300 |
| Input-to-observed-tick | 67 ms | 68 ms | 68 ms | 0 |
| GET `/` | 5 ms | 8 ms | 11 ms | 0/900 |
| POST `/joingame` | 4 ms | 7 ms | 9 ms | 0/900 |

Connection-rate repetitions were 1,449, 1,852, and 2,273/s. The range is why
the median, complete percentiles, and all run rates are reported instead of a
single best run.

## Stress and break-it behavior

| Check | Result |
|---|---|
| Player caps | 99 joined, 21 cleanly rejected |
| Idle connections | 4,000/4,000 held; 6.39 MiB server RSS |
| 4,000-socket open time | 2.20 s total ramp step |
| Lobby flood | 200 created in 17 ms |
| Malformed/oversized traffic | 100 raw cases; server stayed alive; tick p95 67 ms |
| Connection churn | 200 cycles in 1.58 s; zero failures |
| Throttled clients | tick average 66.7 ms, p95/max 68 ms |
| Recovery | recovered in the 5 s window; p50/p95/p99 67/68/68 ms |
| Process peak | 6.51 MiB RSS, 30% CPU, 1 thread, 4,007 FDs |

Across the full normal plus stress run the server recorded 32,468,490 bytes
sent, 5,201,119 bytes received, 138,679 outbound WebSocket frames, 31,920
inbound frames, and 21,567 input events. Average measured input event handling
was 5.77 µs. No sustained memory growth or post-overload tick degradation was
observed; final RSS was 6.51 MiB with only two live connections.

## Optimized Zig versus historical Bun

| Metric | Optimized Zig | Historical Bun | Winner |
|---|---:|---:|---|
| Median connection rate | 1,852/s | 1,923/s | Bun by 3.7% |
| Connection p95 / p99 | 17.72 / 19.65 ms | 20.64 / 21.45 ms | Zig |
| 80-bot messages | 1,119.4/s | 1,118.2/s | Tie (Zig +0.1%) |
| Average tick | 267.6 B | 2,170.8 B | Zig, 87.7% smaller |
| 80-bot wire rate | 231.2 KiB/s | 1.99 MiB/s | Zig, 88.7% lower |
| 80-bot RSS | 1.56 MiB | 57.80 MiB | Zig, 97.3% lower |
| RSS at 4,000 sockets | 6.39 MiB | 58.65 MiB | Zig, 89.1% lower |
| Peak RSS | 6.51 MiB | 84.14 MiB | Zig, 92.3% lower |
| Peak CPU | 30% | 25% | Bun by 5 points |
| Maximum threads | 1 | 12 | Zig |
| GET p95 / p99 | 8 / 11 ms | 9 / 12 ms | Zig |
| Join p95 / p99 | 7 / 9 ms | 8 / 11 ms | Zig |

### Why each wins where it does

- Zig's largest gains come from architectural work: epoll, one reactor/game
  loop, nonblocking incremental parsers, direct `writev`, retained buffers, and
  copying only under socket backpressure. Eliminating two threads per socket is
  responsible for most of the concurrency memory and scheduler improvement.
- The compact roster/tick protocol is responsible for most of the bandwidth
  and client JSON parse improvement.
- Bun still has the best sampled CPU peak and a slightly better median connect
  rate. Zig's one-millisecond tick/input difference is timer phase at a fixed
  15 Hz, not a meaningful simulation slowdown.
- Remaining Zig work is mostly diminishing-return territory: spatial collision
  indexing for much larger per-lobby caps, `sendmmsg` experiments for much
  larger fan-out, and browser-profiler validation of rendering work. None is
  justified by the current cap-16 lobby profile without new measurements.

## Validation completed

- Zig compilation and two Zig unit tests on 0.16.0.
- Go tests/vet and Zig formatting/test checks via `npm run check`.
- Full HTTP, Socket.IO, lifecycle, validation, lobby isolation, movement,
  reversal, chained-turn, death, and rejoin parity.
- Compact wire-format tests and legacy client compatibility.
- Split/partial HTTP request assembly and malformed-request recovery.
- Oversized WebSocket/events, malformed raw TCP, connection/disconnection,
  high concurrency, throttling, churn, overload, and recovery.
- Three repeated load iterations and a 312.4-second sampled run.

Raw local evidence is retained in ignored `.scratch/final/`, with pre-change
Zig baselines in `.scratch/baseline-013/` and `.scratch/baseline-016/`.
