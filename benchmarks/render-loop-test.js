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
  const particleBursts = [];
  const drawnSprites = [];
  const spriteDraws = [];
  const spriteGetCounts = new Map();
  const rotations = [];
  const radiusMasses = [];
  const arcs = [];
  let wrapHeads = false;
  let decodeCalls = 0;
  let ioDecodeCalls = 0;
  let ioObstacleMask = 7;
  let fillRects = 0;
  let strokes = 0;
  let filterWrites = 0;
  const lineTos = [];
  let rectReads = 0;
  let nameplateMetricReads = 0;
  let nameplatePositionWrites = 0;
  let resizeHandler = null;
  let viewportWidth = 2048;
  let viewportHeight = 1152;
  const Particles = {
    burst(...args) { particlesActive = true; particleBursts.push(args); },
    hasActive() { return particlesActive; },
    update(dt) { particleUpdates += 1; lastParticleDt = dt; },
    draw() {},
  };

  const ctx = {
    set filter(_value) { filterWrites += 1; },
    clearRect() {}, save() {}, restore() {}, translate() {},
    rotate(angle) { rotations.push(angle); },
    drawImage(sprite, ...args) { drawnSprites.push(sprite?.name || 'unknown'); spriteDraws.push([sprite, ...args]); },
    fillRect() { fillRects += 1; }, fill() {}, beginPath() {}, moveTo() {}, lineTo(x, y) { lineTos.push([x, y]); },
    arc(x, y, radius) { arcs.push([x, y, radius]); },
    stroke() { strokes += 1; },
  };
  const canvas = {
    width: 2048,
    height: 1152,
    getContext() { return ctx; },
    addEventListener() {},
    getBoundingClientRect() { rectReads += 1; return { left: 0, top: 0, width: viewportWidth, height: viewportHeight }; },
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

  function decodedIoFrame(playerCount = 3) {
    const foodX = new Uint16Array(16);
    const foodY = new Uint16Array(16);
    const foodMass = new Uint8Array(16);
    foodX[10] = 160;
    foodY[10] = 100;
    foodMass[10] = 10;
    // A feast whose center is just outside the left edge still has visible art.
    foodX[11] = 8082;
    foodY[11] = 100;
    foodMass[11] = 10;
    foodX[12] = 4000;
    foodY[12] = 4000;
    foodMass[12] = 10;
    return {
      playerCount, sequence: 80 + ioDecodeCalls, obstacleMask: ioObstacleMask,
      players: [{
        score: 90, mass: 700, angle: Math.PI, previousAngle: Math.PI - 0.2,
        boosting: true, shielded: true,
        body: [{ x: 100, y: 100 }, { x: 92, y: 100 }],
        previous: [{ x: 92, y: 100 }, { x: 84, y: 100 }],
      }, {
        score: 40, mass: 700, angle: 0, previousAngle: Math.PI * 35 / 18,
        boosting: false, shielded: false,
        // Rotated head/tail corners remain visible beyond their unrotated bounds.
        body: [{ x: 8060, y: 100 }, { x: 8067, y: 100 }],
        previous: [{ x: 8060, y: 100 }, { x: 8067, y: 100 }],
      }, {
        score: 20, mass: 700, angle: 0, previousAngle: 0,
        boosting: false, shielded: false,
        // This snake is wholly outside the viewport and must cost no sprite draws.
        body: [{ x: 7800, y: 100 }, { x: 7792, y: 100 }],
        previous: [{ x: 7800, y: 100 }, { x: 7792, y: 100 }],
      }, {
        score: 5, mass: 80, angle: Math.PI / 18, previousAngle: Math.PI * 35 / 18,
        boosting: false, shielded: false,
        body: [{ x: 220, y: 100 }, { x: 212, y: 100 }],
        previous: [{ x: 212, y: 100 }, { x: 204, y: 100 }],
      }].slice(0, playerCount),
      foodCount: 3, foodSlots: Uint16Array.of(10, 11, 12), foodX, foodY, foodMass,
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
    snakeStyleIndex(color, id) {
      const colors = ['#51cf66', '#ff6b6b', '#fcc419', '#339af0', '#845ef7', '#f6e6c7'];
      const exact = colors.indexOf(String(color).toLowerCase());
      if (exact >= 0) return exact;
      let hash = 2166136261;
      for (let index = 0; index < id.length; index++) hash = Math.imul(hash ^ id.charCodeAt(index), 16777619);
      return (hash >>> 0) % colors.length;
    },
    Sprites: { async load() {}, get(name) {
      spriteGetCounts.set(name, (spriteGetCounts.get(name) || 0) + 1);
      return name.startsWith('io') ? { name, naturalWidth: 128, naturalHeight: 128 } : undefined;
    } },
    Sfx: { muted: false, death() {}, toggle() { return false; } },
    Particles,
    Hud: { init() {}, setMode(mode) { modes.push(mode); }, setMuted() {}, feed() {}, update(players, id, state) { hudUpdates.push({ players, id, state }); }, popScore() {} },
    Motion: { canvas() {}, popup() {} },
    decodeSnapshot(payload) { decodeCalls += 1; return payload === 'valid-frame' ? decodedFrame() : null; },
    decodeIoSnapshot(payload, expectedPlayers) {
      ioDecodeCalls += 1;
      if (payload === 'io-frame' && expectedPlayers === 3) return decodedIoFrame(3);
      if (payload === 'io-frame-four' && expectedPlayers === 4) return decodedIoFrame(4);
      return null;
    },
    IO_OBSTACLES: [[100, 100, 64, 0], [200, 100, 52, 2], [300, 100, 52, 2]],
    IO_OBSTACLE_HITBOX_SCALE: 0.70,
    IO_OBSTACLE_ART: [
      { sprite: 'ioCrate', crop: [22, 19, 84, 89] },
      null,
      { sprite: 'ioMine', crop: [8, 10, 112, 108] },
    ],
    IO_OBSTACLE_HITBOX_SCALE: 0.70,
    IO_PICKUP_SPRITES: [null, null, null, 'ioStrawberry', 'ioApple', 'ioCheese', 'ioDonut', 'ioGoldenApple', 'ioLightning', 'ioRainbow', 'ioFeast'],
    ioFoodGrowth(kind) { return kind === 10 ? 14 : 0; },
    ioInterpolateAngle(previous, current, t) {
      const turn = Math.PI * 2;
      const delta = ((current - previous + Math.PI) % turn + turn) % turn - Math.PI;
      return previous + delta * t;
    },
    ioSnakeRadius(mass) { radiusMasses.push(mass); return mass === 700 ? 21 : 9; },
    releaseBoost() {},
    resetDirection() {},
    setGameMode(mode) { inputModes.push(mode); },
    setGameplayEnabled(enabled) { gameplayStates.push(enabled); },
    getPredictedDirection() { return 'ArrowUp'; },
    getPredictedSteerAngle() { return Math.PI / 4; },
    syncDirection(direction) { directions.push(direction); },
    document: {
      getElementById(id) { return elements[id] ?? null; },
      querySelector() { return {}; },
      createElement() {
        const element = {
          _classes: new Set(), style: {}, hidden: false,
          appendChild() {}, textContent: '',
        };
        Object.defineProperty(element.style, 'translate', {
          set(value) { this._translate = value; nameplatePositionWrites += 1; },
          get() { return this._translate; },
        });
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
      devicePixelRatio: 3,
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

  assert.equal(context.ioDelta(8190, 2), -4, 'world geometry takes the short path across the left seam');
  assert.equal(context.ioDelta(2, 8190), 4, 'world geometry takes the short path across the right seam');
  assert.equal(context.ioPointX({ body: [{ x: 2 }], previous: [{ x: 8190 }] }, 0, 0.5), 0,
    'display interpolation crosses the wrapped seam without traversing the whole arena');
  assert.equal(context.ioDelta(4096, 0), 4096, 'the exact positive half-arena tie stays positive');
  assert.equal(context.ioDelta(0, 4096), -4096, 'the exact negative half-arena tie stays negative');
  assert.equal(context.ioIntersectsViewport(-64, 576, 64), true,
    'an object touching the left viewport edge remains visible');
  assert.equal(context.ioIntersectsViewport(-64.001, 576, 64), false,
    'an object wholly beyond the left viewport edge is culled');
  assert.equal(context.ioIntersectsViewport(2112, 576, 64), true,
    'an object touching the right viewport edge remains visible');
  assert.equal(context.ioIntersectsViewport(2112.001, 576, 64), false,
    'an object wholly beyond the right viewport edge is culled');

  assert.equal(queuedFrames.length, 0, 'the join screen must not start an idle render loop');

  socket.emitEvent('r', [['remote', '長い名前 😀', '#abcdef']]);
  assert.equal(nameplateChildren.length, 1, 'a roster member receives one DOM nameplate');
  assert.equal(nameplateChildren[0].textContent, '長い名前 😀', 'Unicode display names remain exact text');
  socket.emitEvent('r', []);
  assert.equal(nameplateChildren[0].removed, true, 'departed roster members lose their nameplate');

  const lateIoRoster = Array.from({ length: 33 }, (_, index) =>
    [`late-${index}`, `Late ${index}`, '#83bf35']);
  const namesBeforeLateIoRoster = nameplateChildren.length;
  socket.emitEvent('r', lateIoRoster);
  assert.equal(nameplateChildren.length, namesBeforeLateIoRoster + 33,
    'an IO-sized retained roster is accepted even when it arrives before the retained init mode');
  socket.emitEvent('r', []);

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

  const rectReadsBeforeFrame = rectReads;
  queuedFrames.shift()(100);
  assert.equal(queuedFrames.length, 1, 'active play must continuously schedule frames');
  assert.ok(fillRects >= 2, 'Arcade renders one matte remain as a base and highlight');
  assert.ok(strokes >= 1, 'nearest approaching head receives one restrained danger chevron');
  assert.deepEqual(lineTos.at(-2), [158, 108], 'danger feedback stays anchored to the newest visible local head');
  assert.deepEqual(snakeDraws.slice(-2), [
    { id: 'local', t: 1, isLocal: true, localDirection: 'ArrowUp' },
    { id: 'remote', t: 1, isLocal: false, localDirection: null },
  ], 'the first complete remote keyframe renders immediately while local input uses the newest authoritative position');
  assert.equal(rectReads, rectReadsBeforeFrame + 1,
    'the first steady frame reads viewport geometry once before caching it');
  assert.equal(nameplateMetricReads, 4, 'each visible nameplate receives one initial width/height measurement');
  const rectReadsBeforeResize = rectReads;
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
  assert.equal(rectReads, rectReadsBeforeResize + 2,
    'a real viewport resize syncs canvas resolution and refreshes cached geometry once');
  assert.equal(nameplateMetricReads, 8, 'a viewport resize remeasures each responsive nameplate once');
  assert.equal(queuedFrames.length, 1, 'Arcade spectating continues after the particle burst');

  particlesActive = false;
  queuedFrames.shift()(4000);
  assert.equal(particleUpdates, 3);
  assert.equal(rectReads, rectReadsBeforeResize + 2, 'steady animation does not repeat layout reads after resizing');
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

  viewportWidth = 390;
  viewportHeight = 844;
  socket.emitEvent('init', { mode: 'snek_io' });
  assert.equal(gameplayStates.at(-1), true, 'IO steering enables immediately so the moving server snake is never left unattended');
  assert.deepEqual([canvas.width, canvas.height], [390, 844],
    'IO keeps one logical backing pixel per CSS pixel even on high-DPR screens, preserving world scale and bounded fill cost');
  socket.emitEvent('r', [
    ['local', 'Local', '#00aa66'],
    ['edge', 'Edge', '#ffaa44'],
    ['far', 'Far', '#aa66ff'],
  ]);
  socket.emitEvent('b', 'io-frame');
  assert.equal(ioDecodeCalls, 1, 'IO snapshots use the dedicated continuous-world decoder');
  const firstIoSprites = drawnSprites.length;
  const firstIoRotations = rotations.length;
  const firstIoStrokes = strokes;
  const firstIoFilterWrites = filterWrites;
  const firstIoNameplateWrites = nameplatePositionWrites;
  queuedFrames.shift()(4032);
  const renderedIoSprites = drawnSprites.slice(firstIoSprites);
  assert(renderedIoSprites.includes('ioCrate') && renderedIoSprites.includes('ioMine'),
    'live obstacle-mask bits render only their matching crate and spike-bomb art');
  const obstacleDraws = spriteDraws.filter(([sprite]) => sprite?.name === 'ioCrate' || sprite?.name === 'ioMine');
  const crateDraw = obstacleDraws.find(([sprite]) => sprite.name === 'ioCrate');
  const mineDraw = obstacleDraws.find(([sprite]) => sprite.name === 'ioMine');
  assert.deepEqual(crateDraw.slice(1, 5), [22, 19, 84, 89],
    'crate rendering crops its measured transparent source padding');
  assert.deepEqual(mineDraw.slice(1, 5), [8, 10, 112, 108],
    'spike-bomb rendering crops its measured transparent source padding');
  assert.equal(Math.max(crateDraw[7], crateDraw[8]), 128,
    'piñata art uses the full 128px authoritative crate footprint');
  assert(Math.abs(crateDraw[7] / crateDraw[8] - 84 / 89) < 1e-12,
    'piñata art preserves its measured source aspect ratio');
  assert(Math.abs(crateDraw[5] + crateDraw[7] / 2 - 195) < 1e-12 &&
    Math.abs(crateDraw[6] + crateDraw[8] / 2 - 422) < 1e-12,
    'subpixel piñata destination bounds stay centered on the authoritative landmark');
  assert.equal(Math.max(mineDraw[7], mineDraw[8]), 104,
    'spike-bomb art uses the full 104px authoritative mine footprint');
  assert(Math.abs(mineDraw[7] / mineDraw[8] - 112 / 108) < 1e-12,
    'spike-bomb art preserves its measured source aspect ratio');
  assert(Math.abs(mineDraw[5] + mineDraw[7] / 2 - 295) < 1e-12 &&
    Math.abs(mineDraw[6] + mineDraw[8] / 2 - 422) < 1e-12,
    'subpixel mine destination bounds stay centered on the authoritative landmark');
  assert.equal(renderedIoSprites.filter((name) => name === 'ioFeast').length, 2,
    `party pickups stay visible until their actual art clears the viewport (drew ${renderedIoSprites.join(', ')})`);
  assert.equal(spriteGetCounts.get('ioFeast'), 2,
    'offscreen party food is culled before sprite lookup in the 8,192-slot hot path');
  assert(renderedIoSprites.includes('ioHead') && renderedIoSprites.includes('ioTail') && renderedIoSprites.includes('ioBoost'),
    'continuous snakes keep directional head/tail art and visible turbo feedback');
  assert.equal(renderedIoSprites.filter((name) => name === 'ioHead').length, 2,
    'partly visible wide heads render at the edge while wholly offscreen heads are culled');
  assert.equal(renderedIoSprites.filter((name) => name === 'ioTail').length, 2,
    'partly visible wide tails render at the edge while wholly offscreen tails are culled');
  assert(radiusMasses.includes(700), 'render width must be derived from authoritative snake mass');
  assert(rotations.slice(firstIoRotations).some(angle => Math.abs(angle - Math.PI / 4) < 1e-12),
    'the local IO head faces the newest predicted 360-degree angle on the next display frame');
  assert(strokes >= firstIoStrokes + 2, 'the IO grid and active shield each receive a visible stroke');
  assert.equal(filterWrites, firstIoFilterWrites,
    'IO rendering must never apply a full-canvas CSS filter that destroys high-refresh frame pacing');
  assert.equal(nameplatePositionWrites, firstIoNameplateWrites + 1,
    'the visible IO nameplate is positioned only once per display frame');
  assert(arcs.some(([, , radius]) => Math.abs(radius - 21 * 3.05 * 0.72) < 1e-9),
    'the shield ring scales with the same mass-derived head width');
  assert(arcs.some(([, , radius]) => Math.abs(radius - 44.8) < 1e-9) &&
    arcs.some(([, , radius]) => Math.abs(radius - 36.4) < 1e-9),
    'crate and spike-bomb lethal cores are visibly telegraphed exactly');

  const beforeEdgeBurst = particleBursts.length;
  ioObstacleMask = 3;
  socket.emitEvent('b', 'io-frame');
  queuedFrames.shift()(4040);
  assert.equal(particleBursts.length, beforeEdgeBurst + 1,
    'a partly visible obstacle produces destruction feedback when it disappears');
  assert.deepEqual(particleBursts.at(-1).slice(0, 3), [390, 422, '#ed4d50'],
    'edge destruction feedback starts on-screen and retains the obstacle kind');

  viewportWidth = 700;
  viewportHeight = 390;
  resizeHandler();
  assert.deepEqual([canvas.width, canvas.height], [700, 390],
    'IO canvas resolution follows a live orientation change without aspect distortion');

  const beforeObstacleBurst = particleBursts.length;
  ioObstacleMask = 2;
  socket.emitEvent('b', 'io-frame');
  queuedFrames.shift()(4048);
  assert.equal(particleBursts.length, beforeObstacleBurst + 1,
    'one newly depleted obstacle produces exactly one destruction burst');
  assert.deepEqual(particleBursts.at(-1).slice(2), ['#e89a38', 20, 5],
    'destruction feedback retains the removed obstacle kind and bounded particle count');

  const namesBeforePendingRoster = nameplateChildren.length;
  socket.emitEvent('r', [
    ['local', 'Local', '#00aa66'],
    ['edge', 'Edge', '#ffaa44'],
    ['far', 'Far', '#aa66ff'],
    ['bot', 'Maya', '#33bb88'],
  ]);
  assert.equal(nameplateChildren.length, namesBeforePendingRoster,
    'an IO roster update waits for its paired positional snapshot instead of relabeling the old frame');
  socket.emitEvent('b', 'io-frame-four');
  assert.equal(nameplateChildren.length, namesBeforePendingRoster + 1,
    'the validated paired IO snapshot commits its roster atomically');
  socket.emitEvent('b', 'io-frame-four');
  const beforeSmoothHeading = rotations.length;
  queuedFrames.shift()(4064);
  const smoothHeadings = rotations.slice(beforeSmoothHeading);
  assert(smoothHeadings.some(angle => Math.abs(angle - Math.PI * 47 / 24) < 1e-12),
    'a remote IO head interpolates smoothly across the 360-degree seam instead of snapping at 15 Hz');

  socket.emitEvent('disconnect');
  assert.equal(gameplayStates.at(-1), false,
    'transport loss disables boost and steering until a fresh init acknowledgement');
  assert.equal(elements.game_error.style.display, 'block',
    'transport loss gives immediate reconnect feedback');
  assert.equal(nameplateChildren.at(-1).removed, true,
    'transport loss clears stale positional identity state from the old socket');
  queuedFrames.shift()(4080);
  assert.equal(queuedFrames.length, 0,
    'transport loss stops the idle high-refresh render loop instead of repainting a frozen arena');

  socket.emitEvent('init', { mode: 'snek_io' });
  assert.equal(elements.game_error.style.display, 'none',
    'a successful reconnect immediately clears the stale disconnected banner');
  assert.equal(gameplayStates.at(-1), true,
    'a fresh init acknowledgement re-enables the new IO life');
  assert.equal(queuedFrames.length, 1,
    'a successful reconnect restarts display-refresh rendering exactly once');

  console.log('render loop tests: PASS (Arcade/Classical flow; atomic IO rosters, masks, width, smooth 360 facing)');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
