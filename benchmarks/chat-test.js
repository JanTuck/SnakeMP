#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { TextEncoder } = require('node:util');

class ClassList {
  constructor() { this.values = new Set(); }
  add(value) { this.values.add(value); }
  remove(value) { this.values.delete(value); }
  contains(value) { return this.values.has(value); }
  toggle(value, force) {
    if (force === true) this.values.add(value);
    else if (force === false) this.values.delete(value);
    else if (this.values.has(value)) this.values.delete(value);
    else this.values.add(value);
  }
}

function element(document, tagName = 'div') {
  const handlers = new Map();
  return {
    tagName: tagName.toUpperCase(),
    value: '',
    textContent: '',
    hidden: false,
    children: [],
    parent: null,
    className: '',
    classList: new ClassList(),
    attributes: new Map(),
    style: {},
    scrollTop: 0,
    scrollHeight: 1000,
    addEventListener(name, handler) {
      let list = handlers.get(name);
      if (!list) handlers.set(name, list = []);
      list.push(handler);
    },
    fire(name, event = {}) { for (const handler of handlers.get(name) || []) handler(event); },
    setAttribute(name, value) { this.attributes.set(name, String(value)); },
    append(...nodes) {
      for (const node of nodes) {
        node.parent = this;
        this.children.push(node);
      }
    },
    remove() {
      if (this.parent) this.parent.children = this.parent.children.filter((child) => child !== this);
      this.parent = null;
    },
    contains(candidate) {
      if (candidate === this) return true;
      return this.children.some((child) => typeof child.contains === 'function' && child.contains(candidate));
    },
    focus() { document.activeElement = this; },
    blur() {
      if (document.activeElement === this) document.activeElement = null;
      this.fire('blur');
    },
    setCustomValidity(message) { this.validityMessage = message; },
    reportValidity() { this.validityReported = true; },
  };
}

const documentHandlers = new Map();
const document = {
  activeElement: null,
  elements: {},
  getElementById(id) { return this.elements[id] || null; },
  createElement(tag) { return element(this, tag); },
  createTextNode(text) {
    const node = element(this, '#text');
    node.textContent = text;
    return node;
  },
  addEventListener(name, handler) {
    let list = documentHandlers.get(name);
    if (!list) documentHandlers.set(name, list = []);
    list.push(handler);
  },
  fire(name, event) { for (const handler of documentHandlers.get(name) || []) handler(event); },
};

for (const [id, tag] of [
  ['game_chat', 'section'], ['chat_history', 'div'], ['chat_form', 'form'],
  ['chat_input', 'input'], ['chat_send', 'button'], ['chat_status', 'span'], ['chat_open', 'button'],
]) document.elements[id] = element(document, tag);
document.elements.game_chat.hidden = true;
document.elements.game_chat.append(
  document.elements.chat_history,
  document.elements.chat_form,
  document.elements.chat_open,
);
document.elements.chat_form.append(document.elements.chat_input, document.elements.chat_send, document.elements.chat_status);

const socketHandlers = new Map();
const emitted = [];
let sendResult = true;
const socket = {
  on(name, handler) { socketHandlers.set(name, handler); },
  fire(name, value) { socketHandlers.get(name)?.(value); },
  emit(...args) { emitted.push(args); return sendResult; },
};
const timers = [];
const activeTimers = new Set();
const animationFrames = [];
const source = fs.readFileSync('client/js/chat.js', 'utf8');
vm.runInNewContext(source, {
  document, socket, TextEncoder,
  requestAnimationFrame(callback) { animationFrames.push(callback); return animationFrames.length; },
  setTimeout(callback, delay) {
    const id = timers.length + 1;
    timers.push({ id, callback, delay });
    activeTimers.add(id);
    return id;
  },
  clearTimeout(id) { activeTimers.delete(id); },
}, { filename: 'client/js/chat.js' });

const root = document.elements.game_chat;
const history = document.elements.chat_history;
const form = document.elements.chat_form;
const input = document.elements.chat_input;

socket.fire('init', {});
assert.equal(root.hidden, false, 'chat becomes available only after joining');
socket.fire('r', [
  ['p2', 'Bea', '#78dce8'],
  ['p1', 'Ada', '#78dce8'],
]);
socket.fire('chat', { id: 'p1', who: 'spoofed', color: '#090d0b', text: '<b>hello</b>' });
socket.fire('chat', { id: 'p2', who: 'spoofed', color: '#090d0b', text: 'hi' });
assert.equal(history.children[0].children[0].textContent, 'Ada', 'active roster name defeats payload spoofing');
assert.equal(history.children[0].children[2].textContent, '<b>hello</b>', 'message is literal text, not markup');
assert.notEqual(
  history.children[0].children[0].style.color,
  history.children[1].children[0].style.color,
  'duplicate supplied colors get distinct deterministic active-roster fallbacks',
);

const ioRoster = Array.from({ length: 55 }, (_, index) => [
  `io-${index}`, `Player ${index}`, index === 54 ? '#ffd866' : '#78dce8',
]);
socket.fire('r', ioRoster);
socket.fire('chat', { id: 'io-54', who: 'spoofed', color: '#090d0b', text: 'full room hello' });
assert.equal(history.children.at(-1).children[0].textContent, 'Player 54',
  'a fluctuating 55-player IO roster retains authoritative chat identity mapping');

for (let index = 0; index < 100; index++) {
  socket.fire('chat', { id: 'io-1', text: `message ${index}` });
}
assert.equal(history.children.length, 100, 'session history evicts beyond its 100-message bound');
assert.equal(activeTimers.size, 200, 'evicted messages release both visibility timers');

const keyEvent = {
  key: 'Enter', target: element(document, 'canvas'), defaultPrevented: false,
  preventDefault() { this.defaultPrevented = true; },
};
document.fire('keydown', keyEvent);
assert.equal(root.classList.contains('is-open'), true);
assert.equal(document.activeElement, input);
assert.equal(keyEvent.defaultPrevented, true);
assert.equal(animationFrames.length, 1, 'opening chat schedules one scroll to the latest history');
animationFrames.shift()();
socket.fire('chat', { id: 'io-1', text: 'burst one' });
socket.fire('chat', { id: 'io-1', text: 'burst two' });
socket.fire('chat', { id: 'io-1', text: 'burst three' });
assert.equal(animationFrames.length, 1, 'a message burst coalesces history scrolling into one animation frame');
animationFrames.shift()();

input.value = '  hello world  ';
form.fire('submit', { preventDefault() {} });
assert.deepEqual(emitted.at(-1), ['chat', 'hello world']);
assert.equal(input.value, '');
assert.equal(root.classList.contains('is-open'), false, 'sending closes chat so steering resumes immediately');
assert.equal(document.activeElement, null, 'sending returns keyboard focus to gameplay');

document.fire('keydown', keyEvent);
input.value = 'x'.repeat(97);
form.fire('submit', { preventDefault() {} });
assert.equal(input.validityReported, true, 'oversize chat reports a useful validation error');
assert.notDeepEqual(emitted.at(-1), ['chat', 'x'.repeat(97)]);

input.fire('keydown', { key: 'Escape', preventDefault() {} });
assert.equal(root.classList.contains('is-open'), false);

socket.fire('death');
assert.equal(root.classList.contains('is-game-over'), true);
assert.match(document.elements.chat_status.textContent, /wait/i);
socket.fire('init', {});
assert.equal(root.classList.contains('is-game-over'), false, 'rejoin clears the dead-chat presentation');
assert.equal(document.elements.chat_status.textContent, '', 'rejoin clears stale waiting instructions');
const retry = element(document, 'button');
const tShortcut = {
  key: 't', code: 'KeyT', target: retry, defaultPrevented: false,
  preventDefault() { this.defaultPrevented = true; },
};
document.fire('keydown', tShortcut);
assert.equal(root.classList.contains('is-open'), true, 'T opens chat even while Retry owns game-over focus');
input.fire('keydown', { key: 'Escape', preventDefault() {} });

const joinInput = element(document, 'input');
const joinEnter = { key: 'Enter', target: joinInput, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
document.fire('keydown', joinEnter);
assert.equal(root.classList.contains('is-open'), false, 'join and other form inputs keep Enter');
assert.equal(joinEnter.defaultPrevented, false);

sendResult = false;
document.fire('keydown', keyEvent);
input.value = 'offline message';
form.fire('submit', { preventDefault() {} });
assert.equal(input.value, 'offline message', 'offline text remains available for retry');
assert.match(document.elements.chat_status.textContent, /offline/i);

console.log('chat interaction tests: PASS');
