#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const TICK_MS = 1000 / 15;

function near(actual, expected, message, epsilon = 1e-9) {
  assert.ok(Math.abs(actual - expected) <= epsilon,
    `${message}: expected ${expected}, received ${actual}`);
}

(async () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'client', 'js', 'snake.js'), 'utf8');
  const moduleUrl = 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
  const { RemoteInterpolationClock } = await import(moduleUrl);
  assert.equal(typeof RemoteInterpolationClock, 'function',
    'the production remote interpolation clock must remain directly testable');

  const exact = new RemoteInterpolationClock(TICK_MS);
  exact.snapshot(100, 40);
  assert.equal(exact.progress(100), 1, 'the first authoritative state is visible immediately');
  exact.snapshot(100 + TICK_MS, 41);
  near(exact.progress(100 + TICK_MS), 0, 'the first adjacent step begins at its previous endpoint');
  near(exact.progress(100 + TICK_MS * 1.5), 0.5, 'half a server tick advances half a cell');
  near(exact.progress(100 + TICK_MS * 2), 1, 'one server tick advances one cell');

  // The intervals deliberately alternate early and late. Resetting t to zero
  // at these packet times makes a straight snake visibly jump and pause even
  // though requestAnimationFrame itself is running at 60 or 120 Hz.
  const snapshotTimes = [0, 67, 121, 200, 263, 337, 397, 468, 533, 608, 670];

  function sampleAt(refreshHz, label) {
    const clock = new RemoteInterpolationClock(TICK_MS);
    let snapshotIndex = 0;
    let state = 0;
    clock.snapshot(snapshotTimes[0], 500);

    // Verify every adjacent snapshot rebases without changing the straight-
    // line screen position at the instant the authoritative endpoints shift.
    for (let index = 1; index < snapshotTimes.length; index++) {
      const at = snapshotTimes[index];
      const before = (state - 1) + clock.progress(at);
      clock.snapshot(at, 500 + index);
      state += 1;
      const after = (state - 1) + clock.progress(at);
      near(after, before, `snapshot ${index} must not create a visible position jump`);
    }

    clock.reset();
    state = 0;
    snapshotIndex = 1;
    clock.snapshot(snapshotTimes[0], 500);
    const samples = [];
    const frameMs = 1000 / refreshHz;
    for (let now = 0; now <= snapshotTimes.at(-1); now += frameMs) {
      while (snapshotIndex < snapshotTimes.length && snapshotTimes[snapshotIndex] <= now) {
        clock.snapshot(snapshotTimes[snapshotIndex], 500 + snapshotIndex);
        state += 1;
        snapshotIndex += 1;
      }
      // Each new snapshot changes the segment basis from [n-1,n] to [n,n+1].
      // The clock's rebased t must therefore preserve this absolute position.
      samples.push({ now, position: (state - 1) + clock.progress(now) });
    }

    const active = samples.filter((sample) => sample.now >= snapshotTimes[1] + frameMs);
    const deltas = active.slice(1).map((sample, index) => sample.position - active[index].position);
    const expectedStep = frameMs / TICK_MS;
    for (const delta of deltas) {
      assert.ok(delta > 0, `${refreshHz} Hz ${label} motion must not freeze or reverse between frames`);
      near(delta, expectedStep, `${refreshHz} Hz ${label} straight motion keeps an even per-frame step`, 1e-8);
    }
    return { samples: active, expectedStep };
  }

  const remote60 = sampleAt(60, 'remote');
  const local60 = sampleAt(60, 'local');
  const remote120 = sampleAt(120, 'remote');
  const local120 = sampleAt(120, 'local');
  assert.deepEqual(local60.samples, remote60.samples,
    'local and remote straight-line presentation must be identical at 60 Hz');
  assert.deepEqual(local120.samples, remote120.samples,
    'local and remote straight-line presentation must be identical at 120 Hz');
  near(remote60.expectedStep, 0.25, '60 Hz renders four equal frames per server cell');
  near(remote120.expectedStep, 0.125, '120 Hz renders eight equal frames per server cell');

  const bounded = new RemoteInterpolationClock(TICK_MS);
  bounded.snapshot(0, 65535);
  bounded.snapshot(TICK_MS, 0);
  near(bounded.progress(TICK_MS), 0, 'sequence wrap remains an adjacent update');
  near(bounded.progress(TICK_MS * 20), 1.35,
    'a delayed packet receives only bounded extrapolation rather than unbounded drift');
  bounded.snapshot(TICK_MS * 20, 4);
  assert.equal(bounded.progress(TICK_MS * 20), 1,
    'a sequence gap resets to the complete authoritative recovery state');
  bounded.reset();
  assert.equal(bounded.progress(10_000), 1, 'reset cannot leave stale interpolation running');

  console.log('local/remote motion tests: PASS (60/120 Hz, jitter continuity, bounded recovery)');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
