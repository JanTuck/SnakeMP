#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextEncoder } = require('node:util');

function inlineScript(filename) {
  const html = fs.readFileSync(filename, 'utf8');
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
  assert(scripts.length > 0, `${filename} must contain inline interaction code`);
  return scripts.at(-1)[1];
}

function control(value = '') {
  const handlers = new Map();
  return {
    value,
    textContent: '',
    hidden: true,
    disabled: false,
    validityMessage: '',
    validityReported: false,
    attributes: new Map(),
    addEventListener(name, handler) { handlers.set(name, handler); },
    fire(name, event = {}) { return handlers.get(name)?.(event); },
    setCustomValidity(message) { this.validityMessage = message; },
    reportValidity() { this.validityReported = true; },
    setAttribute(name, value) { this.attributes.set(name, value); },
    focus() {},
  };
}

function storage(initial = {}, broken = false) {
  const values = new Map(Object.entries(initial));
  return {
    values,
    getItem(key) {
      if (broken) throw new Error('storage unavailable');
      return values.has(key) ? values.get(key) : null;
    },
    setItem(key, value) {
      if (broken) throw new Error('storage unavailable');
      values.set(key, String(value));
    },
    removeItem(key) {
      if (broken) throw new Error('storage unavailable');
      values.delete(key);
    },
  };
}

const landingSource = inlineScript(path.join(__dirname, '..', 'client', 'index.html'));
const gameSource = inlineScript(path.join(__dirname, '..', 'client', 'game.html'));

function landing(overrides = {}) {
  const joinButton = control();
  const createButton = control();
  const joinForm = control();
  const createForm = control();
  joinForm.querySelector = () => joinButton;
  createForm.querySelector = () => createButton;
  const elements = {
    join_error: control(),
    gameId: control(),
    joinPassword: control(),
    createPassword: control(),
  };
  const session = overrides.session || storage();
  const window = {
    location: { search: '?error=unknown-game', origin: 'https://snek.test' },
    name: overrides.windowName || '',
  };
  const document = {
    getElementById(id) { return elements[id]; },
    querySelector(selector) { return selector === '.join-form' ? joinForm : createForm; },
  };
  vm.runInNewContext(landingSource, {
    window, document, sessionStorage: session, URL, URLSearchParams, TextEncoder, JSON,
  }, { filename: 'client/index.html:inline' });
  return { window, session, elements, joinForm, createForm, joinButton, createButton };
}

function submitEvent() {
  return { prevented: false, preventDefault() { this.prevented = true; } };
}

{
  const page = landing();
  assert.match(page.elements.join_error.textContent, /code or password/, 'wrong password and unknown lobby share one generic message');
  page.elements.gameId.value = 'https://snek.test/game/room%20seven';
  page.elements.joinPassword.value = '  päss word  ';
  const first = submitEvent();
  page.joinForm.fire('submit', first);
  assert.equal(first.prevented, false);
  assert.equal(page.elements.gameId.value, 'room seven', 'full game URLs normalize to their decoded lobby id');
  assert.equal(page.session.values.get('snek:lobby-password:room seven'), '  päss word  ', 'join password remains exact');
  assert.equal(page.joinButton.disabled, true);
  const duplicate = submitEvent();
  page.joinForm.fire('submit', duplicate);
  assert.equal(duplicate.prevented, true, 'a double submit cannot issue a second join POST');
}

{
  const page = landing();
  page.elements.gameId.value = '12345';
  page.elements.joinPassword.value = '🔐'.repeat(16);
  const exact = submitEvent();
  page.joinForm.fire('submit', exact);
  assert.equal(exact.prevented, false, '64 UTF-8 password bytes are accepted');
  assert.equal(page.session.values.get('snek:lobby-password:12345'), '🔐'.repeat(16));
}

{
  const page = landing();
  page.elements.gameId.value = '12345';
  page.elements.joinPassword.value = '🔐'.repeat(17);
  const oversized = submitEvent();
  page.joinForm.fire('submit', oversized);
  assert.equal(oversized.prevented, true);
  assert.equal(page.elements.joinPassword.validityReported, true);
  assert.equal(page.joinButton.disabled, false);
}

{
  const page = landing();
  page.elements.createPassword.value = 'create once';
  const first = submitEvent();
  page.createForm.fire('submit', first);
  assert.equal(first.prevented, false);
  assert.equal(page.session.values.get('snek:create-password'), 'create once');
  const duplicate = submitEvent();
  page.createForm.fire('submit', duplicate);
  assert.equal(duplicate.prevented, true, 'a double submit cannot create two lobbies');
}

function game(overrides = {}) {
  const button = control();
  const form = control();
  form.querySelector = () => button;
  const elements = {
    lobby_ref: control(),
    username: control(),
    lobby_password: overrides.missingPassword ? null : control(),
    join_form: form,
  };
  const handlers = new Map();
  const emitted = [];
  const socket = {
    emit(...args) { emitted.push(args); },
    on(name, handler) {
      let list = handlers.get(name);
      if (!list) handlers.set(name, list = []);
      list.push(handler);
    },
    fire(name, value) { for (const handler of handlers.get(name) || []) handler(value); },
  };
  const window = { name: overrides.windowName || '' };
  const session = overrides.session || storage();
  const local = overrides.local || storage();
  vm.runInNewContext(gameSource, {
    window,
    location: { pathname: '/game/room%20seven' },
    document: { getElementById(id) { return elements[id]; } },
    sessionStorage: session,
    localStorage: local,
    socket,
    TextEncoder,
    JSON,
  }, { filename: 'client/game.html:inline' });
  return { window, session, local, elements, form, button, socket, emitted };
}

{
  const page = game({ session: storage({ 'snek:lobby-password:room seven': '  reload pass  ' }) });
  assert.equal(page.elements.lobby_password.value, '  reload pass  ', 'reload restores the exact per-lobby password');
  page.elements.username.value = 'Alice';
  page.form.fire('submit', submitEvent());
  page.form.fire('submit', submitEvent());
  assert.deepEqual(page.emitted, [['clientReady', 'Alice', 'room seven', '  reload pass  ']], 'duplicate in-page joins are coalesced');
  page.socket.fire('game_error', 'That game does not exist any more');
  assert.equal(page.button.disabled, false, 'generic auth failure permits a corrected retry');
  page.elements.lobby_password.value = 'correct';
  page.form.fire('submit', submitEvent());
  assert.deepEqual(page.emitted.at(-1), ['clientReady', 'Alice', 'room seven', 'correct']);
}

{
  const unavailable = storage({}, true);
  const landingPage = landing({ session: unavailable });
  landingPage.elements.gameId.value = 'https://snek.test/game/room%20seven';
  landingPage.elements.joinPassword.value = '  fallback 🔐  ';
  landingPage.joinForm.fire('submit', submitEvent());
  assert.match(landingPage.window.name, /^snek-password-handoff:/);

  const gamePage = game({ session: storage({}, true), local: storage({}, true), windowName: landingPage.window.name });
  assert.equal(gamePage.window.name, '', 'storage-free handoff is consumed once');
  assert.equal(gamePage.elements.lobby_password.value, '  fallback 🔐  ');
  gamePage.elements.username.value = 'NoStore';
  gamePage.form.fire('submit', submitEvent());
  gamePage.socket.fire('connect');
  assert.deepEqual(gamePage.emitted, [
    ['clientReady', 'NoStore', 'room seven', '  fallback 🔐  '],
    ['clientReady', 'NoStore', 'room seven', '  fallback 🔐  '],
  ], 'storage failure still preserves exact credentials across reconnect');
}

{
  const handoff = 'snek-password-handoff:' + JSON.stringify({ kind: 'create', password: 'created 🔐' });
  const page = game({ session: storage({}, true), windowName: handoff });
  assert.equal(page.elements.lobby_password.value, 'created 🔐');
  assert.equal(page.window.name, '', 'create handoff is one-shot');
}

{
  const session = storage({ 'snek:create-password': 'created once' });
  const firstLoad = game({ session });
  assert.equal(firstLoad.elements.lobby_password.value, 'created once');
  assert.equal(session.values.has('snek:create-password'), false, 'create handoff key is consumed');
  assert.equal(session.values.get('snek:lobby-password:room seven'), 'created once', 'created password becomes reload-safe for this lobby');
}

{
  const page = game({ missingPassword: true });
  page.elements.username.value = 'NoField';
  page.form.fire('submit', submitEvent());
  assert.deepEqual(page.emitted, [['clientReady', 'NoField', 'room seven', '']], 'older markup without a password field falls back to a public join');
}

{
  const page = game();
  page.elements.username.value = 'Alice';
  page.elements.lobby_password.value = '🔐'.repeat(17);
  page.form.fire('submit', submitEvent());
  assert.equal(page.emitted.length, 0, 'oversize in-game passwords never reach transport');
  assert.equal(page.elements.lobby_password.validityReported, true);
  assert.equal(page.button.disabled, false);
}

{
  const page = game();
  page.elements.username.value = 'x';
  page.form.fire('submit', submitEvent());
  assert.equal(page.emitted.length, 0, 'names below three characters never reach transport');
  assert.equal(page.elements.username.validityReported, true);
}

{
  const page = game();
  page.elements.username.value = 'xyz';
  page.form.fire('submit', submitEvent());
  assert.deepEqual(page.emitted, [['clientReady', 'xyz', 'room seven', '']], 'three-character names are valid');
}

{
  const page = game();
  page.elements.username.value = 'x'.repeat(65);
  page.form.fire('submit', submitEvent());
  assert.equal(page.emitted.length, 0, 'names over 64 code points never reach transport');
  assert.equal(page.elements.username.validityReported, true);
  assert.equal(page.button.disabled, false);
}

{
  const page = game();
  page.elements.username.value = '😀'.repeat(63);
  page.form.fire('submit', submitEvent());
  assert.equal(page.emitted.length, 1, 'a 252-byte Unicode name fits the wire field');
}

{
  const page = game();
  page.elements.username.value = '😀'.repeat(64);
  page.form.fire('submit', submitEvent());
  assert.equal(page.emitted.length, 0, 'names over the one-byte UTF-8 wire limit never reach transport');
  assert.equal(page.elements.username.validityReported, true);
}

console.log('auth interaction tests: PASS (URL/code joins, exact handoff, bounds, one-shot create, retries)');
