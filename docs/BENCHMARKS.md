# Zig optimization and benchmark report

Measured 2026-08-24 on Linux with an AMD Ryzen 7 5700G (8 cores / 16 threads,
up to 4.67 GHz) and Zig 0.16.0 `-O ReleaseFast -fstrip`.

## Outcome

The production result is a Zig-only server using raw RFC 6455 WebSockets,
binary input, binary snapshot v3, one epoll I/O reactor, and game workers that
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

Player identities now borrow the owning connection's inline 22-byte session ID
instead of allocating a duplicate. At 12,000 players this deterministically
removes 12,000 live allocations, 264,000 requested bytes, and about 384,000
bytes of allocator size-class slots. The connection outlives its player, and
teardown removes the lobby membership entry before releasing either object.

Lobby membership is capped at 16 and needs stable iteration, append, and
known-pointer ordered removal—not key lookup—so it now uses a pointer list
instead of a string hash map. `npm run bench:player-container` validates exact
insertion/removal order and measures the median of nine ReleaseFast samples:

| 16-player container | Live requested | Allocations | Fill | Remove/refill |
|---|---:|---:|---:|---:|
| String array map | 712 B | 3 | 136 ns | 47 ns |
| Pointer array list | 136 B | 1 | 39 ns | 8 ns |

This cuts persistent requested container memory by 80.9%, makes a full-lobby
fill 3.49x faster, and makes ordered removal/refill 5.88x faster. Across 750
full lobbies the requested backing-memory reduction is about 432,000 bytes;
actual RSS depends on allocator size classes.

## Snapshot v3 production-encoder benchmark

The current encoder was measured directly in Zig with 16 players, a retained
output buffer, periodic keyframes, and stationary and moving delta streams. The
harness reports the median of five samples and is reproducible with
`cd servers/zig && zig run -O ReleaseFast bench_snapshot.zig`.

| Cells/player | Stream | v3 ns/frame | v3 payload B/frame |
|---:|---|---:|---:|
| 1 | keyframe / stationary / moving | 240 / 138 / 209 | 140 / 31.73 / 31.73 |
| 18 | keyframe / stationary / moving | 1,101 / 167 / 337 | 220 / 34.40 / 34.40 |
| 256 | keyframe / stationary / moving | 13,463 / 572 / 1,083 | 1,164 / 65.89 / 65.89 |

Against the immediately preceding v2 encoder on the same harness, direction
deltas removed two absolute-coordinate bytes from every moving player row.
Moving streams fell by 47-49% for one- and 18-cell snakes (31.9% at 256 cells,
where periodic keyframes dominate more bytes), while encode time fell by
20-26% for the representative short bodies. Stationary v3 streams also encoded
14-19% faster at one and 18 cells because player transition state is computed
once per frame.

A separate 1,000-client v3 loopback run held all 1,000 clients with zero join
failures or sampled disconnects, a 0.9992 configured-tick ratio, and
66.659/67.449/68.864 ms cadence p50/p95/p99. It measured 34.48 B average
userspace WebSocket write, 515,575 B/s egress, 8.97% CPU, and 2,838,528 B RSS.
The earlier 1,000-player v2 scaling row below measured 172.11 B average wire and
2,581,702 B/s egress; the workloads were both stationary but were separate
runs, so this is evidence of the intended byte reduction rather than a formal
paired performance trial.

## Fan-out accounting and tick scratch

Snapshot fan-out previously performed one global byte-counter and one global
frame-counter atomic operation per client per tick. The current path totals
direct writes locally and commits each counter once per lobby broadcast; queued
suffix bytes remain counted by the reactor when written. At 16 players per
lobby this removes 93.75% of those diagnostic read-modify-write operations
(about 360,000/s to 22,500/s at 12,000 players). When `SNEK_DEBUG` is disabled,
all diagnostic network atomics are now omitted from the production hot path.

A paired 1,000-player, four-second v3 trial against isolated before/after
binaries kept exactly 1,000 clients, zero join failures/disconnects, a 1.0
delivery ratio, and approximately 14,967 frames/s and 510.4 KB/s in both runs.
CPU was 8.48% in both samples. Fan-out p50/p95/p99 was
136.679/182.786/217.892 us before and 143.181/190.851/215.949 us after; that
single end-to-end sample is noise-scale and does not establish a whole-server
latency improvement. It does verify that batching preserved accounting,
delivery, and cadence while removing the deterministic cross-worker atomic
operation count.

The worker tick also replaced two arena-backed pointer lists with bounded
16-player stack arrays, uses the collision index's active mask instead of a
string-map lookup for tombstones, and samples wall time once per packed worker
tick instead of once per lobby. `bench_tick_scratch.zig`, using 16 players and
128 lobbies per worker and reporting the median of five samples, measured:

| Operation | Before | After | Reduction |
|---|---:|---:|---:|
| Snapshot + graveyard scratch | 16.96 ns/lobby | 3.90 ns/lobby | 77.0% |
| Realtime sampling | 2,585.12 ns/worker tick | 20.37 ns/worker tick | 99.2% |

The benchmark is reproducible with
`cd servers/zig && zig run -O ReleaseFast bench_tick_scratch.zig`. At 750 active
lobbies the fixed arrays also remove 22,500 arena allocation API calls per
second; these were cheap retained-arena bump allocations, not 22,500 backing
heap allocations.

Visibility bandwidth must distinguish ordinary deltas from complete recovery
keyframes. With the measured 16-player, 18-cell v3 stream (28 B delta, 220 B
keyframe, one periodic keyframe per 30 foreground snapshots), one foreground
client consumes 516 B/s of application snapshot payload and one hidden client
at 1 Hz consumes 220 B/s: a **57.36%** reduction, not the naive 93.33% cadence
ratio. `node benchmarks/visibility-bandwidth.js` projects mixed-client totals
with those payload classes separately.

## HTTP pipeline compaction benchmark

The HTTP parser previously removed every completed request from the front of
its receive buffer immediately. A large pipeline therefore moved all remaining
bytes once per request, making buffer copies grow quadratically. It now parses
with an offset and compacts the buffer once when the batch is complete.

`npm run bench:http-pipeline` sends minimal keep-alive requests over one
loopback connection, validates the exact number and ordering of responses, and
reports the median of three ReleaseFast samples. The client write-half-closes
after the batch, so the harness also verifies that a normal TCP FIN does not
discard buffered requests. Timing includes response I/O; the smallest batch is
correspondingly noisy. The staged measurements were:

| Requests | Original | One input compaction | + 64-iovec output batches |
|---:|---:|---:|---:|
| 64 | 0.833 ms | 1.602 ms | 0.543 ms |
| 256 | 2.976 ms | 1.828 ms | 0.646 ms |
| 1,024 | 11.302 ms | 6.531 ms | 1.257 ms |
| 2,048 | 23.063 ms | 13.181 ms | 1.919 ms |
| 4,096 | 65.380 ms | 24.696 ms | 4.462 ms |
| 6,240 | 129.133 ms | 39.096 ms | **7.289 ms** |

At 6,240 minimal 21-byte requests, the old parser moved about 390 MiB of buffer
contents. The offset parser performs one final compaction and returned all
6,240 responses in order. Protocol parity tests additionally cover partial
trailing requests, request bodies followed by another request, `Connection:
close`, headerless HTTP/1.0 requests, and a WebSocket frame coalesced with its
upgrade request.

Pipelined responses now retain their copied headers and borrowed static bodies
until the input batch is parsed, then drain up to 64 owned, borrowed, or shared
segments per `writev`. Standalone HTTP requests and WebSocket publication keep
their direct zero-copy fast paths. At 6,240 requests, output batching is 81.4%
faster than input compaction alone and 94.4% faster than the original parser.
The harness also returned all 6,240 responses after the client deliberately
paused reads for 500 ms (508.260 ms total), while unit tests exercise partial
writes across every output ownership type with exact byte/refcount accounting.

## Browser startup dependency cleanup

The production rendering graph previously imported four wrapper/preload
modules that did not contribute behavior, including an unused 3,656-byte swords
image. Food state is now represented by the two coordinates the renderer uses,
and the dead modules, image, embedded routes, and credit entry are removed.

The exact graph test walks every relative import from `rendering.js`, verifies
all nine remaining modules are embedded, and rejects reintroduction of the five
obsolete routes. The change removes five browser requests, four JavaScript
modules, 4,880 bytes of startup payload, and 4,944 bytes of embedded asset
bodies. It does not change visuals or game behavior.

Backpressured output queues now compact released descriptor prefixes after 64
items once the prefix is at least half the array, retain at most 256 descriptors
after completely draining, and cap live WebSocket items at 4,096 in addition to
the four MiB byte cap. Previously, a connection that continuously made partial
progress without fully draining could retain every consumed descriptor; at 15
snapshots/s that stale metadata alone could grow by roughly 31 MiB per day per
connection. The queue unit test preserves a partially written live head and
exact byte accounting across compaction.

Empty-lobby reaping also changed from duplicated-ID collection plus ordered map
removal to an allocation-free in-place swap removal. Expiring all 4,095
temporary lobbies at the default cap previously shifted 8,382,465 later map
entries—at least 191.9 MiB of key/value movement—whereas the new pass visits
and removes each lobby once. `npm run bench:lobby-reap` excludes map setup,
validates the exact permanent survivor and removed-value checksum, and reports
the median of seven ReleaseFast samples:

| Temporary lobbies | Ordered removal | Swap removal | Speedup |
|---:|---:|---:|---:|
| 64 | 5.022 us | 0.278 us | 18.06x |
| 1,000 | 866.824 us | 4.449 us | 194.84x |
| 4,095 | 14,712.030 us | 34.555 us | **425.76x** |

The isolated integration audit additionally verified all 64 temporary lobbies
were reaped and creation capacity recovered.

## Historical v1 wire-format microbenchmark

This older format-selection benchmark is retained to document why binary
replaced JSON. It predates the production v3 temporal format. Representative
world: 16 players, 18 cells per snake, three bonus apples, one drop, and one
golden apple. The harness ran 100,000 encode and parse iterations. These are
format/harness microbenchmarks, not current Zig server tick timings.

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
| Baseline | 1,347,584 B | 0 | 2 | 1 |
| Wave 1 active / recovered | 2,654,208 / 2,654,208 B | 1,000 / 0 | 1,002 / 2 | 64 / 1 |
| Wave 2 active / recovered | 2,748,416 / 2,748,416 B | 1,000 / 0 | 1,002 / 1 | 64 / 1 |
| Wave 3 active / recovered | 2,748,416 / 2,748,416 B | 1,000 / 0 | 1,001 / 1 | 64 / 1 |
| Wave 4 active / recovered | 2,748,416 / 2,748,416 B | 1,000 / 0 | 1,001 / 1 | 64 / 1 |

All assertions passed. Recovered RSS grew by 94,208 B from the first to fourth
recovery, with a fitted slope of 28,262 B/wave, both below the 4 MiB and
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
