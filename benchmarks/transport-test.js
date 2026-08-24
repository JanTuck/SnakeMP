'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { TextEncoder } = require('node:util');

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  static instances = [];

  constructor(url) {
    this.url = url;
    this.readyState = FakeWebSocket.CONNECTING;
    this.sent = [];
    FakeWebSocket.instances.push(this);
  }

  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.();
  }

  receive(data) {
    this.onmessage?.({ data });
  }

  send(value) {
    assert.equal(this.readyState, FakeWebSocket.OPEN);
    this.sent.push(value);
  }

  close() {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.();
  }
}

const timers = [];
const documentListeners = new Map();
const fakeDocument = {
  hidden: false,
  addEventListener(name, callback) { documentListeners.set(name, callback); }
};
const context = vm.createContext({
  window: {},
  document: fakeDocument,
  location: { protocol: 'https:', host: 'snek.test:8443' },
  WebSocket: FakeWebSocket,
  TextEncoder,
  setTimeout(callback, delay) {
    timers.push({ callback, delay });
    return timers.length;
  }
});

const source = fs.readFileSync('client/js/transport.js', 'utf8');
vm.runInContext(source, context, { filename: 'client/js/transport.js' });

const transport = context.window.socket;
const first = FakeWebSocket.instances[0];
assert.equal(first.url, 'wss://snek.test:8443/ws');
assert.equal(first.binaryType, 'arraybuffer');

// Reproduce the browser's initial-submit race: the form queues a join before
// open, then its connect listener asks to rejoin. Exactly one join must leave.
let shouldJoin = true;
transport.emit('clientReady', 'Ålice', 'room');
transport.on('connect', () => {
  if (shouldJoin) transport.emit('clientReady', 'Ålice', 'room');
});
first.open();
assert.equal(first.sent.length, 2);
assert.deepEqual(Array.from(first.sent[0]), [3, 1]);
assert.deepEqual(Array.from(first.sent[1]), [1, 4, 6, 0, 114, 111, 111, 109, 195, 133, 108, 105, 99, 101]);

// Visibility is a two-byte delivery hint and is reasserted on reconnect.
fakeDocument.hidden = true;
documentListeners.get('visibilitychange')();
assert.deepEqual(Array.from(first.sent[2]), [3, 0]);
fakeDocument.hidden = false;
documentListeners.get('visibilitychange')();
assert.deepEqual(Array.from(first.sent[3]), [3, 1]);

// Direction packets are fixed, reused buffers and are never queued offline.
transport.emit('keyPress', 'ArrowLeft');
transport.emit('keyPress', 'ArrowLeft');
assert.equal(first.sent.length, 6);
assert.equal(first.sent[4], first.sent[5]);
assert.deepEqual(Array.from(first.sent[4]), [2, 2]);

let binaryPayload = null;
transport.on('b', (payload) => { binaryPayload = payload; });
const bytes = new Uint8Array([0x53, 0x4e, 1, 0, 0]).buffer;
first.receive(bytes);
assert.equal(binaryPayload, bytes);

first.receive('not-json');
first.receive('{}');
first.receive('[3, "ignored"]');
first.receive('["id", "first-id"]');
assert.equal(transport.id, 'first-id');

let disconnected = 0;
transport.on('disconnect', () => { disconnected += 1; });
first.close();
assert.equal(transport.id, '');
assert.equal(disconnected, 1);
assert.equal(timers.length, 1);
assert.equal(timers[0].delay, 250);

const sentBeforeOfflineInput = first.sent.length;
transport.emit('keyPress', 'ArrowRight');
assert.equal(first.sent.length, sentBeforeOfflineInput);

timers.shift().callback();
const second = FakeWebSocket.instances[1];
assert.equal(second.url, first.url);

// Callbacks from a superseded connection cannot corrupt the active one.
first.receive('["id", "stale-id"]');
assert.equal(transport.id, '');
first.onclose();
assert.equal(timers.length, 0);
assert.equal(disconnected, 1);

second.open();
assert.equal(second.sent.length, 2);
assert.deepEqual(Array.from(second.sent[0]), [3, 1]);
assert.deepEqual(Array.from(second.sent[1]), Array.from(first.sent[1]));

// UTF-8 protocol limits are byte limits, not JavaScript code-unit limits.
const beforeOversize = second.sent.length;
transport.emit('clientReady', '🐍'.repeat(63), 'room');
assert.equal(second.sent.length, beforeOversize + 1); // 252 UTF-8 bytes is valid
transport.emit('clientReady', '🐍'.repeat(64), 'room');
assert.equal(second.sent.length, beforeOversize + 1);

// Passwords are exact opaque values with a 64-byte UTF-8 bound. Missing
// passwords remain compatible with public lobbies.
transport.emit('clientReady', 'Alice', 'room', '  exact pass  ');
assert.deepEqual(Array.from(second.sent.at(-1)), [
  1, 4, 5, 14,
  ...Buffer.from('room'), ...Buffer.from('Alice'), ...Buffer.from('  exact pass  '),
]);

const beforePasswordBounds = second.sent.length;
transport.emit('clientReady', 'Alice', 'room', 'x'.repeat(64));
assert.equal(second.sent.length, beforePasswordBounds + 1);
assert.equal(second.sent.at(-1)[3], 64);

transport.emit('clientReady', 'Alice', 'room', '🔐'.repeat(16));
assert.equal(second.sent.length, beforePasswordBounds + 2, '16 four-byte code points fit exactly');
assert.equal(second.sent.at(-1)[3], 64);

transport.emit('clientReady', 'Alice', 'room', '🔐'.repeat(17));
transport.emit('clientReady', 'Alice', 'room', 'x'.repeat(65));
assert.equal(second.sent.length, beforePasswordBounds + 2, 'oversize passwords are rejected before send');

// Boost state is a fixed two-byte held/released packet and is never queued.
const beforeBoost = second.sent.length;
assert.equal(transport.emit('boost', true), true);
assert.equal(transport.emit('boost', false), true);
assert.deepEqual(Array.from(second.sent[beforeBoost]), [4, 1]);
assert.deepEqual(Array.from(second.sent[beforeBoost + 1]), [4, 0]);

// Chat is a raw type-5 UTF-8 payload. The transport trims it, enforces both
// scalar and byte ceilings, and reports whether it actually reached a live WS.
const beforeChat = second.sent.length;
assert.equal(transport.emit('chat', '  hello 🐍  '), true);
assert.deepEqual(Array.from(second.sent[beforeChat]), [5, ...Buffer.from('hello 🐍')]);
assert.equal(transport.emit('chat', 'x'.repeat(96)), true);
assert.equal(transport.emit('chat', '🐍'.repeat(40)), true, '40 four-byte code points fit 160 bytes');
assert.equal(transport.emit('chat', 'x'.repeat(97)), false, '97 Unicode scalars are rejected');
assert.equal(transport.emit('chat', '🐍'.repeat(41)), false, '164 UTF-8 bytes are rejected');
assert.equal(transport.emit('chat', '   '), false, 'empty trimmed chat is rejected');
assert.equal(second.sent.length, beforeChat + 3);

second.close();
assert.equal(transport.emit('chat', 'offline'), false, 'chat is never queued while disconnected');
assert.equal(transport.emit('boost', true), false, 'boost state is never queued while disconnected');

console.log('transport protocol tests: PASS');
