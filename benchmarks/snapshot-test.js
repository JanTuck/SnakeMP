#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { decodeBinary } = require('./protocol');

function frame(bytes, prefix = 0) {
  const storage = new Uint8Array(prefix + bytes.length + 3);
  storage.set(bytes, prefix);
  return storage.subarray(prefix, prefix + bytes.length);
}

(async () => {
  // Import the exact browser ESM source without changing the repository's
  // CommonJS package mode.
  const source = fs.readFileSync(path.join(__dirname, '..', 'client', 'js', 'snapshot.js'), 'utf8');
  const moduleUrl = 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
  const { decodeSnapshot } = await import(moduleUrl);
  const snakeSource = fs.readFileSync(path.join(__dirname, '..', 'client', 'js', 'snake.js'), 'utf8');
  const { default: Snake, SNAKE_STYLE_COLORS, snakeStyleIndex } = await import('data:text/javascript;base64,' + Buffer.from(snakeSource).toString('base64'));
  assert.deepEqual(SNAKE_STYLE_COLORS.map((color, index) => snakeStyleIndex(color, 'same-player')), [0, 1, 2, 3, 4, 5],
    'every server-authoritative roster color resolves to its selected snake look');
  assert.equal(snakeStyleIndex('#123456', 'stable-id'), snakeStyleIndex('#123456', 'stable-id'),
    'legacy colors use stable identity fallback rather than roster position');
  const massWorkerSource = fs.readFileSync(path.join(__dirname, 'mass-worker.js'), 'utf8');
  assert.match(massWorkerSource, /\(header & 0x40\) !== 0/,
    'mass decoder must reserve only bit 6 of the v5 header');
  assert.match(massWorkerSource, /const players = header & 0x3f/,
    'mass decoder must preserve the full six-bit v5 player count');

  const keyframe = frame([
    0x53, 0x4e, 5, 1, 0, 1,
    0, 0, 0, 0, 1, 0x80, 2, 3, 0,
  ], 5);
  const decodedKeyframe = decodeSnapshot(keyframe, 1, null, []);
  assert.ok(decodedKeyframe);
  assert.equal(decodedKeyframe.sequence, 1);
  assert.equal(decodedKeyframe.players[0].cells, 1);
  assert.equal(decodedKeyframe.players[0].bodyOffset, 12);
  const benchmarkKeyframe = decodeBinary(keyframe, [['id', 'name', '#123456']], null, null);
  assert.ok(benchmarkKeyframe, 'benchmark decoder must accept the production keyframe layout');
  assert.deepEqual(benchmarkKeyframe.world.players[0].snake, [{ x: 32, y: 48 }]);

  const maximumRoster = Array.from({ length: 32 }, (_, index) => [`id-${index}`, `Player ${index}`, '#123456']);
  const maximumKeyframe = [0x53, 0x4e, 5, 1, 0, 32];
  for (let index = 0; index < 32; index++) {
    maximumKeyframe.push(0, 0, 0, 0, 1, 0x80, index, index);
  }
  maximumKeyframe.push(0);
  assert.equal(decodeSnapshot(frame(maximumKeyframe), 32, null, []).playerCount, 32,
    'browser decoder must accept the full 32-player roster');
  assert.equal(decodeBinary(frame(maximumKeyframe), maximumRoster, null, null)?.world.players.length, 32,
    'benchmark decoder must accept the full 32-player roster');

  const boardEdge = frame([
    0x53, 0x4e, 5, 1, 0, 1,
    0, 0, 0, 0, 1, 0x80, 127, 71, 0,
  ]);
  assert.ok(decodeSnapshot(boardEdge, 1, null, []), '128 x 72 board must accept its final cell');
  assert.deepEqual(
    decodeBinary(boardEdge, [['id', 'name', '#123456']], null, null)?.world.players[0].snake,
    [{ x: 2032, y: 1136 }],
    'benchmark decoder must map the final cell into the 2048 x 1152 playfield',
  );
  const beyondBoard = frame([
    0x53, 0x4e, 5, 1, 0, 1,
    0, 0, 0, 0, 1, 0x80, 128, 72, 0,
  ]);
  assert.equal(decodeSnapshot(beyondBoard, 1, null, []), null, 'cell 128,72 must remain outside the board');
  assert.equal(decodeBinary(beyondBoard, [['id', 'name', '#123456']], null, null), null,
    'benchmark decoder must reject coordinates outside the canonical board');

  const current = [{ score: 0, snake: [{ x: 32, y: 48 }] }];
  const unchanged = frame([0x53, 0x4e, 5, 2, 0, 0x81, 0, 0]);
  const decodedUnchanged = decodeSnapshot(unchanged, 1, 1, current);
  assert.ok(decodedUnchanged);
  assert.equal(decodedUnchanged.players[0].mode, 0);

  const movedRight = frame([0x53, 0x4e, 5, 3, 0, 0x81, 0x19, 0]);
  const decodedMove = decodeSnapshot(movedRight, 1, 2, current);
  assert.ok(decodedMove);
  assert.equal(decodedMove.players[0].headX, 3);
  assert.equal(decodedMove.players[0].headY, 3);

  const longCurrent = [{
    score: 0,
    snake: [5, 4, 3, 2, 1].map(x => ({ x: x * 16, y: 3 * 16 })),
  }];
  const doubleShrink = frame([0x53, 0x4e, 5, 2, 0, 0x81, 0x3b, 0]);
  const decodedDoubleShrink = decodeSnapshot(doubleShrink, 1, 1, longCurrent);
  assert.ok(decodedDoubleShrink, 'straight two-cell shrink delta must decode');
  assert.equal(decodedDoubleShrink.players[0].mode, 3);
  assert.equal(decodedDoubleShrink.players[0].steps, 2);
  assert.equal(decodedDoubleShrink.players[0].cells, 4);
  assert.equal(decodedDoubleShrink.players[0].headX, 7);
  const boostedSnake = new Snake({ canvas: {} }, ['id', 'name', '#123456']);
  boostedSnake.snake = longCurrent[0].snake.map(cell => ({ ...cell }));
  boostedSnake.updateDelta(['id', 'name', '#123456'], decodedDoubleShrink.players[0]);
  assert.deepEqual(boostedSnake.snake, [7, 6, 5, 4].map(x => ({ x: x * 16, y: 3 * 16 })),
    'browser reconstruction must preserve both boosted head positions while shedding the tail');
  const benchmarkDoubleShrink = decodeBinary(
    doubleShrink,
    [['id', 'name', '#123456']],
    { players: [{ id: 'id', displayName: 'name', color: '#123456', score: 0, snake: longCurrent[0].snake }] },
    1,
  );
  assert.deepEqual(benchmarkDoubleShrink?.world.players[0].snake,
    [7, 6, 5, 4].map(x => ({ x: x * 16, y: 3 * 16 })),
    'benchmark reconstruction must match the browser for boosted shrink deltas');

  const unchangedDouble = frame([0x53, 0x4e, 5, 2, 0, 0x81, 0x20, 0]);
  assert.equal(decodeSnapshot(unchangedDouble, 1, 1, current), null,
    'unchanged rows cannot claim a double step');
  const shrinkSingleton = frame([0x53, 0x4e, 5, 2, 0, 0x81, 0x03, 0]);
  assert.equal(decodeSnapshot(shrinkSingleton, 1, 1, current), null,
    'shrink deltas cannot remove the final snake cell');

  assert.equal(decodeSnapshot(movedRight, 1, 1, current), null, 'dependent delta must be the wrapping successor of the accepted sequence');
  const reservedDirection = frame([0x53, 0x4e, 5, 2, 0, 0x81, 0x08, 0]);
  assert.equal(decodeSnapshot(reservedDirection, 1, 1, current), null, 'unchanged rows must not carry movement bits');

  const reservedHeader = frame([0x53, 0x4e, 5, 2, 0, 0xc1, 0, 0]);
  assert.equal(decodeSnapshot(reservedHeader, 1, 1, current), null, 'header padding bits must be zero');
  const emptyArcadeExtension = frame([0x53, 0x4e, 5, 2, 0, 0x81, 0, 0x80, 0]);
  assert.ok(decodeSnapshot(emptyArcadeExtension, 1, 1, current), 'world bit 7 selects the bounded Arcade extension');

  const packedPadding = frame([
    0x53, 0x4e, 5, 9, 0, 1,
    0, 0, 0, 0, 2, 0x80, 2, 3, 0xff, 0,
  ]);
  assert.equal(decodeSnapshot(packedPadding, 1, null, []), null, 'unused packed-body direction bits must be zero');
  assert.equal(decodeBinary(packedPadding, [['id', 'name', '#123456']], null, null), null,
    'benchmark decoder must reject packed-body padding too');

  const wrapped = frame([0x53, 0x4e, 5, 0, 0, 0x81, 0, 0]);
  assert.ok(decodeSnapshot(wrapped, 1, 0xffff, current), 'delta sequence continuity must wrap from 65535 to zero');

  const recovery = frame([
    0x53, 0x4e, 5, 10, 0, 1,
    0, 0, 0, 0, 1, 0x80, 4, 3, 0,
  ]);
  assert.equal(decodeSnapshot(recovery, 1, 2, current)?.sequence, 10, 'independent keyframes must recover any prior sequence');

  const packedWorld = frame([
    0x53, 0x4e, 5, 7, 0, 0,
    0x51, 4, 5, 6, 7, 0x6e, 0x04, 8, 9, 0x7d, 0x10,
  ]);
  const decodedWorld = decodeSnapshot(packedWorld, 0, null, []);
  assert.ok(decodedWorld);
  assert.equal(decodedWorld.bonusCount, 1);
  assert.deepEqual(decodedWorld.bonus[0], { x: 4, y: 5 });
  assert.equal(decodedWorld.dropCount, 1);
  assert.deepEqual(decodedWorld.drops[0], { x: 6, y: 7, ttl: 1134 });
  assert.equal(decodedWorld.hasGolden, true);
  assert.equal(decodedWorld.goldenX, 8);
  assert.equal(decodedWorld.goldenY, 9);
  assert.equal(decodedWorld.goldenTtl, 4221);
  const benchmarkWorld = decodeBinary(packedWorld, [], null, null);
  assert.ok(benchmarkWorld, 'benchmark decoder must accept packed world metadata');
  assert.deepEqual(benchmarkWorld.world.golden, { x: 128, y: 144, ttl: 4221 });

  const arcadeFrame = frame([
    0x53, 0x4e, 5, 8, 0, 1,
    0, 0, 0, 0, 1, 0x80, 2, 3,
    0x80, 0xc2,
    4, 5, 0x64, 0, 6, 7, 0xff, 0xff,
    0x96, 0, 0,
  ]);
  const decodedArcade = decodeSnapshot(arcadeFrame, 1, null, []);
  assert.ok(decodedArcade, 'Arcade keyframe extension must decode');
  assert.equal(decodedArcade.remainsCount, 2);
  assert.deepEqual(decodedArcade.remains[0], { x: 4, y: 5, ttl: 100 });
  assert.deepEqual(decodedArcade.remains[1], { x: 6, y: 7, ttl: 65535 });
  assert.equal(decodedArcade.feastActive, true);
  assert.equal(decodedArcade.feastTtl, 150);
  assert.equal(decodedArcade.hasBounty, true);
  assert.equal(decodedArcade.bountySlot, 0);

  for (let cut = arcadeFrame.byteLength - 1; cut >= arcadeFrame.byteLength - 4; cut--) {
    assert.equal(decodeSnapshot(arcadeFrame.subarray(0, cut), 1, null, []), null,
      'truncated optional Arcade fields must reject the complete frame');
  }
  const badRemainCell = Uint8Array.from(arcadeFrame);
  badRemainCell[16] = 128;
  assert.equal(decodeSnapshot(badRemainCell, 1, null, []), null, 'out-of-board remains must reject the frame');
  const badBountySlot = Uint8Array.from(arcadeFrame);
  badBountySlot[badBountySlot.length - 1] = 1;
  assert.equal(decodeSnapshot(badBountySlot, 1, null, []), null, 'bounty slot must name a player in this frame');
  const trailingArcade = new Uint8Array(arcadeFrame.length + 1);
  trailingArcade.set(arcadeFrame);
  assert.equal(decodeSnapshot(trailingArcade, 1, null, []), null, 'trailing Arcade bytes must reject the frame');

  const maximumRemains = [0x53, 0x4e, 5, 11, 0, 0, 0x80, 0x3f];
  for (let index = 0; index < 63; index++) maximumRemains.push(index % 128, index % 72, index, 0);
  const decodedMaximum = decodeSnapshot(frame(maximumRemains), 0, null, []);
  assert.ok(decodedMaximum, 'the negotiated 63-remain boundary must decode');
  assert.equal(decodedMaximum.remainsCount, 63);

  const missingRemain = frame([0x53, 0x4e, 5, 12, 0, 0, 0x80, 2, 1, 1, 1, 0]);
  assert.equal(decodeSnapshot(missingRemain, 0, null, []), null, 'declared remains must all be present');

  const plainAfterArcade = decodeSnapshot(frame([0x53, 0x4e, 5, 13, 0, 0, 0]), 0, null, []);
  assert.ok(plainAfterArcade);
  assert.equal(plainAfterArcade.remainsCount, 0, 'legacy-mode snapshots clear prior Arcade extension state');
  assert.equal(plainAfterArcade.feastActive, false);
  assert.equal(plainAfterArcade.hasBounty, false);

  const recoveredSnake = new Snake({ canvas: {} }, ['id', 'name', '#123456']);
  recoveredSnake.snake = [{ x: 10 * 16, y: 10 * 16 }];
  // Head (18,11), then neck (18,10): a recovery jump must decode the packed
  // body but remain too large for visual interpolation.
  const recoveryBody = new DataView(Uint8Array.from([18, 11, 0]).buffer);
  recoveredSnake.updateKeyframe(['id', 'name', '#123456'], recoveryBody, {
    cells: 2, packed: true, bodyOffset: 0, score: 0,
  });
  assert.equal(recoveredSnake.interpolate, false, 'multi-tick recovery must not interpolate');

  console.log('snapshot v5 production decoder tests: PASS');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
