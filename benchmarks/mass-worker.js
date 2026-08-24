/* Socket fan-out worker for mass-bench.js. Kept separate so the load client
 * can use several CPU cores instead of becoming the measured bottleneck. */
const io = require('./socket');

try { delete globalThis.WebSocket; } catch (_) {}

const sockets = [];
const counters = { connected: 0, joined: 0, failed: 0, disconnected: 0, packets: 0 };
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
    const state = { socket, settled: false, lastTick: 0, observe: job.ordinal % 64 === 0, sequence: null, cells: [] };
    sockets.push(state);
    const finish = (ok) => {
      if (state.settled) return;
      state.settled = true;
      if (!ok) counters.failed++;
      resolve();
    };
    const timer = setTimeout(() => { socket.close(); finish(false); }, 20000);
    socket.on('connect', () => {
      counters.connected++;
      socket.emit('clientReady', 'mass-' + workerIndex + '-' + job.ordinal, job.lobby);
    });
    socket.on('init', () => {
      clearTimeout(timer);
      counters.joined++;
      joinLatencyMs.push(performance.now() - started);
      finish(true);
    });
    socket.on('game_error', () => { clearTimeout(timer); socket.close(); finish(false); });
    socket.on('connect_error', () => { clearTimeout(timer); socket.close(); finish(false); });
    socket.on('disconnect', () => { counters.disconnected++; });
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
      // Traverse and bounds-check the binary layout so the harness includes
      // realistic decode work without constructing render objects.
      const view = payload instanceof ArrayBuffer
        ? new DataView(payload)
        : ArrayBuffer.isView(payload) ? new DataView(payload.buffer, payload.byteOffset, payload.byteLength) : null;
      if (!view || view.byteLength < 12 || view.getUint8(0) !== 0x53 || view.getUint8(1) !== 0x4e || view.getUint8(2) !== 2) return;
      const kind = view.getUint8(3);
      const sequence = view.getUint16(4, true);
      const baseSequence = view.getUint16(6, true);
      if (kind > 1 || (kind === 0 ? baseSequence !== sequence : (state.sequence === null || baseSequence !== state.sequence || sequence !== ((baseSequence + 1) & 0xffff)))) return;
      let offset = 9;
      const players = view.getUint8(8);
      for (let i = 0; i < players; i++) {
        if (kind === 0) {
          if (offset + 6 > view.byteLength) return;
          const encoded = view.getUint16(offset + 4, true);
          const cells = encoded & 0x7fff;
          const packed = (encoded & 0x8000) !== 0;
          if (cells === 0 || cells > 7200) return;
          state.cells[i] = cells;
          offset += 6 + (packed ? 2 + Math.ceil((cells - 1) / 4) : cells * 2);
        } else {
          if (offset >= view.byteLength) return;
          const flags = view.getUint8(offset++);
          const mode = flags & 3;
          if ((flags & 0xf8) !== 0 || mode === 3 || state.cells[i] === undefined) return;
          if ((flags & 4) !== 0) offset += 4;
          if (mode !== 0) offset += 2;
          if (mode === 2) state.cells[i]++;
        }
        if (offset > view.byteLength) return;
      }
      if (offset >= view.byteLength) return;
      const bonus = view.getUint8(offset++); offset += bonus * 2;
      if (offset >= view.byteLength) return;
      const drops = view.getUint8(offset++); offset += drops * 4;
      if (offset >= view.byteLength) return;
      const golden = view.getUint8(offset++); offset += golden * 4;
      if (offset !== view.byteLength) return;
      state.sequence = sequence;
      recordTick();
    });
  });
}

async function addBatch(jobs) {
  let cursor = 0;
  async function lane() {
    while (cursor < jobs.length) {
      const job = jobs[cursor++];
      await addOne(job);
    }
  }
  await Promise.all(Array.from({ length: Math.min(100, jobs.length) }, lane));
  if (process.send) process.send({ type: 'added' });
}

process.on('message', (message) => {
  if (message.type === 'init') {
    base = message.base;
    workerIndex = message.workerIndex;
    if (process.send) process.send({ type: 'ready' });
  } else if (message.type === 'add') {
    addBatch(message.jobs).catch(() => process.send && process.send({ type: 'added' }));
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
