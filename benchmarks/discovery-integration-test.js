'use strict';

const assert = require('assert');
const { spawn } = require('child_process');
const http = require('http');
const net = require('net');
const path = require('path');
const WebSocket = require('ws');

const root = path.resolve(__dirname, '..');
const binary = path.join(root, 'servers/zig/snek-zig');

function reservePort() {
  return new Promise((resolve, reject) => {
    const listener = net.createServer();
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', () => {
      const port = listener.address().port;
      listener.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function request(base, method, route, body = '') {
  return new Promise((resolve, reject) => {
    const payload = Buffer.from(body);
    const req = http.request(base + route, {
      method,
      headers: payload.length === 0 ? {} : {
        'content-type': 'application/x-www-form-urlencoded',
        'content-length': String(payload.length),
      },
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        location: response.headers.location || '',
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.once('error', reject);
    req.end(payload);
  });
}

async function waitUntilReady(base, child) {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`server exited during startup (${child.exitCode})`);
    try {
      if ((await request(base, 'GET', '/')).status === 200) return;
    } catch (_) { /* startup race */ }
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
  throw new Error('server did not become ready');
}

function generatedLobby(response) {
  assert.strictEqual(response.status, 303, `expected lobby redirect, got ${response.status}: ${response.body}`);
  assert.match(response.location, /^\/game\/[^/?#]+$/, `unexpected lobby redirect: ${response.location}`);
  return response.location;
}

function lobbyId(route) {
  return decodeURIComponent(route.slice('/game/'.length));
}

function joinPacket(lobby, username, password = '') {
  const lobbyBytes = Buffer.from(lobby);
  const usernameBytes = Buffer.from(username);
  const passwordBytes = Buffer.from(password);
  return Buffer.concat([
    Buffer.from([1, lobbyBytes.length, usernameBytes.length, passwordBytes.length]),
    lobbyBytes,
    usernameBytes,
    passwordBytes,
  ]);
}

function connectPlayer(base, lobby, username, password = '') {
  return new Promise((resolve, reject) => {
    const wsUrl = new URL('/ws', base);
    wsUrl.protocol = 'ws:';
    const socket = new WebSocket(wsUrl, { perMessageDeflate: false });
    const timeout = setTimeout(() => finish(new Error(`join timed out for ${username}`)), 5000);
    let settled = false;

    function finish(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (error) {
        socket.terminate();
        reject(error);
      } else {
        resolve(socket);
      }
    }

    socket.once('open', () => socket.send(joinPacket(lobby, username, password)));
    socket.on('message', (data, isBinary) => {
      if (isBinary) return;
      try {
        const packet = JSON.parse(data.toString());
        if (packet[0] === 'init') finish();
        if (packet[0] === 'game_error') finish(new Error(String(packet[1] || 'join rejected')));
      } catch (_) { /* unrelated text frame */ }
    });
    socket.once('error', (error) => finish(error));
    socket.once('close', () => {
      if (!settled) finish(new Error(`socket closed before ${username} joined`));
    });
  });
}

(async () => {
  const port = await reservePort();
  const base = `http://127.0.0.1:${port}`;
  let stderr = '';
  const players = [];
  const server = spawn(binary, [], {
    cwd: root,
    env: { ...process.env, PORT: String(port), SNEK_DEBUG: '1', SNEK_MAX_PLAYERS_PER_LOBBY: '2' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  server.stderr.on('data', (chunk) => { stderr += chunk; });

  try {
    await waitUntilReady(base, server);

    const landing = await request(base, 'GET', '/');
    assert.strictEqual(landing.status, 200);
    assert.strictEqual(landing.headers['cache-control'], 'no-store', 'landing HTML must never pin an old asset graph');
    assert.match(landing.body, /\/css\/index\.css\?v=[0-9a-f]{16}/, 'landing CSS URL must carry the content release fingerprint');
    assert.match(landing.body, /\/js\/status\.js\?v=[0-9a-f]{16}/, 'landing script URL must carry the content release fingerprint');

    const landingCss = await request(base, 'GET', '/css/index.css?v=release-check');
    assert.strictEqual(landingCss.status, 200);
    assert.strictEqual(landingCss.headers['cache-control'], 'no-cache, must-revalidate', 'static assets must revalidate before reuse');

    const gamePage = await request(base, 'GET', '/game/12345');
    assert.strictEqual(gamePage.status, 200);
    assert.strictEqual(gamePage.headers['cache-control'], 'no-store', 'game HTML must never pin an old asset graph');
    assert.match(gamePage.body, /\/css\/game\.css\?v=[0-9a-f]{16}/, 'game CSS URL must carry the content release fingerprint');
    assert.match(gamePage.body, /\/js\/rendering\.js\?v=[0-9a-f]{16}/, 'game module URL must carry the content release fingerprint');

    const indexAsset = await request(base, 'GET', '/index.html');
    assert.strictEqual(indexAsset.status, 200);
    assert.strictEqual(indexAsset.headers['cache-control'], 'no-store', 'direct HTML assets must not be cached');

    for (const publicTarget of ['1', '17', 'many', '-1']) {
      const invalid = await request(base, 'POST', '/generateid', `mode=arcade-v2&publicTarget=${encodeURIComponent(publicTarget)}`);
      assert.strictEqual(invalid.status, 400, `invalid publicTarget=${publicTarget} must be rejected`);
    }
    for (const capacity of ['2', '24', '64', 'many']) {
      const invalid = await request(base, 'POST', '/generateid', `mode=arcade-v2&publicTarget=0&capacity=${encodeURIComponent(capacity)}`);
      assert.strictEqual(invalid.status, 400, `invalid capacity=${capacity} must be rejected`);
    }
    const largeProtected = await request(base, 'POST', '/generateid', 'mode=arcade-v2&publicTarget=17&capacity=32&password=secret');
    assert.strictEqual(largeProtected.status, 303, '32-player lobbies must accept targets above the 16-player default');

    // HTTP redirects never reserve phantom seats. A burst with no WebSocket
    // joins must keep returning the same eligible default lobby.
    for (let requestIndex = 0; requestIndex < 20; requestIndex++) {
      const quick = await request(base, 'POST', '/quickjoin');
      assert.strictEqual(quick.status, 303, `default Quick Join ${requestIndex + 1} must redirect`);
      assert.strictEqual(quick.location, '/game/12345', 'default Quick Join route changed unexpectedly');
    }
    players.push(await connectPlayer(base, '12345', 'DefaultOne'));
    players.push(await connectPlayer(base, '12345', 'DefaultTwo'));

    const unlisted = generatedLobby(await request(base, 'POST', '/generateid', 'mode=arcade-v2&publicTarget=0'));
    const protectedLobby = generatedLobby(await request(base, 'POST', '/generateid', 'mode=arcade-v2&password=secret'));
    const listed = generatedLobby(await request(base, 'POST', '/generateid', 'mode=arcade-v2'));
    assert.notStrictEqual(listed, unlisted);
    assert.notStrictEqual(listed, protectedLobby);

    // The protected and unlisted rooms are excluded; the listed room remains
    // eligible across repeated unauthenticated redirects until a real player
    // joins it.
    for (let requestIndex = 0; requestIndex < 20; requestIndex++) {
      const quick = await request(base, 'POST', '/quickjoin');
      assert.strictEqual(quick.status, 303, `listed Quick Join ${requestIndex + 1} must redirect`);
      assert.strictEqual(quick.location, listed, 'Quick Join must choose the passwordless listed lobby');
    }
    players.push(await connectPlayer(base, lobbyId(listed), 'ListedOne'));
    const oneSeat = await request(base, 'POST', '/quickjoin');
    assert.strictEqual(oneSeat.status, 303);
    assert.strictEqual(oneSeat.location, listed, 'one active player must leave the target-2 lobby discoverable');
    players.push(await connectPlayer(base, lobbyId(listed), 'ListedTwo'));

    const full = await request(base, 'POST', '/quickjoin');
    assert.strictEqual(full.status, 303);
    assert.strictEqual(full.location, '/?error=no-open-lobby', 'unlisted and passworded lobbies must stay out of Quick Join');

    const shareAsset = await request(base, 'GET', '/js/share.js');
    assert.strictEqual(shareAsset.status, 200, 'share helper must be embedded in the Zig executable');
    assert.match(shareAsset.body, /navigator\.share/, 'share helper must use native sharing when available');

    console.log('discovery integration test passed (active-player targets, no phantom claims, protected/unlisted exclusion, and share route)');
  } catch (error) {
    if (stderr) error.message += `\nserver stderr:\n${stderr}`;
    throw error;
  } finally {
    for (const player of players) player.terminate();
    server.kill('SIGTERM');
    await Promise.race([
      new Promise((resolve) => server.once('exit', resolve)),
      new Promise((resolve) => setTimeout(resolve, 1500)),
    ]);
    if (server.exitCode === null) server.kill('SIGKILL');
  }
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
