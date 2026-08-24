#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  let keydown;
  const emitted = [];
  global.document = {
    addEventListener(name, handler) {
      if (name === 'keydown') keydown = handler;
    },
  };
  global.socket = {
    emit(name, value) { emitted.push([name, value]); },
  };

  const source = fs.readFileSync(path.join(__dirname, '..', 'client', 'js', 'userInput.js'), 'utf8');
  const moduleUrl = 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
  const input = await import(moduleUrl);
  assert.equal(typeof keydown, 'function');
  assert.equal(input.ARROW_LEFT, 'ArrowLeft');

  function press(code, repeat = false, target = undefined) {
    let prevented = false;
    keydown({ code, repeat, target, preventDefault() { prevented = true; } });
    return prevented;
  }
  const directions = () => emitted.map((entry) => entry[1]);

  assert.equal(press('Escape'), false, 'unrelated keys must remain untouched');
  assert.equal(press('KeyW', false, { tagName: 'input', isContentEditable: false }), false,
    'typing in the username input must not steer or suppress text');
  assert.equal(press('ArrowLeft', false, { tagName: 'span', isContentEditable: true }), false,
    'contenteditable controls must not steer or suppress editing');
  assert.deepEqual(directions(), []);
  assert.equal(press('ArrowLeft'), true);
  assert.deepEqual(directions(), ['ArrowLeft'], 'a stationary snake may start left');
  input.resetDirection();

  const steeringCases = [
    ['ArrowUp', 'ArrowLeft', 'ArrowRight'],
    ['ArrowRight', 'ArrowUp', 'ArrowDown'],
    ['ArrowDown', 'ArrowLeft', 'ArrowRight'],
    ['ArrowLeft', 'ArrowDown', 'ArrowUp'],
  ];
  for (const [heading, left, right] of steeringCases) {
    input.resetDirection();
    input.syncDirection(heading);
    const before = emitted.length;
    press('ArrowLeft');
    assert.equal(emitted[before][1], left, `${heading}: left arrow resolves to the intended turn`);
    input.resetDirection();
    input.syncDirection(heading);
    press('ArrowRight');
    assert.equal(emitted[before + 1][1], right, `${heading}: right arrow resolves to the intended turn`);
  }

  input.resetDirection();
  input.syncDirection('ArrowRight');
  const rapidStart = emitted.length;
  press('ArrowLeft');  // right -> up
  press('ArrowRight'); // queued up -> right
  press('ArrowLeft');  // queue is full; do not drift beyond server capacity
  assert.deepEqual(directions().slice(rapidStart), ['ArrowUp', 'ArrowRight'],
    'rapid relative turns compose from queued intent and mirror the server queue limit');
  input.syncDirection('ArrowRight'); // stale old-heading snapshot: preserve intent
  press('ArrowLeft');
  assert.deepEqual(directions().slice(rapidStart), ['ArrowUp', 'ArrowRight'],
    'an old snapshot cannot reinterpret or overfill queued relative turns');
  input.syncDirection('ArrowUp');
  press('ArrowLeft'); // queued right -> up, now that one queue slot is free
  assert.deepEqual(directions().slice(rapidStart), ['ArrowUp', 'ArrowRight', 'ArrowUp'],
    'acknowledging a turn frees one predictor slot without losing the next turn');

  input.resetDirection();
  input.syncDirection('ArrowRight');
  const absoluteStart = emitted.length;
  press('KeyA'); // immediate reverse
  press('KeyD'); // unchanged heading
  press('KeyW'); // legal absolute turn
  press('KeyS'); // reverse of the queued turn
  assert.deepEqual(directions().slice(absoluteStart), ['ArrowUp'],
    'absolute WASD remains available while same-heading and reversal inputs are suppressed');

  const beforeRepeat = emitted.length;
  assert.equal(press('KeyS', true), true, 'repeated arrows remain prevented from scrolling');
  assert.equal(emitted.length, beforeRepeat, 'OS key-repeat does not enqueue input');

  delete global.document;
  delete global.socket;
  console.log('horizontal-aware steering input tests: PASS');
})().catch((error) => {
  delete global.document;
  delete global.socket;
  console.error(error.stack || error);
  process.exitCode = 1;
});
