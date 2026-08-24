#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

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

  const keyframe = frame([
    0x53, 0x4e, 3, 0, 1, 0, 1, 0, 1,
    0, 0, 0, 0, 1, 0x80, 2, 3,
    0, 0, 0,
  ], 5);
  const decodedKeyframe = decodeSnapshot(keyframe, 1, null, []);
  assert.ok(decodedKeyframe);
  assert.equal(decodedKeyframe.sequence, 1);
  assert.equal(decodedKeyframe.players[0].cells, 1);
  assert.equal(decodedKeyframe.players[0].bodyOffset, 15);

  const current = [{ score: 0, snake: [{ x: 32, y: 48 }] }];
  const unchanged = frame([0x53, 0x4e, 3, 1, 2, 0, 1, 0, 1, 0, 0, 0, 0]);
  const decodedUnchanged = decodeSnapshot(unchanged, 1, 1, current);
  assert.ok(decodedUnchanged);
  assert.equal(decodedUnchanged.players[0].mode, 0);

  const movedRight = frame([0x53, 0x4e, 3, 1, 3, 0, 2, 0, 1, 0x19, 0, 0, 0]);
  const decodedMove = decodeSnapshot(movedRight, 1, 2, current);
  assert.ok(decodedMove);
  assert.equal(decodedMove.players[0].headX, 3);
  assert.equal(decodedMove.players[0].headY, 3);

  assert.equal(decodeSnapshot(movedRight, 1, 1, current), null, 'dependent delta must reject the wrong base');
  const reservedDirection = frame([0x53, 0x4e, 3, 1, 2, 0, 1, 0, 1, 0x08, 0, 0, 0]);
  assert.equal(decodeSnapshot(reservedDirection, 1, 1, current), null, 'unchanged rows must not carry movement bits');

  const recovery = frame([
    0x53, 0x4e, 3, 0, 10, 0, 10, 0, 1,
    0, 0, 0, 0, 1, 0x80, 4, 3,
    0, 0, 0,
  ]);
  assert.equal(decodeSnapshot(recovery, 1, 2, current)?.sequence, 10, 'independent keyframes must recover any prior sequence');

  console.log('snapshot v3 production decoder tests: PASS');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
