#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  const preference = { matches: false };
  let requestedQuery = null;
  global.window = {
    matchMedia(query) {
      requestedQuery = query;
      return preference;
    },
  };

  const source = fs.readFileSync(path.join(__dirname, '..', 'client', 'js', 'hud.js'), 'utf8');
  const moduleUrl = 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
  const { Motion, Hud } = await import(moduleUrl);
  assert.equal(requestedQuery, '(prefers-reduced-motion: reduce)');

  function target() {
    const calls = [];
    return {
      calls,
      animate(keyframes, timing) {
        calls.push({ keyframes, timing });
        return { keyframes, timing };
      },
    };
  }

  const feed = target();
  Motion.feed(feed);
  assert.deepEqual(feed.calls, [{
    keyframes: [
      { translate: '24px 0', opacity: 0.65 },
      { translate: '0 0', opacity: 1 },
    ],
    timing: { duration: 280, easing: 'cubic-bezier(0.165, 0.84, 0.44, 1)' },
  }], 'feed transition must preserve its displacement, fade, duration, and Power3-out curve');

  const score = target();
  Motion.score(score);
  Motion.score(score);
  assert.equal(score.calls.length, 2, 'repeated score events must each start a fresh animation');
  assert.deepEqual(score.calls[0], {
    keyframes: [{ scale: 1.06 }, { scale: 1 }],
    timing: { duration: 220, easing: 'cubic-bezier(0.165, 0.84, 0.44, 1)' },
  });

  const canvas = target();
  Motion.canvas(canvas);
  assert.deepEqual(canvas.calls[0], {
    keyframes: [{ opacity: 0.4 }, { opacity: 1 }],
    timing: { duration: 400, easing: 'cubic-bezier(0.333333, 0.666667, 0.666667, 1)' },
  }, 'canvas reveal must retain GSAP default Quad-out timing');

  const popup = target();
  Motion.popup(popup);
  assert.deepEqual(popup.calls[0], {
    keyframes: [
      { translate: '0 -50px', opacity: 0 },
      { translate: '0 0', opacity: 1 },
    ],
    timing: { duration: 500, easing: 'cubic-bezier(0.333333, 1.533333, 0.666667, 1)' },
  }, 'popup entrance must retain the 50px Back-out(1.6) choreography');
  assert.equal(Motion.popup(null), null, 'missing optional popup is a safe no-op');

  preference.matches = true;
  const reduced = target();
  assert.equal(Motion.feed(reduced), null);
  assert.equal(Motion.score(reduced), null);
  assert.equal(Motion.canvas(reduced), null);
  assert.equal(Motion.popup(reduced), null);
  assert.equal(reduced.calls.length, 0, 'reduced-motion preference must suppress every transition');

  preference.matches = false;
  assert.equal(Motion.feed({}), null, 'animation remains progressive enhancement without Element.animate');

  const elements = new Map();
  function element() {
    const classes = new Set();
    return {
      textContent: '', hidden: false, title: '', dataset: {},
      children: [],
      append(...children) { this.children.push(...children); },
      prepend(...children) { this.children.unshift(...children); },
      get lastElementChild() { return this.children.at(-1) || null; },
      remove() { this.removed = true; },
      setAttribute(name, value) { this[name] = value; },
      classList: {
        toggle(name, force) {
          if (force === false) classes.delete(name); else if (force === true || !classes.has(name)) classes.add(name); else classes.delete(name);
        },
        contains(name) { return classes.has(name); },
      },
    };
  }
  for (const id of ['hud', 'hud_score', 'hud_board', 'hud_you', 'hud_points', 'hud_length', 'hud_rows', 'hud_feed', 'hud_mute', 'hud_mode']) {
    elements.set(id, element());
  }
  global.document = {
    getElementById(id) { return elements.get(id) || null; },
    createElement() { return element(); },
  };
  Hud.setMode('classical');
  Hud.init();
  assert.equal(elements.get('hud_mode').textContent, 'Classical', 'mode received before HUD initialization must be retained');
  assert.match(elements.get('hud_board')['aria-label'], /special pickups are disabled/);
  Hud.setMode('arcade');
  assert.equal(elements.get('hud_mode').textContent, 'Arcade');
  assert.match(elements.get('hud_board')['aria-label'], /Arcade/);
  Hud.setMode('arcade');
  assert.equal(elements.get('hud_mode').textContent, 'Arcade');
  Hud.update([
    { id: 'leader', displayName: 'Leader', score: 8, snake: [{ x: 0, y: 0 }] },
    { id: 'me', displayName: 'Me', score: 3, snake: [{ x: 16, y: 0 }] },
  ], 'me', { feastTtl: 2200, bountyId: 'leader' });
  assert.equal(elements.get('hud_mode').textContent, 'Feast · 3s', 'feast temporarily replaces only the Arcade mode label');
  assert.equal(elements.get('hud_rows').children[0].classList.contains('hud-bounty'), true);
  assert.match(elements.get('hud_rows').children[0]['aria-label'], /bounty/);
  Hud.update([
    { id: 'leader', displayName: 'Leader', score: 8, snake: [{ x: 0, y: 0 }] },
  ], 'departed-player', { feastTtl: 0, bountyId: null });
  assert.equal(elements.get('hud_rows').children[0].children[0].textContent, 'Leader');
  assert.equal(elements.get('hud_rows').children[1].hidden, true,
    'a death roster shrink hides the vacated rank instead of retaining a duplicate survivor');
  Hud.setMode('classical');
  assert.equal(elements.get('hud_rows').children[0].classList.contains('hud-bounty'), false, 'Classical clears Arcade bounty treatment');

  const originalTimeout = global.setTimeout;
  const originalClearTimeout = global.clearTimeout;
  global.setTimeout = () => 1;
  global.clearTimeout = () => {};
  Hud.setMode('arcade');
  Hud.feed({ type: 'kill', killerId: 'killer-id', killer: 'Hunter', victimId: 'victim-id', who: 'Runner', streak: 3 });
  assert.equal(elements.get('hud_feed').children[0].children[1].textContent, 'Hunter cut off Runner — 3 streak');
  assert.equal(elements.get('hud_feed').children[0].className, 'hud-feed-item is-kill');
  global.setTimeout = originalTimeout;
  global.clearTimeout = originalClearTimeout;

  delete global.document;
  delete global.window;
  console.log('native motion/HUD tests: PASS (motion, exact modes, feast, bounty, unique-id kill feed)');
})().catch((error) => {
  delete global.document;
  delete global.window;
  console.error(error.stack || error);
  process.exitCode = 1;
});
