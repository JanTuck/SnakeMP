/* Launch an isolated release server for the accelerated universe audit. */
'use strict';

const childProcess = require('node:child_process');
const http = require('node:http');
const path = require('node:path');

const root = path.join(__dirname, '..');
const binary = path.join(root, 'servers', 'zig', 'snek-zig');
const port = Number(process.env.UNIVERSE_PORT || 4914);
const base = `http://127.0.0.1:${port}`;

function ready() {
  return new Promise(resolve => {
    const request = http.get(`${base}/debug/stats`, response => {
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
    if (server.exitCode !== null) throw new Error(`server exited before ready: ${server.exitCode}`);
    if (await ready()) return;
    await new Promise(resolve => setTimeout(resolve, 100));
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
      SNEK_MAX_PLAYERS: '100',
      SNEK_IO_MAX_PLAYERS_PER_LOBBY: '100',
      SNEK_LOBBY_IDLE_MS: process.env.SNEK_LOBBY_IDLE_MS || '60',
    },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  const stop = () => {
    if (server.exitCode === null && !server.killed) server.kill('SIGTERM');
  };
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, stop);

  try {
    await waitForServer(server);
    const test = childProcess.spawn(process.execPath, ['--expose-gc', path.join(__dirname, 'universe-memory-test.js')], {
      cwd: root,
      env: { ...process.env, UNIVERSE_BASE: base },
      stdio: 'inherit',
    });
    process.exitCode = await new Promise(resolve => test.once('exit', code => resolve(code ?? 1)));
  } finally {
    stop();
    await Promise.race([
      new Promise(resolve => server.once('exit', resolve)),
      new Promise(resolve => setTimeout(resolve, 3000)),
    ]);
    if (server.exitCode === null) server.kill('SIGKILL');
  }
})().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
