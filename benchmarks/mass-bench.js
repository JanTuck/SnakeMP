/* Staged high-concurrency benchmark for the adaptive-worker Zig server.
 *
 * Usage:
 *   MASS_BASE=http://127.0.0.1:4900 MASS_SERVER_PID=<pid> \
 *     node benchmarks/mass-bench.js
 *
 * The server must run with SNEK_DEBUG=1. Results are written to
 * .scratch/mass-zig.json.
 */
const childProcess = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');

const BASE = process.env.MASS_BASE || 'http://127.0.0.1:4900';
const SERVER_PID = Number(process.env.MASS_SERVER_PID || 0);
const LEVELS = String(process.env.MASS_LEVELS || '5,10,20,32').split(',').map(Number).filter(Boolean);
const WORKERS = Math.max(1, Number(process.env.MASS_CLIENT_WORKERS || 8));
const PER_LOBBY = Math.max(1, Number(process.env.MASS_PLAYERS_PER_LOBBY || 16));
const WARMUP_MS = Math.max(1000, Number(process.env.MASS_WARMUP_MS || 3000));
const SAMPLE_MS = Math.max(2000, Number(process.env.MASS_SAMPLE_MS || 5000));
const TICK_HZ = Math.max(1, Number(process.env.MASS_TICK_HZ || 15));
const READY_TIMEOUT_MS = 15000;
const SNAPSHOT_TIMEOUT_MS = 15000;
const ADD_TIMEOUT_MS = 360000;
if (!LEVELS.length || LEVELS.some((level, index) => !Number.isInteger(level) || level <= 0 || (index > 0 && level <= LEVELS[index - 1]))) {
  throw new Error('MASS_LEVELS must contain strictly increasing positive integers');
}
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
  if (response.error || response.status !== 200) {
    throw new Error('debug stats request failed: ' + JSON.stringify(response));
  }
  let parsed;
  try { parsed = JSON.parse(response.body); } catch (error) {
    throw new Error('debug stats returned invalid JSON: ' + String(error));
  }
  for (const key of ['totalPlayers', 'networkBytesSent', 'networkBytesReceived', 'websocketFramesSent']) {
    if (!Number.isFinite(parsed[key]) || parsed[key] < 0) throw new Error('debug stats has invalid ' + key);
  }
  if (!Array.isArray(parsed.lobbies)) throw new Error('debug stats has invalid lobbies');
  return parsed;
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
const clientFailures = new Map();

function failClient(child, error) {
  const failure = error instanceof Error ? error : new Error(String(error));
  if (!clientFailures.has(child)) clientFailures.set(child, failure);
  for (const [id, entry] of pending) {
    if (entry.child !== child) continue;
    clearTimeout(entry.timer);
    pending.delete(id);
    entry.reject(failure);
  }
}

function workerRequest(child, type, payload, timeoutMs) {
  return new Promise((resolve, reject) => {
    const priorFailure = clientFailures.get(child);
    if (priorFailure) return reject(priorFailure);
    if (!child.connected) return reject(new Error('client worker IPC is disconnected'));
    const id = requestId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error('client worker timed out handling ' + type));
    }, timeoutMs);
    pending.set(id, { child, type, resolve, reject, timer });
    try {
      child.send({ type, requestId: id, ...payload }, (error) => {
        if (!error || !pending.has(id)) return;
        clearTimeout(timer);
        pending.delete(id);
        reject(error);
      });
    } catch (error) {
      clearTimeout(timer);
      pending.delete(id);
      reject(error);
    }
  });
}

function spawnClients() {
  return Promise.all(Array.from({ length: WORKERS }, (_, workerIndex) => {
    const child = childProcess.fork(path.join(__dirname, 'mass-worker.js'), [], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
    clients.push(child);
    child.on('error', (error) => failClient(child, new Error('client worker ' + workerIndex + ' error: ' + error.message)));
    child.on('exit', (code, signal) => failClient(child, new Error('client worker ' + workerIndex + ' exited (code ' + code + ', signal ' + signal + ')')));
    child.on('message', (message) => {
      if (!message.requestId || !pending.has(message.requestId)) return;
      const entry = pending.get(message.requestId);
      if (entry.child !== child) return;
      clearTimeout(entry.timer);
      pending.delete(message.requestId);
      const expectedType = { init: 'ready', add: 'added', snapshot: 'snapshot' }[entry.type];
      if (message.type !== expectedType) {
        entry.reject(new Error('client worker returned ' + message.type + ' while handling ' + entry.type));
        return;
      }
      if (message.ok === false) {
        const detail = message.error || (message.failedJobs + ' add jobs failed: ' + JSON.stringify(message.failures || []));
        entry.reject(new Error('client worker failed handling ' + entry.type + ': ' + detail));
      } else {
        entry.resolve(message);
      }
    });
    return workerRequest(child, 'init', { base: BASE, workerIndex }, READY_TIMEOUT_MS);
  }));
}

function snapshots() {
  return Promise.all(clients.map((child) => workerRequest(child, 'snapshot', {}, SNAPSHOT_TIMEOUT_MS)));
}

function totals(parts) {
  const result = {
    connected: 0,
    joined: 0,
    active: 0,
    failed: 0,
    disconnected: 0,
    packets: 0,
    binaryPackets: 0,
    invalidPackets: 0,
    observedActive: 0,
    cadence: [],
    joinLatencyMs: [],
  };
  for (const part of parts) {
    for (const key of ['connected', 'joined', 'active', 'failed', 'disconnected', 'packets', 'binaryPackets', 'invalidPackets']) {
      if (!Number.isFinite(part.counters[key]) || part.counters[key] < 0) throw new Error('client worker returned invalid counter ' + key);
      result[key] += part.counters[key];
    }
    if (!Number.isFinite(part.observedActive) || part.observedActive < 0) throw new Error('client worker returned invalid observedActive');
    result.observedActive += part.observedActive;
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
    if (current.failed > 0) throw new Error(current.failed + ' client joins failed');
    if (current.joined > target) throw new Error('joined player count exceeded target: ' + current.joined + ' > ' + target);
    if (current.joined === target) {
      process.stdout.write('\n');
      current.joinLatencyMs = latencies;
      if (current.active !== target) throw new Error('only ' + current.active + '/' + target + ' joined clients remain active');
      return current;
    }
    await wait(500);
  }
  throw new Error('timed out waiting for ' + target + ' joins');
}

function assertClientPlayers(label, clientStats, target) {
  if (clientStats.failed !== 0) throw new Error(label + ': ' + clientStats.failed + ' client joins failed');
  if (clientStats.joined !== target) throw new Error(label + ': client joined count is ' + clientStats.joined + ', expected ' + target);
  if (clientStats.active !== target) throw new Error(label + ': client active count is ' + clientStats.active + ', expected ' + target);
  const expectedObserved = Math.floor((target - 1) / 64) + 1;
  if (clientStats.observedActive !== expectedObserved) {
    throw new Error(label + ': cadence observer count is ' + clientStats.observedActive + ', expected ' + expectedObserved);
  }
}

function assertServerPlayers(label, serverStats, target) {
  if (serverStats.totalPlayers !== target) {
    throw new Error(label + ': server player count is ' + serverStats.totalPlayers + ', expected ' + target);
  }
  const activeLobbies = serverStats.lobbies.filter((lobby) => lobby.players > 0);
  const expectedLobbies = Math.ceil(target / PER_LOBBY);
  if (activeLobbies.length !== expectedLobbies) {
    throw new Error(label + ': server active lobby count is ' + activeLobbies.length + ', expected ' + expectedLobbies);
  }
  if (activeLobbies.some((lobby) => !Number.isFinite(lobby.players) || lobby.players <= 0)) {
    throw new Error(label + ': server returned an invalid lobby player count');
  }
  const lobbyPlayers = activeLobbies.reduce((sum, lobby) => sum + lobby.players, 0);
  if (lobbyPlayers !== target) throw new Error(label + ': lobby player sum is ' + lobbyPlayers + ', expected ' + target);
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

function closeClients() {
  for (const client of clients) {
    if (!client.connected) continue;
    try { client.send({ type: 'close' }, () => {}); } catch (_) {}
  }
}

(async () => {
  if (!SERVER_PID) throw new Error('MASS_SERVER_PID is required for CPU/RAM measurements');
  if (!procSnapshot()) throw new Error('MASS_SERVER_PID does not identify a readable running process');
  const initialServer = await stats();
  if (initialServer.totalPlayers !== 0) throw new Error('benchmark server must start with zero players');
  const serverPlayerCap = Math.min(32, initialServer.maxPlayers);
  if (!Number.isSafeInteger(serverPlayerCap) || serverPlayerCap < 1) {
    throw new Error('debug stats returned an invalid maxPlayers capacity');
  }
  if (LEVELS.some((level) => level > serverPlayerCap)) {
    throw new Error('MASS_LEVELS exceeds the server player cap of ' + serverPlayerCap);
  }
  if (!Number.isSafeInteger(PER_LOBBY) || PER_LOBBY > Math.min(32, initialServer.maxPlayersPerLobby)) {
    throw new Error('MASS_PLAYERS_PER_LOBBY exceeds the server lobby cap of ' + Math.min(32, initialServer.maxPlayersPerLobby));
  }
  const output = {
    schemaVersion: 2,
    base: BASE,
    serverPid: SERVER_PID,
    serverPlayerCap,
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
      validity: 'phases require exact client/server player agreement, no failed joins or disconnects, monotonic server counters, zero rejected binary snapshots, and non-empty delivery/cadence samples; no performance threshold is used',
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
    await Promise.all(clients.map((child, index) => workerRequest(child, 'add', { jobs: batches[index] }, ADD_TIMEOUT_MS)));
    assigned = target;
    const joined = await waitForJoins(target);
    assertClientPlayers('post-join', joined, target);
    await wait(WARMUP_MS);
    await snapshots(); // discard warmup cadence and establish counter baseline
    const beforeProc = procSnapshot();
    const beforeServer = await stats();
    const beforeClientParts = await snapshots();
    const beforeClient = totals(beforeClientParts);
    assertServerPlayers('sample start', beforeServer, target);
    assertClientPlayers('sample start', beforeClient, target);
    await wait(SAMPLE_MS);
    // Nest the client counter window inside the server counter window. This
    // makes received/sent delivery a conservative ratio instead of allowing
    // boundary packets to appear received before/after the measured sends.
    const afterClientParts = await snapshots();
    const afterClient = totals(afterClientParts);
    const afterServer = await stats();
    const afterProc = procSnapshot();
    if (!beforeProc || !afterProc) throw new Error('server process disappeared during the sample');
    assertServerPlayers('sample end', afterServer, target);
    assertClientPlayers('sample end', afterClient, target);
    if (afterClient.disconnected !== beforeClient.disconnected) {
      throw new Error('sample observed ' + (afterClient.disconnected - beforeClient.disconnected) + ' client disconnects');
    }
    const packets = afterClient.packets - beforeClient.packets;
    const procSeconds = (afterProc.at - beforeProc.at) / 1000;
    const cpuPct = (afterProc.cpuTicks - beforeProc.cpuTicks) / CLK_TCK / procSeconds * 100;
    const concurrentPlayers = afterServer.totalPlayers;
    let expectedPackets = 0;
    let receivedMessagesPerSec = 0;
    for (let i = 0; i < afterClientParts.length; i++) {
      const before = beforeClientParts[i];
      const after = afterClientParts[i];
      const duration = (after.sampledAtMs - before.sampledAtMs) / 1000;
      if (!Number.isFinite(duration) || duration <= 0) throw new Error('worker ' + i + ' returned an invalid sample duration');
      const workerPackets = after.counters.packets - before.counters.packets;
      if (workerPackets < 0) throw new Error('worker ' + i + ' packet counter moved backwards');
      const activeBefore = before.counters.active;
      const activeAfter = after.counters.active;
      const activeClients = (activeBefore + activeAfter) / 2;
      receivedMessagesPerSec += workerPackets / duration;
      expectedPackets += activeClients * TICK_HZ * duration;
    }
    const sentBytes = afterServer.networkBytesSent - beforeServer.networkBytesSent;
    const sentFrames = afterServer.websocketFramesSent - beforeServer.websocketFramesSent;
    const receivedBytes = afterServer.networkBytesReceived - beforeServer.networkBytesReceived;
    const binaryPackets = afterClient.binaryPackets - beforeClient.binaryPackets;
    const invalidPackets = afterClient.invalidPackets - beforeClient.invalidPackets;
    if (procSeconds <= 0) throw new Error('server process sample duration is not positive');
    if (sentBytes < 0 || sentFrames < 0 || receivedBytes < 0) throw new Error('server network counters moved backwards');
    if (packets <= 0 || sentFrames <= 0) throw new Error('sample contains no delivered snapshots or emitted WebSocket frames');
    if (packets > sentFrames) throw new Error('decoded snapshots exceed the surrounding server frame count');
    if (binaryPackets <= 0) throw new Error('sample contains no binary snapshots');
    if (invalidPackets !== 0) throw new Error('client decoder rejected ' + invalidPackets + ' binary snapshots');
    if (!afterClient.cadence.length || afterClient.cadence.some((value) => !Number.isFinite(value) || value <= 0)) {
      throw new Error('sample contains no valid cadence observations');
    }
    const phase = {
      requestedPlayers: target,
      joinedPlayers: joined.joined,
      concurrentPlayers,
      joinFailures: joined.failed,
      sampleDisconnects: afterClient.disconnected - beforeClient.disconnected,
      joinLatencyMs: { p50: round(percentile(joined.joinLatencyMs, 0.50)), p95: round(percentile(joined.joinLatencyMs, 0.95)), p99: round(percentile(joined.joinLatencyMs, 0.99)) },
      receivedMessagesPerSec: round(receivedMessagesPerSec),
      deliveryRatio: round(sentFrames ? packets / sentFrames : 0, 4),
      configuredTickRatio: round(expectedPackets ? packets / expectedPackets : 0, 4),
      averageWireBytes: round(sentFrames ? sentBytes / sentFrames : 0),
      clientTickCadenceMs: { p50: round(percentile(afterClient.cadence, 0.50), 3), p95: round(percentile(afterClient.cadence, 0.95), 3), p99: round(percentile(afterClient.cadence, 0.99), 3) },
      measurementValidity: {
        exactClientPlayers: true,
        exactServerPlayers: true,
        joinFailures: 0,
        sampleDisconnects: 0,
        rejectedBinarySnapshots: 0,
        cadenceObservers: afterClient.observedActive,
        cadenceSamples: afterClient.cadence.length,
      },
      server: {
        cpuPct: round(cpuPct), rssBytes: afterProc && afterProc.rssBytes, vmBytes: afterProc && afterProc.vmBytes,
        threads: afterProc && afterProc.threads, fds: afterProc && afterProc.fds,
        kernelTcpHostWide: afterProc && afterProc.kernelTcpHostWide,
        bytesSentPerSec: round(sentBytes / procSeconds),
        bytesReceivedPerSec: round(receivedBytes / procSeconds),
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
  closeClients();
})().catch((error) => {
  console.error(error.stack || error);
  closeClients();
  process.exitCode = 1;
});
