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
  press('ArrowLeft');
  press('ArrowRight');
  press('ArrowUp');
  press('ArrowDown');
  press('KeyD');
  press('KeyW');
  press('KeyA');
  press('KeyS');
  assert.deepEqual(directions(), [
    'ArrowLeft', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown',
    'ArrowRight', 'ArrowUp', 'ArrowLeft', 'ArrowDown',
  ], 'all non-repeat directions are forwarded absolutely for server validation');

  const beforeRepeat = emitted.length;
  assert.equal(press('KeyS', true), true, 'repeated arrows remain prevented from scrolling');
  assert.equal(emitted.length, beforeRepeat, 'OS key-repeat does not enqueue input');

  delete global.document;
  delete global.socket;
  console.log('absolute input control tests: PASS');
})().catch((error) => {
  delete global.document;
  delete global.socket;
  console.error(error.stack || error);
  process.exitCode = 1;
});
