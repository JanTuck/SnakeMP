'use strict';

// Normalize both the legacy object snapshot and Zig's compact roster/tick
// protocol. Benchmark callers can also inspect raw compact tick bytes and the
// normalization cost separately.
function attachWorld(socket, callback, metrics) {
  let roster = [];
  socket.on('r', (value) => { if (Array.isArray(value)) roster = value; });
  socket.on('gameTick', (world) => callback(world, JSON.stringify(world).length));
  socket.on('tick', (tick) => {
    if (!Array.isArray(tick) || tick.length < 4 || !Array.isArray(tick[0]) || tick[0].length !== roster.length) return;
    const t0 = performance.now();
    const players = tick[0].map((row, i) => {
      const meta = roster[i];
      const coords = row[2];
      const snake = new Array(coords.length >> 1);
      for (let p = 0, c = 0; p < coords.length; p += 2, c++) snake[c] = { x: coords[p] * 16, y: coords[p + 1] * 16 };
      return { id: meta[0], displayName: meta[1], color: meta[2], score: row[0], bodyLength: row[1], snake };
    });
    const bonus = new Array(tick[1].length >> 1);
    for (let p = 0, c = 0; p < tick[1].length; p += 2, c++) bonus[c] = { x: tick[1][p] * 16, y: tick[1][p + 1] * 16 };
    const drops = tick[2].map(row => ({ id: row[0], x: row[1] * 16, y: row[2] * 16, ttl: row[3] }));
    const golden = tick[3] === null ? null : { x: tick[3][0] * 16, y: tick[3][1] * 16, ttl: tick[3][2] };
    if (metrics) metrics.push((performance.now() - t0) * 1000);
    callback({ players, bonus, drops, golden }, JSON.stringify(tick).length);
  });
}

module.exports = { attachWorld };
