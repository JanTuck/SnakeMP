/* Stress / throttle / break-it harness for any Snek server implementation.
 * Usage: STRESS_BASE=http://127.0.0.1:PORT STRESS_NAME=name node benchmarks/stress.js
 * Writes .scratch/stress-<name>.json. Assumes the server is already running
 * (SNEK_DEBUG=1 recommended so /debug/stats can be correlated).
 */
const path = require('path');
const io = require('./socket');
const http = require('http');
const fs = require('fs');
const { attachWorld } = require('./protocol');

try { delete globalThis.WebSocket; } catch (e) {}

const BASE = process.env.STRESS_BASE || 'http://127.0.0.1:4000';
const NAME = process.env.STRESS_NAME || 'server';
const CRLF = String.fromCharCode(13, 10);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (arr, p) => { const s = [...arr].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(s.length * p))] ?? 0; };
function alphaId(value) {
  let remaining = value;
  let encoded = '';
  do {
    encoded = String.fromCharCode(97 + (remaining % 26)) + encoded;
    remaining = Math.floor(remaining / 26);
  } while (remaining > 0);
  return encoded;
}
const validityChecks = [];
function checkValidity(name, passed, detail) {
  validityChecks.push({ name, passed: Boolean(passed), detail });
}
const metrics = {
  schemaVersion: 3,
  name: NAME,
  base: BASE,
  methodology: {
    topology: 'server and Node.js stress client share the loopback host',
    idleRamp: 'connected native WebSockets that do not join a lobby; RSS is server process RSS only',
    rawHostile: 'counts TCP connections opened for malformed payload attempts, not payload acceptance by the protocol parser',
    lowInputRate: 'joined clients send one direction per second; this is not a slow-reader/socket-backpressure test',
  },
  phases: {},
};

function get(path) {
  return new Promise((resolve) => {
    http.get(BASE + path, (res) => {
      let body = '';
      res.on('data', (c) => body += c);
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', (e) => resolve({ error: String(e) }));
  });
}
function post(path) {
  return new Promise((resolve) => {
    const req = http.request(BASE + path, { method: 'POST' }, (res) => {
      res.resume(); res.on('end', () => resolve({ status: res.statusCode, location: res.headers.location }));
    });
    req.on('error', (e) => resolve({ error: String(e) }));
    req.end();
  });
}
function connectOnce(timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const s = io(BASE, { transports: ['websocket'], forceNew: true, reconnection: false, timeout: timeoutMs || 10000 });
    const done = (ok) => { if (!settled) { settled = true; resolve(ok ? s : null); } };
    s.on('connect', () => done(true));
    s.on('connect_error', () => { s.close(); done(false); });
    setTimeout(() => { try { s.close(); } catch (e) {} done(false); }, timeoutMs || 10000);
  });
}
function joinOnce(socket, username, lobby, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (outcome) => {
      if (settled) return;
      settled = true;
      resolve(outcome);
    };
    socket.on('init', () => done('init'));
    socket.on('game_error', () => done('game_error'));
    setTimeout(() => done('timeout'), timeoutMs || 3000);
    socket.emit('clientReady', username, lobby);
  });
}
function rawSocket(port, payload) {
  return new Promise((resolve) => {
    const net = require('net');
    const sock = net.connect(port, '127.0.0.1', () => {
      if (payload) sock.write(payload);
      setTimeout(() => { sock.destroy(); resolve(true); }, 300);
    });
    sock.on('error', () => resolve(false));
  });
}

(async () => {
  const port = parseInt(new URL(BASE).port, 10) || 80;

  // Health observer: a joined player whose tick stream tells us the server
  // stayed alive and healthy throughout the storm.
  const obs = io(BASE, { transports: ['websocket'], forceNew: true, reconnection: true });
  const obsDeltas = [];
  let obsLast = 0;
  let obsConnections = 0;
  obs.on('connect', () => { obsConnections++; });
  obs.on('connect', () => obs.emit('clientReady', 'stress-observer', '12345'));
  obs.on('death', () => setTimeout(() => obs.emit('clientReady', 'stress-observer', '12345'), 300));
  attachWorld(obs, () => { const n = Date.now(); if (obsLast) obsDeltas.push(n - obsLast); obsLast = n; });
  await wait(700);

  // S0: cap enforcement — concentrate 120 join attempts in one fresh lobby so
  // the configured per-lobby/global cap is actually crossed.
  {
    const generated = await post('/generateid');
    const lobby = generated.location ? decodeURIComponent(String(generated.location).split('/').pop()) : null;
    let joined = 0, rejected = 0, timedOut = 0, connectFailed = 0;
    const socks = [];
    for (let i = 0; i < 120; i++) {
      const s = await connectOnce();
      if (!s) { connectFailed++; continue; }
      socks.push(s);
      const outcome = lobby ? await joinOnce(s, 'capbot' + alphaId(i), lobby, 3000) : 'timeout';
      if (outcome === 'init') joined++;
      else if (outcome === 'game_error') rejected++;
      else timedOut++;
    }
    metrics.phases.cap = { attempts: 120, lobbyCreated: Boolean(lobby), joined, rejected, timedOut, connectFailed };
    console.log('S0 caps: ' + JSON.stringify(metrics.phases.cap));
    checkValidity('cap lobby created', Boolean(lobby), metrics.phases.cap);
    checkValidity('cap accepted at least one join', joined > 0, metrics.phases.cap);
    checkValidity('cap produced an explicit rejection', rejected > 0, metrics.phases.cap);
    checkValidity('cap classified every attempt', joined + rejected + timedOut + connectFailed === 120, metrics.phases.cap);
    checkValidity('cap had no ambiguous join timeout', timedOut === 0, metrics.phases.cap);
    for (const s of socks) try { s.close(); } catch (e) {}
    await wait(500);
  }

  // S1: idle connection ramp (sockets that connect but never join).
  {
    const ramp = {};
    const held = [];
    for (const N of [100, 250, 500, 1000, 2000, 4000]) {
      const t0 = Date.now();
      let ok = 0;
      const batch = [];
      const needed = N - held.length;
      for (let i = 0; i < needed; i += 50) {
        const chunk = await Promise.all(Array.from({ length: Math.min(50, needed - i) }, () => connectOnce()));
        for (const s of chunk) { if (s) { ok++; batch.push(s); } }
      }
      held.push(...batch);
      await wait(1500);
      const stats = await get('/debug/stats');
      const stillAlive = (await get('/')).status === 200;
      let rss = null;
      try { rss = JSON.parse(stats.body).rss; } catch (e) {}
      ramp[N] = { target: N, held: held.length, connected: ok, failed: needed - ok, openMs: Date.now() - t0, serverAlive: stillAlive, rss };
      console.log('S1 idle@' + N + ': ' + JSON.stringify(ramp[N]));
      if (held.length < N * 0.8) { ramp.brokeAt = N; console.log('S1 breaking at ' + N); break; }
    }
    metrics.phases.idleRamp = ramp;
    metrics.idleHeld = held.length;
    const samples = Object.values(ramp).filter((entry) => entry && typeof entry === 'object');
    checkValidity('idle ramp collected samples', samples.length > 0, { samples: samples.length });
    checkValidity('server stayed alive during idle ramp', samples.length > 0 && samples.every((entry) => entry.serverAlive), ramp);
    for (const s of held) try { s.close(); } catch (e) {}
    await wait(800);
  }

  // S2: lobby creation flood.
  {
    const t0 = Date.now();
    let ok = 0;
    for (let i = 0; i < 200; i += 20) {
      const res = await Promise.all(Array.from({ length: 20 }, () => post('/generateid')));
      ok += res.filter((r) => r.status === 303).length;
    }
    metrics.phases.lobbyFlood = { created: ok, ms: Date.now() - t0 };
    console.log('S2 lobby flood: ' + JSON.stringify(metrics.phases.lobbyFlood));
    checkValidity('lobby flood completed all requests', ok === 200, metrics.phases.lobbyFlood);
  }

  // S3: hostile garbage — oversized frames + malformed raw TCP.
  {
    const s = await connectOnce();
    let oversizedFrameAttempted = false;
    if (s) {
      s.emit('clientReady', 'garbage-bot', '12345');
      await wait(300);
      // Bypass the bounded adapter to exercise the server's frame-size guard.
      try {
        s.send(Buffer.alloc(2 * 1024 * 1024 + 1, 0xff));
        oversizedFrameAttempted = true;
      } catch (e) {}
      await wait(1000);
      try { s.close(); } catch (e) {}
    }
    const payloads = [
      'GARBAGE' + CRLF + CRLF,
      'GET /ws HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF,
      Buffer.from([0x81, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]),
    ];
    let rawConnectionsOpened = 0;
    for (let i = 0; i < 100; i++) {
      if (await rawSocket(port, payloads[i % payloads.length])) rawConnectionsOpened++;
    }
    await wait(500);
    const alive = (await get('/')).status === 200;
    const tickP95 = obsDeltas.length > 10 ? pct(obsDeltas.slice(-100), 0.95) : null;
    metrics.phases.hostile = { oversizedFrameAttempted, rawAttempts: 100, rawConnectionsOpened, serverAliveAfter: alive, tickP95After: tickP95 };
    console.log('S3 hostile: ' + JSON.stringify(metrics.phases.hostile));
    checkValidity('oversized frame was attempted', oversizedFrameAttempted, metrics.phases.hostile);
    checkValidity('hostile raw connections reached server', rawConnectionsOpened > 0, metrics.phases.hostile);
    checkValidity('server survived hostile phase', alive, metrics.phases.hostile);
  }

  // S4: churn storm — rapid connect/disconnect.
  {
    let fails = 0;
    const t0 = Date.now();
    for (let i = 0; i < 200; i += 25) {
      const res = await Promise.all(Array.from({ length: 25 }, () => connectOnce(6000)));
      for (const s of res) { if (s) try { s.close(); } catch (e) {} else fails++; }
    }
    await wait(1500);
    const alive = (await get('/')).status === 200;
    metrics.phases.churn = { cycles: 200, connected: 200 - fails, connectFails: fails, ms: Date.now() - t0, serverAliveAfter: alive };
    console.log('S4 churn: ' + JSON.stringify(metrics.phases.churn));
    checkValidity('churn established connections', fails < 200, metrics.phases.churn);
    checkValidity('server survived churn phase', alive, metrics.phases.churn);
  }

  // S5: low-input-rate clients — one input/sec per bot, tick cadence must hold.
  {
    const bots = [];
    let joinFailures = 0;
    for (let i = 0; i < 12; i++) {
      const s = await connectOnce();
      if (!s) { joinFailures++; continue; }
      const outcome = await joinOnce(s, 'slowbot' + alphaId(i), '12345', 3000);
      if (outcome === 'init') bots.push(s);
      else { joinFailures++; try { s.close(); } catch (e) {} }
    }
    const d0 = obsDeltas.length;
    const directions = ['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp'];
    let directionIndex = 0;
    let inputRounds = 0;
    const lowRateInput = setInterval(() => {
      inputRounds++;
      const direction = directions[directionIndex++ % directions.length];
      for (const s of bots) s.emit('keyPress', direction);
    }, 1000);
    await wait(8000);
    clearInterval(lowRateInput);
    const deltas = obsDeltas.slice(d0);
    metrics.phases.lowInputRate = { requestedBots: 12, bots: bots.length, joinFailures, inputRounds, inputsPerBotPerSec: 1, observedTicks: deltas.length, tickAvg: deltas.length ? Math.round(deltas.reduce((a, b) => a + b, 0) / deltas.length * 10) / 10 : null, tickP95: deltas.length ? pct(deltas, 0.95) : null, tickMax: deltas.length ? Math.max(...deltas) : null };
    console.log('S5 low input rate: ' + JSON.stringify(metrics.phases.lowInputRate));
    checkValidity('low-input clients joined', bots.length > 0, metrics.phases.lowInputRate);
    checkValidity('low-input phase sent inputs', inputRounds > 0, metrics.phases.lowInputRate);
    checkValidity('low-input phase observed ticks', deltas.length > 0, metrics.phases.lowInputRate);
    for (const s of bots) try { s.close(); } catch (e) {}
  }

  metrics.observerAlive = obsDeltas.length > 20;
  const recoveryStart = Date.now();
  const recoveryD0 = obsDeltas.length;
  await wait(5000);
  const recoveryDeltas = obsDeltas.slice(recoveryD0);
  const recoveryStats = await get('/debug/stats');
  let recoveryJson = null;
  try { recoveryJson = JSON.parse(recoveryStats.body); } catch (e) {}
  metrics.phases.recovery = {
    elapsedMs: Date.now() - recoveryStart,
    tickP50: recoveryDeltas.length ? pct(recoveryDeltas, 0.50) : null,
    tickP95: recoveryDeltas.length ? pct(recoveryDeltas, 0.95) : null,
    tickP99: recoveryDeltas.length ? pct(recoveryDeltas, 0.99) : null,
    rss: recoveryJson?.rss ?? null,
    totalPlayers: recoveryJson?.totalPlayers ?? null,
    recovered: recoveryDeltas.length > 20 && pct(recoveryDeltas, 0.95) < 150,
  };
  metrics.aliveAtEnd = (await get('/')).status === 200;
  const stats = await get('/debug/stats');
  try { metrics.finalStats = JSON.parse(stats.body); } catch (e) { metrics.finalStats = null; }
  checkValidity('observer connected', obsConnections > 0, { connections: obsConnections });
  checkValidity('observer received a sustained tick stream', metrics.observerAlive, { ticks: obsDeltas.length });
  checkValidity('server recovered its established cadence', metrics.phases.recovery.recovered, metrics.phases.recovery);
  checkValidity('server was alive at end', metrics.aliveAtEnd, { aliveAtEnd: metrics.aliveAtEnd });
  const failures = validityChecks.filter((entry) => !entry.passed);
  metrics.validity = { passed: failures.length === 0, checks: validityChecks, failures };
  console.log('STRESS done: alive=' + metrics.aliveAtEnd + ' observer=' + metrics.observerAlive + ' valid=' + metrics.validity.passed);
  obs.close();
  fs.writeFileSync(path.resolve(__dirname, '..', '.scratch', 'stress-' + NAME + '.json'), JSON.stringify(metrics, null, 1));
  if (failures.length) {
    for (const failure of failures) console.error('STRESS INVALID: ' + failure.name + ' ' + JSON.stringify(failure.detail));
    process.exit(1);
  }
  process.exit(0);
})().catch((e) => { console.error('STRESS CRASH:', e && e.message ? e.message : e); process.exit(2); });
