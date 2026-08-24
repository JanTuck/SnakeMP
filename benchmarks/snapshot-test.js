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
  const { default: Snake } = await import('data:text/javascript;base64,' + Buffer.from(snakeSource).toString('base64'));

  const keyframe = frame([
    0x53, 0x4e, 4, 1, 0, 1,
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

  const current = [{ score: 0, snake: [{ x: 32, y: 48 }] }];
  const unchanged = frame([0x53, 0x4e, 4, 2, 0, 0x81, 0, 0]);
  const decodedUnchanged = decodeSnapshot(unchanged, 1, 1, current);
  assert.ok(decodedUnchanged);
  assert.equal(decodedUnchanged.players[0].mode, 0);

  const movedRight = frame([0x53, 0x4e, 4, 3, 0, 0x81, 0x19, 0]);
  const decodedMove = decodeSnapshot(movedRight, 1, 2, current);
  assert.ok(decodedMove);
  assert.equal(decodedMove.players[0].headX, 3);
  assert.equal(decodedMove.players[0].headY, 3);

  assert.equal(decodeSnapshot(movedRight, 1, 1, current), null, 'dependent delta must be the wrapping successor of the accepted sequence');
  const reservedDirection = frame([0x53, 0x4e, 4, 2, 0, 0x81, 0x08, 0]);
  assert.equal(decodeSnapshot(reservedDirection, 1, 1, current), null, 'unchanged rows must not carry movement bits');

  const reservedHeader = frame([0x53, 0x4e, 4, 2, 0, 0xa1, 0, 0]);
  assert.equal(decodeSnapshot(reservedHeader, 1, 1, current), null, 'header padding bits must be zero');
  const reservedWorld = frame([0x53, 0x4e, 4, 2, 0, 0x81, 0, 0x80]);
  assert.equal(decodeSnapshot(reservedWorld, 1, 1, current), null, 'world padding bit must be zero');

  const packedPadding = frame([
    0x53, 0x4e, 4, 9, 0, 1,
    0, 0, 0, 0, 2, 0x80, 2, 3, 0xff, 0,
  ]);
  assert.equal(decodeSnapshot(packedPadding, 1, null, []), null, 'unused packed-body direction bits must be zero');
  assert.equal(decodeBinary(packedPadding, [['id', 'name', '#123456']], null, null), null,
    'benchmark decoder must reject packed-body padding too');

  const wrapped = frame([0x53, 0x4e, 4, 0, 0, 0x81, 0, 0]);
  assert.ok(decodeSnapshot(wrapped, 1, 0xffff, current), 'delta sequence continuity must wrap from 65535 to zero');

  const recovery = frame([
    0x53, 0x4e, 4, 10, 0, 1,
    0, 0, 0, 0, 1, 0x80, 4, 3, 0,
  ]);
  assert.equal(decodeSnapshot(recovery, 1, 2, current)?.sequence, 10, 'independent keyframes must recover any prior sequence');

  const packedWorld = frame([
    0x53, 0x4e, 4, 7, 0, 0,
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

  const recoveredSnake = new Snake({ canvas: {} }, ['id', 'name', '#123456']);
  recoveredSnake.snake = [{ x: 10 * 16, y: 10 * 16 }];
  // Head (18,11), then neck (18,10): a recovery jump must decode the packed
  // body but remain too large for visual interpolation.
  const recoveryBody = new DataView(Uint8Array.from([18, 11, 0]).buffer);
  recoveredSnake.updateKeyframe(['id', 'name', '#123456'], recoveryBody, {
    cells: 2, packed: true, bodyOffset: 0, score: 0,
  });
  assert.equal(recoveredSnake.interpolate, false, 'multi-tick recovery must not interpolate');

  console.log('snapshot v4 production decoder tests: PASS');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
