#!/usr/bin/env node
/*
 * Project server-to-client snapshot bandwidth when background tabs receive
 * visibility-aware 1 Hz updates instead of the foreground 15 Hz cadence.
 *
 * Override the measured defaults with comma-separated application payload
 * sizes, for example:
 *   SNAPSHOT_BYTES=40,80,160 CLIENTS=12000 node benchmarks/visibility-bandwidth.js
 */
'use strict';

const assert = require('node:assert/strict');

const DEFAULT_SAMPLES = [
  { name: 'v2-baseline', bytes: 24.125925925925927 },
  { name: 'v2-5-bot-ramp', bytes: 72.64444444444445 },
  { name: 'v2-10-bot-ramp', bytes: 118.32592592592593 },
  { name: 'v2-20-bot-ramp', bytes: 127.87407407407407 },
  { name: 'v2-40-bot-ramp', bytes: 157.92830188679244 },
  { name: 'v2-80-bot-ramp', bytes: 158.06666666666666 },
];

function finitePositive(name, raw, fallback) {
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be a positive finite number`);
  return value;
}

function parseSamples(raw) {
  if (raw === undefined || raw.trim() === '') return DEFAULT_SAMPLES;
  return raw.split(',').map((item, index) => ({
    name: `configured-${index + 1}`,
    bytes: finitePositive(`SNAPSHOT_BYTES item ${index + 1}`, item.trim()),
  }));
}

function round(value, digits = 3) {
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

function bandwidth(bytesPerSecond) {
  return {
    bytesPerSecond: round(bytesPerSecond),
    megabitsPerSecond: round(bytesPerSecond * 8 / 1_000_000),
    gibibytesPerHour: round(bytesPerSecond * 3600 / 1024 ** 3),
  };
}

const clients = finitePositive('CLIENTS', process.env.CLIENTS, 12_000);
const foregroundHz = finitePositive('FOREGROUND_HZ', process.env.FOREGROUND_HZ, 15);
const hiddenHz = finitePositive('HIDDEN_HZ', process.env.HIDDEN_HZ, 1);
if (hiddenHz >= foregroundHz) throw new Error('HIDDEN_HZ must be lower than FOREGROUND_HZ');

const samples = parseSamples(process.env.SNAPSHOT_BYTES);
const hiddenRatios = [0.25, 0.50, 0.75, 1.00];
const hiddenClientReduction = 1 - hiddenHz / foregroundHz;

// The requirement is specifically a 15 Hz -> 1 Hz background cadence.
if (foregroundHz === 15 && hiddenHz === 1) {
  assert.ok(Math.abs(hiddenClientReduction - 14 / 15) < 1e-12);
  assert.ok(Math.abs(hiddenClientReduction * 100 - 93.33333333333333) < 1e-10);
}

const projections = samples.map((sample) => {
  const allForegroundBytesPerSecond = clients * foregroundHz * sample.bytes;
  const scenarios = hiddenRatios.map((hiddenRatio) => {
    const foregroundClients = clients * (1 - hiddenRatio);
    const hiddenClients = clients * hiddenRatio;
    const throttledBytesPerSecond = sample.bytes * (
      foregroundClients * foregroundHz + hiddenClients * hiddenHz
    );
    const savedBytesPerSecond = allForegroundBytesPerSecond - throttledBytesPerSecond;
    const savedFraction = savedBytesPerSecond / allForegroundBytesPerSecond;
    const expectedSavedFraction = hiddenRatio * hiddenClientReduction;

    assert.ok(Math.abs(savedFraction - expectedSavedFraction) < 1e-12);
    return {
      hiddenRatioPct: hiddenRatio * 100,
      foregroundClients,
      hiddenClients,
      effectiveSnapshotsPerSecond: foregroundClients * foregroundHz + hiddenClients * hiddenHz,
      throttled: bandwidth(throttledBytesPerSecond),
      saved: bandwidth(savedBytesPerSecond),
      totalBandwidthSavedPct: round(savedFraction * 100, 6),
    };
  });

  assert.ok(Math.abs(
    scenarios.at(-1).throttled.bytesPerSecond - allForegroundBytesPerSecond * hiddenHz / foregroundHz
  ) < 0.001);
  return {
    name: sample.name,
    averageApplicationPayloadBytes: round(sample.bytes, 6),
    allForeground: bandwidth(allForegroundBytesPerSecond),
    scenarios,
  };
});

const output = {
  schemaVersion: 1,
  assumptions: {
    clients,
    foregroundSnapshotHz: foregroundHz,
    hiddenSnapshotHz: hiddenHz,
    hiddenClientSnapshotReductionPct: round(hiddenClientReduction * 100, 6),
    byteScope: 'application snapshot payload only; excludes WebSocket/TCP/IP/TLS framing, control events, and client-to-server inputs',
    clientMix: 'hidden clients receive complete snapshots at the lower cadence; foreground clients remain at full cadence',
    serialization: 'assumes one shared immutable payload per lobby tick, so visibility changes fan-out frequency rather than snapshot encode cost',
    defaultSamples: 'measured v2 payload means from .scratch/bench-zig-raw.json; set SNAPSHOT_BYTES to project other observed or proposed sizes',
    projectionOnly: 'this is deterministic bandwidth arithmetic, not an end-to-end network or CPU benchmark',
  },
  expectedTotalBandwidthSavedPct: {
    hidden25: round(0.25 * hiddenClientReduction * 100, 6),
    hidden50: round(0.50 * hiddenClientReduction * 100, 6),
    hidden75: round(0.75 * hiddenClientReduction * 100, 6),
    hidden100: round(hiddenClientReduction * 100, 6),
  },
  projections,
  assertions: {
    hiddenClientReductionIsFourteenFifteenths: foregroundHz === 15 && hiddenHz === 1,
    everyScenarioMatchesWeightedCadence: true,
    allHiddenMatchesConfiguredCadenceRatio: true,
  },
};

console.log(JSON.stringify(output, null, 2));
