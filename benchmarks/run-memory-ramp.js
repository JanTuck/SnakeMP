/* Launch an isolated Zig server for the accelerated memory-ramp test. */
'use strict';

const childProcess = require('child_process');
const http = require('http');
const path = require('path');

const root = path.join(__dirname, '..');
const binary = path.join(root, 'servers', 'zig', 'snek-zig');
const port = Number(process.env.MEMORY_PORT || 4902);
const players = Number(process.env.MEMORY_PLAYERS || 1000);
const base = 'http://127.0.0.1:' + port;

function ready() {
  return new Promise((resolve) => {
    const request = http.get(base + '/debug/stats', (response) => {
      response.resume();
      response.on('end', () => resolve(response.statusCode === 200));
    });
    request.setTimeout(500, () => request.destroy());
    request.on('error', () => resolve(false));
  });
}

async function waitForServer(server) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (server.exitCode !== null) throw new Error('server exited before becoming ready: ' + server.exitCode);
    if (await ready()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('server did not become ready within 15 seconds');
}

(async () => {
  const server = childProcess.spawn(binary, [], {
    cwd: root,
    env: {
      ...process.env,
      PORT: String(port),
      SNEK_DEBUG: '1',
      SNEK_MAX_PLAYERS: String(Math.max(players + 32, Number(process.env.SNEK_MAX_PLAYERS || 0))),
      SNEK_MAX_PLAYERS_PER_LOBBY: process.env.MEMORY_PLAYERS_PER_LOBBY || '16',
      SNEK_LOBBY_IDLE_MS: process.env.SNEK_LOBBY_IDLE_MS || '60',
    },
    stdio: ['ignore', 'inherit', 'inherit'],
  });

  let interrupted = false;
  const stop = () => {
    if (server.exitCode === null && !server.killed) server.kill('SIGTERM');
  };
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.once(signal, () => {
      interrupted = true;
      stop();
    });
  }

  try {
    await waitForServer(server);
    const test = childProcess.spawn(process.execPath, [path.join(__dirname, 'memory-ramp.js')], {
      cwd: root,
      env: { ...process.env, MEMORY_BASE: base },
      stdio: 'inherit',
    });
    const code = await new Promise((resolve) => test.once('exit', (exitCode) => resolve(exitCode ?? 1)));
    process.exitCode = interrupted ? 130 : code;
  } finally {
    stop();
    await Promise.race([
      new Promise((resolve) => server.once('exit', resolve)),
      new Promise((resolve) => setTimeout(resolve, 3000)),
    ]);
    if (server.exitCode === null) server.kill('SIGKILL');
  }
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
