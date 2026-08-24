#!/usr/bin/env node
'use strict';

// Focused end-to-end regression for browser visibility delivery hints. Run a
// built server first and set BENCH_BASE if it is not listening on :3000.
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { performance } = require('node:perf_hooks');

const base = new URL(process.env.BENCH_BASE || 'http://127.0.0.1:3000');
const wsUrl = `${base.protocol === 'https:' ? 'wss:' : 'ws:'}//${base.host}/ws`;
const socket = new WebSocket(wsUrl);
const frames = [];
let identified = false;

function wait(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
async function waitUntil(predicate, timeoutMs, label) {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error(`timeout waiting for ${label}`);
    await wait(10);
  }
}

function joinPacket(name, lobby) {
  const username = Buffer.from(name);
  const lobbyId = Buffer.from(lobby);
  return Buffer.concat([Buffer.from([1, lobbyId.length, username.length]), lobbyId, username]);
}

function snapshotHeader(data) {
  if (data.length < 9 || data[0] !== 0x53 || data[1] !== 0x4e || data[2] !== 3) return null;
  const kind = data[3];
  if (kind > 1) return null;
  const item = { at: performance.now(), kind, sequence: data.readUInt16LE(4), head: null };
  // A one-player keyframe starts with score:i32, cells:u16, then absolute head.
  if (kind === 0 && data[8] === 1 && data.length >= 17) item.head = `${data[15]},${data[16]}`;
  return item;
}

socket.on('message', (data, isBinary) => {
  const bytes = Buffer.from(data);
  // ws 7.x does not consistently provide the isBinary callback argument.
  // The production payload has an unambiguous magic prefix, matching the
  // compatibility check in benchmarks/socket.js.
  if (isBinary === true || (bytes.length >= 2 && bytes[0] === 0x53 && bytes[1] === 0x4e)) {
    const header = snapshotHeader(bytes);
    if (header !== null) frames.push(header);
    return;
  }
  try {
    const event = JSON.parse(String(data));
    if (event[0] === 'id') identified = true;
  } catch (_) {}
});

(async () => {
  await new Promise((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
  });
  await waitUntil(() => identified, 1_000, 'server identity');
  socket.send(Buffer.from([3, 1]));
  // Production usernames are capped at 16 code points. Keep the regression
  // identity valid even on hosts with long process ids.
  socket.send(joinPacket(`v-${process.pid}`.slice(0, 16), '12345'));
  await waitUntil(() => frames.some((frame) => frame.kind === 0), 2_000, 'initial keyframe');

  const foregroundStart = frames.length;
  await wait(1_200);
  const foregroundFrames = frames.length - foregroundStart;
  assert.ok(foregroundFrames >= 12, `foreground cadence too low: ${foregroundFrames} frames/1.2s`);

  socket.send(Buffer.from([3, 0]));
  await wait(150); // discard a frame already in flight when the hint was sent
  const hiddenStart = frames.length;
  const steering = setInterval(() => socket.send(Buffer.from([2, 1 + ((Math.floor(performance.now() / 600)) & 3)])), 600);
  await wait(2_400);
  clearInterval(steering);
  const hidden = frames.slice(hiddenStart);
  assert.ok(hidden.length >= 2 && hidden.length <= 3, `hidden cadence was ${hidden.length} frames/2.4s`);
  assert.ok(hidden.every((frame) => frame.kind === 0), 'hidden clients must only receive independent keyframes');
  const heads = new Set(hidden.map((frame) => frame.head).filter(Boolean));
  assert.ok(heads.size >= 2, 'authoritative snake simulation did not advance while hidden');

  const visibleAt = performance.now();
  const visibleStart = frames.length;
  socket.send(Buffer.from([3, 1]));
  await waitUntil(() => frames.slice(visibleStart).some((frame) => frame.kind === 0), 350, 'foreground resync keyframe');
  const recovery = frames.slice(visibleStart);
  const keyframe = recovery.find((frame) => frame.kind === 0);
  assert.ok(keyframe.at - visibleAt < 350, 'foreground keyframe was not prompt');
  await waitUntil(() => frames.slice(visibleStart).some((frame) => frame.kind === 1), 500, 'post-resync delta');

  socket.close();
  console.log(JSON.stringify({
    status: 'PASS',
    foregroundFramesPer1_2s: foregroundFrames,
    hiddenFramesPer2_4s: hidden.length,
    hiddenKinds: hidden.map((frame) => frame.kind),
    hiddenDistinctHeads: heads.size,
    visibleResyncMs: Math.round((keyframe.at - visibleAt) * 1000) / 1000,
  }, null, 2));
})().catch((error) => {
  socket.close();
  console.error(error.stack || error);
  process.exitCode = 1;
});
