#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  const documentHandlers = new Map();
  const windowHandlers = new Map();
  const emitted = [];
  const animationFrames = [];
  const boostHandlers = new Map();
  const boostAttributes = new Map([['aria-pressed', 'false']]);
  let canvasRectReads = 0;
  const boostButton = {
    tagName: 'BUTTON', hidden: true, disabled: true, capturedPointer: null,
    addEventListener(name, handler) {
      let handlers = boostHandlers.get(name);
      if (!handlers) boostHandlers.set(name, handlers = []);
      handlers.push(handler);
    },
    setAttribute(name, value) { boostAttributes.set(name, value); },
    setPointerCapture(pointerId) { this.capturedPointer = pointerId; },
  };
  const canvasSurface = {
    // A 2x backing store with an offset, non-square CSS rect proves steering
    // uses the displayed board center rather than window/backing dimensions.
    width: 1600,
    height: 800,
    getBoundingClientRect() {
      canvasRectReads += 1;
      return { left: 100, top: 50, width: 800, height: 400 };
    },
  };
  global.document = {
    hidden: false,
    getElementById(id) { return id === 'io_boost' ? boostButton : id === 'canvas' ? canvasSurface : null; },
    addEventListener(name, handler) {
      let handlers = documentHandlers.get(name);
      if (!handlers) documentHandlers.set(name, handlers = []);
      handlers.push(handler);
    },
  };
  global.window = {
    addEventListener(name, handler) { windowHandlers.set(name, handler); },
  };
  global.innerWidth = 1000;
  global.innerHeight = 800;
  global.requestAnimationFrame = (handler) => {
    animationFrames.push(handler);
    return animationFrames.length;
  };
  global.socket = {
    emit(name, value) { emitted.push([name, value]); },
  };

  const source = fs.readFileSync(path.join(__dirname, '..', 'client', 'js', 'userInput.js'), 'utf8');
  const moduleUrl = 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
  const input = await import(moduleUrl);
  assert.equal(documentHandlers.get('keydown').length, 2);
  assert.equal(input.ARROW_LEFT, 'ArrowLeft');

  function press(code, repeat = false, target = undefined) {
    let prevented = false;
    const event = { code, repeat, target, preventDefault() { prevented = true; } };
    for (const handler of documentHandlers.get('keydown')) handler(event);
    return prevented;
  }
  function release(code, target = undefined) {
    let prevented = false;
    const event = { code, target, preventDefault() { prevented = true; } };
    for (const handler of documentHandlers.get('keyup')) handler(event);
    return prevented;
  }
  function point(clientX, clientY, target = undefined) {
    const event = { clientX, clientY, target };
    for (const handler of documentHandlers.get('pointermove')) handler(event);
  }
  function touchBoost(name, pointerId = 7) {
    let prevented = false;
    const event = {
      pointerId, target: boostButton, currentTarget: boostButton,
      preventDefault() { prevented = true; },
    };
    for (const handler of boostHandlers.get(name) || []) handler(event);
    if (name === 'pointerdown') {
      for (const handler of documentHandlers.get('pointerdown') || []) handler(event);
    }
    return prevented;
  }
  function flushPointerFrame() {
    const handler = animationFrames.shift();
    assert.equal(typeof handler, 'function', 'pointer steering must schedule one display-refresh flush');
    handler();
  }
  const directions = () => emitted.filter((entry) => entry[0] === 'keyPress').map((entry) => entry[1]);

  assert.equal(press('ArrowLeft'), false, 'gameplay input starts disabled while the join dialog is open');
  input.setGameplayEnabled(true);

  assert.equal(press('Escape'), false, 'unrelated keys must remain untouched');
  assert.equal(press('KeyW', false, { tagName: 'input', isContentEditable: false }), false,
    'typing in the username input must not steer or suppress text');
  assert.equal(press('ArrowLeft', false, { tagName: 'span', isContentEditable: true }), false,
    'contenteditable controls must not steer or suppress editing');
  assert.deepEqual(directions(), []);
  assert.equal(press('ArrowLeft'), true);
  assert.deepEqual(directions(), ['ArrowLeft'], 'a stationary snake may start left');
  input.resetDirection();

  for (const heading of ['ArrowUp', 'ArrowDown']) {
    input.resetDirection();
    input.syncDirection(heading);
    const before = emitted.length;
    press('ArrowLeft');
    assert.equal(emitted[before][1], 'ArrowLeft', `${heading}: left remains an absolute direction`);
    input.resetDirection();
    input.syncDirection(heading);
    press('ArrowRight');
    assert.equal(emitted[before + 1][1], 'ArrowRight', `${heading}: right remains an absolute direction`);
  }

  input.resetDirection();
  input.syncDirection('ArrowRight');
  assert.equal(input.getPredictedDirection(), 'ArrowRight', 'rendering starts from the authoritative heading');
  const rapidStart = emitted.length;
  press('ArrowLeft');  // opposite: ignored
  press('ArrowRight'); // unchanged: ignored
  press('ArrowUp');
  assert.equal(input.getPredictedDirection(), 'ArrowUp', 'accepted input is visible to rendering synchronously');
  press('ArrowRight');
  assert.equal(input.getPredictedDirection(), 'ArrowUp', 'the visible heading follows the next authoritative queued turn');
  press('ArrowDown');  // queue is full; do not drift beyond server capacity
  assert.deepEqual(directions().slice(rapidStart), ['ArrowUp', 'ArrowRight'],
    'horizontal left/right no longer remap, while absolute turns mirror the server queue limit');
  input.syncDirection('ArrowRight'); // stale old-heading snapshot: preserve intent
  press('ArrowLeft');
  assert.deepEqual(directions().slice(rapidStart), ['ArrowUp', 'ArrowRight'],
    'an old snapshot cannot reinterpret or overfill queued absolute turns');
  input.syncDirection('ArrowUp');
  assert.equal(input.getPredictedDirection(), 'ArrowRight', 'the second queued turn becomes visible after the first is acknowledged');
  press('ArrowDown'); // reverse of queued right is allowed only after it becomes perpendicular
  assert.deepEqual(directions().slice(rapidStart), ['ArrowUp', 'ArrowRight', 'ArrowDown'],
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

  input.setGameMode('classical');
  const beforeClassicalSpace = emitted.length;
  assert.equal(press('Space'), false, 'Classical keeps Space untouched');
  assert.equal(emitted.length, beforeClassicalSpace);

  input.setGameMode('arcade');
  assert.equal(press('Space', false, { tagName: 'input' }), false, 'Space remains usable in form fields');
  const beforeChatButton = emitted.length;
  assert.equal(press('Space', false, { tagName: 'button' }), false,
    'Space on the persistent Chat button remains available for native activation');
  assert.equal(press('ArrowUp', false, { tagName: 'button' }), false,
    'focused game controls do not steer the snake');
  assert.equal(emitted.length, beforeChatButton, 'game control keys never leak into movement or boost');
  assert.equal(press('Space'), true, 'Arcade captures held boost');
  assert.deepEqual(emitted.at(-1), ['boost', true]);
  press('Space', true);
  assert.deepEqual(emitted.slice(-1), [['boost', true]], 'repeat cannot duplicate boost-on');
  assert.equal(release('Space'), true);
  assert.deepEqual(emitted.at(-1), ['boost', false]);

  press('Space');
  windowHandlers.get('blur')();
  assert.deepEqual(emitted.at(-1), ['boost', false], 'window blur releases held boost');
  press('Space');
  global.document.hidden = true;
  for (const handler of documentHandlers.get('visibilitychange')) handler();
  assert.deepEqual(emitted.at(-1), ['boost', false], 'hidden tabs release held boost');
  global.document.hidden = false;

  input.setGameMode('snek_io');
  assert.equal(boostButton.hidden, false, 'active IO play exposes the touch boost control');
  assert.equal(boostButton.disabled, false, 'active IO play enables the touch boost control');
  const beforeTouchBoost = emitted.length;
  assert.equal(touchBoost('pointerdown'), true, 'touch boost prevents browser hold gestures');
  assert.equal(boostButton.capturedPointer, 7, 'touch boost keeps release events when the finger drifts');
  assert.deepEqual(emitted.slice(beforeTouchBoost), [['boost', true]], 'pressing touch boost uses the normal boost event');
  assert.equal(boostAttributes.get('aria-pressed'), 'true', 'the held state is exposed to assistive technology');
  assert.equal(touchBoost('pointerup'), true);
  assert.deepEqual(emitted.slice(beforeTouchBoost), [['boost', true], ['boost', false]], 'releasing touch boost clears boost exactly once');
  assert.equal(boostAttributes.get('aria-pressed'), 'false');
  touchBoost('pointerdown', 8);
  touchBoost('pointercancel', 8);
  assert.deepEqual(emitted.slice(-2), [['boost', true], ['boost', false]], 'cancelled touch gestures cannot leave boost held');
  touchBoost('pointerdown', 9);
  input.setGameMode('arcade');
  assert.deepEqual(emitted.slice(-2), [['boost', true], ['boost', false]],
    'a mode change releases touch boost even when its pointer-up was lost');
  assert.equal(boostAttributes.get('aria-pressed'), 'false');
  input.setGameMode('snek_io');
  const ioStart = emitted.length;
  assert.equal(press('ArrowUp'), false, 'IO reserves keyboard directions for continuous pointer steering');
  assert.equal(emitted.length, ioStart, 'grid inputs cannot leak into the continuous IO controller');

  const steeringCases = [
    [900, 250, 0, 'right cardinal'],
    [900, 650, 8192, 'down-right diagonal'],
    [500, 650, 16384, 'down cardinal'],
    [100, 650, 24576, 'down-left diagonal'],
    [100, 250, 32768, 'left cardinal'],
    [100, -150, 40959, 'up-left diagonal'],
    [500, -150, 49151, 'up cardinal'],
    [900, -150, 57343, 'up-right diagonal'],
  ];
  for (const [x, y, expected, label] of steeringCases) {
    point(x, y);
    assert(Math.abs(input.getPredictedSteerAngle() - expected / 65535 * Math.PI * 2) < 1e-12,
      `${label} must update head-facing feedback before the next network flush`);
    flushPointerFrame();
    assert.deepEqual(emitted.at(-1), ['steer', expected], `${label} must retain its absolute u16 angle`);
  }
  assert.equal(canvasRectReads, 1,
    'high-rate pointer samples reuse one displayed-canvas center without repeated layout reads');

  point(900, 250 - 1e-9);
  flushPointerFrame();
  assert.deepEqual(emitted.at(-1), ['steer', 65535], 'the clockwise seam must reach the final u16 quantum');
  point(900, 250);
  flushPointerFrame();
  assert.deepEqual(emitted.at(-1), ['steer', 0], 'the seam wraps cleanly back to zero');

  const beforeCoalesced = emitted.length;
  point(900, 250);
  point(500, 650);
  point(100, 250);
  assert.equal(animationFrames.length, 1, 'many pointer samples within one display frame coalesce into one send');
  flushPointerFrame();
  assert.equal(emitted.length, beforeCoalesced + 1);
  assert.deepEqual(emitted.at(-1), ['steer', 32768], 'the newest coalesced pointer angle wins');

  const beforeEditingPointer = emitted.length;
  point(900, 250, { tagName: 'input', isContentEditable: false });
  assert.equal(animationFrames.length, 0, 'form interaction cannot schedule steering');
  assert.equal(emitted.length, beforeEditingPointer);

  point(900, 250);
  const beforeBlurredFlush = emitted.length;
  windowHandlers.get('blur')();
  flushPointerFrame();
  assert.equal(emitted.length, beforeBlurredFlush,
    'a steer queued before window blur cannot turn the snake while unfocused');

  point(900, 250);
  const beforeHiddenFlush = emitted.length;
  global.document.hidden = true;
  for (const handler of documentHandlers.get('visibilitychange')) handler();
  global.document.hidden = false;
  flushPointerFrame();
  assert.equal(emitted.length, beforeHiddenFlush,
    'a steer queued before tab hiding cannot turn the snake in the background');

  point(900, 250);
  const beforeCrossLifeFlush = emitted.length;
  input.setGameplayEnabled(false);
  input.setGameplayEnabled(true);
  flushPointerFrame();
  assert.equal(emitted.length, beforeCrossLifeFlush,
    'a steer queued before death or disconnect cannot fire into a newly initialized life');
  input.setGameplayEnabled(false);
  assert.equal(boostButton.hidden, true, 'dead, spectating, and pre-play IO states hide touch boost');
  assert.equal(boostButton.disabled, true, 'inactive IO states disable touch boost for keyboard and screen readers');
  const beforeDisabled = emitted.length;
  assert.equal(press('ArrowUp'), false, 'death disables steering without affecting the chat keyboard');
  assert.equal(press('Space'), false, 'death disables boost without swallowing Space');
  assert.equal(emitted.length, beforeDisabled);
  input.resetDirection();
  assert.equal(input.getPredictedSteerAngle(), null, 'death/rejoin reset cannot retain a stale IO head angle');

  delete global.document;
  delete global.socket;
  delete global.window;
  delete global.innerWidth;
  delete global.innerHeight;
  delete global.requestAnimationFrame;
  console.log('absolute steering input tests: PASS');
})().catch((error) => {
      delete global.document;
      delete global.socket;
      delete global.window;
      delete global.innerWidth;
      delete global.innerHeight;
      delete global.requestAnimationFrame;
  console.error(error.stack || error);
  process.exitCode = 1;
});
