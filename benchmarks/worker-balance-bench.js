'use strict';

// Deliberately puts full lobbies in the first-created worker's range and sparse
// lobbies elsewhere. The 1 Hz samples show whether migration converges without
// violating connection or player counts.
const fs = require('fs');
const http = require('http');
const path = require('path');
const io = require('./socket');

const BASE = process.env.BALANCE_BASE || 'http://127.0.0.1:4900';
const LOBBIES = Math.max(130, Number(process.env.BALANCE_LOBBIES || 160));
const HOT_LOBBIES = Math.min(LOBBIES, Number(process.env.BALANCE_HOT_LOBBIES || 32));
const HOT_PLAYERS = Math.max(2, Number(process.env.BALANCE_HOT_PLAYERS || 16));
const SAMPLE_MS = Math.max(4000, Number(process.env.BALANCE_SAMPLE_MS || 8000));
const sockets = [];

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function request(method, route) {
  return new Promise((resolve, reject) => {
    const req = http.request(BASE + route, { method }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

async function createLobby() {
  const response = await request('POST', '/generateid');
  if (response.status !== 303 || !response.headers.location) throw new Error('lobby creation failed');
  return decodeURIComponent(response.headers.location.split('/').pop());
}

async function createLobbies() {
  const result = [];
  while (result.length < LOBBIES) {
    const count = Math.min(32, LOBBIES - result.length);
    result.push(...await Promise.all(Array.from({ length: count }, createLobby)));
  }
  return result;
}

function join(job) {
  return new Promise((resolve, reject) => {
    const socket = io(BASE, { reconnection: false });
    sockets.push(socket);
    const timer = setTimeout(() => reject(new Error('join timeout')), 15000);
    socket.on('connect', () => socket.emit('clientReady', job.name, job.lobby));
    socket.on('init', () => { clearTimeout(timer); resolve(); });
    socket.on('game_error', (message) => { clearTimeout(timer); reject(new Error(String(message))); });
    socket.on('connect_error', (error) => { clearTimeout(timer); reject(error); });
  });
}

async function joinAll(jobs) {
  let cursor = 0;
  async function lane() {
    while (cursor < jobs.length) await join(jobs[cursor++]);
  }
  await Promise.all(Array.from({ length: Math.min(100, jobs.length) }, lane));
}

async function stats() {
  const response = await request('GET', '/debug/stats');
  if (response.status !== 200) throw new Error('/debug/stats requires SNEK_DEBUG=1');
  return JSON.parse(response.body);
}

function loadRatio(sample) {
  const loads = sample.workerLoads.map((worker) => worker.estimatedTickUs).filter((value) => value > 0);
  return loads.length < 2 ? 1 : Math.max(...loads) / Math.min(...loads);
}

(async () => {
  const lobbyIds = await createLobbies();
  const jobs = [];
  for (let lobbyIndex = 0; lobbyIndex < lobbyIds.length; lobbyIndex++) {
    const players = lobbyIndex < HOT_LOBBIES ? HOT_PLAYERS : 1;
    for (let player = 0; player < players; player++) {
      jobs.push({ lobby: lobbyIds[lobbyIndex], name: `balance-${lobbyIndex}-${player}` });
    }
  }

  const samples = [];
  let sampling = true;
  const sampler = (async () => {
    while (sampling) {
      try {
        const sample = await stats();
        samples.push({
          elapsedMs: Date.now(),
          totalPlayers: sample.totalPlayers,
          workers: sample.lobbyWorkers,
          migrations: sample.workerMigrations,
          loads: sample.workerLoads,
          ratio: loadRatio(sample),
        });
      } catch (_) {}
      await wait(200);
    }
  })();

  await joinAll(jobs);
  await wait(SAMPLE_MS);
  sampling = false;
  await sampler;
  const final = await stats();
  const finalRatio = loadRatio(final);
  const expectedPlayers = jobs.length;
  const passed = final.totalPlayers === expectedPlayers && final.workerMigrations > 0 && finalRatio <= 1.25;
  const output = {
    schemaVersion: 1,
    workload: { lobbies: LOBBIES, hotLobbies: HOT_LOBBIES, hotPlayers: HOT_PLAYERS, sparsePlayers: 1, expectedPlayers },
    passed,
    finalRatio,
    final: {
      totalPlayers: final.totalPlayers,
      workers: final.lobbyWorkers,
      migrations: final.workerMigrations,
      loads: final.workerLoads,
    },
    samples,
  };
  fs.mkdirSync(path.join(__dirname, '..', '.scratch'), { recursive: true });
  fs.writeFileSync(path.join(__dirname, '..', '.scratch', 'worker-balance-zig.json'), JSON.stringify(output, null, 2));
  console.log(JSON.stringify(output.final, null, 2));
  console.log(`worker balancing: ${passed ? 'PASS' : 'FAIL'} (final load ratio ${finalRatio.toFixed(3)})`);
  if (!passed) process.exitCode = 1;
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
}).finally(() => {
  for (const socket of sockets) socket.close();
});
