'use strict';

function asView(payload) {
  if (payload instanceof ArrayBuffer) return new DataView(payload);
  if (ArrayBuffer.isView(payload)) return new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  return null;
}

// Transactional benchmark/parity decoder for the production v2 keyframe and
// delta protocol. A rejected frame never replaces the last valid world.
function decodeBinary(payload, roster, previous, lastSequence) {
  const view = asView(payload);
  if (!view || view.byteLength < 12 || view.getUint8(0) !== 0x53 || view.getUint8(1) !== 0x4e || view.getUint8(2) !== 2) return null;
  const kind = view.getUint8(3);
  if (kind > 1) return null;
  const sequence = view.getUint16(4, true);
  const base = view.getUint16(6, true);
  const count = view.getUint8(8);
  if (count !== roster.length || count > 16) return null;
  if (kind === 0 ? base !== sequence : (!previous || base !== lastSequence || sequence !== ((base + 1) & 0xffff))) return null;
  let at = 9;
  const players = new Array(count);
  for (let i = 0; i < count; i++) {
    const meta = roster[i];
    if (kind === 0) {
      if (at + 6 > view.byteLength) return null;
      const score = view.getInt32(at, true); at += 4;
      const encoded = view.getUint16(at, true); at += 2;
      const packed = (encoded & 0x8000) !== 0;
      const cells = encoded & 0x7fff;
      if (cells === 0 || cells > 7200) return null;
      const snake = new Array(cells);
      if (packed) {
        const bytes = Math.ceil((cells - 1) / 4);
        if (at + 2 + bytes > view.byteLength) return null;
        let x = view.getUint8(at++), y = view.getUint8(at++);
        for (let c = 0; c < cells; c++) {
          if (c !== 0) {
            const direction = (view.getUint8(at + ((c - 1) >> 2)) >> (((c - 1) & 3) * 2)) & 3;
            if (direction === 0) y--; else if (direction === 1) y++;
            else if (direction === 2) x--; else x++;
          }
          if (x < 0 || x >= 120 || y < 0 || y >= 60) return null;
          snake[c] = { x: x * 16, y: y * 16 };
        }
        at += bytes;
      } else {
        if (at + cells * 2 > view.byteLength) return null;
        for (let c = 0; c < cells; c++) snake[c] = { x: view.getUint8(at++) * 16, y: view.getUint8(at++) * 16 };
      }
      players[i] = { id: meta[0], displayName: meta[1], color: meta[2], score, bodyLength: cells, snake };
    } else {
      if (at >= view.byteLength) return null;
      const flags = view.getUint8(at++);
      const mode = flags & 3;
      if ((flags & 0xf8) !== 0 || mode === 3) return null;
      const old = previous.players[i];
      let score = old.score;
      if ((flags & 4) !== 0) {
        if (at + 4 > view.byteLength) return null;
        score = view.getInt32(at, true); at += 4;
      }
      let snake;
      if (mode === 0) snake = old.snake.map(cell => ({ ...cell }));
      else {
        if (at + 2 > view.byteLength) return null;
        const head = { x: view.getUint8(at++) * 16, y: view.getUint8(at++) * 16 };
        const length = old.snake.length + (mode === 2 ? 1 : 0);
        snake = new Array(length);
        snake[0] = head;
        for (let c = 1; c < length; c++) snake[c] = { ...old.snake[c - 1] };
      }
      players[i] = { id: meta[0], displayName: meta[1], color: meta[2], score, bodyLength: snake.length, snake };
    }
  }
  if (at >= view.byteLength) return null;
  const bonusCount = view.getUint8(at++);
  if (bonusCount > 12 || at + bonusCount * 2 > view.byteLength) return null;
  const bonus = new Array(bonusCount);
  for (let i = 0; i < bonusCount; i++) bonus[i] = { x: view.getUint8(at++) * 16, y: view.getUint8(at++) * 16 };
  if (at >= view.byteLength) return null;
  const dropCount = view.getUint8(at++);
  if (dropCount > 2 || at + dropCount * 4 > view.byteLength) return null;
  const drops = new Array(dropCount);
  for (let i = 0; i < dropCount; i++) {
    const x = view.getUint8(at++) * 16, y = view.getUint8(at++) * 16;
    const ttl = view.getUint16(at, true); at += 2;
    drops[i] = { id: '', x, y, ttl };
  }
  if (at >= view.byteLength) return null;
  const hasGolden = view.getUint8(at++);
  if (hasGolden > 1 || at + hasGolden * 4 !== view.byteLength) return null;
  const golden = hasGolden ? { x: view.getUint8(at++) * 16, y: view.getUint8(at++) * 16, ttl: view.getUint16(at, true) } : null;
  return { world: { players, bonus, drops, golden }, sequence };
}

function attachWorld(socket, callback, metrics) {
  let roster = [];
  let previous = null;
  let lastSequence = null;
  socket.on('r', (value) => {
    if (!Array.isArray(value) || value.length > 16) return;
    roster = value;
    previous = null;
    lastSequence = null;
  });
  socket.on('b', (payload) => {
    const t0 = performance.now();
    const decoded = decodeBinary(payload, roster, previous && previous.world, lastSequence);
    if (!decoded) return;
    previous = decoded;
    lastSequence = decoded.sequence;
    if (metrics) metrics.push((performance.now() - t0) * 1000);
    callback(decoded.world, asView(payload).byteLength);
  });
}

module.exports = { attachWorld, decodeBinary };
