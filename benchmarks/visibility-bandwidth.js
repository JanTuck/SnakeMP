#!/usr/bin/env node
/*
 * Project server-to-client snapshot bandwidth when background tabs receive
 * visibility-aware keyframes at 1 Hz instead of the foreground 15 Hz stream.
 *
 * Delta and keyframe payloads differ substantially in snapshot v3, so they
 * must be supplied separately. Comma-separated lists are paired by position:
 *   DELTA_BYTES=28,32 KEYFRAME_BYTES=220,300 CLIENTS=12000 \
 *     node benchmarks/visibility-bandwidth.js
 */
'use strict';

const assert = require('node:assert/strict');

// The 18-cell sample is the representative production-encoder measurement in
// docs/BENCHMARKS.md. Its 34.40 B periodic-stream mean consists of a 220 B
// keyframe every 30 frames and 28 B dependent deltas.
const DEFAULT_SAMPLES = [
  { name: 'v3-16-player-18-cell', deltaBytes: 28, keyframeBytes: 220 },
];

function finitePositive(name, raw, fallback) {
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be a positive finite number`);
  return value;
}

function parseByteList(name, raw) {
  return raw.split(',').map((item, index) => finitePositive(`${name} item ${index + 1}`, item.trim()));
}

function parseSamples(deltaRaw, keyframeRaw) {
  if (deltaRaw === undefined && keyframeRaw === undefined) return DEFAULT_SAMPLES;
  if (deltaRaw === undefined || keyframeRaw === undefined) {
    throw new Error('DELTA_BYTES and KEYFRAME_BYTES must be configured together');
  }
  const deltas = parseByteList('DELTA_BYTES', deltaRaw);
  const keyframes = parseByteList('KEYFRAME_BYTES', keyframeRaw);
  if (deltas.length !== keyframes.length) {
    throw new Error('DELTA_BYTES and KEYFRAME_BYTES must contain the same number of items');
  }
  return deltas.map((deltaBytes, index) => ({
    name: `configured-${index + 1}`,
    deltaBytes,
    keyframeBytes: keyframes[index],
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
const keyframeInterval = finitePositive('KEYFRAME_INTERVAL', process.env.KEYFRAME_INTERVAL, 30);
if (!Number.isSafeInteger(keyframeInterval)) throw new Error('KEYFRAME_INTERVAL must be a positive integer');
if (hiddenHz >= foregroundHz) throw new Error('HIDDEN_HZ must be lower than FOREGROUND_HZ');

const samples = parseSamples(process.env.DELTA_BYTES, process.env.KEYFRAME_BYTES);
const hiddenRatios = [0.25, 0.50, 0.75, 1.00];
const foregroundKeyframeHz = foregroundHz / keyframeInterval;
const foregroundDeltaHz = foregroundHz - foregroundKeyframeHz;

const projections = samples.map((sample) => {
  const foregroundBytesPerClientSecond =
    foregroundDeltaHz * sample.deltaBytes + foregroundKeyframeHz * sample.keyframeBytes;
  const hiddenBytesPerClientSecond = hiddenHz * sample.keyframeBytes;
  const hiddenClientReduction = 1 - hiddenBytesPerClientSecond / foregroundBytesPerClientSecond;
  const allForegroundBytesPerSecond = clients * foregroundBytesPerClientSecond;

  const scenarios = hiddenRatios.map((hiddenRatio) => {
    const foregroundClients = clients * (1 - hiddenRatio);
    const hiddenClients = clients * hiddenRatio;
    const foregroundDeltaBytesPerSecond = foregroundClients * foregroundDeltaHz * sample.deltaBytes;
    const foregroundKeyframeBytesPerSecond = foregroundClients * foregroundKeyframeHz * sample.keyframeBytes;
    const hiddenKeyframeBytesPerSecond = hiddenClients * hiddenHz * sample.keyframeBytes;
    const throttledBytesPerSecond = foregroundDeltaBytesPerSecond
      + foregroundKeyframeBytesPerSecond
      + hiddenKeyframeBytesPerSecond;
    const savedBytesPerSecond = allForegroundBytesPerSecond - throttledBytesPerSecond;
    const savedFraction = savedBytesPerSecond / allForegroundBytesPerSecond;
    const expectedSavedFraction = hiddenRatio * hiddenClientReduction;

    assert.ok(Math.abs(savedFraction - expectedSavedFraction) < 1e-12);
    return {
      hiddenRatioPct: hiddenRatio * 100,
      foregroundClients,
      hiddenClients,
      effectiveSnapshotsPerSecond: foregroundClients * foregroundHz + hiddenClients * hiddenHz,
      payloadBreakdown: {
        foregroundDeltas: bandwidth(foregroundDeltaBytesPerSecond),
        foregroundKeyframes: bandwidth(foregroundKeyframeBytesPerSecond),
        hiddenKeyframes: bandwidth(hiddenKeyframeBytesPerSecond),
      },
      throttled: bandwidth(throttledBytesPerSecond),
      saved: bandwidth(savedBytesPerSecond),
      totalBandwidthSavedPct: round(savedFraction * 100, 6),
    };
  });

  assert.ok(Math.abs(
    scenarios.at(-1).throttled.bytesPerSecond - clients * hiddenBytesPerClientSecond
  ) < 0.001);
  return {
    name: sample.name,
    applicationPayloadBytes: {
      delta: round(sample.deltaBytes, 6),
      keyframe: round(sample.keyframeBytes, 6),
      foregroundPeriodicMean: round(foregroundBytesPerClientSecond / foregroundHz, 6),
    },
    perClient: {
      foregroundBytesPerSecond: round(foregroundBytesPerClientSecond, 6),
      hiddenBytesPerSecond: round(hiddenBytesPerClientSecond, 6),
      hiddenClientBandwidthReductionPct: round(hiddenClientReduction * 100, 6),
    },
    allForeground: bandwidth(allForegroundBytesPerSecond),
    expectedTotalBandwidthSavedPct: {
      hidden25: round(0.25 * hiddenClientReduction * 100, 6),
      hidden50: round(0.50 * hiddenClientReduction * 100, 6),
      hidden75: round(0.75 * hiddenClientReduction * 100, 6),
      hidden100: round(hiddenClientReduction * 100, 6),
    },
    scenarios,
  };
});

const output = {
  schemaVersion: 2,
  assumptions: {
    clients,
    foregroundSnapshotHz: foregroundHz,
    foregroundDeltaHz: round(foregroundDeltaHz, 6),
    foregroundKeyframeHz: round(foregroundKeyframeHz, 6),
    foregroundKeyframeIntervalSnapshots: keyframeInterval,
    hiddenKeyframeHz: hiddenHz,
    byteScope: 'application snapshot payload only; excludes WebSocket/TCP/IP/TLS framing, control events, and client-to-server inputs',
    clientMix: 'foreground clients receive the periodic delta/keyframe stream; hidden clients receive only independent keyframes at the lower cadence',
    serialization: 'assumes one shared immutable payload per lobby tick, so visibility changes fan-out frequency rather than snapshot encode cost',
    defaultSamples: 'snapshot v3 production encoder, 16 players with 18 cells each: 220 B keyframe and derived 28 B delta (34.40 B mean with one keyframe per 30 snapshots)',
    projectionOnly: 'this is deterministic bandwidth arithmetic, not an end-to-end network or CPU benchmark',
  },
  projections,
  assertions: {
    foregroundRateMixSumsToConfiguredCadence: Math.abs(foregroundDeltaHz + foregroundKeyframeHz - foregroundHz) < 1e-12,
    everyScenarioMatchesPayloadWeightedMix: true,
    allHiddenUsesConfiguredKeyframeCadence: true,
  },
};

console.log(JSON.stringify(output, null, 2));
