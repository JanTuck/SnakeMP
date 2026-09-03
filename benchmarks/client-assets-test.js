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
      assert.match(match[1], /\?v=__SNEK_ASSET_REV__$/, `browser module import is not release-pinned: ${match[1]}`);
      const dependency = path.resolve(path.dirname(filename), match[1].split('?')[0]);
      assert(fs.existsSync(dependency), `browser module import is missing: ${dependency}`);
      pending.push(dependency);
    }
  }
  return visited;
}

const graph = collectModuleGraph(path.join(clientRoot, 'js/rendering.js'));
assert.strictEqual(graph.size, 12, 'rendering module graph changed; update the production asset expectation deliberately');
for (const filename of graph) {
  const route = '/' + path.relative(clientRoot, filename).split(path.sep).join('/');
  assert(manifest.includes(`.path = "${route}"`), `browser dependency is not embedded: ${route}`);
}
for (const route of [
  '/img/landing-arena.png',
  '/img/mode-classical.png', '/img/mode-arcade.png', '/img/mode-io.png',
  '/img/classic-green-head.png', '/img/classic-green-body.png', '/img/classic-green-tail.png',
  '/img/io-360-head.png', '/img/io-360-body.png', '/img/io-360-tail.png', '/img/io-360-boost-ring.png',
  '/img/io/apple.png', '/img/io/strawberry.png', '/img/io/cheese.png', '/img/io/donut.png',
  '/img/io/golden-apple.png', '/img/io/lightning-berry.png', '/img/io/rainbow-candy.png', '/img/io/feast-platter.png',
  '/img/io/crate.png', '/img/io/spike-mine.png',
  '/fonts/montserrat-black.otf', '/fonts/OFL-Montserrat.txt',
]) {
  assert(manifest.includes(`.path = "${route}"`), `generated mode artwork is not embedded: ${route}`);
}
for (const route of ['/img/io/rocks.png', '/img/io/thorn-hedge.png']) {
  assert(!manifest.includes(`.path = "${route}"`), `removed IO obstacle artwork must not ship: ${route}`);
}

const startupScripts = new Set([
  ...graph,
  path.join(clientRoot, 'js/share.js'),
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
const sprites = fs.readFileSync(path.join(clientRoot, 'js/sprites.js'), 'utf8');
const snake = fs.readFileSync(path.join(clientRoot, 'js/snake.js'), 'utf8');
const gameOverMenu = fs.readFileSync(path.join(clientRoot, 'js/menu/gameOverMenu.js'), 'utf8');
assert(!/\b(?:Food|ResourceHandler)\b/.test(rendering), 'rendering still depends on obsolete wrapper classes');
assert.strictEqual(
  (rendering.match(/food = \{ x: [^,;]+, y: [^};]+ \};/g) || []).length,
  2,
  'initial and updated food coordinates must remain plain position objects',
);
assert(!/swords\.png/.test(fs.readFileSync(path.join(clientRoot, 'img/CREDITS.md'), 'utf8')), 'removed image remains in credits');
assert(!/gsap/i.test(fs.readFileSync(path.join(clientRoot, 'game.html'), 'utf8')), 'game page still loads GSAP');
assert(!/window\.gsap/.test(rendering), 'rendering still depends on GSAP');
assert(/snakeStyleIndex\(meta\[2\], meta\[0\]\)/.test(rendering),
  'IO appearance must come from stable roster identity, never roster position');
assert(!/getIo\?\.\('io(?:Body|Tail|Head)', playerIndex\)/.test(rendering),
  'IO sprite variants must not change when bots reorder the roster');
assert(/new Array\(IO_STYLE_COLORS\.length\)/.test(sprites) && /IO_STYLE_COLORS\.length === 6|IO_STYLE_COLORS = \[/.test(sprites),
  'IO skin cache must remain bounded to the small appearance palette');
assert(/export function snakeStyleIndex/.test(snake), 'grid and IO renderers must share the stable style resolver');
assert(!/window\.gsap/.test(fs.readFileSync(path.join(clientRoot, 'js/hud.js'), 'utf8')), 'HUD still depends on GSAP');
assert(/overlay\.setAttribute\("role", "region"\)/.test(gameOverMenu),
  'game over must remain a non-modal region so Chat and Retry are keyboard peers');
assert(!/setAttribute\("aria-modal"/.test(gameOverMenu),
  'game over must not hide the still-interactive Chat control from assistive technology');

const gamePage = fs.readFileSync(path.join(clientRoot, 'game.html'), 'utf8');
const chat = fs.readFileSync(path.join(clientRoot, 'js/chat.js'), 'utf8');
const chatCss = fs.readFileSync(path.join(clientRoot, 'css/chat.css'), 'utf8');
const gameCss = fs.readFileSync(path.join(clientRoot, 'css/game.css'), 'utf8');
for (const route of ['/js/chat.js', '/css/chat.css']) {
  assert(gamePage.includes(route), `game page does not load ${route}`);
  assert(manifest.includes(`.path = "${route}"`), `chat asset is not embedded: ${route}`);
}
assert(/const MAX_HISTORY = 100;/.test(chat), 'chat session history must remain explicitly bounded');
assert(/\.game-chat:not\(\.is-open\) \.chat-message:nth-last-child\(n \+ 6\)/.test(chatCss),
  'closed chat must keep exactly the five newest messages in its live feed');
assert(/\.game-chat\.is-open \.chat-history[\s\S]*overflow-y: auto;/.test(chatCss),
  'focused chat must expose scrollable full history');
assert(/\.chat-message[\s\S]*background: #090c12;/.test(chatCss),
  'chat messages need an opaque contrast surface over every arena color');
assert(/\.game-chat:not\(\.is-open\) \.chat-open[\s\S]*display: block;/.test(chatCss),
  'the Chat control must remain visible and clickable during active play');
assert(/\.hud-rows li\[hidden\]\s*\{\s*display:\s*none\s*!important;\s*\}/.test(gameCss),
  'HUD row display rules must not override hidden rows after a player dies');
assert(/canvas\.io-arena\s*\{[^}]*touch-action:\s*none;/.test(gameCss),
  'IO drag steering must opt out of browser pan/zoom gesture cancellation');
assert(!/\.innerHTML\b|insertAdjacentHTML|document\.write/.test(chat), 'chat must only render untrusted text through DOM text nodes');
assert(/\.textContent = name;/.test(chat) && /\.textContent = text;/.test(chat), 'chat names and messages must use textContent');

assert(!/<script[^>]+userInput\.js/.test(gamePage), 'user input must load once through the rendering module graph');
assert(gamePage.includes('/js/rendering.js?v=__SNEK_ASSET_REV__'), 'rendering entry must carry the build revision placeholder');

const stagedRoot = path.join(root, 'servers/zig/src/generated/client');
const stagedFiles = [
  path.join(stagedRoot, 'index.html'),
  path.join(stagedRoot, 'game.html'),
  path.join(stagedRoot, 'js/rendering.js'),
  path.join(stagedRoot, 'js/menu/gameOverMenu.js'),
].map((filename) => fs.readFileSync(filename, 'utf8'));
const revisions = stagedFiles.flatMap((source) => [...source.matchAll(/\?v=([0-9a-f]{16})/g)].map((match) => match[1]));
assert(revisions.length >= 15, 'staged asset graph is missing release-pinned URLs');
assert.strictEqual(new Set(revisions).size, 1, 'one page can load dependencies from different release revisions');
assert(stagedFiles.every((source) => !source.includes('__SNEK_ASSET_REV__')), 'staged client still contains an unresolved release placeholder');

console.log(`client asset test passed (${graph.size} rendering modules; ${startupScripts.size} startup JS requests / ${startupBytes} B; one fingerprinted module graph)`);
