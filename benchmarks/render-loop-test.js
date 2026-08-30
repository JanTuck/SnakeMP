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
  const nameplateChildren = [];
  let particlesActive = false;
  let particleUpdates = 0;
  let lastParticleDt = 0;
  const modes = [];
  const inputModes = [];
  const gameplayStates = [];
  const hudUpdates = [];
  const menus = [];
  const snakeDraws = [];
  const directions = [];
  let wrapHeads = false;
  let decodeCalls = 0;
  let fillRects = 0;
  let strokes = 0;
  const lineTos = [];
  let rectReads = 0;
  let nameplateMetricReads = 0;
  let resizeHandler = null;
  const Particles = {
    burst() { particlesActive = true; },
    hasActive() { return particlesActive; },
    update(dt) { particleUpdates += 1; lastParticleDt = dt; },
    draw() {},
  };

  const ctx = {
    clearRect() {}, save() {}, restore() {}, translate() {}, drawImage() {},
    fillRect() { fillRects += 1; }, beginPath() {}, moveTo() {}, lineTo(x, y) { lineTos.push([x, y]); }, arc() {},
    stroke() { strokes += 1; },
  };
  const canvas = {
    width: 2048,
    height: 1152,
    getContext() { return ctx; },
    addEventListener() {},
    getBoundingClientRect() { rectReads += 1; return { left: 0, top: 0, width: 2048, height: 1152 }; },
  };
  ctx.canvas = canvas;
  const elements = {
    canvas,
    game_error: { style: {}, textContent: '' },
    game_popup: { style: {} },
    hud_mute: { addEventListener() {} },
    nameplates: { hidden: false, appendChild(child) { nameplateChildren.push(child); } },
  };

  class GameOverMenu {
    constructor(_ctx, options = {}) { this.buttonArray = []; this.compact = options.compact === true; menus.push(this); }
    setScore(score) { this.score = score; }
    setReplay(ms) { this.replay = ms; }
    finishReplay() { this.finished = true; }
    draw() {}
    destroy() { this.destroyed = true; }
  }

  class Snake {
    constructor(_ctx, meta) {
      this.id = meta[0]; this.color = meta[2]; this.scale = 16; this.interpolate = true;
      this.snake = [{ x: 0, y: 0 }]; this.prevSnake = [{ x: 0, y: 0 }];
    }
    updateKeyframe(meta) {
      this.prevSnake = this.id === 'local'
        ? [{ x: wrapHeads ? 2032 : 100, y: 100 }]
        : [{ x: 200, y: 100 }];
      this.snake = this.id === 'local'
        ? [{ x: wrapHeads ? 0 : 116, y: 100 }]
        : [{ x: 184, y: 100 }];
    }
    updateDelta(meta) { this.updateKeyframe(meta); }
    draw(t, isLocal, localDirection) { snakeDraws.push({ id: this.id, t, isLocal, localDirection }); }
  }

  function decodedFrame() {
    return {
      playerCount: 2, kind: 0, sequence: decodeCalls, view: {},
      players: [{ score: 0, cells: 1 }, { score: 4, cells: 1 }],
      bonusCount: 0, bonus: [], dropCount: 0, drops: [], hasGolden: false,
      remainsCount: 1, remains: [{ x: 20, y: 20, ttl: 5000 }],
      feastTtl: 2200, hasBounty: true, bountySlot: 1,
    };
  }

  const context = vm.createContext({
    console,
    socket,
    Snake,
    RemoteInterpolationClock: class {
      reset() { this.snapshots = 0; }
      snapshot() { this.snapshots += 1; }
      progress() { return this.snapshots >= 2 ? 0.25 : 1; }
    },
    GameOverMenu,
    Sprites: { async load() {}, get() { return undefined; } },
    Sfx: { muted: false, death() {}, toggle() { return false; } },
    Particles,
    Hud: { init() {}, setMode(mode) { modes.push(mode); }, setMuted() {}, feed() {}, update(players, id, state) { hudUpdates.push({ players, id, state }); }, popScore() {} },
    Motion: { canvas() {}, popup() {} },
    decodeSnapshot(payload) { decodeCalls += 1; return payload === 'valid-frame' ? decodedFrame() : null; },
    releaseBoost() {},
    resetDirection() {},
    setGameMode(mode) { inputModes.push(mode); },
    setGameplayEnabled(enabled) { gameplayStates.push(enabled); },
    getPredictedDirection() { return 'ArrowUp'; },
    syncDirection(direction) { directions.push(direction); },
    document: {
      getElementById(id) { return elements[id]; },
      querySelector() { return {}; },
      createElement() {
        const element = {
          _classes: new Set(), style: {}, hidden: false,
          appendChild() {}, textContent: '',
        };
        Object.defineProperties(element, {
          offsetWidth: { get() { nameplateMetricReads += 1; return 80; } },
          offsetHeight: { get() { nameplateMetricReads += 1; return 28; } },
        });
        element.classList = {
          toggle(name, force) { if (force === false) element._classes.delete(name); else element._classes.add(name); },
          contains(name) { return element._classes.has(name); },
        };
        element.remove = () => { element.removed = true; };
        return element;
      },
    },
    window: {
      location: { reload() {} },
      matchMedia() { return { matches: false }; },
      addEventListener(name, handler) { if (name === 'resize') resizeHandler = handler; },
    },
    performance: { now() { return 100; } },
    requestAnimationFrame(callback) { queuedFrames.push(callback); return queuedFrames.length; },
    setTimeout() { return 1; },
    clearTimeout() {},
  });

  const filename = path.join(__dirname, '..', 'client', 'js', 'rendering.js');
  const source = fs.readFileSync(filename, 'utf8').replace(/^import .*;\n/gm, '');
  await new vm.Script(source, { filename }).runInContext(context);

  assert.equal(queuedFrames.length, 0, 'the join screen must not start an idle render loop');

  socket.emitEvent('r', [['remote', '長い名前 😀', '#abcdef']]);
  assert.equal(nameplateChildren.length, 1, 'a roster member receives one DOM nameplate');
  assert.equal(nameplateChildren[0].textContent, '長い名前 😀', 'Unicode display names remain exact text');
  socket.emitEvent('r', []);
  assert.equal(nameplateChildren[0].removed, true, 'departed roster members lose their nameplate');

  socket.emitEvent('init', { food: { x: 10, y: 20 }, mode: 'classical' });
  assert.deepEqual(modes, ['classical'], 'classical init state must reach the exact HUD mode label');
  assert.equal(queuedFrames.length, 1, 'initial game setup must start rendering');
  socket.emitEvent('init', { food: { x: 10, y: 20 }, mode: 'classical' });
  socket.emitEvent('init', { food: { x: 10, y: 20 }, mode: 'arcade' });
  assert.deepEqual(modes, ['classical', 'classical', 'arcade']);
  assert.deepEqual(inputModes, ['classical', 'classical', 'arcade']);
  assert.equal(gameplayStates.at(-1), true);
  assert.equal(queuedFrames.length, 1, 'repeated setup must not queue duplicate frames');

  socket.emitEvent('r', [
    ['local', 'Local', '#00aa66'],
    ['remote', 'Remote', '#aa3344'],
  ]);
  socket.emitEvent('b', 'valid-frame');
  assert.equal(decodeCalls, 1);
  assert.equal(hudUpdates.at(-1).state.feastTtl, 2200);
  assert.equal(hudUpdates.at(-1).state.bountyId, 'remote');
  assert.equal(directions.at(-1), 'ArrowRight', 'ordinary movement synchronizes the local heading');
  assert.equal(nameplateChildren.at(-2)._classes.has('is-local'), true, 'the local nameplate is explicitly identified');
  assert.equal(nameplateChildren.at(-1)._classes.has('is-local'), false, 'remote nameplates never receive the local marker');
  assert.equal(nameplateChildren.at(-1)._classes.has('is-bounty'), true, 'bounty slot marks the matching unique-id nameplate');

  queuedFrames.shift()(100);
  assert.equal(queuedFrames.length, 1, 'active play must continuously schedule frames');
  assert.ok(fillRects >= 2, 'Arcade renders one matte remain as a base and highlight');
  assert.ok(strokes >= 1, 'nearest approaching head receives one restrained danger chevron');
  assert.deepEqual(lineTos.at(-2), [158, 108], 'danger feedback stays anchored to the newest visible local head');
  assert.deepEqual(snakeDraws.slice(-2), [
    { id: 'local', t: 1, isLocal: true, localDirection: 'ArrowUp' },
    { id: 'remote', t: 1, isLocal: false, localDirection: null },
  ], 'the first complete remote keyframe renders immediately while local input uses the newest authoritative position');
  assert.equal(rectReads, 1, 'steady animation caches the viewport-sized canvas geometry');
  assert.equal(nameplateMetricReads, 4, 'each visible nameplate receives one initial width/height measurement');
  resizeHandler();

  wrapHeads = true;
  socket.emitEvent('b', 'valid-frame');
  assert.equal(directions.at(-1), 'ArrowRight', 'crossing the right seam preserves rightward steering');

  socket.emitEvent('death', { score: 7, focus: { x: 140, y: 120 } });
  assert.equal(menus.at(-1).compact, true, 'Arcade uses the compact spectator retry state');
  assert.equal(elements.nameplates.hidden, false, 'Arcade preserves remote nameplates and the full live board');
  assert.equal(gameplayStates.at(-1), false, 'death disables gameplay input without disabling chat');
  socket.emitEvent('b', 'valid-frame');
  assert.equal(decodeCalls, 3, 'spectators continue applying authoritative snapshots');
  assert.equal(queuedFrames.length, 1, 'death reuses the already pending live-arena frame');
  queuedFrames.shift()(116);
  assert.equal(particleUpdates, 2);
  assert.deepEqual(snakeDraws.slice(-2), [
    { id: 'local', t: 0.25, isLocal: true, localDirection: 'ArrowUp' },
    { id: 'remote', t: 0.25, isLocal: false, localDirection: null },
  ], 'local and remote bodies share smooth presentation time while local steering feedback remains immediate');
  assert.equal(rectReads, 2, 'a real viewport resize refreshes the cached canvas geometry once');
  assert.equal(nameplateMetricReads, 8, 'a viewport resize remeasures each responsive nameplate once');
  assert.equal(queuedFrames.length, 1, 'Arcade spectating continues after the particle burst');

  particlesActive = false;
  queuedFrames.shift()(4000);
  assert.equal(particleUpdates, 3);
  assert.equal(rectReads, 2, 'steady animation does not repeat layout reads after resizing');
  assert.equal(nameplateMetricReads, 8, 'steady animation reuses resized nameplate metrics');
  assert.equal(menus.at(-1).finished, true, 'the 3.5 second wreckage replay resolves into retry state');
  assert.equal(queuedFrames.length, 1, 'the full board stays live after replay');

  socket.emitEvent('init', { food: { x: 30, y: 40 }, mode: 'classical' });
  socket.emitEvent('death', 8);
  assert.equal(menus.at(-1).compact, false, 'Classical retains its established terminal presentation');
  assert.equal(elements.nameplates.hidden, true);
  assert.equal(queuedFrames.length, 1);
  particlesActive = false;
  queuedFrames.shift()(4016);
  assert.equal(queuedFrames.length, 0);
  assert.equal(lastParticleDt, 16, 'terminal rendering does not apply an idle-sized particle step');

  socket.emitEvent('init', { food: { x: 30, y: 40 }, mode: 'classical' });
  assert.equal(queuedFrames.length, 1, 'rejoining after game over must restart active rendering');

  console.log('render loop tests: PASS (arcade remains/bounty/danger/spectating; classical terminal presentation)');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
