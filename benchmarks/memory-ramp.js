/*
 * Accelerated lifecycle/RSS integration test for the native WebSocket server.
 *
 * The server should be started with SNEK_DEBUG=1 and
 * SNEK_LOBBY_IDLE_MS=60 (the production 30-minute idle lifetime at 30,000x).
 * Each wave creates fresh lobbies, joins a large number of stationary players,
 * closes every socket, waits for lifecycle cleanup, and checks that both state
 * and resident memory return to a bounded baseline.
 */
'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');

const BASE = process.env.MEMORY_BASE || 'http://127.0.0.1:4902';
const WS_BASE = BASE.replace(/^http/, 'ws');
const PLAYERS = positiveInt('MEMORY_PLAYERS', 1000);
const WAVES = positiveInt('MEMORY_WAVES', 4);
const PER_LOBBY = positiveInt('MEMORY_PLAYERS_PER_LOBBY', 16);
const LOBBY_LANES = positiveInt('MEMORY_LOBBY_LANES', 8);
const JOIN_TIMEOUT_MS = positiveInt('MEMORY_JOIN_TIMEOUT_MS', 30_000);
const CLEANUP_TIMEOUT_MS = positiveInt('MEMORY_CLEANUP_TIMEOUT_MS', 15_000);
const SAMPLE_COUNT = positiveInt('MEMORY_SAMPLE_COUNT', 5);
const MAX_RECOVERY_OVER_BASELINE = positiveInt('MEMORY_MAX_RECOVERY_OVER_BASELINE_BYTES', 16 * 1024 * 1024);
const MAX_RECOVERY_GROWTH = positiveInt('MEMORY_MAX_RECOVERY_GROWTH_BYTES', 4 * 1024 * 1024);
const MAX_SLOPE_PER_WAVE = positiveInt('MEMORY_MAX_SLOPE_PER_WAVE_BYTES', 1024 * 1024);
const MAX_POST_WAVE_RSS_INCREASE = positiveInt('MEMORY_MAX_POST_WAVE_RSS_INCREASE_BYTES', 1024 * 1024);
const MIN_RAMP_DOWN_RATIO = boundedNumber('MEMORY_MIN_RAMP_DOWN_RATIO', 0, 0, 1);
const OUTPUT = process.env.MEMORY_OUTPUT || path.join(__dirname, '..', '.scratch', 'memory-ramp-zig.json');

function positiveInt(name, fallback) {
  const parsed = Number(process.env[name]);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function boundedNumber(name, fallback, minimum, maximum) {
  const parsed = Number(process.env[name]);
  return Number.isFinite(parsed) && parsed >= minimum && parsed <= maximum ? parsed : fallback;
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function percentile(values, fraction) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * fraction))];
}

function request(method, route) {
  return new Promise((resolve, reject) => {
    const req = http.request(BASE + route, { method, agent: false }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.setTimeout(10_000, () => req.destroy(new Error(method + ' ' + route + ' timed out')));
    req.on('error', reject);
    req.end();
  });
}

async function stats() {
  const response = await request('GET', '/debug/stats');
  if (response.status !== 200) throw new Error('/debug/stats returned HTTP ' + response.status);
  return JSON.parse(response.body);
}

async function createLobby() {
  const response = await request('POST', '/generateid');
  if (response.status !== 303 || !response.headers.location) {
    throw new Error('POST /generateid failed: HTTP ' + response.status);
  }
  return decodeURIComponent(response.headers.location.split('/').pop());
}

function joinPacket(lobby, username) {
  const lobbyBytes = Buffer.from(lobby);
  const usernameBytes = Buffer.from(username);
  if (lobbyBytes.length > 255 || usernameBytes.length > 255) throw new Error('join field exceeds u8 protocol limit');
  return Buffer.concat([
    Buffer.from([1, lobbyBytes.length, usernameBytes.length]),
    lobbyBytes,
    usernameBytes,
  ]);
}

function connectPlayer(lobby, username) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(WS_BASE + '/ws');
    socket.binaryType = 'arraybuffer';
    let settled = false;
    const timer = setTimeout(() => finish(new Error('join timed out for ' + username)), JOIN_TIMEOUT_MS);

    function finish(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        try { socket.close(); } catch (_) {}
        reject(error);
      } else {
        resolve(socket);
      }
    }

    socket.addEventListener('open', () => socket.send(joinPacket(lobby, username)));
    socket.addEventListener('message', (event) => {
      if (typeof event.data !== 'string') return;
      try {
        const packet = JSON.parse(event.data);
        if (packet[0] === 'init') finish();
        if (packet[0] === 'game_error') finish(new Error(String(packet[1] || 'join rejected')));
      } catch (_) {
        // Ignore unrelated control text; the server's init event is JSON.
      }
    });
    socket.addEventListener('error', () => finish(new Error('websocket error for ' + username)));
    socket.addEventListener('close', () => {
      if (!settled) finish(new Error('websocket closed before init for ' + username));
    });
  });
}

async function mapLimit(count, limit, operation) {
  let cursor = 0;
  async function lane() {
    while (cursor < count) {
      const index = cursor++;
      await operation(index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(count, limit) }, lane));
}

async function createWave(wave) {
  const sockets = [];
  const lobbyCount = Math.ceil(PLAYERS / PER_LOBBY);
  const started = performance.now();
  try {
    await mapLimit(lobbyCount, LOBBY_LANES, async (lobbyIndex) => {
      const lobby = await createLobby();
      const first = lobbyIndex * PER_LOBBY;
      const count = Math.min(PER_LOBBY, PLAYERS - first);
      const joined = await Promise.all(Array.from({ length: count }, (_, slot) =>
        connectPlayer(lobby, 'r' + wave + '-' + (first + slot))));
      sockets.push(...joined);
    });
  } catch (error) {
    closeSockets(sockets);
    throw error;
  }
  return { sockets, lobbyCount, joinMs: performance.now() - started };
}

async function waitFor(label, predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let latest;
  while (Date.now() < deadline) {
    latest = await stats();
    if (predicate(latest)) return latest;
    await wait(100);
  }
  throw new Error(label + ' timed out; last stats=' + JSON.stringify(latest && {
    totalPlayers: latest.totalPlayers,
    connections: latest.connections,
    lobbies: latest.lobbies && latest.lobbies.length,
    rss: latest.rss,
  }));
}

async function sampledStats() {
  const samples = [];
  for (let i = 0; i < SAMPLE_COUNT; i++) {
    samples.push(await stats());
    if (i + 1 < SAMPLE_COUNT) await wait(100);
  }
  const rssValues = samples.map((sample) => sample.rss);
  const middle = [...samples].sort((a, b) => a.rss - b.rss)[Math.floor(samples.length / 2)];
  return {
    stats: middle,
    rss: {
      min: Math.min(...rssValues),
      median: percentile(rssValues, 0.5),
      max: Math.max(...rssValues),
    },
  };
}

function closeSockets(sockets) {
  for (const socket of sockets) {
    try { socket.close(1000, 'wave complete'); } catch (_) {}
  }
}

function linearSlope(values) {
  if (values.length < 2) return 0;
  const meanX = (values.length - 1) / 2;
  const meanY = values.reduce((sum, value) => sum + value, 0) / values.length;
  let numerator = 0;
  let denominator = 0;
  for (let x = 0; x < values.length; x++) {
    numerator += (x - meanX) * (values[x] - meanY);
    denominator += (x - meanX) ** 2;
  }
  return denominator ? numerator / denominator : 0;
}

function assertion(name, pass, actual, expected) {
  return { name, pass: Boolean(pass), actual, expected };
}

async function main() {
  const initial = await sampledStats();
  const baseline = {
    rssBytes: initial.rss.median,
    totalPlayers: initial.stats.totalPlayers,
    connections: initial.stats.connections,
    lobbies: initial.stats.lobbies.length,
  };
  const evidence = {
    schemaVersion: 1,
    test: 'accelerated-lifecycle-memory-ramp',
    generatedAt: new Date().toISOString(),
    base: BASE,
    configuration: {
      playersPerWave: PLAYERS,
      waves: WAVES,
      playersPerLobby: PER_LOBBY,
      lifecycleAcceleration: 1000,
      expectedLobbyIdleMs: 60,
      thresholds: {
        maxRecoveryOverBaselineBytes: MAX_RECOVERY_OVER_BASELINE,
        maxRecoveryGrowthBytes: MAX_RECOVERY_GROWTH,
        maxSlopePerWaveBytes: MAX_SLOPE_PER_WAVE,
        maxPostWaveRssIncreaseBytes: MAX_POST_WAVE_RSS_INCREASE,
        minRampDownRatio: MIN_RAMP_DOWN_RATIO,
      },
    },
    methodology: {
      acceleratedComponent: 'lobby idle/reap timeout only; socket creation and 15 Hz simulation run in real time',
      rssScope: 'server process resident set from /debug/stats; excludes kernel socket buffers and the load generator',
      proofScope: 'live players/connections/lobbies return to baseline and recovered RSS remains bounded across waves; allocators may retain freed pages for reuse, so OS RSS need not fall after every wave',
    },
    baseline,
    waves: [],
    assertions: [],
  };

  for (let wave = 1; wave <= WAVES; wave++) {
    process.stdout.write('memory wave ' + wave + '/' + WAVES + ': joining ' + PLAYERS + ' players\n');
    const created = await createWave(wave);
    let active;
    try {
      await waitFor('wave ' + wave + ' activation', (sample) => sample.totalPlayers >= baseline.totalPlayers + PLAYERS, JOIN_TIMEOUT_MS);
      active = await sampledStats();
    } finally {
      closeSockets(created.sockets);
    }
    await waitFor('wave ' + wave + ' player/connection cleanup', (sample) =>
      sample.totalPlayers <= baseline.totalPlayers && sample.connections <= baseline.connections + 1, CLEANUP_TIMEOUT_MS);
    await waitFor('wave ' + wave + ' lobby reap', (sample) => sample.lobbies.length <= baseline.lobbies, CLEANUP_TIMEOUT_MS);
    await wait(200);
    const recovered = await sampledStats();
    const activeRss = active.rss.max;
    const recoveredRss = recovered.rss.median;
    const excess = Math.max(0, activeRss - baseline.rssBytes);
    const rampDownBytes = Math.max(0, activeRss - recoveredRss);
    evidence.waves.push({
      wave,
      requestedPlayers: PLAYERS,
      createdLobbies: created.lobbyCount,
      joinMs: Number(created.joinMs.toFixed(2)),
      active: {
        rssBytes: activeRss,
        totalPlayers: active.stats.totalPlayers,
        connections: active.stats.connections,
        lobbies: active.stats.lobbies.length,
      },
      recovered: {
        rssBytes: recoveredRss,
        totalPlayers: recovered.stats.totalPlayers,
        connections: recovered.stats.connections,
        lobbies: recovered.stats.lobbies.length,
      },
      rampDownBytes,
      rampDownRatioOfActiveExcess: excess ? Number((rampDownBytes / excess).toFixed(4)) : 1,
    });
  }

  for (const wave of evidence.waves) {
    evidence.assertions.push(assertion(
      'wave ' + wave.wave + ' player count recovers',
      wave.recovered.totalPlayers <= baseline.totalPlayers,
      wave.recovered.totalPlayers,
      '<= ' + baseline.totalPlayers,
    ));
    evidence.assertions.push(assertion(
      'wave ' + wave.wave + ' connection count recovers',
      wave.recovered.connections <= baseline.connections + 1,
      wave.recovered.connections,
      '<= ' + (baseline.connections + 1),
    ));
    evidence.assertions.push(assertion(
      'wave ' + wave.wave + ' lobbies are reaped',
      wave.recovered.lobbies <= baseline.lobbies,
      wave.recovered.lobbies,
      '<= ' + baseline.lobbies,
    ));
    evidence.assertions.push(assertion(
      'wave ' + wave.wave + ' RSS does not jump after release',
      wave.recovered.rssBytes <= wave.active.rssBytes + MAX_POST_WAVE_RSS_INCREASE,
      wave.recovered.rssBytes - wave.active.rssBytes,
      '<= +' + MAX_POST_WAVE_RSS_INCREASE,
    ));
    if (MIN_RAMP_DOWN_RATIO > 0) {
      evidence.assertions.push(assertion(
        'wave ' + wave.wave + ' strict RSS ramp-down ratio',
        wave.rampDownRatioOfActiveExcess >= MIN_RAMP_DOWN_RATIO,
        wave.rampDownRatioOfActiveExcess,
        '>= ' + MIN_RAMP_DOWN_RATIO,
      ));
    }
    evidence.assertions.push(assertion(
      'wave ' + wave.wave + ' recovery stays near baseline',
      wave.recovered.rssBytes <= baseline.rssBytes + MAX_RECOVERY_OVER_BASELINE,
      wave.recovered.rssBytes,
      '<= ' + (baseline.rssBytes + MAX_RECOVERY_OVER_BASELINE),
    ));
  }

  const recoveredRss = evidence.waves.map((wave) => wave.recovered.rssBytes);
  const growth = Math.max(0, ...recoveredRss.map((value) => value - recoveredRss[0]));
  const slope = linearSlope(recoveredRss);
  evidence.recoveryTrend = {
    rssBytes: recoveredRss,
    maxGrowthFromFirstRecoveryBytes: growth,
    linearSlopeBytesPerWave: Number(slope.toFixed(2)),
    rssDecreaseObserved: evidence.waves.some((wave) => wave.rampDownBytes > 0),
    interpretation: 'Freed small allocations may remain resident for allocator reuse; bounded recovery RSS plus zero live players/connections/lobbies is the leak regression signal.',
  };
  evidence.assertions.push(assertion(
    'recovered RSS does not drift wave-over-wave',
    growth <= MAX_RECOVERY_GROWTH,
    growth,
    '<= ' + MAX_RECOVERY_GROWTH,
  ));
  evidence.assertions.push(assertion(
    'recovered RSS slope remains bounded',
    slope <= MAX_SLOPE_PER_WAVE,
    Number(slope.toFixed(2)),
    '<= ' + MAX_SLOPE_PER_WAVE,
  ));
  evidence.pass = evidence.assertions.every((item) => item.pass);
  return evidence;
}

(async () => {
  let evidence;
  try {
    evidence = await main();
  } catch (error) {
    evidence = {
      schemaVersion: 1,
      test: 'accelerated-lifecycle-memory-ramp',
      generatedAt: new Date().toISOString(),
      pass: false,
      fatalError: error.stack || String(error),
    };
  }
  fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
  fs.writeFileSync(OUTPUT, JSON.stringify(evidence, null, 2) + '\n');
  process.stdout.write(JSON.stringify(evidence, null, 2) + '\n');
  process.stdout.write('memory-ramp evidence: ' + OUTPUT + '\n');
  if (!evidence.pass) process.exitCode = 1;
})();
