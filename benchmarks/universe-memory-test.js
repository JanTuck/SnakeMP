/*
 * Accelerated long-horizon memory audit.
 *
 * Twelve thousand real WebSocket join/input/disconnect lifecycles are mapped
 * across a one-million-second virtual timeline. Concurrency stays inside the
 * product's authoritative 100-player IO arena limit; this is a cumulative user
 * universe, never a misleading claim of 12,000 simultaneous players.
 */
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const WebSocket = require('ws');

const BASE = process.env.UNIVERSE_BASE || 'http://127.0.0.1:4914';
const WS_URL = BASE.replace(/^http/, 'ws') + '/ws';
const OUTPUT = process.env.UNIVERSE_OUTPUT || path.join(__dirname, '..', '.scratch', 'universe-memory-test.json');
const USERS = positiveInt('UNIVERSE_USERS', 12_000);
const SIMULATED_SECONDS = positiveInt('UNIVERSE_SIMULATED_SECONDS', 1_000_000);
const ACTIVE_COHORT = Math.min(99, positiveInt('UNIVERSE_ACTIVE_COHORT', 99));
const SAMPLE_EVERY_USERS = positiveInt('UNIVERSE_SAMPLE_EVERY_USERS', 500);
const JOIN_LANES = Math.min(ACTIVE_COHORT, positiveInt('UNIVERSE_JOIN_LANES', 48));
const JOIN_TIMEOUT_MS = positiveInt('UNIVERSE_JOIN_TIMEOUT_MS', 15_000);
const CLEANUP_TIMEOUT_MS = positiveInt('UNIVERSE_CLEANUP_TIMEOUT_MS', 15_000);
const MAX_FINAL_DRIFT = positiveInt('UNIVERSE_MAX_FINAL_DRIFT_BYTES', 8 * 1024 * 1024);
const MAX_RECOVERY_SLOPE_PER_1000 = positiveInt('UNIVERSE_MAX_RECOVERY_SLOPE_BYTES_PER_1000_USERS', 256 * 1024);

function positiveInt(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}

const wait = (ms) => new Promise(resolve => setTimeout(resolve, ms));

function request(method, route, body = '') {
  return new Promise((resolve, reject) => {
    const payload = Buffer.from(body);
    const req = http.request(BASE + route, {
      method,
      agent: false,
      headers: payload.length ? {
        'content-type': 'application/x-www-form-urlencoded',
        'content-length': payload.length,
      } : undefined,
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.setTimeout(10_000, () => req.destroy(new Error(`${method} ${route} timed out`)));
    req.once('error', reject);
    req.end(payload);
  });
}

async function stats() {
  const response = await request('GET', '/debug/stats');
  if (response.status !== 200) throw new Error(`/debug/stats returned HTTP ${response.status}`);
  return JSON.parse(response.body);
}

async function sampledStats(count = 3) {
  const samples = [];
  for (let index = 0; index < count; index++) {
    samples.push(await stats());
    if (index + 1 < count) await wait(25);
  }
  const ordered = [...samples].sort((left, right) => left.rss - right.rss);
  const median = ordered[Math.floor(ordered.length / 2)];
  return {
    serverRssBytes: median.rss,
    serverRssMiB: mib(median.rss),
    serverRssMinBytes: ordered[0].rss,
    serverRssMaxBytes: ordered.at(-1).rss,
    loadGeneratorRssBytes: process.memoryUsage().rss,
    loadGeneratorRssMiB: mib(process.memoryUsage().rss),
    totalPlayers: median.totalPlayers,
    connections: median.connections,
    lobbies: median.lobbies.length,
  };
}

async function waitFor(label, predicate) {
  const deadline = performance.now() + CLEANUP_TIMEOUT_MS;
  let latest;
  while (performance.now() < deadline) {
    latest = await stats();
    if (predicate(latest)) return latest;
    await wait(20);
  }
  throw new Error(`${label} timed out: ${JSON.stringify(latest && {
    rss: latest.rss,
    totalPlayers: latest.totalPlayers,
    connections: latest.connections,
    lobbies: latest.lobbies.length,
  })}`);
}

async function createIoLobby() {
  const response = await request('POST', '/generateid', 'mode=snek_io&capacity=100&walls=wrap&publicTarget=0');
  if (response.status !== 303 || !response.headers.location) {
    throw new Error(`IO lobby creation returned HTTP ${response.status}`);
  }
  return decodeURIComponent(response.headers.location.split('/').pop());
}

function alphaId(value) {
  let result = '';
  let current = value + 1;
  while (current > 0) {
    current--;
    result = String.fromCharCode(97 + (current % 26)) + result;
    current = Math.floor(current / 26);
  }
  return result;
}

function joinPacket(lobby, username) {
  const lobbyBytes = Buffer.from(lobby);
  const usernameBytes = Buffer.from(username);
  return Buffer.concat([
    Buffer.from([1, lobbyBytes.length, usernameBytes.length, 0]),
    lobbyBytes,
    usernameBytes,
  ]);
}

function connectPlayer(lobby, userIndex) {
  return new Promise((resolve, reject) => {
    const username = `user${alphaId(userIndex)}`;
    const socket = new WebSocket(WS_URL, { perMessageDeflate: false });
    let settled = false;
    const timer = setTimeout(() => finish(new Error(`join timed out for ${username}`)), JOIN_TIMEOUT_MS);

    function finish(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        try { socket.terminate(); } catch (_) {}
        reject(error);
      } else {
        resolve(socket);
      }
    }

    socket.once('open', () => socket.send(joinPacket(lobby, username)));
    socket.on('message', (data, isBinary) => {
      if (isBinary) return;
      try {
        const event = JSON.parse(data.toString());
        if (event[0] === 'init') finish();
        if (event[0] === 'game_error') finish(new Error(String(event[1] || 'join rejected')));
      } catch (_) {}
    });
    socket.once('error', error => finish(error));
    socket.once('close', () => {
      if (!settled) finish(new Error(`socket closed before init for ${username}`));
    });
  });
}

async function mapLimit(count, limit, operation) {
  let cursor = 0;
  async function lane() {
    while (cursor < count) await operation(cursor++);
  }
  await Promise.all(Array.from({ length: Math.min(count, limit) }, lane));
}

function terminateAll(sockets) {
  for (const socket of sockets) {
    try { socket.terminate(); } catch (_) {}
  }
}

function steerAndBoost(sockets, cohort) {
  for (let index = 0; index < sockets.length; index++) {
    const encoded = Math.floor(((cohort + index) * 4051) % 65536);
    sockets[index].send(Buffer.from([6, encoded & 255, encoded >>> 8]));
    if ((cohort + index) % 5 === 0) sockets[index].send(Buffer.from([4, 1]));
  }
}

function linearSlope(points) {
  if (points.length < 2) return 0;
  const meanX = points.reduce((sum, point) => sum + point.x, 0) / points.length;
  const meanY = points.reduce((sum, point) => sum + point.y, 0) / points.length;
  let numerator = 0;
  let denominator = 0;
  for (const point of points) {
    numerator += (point.x - meanX) * (point.y - meanY);
    denominator += (point.x - meanX) ** 2;
  }
  return denominator ? numerator / denominator : 0;
}

function mib(bytes) {
  return Number((bytes / 1024 / 1024).toFixed(3));
}

function assertion(name, pass, actual, expected) {
  return { name, pass: Boolean(pass), actual, expected };
}

async function run() {
  const wallStarted = performance.now();
  const coldStart = await sampledStats();
  const warmupLobby = await createIoLobby();
  const warmupSockets = [];
  await mapLimit(Math.min(ACTIVE_COHORT, 25), JOIN_LANES, async offset => {
    warmupSockets.push(await connectPlayer(warmupLobby, USERS + 1 + offset));
  });
  steerAndBoost(warmupSockets, 0);
  terminateAll(warmupSockets);
  await waitFor('warmup player and connection cleanup', sample =>
    sample.totalPlayers <= coldStart.totalPlayers && sample.connections <= coldStart.connections + 1);
  await waitFor('warmup lobby reap', sample => sample.lobbies.length <= coldStart.lobbies);
  await wait(100);
  const baseline = await sampledStats();
  const lobby = await createIoLobby();
  const sentinel = await connectPlayer(lobby, USERS);
  const checkpoints = [];
  let completedUsers = 0;
  let peakServerRssBytes = baseline.serverRssBytes;
  let nextSampleAt = Math.min(USERS, SAMPLE_EVERY_USERS);

  try {
    let cohort = 0;
    while (completedUsers < USERS) {
      const cohortSize = Math.min(ACTIVE_COHORT, USERS - completedUsers);
      const sockets = [];
      await mapLimit(cohortSize, JOIN_LANES, async offset => {
        sockets.push(await connectPlayer(lobby, completedUsers + offset));
      });
      try {
        steerAndBoost(sockets, cohort);
        const active = await stats();
        peakServerRssBytes = Math.max(peakServerRssBytes, active.rss);
      } finally {
        terminateAll(sockets);
      }
      completedUsers += cohortSize;
      await waitFor(`cohort ${cohort + 1} cleanup`, sample =>
        sample.totalPlayers <= baseline.totalPlayers + 1 && sample.connections <= baseline.connections + 2);

      // Closed ws wrapper graphs belong to the driver, not the measured
      // server. Collect them periodically so this 12k-session harness also
      // stays practical on a developer machine.
      if (typeof global.gc === 'function' && cohort % 5 === 0) global.gc();

      if (completedUsers >= nextSampleAt || completedUsers === USERS) {
        const recovered = await sampledStats();
        peakServerRssBytes = Math.max(peakServerRssBytes, recovered.serverRssMaxBytes);
        checkpoints.push({
          completedUsers,
          simulatedSeconds: Number((SIMULATED_SECONDS * completedUsers / USERS).toFixed(3)),
          wallSeconds: Number(((performance.now() - wallStarted) / 1000).toFixed(3)),
          ...recovered,
        });
        nextSampleAt = Math.min(USERS, nextSampleAt + SAMPLE_EVERY_USERS);
        process.stdout.write(`universe ${completedUsers}/${USERS} users · virtual ${checkpoints.at(-1).simulatedSeconds}s · server ${recovered.serverRssMiB} MiB RSS\n`);
      }
      cohort++;
    }
  } finally {
    sentinel.terminate();
  }

  await waitFor('final player and connection cleanup', sample =>
    sample.totalPlayers <= baseline.totalPlayers && sample.connections <= baseline.connections + 1);
  await waitFor('temporary IO lobby reap', sample => sample.lobbies.length <= baseline.lobbies);
  await wait(100);
  const final = await sampledStats();
  const wallSeconds = (performance.now() - wallStarted) / 1000;
  const trendPoints = checkpoints.map(point => ({ x: point.completedUsers, y: point.serverRssBytes }));
  const slopePer1000Users = linearSlope(trendPoints) * 1000;
  const finalDriftBytes = final.serverRssBytes - baseline.serverRssBytes;
  const evidence = {
    schemaVersion: 1,
    test: 'accelerated-universe-memory-test',
    generatedAt: new Date().toISOString(),
    pass: false,
    configuration: {
      cumulativeUsers: USERS,
      simulatedSeconds: SIMULATED_SECONDS,
      maxConcurrentCohort: ACTIVE_COHORT,
      joinConcurrency: JOIN_LANES,
      sampleEveryUsers: SAMPLE_EVERY_USERS,
      thresholds: {
        maxFinalDriftBytes: MAX_FINAL_DRIFT,
        maxRecoverySlopeBytesPer1000Users: MAX_RECOVERY_SLOPE_PER_1000,
      },
    },
    methodology: {
      userMeaning: 'One real WebSocket upgrade, authoritative IO join, snapshot delivery, steering/boost input, and disconnect. Users are cumulative across the virtual timeline, not simultaneous.',
      virtualClock: 'Completed user lifecycles are distributed linearly across 1,000,000 simulated seconds; server ticks and network operations remain real.',
      serverRssScope: 'Measured server-process resident set from /debug/stats. It excludes the load generator and kernel socket buffers.',
      loadGeneratorScope: 'Node process RSS is reported separately at checkpoints and is never added to server RSS.',
      leakSignal: 'All player, connection, and lobby counts recover, then final RSS drift and recovered-RSS slope are bounded. Allocator-retained pages are not mislabeled as live allocations.',
      baselinePreparation: 'A real IO join/snapshot/input/disconnect cycle runs before the baseline so first-use code pages and reusable pools are not misreported as leaks.',
    },
    timing: {
      simulatedSeconds: SIMULATED_SECONDS,
      wallSeconds: Number(wallSeconds.toFixed(3)),
      acceleration: Number((SIMULATED_SECONDS / wallSeconds).toFixed(2)),
      unit: 'simulated-seconds per wall-second',
    },
    coldStart,
    baseline,
    checkpoints,
    memorySummary: {
      baselineServerRssBytes: baseline.serverRssBytes,
      baselineServerRssMiB: baseline.serverRssMiB,
      peakMeasuredServerRssBytes: peakServerRssBytes,
      peakMeasuredServerRssMiB: mib(peakServerRssBytes),
      finalServerRssBytes: final.serverRssBytes,
      finalServerRssMiB: final.serverRssMiB,
      finalDriftBytes,
      finalDriftMiB: mib(finalDriftBytes),
      recoveredSlopeBytesPer1000Users: Number(slopePer1000Users.toFixed(2)),
    },
    final,
    assertions: [],
  };
  evidence.assertions.push(assertion('all configured user lifecycles completed', completedUsers === USERS, completedUsers, USERS));
  evidence.assertions.push(assertion('virtual horizon reached exactly', checkpoints.at(-1)?.simulatedSeconds === SIMULATED_SECONDS, checkpoints.at(-1)?.simulatedSeconds, SIMULATED_SECONDS));
  evidence.assertions.push(assertion('all players released', final.totalPlayers <= baseline.totalPlayers, final.totalPlayers, `<= ${baseline.totalPlayers}`));
  evidence.assertions.push(assertion('all connections released', final.connections <= baseline.connections + 1, final.connections, `<= ${baseline.connections + 1}`));
  evidence.assertions.push(assertion('temporary lobby reaped', final.lobbies <= baseline.lobbies, final.lobbies, `<= ${baseline.lobbies}`));
  evidence.assertions.push(assertion('final server RSS drift is bounded', finalDriftBytes <= MAX_FINAL_DRIFT, finalDriftBytes, `<= ${MAX_FINAL_DRIFT}`));
  evidence.assertions.push(assertion('recovered RSS slope is bounded', slopePer1000Users <= MAX_RECOVERY_SLOPE_PER_1000, Number(slopePer1000Users.toFixed(2)), `<= ${MAX_RECOVERY_SLOPE_PER_1000}`));
  evidence.pass = evidence.assertions.every(item => item.pass);
  return evidence;
}

(async () => {
  let evidence;
  try {
    evidence = await run();
  } catch (error) {
    evidence = {
      schemaVersion: 1,
      test: 'accelerated-universe-memory-test',
      generatedAt: new Date().toISOString(),
      pass: false,
      fatalError: error.stack || String(error),
    };
  }
  fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
  fs.writeFileSync(OUTPUT, JSON.stringify(evidence, null, 2) + '\n');
  process.stdout.write(JSON.stringify(evidence, null, 2) + '\n');
  process.stdout.write(`universe memory evidence: ${OUTPUT}\n`);
  if (!evidence.pass) process.exitCode = 1;
})();
