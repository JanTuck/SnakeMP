/* Socket fan-out worker for mass-bench.js. Kept separate so the load client
 * can use several CPU cores instead of becoming the measured bottleneck. */
const io = require('./socket');

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
      socket.emit('clientReady', 'mass-' + workerIndex + '-' + job.ordinal, job.lobby);
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
      if (!view || view.byteLength < 7 || view.getUint8(0) !== 0x53 || view.getUint8(1) !== 0x4e || view.getUint8(2) !== 4) return invalid();
      const sequence = view.getUint16(3, true);
      const header = view.getUint8(5);
      if ((header & 0x60) !== 0) return invalid();
      const kind = header >>> 7;
      const players = header & 0x1f;
      if (players > 16 || (kind === 1 && (state.sequence === null || sequence !== ((state.sequence + 1) & 0xffff)))) return invalid();
      let offset = 6;
      for (let i = 0; i < players; i++) {
        if (kind === 0) {
          if (offset + 6 > view.byteLength) return invalid();
          const encoded = view.getUint16(offset + 4, true);
          const cells = encoded & 0x7fff;
          const packed = (encoded & 0x8000) !== 0;
          if (cells === 0 || cells > 7200) return invalid();
          state.cells[i] = cells;
          offset += 6 + (packed ? 2 + Math.ceil((cells - 1) / 4) : cells * 2);
        } else {
          if (offset >= view.byteLength) return invalid();
          const flags = view.getUint8(offset++);
          const mode = flags & 3;
          if ((flags & 0xe0) !== 0 || mode === 3 || state.cells[i] === undefined) return invalid();
          if ((flags & 4) !== 0) offset += 4;
          if (mode === 0 && (flags & 0x18) !== 0) return invalid();
          if (mode === 2) state.cells[i]++;
        }
        if (offset > view.byteLength) return invalid();
      }
      if (offset >= view.byteLength) return invalid();
      const world = view.getUint8(offset++);
      if ((world & 0x80) !== 0) return invalid();
      const bonus = world & 0x0f;
      const drops = (world >>> 4) & 3;
      const golden = (world & 0x40) !== 0;
      if (bonus > 12 || drops > 2) return invalid();
      offset += bonus * 2 + drops * 4 + (golden ? 4 : 0);
      if (offset !== view.byteLength) return invalid();
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
