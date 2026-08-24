/* Battle/benchmark harness for any Snek server implementation.
 * Usage: BENCH_BASE=http://127.0.0.1:PORT BENCH_NAME=rust node benchmarks/bench.js
 * Requires the target to run with SNEK_DEBUG=1 (for /debug/stats).
 * Writes .scratch/bench-<name>.json with all collected metrics.
 */
const path = require('path');
const io = require('./socket');
const http = require('http');
const fs = require('fs');
const { attachWorld } = require('./protocol');

const BASE = process.env.BENCH_BASE || 'http://127.0.0.1:4000';
const NAME = process.env.BENCH_NAME || 'server';
function positiveNumberEnv(name, fallback) {
  if (process.env[name] === undefined) return fallback;
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a finite positive number; received ${JSON.stringify(process.env[name])}`);
  }
  return value;
}
function positiveIntegerEnv(name, fallback) {
  const value = positiveNumberEnv(name, fallback);
  if (!Number.isSafeInteger(value)) {
    throw new Error(`${name} must be an integer; received ${JSON.stringify(process.env[name])}`);
  }
  return value;
}
const REPETITIONS = positiveIntegerEnv('BENCH_REPETITIONS', 3);
const WARMUP_MS = positiveNumberEnv('BENCH_WARMUP_MS', 5000);
const SAMPLE_MS = positiveNumberEnv('BENCH_SAMPLE_MS', 6000);
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const pct = (arr, p) => { const s = [...arr].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(s.length * p))] ?? 0; };
const avg = (arr) => arr.length ? arr.reduce((a, b) => a + b, 0) / arr.length : 0;
const max = (arr) => arr.length ? Math.max(...arr) : 0;
const metrics = {
  schemaVersion: 2,
  name: NAME,
  base: BASE,
  repetitions: REPETITIONS,
  warmupMs: WARMUP_MS,
  sampleMs: SAMPLE_MS,
  methodology: {
    topology: 'server and one Node.js load generator share the loopback host',
    rampWorkload: 'bots send random cardinal input every 280 ms; deaths can temporarily reduce the sampled active-player count during the 400 ms rejoin delay',
    messageRate: 'decoded world snapshots received by bots, not unconstrained request throughput; the simulation is fixed at 15 Hz',
    clientCpuPct: 'CPU consumed by this Node.js benchmark process; it is not server CPU',
    rss: 'server process RSS reported by /debug/stats; excludes kernel socket buffers and the load generator',
    inputLatency: 'loopback elapsed time from a binary direction send until an observer decodes a snapshot with movement on that cardinal axis',
  },
  phases: {},
};

try { delete globalThis.WebSocket; } catch (e) {}

function get(path) {
  return new Promise((resolve) => {
    http.get(BASE + path, (res) => {
      let body = '';
      res.on('data', (c) => body += c);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    }).on('error', (e) => resolve({ error: String(e) }));
  });
}
async function getStats() {
  const r = await get('/debug/stats');
  if (r.error) throw new Error('/debug/stats request failed: ' + r.error);
  if (r.status !== 200) throw new Error('/debug/stats returned HTTP ' + r.status);
  try {
    const stats = JSON.parse(r.body);
    if (!stats || typeof stats !== 'object' || Array.isArray(stats)) throw new Error('expected an object');
    return stats;
  } catch (e) {
    throw new Error('/debug/stats returned invalid JSON: ' + e.message);
  }
}
function connect() {
  return new Promise((resolve, reject) => {
    const s = io(BASE, { transports: ['websocket'], forceNew: true });
    const t = setTimeout(() => { s.close(); reject(new Error('connect timeout')); }, 8000);
    s.on('connect', () => { clearTimeout(t); resolve(s); });
    s.on('connect_error', (e) => { clearTimeout(t); s.close(); reject(new Error('connect_error')); });
  });
}
function makeObserver() {
  const obs = { deltas: [], bytes: [], last: 0, decodeUs: [], worldHandlers: new Set() };
  obs.socket = io(BASE, { transports: ['websocket'], forceNew: true });
  const join = () => obs.socket.emit('clientReady', 'bench-observer', '12345');
  obs.socket.on('connect', join);
  // Bots wander into the stationary observer and kill it - rejoin so the
  // observer keeps receiving ticks.
  obs.socket.on('death', () => setTimeout(join, 300));
  attachWorld(obs.socket, (w, wireBytes) => {
    const now = Date.now();
    if (obs.last) obs.deltas.push(now - obs.last);
    obs.last = now;
    obs.bytes.push(wireBytes);
    for (const handler of obs.worldHandlers) handler(w);
  }, obs.decodeUs);
  obs.onWorld = (handler) => obs.worldHandlers.add(handler);
  obs.offWorld = (handler) => obs.worldHandlers.delete(handler);
  return obs;
}
async function cadence(obs, ms) {
  const d0 = obs.deltas.length, b0 = obs.bytes.length;
  await wait(ms);
  return { deltas: obs.deltas.slice(d0), bytes: obs.bytes.slice(b0) };
}
function makeBot(i, lobbyId) {
  const state = { alive: false, packets: 0, bytes: 0 };
  const s = io(BASE, { transports: ['websocket'], forceNew: true });
  state.socket = s;
  const joinOnce = () => { s.emit('clientReady', 'bot-' + i + '-' + (Date.now() % 100000), lobbyId || '12345'); state.alive = true; };
  const walk = setInterval(() => {
    if (!state.alive) return;
    const dirs = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'];
    s.emit('keyPress', dirs[Math.floor(Math.random() * 4)]);
  }, 280);
  s.on('connect', joinOnce);
  s.on('death', () => { state.alive = false; setTimeout(joinOnce, 400); });
  s.on('disconnect', () => { state.alive = false; });
  attachWorld(s, (world, wireBytes) => {
    state.packets++;
    state.bytes += wireBytes;
  });
  state.close = () => { clearInterval(walk); s.close(); };
  return state;
}

async function connectionBench(total, concurrency) {
  const latencies = [];
  const sockets = [];
  let next = 0;
  const started = Date.now();
  async function worker() {
    while (next < total) {
      next++;
      const t0 = performance.now();
      try {
        const socket = await connect();
        latencies.push(performance.now() - t0);
        sockets.push(socket);
      } catch {
        latencies.push(-1);
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, total) }, worker));
  const elapsedMs = Date.now() - started;
  for (const socket of sockets) socket.close();
  return {
    attempts: total,
    connected: sockets.length,
    failed: total - sockets.length,
    elapsedMs,
    connectionsPerSec: sockets.length / (elapsedMs / 1000),
    latenciesMs: latencies.filter((value) => value >= 0),
  };
}

function clientCpu(startUsage, elapsedMs) {
  const used = process.cpuUsage(startUsage);
  return (used.user + used.system) / (elapsedMs * 1000) * 100;
}
function httpBench(path, method, body, total, conc) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    let done = 0, fail = 0;
    const lat = [];
    let inflight = 0, i = 0;
    const one = (cb) => {
      const s0 = Date.now();
      const req = http.request(BASE + path, { method, headers: body ? { 'content-type': 'application/x-www-form-urlencoded' } : {} }, (res) => {
        res.resume(); res.on('end', () => { lat.push(Date.now() - s0); done++; cb(); });
      });
      req.on('error', () => { fail++; cb(); });
      req.end(body);
    };
    const pump = () => {
      while (inflight < conc && i < total) { inflight++; i++; one(() => { inflight--; pump(); }); }
      if (done + fail >= total) resolve({ attempts: total, ms: Date.now() - t0, lat, fail });
    };
    pump();
  });
}

function validateMeasurements() {
  const errors = [];
  const assert = (condition, message) => { if (!condition) errors.push(message); };
  const finite = (value) => typeof value === 'number' && Number.isFinite(value);
  const finiteNonNegative = (value) => finite(value) && value >= 0;
  const finitePositive = (value) => finite(value) && value > 0;
  const validSamples = (values, positive = false) => Array.isArray(values)
    && values.length > 0
    && values.every(positive ? finitePositive : finiteNonNegative);
  const validStats = (stats) => stats
    && finitePositive(stats.rss)
    && finiteNonNegative(stats.totalPlayers)
    && finiteNonNegative(stats.connections)
    && Array.isArray(stats.lobbies);

  assert(validStats(metrics.phases.idle?.stats), 'idle debug stats are missing or malformed');

  const baselineRuns = metrics.phases.baseline?.runs;
  assert(Array.isArray(baselineRuns) && baselineRuns.length === REPETITIONS,
    'baseline did not record every repetition');
  for (const [index, run] of (baselineRuns || []).entries()) {
    assert(validSamples(run.deltas, true), `baseline repetition ${index + 1} has no valid cadence samples`);
    assert(validSamples(run.bytes, true), `baseline repetition ${index + 1} has no valid wire-byte samples`);
  }

  const connectionRuns = metrics.phases.connections?.runs;
  assert(Array.isArray(connectionRuns) && connectionRuns.length === REPETITIONS,
    'connection phase did not record every repetition');
  for (const [index, run] of (connectionRuns || []).entries()) {
    assert(Number.isSafeInteger(run.attempts) && run.attempts > 0,
      `connection repetition ${index + 1} has an invalid attempt count`);
    assert(Number.isSafeInteger(run.connected) && Number.isSafeInteger(run.failed)
      && run.connected >= 0 && run.failed >= 0 && run.connected + run.failed === run.attempts,
    `connection repetition ${index + 1} did not account for every attempt`);
    assert(run.connected > 0 && validSamples(run.latenciesMs),
      `connection repetition ${index + 1} has no successful latency samples`);
    assert(finitePositive(run.elapsedMs) && finiteNonNegative(run.connectionsPerSec),
      `connection repetition ${index + 1} has invalid timing measurements`);
  }

  for (const count of [5, 10, 20, 40, 80]) {
    const runs = metrics.phases.ramp?.[count]?.runs;
    assert(Array.isArray(runs) && runs.length === REPETITIONS,
      `ramp ${count} did not record every repetition`);
    for (const [index, run] of (runs || []).entries()) {
      const label = `ramp ${count} repetition ${index + 1}`;
      assert(validSamples(run.deltas, true), `${label} has no valid cadence samples`);
      assert(validSamples(run.bytes, true), `${label} has no valid observer wire-byte samples`);
      assert(finitePositive(run.elapsedMs), `${label} has invalid elapsed time`);
      assert(finitePositive(run.packets) && finitePositive(run.messageRate), `${label} has no bot message samples`);
      assert(finitePositive(run.byteRate), `${label} has no bot wire-byte samples`);
      assert(finiteNonNegative(run.clientCpuPct), `${label} has an invalid client CPU measurement`);
      assert(finiteNonNegative(run.players) && finitePositive(run.rss) && Array.isArray(run.lobbies),
        `${label} has missing or malformed debug stats`);
    }
  }

  assert(validSamples(metrics.phases.inputLatencyMs), 'input-latency phase has no successful samples');
  assert(Number.isSafeInteger(metrics.phases.churn?.fails) && metrics.phases.churn.fails >= 0
    && finitePositive(metrics.phases.churn?.rssBefore) && finitePositive(metrics.phases.churn?.rssAfter),
  'churn phase has missing or malformed measurements');
  assert(Number.isSafeInteger(metrics.phases.hostile?.stormFails) && metrics.phases.hostile.stormFails >= 0
    && finiteNonNegative(metrics.phases.hostile?.floodMs)
    && validSamples(metrics.phases.hostile?.deltas, true),
  'hostile phase has missing or malformed measurements');

  for (const kind of ['home', 'join']) {
    const runs = metrics.phases.http?.runs?.[kind];
    assert(Array.isArray(runs) && runs.length === REPETITIONS,
      `HTTP ${kind} phase did not record every repetition`);
    for (const [index, run] of (runs || []).entries()) {
      assert(Number.isSafeInteger(run.attempts) && run.attempts > 0
        && Number.isSafeInteger(run.fail) && run.fail >= 0 && Array.isArray(run.lat)
        && run.lat.length + run.fail === run.attempts,
      `HTTP ${kind} repetition ${index + 1} did not account for every request`);
      assert(validSamples(run.lat), `HTTP ${kind} repetition ${index + 1} has no successful latency samples`);
      assert(finiteNonNegative(run.ms), `HTTP ${kind} repetition ${index + 1} has invalid elapsed time`);
    }
  }

  const decode = metrics.phases.protocolNormalizeUs;
  assert(Number.isSafeInteger(decode?.samples) && decode.samples > 0
    && finiteNonNegative(decode.avg) && finiteNonNegative(decode.p50)
    && finiteNonNegative(decode.p95) && finiteNonNegative(decode.p99),
  'protocol decode phase has no valid samples');
  assert(finitePositive(metrics.rssStart) && finitePositive(metrics.rssEnd),
    'start or end RSS measurement is missing');
  assert(metrics.alive === true, 'server failed the final liveness check');
  return errors;
}

async function ensureLobbies(nLobbies) {
  const ids = ['12345'];
  while (ids.length < nLobbies) {
    const loc = await new Promise((resolve) => {
      const req = http.request(BASE + '/generateid', { method: 'POST' }, (res) => {
        res.resume(); res.on('end', () => resolve(String(res.headers.location || '')));
      });
      req.on('error', () => resolve(''));
      req.end();
    });
    if (!loc) break;
    ids.push(decodeURIComponent(loc.split('/').pop()));
  }
  return ids;
}

(async () => {
  metrics.rssStart = (await getStats())?.rss ?? null;
  metrics.phases.idle = { stats: await getStats() };
  const obs = makeObserver();
  await new Promise((r, j) => { obs.socket.on('connect', r); obs.socket.on('connect_error', j); obs.socket.on('disconnect', () => {}); });
  await wait(WARMUP_MS); // identical runtime/JIT warm-up for every implementation

  // A: baseline cadence
  const baselineRuns = [];
  for (let rep = 0; rep < REPETITIONS; rep++) {
    baselineRuns.push(await cadence(obs, SAMPLE_MS));
  }
  const base = {
    deltas: baselineRuns.flatMap((run) => run.deltas),
    bytes: baselineRuns.flatMap((run) => run.bytes),
    runs: baselineRuns,
  };
  metrics.phases.baseline = base;
  console.log('A baseline: ' + JSON.stringify({ avg: avg(base.deltas).toFixed(1), p95: pct(base.deltas, 0.95), max: max(base.deltas), n: base.deltas.length }));

  // A2: connection establishment is intentionally separate from steady-state load.
  const connectionRuns = [];
  for (let rep = 0; rep < REPETITIONS; rep++) {
    connectionRuns.push(await connectionBench(100, 25));
    await wait(500);
  }
  metrics.phases.connections = {
    runs: connectionRuns,
    latenciesMs: connectionRuns.flatMap((run) => run.latenciesMs),
    connectionRates: connectionRuns.map((run) => run.connectionsPerSec),
    failed: connectionRuns.reduce((sum, run) => sum + run.failed, 0),
  };

  // B: load ramp
  metrics.phases.ramp = {};
  for (const N of [5, 10, 20, 40, 80]) {
    const runs = [];
    for (let rep = 0; rep < REPETITIONS; rep++) {
      const lobbies = await ensureLobbies(Math.ceil((N + 1) / 16));
      const bots = [];
      for (let i = 0; i < N; i++) bots.push(makeBot(i + N * 1000 + rep * 100000, lobbies[i % lobbies.length]));
      await wait(WARMUP_MS);
      const packetStart = bots.reduce((sum, bot) => sum + bot.packets, 0);
      const byteStart = bots.reduce((sum, bot) => sum + bot.bytes, 0);
      const cpuStart = process.cpuUsage();
      const wallStart = Date.now();
      const sample = await cadence(obs, SAMPLE_MS);
      const elapsedMs = Date.now() - wallStart;
      const packets = bots.reduce((sum, bot) => sum + bot.packets, 0) - packetStart;
      const bytes = bots.reduce((sum, bot) => sum + bot.bytes, 0) - byteStart;
      const st = await getStats();
      runs.push({
        ...sample,
        elapsedMs,
        packets,
        messageRate: packets / (elapsedMs / 1000),
        byteRate: bytes / (elapsedMs / 1000),
        clientCpuPct: clientCpu(cpuStart, elapsedMs),
        players: st?.totalPlayers ?? null,
        rss: st?.rss ?? null,
        lobbies: st?.lobbies ?? null,
      });
      for (const bot of bots) bot.close();
      await wait(800);
    }
    metrics.phases.ramp[N] = {
      requestedBots: N,
      runs,
      deltas: runs.flatMap((run) => run.deltas),
      bytes: runs.flatMap((run) => run.bytes),
      players: Math.round(avg(runs.map((run) => run.players || 0))),
      rss: Math.round(avg(runs.map((run) => run.rss || 0))),
      messageRate: avg(runs.map((run) => run.messageRate)),
      byteRate: avg(runs.map((run) => run.byteRate)),
      clientCpuPct: max(runs.map((run) => run.clientCpuPct)),
      lobbies: runs.at(-1)?.lobbies ?? null,
    };
    const run = metrics.phases.ramp[N];
    console.log('B ' + N + ' bots: ' + JSON.stringify({ avg: avg(run.deltas).toFixed(1), p95: pct(run.deltas, 0.95), messagesPerSec: Math.round(run.messageRate), clientCpuPct: run.clientCpuPct.toFixed(1), players: run.players, rssKb: Math.round(run.rss / 1024) }));
  }

  // C: input latency
  const bot = await connect();
  bot.emit('clientReady', 'latency-bot', '12345');
  bot.on('death', () => setTimeout(() => bot.emit('clientReady', 'latency-bot', '12345'), 300));
  await wait(400);
  const latencies = [];
  const latencyDirections = ['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp'];
  for (let i = 0; i < 60 && latencies.length < 30; i++) {
    const dir = latencyDirections[i % latencyDirections.length];
    const before = await new Promise((r) => {
      const h = (w) => { const me = (w.players || []).find(p => p.id === bot.id); if (me) { obs.offWorld(h); r(me.snake[0]); } };
      obs.onWorld(h);
      setTimeout(() => { obs.offWorld(h); r(null); }, 500);
    });
    if (!before) { await wait(200); continue; }
    const t0 = performance.now();
    bot.emit('keyPress', dir);
    const applied = await new Promise((r) => {
      const h = (w) => {
        const me = (w.players || []).find(p => p.id === bot.id);
        if (!me) return;
        const head = me.snake[0];
        const moved = dir === 'ArrowRight' ? head.x > before.x
          : dir === 'ArrowLeft' ? head.x < before.x
            : dir === 'ArrowDown' ? head.y > before.y
              : head.y < before.y;
        if (moved) { obs.offWorld(h); r(performance.now() - t0); }
      };
      obs.onWorld(h);
      setTimeout(() => { obs.offWorld(h); r(-1); }, 600);
    });
    if (applied >= 0) latencies.push(applied);
    await wait(150);
  }
  metrics.phases.inputLatencyMs = latencies;
  console.log('C input latency: ' + JSON.stringify({ n: latencies.length, avg: avg(latencies).toFixed(1), max: max(latencies) }));
  bot.close();

  // D: churn
  const rssBeforeChurn = (await getStats())?.rss ?? null;
  let churnFails = 0;
  for (let i = 0; i < 30; i++) {
    try { const s = await connect(); s.emit('clientReady', 'churn-' + i, '12345'); await wait(50); s.close(); } catch (e) { churnFails++; }
  }
  await wait(2000);
  metrics.phases.churn = { fails: churnFails, rssAfter: (await getStats())?.rss ?? null, rssBefore: rssBeforeChurn };
  console.log('D churn: ' + JSON.stringify({ fails: churnFails }));

  // E: hostile
  const h = await connect();
  h.emit('clientReady', 'hostile-bot', '12345');
  await wait(200);
  const floodStart = Date.now();
  for (let i = 0; i < 3000; i++) h.emit('keyPress', i % 2 ? 'ArrowUp' : 'ArrowDown');
  h.emit('clientReady', 'x'.repeat(1000000));
  h.emit('clientReady', null);
  h.emit('keyPress', { dir: 'ArrowUp' });
  h.emit('keyPress', 12345);
  let stormFails = 0;
  for (let i = 0; i < 40; i++) { try { const s = await connect(); s.close(); } catch (e) { stormFails++; } }
  const still = await cadence(obs, 2000);
  metrics.phases.hostile = { floodMs: Date.now() - floodStart, stormFails, deltas: still.deltas };
  console.log('E hostile: ' + JSON.stringify({ floodMs: Date.now() - floodStart, stormFails, tickP95: pct(still.deltas, 0.95) }));
  h.close();

  // F: HTTP
  const httpRuns = { home: [], join: [] };
  for (let rep = 0; rep < REPETITIONS; rep++) {
    httpRuns.home.push(await httpBench('/', 'GET', null, 300, 50));
    httpRuns.join.push(await httpBench('/joingame', 'POST', 'gameId=12345', 300, 50));
  }
  const homeLat = httpRuns.home.flatMap((run) => run.lat);
  const joinLat = httpRuns.join.flatMap((run) => run.lat);
  metrics.phases.http = {
    runs: httpRuns,
    home: { avgMs: avg(homeLat), p50Ms: pct(homeLat, 0.50), p95Ms: pct(homeLat, 0.95), p99Ms: pct(homeLat, 0.99), fails: httpRuns.home.reduce((n, run) => n + run.fail, 0) },
    join: { avgMs: avg(joinLat), p50Ms: pct(joinLat, 0.50), p95Ms: pct(joinLat, 0.95), p99Ms: pct(joinLat, 0.99), fails: httpRuns.join.reduce((n, run) => n + run.fail, 0) },
  };
  console.log('F http: ' + JSON.stringify({ home: metrics.phases.http.home, join: metrics.phases.http.join }));

  metrics.phases.protocolNormalizeUs = {
    samples: obs.decodeUs.length,
    avg: avg(obs.decodeUs),
    p50: pct(obs.decodeUs, 0.50),
    p95: pct(obs.decodeUs, 0.95),
    p99: pct(obs.decodeUs, 0.99),
  };

  metrics.rssEnd = (await getStats())?.rss ?? null;
  const alive = await get('/');
  metrics.alive = alive.status === 200;
  console.log('SERVER alive: ' + metrics.alive + ' | rss ' + metrics.rssStart + ' -> ' + metrics.rssEnd);

  const validityErrors = validateMeasurements();
  metrics.validity = { passed: validityErrors.length === 0, errors: validityErrors };

  obs.socket.close();
  const dir = path.resolve(__dirname, '..', '.scratch');
  fs.writeFileSync(dir + '/bench-' + NAME + '.json', JSON.stringify(metrics, null, 1));
  console.log('metrics written to .scratch/bench-' + NAME + '.json');
  if (validityErrors.length > 0) {
    console.error('BENCH INVALID:\n- ' + validityErrors.join('\n- '));
    process.exit(1);
  }
  console.log('BENCH VALID');
  process.exit(0);
})().catch(e => { console.error('BENCH CRASH:', e && e.message ? e.message : e); process.exit(2); });
