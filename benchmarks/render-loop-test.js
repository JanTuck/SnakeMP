#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

(async () => {
  const particleSource = fs.readFileSync(path.join(__dirname, '..', 'client', 'js', 'particles.js'), 'utf8');
  const { Particles: productionParticles } = await import(
    'data:text/javascript;base64,' + Buffer.from(particleSource).toString('base64')
  );
  assert.equal(productionParticles.hasActive(), false);
  productionParticles.burst(0, 0, '#fff', 1, 0);
  assert.equal(productionParticles.hasActive(), true);
  for (let iteration = 0; iteration < 20; iteration++) productionParticles.update(50);
  assert.equal(productionParticles.hasActive(), false, 'particle activity must clear after the tail expires');

  const handlers = new Map();
  const socket = {
    id: 'local',
    on(name, handler) { handlers.set(name, handler); },
    emitEvent(name, value) { handlers.get(name)?.(value); },
  };

  const queuedFrames = [];
  let particlesActive = false;
  let particleUpdates = 0;
  let lastParticleDt = 0;
  const Particles = {
    burst() { particlesActive = true; },
    hasActive() { return particlesActive; },
    update(dt) { particleUpdates += 1; lastParticleDt = dt; },
    draw() {},
  };

  const ctx = {
    clearRect() {}, save() {}, restore() {}, translate() {}, drawImage() {},
  };
  const canvas = {
    width: 1920,
    height: 960,
    getContext() { return ctx; },
    addEventListener() {},
    getBoundingClientRect() { return { left: 0, top: 0, width: 1920, height: 960 }; },
  };
  ctx.canvas = canvas;
  const elements = {
    canvas,
    game_error: { style: {}, textContent: '' },
    game_popup: { style: {} },
    hud_mute: { addEventListener() {} },
  };

  class GameOverMenu {
    constructor() { this.buttonArray = []; }
    setScore() {}
    draw() {}
  }

  const context = vm.createContext({
    console,
    socket,
    Snake: class {},
    GameOverMenu,
    Sprites: { async load() {}, get() { return undefined; } },
    Sfx: { muted: false, death() {}, toggle() { return false; } },
    Particles,
    Hud: { init() {}, setMuted() {}, feed() {}, update() {}, popScore() {} },
    Motion: { canvas() {}, popup() {} },
    decodeSnapshot() { return null; },
    document: {
      getElementById(id) { return elements[id]; },
      querySelector() { return {}; },
    },
    window: { location: { reload() {} } },
    performance: { now() { return 100; } },
    requestAnimationFrame(callback) { queuedFrames.push(callback); return queuedFrames.length; },
    setTimeout() { return 1; },
    clearTimeout() {},
  });

  const filename = path.join(__dirname, '..', 'client', 'js', 'rendering.js');
  const source = fs.readFileSync(filename, 'utf8').replace(/^import .*;\n/gm, '');
  await new vm.Script(source, { filename }).runInContext(context);

  assert.equal(queuedFrames.length, 0, 'the join screen must not start an idle render loop');

  socket.emitEvent('init', { food: { x: 10, y: 20 } });
  assert.equal(queuedFrames.length, 1, 'initial game setup must start rendering');
  socket.emitEvent('init', { food: { x: 10, y: 20 } });
  assert.equal(queuedFrames.length, 1, 'repeated setup must not queue duplicate frames');

  queuedFrames.shift()(100);
  assert.equal(queuedFrames.length, 1, 'active play must continuously schedule frames');

  socket.emitEvent('death', 7);
  assert.equal(queuedFrames.length, 1, 'death must reuse the already pending active-game frame');
  queuedFrames.shift()(116);
  assert.equal(particleUpdates, 2);
  assert.equal(queuedFrames.length, 1, 'game over must render while particles remain active');

  particlesActive = false;
  queuedFrames.shift()(132);
  assert.equal(particleUpdates, 3);
  assert.equal(queuedFrames.length, 0, 'the loop must stop after the game-over particle tail drains');

  socket.emitEvent('death', 8);
  assert.equal(queuedFrames.length, 1, 'a later render-producing event must restart an idle loop');
  particlesActive = false;
  queuedFrames.shift()(10_000);
  assert.equal(queuedFrames.length, 0);
  assert.equal(lastParticleDt, 16, 'restarting an idle loop must not apply the whole idle gap to fresh particles');

  socket.emitEvent('init', { food: { x: 30, y: 40 } });
  assert.equal(queuedFrames.length, 1, 'rejoining after game over must restart active rendering');

  console.log('render loop tests: PASS (idle start, active cadence, particle drain, event restart)');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
