/* Samples RSS / CPU / threads / FDs of a server PID until interrupted.
 * Usage: node benchmarks/sample-metrics.js <pid> <out.json> [intervalMs=200]
 * Writes summary JSON on SIGINT/SIGTERM (or when the PID dies).
 */
const fs = require('fs');
const childProcess = require('child_process');

const pid = parseInt(process.argv[2], 10);
const out = process.argv[3];
const interval = parseInt(process.argv[4] || '200', 10);
const CLK_TCK = (() => {
  try {
    return Number(childProcess.execFileSync('getconf', ['CLK_TCK'], { encoding: 'utf8' }).trim()) || 100;
  } catch (_) {
    return 100;
  }
})();

const samples = [];
let lastCpu = null;
let running = true;

function statusField(status, key) {
  const marker = key + ':';
  const line = status.split('\n').find((l) => l.startsWith(marker));
  return line ? line.slice(marker.length).trim() : '';
}

function tick() {
  if (!running) return;
  const now = Date.now();
  try {
    const status = fs.readFileSync('/proc/' + pid + '/status', 'utf8');
    const rssKb = parseInt(statusField(status, 'VmRSS'), 10) || 0;
    const threads = parseInt(statusField(status, 'Threads'), 10) || 0;
    let fds = 0;
    try { fds = fs.readdirSync('/proc/' + pid + '/fd').length; } catch (e) { fds = -1; }
    let cpuPct = 0;
    try {
      const stat = fs.readFileSync('/proc/' + pid + '/stat', 'utf8');
      const rest = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
      const cpuTicks = parseInt(rest[11], 10) + parseInt(rest[12], 10);
      if (lastCpu) {
        const dt = (now - lastCpu.t) / 1000;
        if (dt > 0) cpuPct = ((cpuTicks - lastCpu.ticks) / CLK_TCK / dt) * 100;
      }
      lastCpu = { ticks: cpuTicks, t: now };
    } catch (e) { /* stat unreadable */ }
    samples.push({ t: now, rss: rssKb * 1024, cpuPct: Math.round(cpuPct * 100) / 100, threads, fds });
  } catch (e) {
    finish(); // process gone
    return;
  }
}

function finish() {
  running = false;
  const rss = samples.map((s) => s.rss).filter((v) => v > 0);
  const sum = rss.reduce((a, b) => a + b, 0);
  const cpu = samples.slice(1).map((s) => s.cpuPct);
  const summary = {
    pid,
    samples: samples.length,
    durationSec: samples.length ? Math.round((samples[samples.length - 1].t - samples[0].t) / 100) / 10 : 0,
    rssMin: rss.length ? Math.min.apply(null, rss) : null,
    rssMax: rss.length ? Math.max.apply(null, rss) : null,
    rssAvg: rss.length ? Math.round(sum / rss.length) : null,
    cpuAvgPct: cpu.length ? Math.round(cpu.reduce((a, b) => a + b, 0) / cpu.length * 100) / 100 : null,
    cpuPeakPct: samples.length ? Math.max.apply(null, samples.map((s) => s.cpuPct)) : null,
    threadsMax: samples.length ? Math.max.apply(null, samples.map((s) => s.threads)) : null,
    fdsMax: samples.length ? Math.max.apply(null, samples.map((s) => s.fds)) : null,
  };
  try { fs.writeFileSync(out, JSON.stringify(summary, null, 1)); } catch (e) {}
  process.exit(0);
}

process.on('SIGINT', finish);
process.on('SIGTERM', finish);
setInterval(tick, interval);
tick();
