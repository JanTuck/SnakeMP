#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require('playwright-core');

const root = path.resolve(__dirname, '..');
const clientRoot = path.join(root, 'client');

function findChromium() {
  const candidates = [process.env.SNEK_CHROMIUM, '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome'].filter(Boolean);
  const cache = path.join(os.homedir(), '.cache', 'ms-playwright');
  if (fs.existsSync(cache)) {
    for (const directory of fs.readdirSync(cache).filter(name => name.startsWith('chromium-')).sort().reverse()) {
      candidates.push(path.join(cache, directory, 'chrome-linux64', 'chrome'));
      candidates.push(path.join(cache, directory, 'chrome-linux', 'chrome'));
    }
  }
  const executable = candidates.find(candidate => fs.existsSync(candidate));
  assert(executable, 'Chromium is required. Run `npx playwright-core install chromium` or set SNEK_CHROMIUM.');
  return executable;
}

function fixtureServer() {
  const mime = { '.css': 'text/css', '.html': 'text/html', '.js': 'text/javascript', '.otf': 'font/otf', '.png': 'image/png' };
  return http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
    if (pathname === '/status') {
      response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end('{"players":12,"lobbies":3}');
      return;
    }
    if (pathname === '/__layout/game') {
      const html = fs.readFileSync(path.join(clientRoot, 'game.html'), 'utf8')
        .replace(/<script\b[\s\S]*?<\/script>/gi, '')
        .replaceAll('__SNEK_ASSET_REV__', 'layout-test');
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      response.end(html);
      return;
    }
    const relative = pathname === '/' ? 'index.html' : pathname.slice(1);
    const filename = path.resolve(clientRoot, relative);
    if (!filename.startsWith(clientRoot + path.sep) || !fs.existsSync(filename) || !fs.statSync(filename).isFile()) {
      response.writeHead(404);
      response.end('not found');
      return;
    }
    response.writeHead(200, { 'content-type': `${mime[path.extname(filename)] || 'application/octet-stream'}; charset=utf-8` });
    response.end(fs.readFileSync(filename));
  });
}

const listen = server => new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', () => resolve(server.address().port));
});
const close = server => new Promise(resolve => server.close(resolve));

async function containmentFailures(page, scopeName) {
  return page.evaluate(name => {
    const failures = [];
    const epsilon = 1.1;
    const visible = element => {
      const style = getComputedStyle(element);
      const box = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
    };
    const contains = (outer, inner, label) => {
      const a = outer.getBoundingClientRect();
      const b = inner.getBoundingClientRect();
      if (b.left < a.left - epsilon || b.right > a.right + epsilon || b.top < a.top - epsilon || b.bottom > a.bottom + epsilon) {
        failures.push(`${name}: ${label} escapes its box`);
      }
    };
    if (document.documentElement.scrollWidth > document.documentElement.clientWidth + 1) {
      failures.push(`${name}: ${document.documentElement.scrollWidth - document.documentElement.clientWidth}px horizontal overflow`);
    }
    const pairs = [
      ['.console-title h1', '.console-title', 'landing headline'],
      ['.panel-title h2', '.panel-title', 'panel headline'],
      ['.popup h1', '.popup_content', 'game join headline'],
      ['.game-over-panel h1', '.game-over-panel', 'game-over headline'],
      ['.hud-you', '.hud-score', 'player name'],
      ['.hud-board-header', '.hud-board', 'standings header'],
      ['.chat-form', '.game-chat', 'chat controls'],
    ];
    for (const [innerSelector, outerSelector, label] of pairs) {
      for (const inner of document.querySelectorAll(innerSelector)) {
        if (visible(inner)) contains(inner.closest(outerSelector) || document.querySelector(outerSelector), inner, label);
      }
    }
    for (const action of document.querySelectorAll('.cabinet-action')) {
      if (visible(action)) contains(action, action.children[1], `action label ${action.textContent.trim()}`);
    }
    for (const item of document.querySelectorAll('.site-footer span')) {
      if (visible(item)) contains(document.querySelector('.site-footer'), item, 'footer label');
    }
    for (const element of document.querySelectorAll('.popup, .hud-panel, #hud_feed, #hud_mute, .game-chat, .game-over-panel, .io-boost')) {
      if (!visible(element)) continue;
      const box = element.getBoundingClientRect();
      const verticalEscape = !element.matches('.popup') && (box.top < -epsilon || box.bottom > innerHeight + epsilon);
      if (box.left < -epsilon || box.right > innerWidth + epsilon || verticalEscape) {
        failures.push(`${name}: ${element.className || element.id} escapes the viewport (${Math.round(box.left)},${Math.round(box.top)}..${Math.round(box.right)},${Math.round(box.bottom)} of ${innerWidth}x${innerHeight})`);
      }
    }
    return failures;
  }, scopeName);
}

async function verifyLanding(browser, base, viewport) {
  const page = await browser.newPage({ viewport });
  const browserErrors = [];
  page.on('pageerror', error => browserErrors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') browserErrors.push(message.text()); });
  await page.goto(base, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  const name = `${viewport.width}x${viewport.height}`;
  assert.deepEqual(await containmentFailures(page, `${name} menu`), []);
  await assertLandingViewport(page, `${name} menu`, true);

  await page.click('[data-open-panel="join"]');
  assert.deepEqual(await containmentFailures(page, `${name} join`), []);
  await assertLandingViewport(page, `${name} join`, false);
  const snake = await page.evaluate(() => {
    const head = document.querySelector('.join-snake img:last-child');
    const body = document.querySelector('.join-snake i:last-of-type');
    const matrix = new DOMMatrixReadOnly(getComputedStyle(head).transform);
    const headBox = head.getBoundingClientRect();
    const bodyBox = body.getBoundingClientRect();
    return { horizontalScale: matrix.a, verticalScale: matrix.d, headCenter: headBox.x + headBox.width / 2, bodyCenter: bodyBox.x + bodyBox.width / 2 };
  });
  assert(snake.horizontalScale < 0 && snake.verticalScale > 0, `${name}: join snake head must face right without being upside-down`);
  assert(snake.headCenter > snake.bodyCenter, `${name}: join snake head must lead its body toward the action arrow`);

  await page.click('#console_join [data-open-panel="menu"]');
  await page.click('[data-open-panel="create"]');
  assert.deepEqual(await containmentFailures(page, `${name} create`), []);
  await assertLandingViewport(page, `${name} create`, false);
  const modeFailures = await page.evaluate(() => {
    const failures = [];
    const epsilon = 1.1;
    for (const surface of document.querySelectorAll('.mode-surface')) {
      const outer = surface.getBoundingClientRect();
      const label = surface.querySelector('.mode-heading > span:first-child');
      for (const [element, part] of [[label, 'name'], [surface.querySelector('small'), 'description'], [surface.querySelector('.mode-preview'), 'artwork']]) {
        const inner = element.getBoundingClientRect();
        if (inner.left < outer.left - epsilon || inner.right > outer.right + epsilon || inner.top < outer.top - epsilon || inner.bottom > outer.bottom + epsilon) failures.push(`${label.textContent} ${part} is clipped`);
      }
      if (getComputedStyle(surface.querySelector('.mode-preview')).objectFit !== 'contain') failures.push(`${label.textContent} artwork is cropped`);
      if (surface.scrollWidth > surface.clientWidth + 1 || surface.scrollHeight > surface.clientHeight + 1) failures.push(`${label.textContent} card overflows`);
    }
    return failures;
  });
  assert.deepEqual(modeFailures, [], `${name}: mode cards clipped content`);
  assert.deepEqual(browserErrors, [], `${name}: landing page emitted browser errors`);
  await page.close();
}

async function assertLandingViewport(page, name, requirePanelFullyVisible) {
  const metrics = await page.evaluate(fullyVisible => {
    const root = document.documentElement;
    const active = document.querySelector('.console-view:not([hidden])');
    const panel = active && active.getBoundingClientRect();
    const consoleElement = document.querySelector('.play-console');
    const consoleBox = consoleElement.getBoundingClientRect();
    const activeStyle = active && getComputedStyle(active);
    return {
      viewport: innerHeight,
      pageScrollHeight: root.scrollHeight,
      bodyScrollHeight: document.body.scrollHeight,
      scrollTop: document.scrollingElement.scrollTop,
      consoleTop: consoleBox.top,
      consoleBottom: consoleBox.bottom,
      panelTop: panel && panel.top,
      panelBottom: panel && panel.bottom,
      panelScrollHeight: active && active.scrollHeight,
      panelClientHeight: active && active.clientHeight,
      panelOverflowY: activeStyle && activeStyle.overflowY,
      requirePanelFullyVisible: fullyVisible,
    };
  }, requirePanelFullyVisible);
  assert(metrics.pageScrollHeight <= metrics.viewport + 1,
    `${name}: page needs vertical scrolling (${metrics.pageScrollHeight}px document in ${metrics.viewport}px viewport)`);
  assert(metrics.bodyScrollHeight <= metrics.viewport + 1,
    `${name}: body needs vertical scrolling (${metrics.bodyScrollHeight}px body in ${metrics.viewport}px viewport)`);
  assert.equal(metrics.scrollTop, 0, `${name}: page was displaced ${metrics.scrollTop}px from the top`);
  assert(metrics.consoleTop >= -1 && metrics.consoleBottom <= metrics.viewport + 1,
    `${name}: console escapes viewport (${Math.round(metrics.consoleTop)}..${Math.round(metrics.consoleBottom)} of ${metrics.viewport})`);
  if (requirePanelFullyVisible) {
    assert(metrics.panelTop >= -1 && metrics.panelBottom <= metrics.viewport + 1,
      `${name}: initial menu is not fully visible (${Math.round(metrics.panelTop)}..${Math.round(metrics.panelBottom)} of ${metrics.viewport})`);
    assert(metrics.panelScrollHeight <= metrics.panelClientHeight + 1,
      `${name}: initial menu has hidden internal overflow (${metrics.panelScrollHeight}px in ${metrics.panelClientHeight}px)`);
    assert(metrics.panelTop >= metrics.consoleTop - 1 && metrics.panelBottom <= metrics.consoleBottom + 1,
      `${name}: initial menu is clipped by its cabinet (${Math.round(metrics.panelTop)}..${Math.round(metrics.panelBottom)} in ${Math.round(metrics.consoleTop)}..${Math.round(metrics.consoleBottom)})`);
  } else if (metrics.panelScrollHeight > metrics.panelClientHeight + 1) {
    assert(['auto', 'scroll'].includes(metrics.panelOverflowY),
      `${name}: compact panel clips ${metrics.panelScrollHeight - metrics.panelClientHeight}px without a usable scroll region`);
  }
}

async function verifyGameplay(browser, base, viewport) {
  const hasTouch = viewport.width <= 700;
  const page = await browser.newPage({ viewport, hasTouch, isMobile: hasTouch });
  await page.goto(`${base}__layout/game`, { waitUntil: 'networkidle' });
  const name = `${viewport.width}x${viewport.height}`;
  assert.deepEqual(await containmentFailures(page, `${name} game join`), []);
  const picker = await page.evaluate(() => {
    const choices = [...document.querySelectorAll('.skin-choice')];
    const field = document.querySelector('.skin-field').getBoundingClientRect();
    return {
      count: choices.length,
      checked: document.querySelectorAll('input[name="snake_style"]:checked').length,
      minWidth: Math.min(...choices.map(choice => choice.getBoundingClientRect().width)),
      minHeight: Math.min(...choices.map(choice => choice.getBoundingClientRect().height)),
      fieldLeft: field.left,
      fieldRight: field.right,
      viewportWidth: innerWidth,
      pageScrollWidth: document.documentElement.scrollWidth,
      pageScrollHeight: document.documentElement.scrollHeight,
      bodyScrollHeight: document.body.scrollHeight,
      viewportHeight: innerHeight,
      overlayScrollHeight: document.querySelector('.background_blur').scrollHeight,
      overlayClientHeight: document.querySelector('.background_blur').clientHeight,
      overlayOverflowY: getComputedStyle(document.querySelector('.background_blur')).overflowY,
    };
  });
  assert.equal(picker.count, 6, `${name}: join flow must expose the complete bounded style palette`);
  assert.equal(picker.checked, 1, `${name}: exactly one snake appearance must be selected`);
  assert(picker.minWidth >= 44 && picker.minHeight >= 44,
    `${name}: style touch targets are smaller than 44px (${picker.minWidth}x${picker.minHeight})`);
  assert(picker.fieldLeft >= -1 && picker.fieldRight <= picker.viewportWidth + 1,
    `${name}: style picker escapes the viewport`);
  assert(picker.pageScrollWidth <= picker.viewportWidth + 1, `${name}: style picker introduces horizontal page overflow`);
  assert(picker.pageScrollHeight <= picker.viewportHeight + 1 && picker.bodyScrollHeight <= picker.viewportHeight + 1,
    `${name}: game join introduces document scrolling instead of using its fixed overlay`);
  if (viewport.width === 390 && viewport.height === 844) {
    assert(picker.overlayScrollHeight <= picker.overlayClientHeight + 1,
      `${name}: reference-sized mobile join should fit without even internal scrolling`);
  } else if (picker.overlayScrollHeight > picker.overlayClientHeight + 1) {
    assert(['auto', 'scroll'].includes(picker.overlayOverflowY),
      `${name}: short join content is clipped without a bounded internal scroll region`);
  }

  await page.locator('input[name="snake_style"]').first().focus();
  await page.keyboard.press('ArrowRight');
  assert.equal(await page.locator('input[name="snake_style"]:checked').getAttribute('value'), '1',
    `${name}: style picker must support native arrow-key selection`);
  await page.locator('.skin-choice').nth(5).click();
  assert.equal(await page.locator('input[name="snake_style"]:checked').getAttribute('value'), '5',
    `${name}: style picker must support direct touch/click selection`);
  const controlsCopy = await page.locator('.popup-footnote').textContent();
  assert.match(controlsCopy, /IO:\s*point or touch/i, `${name}: IO steering instructions are missing before Join`);
  assert.match(controlsCopy, /Space or Boost/i, `${name}: IO boost instructions are missing before Join`);

  await page.evaluate(async () => {
    document.querySelector('#game_popup').style.display = 'none';
    document.querySelector('#io_boost').hidden = false;
    const { Hud } = await import('/js/hud.js?v=layout-test');
    Hud.init();
    Hud.setMode('snek_io');
    Hud.update([
      { id: 'me', displayName: 'A very long player name 1234', score: 98765, snake: new Array(80).fill({ x: 0, y: 0 }) },
      { id: 'two', displayName: 'Leaderboard player with long text', score: 87654, snake: [{ x: 0, y: 0 }] },
      { id: 'three', displayName: 'Third player name', score: 76543, snake: [{ x: 0, y: 0 }] },
    ], 'me');
    const chat = document.querySelector('#game_chat');
    chat.hidden = false;
    chat.classList.add('is-open');
    const history = document.querySelector('#chat_history');
    for (let index = 0; index < 5; index++) {
      const message = document.createElement('p');
      message.className = 'chat-message';
      message.textContent = `LongPlayerName: gameplay chat message ${index} with enough text to wrap safely inside the panel.`;
      history.append(message);
    }
  });
  assert.deepEqual(await containmentFailures(page, `${name} live gameplay`), []);
  const touchBoost = await page.evaluate(() => {
    const button = document.querySelector('#io_boost');
    const box = button.getBoundingClientRect();
    return { display: getComputedStyle(button).display, width: box.width, height: box.height };
  });
  if (hasTouch) {
    assert.notEqual(touchBoost.display, 'none', `${name}: touch IO play must expose boost`);
    assert(touchBoost.width >= 44 && touchBoost.height >= 44,
      `${name}: touch boost is smaller than 44px (${touchBoost.width}x${touchBoost.height})`);
  } else {
    assert.equal(touchBoost.display, 'none', `${name}: fine-pointer play should keep the touch-only boost out of the way`);
  }

  const deathPreservedChatFocus = await page.evaluate(async () => {
    document.querySelector('#game_chat').classList.remove('is-open');
    const chat = document.querySelector('#chat_open');
    chat.focus();
    const module = await import('/js/menu/gameOverMenu.js?v=layout-test');
    const context = document.querySelector('#canvas').getContext('2d');
    const menu = new module.default(context);
    menu.setScore(123456789);
    window.__layoutGameOverMenu = menu;
    await new Promise(resolve => requestAnimationFrame(resolve));
    return document.activeElement === chat;
  });
  assert.equal(deathPreservedChatFocus, true,
    `${name}: game over must not interrupt a live Chat control`);
  assert.deepEqual(await containmentFailures(page, `${name} game over`), []);
  const chatFocusPreserved = await page.evaluate(() => {
    const chat = document.querySelector('#chat_open');
    chat.focus();
    window.__layoutGameOverMenu.destroy();
    delete window.__layoutGameOverMenu;
    return document.activeElement === chat;
  });
  assert.equal(chatFocusPreserved, true,
    `${name}: reconnect teardown must not steal focus from the non-modal Chat control`);

  const frameTiming = await page.evaluate(() => new Promise(resolve => {
    const intervals = [];
    let previous = performance.now();
    const sample = now => {
      intervals.push(now - previous);
      previous = now;
      if (intervals.length === 45) resolve(intervals.slice(5));
      else requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  }));
  const sorted = [...frameTiming].sort((a, b) => a - b);
  const p95 = sorted[Math.floor(sorted.length * 0.95)];
  assert(p95 < 50, `${name}: compositor frame p95 ${p95.toFixed(1)}ms exceeds smoothness budget`);
  await page.close();
}

(async () => {
  const server = fixtureServer();
  const port = await listen(server);
  const base = `http://127.0.0.1:${port}/`;
  const browser = await chromium.launch({ headless: true, executablePath: findChromium(), args: ['--no-sandbox'] });
  try {
    const viewports = [{ width: 1440, height: 1000 }, { width: 1024, height: 768 }, { width: 650, height: 900 }, { width: 390, height: 844 }, { width: 320, height: 1000 }, { width: 320, height: 700 }];
    for (const viewport of viewports) await verifyLanding(browser, base, viewport);
    for (const viewport of [{ width: 1440, height: 1000 }, { width: 390, height: 844 }, { width: 320, height: 700 }, { width: 700, height: 390 }]) await verifyGameplay(browser, base, viewport);
    console.log('frontend layout regressions: PASS (landing + gameplay containment, accessible snake styles, mode artwork, snake direction, frame pacing)');
  } finally {
    await browser.close();
    await close(server);
  }
})().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
