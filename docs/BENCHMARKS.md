# Zig optimization and benchmark report

Measured 2026-08-24 on Linux with an AMD Ryzen 7 5700G (8 cores / 16 threads,
up to 4.67 GHz) and Zig 0.16.0 `-O ReleaseFast -fstrip`.

## Outcome

The production result is a Zig-only server using raw RFC 6455 WebSockets,
binary input, binary snapshot v1, one epoll I/O reactor, and game workers that
expand at 128 lobbies per worker. The measured 12,000-player configuration used
750 lobbies, six game workers, and seven process threads in total.

At the top stage it sustained:

- **12,000 concurrent players** with zero join failures and zero sampled
  disconnects;
- **181,931.2 received snapshots/s**;
- **66.675 / 68.225 / 69.359 ms** client cadence p50/p95/p99;
- **115.18% process CPU** (where 100% is one logical CPU);
- **21,381,120 B RSS** (20.39 MiB) and **26,775,552 B VM** (25.54 MiB);
- **32,299,021.8 B/s** application egress and **177.53 B** average measured
  snapshot/frame;
- **0.186 / 0.226 / 0.244 ms** per-lobby tick p50/p95/p99;
- **12,764 file descriptors** at the sample point.

The fixed 15 Hz simulation means the useful target is complete delivery at a
stable cadence, not an unbounded request counter. The slight 1.0107 delivery
ratio and rate above 180,000/s are five-second sampling-boundary effects, not a
simulation frequency above 15 Hz.

## Final 12,000-player methodology

- Server and load clients ran over loopback on the same host.
- Players were staged cumulatively at 1,000, 3,000, 6,000, 9,000, then 12,000.
- Each lobby held 16 stationary joined players. Stationary players exercise
  connection state, 15 Hz scheduling, serialization, and full fan-out without
  confounding the result with random deaths/rejoins or long synthetic snakes.
- Sixteen Node.js load-generator processes opened raw `/ws` connections, sent
  the same binary join packet as the browser, parsed and bounds-checked every
  binary snapshot, and recorded receive cadence.
- Each stage had a three-second warm-up and a five-second measured window.
- CPU, RSS, VM, thread count, and file descriptors came from `/proc/<pid>`.
  Byte/frame counters and per-lobby timing came from `/debug/stats` deltas.
- Join latency includes intentionally batched connection establishment. Its
  long tail is therefore a capacity-ramp result rather than single-user steady
  state request latency.
- This is a local server/fan-out capacity test. Internet RTT, TLS termination,
  proxies, NIC limits, packet loss, and browser rendering are not represented.

Raw evidence: `.scratch/mass-zig.json` (ignored local benchmark output).

## Scaling results

| Players | Lobbies | Game workers | Snapshots/s | Fail/disconnect | CPU | RSS | VM | Egress B/s | Avg wire | Cadence p50/p95/p99 ms | Tick p50/p95/p99 ms | FDs |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 1,000 | 63 | 1 | 15,000.0 | 0 / 0 | 7.99% | 3,031,040 | 7,569,408 | 2,581,701.6 | 172.11 B | 66.678 / 67.254 / 67.697 | .141 / .174 / .205 | 1,069 |
| 3,000 | 188 | 2 | 45,000.0 | 0 / 0 | 24.16% | 6,512,640 | 11,173,888 | 7,824,787.0 | 173.88 B | 66.667 / 67.370 / 68.079 | .149 / .192 / .207 | 3,196 |
| 6,000 | 375 | 3 | 90,798.6 | 0 / 0 | 50.26% | 11,468,800 | 15,888,384 | 15,973,446.0 | 175.92 B | 66.671 / 67.615 / 69.076 | .156 / .211 / .237 | 6,385 |
| 9,000 | 563 | 5 | 136,676.2 | 0 / 0 | 85.18% | 16,760,832 | 21,123,072 | 24,169,081.6 | 176.83 B | 66.653 / 68.569 / 73.319 | .193 / .244 / .324 | 9,575 |
| 12,000 | 750 | 6 | **181,931.2** | **0 / 0** | **115.18%** | **21,381,120** | **26,775,552** | **32,299,021.8** | **177.53 B** | **66.675 / 68.225 / 69.359** | **.186 / .226 / .244** | **12,764** |

Join p50/p95/p99 was 95.74/1,092.35/1,099.82 ms at 1,000 and
138.81/1,464.10/2,093.06 ms at 12,000. All 12,000 eventually joined. The 9,000
stage had the largest cadence p99 (73.319 ms), while the 12,000 stage returned
to 69.359 ms; that non-monotonicity is another reason to report all stages and
not extrapolate from one sample.

The measured `serializeUs` section includes snapshot construction plus its
broadcast calls. At 12,000 players it was 181.483/220.317/235.876 us
p50/p95/p99 (342.538 us max), accounting for most of the 186/226/244 us
per-lobby tick. The data does not support spending complexity on the remaining
few microseconds of scalar game logic.

## CPU and deployment recommendation

The 12,000-player loopback run consumed about 1.15 logical CPUs on the Ryzen 7
5700G while six game workers and the reactor preserved the target cadence. A
modern **2-core CPU is the measured compute floor** for this exact stationary,
unencrypted workload, but it leaves too little room for TLS, kernel networking,
moving/growing snakes, monitoring, or noisy neighbors. A **modern 4 physical
core CPU is the practical recommendation** for 12,000 players, with at least
eight cores when colocating TLS/proxying, load generation, or other services.

Clock speed and predictable single-core latency matter more than a very large
core count at this scale: only six game workers were required, and each worker
still processes its assigned lobbies sequentially. The tested 8-core/16-thread
Ryzen 7 5700G is comfortably above the compute requirement.

Network capacity is more likely to constrain deployment. Measured application
egress was 32.30 MB/s, about 258.4 Mbit/s before TCP/IP, WebSocket, retransmit,
and TLS overhead. Use at least a **1 Gbit/s NIC/uplink** for the measured shape,
and remeasure with realistic snake lengths and production TLS before committing
capacity.

## Why 12,000 players use megabytes, not only kilobytes

The logical game payload is mostly small integers, but each player also has an
OS socket/file descriptor, a connection object, membership/output locks,
WebSocket parser state, retained input/output capacity, identity strings, map
entries, and allocator alignment. Lobbies add hash tables, PRNG state, pickup
arrays, metrics, mutexes, and reusable wire buffers. Process RSS does not
include all kernel socket memory, and the separate client/load-generator memory
is not included either.

Even with those costs the measured Zig process RSS was only 20.39 MiB at
12,000 players: about **1,782 bytes of process RSS per concurrent player**,
including shared server state. Reducing that further is possible, but at this
point network fan-out and the kernel's per-socket cost matter more than storing
the game integers.

## Wire-format microbenchmark

Representative world: 16 players, 18 cells per snake, three bonus apples, one
drop, and one golden apple. The harness ran 100,000 encode and parse iterations.
These are format/harness microbenchmarks, not Zig server tick timings.

| Layout | Tick bytes | One-time roster | Encode/op | Parse/op |
|---|---:|---:|---:|---:|
| Legacy JSON objects | 7,164 B | - | 21.4 us | 33.2 us |
| Compact self-contained JSON arrays | 2,704 B | - | 6.2 us | 7.9 us |
| Separate roster + compact JSON tick | 1,952 B | 785 B | 5.204 us | 6.023 us |
| Separate roster + binary snapshot v1 | **725 B** | 785 B | **1.366 us** | **0.310 us** |

Against the already-compact roster JSON tick, binary cut the repeated snapshot
by 62.9%, encode time by 73.8%, and parse time by 94.9%. The real 12,000-player
average was smaller (177.53 B) because those stationary snakes contained one
cell rather than the synthetic 18 cells.

The binary layout favors simple bounds-checked scalar loads/stores. SIMD was
not added: rows are short and variable length, serialization-plus-broadcast is
under 0.25 ms at p99 per lobby, and the measurable costs are fan-out/syscalls
and network bytes. SIMD would need a targeted benchmark on long-snake or
collision-heavy workloads before its added complexity could be justified.

## Adaptive workers versus the 8-worker JSON load-generator overload attempt

An earlier experiment assigned one 128 KiB server thread to every lobby and
used the then-current JSON stream. With eight (8) client load-generator processes,
it successfully joined 12,000 players, but only 9,314 remained concurrent in
the measured window and 1,820 disconnects were observed. It used 752 server
threads, 228,618,240 B RSS, 331,005,952 B VM, 109.04% CPU, and 41,605,991.8 B/s
egress. This was an overload/failure result, not a successful 12,000-player
capacity claim.

The attempt exposed both load-generator pressure and the poor memory/scheduler
shape of one thread per lobby. It was replaced with 128 lobbies per worker and
16 client generators for the final run. At the same requested population the
final server held all 12,000 connections with no sampled disconnects, used six
game workers, and reduced RSS by 90.6% and VM by 91.9%. Raw evidence:
`.scratch/mass-zig-8workers-overload.json`.

## Accelerated lifecycle memory regression

`npm run test:memory` launches an isolated server and runs four consecutive
waves of 1,000 players across 63 temporary lobbies per wave. It accelerates the
60-second empty-lobby lifetime to 60 ms (**1,000x lifecycle acceleration**),
then verifies that players, connections, and temporary lobbies return to zero,
approximately zero, and one respectively after every wave.

| Point | RSS | Players | Connections | Lobbies |
|---|---:|---:|---:|---:|
| Baseline | 1,339,392 B | 0 | 2 | 1 |
| Wave 1 active / recovered | 3,457,024 / 3,461,120 B | 1,000 / 0 | 1,002 / 2 | 64 / 1 |
| Wave 2 active / recovered | 3,825,664 / 3,825,664 B | 1,000 / 0 | 1,002 / 1 | 64 / 1 |
| Wave 3 active / recovered | 4,198,400 / 4,202,496 B | 1,000 / 0 | 1,001 / 1 | 64 / 1 |
| Wave 4 active / recovered | 4,202,496 / 4,202,496 B | 1,000 / 0 | 1,001 / 1 | 64 / 1 |

All assertions passed. Recovered RSS grew by 741,376 B from the first to fourth
recovery, with a fitted slope of 260,096 B/wave, both below the 4 MiB and
1 MiB/wave regression limits. RSS does **not** immediately fall when small
allocations are freed because the allocator retains pages for reuse; claiming a
per-wave RSS drop would therefore be misleading. The leak signal is zero live
game resources plus bounded, flattening recovered RSS. Raw evidence:
`.scratch/memory-ramp-zig.json`.

## Stress and malformed-input validation

The raw-WebSocket parity/stress suite also covered:

| Check | Result |
|---|---|
| Capacity enforcement | 99 joined, 21 cleanly rejected |
| Idle WebSockets | 4,000/4,000 held; 6,696,960 B server RSS |
| 4,000-socket ramp | 2.204 s for the final ramp step |
| Lobby flood | 200 created in 17 ms |
| Malformed/oversized traffic | 100 raw cases; server alive; tick p95 67 ms |
| Connection churn | 200 cycles in 1.582 s; zero failures |
| Throttled clients | 66.7 ms average, 68 ms p95/max |
| Recovery | successful in 5 s; tick p50/p95/p99 67/68/68 ms |

Zig unit tests additionally cover minimal WebSocket header lengths, malformed
and partial binary client packets, snapshot bounds/clamping, player turn rules,
and serializer edge cases. The browser parser validates every variable-length
section before state mutation.

## Historical retired-server comparison (not side-by-side with final Zig)

The following numbers are preserved from the earlier Socket.IO/Engine.IO JSON
benchmark on the same machine. Bun was deleted before the raw-WebSocket binary
revision, so it was **not rerun side by side** with the current server. These
numbers explain the retirement decision but must not be presented as a current
apples-to-apples binary-protocol comparison.

| Historical metric | Earlier optimized Zig JSON | Historical Bun JSON | Historical winner |
|---|---:|---:|---|
| Median connection rate | 1,852/s | 1,923/s | Bun by 3.7% |
| Connection p95 / p99 | 17.72 / 19.65 ms | 20.64 / 21.45 ms | Zig |
| 80-bot messages | 1,119.4/s | 1,118.2/s | Tie |
| Average tick | 267.6 B | 2,170.8 B | Zig, 87.7% smaller |
| 80-bot wire rate | 231.2 KiB/s | 1.99 MiB/s | Zig |
| 80-bot RSS | 1.56 MiB | 57.80 MiB | Zig |
| RSS at 4,000 sockets | 6.39 MiB | 58.65 MiB | Zig |
| Peak RSS | 6.51 MiB | 84.14 MiB | Zig |
| Peak CPU | 30% | 25% | Bun by 5 points |
| Maximum threads | 1 | 12 | Zig |

On that retired workload the earlier optimized Zig implementation was the
overall winner for bandwidth, memory, tail latency, and thread count; Bun won
median connection rate and sampled peak CPU. The current raw/binary Zig server
is the only maintained implementation and has substantially better absolute
wire and 12,000-connection results, but there is no responsible current
Zig-versus-Bun winner claim without rebuilding Bun around the same protocol and
rerunning identical workloads.

### Historical Zig optimization progression

| Historical metric | Zig 0.13 baseline | Direct Zig 0.16 port | Earlier optimized Zig JSON |
|---|---:|---:|---:|
| Median connection rate | 1,724/s | 1,923/s | 1,852/s |
| 80-bot messages | 1,096.5/s | 1,098.7/s | 1,119.4/s |
| Average tick | 2,123 B | 2,059.7 B | 267.6 B |
| RSS at 4,000 sockets | 132.61 MiB | 2.02 GiB | 6.39 MiB |
| Peak RSS | 135.50 MiB | 2.07 GiB | 6.51 MiB |
| Peak CPU | 288.6% | 185.0% | 30.0% |
| Maximum threads | 8,006 | 8,006 | 1 |

The large direct-port memory result was caused by two threads per connection
and their stacks. Replacing that model with epoll produced most of the memory
and scheduler gain. The later raw-WebSocket, binary snapshot, modular source,
and adaptive game-worker changes are the production architecture described in
the rest of this report.
