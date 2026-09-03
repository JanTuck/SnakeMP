#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

function pngAlphaBounds(filename) {
  const png = fs.readFileSync(filename);
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10], `${filename} must be a PNG`);
  let width = 0;
  let height = 0;
  const idat = [];
  for (let offset = 8; offset < png.length;) {
    const length = png.readUInt32BE(offset);
    const type = png.toString('ascii', offset + 4, offset + 8);
    const data = png.subarray(offset + 8, offset + 8 + length);
    offset += 12 + length;
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      assert.deepEqual([...data.subarray(8, 13)], [8, 6, 0, 0, 0],
        `${filename} must remain an 8-bit, non-interlaced RGBA sprite`);
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
  }
  const packed = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * 4;
  const pixels = Buffer.alloc(stride * height);
  let source = 0;
  const paeth = (left, up, upperLeft) => {
    const p = left + up - upperLeft;
    const leftDistance = Math.abs(p - left);
    const upDistance = Math.abs(p - up);
    const upperLeftDistance = Math.abs(p - upperLeft);
    return leftDistance <= upDistance && leftDistance <= upperLeftDistance ? left
      : upDistance <= upperLeftDistance ? up : upperLeft;
  };
  for (let y = 0; y < height; y++) {
    const filter = packed[source++];
    for (let x = 0; x < stride; x++) {
      const left = x >= 4 ? pixels[y * stride + x - 4] : 0;
      const up = y > 0 ? pixels[(y - 1) * stride + x] : 0;
      const upperLeft = y > 0 && x >= 4 ? pixels[(y - 1) * stride + x - 4] : 0;
      const predictor = filter === 0 ? 0 : filter === 1 ? left : filter === 2 ? up
        : filter === 3 ? Math.floor((left + up) / 2) : filter === 4 ? paeth(left, up, upperLeft) : NaN;
      assert(Number.isFinite(predictor), `${filename} uses unsupported PNG filter ${filter}`);
      pixels[y * stride + x] = (packed[source++] + predictor) & 0xff;
    }
  }
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    if (pixels[y * stride + x * 4 + 3] === 0) continue;
    minX = Math.min(minX, x); minY = Math.min(minY, y);
    maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
  }
  assert(maxX >= minX && maxY >= minY, `${filename} must contain visible pixels`);
  return [minX, minY, maxX - minX + 1, maxY - minY + 1];
}

(async () => {
  const root = path.join(__dirname, '..');
  const source = fs.readFileSync(path.join(root, 'client', 'js', 'ioSnapshot.js'), 'utf8');
  const { decodeIoSnapshot } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
  const worldSource = fs.readFileSync(path.join(root, 'client', 'js', 'ioWorld.js'), 'utf8');
  const world = await import('data:text/javascript;base64,' + Buffer.from(worldSource).toString('base64'));
  const serverSource = fs.readFileSync(path.join(root, 'servers', 'zig', 'src', 'snek.zig'), 'utf8');

  const obstacleBlock = serverSource.match(/pub const OBSTACLES = \[_\]Obstacle\{([\s\S]*?)\n\};/);
  assert(obstacleBlock, 'the server must retain one explicit immutable IO obstacle map');
  const serverObstacles = [...obstacleBlock[1].matchAll(
    /\.x\s*=\s*([\d.]+),\s*\.y\s*=\s*([\d.]+),\s*\.radius\s*=\s*([\d.]+),\s*\.kind\s*=\s*(\d+)/g
  )].map(match => match.slice(1).map(Number));
  assert.deepEqual(world.IO_OBSTACLES, serverObstacles,
    'browser art and authoritative collision geometry must use identical obstacle coordinates, sizes, kinds, and order');
  const hitboxScaleMatch = serverSource.match(/pub const OBSTACLE_HITBOX_SCALE: f32 = ([\d.]+);/);
  assert(hitboxScaleMatch, 'server obstacle collision-core scale must remain statically auditable');
  assert.equal(world.IO_OBSTACLE_HITBOX_SCALE, Number(hitboxScaleMatch[1]),
    'the rendered obstacle telegraph radius must exactly match the authoritative collision core');
  assert.equal(serverObstacles.length, 27, 'the party world keeps its full obstacle population');
  assert.deepEqual([...new Set(serverObstacles.map(obstacle => obstacle[3]))].sort(), [0, 2],
    'IO obstacles are deliberately limited to readable crates and spike bombs');
  for (const [x, y, radius, kind] of serverObstacles) {
    assert(x >= 0 && x < 8192 && y >= 0 && y < 8192, `obstacle kind ${kind} must stay inside the wrapped arena`);
    assert.equal(radius, kind === 0 ? 64 : 52,
      `obstacle kind ${kind} retains its exact readable art footprint`);
  }

  const masses = [30, 120, 220, 450, 700, 1000];
  const radii = masses.map(world.ioSnakeRadius);
  assert.equal(radii[0], 10, 'a newly spawned IO snake keeps the base collision width');
  for (let index = 1; index < radii.length; index++) {
    assert(radii[index] > radii[index - 1], `mass ${masses[index]} must render wider than mass ${masses[index - 1]}`);
  }
  assert(radii.at(-1) <= 72, 'maximum mass must remain within the server collision-width cap');
  assert(world.ioSnakeRadius(633) * 2 >= 128,
    'a snake that can eat a crate is visibly at least as wide as the crate');
  const initialMassMatch = serverSource.match(/pub const INITIAL_MASS: u16 = (\d+)/);
  const radiusFormula = serverSource.match(
    /return std\.math\.clamp\(([\d.]+) \+ std\.math\.sqrt\(extra\) \* ([\d.]+), ([\d.]+), ([\d.]+)\);/
  );
  assert(initialMassMatch && radiusFormula, 'server snake-width formula must remain statically auditable');
  const initialMass = Number(initialMassMatch[1]);
  const [base, scale, minimum, maximum] = radiusFormula.slice(1).map(Number);
  for (const mass of masses) {
    const serverFormula = Math.max(minimum,
      Math.min(maximum, base + Math.sqrt(Math.max(0, mass - initialMass)) * scale));
    assert.equal(world.ioSnakeRadius(mass), serverFormula,
      `client width at mass ${mass} must match Snek.snakeRadius collision geometry`);
  }
  assert.deepEqual(Array.from({ length: 11 }, (_, kind) => world.ioFoodGrowth(kind)),
    [0, 2, 2, 3, 5, 7, 10, 12, 6, 9, 14],
    'all ambient, corpse, treat, turbo, shield, and feast pickup growth values stay mapped');
  const degrees = (value) => value / 180 * Math.PI;
  assert(Math.abs(world.ioInterpolateAngle(degrees(350), degrees(10), 0.5) - Math.PI * 2) < 1e-12,
    'remote head interpolation crosses the 360-degree seam by the short 20-degree arc');
  assert(Math.abs(world.ioInterpolateAngle(degrees(10), degrees(350), 0.5)) < 1e-12,
    'counter-clockwise head interpolation also takes the short arc across zero');
  assert.deepEqual(world.IO_OBSTACLE_ART, [
    { sprite: 'ioCrate', crop: [22, 19, 84, 89] },
    null,
    { sprite: 'ioMine', crop: [8, 10, 112, 108] },
  ], 'piñata-crate and spike-bomb artwork retain measured alpha crops while removed kinds stay unmapped');
  assert.deepEqual(pngAlphaBounds(path.join(root, 'client/img/io/crate.png')), world.IO_OBSTACLE_ART[0].crop,
    'the piñata source crop must include every non-transparent pixel without empty padding');
  assert.deepEqual(pngAlphaBounds(path.join(root, 'client/img/io/spike-mine.png')), world.IO_OBSTACLE_ART[2].crop,
    'the spike-bomb source crop must include every non-transparent pixel without empty padding');
  assert.deepEqual(world.IO_PICKUP_SPRITES, [
    null, null, null, 'ioStrawberry', 'ioApple', 'ioCheese', 'ioDonut',
    'ioGoldenApple', 'ioLightning', 'ioRainbow', 'ioFeast',
  ], 'every special food kind retains its party pickup art mapping');
  const bytes = Buffer.alloc(12 + 11 + 8 + 7);
  let at = 0;
  bytes.write('SI', at); at += 2;
  bytes[at++] = 2;
  bytes.writeUInt16LE(9, at); at += 2;
  bytes[at++] = 1;
  bytes.writeUInt16LE(1, at); at += 2;
  const obstacleMask = (1 << 0) | (1 << 2) | (1 << 26);
  bytes.writeUInt32LE(obstacleMask, at); at += 4;
  bytes.writeUInt32LE(7, at); at += 4;
  bytes.writeUInt16LE(32, at); at += 2;
  bytes.writeUInt16LE(2, at); at += 2;
  bytes.writeUInt16LE(16384, at); at += 2;
  bytes[at++] = 3;
  for (const [x, y] of [[8100, 40], [8092, 40]]) {
    bytes.writeUInt16LE(x, at); at += 2;
    bytes.writeUInt16LE(y, at); at += 2;
  }
  bytes.writeUInt16LE(44, at); at += 2;
  bytes.writeUInt16LE(20, at); at += 2;
  bytes.writeUInt16LE(30, at); at += 2;
  bytes[at++] = 2;

  const frame = decodeIoSnapshot(bytes, 1);
  assert(frame, 'valid IO frame must decode');
  assert.equal(frame.sequence, 9);
  assert.equal(frame.players[0].score, 7);
  assert.equal(frame.players[0].body.length, 2);
  assert.equal(frame.players[0].boosting, true);
  assert.equal(frame.players[0].shielded, true);
  assert.equal(frame.obstacleMask, obstacleMask, 'the authoritative live/depleted obstacle mask must survive decoding exactly');
  assert(Math.abs(frame.players[0].angle - Math.PI / 2) < 0.0001, 'the full u16 heading quantum decodes to a continuous angle');
  assert.equal(frame.foodMass[44], 2);
  const visibleBeforeInvalid = {
    score: frame.players[0].score,
    mass: frame.players[0].mass,
    angle: frame.players[0].angle,
    previousAngle: frame.players[0].previousAngle,
    body: frame.players[0].body.map(point => [point.x, point.y]),
    previous: frame.players[0].previous.map(point => [point.x, point.y]),
    food44: frame.foodMass[44],
  };
  assert.equal(decodeIoSnapshot(bytes.subarray(0, -1), 1), null, 'truncated IO frame must be rejected');
  assert.deepEqual({
    score: frame.players[0].score,
    mass: frame.players[0].mass,
    angle: frame.players[0].angle,
    previousAngle: frame.players[0].previousAngle,
    body: frame.players[0].body.map(point => [point.x, point.y]),
    previous: frame.players[0].previous.map(point => [point.x, point.y]),
    food44: frame.foodMass[44],
  }, visibleBeforeInvalid, 'an invalid frame cannot partially mutate the currently displayed IO state');
  assert.equal(decodeIoSnapshot(bytes, 2), null, 'roster and snapshot counts must stay aligned');
  assert.equal(decodeIoSnapshot(Buffer.concat([bytes, Buffer.from([0])]), 1), null, 'trailing bytes must be rejected');

  function mutated(offset, value, method = 'writeUInt8') {
    const candidate = Buffer.from(bytes);
    candidate[method](value, offset);
    return candidate;
  }
  assert.equal(decodeIoSnapshot(mutated(2, 1), 1), null, 'legacy SI v1 snapshots cannot be interpreted as v2');
  assert.equal(decodeIoSnapshot(mutated(22, 4), 1), null, 'unknown player effect flag bits must be rejected');
  assert(decodeIoSnapshot(mutated(8, 1 << 27, 'writeUInt32LE'), 1) === null,
    'obstacle mask bits outside the exact 27-landmark map must be rejected');
  assert.equal(decodeIoSnapshot(mutated(18, 0, 'writeUInt16LE'), 1), null, 'zero-length snakes are invalid');
  assert.equal(decodeIoSnapshot(mutated(18, 1001, 'writeUInt16LE'), 1), null, 'body lengths above the fixed server cap are invalid');
  assert.equal(decodeIoSnapshot(mutated(23, 8192, 'writeUInt16LE'), 1), null, 'snake coordinates cannot escape the wrapped arena');
  assert.equal(decodeIoSnapshot(mutated(31, 8192, 'writeUInt16LE'), 1), null, 'food slots cannot exceed the fixed SoA capacity');
  assert.equal(decodeIoSnapshot(mutated(33, 8192, 'writeUInt16LE'), 1), null, 'food coordinates cannot escape the wrapped arena');
  assert.equal(decodeIoSnapshot(mutated(37, 0), 1), null, 'zero is reserved for an unused food slot');
  assert.equal(decodeIoSnapshot(mutated(37, 11), 1), null, 'pickup kinds above feast are invalid');
  assert.equal(decodeIoSnapshot(bytes, 101), null, 'client roster expectations remain bounded to 100 snakes');

  const next = Buffer.from(bytes);
  next.writeUInt16LE(45, 31);
  next[37] = 10;
  const nextFrame = decodeIoSnapshot(next, 1);
  assert(nextFrame);
  assert.equal(nextFrame.foodMass[44], 0, 'absent food slots clear between full snapshots');
  assert.equal(nextFrame.foodMass[45], 10, 'the feast pickup kind survives the authoritative snapshot');
  console.log('IO world/snapshot tests: PASS (v2 flags, masks, bounds, parity, growth)');
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
