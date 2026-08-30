#!/usr/bin/env node
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

  send(value) {
    assert.equal(this.readyState, FakeWebSocket.OPEN);
    this.sent.push(value);
  }

  receive(value) {
    this.onmessage?.({ data: value });
  }

  close() {
    if (this.readyState === FakeWebSocket.CLOSED) return;
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.();
  }
}

function control(value = '') {
  const handlers = new Map();
  return {
    value,
    textContent: '',
    disabled: false,
    attributes: new Map(),
    addEventListener(name, handler) { handlers.set(name, handler); },
    fire(name, event = {}) { return handlers.get(name)?.(event); },
    setCustomValidity() {},
    reportValidity() {},
    setAttribute(name, value) { this.attributes.set(name, value); },
    focus() {},
  };
}

function storage() {
  const values = new Map();
  return {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) { values.set(key, String(value)); },
    removeItem(key) { values.delete(key); },
  };
}

const timers = [];
function schedule(handler, delay) {
  timers.push({ handler, delay, cleared: false });
  return timers.length;
}
function clearScheduled(id) {
  if (timers[id - 1]) timers[id - 1].cleared = true;
}
function runNext(delay) {
  const timer = timers.find((item) => !item.cleared && item.delay === delay);
  assert(timer, `missing active ${delay}ms timer`);
  timer.cleared = true;
  timer.handler();
}

const button = control();
const form = control();
form.querySelector = () => button;
const elements = {
  lobby_ref: control(),
  username: control(),
  lobby_password: control(),
  join_form: form,
  join_status: control(),
};
const documentListeners = new Map();
const fakeDocument = {
  hidden: false,
  addEventListener(name, handler) { documentListeners.set(name, handler); },
  getElementById(id) { return elements[id] || null; },
};

const context = vm.createContext({
  document: fakeDocument,
  location: {
    protocol: 'http:',
    host: 'snek.test:9687',
    pathname: '/game/recovery-room',
    replace() {},
  },
  WebSocket: FakeWebSocket,
  TextEncoder,
  JSON,
  console,
  sessionStorage: storage(),
  localStorage: storage(),
  setTimeout: schedule,
  clearTimeout: clearScheduled,
  fetch: undefined,
});
context.window = context;
context.window.name = '';

const transportSource = fs.readFileSync('client/js/transport.js', 'utf8');
const gameHtml = fs.readFileSync('client/game.html', 'utf8');
const inlineScripts = [...gameHtml.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert(inlineScripts.length > 0, 'game page must retain its inline join controller');

vm.runInContext(transportSource, context, { filename: 'client/js/transport.js' });
vm.runInContext(inlineScripts.at(-1)[1], context, { filename: 'client/game.html:inline' });

const first = FakeWebSocket.instances[0];
first.open();
elements.username.value = 'RecoveryCheck';
form.fire('submit', { preventDefault() {} });

assert.equal(button.disabled, true, 'the first join is guarded against double submission');
assert.equal(elements.join_status.textContent, 'Joining lobby…');
assert.equal(first.sent.filter((packet) => packet[0] === 1).length, 1, 'the initial join is sent exactly once');

// Deliberately withhold both init and game_error: this is the reported grey,
// permanently-disabled failure. The client must recover without user action.
runNext(5000);
assert.equal(button.disabled, false, 'a missing acknowledgement releases the form');
assert.match(elements.join_status.textContent, /connection stalled/i);
assert.equal(first.readyState, FakeWebSocket.CLOSED, 'the half-open socket is discarded');

runNext(250);
const second = FakeWebSocket.instances[1];
second.open();
assert.equal(button.disabled, true, 'the automatic reconnect visibly resumes joining');
assert.equal(elements.join_status.textContent, 'Reconnecting…');
assert.equal(second.sent.filter((packet) => packet[0] === 1).length, 1, 'the identity is replayed once on the fresh socket');

second.receive('["init",{"mode":"arcade"}]');
assert.equal(button.disabled, false, 'init acknowledges and clears the pending state');
assert.equal(elements.join_status.textContent, '');
assert.equal(form.attributes.get('aria-busy'), 'false');

console.log('join recovery integration test: PASS (stalled join unlocks, reconnects, and receives Arcade init)');
