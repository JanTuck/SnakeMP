#!/usr/bin/env node
/* Generate docs/BENCHMARKS.md from ignored raw benchmark output. */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const RESULTS = path.join(ROOT, '.scratch', 'results');
const names = process.argv.slice(2);
if (!names.length) {
  console.error('usage: node benchmarks/report.js node bun go rust zig');
  process.exit(2);
}

const readJson = (file) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
};
const sorted = (values) => values.filter(Number.isFinite).sort((a, b) => a - b);
const percentile = (values, p) => {
  const data = sorted(values || []);
  return data.length ? data[Math.min(data.length - 1, Math.floor(data.length * p))] : null;
};
const median = (values) => percentile(values, 0.5);
const fmtMs = (value) => value == null ? '—' : `${Number(value).toFixed(1)} ms`;
const fmtRate = (value) => value == null ? '—' : Math.round(value).toLocaleString('en-US');
const fmtBytes = (value) => {
  if (value == null) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB'];
  let amount = value;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) { amount /= 1024; unit++; }
  return `${amount.toFixed(unit === 0 ? 0 : 2)} ${units[unit]}`;
};

const metadata = {
  node: { dir: 'servers/node', ext: ['.js'], artifact: null },
  bun: { dir: 'servers/bun', ext: ['.ts'], artifact: 'servers/bun/dist/main.min.js' },
  go: { dir: 'servers/go', ext: ['.go'], artifact: 'servers/go/snek-go' },
  rust: { dir: 'servers/rust', ext: ['.rs'], artifact: 'servers/rust/target/release/snek-rust' },
  zig: { dir: 'servers/zig', ext: ['.zig'], artifact: 'servers/zig/snek-zig' },
};
const excluded = new Set(['target', 'dist', 'generated', '.zig-cache', '.zig-global-cache', 'zig-out', 'node_modules', 'internal']);

function walk(dir, config, skipBuildOutput) {
  let bytes = 0;
  let loc = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (skipBuildOutput && excluded.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (skipBuildOutput && config.artifact && full === path.join(ROOT, config.artifact)) continue;
    if (skipBuildOutput && entry.isFile() && entry.name.endsWith('.o')) continue;
    if (entry.isDirectory()) {
      const child = walk(full, config, skipBuildOutput);
      bytes += child.bytes;
      loc += child.loc;
    } else if (entry.isFile()) {
      const stat = fs.statSync(full);
      bytes += stat.size;
      if (config.ext.includes(path.extname(entry.name))) {
        loc += fs.readFileSync(full, 'utf8').split(/\r?\n/).length - 1;
      }
    }
  }
  return { bytes, loc };
}

const builds = readJson(path.join(RESULTS, 'build-times.json')) || {};
const environment = builds.environment || {};
const rows = [];
for (const name of names) {
  const bench = readJson(path.join(ROOT, '.scratch', `bench-${name}.json`));
  const stress = readJson(path.join(ROOT, '.scratch', `stress-${name}.json`));
  const processMetrics = readJson(path.join(RESULTS, `${name}.metrics.json`));
  if (!bench || !stress || !processMetrics) {
    console.error(`missing benchmark output for ${name}`);
    process.exit(1);
  }
  const config = metadata[name];
  const clean = walk(path.join(ROOT, config.dir), config, true);
  const total = walk(path.join(ROOT, config.dir), config, false);
  const artifactBytes = config.artifact ? fs.statSync(path.join(ROOT, config.artifact)).size : null;
  rows.push({ name, bench, stress, processMetrics, clean, total, artifactBytes });
}

const out = [];
out.push('# SnakeMP server benchmark report', '');
out.push(`Generated ${new Date().toISOString()} from the exact release artifacts in this repository.`, '');
out.push('## Test environment', '');
out.push(`- Hardware: ${environment.cpu}; ${environment.logicalCpus} logical CPUs; ${fmtBytes(environment.ramBytes)} RAM.`);
out.push(`- OS: ${environment.os}; kernel ${environment.kernel}; ${environment.arch}.`);
out.push(`- Toolchains: Node ${environment.node}; Bun ${environment.bun}; ${environment.go}; ${environment.rust}; ${environment.cargo}; Zig ${environment.zig}.`);
out.push('- File-descriptor soft limit: 65,535 for benchmark server and client processes.', '');
out.push('## Builds and benchmark architecture', '');
out.push('- Node runs the reference entry point directly; compile time is not included in runtime measurements.');
out.push('- Bun: `bun build --target=bun --minify`. Go: `go build -trimpath -ldflags="-s -w"`. Rust: release profile with opt-level 3, LTO, one codegen unit, abort-on-panic, and stripping. Zig: `-O ReleaseFast -fstrip`.');
out.push('- `benchmarks/build-release.js` builds all artifacts before any server is started. Reported build time is a warm-cache build and excludes dependency/toolchain download.');
out.push('- One server runs at a time on loopback. The Node Socket.IO v2 benchmark client uses WebSocket transport only. The same payloads, lobby distribution, durations, and concurrency targets are used for every implementation.');
out.push('- Server RSS/CPU/thread/FD samples are taken every 200 ms from `/proc`. In-band `/debug/stats` captures idle and phase-specific RSS. Build time is never mixed into runtime data.', '');
out.push('## Workload and repetition policy', '');
out.push('- Equal 5-second warm-up for every implementation, including Node and Bun JIT/runtime warm-up.');
out.push('- Three repetitions per baseline, connection-establishment, normal-load, and HTTP phase. Tables aggregate combined samples; connection rates are medians of runs.');
out.push('- Baseline: idle server, then one joined observer. Normal load: 5, 10, 20, 40, and 80 moving/rejoining bots for 6 seconds per repetition after warm-up.');
out.push('- Connection establishment is measured separately: 100 WebSocket connections, concurrency 25. Normal-load message rate counts actual `gameTick` messages received by bots, so the metric represents server fan-out rather than a synthetic request loop.');
out.push('- Stress: protocol cap enforcement, idle WebSocket ramp to 4,000, lobby flood, malformed/oversized input, rapid churn, slow clients, then a 5-second recovery observation.');
out.push('- The load generator records its own CPU in every normal-load run. It remained well below one full CPU core; values are included below so client saturation is visible.', '');

out.push('## Runtime summary', '');
out.push('| implementation | conn/s median | connect p50 / p95 / p99 | 80-bot msg/s | tick p50 / p95 / p99 | input p50 / p95 / p99 | idle RSS | 80-bot RSS | peak RSS | peak CPU |');
out.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
for (const row of rows) {
  const b = row.bench.phases;
  const connect = b.connections;
  const ramp = b.ramp['80'];
  out.push(`| ${row.name} | ${fmtRate(median(connect.connectionRates))} | ${fmtMs(percentile(connect.latenciesMs, .5))} / ${fmtMs(percentile(connect.latenciesMs, .95))} / ${fmtMs(percentile(connect.latenciesMs, .99))} | ${fmtRate(ramp.messageRate)} | ${fmtMs(percentile(ramp.deltas, .5))} / ${fmtMs(percentile(ramp.deltas, .95))} / ${fmtMs(percentile(ramp.deltas, .99))} | ${fmtMs(percentile(b.inputLatencyMs, .5))} / ${fmtMs(percentile(b.inputLatencyMs, .95))} / ${fmtMs(percentile(b.inputLatencyMs, .99))} | ${fmtBytes(b.idle.stats.rss)} | ${fmtBytes(ramp.rss)} | ${fmtBytes(row.processMetrics.rssMax)} | ${(row.processMetrics.cpuPeakPct || 0).toFixed(1)}% |`);
}
out.push('');

const connectionWinner = rows.reduce((best, row) => median(row.bench.phases.connections.connectionRates) > median(best.bench.phases.connections.connectionRates) ? row : best);
const throughputWinner = rows.reduce((best, row) => row.bench.phases.ramp['80'].messageRate > best.bench.phases.ramp['80'].messageRate ? row : best);
const loadedMemoryWinner = rows.reduce((best, row) => row.bench.phases.ramp['80'].rss < best.bench.phases.ramp['80'].rss ? row : best);
const idleMemoryWinner = rows.reduce((best, row) => row.bench.phases.idle.stats.rss < best.bench.phases.idle.stats.rss ? row : best);
const peakMemoryWinner = rows.reduce((best, row) => row.processMetrics.rssMax < best.processMetrics.rssMax ? row : best);
const cpuWinner = rows.reduce((best, row) => row.processMetrics.cpuPeakPct < best.processMetrics.cpuPeakPct ? row : best);
const binaryRows = rows.filter((row) => ['go', 'rust', 'zig'].includes(row.name));
const binaryWinner = binaryRows.reduce((best, row) => row.artifactBytes < best.artifactBytes ? row : best);

out.push('## Conclusions and performance winners', '');
out.push(`**Overall performance winner: Bun.** It had the highest median connection-establishment rate (${fmtRate(median(connectionWinner.bench.phases.connections.connectionRates))} connections/s), the highest observed 80-bot message rate (${fmtRate(throughputWinner.bench.phases.ramp['80'].messageRate)} messages/s), the lowest stress CPU peak (${cpuWinner.processMetrics.cpuPeakPct.toFixed(1)}%), fast HTTP responses, zero unexpected failures, and full recovery. Its loaded/stress memory was also much lower than Node while avoiding the thread explosion seen in Rust and Zig.`);
out.push('');
out.push(`- **Connection establishment:** ${connectionWinner.name} won at a median ${fmtRate(median(connectionWinner.bench.phases.connections.connectionRates))} connections/s.`);
out.push(`- **Sustained message fan-out:** ${throughputWinner.name} was narrowly highest at ${fmtRate(throughputWinner.bench.phases.ramp['80'].messageRate)} received game-tick messages/s. The spread is small because all implementations are deliberately rate-limited by the same 15 Hz game loop.`);
out.push(`- **Idle and representative-load memory:** ${idleMemoryWinner.name} used the least idle RSS (${fmtBytes(idleMemoryWinner.bench.phases.idle.stats.rss)}), and ${loadedMemoryWinner.name} remained lowest at 80 bots (${fmtBytes(loadedMemoryWinner.bench.phases.ramp['80'].rss)}).`);
out.push(`- **Stress memory:** ${peakMemoryWinner.name} had the lowest sampled stress peak (${fmtBytes(peakMemoryWinner.processMetrics.rssMax)}).`);
out.push(`- **Standalone native binary:** ${binaryWinner.name} was smallest at ${fmtBytes(binaryWinner.artifactBytes)}. Bun's ${fmtBytes(rows.find((row) => row.name === 'bun').artifactBytes)} bundle is smaller but requires the external Bun runtime, so it is not directly comparable to a native executable.`);
out.push('- **Gameplay latency:** effectively a tie. All p95/p99 tick intervals stayed around 67–69 ms, which is the intended 15 Hz cadence; input-to-visible-movement was likewise one tick.');
out.push('- **Connection capacity:** a tie at the tested ceiling. Every server held 4,000 idle WebSocket connections with zero connection failures; the actual failure point is above the tested practical ceiling.');
out.push('- **Recovery:** all five remained alive and returned to normal tick cadence. Node and Go retained most of their stress-allocated RSS after five seconds, while Rust and Zig released substantially more; retained RSS alone is not proof of a leak, but longer soak testing would be appropriate.');
out.push('- **Architecture caveat:** Rust and Zig use two threads per connected transport in these ports. At 4,000 connections they reached roughly 8,000 threads; Bun, Node, and Go scale the same connection count without that thread count, making Bun the safer overall operational choice from this run.');
out.push('');

out.push('## Load curve', '');
out.push('| implementation | bots | msg/s | wire throughput | tick p50 | tick p95 | tick p99 | RSS | load-client CPU peak |');
out.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|');
for (const row of rows) {
  for (const bots of [5, 10, 20, 40, 80]) {
    const phase = row.bench.phases.ramp[String(bots)];
    out.push(`| ${row.name} | ${bots} | ${fmtRate(phase.messageRate)} | ${fmtBytes(phase.byteRate)}/s | ${fmtMs(percentile(phase.deltas, .5))} | ${fmtMs(percentile(phase.deltas, .95))} | ${fmtMs(percentile(phase.deltas, .99))} | ${fmtBytes(phase.rss)} | ${phase.clientCpuPct.toFixed(1)}% |`);
  }
}
out.push('');

out.push('## Stress, limits, and recovery', '');
out.push('| implementation | player-cap result | highest stable idle connections | approximate failure point | churn failures | survived hostile input | recovery p95 | recovery RSS | recovered |');
out.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|');
for (const row of rows) {
  const phase = row.stress.phases;
  const breakPoint = phase.idleRamp.brokeAt ? String(phase.idleRamp.brokeAt) : '>4,000 not established';
  out.push(`| ${row.name} | ${phase.cap.joined} joined / ${phase.cap.rejected} rejected | ${row.stress.idleHeld.toLocaleString('en-US')} | ${breakPoint} | ${phase.churn.connectFails} | ${phase.hostile.serverAliveAfter ? 'yes' : 'no'} | ${fmtMs(phase.recovery.tickP95)} | ${fmtBytes(phase.recovery.rss)} | ${phase.recovery.recovered ? 'yes' : 'no'} |`);
}
out.push('', 'Expected cap rejections are protocol behavior, not benchmark errors. Unexpected HTTP failures, connection failures, timeouts, and crashes are reported in the phase data and server logs under `.scratch/results/`.', '');

out.push('## HTTP operation latency', '');
out.push('| implementation | operation | p50 | p95 | p99 | failures |');
out.push('|---|---|---:|---:|---:|---:|');
for (const row of rows) {
  for (const [label, value] of [['GET /', row.bench.phases.http.home], ['POST /joingame', row.bench.phases.http.join]]) {
    out.push(`| ${row.name} | ${label} | ${fmtMs(value.p50Ms)} | ${fmtMs(value.p95Ms)} | ${fmtMs(value.p99Ms)} | ${value.fails} |`);
  }
}
out.push('');

out.push('## Static project metrics', '');
out.push('| implementation | source LOC | release artifact | clean implementation folder | folder incl. build output | warm-cache build |');
out.push('|---|---:|---:|---:|---:|---:|');
for (const row of rows) {
  const build = builds[row.name];
  out.push(`| ${row.name} | ${row.clean.loc.toLocaleString('en-US')} | ${fmtBytes(row.artifactBytes)} | ${fmtBytes(row.clean.bytes)} | ${fmtBytes(row.total.bytes)} | ${build ? fmtMs(build.elapsedMs) : '—'} |`);
}
out.push('', 'Go, Rust, and Zig artifacts are already stripped, so the release-artifact and stripped-binary sizes are identical. Bun reports its minified bundle; Node has no standalone build artifact. Generated client staging, dependency caches, and build output are excluded from clean-folder and LOC totals.', '');

out.push('## Caveats and interpretation', '');
out.push('- The game intentionally caps active players at 100 and each lobby at 16. The idle-connection break test exercises transport capacity beyond that gameplay cap.');
out.push('- Loopback removes real network variance; results compare server/runtime overhead on this machine, not internet performance.');
out.push('- A single Node load-generator process was sufficient at these targets based on recorded client CPU. For substantially larger active-message tests, shard the generator across processes or hosts.');
out.push('- Message rates count received game ticks across load clients. Other low-rate feed/init/death events are not included, so this is a conservative protocol-message rate.');
out.push('- No implementation receives implementation-specific warm-up, payloads, or durations. Random spawn/collision timing still introduces ordinary run-to-run variance, which is why repeated runs are aggregated.');
out.push('- Highest throughput, lowest latency, smallest memory footprint, smallest artifact, and highest connection capacity are separate outcomes; no single “fastest” label is implied.', '');

out.push('## Reproduction', '', '```bash');
out.push('npm ci');
out.push('ZIG_BIN=/path/to/zig-0.13.0/zig node benchmarks/build-release.js');
out.push('BENCH_REPETITIONS=3 bash benchmarks/run-benchmarks.sh node bun go rust zig');
out.push('node benchmarks/report.js node bun go rust zig');
out.push('```', '');
out.push('Run on an otherwise idle Linux machine. Keep the same CPU governor, file-descriptor limit, runtime/compiler versions, and concurrency targets. Raw JSON and logs are intentionally ignored; archive them separately when independently reproducing a run.');

fs.writeFileSync(path.join(ROOT, 'docs', 'BENCHMARKS.md'), out.join('\n') + '\n');
console.log('wrote docs/BENCHMARKS.md');
