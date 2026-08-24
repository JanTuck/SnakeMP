'use strict';

const BOARD_COLUMNS = 128;
const BOARD_ROWS = 72;
const CELL_SIZE = 16;
const BOARD_WIDTH = BOARD_COLUMNS * CELL_SIZE;
const BOARD_HEIGHT = BOARD_ROWS * CELL_SIZE;
const BOARD_CELLS = BOARD_COLUMNS * BOARD_ROWS;

function asView(payload) {
  if (payload instanceof ArrayBuffer) return new DataView(payload);
  if (ArrayBuffer.isView(payload)) return new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  return null;
}

// Transactional benchmark/parity decoder for the production v5 keyframe and
// delta protocol. A rejected frame never replaces the last valid world.
function decodeBinary(payload, roster, previous, lastSequence) {
  const view = asView(payload);
  if (!view || !Array.isArray(roster) || view.byteLength < 7 || view.getUint8(0) !== 0x53 || view.getUint8(1) !== 0x4e || view.getUint8(2) !== 5) return null;
  const sequence = view.getUint16(3, true);
  const header = view.getUint8(5);
  if ((header & 0x60) !== 0) return null;
  const kind = header >>> 7;
  const count = header & 0x1f;
  if (count !== roster.length || count > 16) return null;
  if (kind === 1 && (!previous || !Array.isArray(previous.players) || previous.players.length !== count ||
      !Number.isInteger(lastSequence) || sequence !== ((lastSequence + 1) & 0xffff))) return null;
  let at = 6;
  const players = new Array(count);
  for (let i = 0; i < count; i++) {
    const meta = roster[i];
    if (!Array.isArray(meta) || meta.length < 3) return null;
    if (kind === 0) {
      if (at + 6 > view.byteLength) return null;
      const score = view.getInt32(at, true); at += 4;
      const encoded = view.getUint16(at, true); at += 2;
      const packed = (encoded & 0x8000) !== 0;
      const cells = encoded & 0x7fff;
      if (cells === 0 || cells > BOARD_CELLS) return null;
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
          if (x < 0 || x >= BOARD_COLUMNS || y < 0 || y >= BOARD_ROWS) return null;
          snake[c] = { x: x * CELL_SIZE, y: y * CELL_SIZE };
        }
        if (bytes > 0 && ((cells - 1) & 3) !== 0) {
          const usedBits = ((cells - 1) & 3) * 2;
          if ((view.getUint8(at + bytes - 1) >> usedBits) !== 0) return null;
        }
        at += bytes;
      } else {
        if (at + cells * 2 > view.byteLength) return null;
        for (let c = 0; c < cells; c++) {
          const x = view.getUint8(at++), y = view.getUint8(at++);
          if (x >= BOARD_COLUMNS || y >= BOARD_ROWS) return null;
          snake[c] = { x: x * CELL_SIZE, y: y * CELL_SIZE };
        }
      }
      players[i] = { id: meta[0], displayName: meta[1], color: meta[2], score, bodyLength: cells, snake };
    } else {
      if (at >= view.byteLength) return null;
      const flags = view.getUint8(at++);
      const mode = flags & 3;
      if ((flags & 0xc0) !== 0) return null;
      const old = previous.players[i];
      if (!old || !Array.isArray(old.snake) || old.snake.length === 0) return null;
      let score = old.score;
      if ((flags & 4) !== 0) {
        if (at + 4 > view.byteLength) return null;
        score = view.getInt32(at, true); at += 4;
      }
      let snake;
      if (mode === 0) snake = old.snake.map(cell => ({ ...cell }));
      else {
        const direction = (flags >> 3) & 3;
        const head = { x: old.snake[0].x, y: old.snake[0].y };
        const steps = (flags & 0x20) !== 0 ? 2 : 1;
        if (direction === 0) head.y -= CELL_SIZE * steps; else if (direction === 1) head.y += CELL_SIZE * steps;
        else if (direction === 2) head.x -= CELL_SIZE * steps; else head.x += CELL_SIZE * steps;
        if (head.x < 0 || head.x >= BOARD_WIDTH || head.y < 0 || head.y >= BOARD_HEIGHT) return null;
        const length = old.snake.length + (mode === 2 ? 1 : mode === 3 ? -1 : 0);
        if (length <= 0 || length > BOARD_CELLS) return null;
        snake = new Array(length);
        snake[0] = head;
        if (steps === 2 && length > 1) {
          snake[1] = {
            x: (old.snake[0].x + head.x) / 2,
            y: (old.snake[0].y + head.y) / 2,
          };
        }
        for (let c = steps; c < length; c++) snake[c] = { ...old.snake[c - steps] };
      }
      if (mode === 0 && (flags & 0x38) !== 0) return null;
      players[i] = { id: meta[0], displayName: meta[1], color: meta[2], score, bodyLength: snake.length, snake };
    }
  }
  if (at >= view.byteLength) return null;
  const worldHeader = view.getUint8(at++);
  const hasArcadeExtension = (worldHeader & 0x80) !== 0;
  const bonusCount = worldHeader & 0x0f;
  const dropCount = (worldHeader >>> 4) & 3;
  const hasGolden = (worldHeader & 0x40) !== 0;
  if (bonusCount > 12 || at + bonusCount * 2 > view.byteLength) return null;
  const bonus = new Array(bonusCount);
  for (let i = 0; i < bonusCount; i++) {
    const x = view.getUint8(at++), y = view.getUint8(at++);
    if (x >= BOARD_COLUMNS || y >= BOARD_ROWS) return null;
    bonus[i] = { x: x * CELL_SIZE, y: y * CELL_SIZE };
  }
  if (dropCount > 2 || at + dropCount * 4 > view.byteLength) return null;
  const drops = new Array(dropCount);
  for (let i = 0; i < dropCount; i++) {
    const cellX = view.getUint8(at++), cellY = view.getUint8(at++);
    if (cellX >= BOARD_COLUMNS || cellY >= BOARD_ROWS) return null;
    const x = cellX * CELL_SIZE, y = cellY * CELL_SIZE;
    const ttl = view.getUint16(at, true); at += 2;
    drops[i] = { id: '', x, y, ttl };
  }
  let golden = null;
  if (hasGolden) {
    if (at + 4 > view.byteLength) return null;
    const x = view.getUint8(at++), y = view.getUint8(at++);
    if (x >= BOARD_COLUMNS || y >= BOARD_ROWS) return null;
    golden = { x: x * CELL_SIZE, y: y * CELL_SIZE, ttl: view.getUint16(at, true) }; at += 2;
  }

  let remains = [];
  let feastActive = false;
  let feastTtl = 0;
  let hasBounty = false;
  let bountySlot = 0;
  if (hasArcadeExtension) {
    if (at >= view.byteLength) return null;
    const arcadeHeader = view.getUint8(at++);
    const remainsCount = arcadeHeader & 0x3f;
    feastActive = (arcadeHeader & 0x40) !== 0;
    hasBounty = (arcadeHeader & 0x80) !== 0;
    if (at + remainsCount * 4 > view.byteLength) return null;
    remains = new Array(remainsCount);
    for (let i = 0; i < remainsCount; i++) {
      const x = view.getUint8(at++), y = view.getUint8(at++);
      if (x >= BOARD_COLUMNS || y >= BOARD_ROWS) return null;
      remains[i] = { x: x * CELL_SIZE, y: y * CELL_SIZE, ttl: view.getUint16(at, true) };
      at += 2;
    }
    if (feastActive) {
      if (at + 2 > view.byteLength) return null;
      feastTtl = view.getUint16(at, true); at += 2;
    }
    if (hasBounty) {
      if (at >= view.byteLength) return null;
      bountySlot = view.getUint8(at++);
      if (bountySlot >= count) return null;
    }
  }
  if (at !== view.byteLength) return null;
  return { world: { players, bonus, drops, golden, remains, feastActive, feastTtl, hasBounty, bountySlot }, sequence };
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
