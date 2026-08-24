/* Compare practical JSON layouts using a deterministic, representative lobby.
 * This is intentionally independent of any server implementation.
 */
'use strict';

const ITERATIONS = Math.max(10_000, Number(process.env.WIRE_ITERATIONS || 100_000));
const players = Array.from({ length: 16 }, (_, p) => ({
  id: `AbCdEfGhIjKlMnOpQrSt${String(p).padStart(2, '0')}`,
  displayName: `player-${String(p).padStart(2, '0')}`,
  color: `#${((p + 1) * 0x0f1e2d & 0xffffff).toString(16).padStart(6, '0')}`,
  snake: Array.from({ length: 18 }, (_, s) => ({ x: (20 + p + s) * 16, y: (10 + p) * 16 })),
  score: 37 + p,
  bodyLength: 18,
}));
const world = {
  players,
  bonus: [{ x: 160, y: 208 }, { x: 544, y: 352 }, { x: 912, y: 608 }],
  drops: [{ id: 'drop-1042', x: 448, y: 224, ttl: 7632 }],
  golden: { x: 672, y: 400, ttl: 12917 },
};

const layouts = {
  legacy: world,
  compact: [
    players.map(p => [p.id, p.displayName, p.color, p.score, p.bodyLength,
      p.snake.flatMap(c => [c.x / 16, c.y / 16])]),
    world.bonus.flatMap(c => [c.x / 16, c.y / 16]),
    world.drops.map(d => [d.id, d.x / 16, d.y / 16, d.ttl]),
    [world.golden.x / 16, world.golden.y / 16, world.golden.ttl],
  ],
  rosterTick: [
    players.map(p => [p.id, p.displayName, p.color]),
    [
      players.map(p => [p.score, p.bodyLength, p.snake.flatMap(c => [c.x / 16, c.y / 16])]),
      world.bonus.flatMap(c => [c.x / 16, c.y / 16]),
      world.drops.map(d => [d.id, d.x / 16, d.y / 16, d.ttl]),
      [world.golden.x / 16, world.golden.y / 16, world.golden.ttl],
    ],
  ],
};

function timed(fn) {
  const cpu0 = process.cpuUsage();
  const t0 = performance.now();
  for (let i = 0; i < ITERATIONS; i++) fn();
  const elapsedMs = performance.now() - t0;
  const cpu = process.cpuUsage(cpu0);
  return {
    nsPerOp: Math.round(elapsedMs * 1e6 / ITERATIONS),
    cpuNsPerOp: Math.round((cpu.user + cpu.system) * 1000 / ITERATIONS),
  };
}

const out = { iterations: ITERATIONS, players: players.length, segmentsPerPlayer: 18, layouts: {} };
for (const [name, value] of Object.entries(layouts)) {
  const roster = name === 'rosterTick' ? JSON.stringify(value[0]) : '';
  const tickValue = name === 'rosterTick' ? value[1] : value;
  const tick = JSON.stringify(tickValue);
  let sink;
  out.layouts[name] = {
    tickBytes: Buffer.byteLength(tick),
    rosterBytes: Buffer.byteLength(roster),
    encode: timed(() => { sink = JSON.stringify(tickValue); }),
    parse: timed(() => { sink = JSON.parse(tick); }),
  };
  if (!sink) process.exitCode = 1;
}
console.log(JSON.stringify(out, null, 2));
