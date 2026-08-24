/*
 * Lifecycle memory audit for the native WebSocket server.
 *
 * This intentionally complements memory-ramp.js instead of duplicating it:
 * - rapid connection churn without joining;
 * - retained fragmented and partial WebSocket payloads;
 * - repeated lobby creation/destruction;
 * - paused HTTP readers that exercise output backpressure and pipelining.
 *
 * Run against a server started with SNEK_DEBUG=1 and a short
 * SNEK_LOBBY_IDLE_MS. The wrapper in run-memory-lifecycle-audit.js supplies
 * those settings and writes machine-readable evidence under .scratch/.
 */
'use strict';

const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');
const WebSocket = require('ws');

const BASE = process.env.LIFECYCLE_BASE || 'http://127.0.0.1:4912';
const WS_BASE = BASE.replace(/^http/, 'ws') + '/ws';
const OUTPUT = process.env.LIFECYCLE_OUTPUT || path.join(__dirname, '..', '.scratch', 'memory-lifecycle-audit.json');
const PORT = Number(new URL(BASE).port || 80);
const CHURN_ROUNDS = positiveInt('LIFECYCLE_CHURN_ROUNDS', 3);
const CHURN_CONNECTIONS = positiveInt('LIFECYCLE_CHURN_CONNECTIONS', 300);
const RETAINED_CONNECTIONS = positiveInt('LIFECYCLE_RETAINED_CONNECTIONS', 64);
const FRAGMENT_BYTES = positiveInt('LIFECYCLE_FRAGMENT_BYTES', 256 * 1024);
const PARTIAL_BYTES = positiveInt('LIFECYCLE_PARTIAL_BYTES', 128 * 1024);
const LOBBY_WAVES = positiveInt('LIFECYCLE_LOBBY_WAVES', 3);
const LOBBIES_PER_WAVE = positiveInt('LIFECYCLE_LOBBIES_PER_WAVE', 64);
const MALFORMED_CONNECTIONS = positiveInt('LIFECYCLE_MALFORMED_CONNECTIONS', 300);
const PIPELINE_WAVES = positiveInt('LIFECYCLE_PIPELINE_WAVES', 3);
const PIPELINE_CONNECTIONS = positiveInt('LIFECYCLE_PIPELINE_CONNECTIONS', 12);
const PIPELINE_REQUESTS = positiveInt('LIFECYCLE_PIPELINE_REQUESTS', 400);
const MAX_RECOVERY_DRIFT = positiveInt('LIFECYCLE_MAX_RECOVERY_DRIFT_BYTES', 64 * 1024 * 1024);

function positiveInt(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function percentile(values, fraction) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * fraction))];
}

function request(method, route) {
  return new Promise((resolve, reject) => {
    const req = http.request(BASE + route, { method, agent: false }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.setTimeout(10_000, () => req.destroy(new Error(method + ' ' + route + ' timed out')));
    req.once('error', reject);
    req.end();
  });
}

async function stats() {
  const response = await request('GET', '/debug/stats');
  if (response.status !== 200) throw new Error('/debug/stats returned HTTP ' + response.status);
  return JSON.parse(response.body);
}

async function sampledStats(count = 5) {
  const samples = [];
  for (let index = 0; index < count; index++) {
    samples.push(await stats());
    if (index + 1 < count) await wait(75);
  }
  const rss = samples.map((sample) => sample.rss);
  const middle = [...samples].sort((left, right) => left.rss - right.rss)[Math.floor(samples.length / 2)];
  return {
    rssMin: Math.min(...rss),
    rssMedian: percentile(rss, 0.5),
    rssMax: Math.max(...rss),
    connections: middle.connections,
    totalPlayers: middle.totalPlayers,
    lobbies: middle.lobbies.length,
  };
}

async function waitFor(label, predicate, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let latest;
  while (Date.now() < deadline) {
    latest = await stats();
    if (predicate(latest)) return latest;
    await wait(100);
  }
  throw new Error(label + ' timed out: ' + JSON.stringify(latest && {
    connections: latest.connections,
    totalPlayers: latest.totalPlayers,
    lobbies: latest.lobbies.length,
    rss: latest.rss,
  }));
}

function connectWebSocket() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(WS_BASE, { perMessageDeflate: false });
    const timer = setTimeout(() => {
      socket.terminate();
      reject(new Error('WebSocket open timed out'));
    }, 10_000);
    socket.once('open', () => {
      clearTimeout(timer);
      resolve(socket);
    });
    socket.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
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

function terminateAll(sockets) {
  for (const socket of sockets) {
    try { socket.terminate(); } catch (_) {}
  }
}

async function openMany(count) {
  const sockets = [];
  try {
    await mapLimit(count, 64, async () => sockets.push(await connectWebSocket()));
    return sockets;
  } catch (error) {
    terminateAll(sockets);
    throw error;
  }
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
  return Buffer.concat([
    Buffer.from([1, lobbyBytes.length, usernameBytes.length]),
    lobbyBytes,
    usernameBytes,
  ]);
}

function joinLobby(lobby, username) {
  return new Promise(async (resolve, reject) => {
    let socket;
    let timer;
    try {
      socket = await connectWebSocket();
      timer = setTimeout(() => {
        socket.terminate();
        reject(new Error('join timed out for ' + username));
      }, 10_000);
      socket.on('message', (data, binary) => {
        if (binary) return;
        let packet;
        try { packet = JSON.parse(data.toString()); } catch (_) { return; }
        if (packet[0] === 'init') {
          clearTimeout(timer);
          resolve(socket);
        } else if (packet[0] === 'game_error') {
          clearTimeout(timer);
          socket.terminate();
          reject(new Error(String(packet[1])));
        }
      });
      socket.send(joinPacket(lobby, username));
    } catch (error) {
      clearTimeout(timer);
      if (socket) socket.terminate();
      reject(error);
    }
  });
}

async function churnPhase(baseline) {
  const recovered = [];
  for (let round = 1; round <= CHURN_ROUNDS; round++) {
    const sockets = await openMany(CHURN_CONNECTIONS);
    terminateAll(sockets);
    await waitFor('connection churn round ' + round, (sample) => sample.connections <= baseline.connections + 1);
    recovered.push(await sampledStats());
  }
  return {
    rounds: CHURN_ROUNDS,
    connectionsPerRound: CHURN_CONNECTIONS,
    recovered,
  };
}

async function fragmentedPhase(baseline) {
  const sockets = await openMany(RETAINED_CONNECTIONS);
  const payload = Buffer.alloc(FRAGMENT_BYTES, 0x5a);
  await Promise.all(sockets.map((socket) => new Promise((resolve, reject) => {
    socket.send(payload, { binary: true, fin: false }, (error) => error ? reject(error) : resolve());
  })));
  await wait(500);
  const active = await sampledStats();
  terminateAll(sockets);
  await waitFor('fragment connection cleanup', (sample) => sample.connections <= baseline.connections + 1);
  await wait(300);
  return {
    connections: sockets.length,
    fragmentBytesPerConnection: FRAGMENT_BYTES,
    retainedPayloadBytes: sockets.length * FRAGMENT_BYTES,
    active,
    recovered: await sampledStats(),
  };
}

async function partialFramePhase(baseline) {
  const sockets = await openMany(RETAINED_CONNECTIONS);
  const declaredLength = Math.max(PARTIAL_BYTES + 1, 256 * 1024);
  const header = Buffer.alloc(14);
  header[0] = 0x82;
  header[1] = 0xff;
  header.writeBigUInt64BE(BigInt(declaredLength), 2);
  header.writeUInt32BE(0x12345678, 10);
  const partial = Buffer.alloc(PARTIAL_BYTES, 0x6b);
  for (const socket of sockets) socket._socket.write(Buffer.concat([header, partial]));
  await wait(500);
  const active = await sampledStats();
  terminateAll(sockets);
  await waitFor('partial-frame connection cleanup', (sample) => sample.connections <= baseline.connections + 1);
  await wait(300);
  return {
    connections: sockets.length,
    declaredBytesPerConnection: declaredLength,
    receivedBytesPerConnection: PARTIAL_BYTES,
    retainedInputBytes: sockets.length * PARTIAL_BYTES,
    active,
    recovered: await sampledStats(),
  };
}

async function malformedFramePhase(baseline) {
  const sockets = await openMany(MALFORMED_CONNECTIONS);
  const closed = sockets.map((socket) => new Promise((resolve) => {
    socket.once('error', () => {});
    socket.once('close', resolve);
    // Client frames must be masked. This deliberately bypasses ws framing.
    socket._socket.write(Buffer.from([0x82, 0x01, 0x00]));
  }));
  await Promise.race([
    Promise.all(closed),
    wait(10_000).then(() => { throw new Error('malformed WebSocket peers were not rejected'); }),
  ]);
  await waitFor('malformed-frame cleanup', (sample) => sample.connections <= baseline.connections + 1);
  return {
    connections: MALFORMED_CONNECTIONS,
    rejected: MALFORMED_CONNECTIONS,
    recovered: await sampledStats(),
  };
}

async function lobbyLifecyclePhase(baseline) {
  const waves = [];
  for (let wave = 1; wave <= LOBBY_WAVES; wave++) {
    const sockets = [];
    await mapLimit(LOBBIES_PER_WAVE, 16, async (index) => {
      const lobby = await createLobby();
      sockets.push(await joinLobby(lobby, 'lifecycle-' + wave + '-' + index));
    });
    const active = await sampledStats();
    terminateAll(sockets);
    await waitFor('lobby wave ' + wave + ' player cleanup', (sample) =>
      sample.connections <= baseline.connections + 1 && sample.totalPlayers <= baseline.totalPlayers);
    await waitFor('lobby wave ' + wave + ' reap', (sample) => sample.lobbies.length <= baseline.lobbies);
    waves.push({ wave, active, recovered: await sampledStats() });
  }
  return { waves, lobbiesPerWave: LOBBIES_PER_WAVE };
}

function openPausedPipeline() {
  return new Promise((resolve, reject) => {
    const socket = net.connect(PORT, '127.0.0.1');
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('HTTP pipeline connect timed out'));
    }, 10_000);
    socket.once('connect', () => {
      clearTimeout(timer);
      socket.pause();
      const single = 'GET /css/index.css HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n';
      socket.write(single.repeat(PIPELINE_REQUESTS));
      resolve(socket);
    });
    socket.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function backpressurePhase(baseline) {
  const before = await sampledStats();
  const waves = [];
  for (let wave = 1; wave <= PIPELINE_WAVES; wave++) {
    const sockets = await Promise.all(Array.from({ length: PIPELINE_CONNECTIONS }, openPausedPipeline));
    await wait(1500);
    const active = await sampledStats();
    for (const socket of sockets) socket.destroy();
    await waitFor('HTTP backpressure wave ' + wave + ' cleanup', (sample) => sample.connections <= baseline.connections + 1);
    await wait(500);
    waves.push({ wave, active, recovered: await sampledStats() });
  }
  const recovered = waves[waves.length - 1].recovered;
  return {
    waves,
    connections: PIPELINE_CONNECTIONS,
    requestsPerConnection: PIPELINE_REQUESTS,
    before,
    recovered,
    persistentRssGrowthBytes: Math.max(0, recovered.rssMedian - before.rssMedian),
  };
}

function assertion(name, pass, actual, expected) {
  return { name, pass: Boolean(pass), actual, expected };
}

(async () => {
  const evidence = {
    schemaVersion: 1,
    test: 'memory-lifecycle-audit',
    generatedAt: new Date().toISOString(),
    base: BASE,
    configuration: {
      churnRounds: CHURN_ROUNDS,
      churnConnections: CHURN_CONNECTIONS,
      retainedConnections: RETAINED_CONNECTIONS,
      fragmentBytes: FRAGMENT_BYTES,
      partialBytes: PARTIAL_BYTES,
      malformedConnections: MALFORMED_CONNECTIONS,
      pipelineWaves: PIPELINE_WAVES,
      lobbyWaves: LOBBY_WAVES,
      lobbiesPerWave: LOBBIES_PER_WAVE,
      pipelineConnections: PIPELINE_CONNECTIONS,
      pipelineRequests: PIPELINE_REQUESTS,
      maxRecoveryDriftBytes: MAX_RECOVERY_DRIFT,
    },
    baseline: await sampledStats(),
    phases: {},
    assertions: [],
  };

  process.stdout.write('lifecycle audit: connection churn\n');
  evidence.phases.churn = await churnPhase(evidence.baseline);
  process.stdout.write('lifecycle audit: fragmented WebSocket payload retention\n');
  evidence.phases.fragmented = await fragmentedPhase(evidence.baseline);
  process.stdout.write('lifecycle audit: partial WebSocket frame retention\n');
  evidence.phases.partialFrames = await partialFramePhase(evidence.baseline);
  process.stdout.write('lifecycle audit: malformed WebSocket frame churn\n');
  evidence.phases.malformedFrames = await malformedFramePhase(evidence.baseline);
  process.stdout.write('lifecycle audit: lobby create/destroy waves\n');
  evidence.phases.lobbies = await lobbyLifecyclePhase(evidence.baseline);
  process.stdout.write('lifecycle audit: paused-reader HTTP output pressure\n');
  evidence.phases.backpressure = await backpressurePhase(evidence.baseline);
  evidence.final = await sampledStats();

  const baseline = evidence.baseline;
  evidence.assertions.push(assertion(
    'all transient connections are released',
    evidence.final.connections <= baseline.connections + 1,
    evidence.final.connections,
    '<= ' + (baseline.connections + 1),
  ));
  evidence.assertions.push(assertion(
    'all transient players are released',
    evidence.final.totalPlayers <= baseline.totalPlayers,
    evidence.final.totalPlayers,
    '<= ' + baseline.totalPlayers,
  ));
  evidence.assertions.push(assertion(
    'all transient lobbies are reaped',
    evidence.final.lobbies <= baseline.lobbies,
    evidence.final.lobbies,
    '<= ' + baseline.lobbies,
  ));
  evidence.assertions.push(assertion(
    'recovered RSS remains within the lifecycle audit envelope',
    evidence.final.rssMedian <= baseline.rssMedian + MAX_RECOVERY_DRIFT,
    evidence.final.rssMedian - baseline.rssMedian,
    '<= +' + MAX_RECOVERY_DRIFT,
  ));
  evidence.pass = evidence.assertions.every((item) => item.pass);

  fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
  fs.writeFileSync(OUTPUT, JSON.stringify(evidence, null, 2) + '\n');
  process.stdout.write(JSON.stringify(evidence, null, 2) + '\n');
  process.stdout.write('lifecycle evidence: ' + OUTPUT + '\n');
  if (!evidence.pass) process.exitCode = 1;
})().catch((error) => {
  const evidence = {
    schemaVersion: 1,
    test: 'memory-lifecycle-audit',
    generatedAt: new Date().toISOString(),
    pass: false,
    fatalError: error.stack || String(error),
  };
  fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
  fs.writeFileSync(OUTPUT, JSON.stringify(evidence, null, 2) + '\n');
  console.error(evidence.fatalError);
  process.exitCode = 1;
});
