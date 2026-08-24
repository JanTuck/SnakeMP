#!/usr/bin/env node
/* Build every runtime artifact before benchmarking and record warm-cache build
 * durations. Dependency installation and compiler download time are excluded. */
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.resolve(__dirname, '..');
const resultsDir = path.join(root, '.scratch', 'results');
fs.mkdirSync(resultsDir, { recursive: true });

const zig = process.env.ZIG_BIN || 'zig';
const builds = [
  ['go-assets', 'bash', ['servers/go/build-assets.sh'], root],
  ['go', 'go', ['build', '-trimpath', '-ldflags=-s -w', '-o', 'snek-go', '.'], path.join(root, 'servers', 'go')],
  ['zig-assets', 'bash', ['servers/zig/build-assets.sh'], root],
  ['zig', zig, ['build-exe', '-O', 'ReleaseFast', '-fstrip', 'src/main.zig', '-femit-bin=snek-zig', '--cache-dir', '.zig-cache', '--global-cache-dir', '.zig-global-cache'], path.join(root, 'servers', 'zig')],
];

const version = (command, args) => {
  const child = spawnSync(command, args, { encoding: 'utf8' });
  return child.status === 0 ? (child.stdout || child.stderr).trim() : 'unavailable';
};
const osRelease = fs.readFileSync('/etc/os-release', 'utf8').match(/^PRETTY_NAME=(.*)$/m)?.[1]?.replace(/^"|"$/g, '') || os.type();
const result = {
  environment: {
    cpu: os.cpus()[0]?.model || 'unknown CPU',
    logicalCpus: os.cpus().length,
    ramBytes: os.totalmem(),
    os: osRelease,
    kernel: os.release(),
    arch: os.arch(),
    node: process.version,
    go: version('go', ['version']),
    zig: version(zig, ['version']),
  },
};
for (const [name, command, args, cwd] of builds) {
  const start = process.hrtime.bigint();
  const env = name === 'go'
    ? { ...process.env, GOCACHE: path.join(root, '.scratch', '.gocache') }
    : process.env;
  const child = spawnSync(command, args, { cwd, env, encoding: 'utf8' });
  const elapsedMs = Number(process.hrtime.bigint() - start) / 1e6;
  if (child.status !== 0) {
    process.stderr.write(child.stdout || '');
    process.stderr.write(child.stderr || '');
    process.exit(child.status || 1);
  }
  result[name] = { elapsedMs, command: [command, ...args].join(' ') };
  process.stdout.write(`${name}: ${elapsedMs.toFixed(1)} ms\n`);
}

fs.writeFileSync(path.join(resultsDir, 'build-times.json'), JSON.stringify(result, null, 2) + '\n');
