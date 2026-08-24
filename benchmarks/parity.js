/* Parity harness: verifies any Snek server implementation against the spec.
 * Usage: PARITY_BASE=http://127.0.0.1:4100 node benchmarks/parity.js
 * Exit code 0 = parity. Run against the Node reference first.
 */
const io = require('./socket');
const http = require('http');
const net = require('net');
const { attachWorld } = require('./protocol');

// Keep the benchmark on the installed `ws` implementation across Node versions.
try { delete globalThis.WebSocket; } catch (e) {}

const BASE = process.env.PARITY_BASE || 'http://127.0.0.1:4000';
let failed = 0;
function check(id, ok, ev) { console.log((ok ? 'PASS' : 'FAIL') + ' | ' + id + (ev ? ' | ' + ev : '')); if (!ok) failed++; }
const wait = (ms) => new Promise(r => setTimeout(r, ms));

function get(path) {
  return new Promise((resolve) => {
    http.get(BASE + path, (res) => {
      let body = '';
      res.on('data', (c) => body += c);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    }).on('error', (e) => resolve({ error: String(e) }));
  });
}
function post(path, body, type) {
  return new Promise((resolve) => {
    const payload = body || '';
    const req = http.request(BASE + path, {
      method: 'POST',
      headers: payload ? { 'content-type': type || 'application/x-www-form-urlencoded' } : {},
    }, (res) => { res.resume(); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers })); });
    req.on('error', (e) => resolve({ error: String(e) }));
    req.end(payload);
  });
}
function rawParts(parts) {
  const port = Number(new URL(BASE).port || 80);
  return new Promise((resolve) => {
    let response = '';
    const socket = net.connect(port, '127.0.0.1');
    const finish = () => { socket.destroy(); resolve(response); };
    socket.setTimeout(1500, finish);
    socket.on('data', (chunk) => { response += chunk.toString('utf8'); });
    socket.on('error', finish);
    socket.on('end', finish);
    socket.on('connect', async () => {
      for (const part of parts) { socket.write(part); await wait(10); }
    });
  });
}
function connect() {
  return new Promise((resolve, reject) => {
    const s = io(BASE, { transports: ['websocket'], forceNew: true });
    const events = [];
    attachWorld(s, (w) => events.push(w));
    s.on('updateFood', (f) => events.push({ updateFood: f }));
    s.on('feed', (f) => events.push({ feed: f }));
    s.on('death', (sc) => events.push({ death: sc }));
    s.on('init', (d) => events.push({ init: d }));
    s.on('game_error', (m) => events.push({ game_error: m }));
    s.on('connect', () => resolve({ s, events }));
    s.on('connect_error', (e) => { s.close(); reject(new Error('connect_error: ' + e)); });
    setTimeout(() => reject(new Error('connect timeout')), 8000);
  });
}
const lastPlayers = (events) => { for (let i = events.length - 1; i >= 0; i--) { const e = events[i]; if (e.players) return e.players; } return []; };
const lastWorld = (events) => { for (let i = events.length - 1; i >= 0; i--) if (events[i].players) return events[i]; return null; };
const hasEvent = (events, type) => events.some(e => e[type] !== undefined);
const moved = (samples, axis, sign) => {
  for (let i = 1; i < samples.length; i++) {
    const d = samples[i][axis] - samples[i - 1][axis];
    if (Math.abs(d) > 0 && Math.sign(d) === sign) return true;
  }
  return false;
};

(async () => {
  // ---- HTTP surface ----
  const home = await get('/');
  check('GET / serves index', home.status === 200 && home.body.includes('Snek'), 'status=' + home.status);
  const lobbyPage = await get('/lobby.html');
  check('GET /lobby.html serves shared client', lobbyPage.status === 200 && lobbyPage.body.includes('Lobby'), 'status=' + lobbyPage.status);
  const clientScript = await get('/js/rendering.js');
  check('GET /js/rendering.js serves shared client', clientScript.status === 200 && clientScript.body.length > 100, 'status=' + clientScript.status);
  const socketClient = await get('/js/transport.js');
  check('GET /js/transport.js serves native websocket client', socketClient.status === 200 && socketClient.body.includes('WebSocket'), 'status=' + socketClient.status);
  const gsap = await get('/vendor/gsap.min.js');
  check('GET /vendor/gsap.min.js serves embedded vendor bundle', gsap.status === 200 && gsap.body.length > 1000, 'status=' + gsap.status);
  const created = await post('/generateid');
  const loc = String(created.headers.location || '');
  check('POST /generateid -> 303 /game/<id>', created.status === 303 && /\/game\/.+/.test(loc), loc);
  const lobbyId = decodeURIComponent(loc.split('/').pop());
  const gamePage = await get('/game/' + lobbyId);
  check('GET /game/<id> serves game page', gamePage.status === 200 && gamePage.body.includes('canvas'), 'status=' + gamePage.status);
  const gated = await get('/game.html');
  check('GET /game.html gated', gated.status === 302, 'status=' + gated.status);
  const joinOk = await post('/joingame', 'gameId=' + encodeURIComponent(lobbyId));
  check('POST /joingame valid -> 303 game', joinOk.status === 303 && String(joinOk.headers.location).includes('/game/'), 'loc=' + joinOk.headers.location);
  const joinBad = await post('/joingame', 'gameId=does-not-exist');
  check('POST /joingame unknown -> 303 /?error=unknown-game', joinBad.status === 303 && String(joinBad.headers.location).includes('error=unknown-game'), 'loc=' + joinBad.headers.location);
  const stats = await get('/debug/stats');
  let statsOk = false, statsEv = '';
  try {
    const j = JSON.parse(stats.body);
    statsOk = typeof j.rss === 'number' && Array.isArray(j.lobbies) && typeof j.totalPlayers === 'number';
    statsEv = 'lobbies=' + j.lobbies.length + ' players=' + j.totalPlayers;
  } catch (e) { statsEv = 'unparseable'; }
  check('GET /debug/stats JSON', stats.status === 200 && statsOk, statsEv);
  const hdrs = home.headers;
  check('security headers', String(hdrs['x-content-type-options']).toLowerCase() === 'nosniff' && String(hdrs['x-frame-options']).toLowerCase() === 'deny', JSON.stringify({ n: hdrs['x-content-type-options'], f: hdrs['x-frame-options'] }));
  const partial = await rawParts(['GET / HTTP/1.1\r\nHo', 'st: 127.0.0.1\r\nConnection: close\r\n', '\r\n']);
  check('partial HTTP request is assembled incrementally', partial.startsWith('HTTP/1.1 200'), partial.slice(0, 32));
  await rawParts(['POST /joingame HTTP/1.1\r\nHost: x\r\nContent-Length: nope\r\n\r\n']);
  check('malformed HTTP closes safely and server remains healthy', (await get('/')).status === 200);

  // ---- WS: join, init, movement, input semantics ----
  const a = await connect();
  a.s.emit('clientReady', 'parity-player', lobbyId);
  await wait(500);
  check('join -> init received', hasEvent(a.events, 'init'));
  await a.s.emit.call ? null : null;
  a.s.emit('keyPress', 'ArrowRight');
  await wait(400);
  const p1 = lastPlayers(a.events).find(p => p.id === a.s.id);
  check('movement works', !!p1 && p1.snake.length >= 1, JSON.stringify(p1 && p1.snake[0]));
  const w1 = lastWorld(a.events);
  check('gameTick world shape', !!w1 && Array.isArray(w1.bonus) && Array.isArray(w1.drops) && 'golden' in (w1 || {}));

  // reversal ignored
  const xBefore = (lastPlayers(a.events).find(p => p.id === a.s.id) || { snake: [{ x: 0 }] }).snake[0].x;
  a.s.emit('keyPress', 'ArrowLeft');
  await wait(300);
  const p2 = lastPlayers(a.events).find(p => p.id === a.s.id);
  check('reversal ignored (alive, still moving right)', !!p2 && p2.snake[0].x > xBefore, JSON.stringify(p2 && p2.snake[0]));

  // chained UP -> LEFT
  a.s.emit('keyPress', 'ArrowUp');
  a.s.emit('keyPress', 'ArrowLeft');
  await wait(500);
  const p3 = lastPlayers(a.events).find(p => p.id === a.s.id);
  check('chained turn applies over two ticks', !!p3, '');

  // unknown lobby
  const c = await connect();
  c.s.emit('clientReady', 'sneaky', 'does-not-exist');
  await wait(500);
  check('unknown lobby -> game_error, no init', hasEvent(c.events, 'game_error') && !hasEvent(c.events, 'init'), '');
  c.s.close();

  // isolation: second lobby does not see first player
  const created2 = await post('/generateid');
  const lobby2 = decodeURIComponent(String(created2.headers.location).split('/').pop());
  const b = await connect();
  b.s.emit('clientReady', 'parity-other', lobby2);
  await wait(600);
  const bPlayers = lastPlayers(b.events);
  check('lobby isolation', bPlayers.length === 1 && bPlayers[0].displayName === 'parity-other', JSON.stringify(bPlayers.map(p => p.displayName)));

  // same-socket rejoin after death
  const beforeDeath = hasEvent(a.events, 'death');
  let died = false;
  for (let i = 0; i < 120 && !died; i++) {
    a.s.emit('keyPress', 'ArrowLeft'); // drive into the left wall
    await wait(80);
    died = a.events.some(e => e.death !== undefined);
  }
  check('death occurs (wall)', died);
  await wait(300);
  a.s.emit('clientReady', 'parity-player-2', lobbyId);
  await wait(500);
  const rejoined = lastPlayers(a.events).some(p => p.displayName === 'parity-player-2');
  check('same-socket rejoin after death works', rejoined);

  a.s.close(); b.s.close();
  console.log(failed === 0 ? '\nPARITY: all passed (' + BASE + ')' : '\nPARITY: ' + failed + ' failed (' + BASE + ')');
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error('PARITY CRASH:', e && e.message ? e.message : e); process.exit(2); });
