/**
 * Snek server — Bun port (zero npm dependencies).
 *
 * One Bun.serve instance handles:
 *   - the HTTP surface from docs/SPEC.md (pages, redirects, static assets,
 *     gated /debug/stats), and
 *   - socket.io v2 over engine.io v3 websocket transport on /socket.io/
 *     (Bun performs the WS handshake; engine.io v3 framing lives here).
 */

import { GameHost } from './game.ts';
import { loadAssets } from './assets.ts';
import { PING_INTERVAL, PING_TIMEOUT, DEFAULT_LOBBY_ID } from './config.ts';

const DEBUG = process.env.SNEK_DEBUG === '1';
const PORT = (() => {
  const n = Number.parseInt(process.env.PORT ?? '', 10);
  return Number.isFinite(n) && n > 0 ? n : 3000;
})();

// ---- embedded assets --------------------------------------------------------

const assets = loadAssets(import.meta.dir);

// ---- security headers -------------------------------------------------------

const SECURITY_HEADERS: Record<string, string> = {
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
};
// No x-powered-by anywhere.

function respond(body: BodyInit | null, status: number, extra?: Record<string, string>): Response {
  return new Response(body, { status, headers: { ...SECURITY_HEADERS, ...extra } });
}

function redirect(status: number, location: string): Response {
  return respond(null, status, { location });
}

function serveAsset(pathKey: string): Response | null {
  const asset = assets.get(pathKey);
  if (!asset) return null;
  return respond(asset.body as unknown as BodyInit, 200, { 'content-type': asset.type });
}

// ---- game host wiring ---------------------------------------------------------

/** sid -> ServerWebSocket for every live engine.io session. */
const sockets = new Map<string, any>();

let nextSidSeq = 0;
function newSid(): string {
  // >=20 chars, unique: monotonic counter + crypto randomness.
  const rand = Array.from(crypto.getRandomValues(new Uint8Array(12)),
    (b) => b.toString(36).padStart(2, '0')).join('');
  return ((++nextSidSeq).toString(36)) + rand;
}

const host = new GameHost(
  (sid, frame) => {
    const ws = sockets.get(sid);
    if (ws !== undefined) ws.send(frame);
  },
  (sids, frame) => {
    for (const sid of sids) {
      const ws = sockets.get(sid);
      if (ws !== undefined) ws.send(frame);
    }
  },
);

// ---- engine.io v3 / socket.io v2 framing -------------------------------------

function handleSocketIoPayload(ws: any, payload: string, sid: string): void {
  // payload is the socket.io packet WITHOUT the engine.io '4' prefix:
  //   0 = CONNECT (ignored), 1 = DISCONNECT, 2 = EVENT, 3+ = ack/error.
  const type = payload[0];
  if (type === '1') {                       // socket.io disconnect
    try { ws.close(); } catch { /* already gone */ }
    return;
  }
  if (type !== '2') return;                 // only EVENT frames matter here
  let arr: unknown;
  try {
    arr = JSON.parse(payload.slice(1));
  } catch {
    return;
  }
  if (!Array.isArray(arr) || typeof arr[0] !== 'string') return;
  const event = arr[0] as string;
  const args = arr.slice(1);
  if (event === 'clientReady') {
    host.clientReady(sid, args[0], args[1]);
  } else if (event === 'keyPress') {
    host.keyPress(sid, args[0]);
  }
  // Unknown events are ignored.
}

function handleEngineIoFrame(ws: any, frame: string, sid: string): void {
  switch (frame[0]) {
    case '2':                               // ping -> pong
      ws.send('3');
      break;
    case '3':                               // pong: liveness already reset
      break;
    case '1':                               // engine.io close
      try { ws.close(); } catch { /* already gone */ }
      break;
    case '4':                               // message -> socket.io layer
      handleSocketIoPayload(ws, frame.slice(1), sid);
      break;
    default:                                // 0 open / 5 upgrade / junk: ignore
      break;
  }
}

// Heartbeat: server-initiated ping every pingInterval; close when the previous
// ping went unanswered (i.e. silence has exceeded pingTimeout).
setInterval(() => {
  for (const ws of sockets.values()) {
    if (ws.data.awaitingPong) {
      try { ws.close(); } catch { /* already gone */ }
    } else {
      ws.data.awaitingPong = true;
      ws.send('2');
    }
  }
}, PING_INTERVAL);

// ---- HTTP -------------------------------------------------------------------

function handleHealthStats(): Response {
  return respond(JSON.stringify(host.statsPayload()), 200, { 'content-type': 'application/json' });
}

function parseForm(body: string): URLSearchParams {
  try {
    return new URLSearchParams(body);
  } catch {
    return new URLSearchParams();
  }
}

async function route(req: Request, server: any): Promise<Response | undefined> {
  const url = new URL(req.url);
  const path = url.pathname;

  // engine.io v3 websocket endpoint.
  if (path === '/socket.io/') {
    if (req.method === 'GET' &&
        url.searchParams.get('EIO') === '3' &&
        url.searchParams.get('transport') === 'websocket') {
      const sid = newSid();
      const upgraded = server.upgrade(req, { data: { sid, awaitingPong: false } });
      if (!upgraded) return respond('upgrade failed', 400);
      return undefined; // connection is now a websocket
    }
    return respond('unsupported socket.io transport', 400);
  }

  if (req.method === 'GET') {
    if (path === '/') return serveAsset('/index.html');
    if (path === '/game.html') return redirect(302, '/'); // lobby gate

    const gameMatch = /^\/game\/([^/]+)$/.exec(path);
    if (gameMatch) {
      let id: string;
      try {
        id = decodeURIComponent(gameMatch[1]);
      } catch {
        id = gameMatch[1];
      }
      return host.lobbies.has(id)
        ? serveAsset('/game.html')
        : redirect(302, '/');
    }

    if (path === '/debug/stats' && DEBUG) return handleHealthStats();

    const asset = serveAsset(path);
    if (asset !== null) return asset;

    return respond('Not Found', 404, { 'content-type': 'text/html; charset=utf-8' });
  }

  if (req.method === 'POST') {
    if (path === '/generateid') {
      const lobby = host.createLobby();
      // 303 so refreshing the landing page cannot re-submit the POST.
      return redirect(303, '/game/' + encodeURIComponent(lobby.id));
    }
    if (path === '/joingame') {
      const raw = await req.text().catch(() => '');
      const rawGameId = parseForm(raw).get('gameId');
      if (typeof rawGameId === 'string' && host.lobbies.has(rawGameId.trim())) {
        return redirect(303, '/game/' + encodeURIComponent(rawGameId.trim()));
      }
      return redirect(303, '/?error=unknown-game');
    }
  }

  return respond('Not Found', 404, { 'content-type': 'text/html; charset=utf-8' });
}

// ---- server -----------------------------------------------------------------

const server = Bun.serve({
  port: PORT,
  // Our own engine.io heartbeat governs liveness; never time out idle sockets.
  idleTimeout: 0,
  async fetch(req: Request, srv: any): Promise<Response | undefined> {
    return route(req, srv);
  },
  websocket: {
    open(ws: any): void {
      const sid: string = ws.data.sid;
      sockets.set(sid, ws);
      host.addConnection(sid);
      ws.send('0' + JSON.stringify({
        sid,
        upgrades: [],
        pingInterval: PING_INTERVAL,
        pingTimeout: PING_TIMEOUT,
      }));
      ws.send('40'); // socket.io CONNECT for namespace /
    },
    message(ws: any, msg: string | ArrayBuffer): void {
      // Any inbound traffic proves the client alive.
      ws.data.awaitingPong = false;
      if (typeof msg !== 'string') return; // binary frames unused by clients here
      handleEngineIoFrame(ws, msg, ws.data.sid as string);
    },
    close(ws: any): void {
      const sid: string = ws.data.sid;
      sockets.delete(sid);
      host.dropConnection(sid);
    },
  },
});

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
function shutdown(): void {
  host.stop();
  try { server.stop(true); } catch { /* ignore */ }
  process.exit(0);
}

console.log('listening on *:' + PORT + ' (default lobby ' + DEFAULT_LOBBY_ID + ')');
