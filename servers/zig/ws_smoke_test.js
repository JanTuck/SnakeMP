
// Smoke test: 3 bots join lobby '12345' over websocket-only socket.io v2,
// steer around, and we verify all three appear together in gameTick payloads.
const io = require('socket.io-client');
try { delete globalThis.WebSocket; } catch (e) {}

const BASE = process.env.SMOKE_BASE || 'http://127.0.0.1:4213';
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const bots = [];
  for (let i = 0; i < 3; i++) {
    const bot = await new Promise((resolve, reject) => {
      const s = io(BASE, { transports: ['websocket'], forceNew: true });
      const w = { ticks: 0, lastWorld: null, allThreeSeenAt: -1 };
      s.on('gameTick', (world) => {
        w.ticks += 1;
        w.lastWorld = world;
        if (w.allThreeSeenAt < 0 && world.players && world.players.length >= 3) {
          const names = world.players.map((p) => p.displayName).sort();
          if (JSON.stringify(names) === JSON.stringify(['bot-0', 'bot-1', 'bot-2'])) w.allThreeSeenAt = w.ticks;
        }
      });
      s.on('connect', () => resolve({ s, w }));
      s.on('connect_error', (e) => { s.close(); reject(new Error('connect_error: ' + e)); });
      setTimeout(() => reject(new Error('connect timeout bot-' + i)), 8000);
    }).catch((e) => { console.log('BOT ' + i + ' FAILED: ' + e.message); return null; });
    if (!bot) process.exit(1);
    bots.push(bot);
  }

  // Join all three.
  bots.forEach((b, i) => b.s.emit('clientReady', 'bot-' + i, '12345'));
  await wait(700);

  // Send some keyPress turns (chained turns exercise the queue).
  bots[0].s.emit('keyPress', 'ArrowUp');
  bots[0].s.emit('keyPress', 'ArrowLeft');
  bots[1].s.emit('keyPress', 'ArrowDown');
  setTimeout(() => bots[1].s.emit('keyPress', 'ArrowRight'), 250);
  bots[2].s.emit('keyPress', 'ArrowUp');
  await wait(900);

  const last = bots[0].w.lastWorld;
  if (!last || !last.players) { console.log('SMOKE: FAIL (no gameTick observed)'); process.exit(1); }
  const names = last.players.map((p) => p.displayName).sort();
  const idsOk = last.players.every((p) => typeof p.id === 'string' && p.snake.length >= 1 && typeof p.score === 'number');
  console.log('players in final tick:', JSON.stringify(names));
  console.log('ticks received per bot:', bots.map((b) => b.w.ticks).join(','));
  console.log('all-three-seen tick index:', bots.map((b) => b.w.allThreeSeenAt).join(','));
  const okAllSeen = bots.every((b) => b.w.allThreeSeenAt > 0);
  const okShape = idsOk && Array.isArray(last.bonus) && Array.isArray(last.drops) && 'golden' in last;
  console.log(okAllSeen && okShape ? 'SMOKE: PASS' : 'SMOKE: FAIL');
  bots.forEach((b) => b.s.close());
  process.exit(okAllSeen && okShape ? 0 : 1);
})().catch((e) => { console.log('SMOKE CRASH:', e.message); process.exit(2); });
