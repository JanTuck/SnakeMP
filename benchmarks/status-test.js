#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'client', 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(root, 'client', 'css', 'index.css'), 'utf8');
const source = fs.readFileSync(path.join(root, 'client', 'js', 'status.js'), 'utf8');
const manifest = fs.readFileSync(path.join(root, 'servers', 'zig', 'src', 'assets_manifest.zig'), 'utf8');
const server = fs.readFileSync(path.join(root, 'servers', 'zig', 'src', 'main.zig'), 'utf8');

assert.match(html, /id="server_state"[^>]*role="status"[^>]*aria-live="polite"/, 'live totals must be announced as a polite status');
for (const id of ['status_players', 'status_lobbies', 'status_summary']) {
  assert(html.includes(`id="${id}"`), `landing page is missing #${id}`);
}
assert(html.includes('/js/status.js'), 'landing page must load its status controller');
assert(manifest.includes('.path = "/js/status.js"'), 'status controller must be embedded in the Zig binary');
assert.match(server, /std\.mem\.eql\(u8, dec_path, "\/status"\)/, 'Zig server must expose the public status route');
assert.match(server, /\.cache_control = "no-store"/, 'live totals must not be served from a stale cache');
assert.match(css, /font-variant-numeric:\s*tabular-nums/, 'live counters must use stable-width numerals');
assert.match(css, /@media \(prefers-reduced-motion: reduce\)/, 'landing page must respect reduced-motion preferences');

function makeElement() {
  return {
    textContent: '',
    dataset: {},
    querySelector() { return null; },
  };
}

function page(fetchImpl) {
  const elements = Object.fromEntries([
    'server_state', 'status_players', 'status_lobbies', 'status_players_label',
    'status_lobbies_label', 'status_summary',
  ].map((id) => [id, makeElement()]));
  const stateLabel = makeElement();
  elements.server_state.dataset.state = 'loading';
  elements.server_state.querySelector = (selector) => selector === '.server-state-label' ? stateLabel : null;
  const documentHandlers = new Map();
  const windowHandlers = new Map();
  const timers = [];
  const requests = [];
  const document = {
    hidden: false,
    getElementById(id) { return elements[id] || null; },
    addEventListener(name, handler) { documentHandlers.set(name, handler); },
  };
  const window = {
    fetch(route, options) {
      requests.push({ route, options });
      return fetchImpl(route, options);
    },
    setTimeout(handler, delay) { timers.push({ handler, delay }); return timers.length; },
    clearTimeout() {},
    addEventListener(name, handler) { windowHandlers.set(name, handler); },
  };
  vm.runInNewContext(source, { window, document, Number, Date, Error }, { filename: 'client/js/status.js' });
  return { document, elements, stateLabel, documentHandlers, windowHandlers, timers, requests };
}

async function settle() {
  for (let index = 0; index < 6; index += 1) await Promise.resolve();
}

(async () => {
  const live = page(async () => ({
    ok: true,
    async json() { return { players: 1, lobbies: 12000 }; },
  }));
  await settle();
  assert.equal(live.requests.length, 1);
  assert.equal(live.requests[0].route, '/status');
  assert.equal(live.requests[0].options.cache, 'no-store');
  assert.equal(live.requests[0].options.credentials, 'same-origin');
  assert.equal(live.elements.server_state.dataset.state, 'live');
  assert.equal(live.stateLabel.textContent, 'Live');
  assert.equal(live.elements.status_players.textContent, '1');
  assert.equal(live.elements.status_players_label.textContent, 'player');
  assert.equal(live.elements.status_lobbies.textContent, '12K');
  assert.equal(live.elements.status_lobbies_label.textContent, 'lobbies');
  assert.match(live.elements.status_summary.textContent, /1 player across 12,000 lobbies right now/);
  assert(live.timers.some((timer) => timer.delay === 15000), 'successful requests must schedule a bounded refresh');

  const unavailable = page(async () => { throw new Error('offline'); });
  await settle();
  assert.equal(unavailable.elements.server_state.dataset.state, 'retrying');
  assert.equal(unavailable.stateLabel.textContent, 'Retrying');
  assert.match(unavailable.elements.status_summary.textContent, /temporarily unavailable/);
  assert(unavailable.timers.some((timer) => timer.delay === 15000), 'failed requests must retry without a tight loop');

  const invalid = page(async () => ({ ok: true, async json() { return { players: -1, lobbies: 'many' }; } }));
  await settle();
  assert.equal(invalid.elements.server_state.dataset.state, 'retrying', 'invalid server data must not reach the page');

  console.log('landing status tests: PASS (bounded endpoint, stable counters, a11y, refresh and failure states)');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
