/* Isolated regression audit for lobby caps and lazy game-worker ownership. */
'use strict';

const childProcess = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');
const io = require('./socket');

try { delete globalThis.WebSocket; } catch (_) {}

const root = path.join(__dirname, '..');
const binary = path.join(root, 'servers', 'zig', 'snek-zig');
const port = Number(process.env.LOBBY_AUDIT_PORT || 4914);
const maxLobbies = Number(process.env.LOBBY_AUDIT_MAX || 65);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('LOBBY_AUDIT_PORT must be an integer from 1 to 65535');
if (!Number.isInteger(maxLobbies) || maxLobbies < 4 || maxLobbies > 100000) throw new Error('LOBBY_AUDIT_MAX must be an integer from 4 to 100000');
const attempts = maxLobbies + 15;
const base = 'http://127.0.0.1:' + port;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function request(method, route) {
  return new Promise((resolve) => {
    const req = http.request(base + route, { method }, (response) => {
      let body = '';
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => resolve({
        status: response.statusCode,
        location: response.headers.location,
        body,
      }));
    });
    req.setTimeout(3000, () => req.destroy(new Error('request timeout')));
    req.on('error', (error) => resolve({ status: 0, error: String(error) }));
    req.end();
  });
}

async function stats() {
  const response = await request('GET', '/debug/stats');
  if (response.status !== 200) throw new Error('stats request failed: HTTP ' + response.status);
  return JSON.parse(response.body);
}

async function waitFor(predicate, description, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let sample;
  while (Date.now() < deadline) {
    try {
      sample = await stats();
      if (predicate(sample)) return sample;
    } catch (_) {}
    await wait(50);
  }
  throw new Error('timed out waiting for ' + description + '; last=' + JSON.stringify(sample));
}

function processThreads(pid) {
  const status = fs.readFileSync('/proc/' + pid + '/status', 'utf8');
  const match = /^Threads:\s+(\d+)$/m.exec(status);
  if (!match) throw new Error('missing Threads in /proc status');
  return Number(match[1]);
}

function lobbyId(response) {
  if (response.status !== 303 || !response.location) return null;
  return decodeURIComponent(String(response.location).split('/').pop());
}

function connectAndJoin(id, name, expected, expectedDetail) {
  return new Promise((resolve, reject) => {
    const socket = io(base, { transports: ['websocket'], forceNew: true, reconnection: false });
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.close();
      reject(new Error('join timed out: ' + name));
    }, 5000);
    const finish = (outcome, detail) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (outcome !== expected || (expectedDetail !== undefined && detail !== expectedDetail)) {
        socket.close();
        reject(new Error(name + ' expected ' + expected + ' ' + JSON.stringify(expectedDetail) +
          ', received ' + outcome + ' ' + JSON.stringify(detail)));
        return;
      }
      resolve(socket);
    };
    socket.on('connect', () => socket.emit('clientReady', name, id));
    socket.once('init', () => finish('init'));
    socket.once('game_error', (message) => finish('game_error', String(message)));
    socket.once('connect_error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
  });
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

(async () => {
  const server = childProcess.spawn(binary, [], {
    cwd: root,
    env: {
      ...process.env,
      PORT: String(port),
      SNEK_DEBUG: '1',
      SNEK_MAX_PLAYERS: '2',
      SNEK_MAX_LOBBIES: String(maxLobbies),
      SNEK_LOBBIES_PER_WORKER: '8',
      SNEK_LOBBY_IDLE_MS: '10000',
    },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  const sockets = [];
  const stop = () => {
    for (const socket of sockets) socket.close();
    if (server.exitCode === null && !server.killed) server.kill('SIGTERM');
  };
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, stop);

  try {
    const initial = await waitFor(() => true, 'server readiness', 15000);
    assert(initial.maxLobbies === maxLobbies, 'maxLobbies is not exposed correctly');
    assert(initial.lobbies.length === 1, 'expected only the permanent lobby at startup');
    assert(initial.lobbyWorkers === 0 && initial.workerLoads.length === 0, 'empty startup created game workers');
    const initialThreads = processThreads(server.pid);
    assert(initialThreads === 1, 'empty startup used more than the reactor thread');

    const responses = [];
    let cursor = 0;
    async function lane() {
      while (cursor < attempts) {
        cursor += 1;
        responses.push(await request('POST', '/generateid'));
      }
    }
    await Promise.all(Array.from({ length: 16 }, lane));
    const created = responses.filter((response) => response.status === 303);
    const rejected = responses.filter((response) => response.status === 503);
    assert(created.length === maxLobbies - 1, 'unexpected successful lobby count: ' + created.length);
    assert(rejected.length === attempts - created.length, 'unexpected 503 count: ' + rejected.length);
    assert(responses.every((response) => response.status === 303 || response.status === 503), 'unexpected lobby response status');

    const filled = await stats();
    assert(filled.lobbies.length === maxLobbies, 'lobby cap did not remain exact');
    assert(filled.lobbyWorkers === 0 && filled.workerLoads.length === 0, 'empty generated lobbies acquired workers');
    const emptyThreads = processThreads(server.pid);
    assert(emptyThreads === 1, 'empty lobby flood acquired OS threads');

    const firstId = lobbyId(created[0]);
    const secondId = lobbyId(created[1]);
    const thirdId = lobbyId(created[2]);
    const first = await connectAndJoin(firstId, 'audit-first', 'init');
    sockets.push(first);
    const active = await waitFor((sample) => sample.totalPlayers === 1 && sample.lobbyWorkers === 1, 'first worker activation');
    assert(active.workerLoads.reduce((sum, worker) => sum + worker.lobbies, 0) === 1, 'worker owns empty lobbies');
    const activeThreads = processThreads(server.pid);
    assert(activeThreads === 2, 'first active lobby did not add exactly one game thread');

    const second = await connectAndJoin(secondId, 'audit-second', 'init');
    sockets.push(second);
    const shared = await waitFor((sample) => sample.totalPlayers === 2 && sample.lobbyWorkers === 1 &&
      sample.workerLoads.reduce((sum, worker) => sum + worker.lobbies, 0) === 2, 'shared-worker activation');

    const rejectedJoin = await connectAndJoin(thirdId, 'audit-over-cap', 'game_error', 'Server is full, try again later');
    sockets.push(rejectedJoin);
    const afterRejectedJoin = await stats();
    assert(afterRejectedJoin.totalPlayers === 2, 'global player cap changed after rejected join');
    assert(afterRejectedJoin.workerLoads.reduce((sum, worker) => sum + worker.lobbies, 0) === 2, 'rejected join assigned an empty lobby');
    rejectedJoin.close();

    first.close();
    const partial = await waitFor((sample) => sample.totalPlayers === 1 && sample.lobbyWorkers === 1 &&
      sample.workerLoads.reduce((sum, worker) => sum + worker.lobbies, 0) === 1, 'partial shared-worker deactivation');
    assert(partial.lobbies.length === maxLobbies, 'lobby was reaped before its configured TTL');
    assert(processThreads(server.pid) === 2, 'partial deactivation retired a nonempty shared worker');

    const reactivated = await connectAndJoin(firstId, 'audit-rejoin', 'init');
    sockets.push(reactivated);
    await waitFor((sample) => sample.totalPlayers === 2 && sample.lobbyWorkers === 1 &&
      sample.workerLoads.reduce((sum, worker) => sum + worker.lobbies, 0) === 2, 'worker reactivation');
    reactivated.close();
    second.close();
    const inactive = await waitFor((sample) => sample.totalPlayers === 0 && sample.lobbyWorkers === 0, 'empty worker deactivation');
    const inactiveThreads = processThreads(server.pid);
    assert(inactiveThreads === 1, 'empty used lobby retained a game thread');

    const reaped = await waitFor((sample) => sample.totalPlayers === 0 && sample.lobbies.length === 1 && sample.lobbyWorkers === 0,
      'idle lobby reaping', 20000);
    const replacement = await request('POST', '/generateid');
    assert(replacement.status === 303, 'reaping did not restore lobby creation capacity');

    console.log(JSON.stringify({
      schemaVersion: 1,
      passed: true,
      maxLobbies,
      creationAttempts: attempts,
      created: created.length,
      rejected: rejected.length,
      emptyLobbyWorkers: filled.lobbyWorkers,
      emptyProcessThreads: emptyThreads,
      activeLobbyWorkers: active.lobbyWorkers,
      activeProcessThreads: activeThreads,
      sharedWorkerLobbies: shared.workerLoads.reduce((sum, worker) => sum + worker.lobbies, 0),
      partiallyActiveWorkerLobbies: partial.workerLoads.reduce((sum, worker) => sum + worker.lobbies, 0),
      inactiveProcessThreads: inactiveThreads,
      rejectedJoinAssignedLobbies: afterRejectedJoin.workerLoads.reduce((sum, worker) => sum + worker.lobbies, 0),
      reapedLobbies: maxLobbies - reaped.lobbies.length,
      capacityRecovered: true,
    }, null, 2));
  } finally {
    for (const signal of ['SIGINT', 'SIGTERM']) process.removeListener(signal, stop);
    stop();
    await Promise.race([
      new Promise((resolve) => server.once('exit', resolve)),
      wait(3000),
    ]);
    if (server.exitCode === null) server.kill('SIGKILL');
  }
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
