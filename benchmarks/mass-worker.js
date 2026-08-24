/* Socket fan-out worker for mass-bench.js. Kept separate so the load client
 * can use several CPU cores instead of becoming the measured bottleneck. */
const io = require('./socket');

const BOARD_COLUMNS = 128;
const BOARD_ROWS = 72;
const BOARD_CELLS = BOARD_COLUMNS * BOARD_ROWS;

try { delete globalThis.WebSocket; } catch (_) {}

const sockets = [];
const counters = {
  connected: 0,
  joined: 0,
  active: 0,
  failed: 0,
  disconnected: 0,
  packets: 0,
  binaryPackets: 0,
  invalidPackets: 0,
};
let cadence = [];
let joinLatencyMs = [];
let base = '';
let workerIndex = 0;

function alphaId(value) {
  let remaining = value;
  let encoded = '';
  do {
    encoded = String.fromCharCode(97 + (remaining % 26)) + encoded;
    remaining = Math.floor(remaining / 26);
  } while (remaining > 0);
  return encoded;
}

function playerName(ordinal) {
  // Production names allow at most 24 characters and four non-letters. Keep
  // load identities entirely alphabetic while remaining unique per worker.
  return 'mass' + alphaId(workerIndex) + 'player' + alphaId(ordinal);
}

function addOne(job) {
  return new Promise((resolve) => {
    const started = performance.now();
    const socket = io(base, {
      transports: ['websocket'],
      forceNew: true,
      reconnection: false,
      timeout: 15000,
    });
    const state = {
      socket,
      settled: false,
      joined: false,
      disconnected: false,
      lastTick: 0,
      observe: job.ordinal % 64 === 0,
      sequence: null,
      cells: [],
      scratchCells: [],
    };
    sockets.push(state);
    let timer;
    const finish = (error) => {
      if (state.settled) return;
      state.settled = true;
      clearTimeout(timer);
      if (error) counters.failed++;
      resolve(error);
    };
    timer = setTimeout(() => { socket.close(); finish('join timeout'); }, 20000);
    socket.on('connect', () => {
      if (state.settled) return;
      counters.connected++;
      socket.emit('clientReady', playerName(job.ordinal), job.lobby);
    });
    socket.on('init', () => {
      if (state.settled) {
        socket.close();
        return;
      }
      state.joined = true;
      counters.joined++;
      counters.active++;
      joinLatencyMs.push(performance.now() - started);
      finish(null);
    });
    socket.on('game_error', (message) => { socket.close(); finish('game_error: ' + String(message || 'unknown')); });
    socket.on('connect_error', (error) => { socket.close(); finish('connect_error: ' + String(error && error.message || error)); });
    socket.on('disconnect', () => {
      if (state.disconnected) return;
      state.disconnected = true;
      counters.disconnected++;
      if (state.joined) counters.active--;
    });
    const recordTick = () => {
      counters.packets++;
      if (state.observe) {
        const now = performance.now();
        if (state.lastTick && cadence.length < 250000) cadence.push(now - state.lastTick);
        state.lastTick = now;
      }
    };
    socket.on('tick', recordTick);
    socket.on('b', (payload) => {
      counters.binaryPackets++;
      const invalid = () => { counters.invalidPackets++; };
      // Traverse and bounds-check the binary layout so the harness includes
      // realistic decode work without constructing render objects.
      const view = payload instanceof ArrayBuffer
        ? new DataView(payload)
        : ArrayBuffer.isView(payload) ? new DataView(payload.buffer, payload.byteOffset, payload.byteLength) : null;
      if (!view || view.byteLength < 7 || view.getUint8(0) !== 0x53 || view.getUint8(1) !== 0x4e || view.getUint8(2) !== 5) return invalid();
      const sequence = view.getUint16(3, true);
      const header = view.getUint8(5);
      if ((header & 0x40) !== 0) return invalid();
      const kind = header >>> 7;
      const players = header & 0x3f;
      if (players > 32 || (kind === 1 && (state.sequence === null || sequence !== ((state.sequence + 1) & 0xffff)))) return invalid();
      if (kind === 1 && players !== state.cells.length) return invalid();
      const nextCells = state.scratchCells;
      nextCells.length = players;
      if (kind === 1) {
        for (let i = 0; i < players; i++) nextCells[i] = state.cells[i];
      }
      let offset = 6;
      const need = (bytes) => bytes >= 0 && offset + bytes <= view.byteLength;
      const validCell = (x, y) => x < BOARD_COLUMNS && y < BOARD_ROWS;
      for (let i = 0; i < players; i++) {
        if (kind === 0) {
          if (!need(6)) return invalid();
          const encoded = view.getUint16(offset + 4, true);
          const cells = encoded & 0x7fff;
          const packed = (encoded & 0x8000) !== 0;
          if (cells === 0 || cells > BOARD_CELLS) return invalid();
          nextCells[i] = cells;
          offset += 6;
          if (packed) {
            const pathBytes = Math.ceil((cells - 1) / 4);
            if (!need(2 + pathBytes)) return invalid();
            let x = view.getUint8(offset++), y = view.getUint8(offset++);
            if (!validCell(x, y)) return invalid();
            for (let cell = 1; cell < cells; cell++) {
              const direction = (view.getUint8(offset + ((cell - 1) >> 2)) >> (((cell - 1) & 3) * 2)) & 3;
              if (direction === 0) y--; else if (direction === 1) y++;
              else if (direction === 2) x--; else x++;
              if (x < 0 || y < 0 || !validCell(x, y)) return invalid();
            }
            if (pathBytes > 0 && ((cells - 1) & 3) !== 0) {
              const usedBits = ((cells - 1) & 3) * 2;
              if ((view.getUint8(offset + pathBytes - 1) >> usedBits) !== 0) return invalid();
            }
            offset += pathBytes;
          } else {
            if (!need(cells * 2)) return invalid();
            for (let cell = 0; cell < cells; cell++) {
              if (!validCell(view.getUint8(offset + cell * 2), view.getUint8(offset + cell * 2 + 1))) return invalid();
            }
            offset += cells * 2;
          }
        } else {
          if (!need(1)) return invalid();
          const flags = view.getUint8(offset++);
          const mode = flags & 3;
          if ((flags & 0xc0) !== 0 || nextCells[i] === undefined) return invalid();
          if ((flags & 4) !== 0) {
            if (!need(4)) return invalid();
            offset += 4;
          }
          if (mode === 0 && (flags & 0x38) !== 0) return invalid();
          if (mode === 2 && ++nextCells[i] > BOARD_CELLS) return invalid();
          if (mode === 3 && --nextCells[i] === 0) return invalid();
        }
      }
      if (!need(1)) return invalid();
      const world = view.getUint8(offset++);
      const hasArcadeExtension = (world & 0x80) !== 0;
      const bonus = world & 0x0f;
      const drops = (world >>> 4) & 3;
      const golden = (world & 0x40) !== 0;
      if (bonus > 12 || drops > 2) return invalid();
      if (!need(bonus * 2)) return invalid();
      for (let i = 0; i < bonus; i++) {
        if (!validCell(view.getUint8(offset), view.getUint8(offset + 1))) return invalid();
        offset += 2;
      }
      if (!need(drops * 4)) return invalid();
      for (let i = 0; i < drops; i++) {
        if (!validCell(view.getUint8(offset), view.getUint8(offset + 1))) return invalid();
        offset += 4;
      }
      if (golden) {
        if (!need(4) || !validCell(view.getUint8(offset), view.getUint8(offset + 1))) return invalid();
        offset += 4;
      }
      if (hasArcadeExtension) {
        if (!need(1)) return invalid();
        const arcade = view.getUint8(offset++);
        const remains = arcade & 0x3f;
        const feast = (arcade & 0x40) !== 0;
        const bounty = (arcade & 0x80) !== 0;
        if (!need(remains * 4)) return invalid();
        for (let i = 0; i < remains; i++) {
          if (!validCell(view.getUint8(offset), view.getUint8(offset + 1))) return invalid();
          offset += 4;
        }
        if (feast) {
          if (!need(2)) return invalid();
          offset += 2;
        }
        if (bounty) {
          if (!need(1) || view.getUint8(offset) >= players) return invalid();
          offset++;
        }
      }
      if (offset !== view.byteLength) return invalid();
      state.scratchCells = state.cells;
      state.cells = nextCells;
      state.sequence = sequence;
      recordTick();
    });
  });
}

async function addBatch(jobs) {
  let cursor = 0;
  const failures = [];
  async function lane() {
    while (cursor < jobs.length) {
      const job = jobs[cursor++];
      const error = await addOne(job);
      if (error) failures.push({ ordinal: job.ordinal, error });
    }
  }
  await Promise.all(Array.from({ length: Math.min(100, jobs.length) }, lane));
  return failures;
}

process.on('message', (message) => {
  if (message.type === 'init') {
    base = message.base;
    workerIndex = message.workerIndex;
    if (process.send) process.send({ type: 'ready', requestId: message.requestId, ok: true });
  } else if (message.type === 'add') {
    addBatch(message.jobs).then((failures) => {
      if (!process.send) return;
      process.send({
        type: 'added',
        requestId: message.requestId,
        ok: failures.length === 0,
        failedJobs: failures.length,
        failures: failures.slice(0, 10),
      });
    }).catch((error) => {
      if (process.send) process.send({ type: 'added', requestId: message.requestId, ok: false, error: String(error && error.stack || error) });
    });
  } else if (message.type === 'snapshot') {
    // Capture the counter and timestamp together in this process. The parent
    // receives worker replies at slightly different times under heavy load,
    // so using one nominal wall-clock window can report impossible >100%
    // delivery at a perfectly healthy 15 Hz.
    const reply = {
      type: 'snapshot',
      requestId: message.requestId,
      sampledAtMs: performance.now(),
      counters: { ...counters },
      observedActive: sockets.reduce((count, state) => count + Number(state.observe && state.joined && !state.disconnected), 0),
      cadence,
      joinLatencyMs,
    };
    cadence = [];
    joinLatencyMs = [];
    if (process.send) process.send(reply);
  } else if (message.type === 'close') {
    for (const state of sockets) state.socket.close();
    setTimeout(() => process.exit(0), 25);
  }
});
