/* Staged high-concurrency benchmark for the adaptive-worker Zig server.
 *
 * Usage:
 *   MASS_BASE=http://127.0.0.1:4900 MASS_SERVER_PID=<pid> \
 *     node benchmarks/mass-bench.js
 *
 * The server must run with SNEK_DEBUG=1 and a sufficiently high
 * SNEK_MAX_PLAYERS. Results are written to .scratch/mass-zig.json.
 */
const childProcess = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');

const BASE = process.env.MASS_BASE || 'http://127.0.0.1:4900';
const SERVER_PID = Number(process.env.MASS_SERVER_PID || 0);
const LEVELS = String(process.env.MASS_LEVELS || '1000,3000,6000,9000,12000').split(',').map(Number).filter(Boolean);
const WORKERS = Math.max(1, Number(process.env.MASS_CLIENT_WORKERS || 8));
const PER_LOBBY = Math.max(1, Number(process.env.MASS_PLAYERS_PER_LOBBY || 16));
const WARMUP_MS = Math.max(1000, Number(process.env.MASS_WARMUP_MS || 3000));
const SAMPLE_MS = Math.max(2000, Number(process.env.MASS_SAMPLE_MS || 5000));
const TICK_HZ = Math.max(1, Number(process.env.MASS_TICK_HZ || 15));
const CLK_TCK = (() => {
  try {
    return Number(childProcess.execFileSync('getconf', ['CLK_TCK'], { encoding: 'utf8' }).trim()) || 100;
  } catch (_) {
    return 100;
  }
})();
const PAGE_SIZE = (() => {
  try {
    return Number(childProcess.execFileSync('getconf', ['PAGESIZE'], { encoding: 'utf8' }).trim()) || 4096;
  } catch (_) {
    return 4096;
  }
})();
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const percentile = (values, p) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p))];
};
const round = (value, places = 2) => Number(value.toFixed(places));

function request(method, route) {
  return new Promise((resolve) => {
    const req = http.request(BASE + route, { method, agent: new http.Agent({ keepAlive: true }) }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', (error) => resolve({ error: String(error) }));
    req.end();
  });
}

async function stats() {
  const response = await request('GET', '/debug/stats');
  try { return JSON.parse(response.body); } catch (_) { return null; }
}

function procSnapshot() {
  if (!SERVER_PID) return null;
  try {
    const status = fs.readFileSync('/proc/' + SERVER_PID + '/status', 'utf8');
    const stat = fs.readFileSync('/proc/' + SERVER_PID + '/stat', 'utf8');
    const field = (key) => {
      const line = status.split('\n').find((entry) => entry.startsWith(key + ':'));
      return line ? line.slice(key.length + 1).trim() : '';
    };
    const parts = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    let kernelTcpHostWide = null;
    try {
      const tcp = fs.readFileSync('/proc/net/sockstat', 'utf8').split('\n').find((line) => line.startsWith('TCP:'));
      if (tcp) {
        const parts = tcp.trim().split(/\s+/).slice(1);
        const fields = {};
        for (let i = 0; i + 1 < parts.length; i += 2) fields[parts[i]] = Number(parts[i + 1]);
        kernelTcpHostWide = {
          inUseSockets: fields.inuse || 0,
          allocatedSockets: fields.alloc || 0,
          timeWaitSockets: fields.tw || 0,
          orphanSockets: fields.orphan || 0,
          memoryPages: fields.mem || 0,
          memoryBytes: (fields.mem || 0) * PAGE_SIZE,
        };
      }
    } catch (_) {}
    return {
      at: performance.now(),
      cpuTicks: Number(parts[11]) + Number(parts[12]),
      rssBytes: (parseInt(field('VmRSS'), 10) || 0) * 1024,
      vmBytes: (parseInt(field('VmSize'), 10) || 0) * 1024,
      threads: parseInt(field('Threads'), 10) || 0,
      fds: fs.readdirSync('/proc/' + SERVER_PID + '/fd').length,
      kernelTcpHostWide,
    };
  } catch (_) { return null; }
}

const clients = [];
let requestId = 1;
const pending = new Map();

function spawnClients() {
  return Promise.all(Array.from({ length: WORKERS }, (_, workerIndex) => new Promise((resolve, reject) => {
    const child = childProcess.fork(path.join(__dirname, 'mass-worker.js'), [], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
    child.on('error', reject);
    child.on('message', (message) => {
      if (message.type === 'ready') resolve();
      if (message.requestId && pending.has(message.requestId)) {
        pending.get(message.requestId)(message);
        pending.delete(message.requestId);
      }
    });
    clients.push(child);
    child.send({ type: 'init', base: BASE, workerIndex });
  })));
}

function snapshots() {
  return Promise.all(clients.map((child) => new Promise((resolve) => {
    const id = requestId++;
    pending.set(id, resolve);
    child.send({ type: 'snapshot', requestId: id });
  })));
}

function totals(parts) {
  const result = { connected: 0, joined: 0, failed: 0, disconnected: 0, packets: 0, cadence: [], joinLatencyMs: [] };
  for (const part of parts) {
    for (const key of ['connected', 'joined', 'failed', 'disconnected', 'packets']) result[key] += part.counters[key];
    result.cadence.push(...part.cadence);
    result.joinLatencyMs.push(...part.joinLatencyMs);
  }
  return result;
}

async function createLobby() {
  const response = await request('POST', '/generateid');
  if (response.status !== 303 || !response.headers.location) throw new Error('create lobby failed: ' + JSON.stringify(response));
  return decodeURIComponent(response.headers.location.split('/').pop());
}

async function ensureLobbies(lobbies, count) {
  while (lobbies.length < count) {
    const wanted = Math.min(32, count - lobbies.length);
    lobbies.push(...await Promise.all(Array.from({ length: wanted }, createLobby)));
    process.stdout.write('\rcreated lobbies: ' + lobbies.length + '/' + count);
  }
  process.stdout.write('\n');
}

async function waitForJoins(target) {
  const deadline = Date.now() + 180000;
  const latencies = [];
  while (Date.now() < deadline) {
    const current = totals(await snapshots());
    latencies.push(...current.joinLatencyMs);
    process.stdout.write('\rjoined players: ' + current.joined + '/' + target + ' (failed ' + current.failed + ')');
    if (current.joined >= target || current.joined + current.failed >= target) {
      process.stdout.write('\n');
      current.joinLatencyMs = latencies;
      return current;
    }
    await wait(500);
  }
  throw new Error('timed out waiting for ' + target + ' joins');
}

function lobbySummary(serverStats) {
  const lobbies = serverStats ? serverStats.lobbies.filter((lobby) => lobby.players > 0) : [];
  const tick = lobbies.map((lobby) => lobby.lastTickMs);
  const serialize = lobbies.map((lobby) => lobby.serializeUs);
  const encode = lobbies.map((lobby) => lobby.encodeUs).filter(Number.isFinite);
  const fanout = lobbies.map((lobby) => lobby.fanoutUs).filter(Number.isFinite);
  const summary = (values) => ({
    p50: round(percentile(values, 0.50), 3),
    p95: round(percentile(values, 0.95), 3),
    p99: round(percentile(values, 0.99), 3),
    max: round(Math.max(0, ...values), 3),
  });
  return {
    active: lobbies.length,
    tickMs: summary(tick),
    serializeUs: summary(serialize),
    ...(encode.length ? { encodeUs: summary(encode) } : {}),
    ...(fanout.length ? { fanoutUs: summary(fanout) } : {}),
  };
}

(async () => {
  if (!SERVER_PID) throw new Error('MASS_SERVER_PID is required for CPU/RAM measurements');
  const output = {
    schemaVersion: 2,
    base: BASE,
    serverPid: SERVER_PID,
    levels: LEVELS,
    clientWorkers: WORKERS,
    playersPerLobby: PER_LOBBY,
    tickHz: TICK_HZ,
    warmupMs: WARMUP_MS,
    sampleMs: SAMPLE_MS,
    methodology: {
      workload: 'stationary joined players; every lobby remains active at the configured tick rate',
      topology: 'server and load-generator workers share one loopback host',
      processCpu: 'Linux process CPU; 100% equals one fully occupied logical CPU',
      processRss: 'VmRSS for the server process only; excludes kernel socket buffers and load generators',
      kernelTcpHostWide: '/proc/net/sockstat for the whole network namespace; includes both loopback endpoints, load generators, the server, and unrelated TCP sockets',
      wireBytes: 'all server userspace socket-write bytes divided by emitted WebSocket frames; overwhelmingly snapshot traffic but includes one /debug/stats HTTP response per sample; includes WebSocket framing and excludes TCP/IP/TLS overhead',
      delivery: 'decoded client snapshots divided by all server-emitted WebSocket frames in a surrounding counter window; conservative because rare control frames are included in the denominator',
      configuredTickRatio: 'received snapshots divided by per-worker active clients, configured tick rate, and each worker\'s measured sample duration; finite-window tick boundaries can put this slightly above 1',
    },
    phases: [],
  };
  const lobbies = [];
  let assigned = 0;
  await spawnClients();

  for (const target of LEVELS) {
    await ensureLobbies(lobbies, Math.ceil(target / PER_LOBBY));
    const batches = Array.from({ length: WORKERS }, () => []);
    for (let ordinal = assigned; ordinal < target; ordinal++) {
      batches[ordinal % WORKERS].push({ ordinal, lobby: lobbies[Math.floor(ordinal / PER_LOBBY)] });
    }
    clients.forEach((child, index) => child.send({ type: 'add', jobs: batches[index] }));
    assigned = target;
    const joined = await waitForJoins(target);
    await wait(WARMUP_MS);
    await snapshots(); // discard warmup cadence and establish counter baseline
    const beforeProc = procSnapshot();
    const beforeServer = await stats();
    const beforeClientParts = await snapshots();
    const beforeClient = totals(beforeClientParts);
    await wait(SAMPLE_MS);
    // Nest the client counter window inside the server counter window. This
    // makes received/sent delivery a conservative ratio instead of allowing
    // boundary packets to appear received before/after the measured sends.
    const afterClientParts = await snapshots();
    const afterClient = totals(afterClientParts);
    const afterServer = await stats();
    const afterProc = procSnapshot();
    const packets = afterClient.packets - beforeClient.packets;
    const procSeconds = beforeProc && afterProc ? (afterProc.at - beforeProc.at) / 1000 : SAMPLE_MS / 1000;
    const cpuPct = beforeProc && afterProc ? (afterProc.cpuTicks - beforeProc.cpuTicks) / CLK_TCK / procSeconds * 100 : 0;
    const concurrentPlayers = afterServer.totalPlayers;
    let expectedPackets = 0;
    let workerSecondsTotal = 0;
    for (let i = 0; i < afterClientParts.length; i++) {
      const before = beforeClientParts[i];
      const after = afterClientParts[i];
      const duration = Math.max(0, (after.sampledAtMs - before.sampledAtMs) / 1000);
      const activeBefore = Math.max(0, before.counters.joined - before.counters.disconnected);
      const activeAfter = Math.max(0, after.counters.joined - after.counters.disconnected);
      const activeClients = (activeBefore + activeAfter) / 2;
      workerSecondsTotal += duration;
      expectedPackets += activeClients * TICK_HZ * duration;
    }
    const averageWorkerSeconds = workerSecondsTotal / Math.max(1, afterClientParts.length);
    const sentBytes = afterServer.networkBytesSent - beforeServer.networkBytesSent;
    const sentFrames = afterServer.websocketFramesSent - beforeServer.websocketFramesSent;
    const phase = {
      requestedPlayers: target,
      joinedPlayers: joined.joined,
      concurrentPlayers,
      joinFailures: joined.failed,
      sampleDisconnects: afterClient.disconnected - beforeClient.disconnected,
      joinLatencyMs: { p50: round(percentile(joined.joinLatencyMs, 0.50)), p95: round(percentile(joined.joinLatencyMs, 0.95)), p99: round(percentile(joined.joinLatencyMs, 0.99)) },
      receivedMessagesPerSec: round(packets / averageWorkerSeconds),
      deliveryRatio: round(sentFrames ? packets / sentFrames : 0, 4),
      configuredTickRatio: round(expectedPackets ? packets / expectedPackets : 0, 4),
      averageWireBytes: round(sentFrames ? sentBytes / sentFrames : 0),
      clientTickCadenceMs: { p50: round(percentile(afterClient.cadence, 0.50), 3), p95: round(percentile(afterClient.cadence, 0.95), 3), p99: round(percentile(afterClient.cadence, 0.99), 3) },
      server: {
        cpuPct: round(cpuPct), rssBytes: afterProc && afterProc.rssBytes, vmBytes: afterProc && afterProc.vmBytes,
        threads: afterProc && afterProc.threads, fds: afterProc && afterProc.fds,
        kernelTcpHostWide: afterProc && afterProc.kernelTcpHostWide,
        bytesSentPerSec: round(sentBytes / procSeconds),
        bytesReceivedPerSec: round((afterServer.networkBytesReceived - beforeServer.networkBytesReceived) / procSeconds),
        websocketFramesSentPerSec: round(sentFrames / procSeconds),
        ...lobbySummary(afterServer),
      },
    };
    output.phases.push(phase);
    console.log(JSON.stringify(phase, null, 2));
  }

  fs.mkdirSync(path.join(__dirname, '..', '.scratch'), { recursive: true });
  const destination = path.join(__dirname, '..', '.scratch', 'mass-zig.json');
  fs.writeFileSync(destination, JSON.stringify(output, null, 2));
  console.log('wrote ' + destination);
  for (const client of clients) client.send({ type: 'close' });
})().catch((error) => {
  console.error(error.stack || error);
  for (const client of clients) client.send({ type: 'close' });
  process.exitCode = 1;
});
