#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const indexHtml = fs.readFileSync(path.join(root, 'client', 'index.html'), 'utf8');
const gameHtml = fs.readFileSync(path.join(root, 'client', 'game.html'), 'utf8');
const shareSource = fs.readFileSync(path.join(root, 'client', 'js', 'share.js'), 'utf8');

assert.match(indexHtml, /<form\b[^>]*method="post"[^>]*action="\/quickjoin"/, 'Quick Join must use the POST endpoint');
const targetSelect = indexHtml.match(/<select\b[^>]*name="publicTarget"[\s\S]*?<\/select>/)?.[0];
assert(targetSelect, 'lobby creation must expose a publicTarget select');
const targetValues = [...targetSelect.matchAll(/<option\b[^>]*value="(\d+)"/g)].map((match) => Number(match[1]));
assert.deepEqual(targetValues, [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16], 'publicTarget must only offer unlisted or the 2–16 player bounds');
assert.match(indexHtml, /'no-open-lobby':\s*'No open Quick Join lobby/, 'the empty Quick Join state must explain what failed');

for (const id of ['invite_url', 'share_link', 'copy_link', 'invite_status']) {
  assert(gameHtml.includes(`id="${id}"`), `game page is missing invite control #${id}`);
}
assert(gameHtml.includes('/js/share.js'), 'game page must load the invite interaction script');

function element() {
  const handlers = new Map();
  return {
    value: '',
    textContent: '',
    focused: false,
    selected: false,
    selection: null,
    addEventListener(name, handler) { handlers.set(name, handler); },
    fire(name) { return handlers.get(name)?.({ type: name }); },
    focus() { this.focused = true; },
    select() { this.selected = true; },
    setSelectionRange(start, end) { this.selection = [start, end]; },
  };
}

function page(navigator, execCommand) {
  const elements = Object.fromEntries([
    'invite_url', 'share_link', 'copy_link', 'copy_link_label', 'invite_status',
  ].map((id) => [id, element()]));
  const timers = [];
  const window = {
    location: { origin: 'https://snek.test', pathname: '/game/room%20seven/' },
    navigator,
    clearTimeout() {},
    setTimeout(handler) { timers.push(handler); return timers.length; },
  };
  const document = {
    getElementById(id) { return elements[id] || null; },
    execCommand,
  };
  vm.runInNewContext(shareSource, { window, document, URL, decodeURIComponent, encodeURIComponent }, { filename: 'client/js/share.js' });
  return { elements, timers };
}

(async () => {
  const copied = [];
  const shared = [];
  const native = page({
    clipboard: { async writeText(value) { copied.push(value); } },
    async share(data) { shared.push(data); },
  });

  assert.equal(native.elements.invite_url.value, 'https://snek.test/game/room%20seven', 'invite URL must be canonical and preserve the encoded lobby id');
  await native.elements.copy_link.fire('click');
  assert.deepEqual(copied, ['https://snek.test/game/room%20seven']);
  assert.equal(native.elements.copy_link_label.textContent, 'Copied');
  assert.equal(native.elements.invite_status.textContent, 'Invite link copied.');

  await native.elements.share_link.fire('click');
  assert.equal(JSON.stringify(shared), JSON.stringify([{
    title: 'Join my Snek lobby',
    text: 'Join my Snek lobby.',
    url: 'https://snek.test/game/room%20seven',
  }]));
  assert.equal(native.elements.invite_status.textContent, 'Invite link shared.');

  const shareFallbackCopies = [];
  const fallback = page({
    clipboard: { async writeText(value) { shareFallbackCopies.push(value); } },
  });
  await fallback.elements.share_link.fire('click');
  assert.deepEqual(shareFallbackCopies, ['https://snek.test/game/room%20seven']);
  assert.match(fallback.elements.invite_status.textContent, /copied instead/);

  const manual = page({
    clipboard: { async writeText() { throw new Error('denied'); } },
  }, () => false);
  await manual.elements.copy_link.fire('click');
  assert.equal(manual.elements.invite_url.focused, true);
  assert.equal(manual.elements.invite_url.selected, true);
  assert.deepEqual(manual.elements.invite_url.selection, [0, manual.elements.invite_url.value.length]);
  assert.match(manual.elements.invite_status.textContent, /copy it manually/);

  console.log('discovery/share interaction tests: PASS (POST, bounds, canonical URL, native and fallback sharing)');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
