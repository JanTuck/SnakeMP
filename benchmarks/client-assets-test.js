'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const clientRoot = path.join(root, 'client');
const manifest = fs.readFileSync(path.join(root, 'servers/zig/src/assets_manifest.zig'), 'utf8');
const importPattern = /^\s*import(?:[\s\S]*?\sfrom\s*)?["']([^"']+)["'];?\s*$/gm;

function collectModuleGraph(entry) {
  const pending = [entry];
  const visited = new Set();
  while (pending.length !== 0) {
    const filename = pending.pop();
    if (visited.has(filename)) continue;
    visited.add(filename);
    const source = fs.readFileSync(filename, 'utf8');
    importPattern.lastIndex = 0;
    for (let match; (match = importPattern.exec(source)) !== null;) {
      assert(match[1].startsWith('.'), `browser module uses an unexpected bare import: ${match[1]}`);
      const dependency = path.resolve(path.dirname(filename), match[1]);
      assert(fs.existsSync(dependency), `browser module import is missing: ${dependency}`);
      pending.push(dependency);
    }
  }
  return visited;
}

const graph = collectModuleGraph(path.join(clientRoot, 'js/rendering.js'));
assert.strictEqual(graph.size, 10, 'rendering module graph changed; update the production asset expectation deliberately');
for (const filename of graph) {
  const route = '/' + path.relative(clientRoot, filename).split(path.sep).join('/');
  assert(manifest.includes(`.path = "${route}"`), `browser dependency is not embedded: ${route}`);
}

const startupScripts = new Set([
  ...graph,
  path.join(clientRoot, 'js/userInput.js'),
  path.join(clientRoot, 'js/transport.js'),
  path.join(clientRoot, 'js/chat.js'),
]);
const startupBytes = [...startupScripts].reduce((total, filename) => total + fs.statSync(filename).size, 0);

const removed = [
  ['js/box.js', '/js/box.js'],
  ['js/food.js', '/js/food.js'],
  ['js/gameObject.js', '/js/gameObject.js'],
  ['js/resourceHandler.js', '/js/resourceHandler.js'],
  ['img/swords.png', '/img/swords.png'],
  ['vendor/gsap.min.js', '/vendor/gsap.min.js'],
];
for (const [relative, route] of removed) {
  assert(!fs.existsSync(path.join(clientRoot, relative)), `obsolete client asset still exists: ${relative}`);
  assert(!manifest.includes(`.path = "${route}"`), `obsolete client asset is still embedded: ${route}`);
}

const rendering = fs.readFileSync(path.join(clientRoot, 'js/rendering.js'), 'utf8');
assert(!/\b(?:Food|ResourceHandler)\b/.test(rendering), 'rendering still depends on obsolete wrapper classes');
assert.strictEqual(
  (rendering.match(/food = \{ x: [^,;]+, y: [^};]+ \};/g) || []).length,
  2,
  'initial and updated food coordinates must remain plain position objects',
);
assert(!/swords\.png/.test(fs.readFileSync(path.join(clientRoot, 'img/CREDITS.md'), 'utf8')), 'removed image remains in credits');
assert(!/gsap/i.test(fs.readFileSync(path.join(clientRoot, 'game.html'), 'utf8')), 'game page still loads GSAP');
assert(!/window\.gsap/.test(rendering), 'rendering still depends on GSAP');
assert(!/window\.gsap/.test(fs.readFileSync(path.join(clientRoot, 'js/hud.js'), 'utf8')), 'HUD still depends on GSAP');

const gamePage = fs.readFileSync(path.join(clientRoot, 'game.html'), 'utf8');
const chat = fs.readFileSync(path.join(clientRoot, 'js/chat.js'), 'utf8');
for (const route of ['/js/chat.js', '/css/chat.css']) {
  assert(gamePage.includes(route), `game page does not load ${route}`);
  assert(manifest.includes(`.path = "${route}"`), `chat asset is not embedded: ${route}`);
}
assert(/const MAX_HISTORY = 100;/.test(chat), 'chat session history must remain explicitly bounded');
assert(!/\.innerHTML\b|insertAdjacentHTML|document\.write/.test(chat), 'chat must only render untrusted text through DOM text nodes');
assert(/\.textContent = name;/.test(chat) && /\.textContent = text;/.test(chat), 'chat names and messages must use textContent');

console.log(`client asset test passed (${graph.size} rendering modules; ${startupScripts.size} startup JS requests / ${startupBytes} B; 4 modules, 1 image, and GSAP removed)`);
