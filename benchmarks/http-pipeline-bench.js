#!/usr/bin/env node
'use strict';

const net = require('node:net');

const base = new URL(process.env.HTTP_PIPELINE_BASE || 'http://127.0.0.1:4917');
const port = Number(base.port || 80);
const host = base.hostname;
const sizes = String(process.env.HTTP_PIPELINE_SIZES || '64,256,1024,2048,4096,6240')
  .split(',').map(Number).filter(Number.isInteger);
const samples = Math.max(1, Number(process.env.HTTP_PIPELINE_SAMPLES || 3));
const pauseReadMs = Number(process.env.HTTP_PIPELINE_PAUSE_READ_MS || 0);
const request = 'X x HTTP/1.1\r\nH:x\r\n\r\n';
const finalRequest = 'X x HTTP/1.1\r\nConnection: close\r\n\r\n';

if (!sizes.length || sizes.some((size) => size < 1 || size > 6240)) {
  throw new Error('HTTP_PIPELINE_SIZES must contain integers from 1 to 6240');
}
if (!Number.isFinite(pauseReadMs) || pauseReadMs < 0) {
  throw new Error('HTTP_PIPELINE_PAUSE_READ_MS must be a non-negative number');
}

function run(count) {
  return new Promise((resolve, reject) => {
    const payload = request.repeat(count - 1) + finalRequest;
    const socket = net.connect(port, host);
    let response = '';
    const started = process.hrtime.bigint();
    const timeout = setTimeout(() => socket.destroy(new Error('pipeline timeout')), 15000);
    // Exercise the normal request-then-FIN path as well as pipeline parsing.
    // A TCP write half-close must not discard already-buffered requests.
    socket.on('connect', () => {
      if (pauseReadMs > 0) {
        socket.pause();
        setTimeout(() => socket.resume(), pauseReadMs);
      }
      socket.end(payload);
    });
    socket.on('data', (chunk) => { response += chunk.toString('latin1'); });
    socket.on('error', reject);
    socket.on('end', () => {
      clearTimeout(timeout);
      const statuses = response.match(/HTTP\/1\.1 404 Not Found/g) || [];
      if (statuses.length !== count) return reject(new Error('received ' + statuses.length + '/' + count + ' ordered responses'));
      resolve(Number(process.hrtime.bigint() - started) / 1e6);
    });
  });
}

(async () => {
  const results = [];
  for (const count of sizes) {
    const times = [];
    for (let sample = 0; sample < samples; sample++) times.push(await run(count));
    times.sort((a, b) => a - b);
    results.push({ requests: count, requestBytes: count === 1 ? finalRequest.length : request.length * (count - 1) + finalRequest.length,
      medianMs: Number(times[Math.floor(times.length / 2)].toFixed(3)), samplesMs: times.map((value) => Number(value.toFixed(3))) });
  }
  console.log(JSON.stringify({ schemaVersion: 1, base: base.href, samples, pauseReadMs, results }, null, 2));
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
