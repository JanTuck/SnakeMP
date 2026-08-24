/* Battle/benchmark harness for any Snek server implementation.
 * Usage: BENCH_BASE=http://127.0.0.1:PORT BENCH_NAME=rust node tools/bench.js
 * Requires the target to run with SNEK_DEBUG=1 (for /debug/stats).
 * Writes .scratch/bench-<name>.json with all collected metrics.
 */
const io = require('/home/jantuck/Documents/Projects/SnakeMP/node_modules/socket.io-client');
const http = require('http');
const fs = require('fs');

const BASE = process.env.BENCH_BASE || 'http://127.0.0.1:4000';
const NAME = process.env.BENCH_NAME || 'server';
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const pct = (arr, p) => { const s = [...arr].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(s.length * p))] ?? 0; };
const avg = (arr) => arr.length ? arr.reduce((a, b) => a + b, 0) / arr.length : 0;
const max = (arr) => arr.length ? Math.max(...arr) : 0;
const metrics = { name: NAME, base: BASE, phases: {} };

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
  try { return JSON.parse(r.body); } catch (e) { return null; }
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
  const obs = { deltas: [], bytes: [], last: 0 };
  obs.socket = io(BASE, { transports: ['websocket'], forceNew: true });
  const join = () => obs.socket.emit('clientReady', 'bench-observer', '12345');
  obs.socket.on('connect', join);
  // Bots wander into the stationary observer and kill it - rejoin so the
  // observer keeps receiving ticks.
  obs.socket.on('death', () => setTimeout(join, 300));
  obs.socket.on('gameTick', (w) => {
    const now = Date.now();
    if (obs.last) obs.deltas.push(now - obs.last);
    obs.last = now;
    obs.bytes.push(JSON.stringify(w).length);
  });
  return obs;
}
async function cadence(obs, ms) {
  const d0 = obs.deltas.length, b0 = obs.bytes.length;
  await wait(ms);
  return { deltas: obs.deltas.slice(d0), bytes: obs.bytes.slice(b0) };
}
function makeBot(i) {
  const state = { alive: false };
  const s = io(BASE, { transports: ['websocket'], forceNew: true });
  state.socket = s;
  const joinOnce = () => { s.emit('clientReady', 'bot-' + i + '-' + (Date.now() % 100000), '12345'); state.alive = true; };
  const walk = setInterval(() => {
    if (!state.alive) return;
    const dirs = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'];
    s.emit('keyPress', dirs[Math.floor(Math.random() * 4)]);
  }, 280);
  s.on('connect', joinOnce);
  s.on('death', () => { state.alive = false; setTimeout(joinOnce, 400); });
  s.on('disconnect', () => { state.alive = false; });
  state.close = () => { clearInterval(walk); s.close(); };
  return state;
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
      if (done + fail >= total) resolve({ ms: Date.now() - t0, lat, fail });
    };
    pump();
  });
}

(async () => {
  metrics.rssStart = (await getStats())?.rss ?? null;
  const obs = makeObserver();
  await new Promise((r, j) => { obs.socket.on('connect', r); obs.socket.on('connect_error', j); obs.socket.on('disconnect', () => {}); });
  await wait(400);

  // A: baseline cadence
  const base = await cadence(obs, 5000);
  metrics.phases.baseline = { deltas: base.deltas, bytes: base.bytes };
  console.log('A baseline: ' + JSON.stringify({ avg: avg(base.deltas).toFixed(1), p95: pct(base.deltas, 0.95), max: max(base.deltas), n: base.deltas.length }));

  // B: load ramp
  metrics.phases.ramp = {};
  for (const N of [5, 10, 20, 40, 80]) {
    const bots = [];
    for (let i = 0; i < N; i++) bots.push(makeBot(i + N * 1000));
    await wait(6000); // join, walk, die, rejoin - reach rough steady state
    const run = await cadence(obs, 6000);
    const st = await getStats();
    metrics.phases.ramp[N] = { deltas: run.deltas, bytes: run.bytes, players: st?.totalPlayers ?? null, rss: st?.rss ?? null, lobbies: st?.lobbies ?? null };
    console.log('B ' + N + ' bots: ' + JSON.stringify({ avg: avg(run.deltas).toFixed(1), p95: pct(run.deltas, 0.95), max: max(run.deltas), payloadAvg: Math.round(avg(run.bytes)), payloadMax: max(run.bytes), players: st?.totalPlayers, rssKb: st ? Math.round(st.rss / 1024) : null }));
    for (const b of bots) b.close();
    await wait(800);
  }

  // C: input latency
  const bot = await connect();
  bot.emit('clientReady', 'latency-bot', '12345');
  bot.on('death', () => setTimeout(() => bot.emit('clientReady', 'latency-bot', '12345'), 300));
  await wait(400);
  const latencies = [];
  for (let i = 0; i < 20; i++) {
    const dir = i % 2 === 0 ? 'ArrowRight' : 'ArrowLeft';
    const before = await new Promise((r) => {
      const h = (w) => { const me = (w.players || []).find(p => p.id === bot.id); if (me) { obs.socket.off('gameTick', h); r(me.snake[0]); } };
      obs.socket.on('gameTick', h);
      setTimeout(() => { obs.socket.off('gameTick', h); r(null); }, 500);
    });
    if (!before) { await wait(200); continue; }
    const t0 = Date.now();
    bot.emit('keyPress', dir);
    const applied = await new Promise((r) => {
      const h = (w) => {
        const me = (w.players || []).find(p => p.id === bot.id);
        if (!me) return;
        const moved = dir === 'ArrowRight' ? me.snake[0].x > before.x : me.snake[0].x < before.x;
        if (moved) { obs.socket.off('gameTick', h); r(Date.now() - t0); }
      };
      obs.socket.on('gameTick', h);
      setTimeout(() => { obs.socket.off('gameTick', h); r(-1); }, 600);
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
  const home = await httpBench('/', 'GET', null, 300, 50);
  const joinB = await httpBench('/joingame', 'POST', 'gameId=12345', 300, 50);
  metrics.phases.http = { home: { avgMs: avg(home.lat), p95Ms: pct(home.lat, 0.95), fails: home.fail }, join: { avgMs: avg(joinB.lat), p95Ms: pct(joinB.lat, 0.95), fails: joinB.fail } };
  console.log('F http: ' + JSON.stringify(metrics.phases.http));

  metrics.rssEnd = (await getStats())?.rss ?? null;
  const alive = await get('/');
  metrics.alive = alive.status === 200;
  console.log('SERVER alive: ' + metrics.alive + ' | rss ' + metrics.rssStart + ' -> ' + metrics.rssEnd);

  obs.socket.close();
  const dir = '/home/jantuck/Documents/Projects/SnakeMP/.scratch';
  fs.writeFileSync(dir + '/bench-' + NAME + '.json', JSON.stringify(metrics, null, 1));
  console.log('metrics written to .scratch/bench-' + NAME + '.json');
  process.exit(0);
})().catch(e => { console.error('BENCH CRASH:', e && e.message ? e.message : e); process.exit(2); });