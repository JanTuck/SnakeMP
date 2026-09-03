import Snake, { RemoteInterpolationClock, snakeStyleIndex } from "./snake.js?v=__SNEK_ASSET_REV__";
import GameOverMenu from "./menu/gameOverMenu.js?v=__SNEK_ASSET_REV__";
import { Sprites } from "./sprites.js?v=__SNEK_ASSET_REV__";
import { Sfx } from "./audio.js?v=__SNEK_ASSET_REV__";
import { Particles } from "./particles.js?v=__SNEK_ASSET_REV__";
import { Hud, Motion } from "./hud.js?v=__SNEK_ASSET_REV__";
import { decodeSnapshot } from "./snapshot.js?v=__SNEK_ASSET_REV__";
import { decodeIoSnapshot } from "./ioSnapshot.js?v=__SNEK_ASSET_REV__";
import { IO_OBSTACLES, IO_OBSTACLE_ART, IO_OBSTACLE_HITBOX_SCALE, IO_PICKUP_SPRITES, ioFoodGrowth, ioInterpolateAngle, ioSnakeRadius } from "./ioWorld.js?v=__SNEK_ASSET_REV__";
import { getPredictedDirection, getPredictedSteerAngle, releaseBoost, resetDirection, setGameMode, setGameplayEnabled, syncDirection } from "./userInput.js?v=__SNEK_ASSET_REV__";

// Module scripts run after the DOM is parsed, so the canvas/socket exist
// already. Wiring handlers here instead of inside window.onload avoids a
// soft-lock when slow render-blocking resources delay onload past the point
// where the player joins.
const canvas = document.getElementById("canvas");
const ctx = canvas.getContext('2d');
const nameplateLayer = document.getElementById("nameplates");
const CLASSIC_CANVAS_WIDTH = canvas.width;
const CLASSIC_CANVAS_HEIGHT = canvas.height;

const TICK_MS = 1000 / 15; // must match the server game loop
const DROP_TTL_MS = 25000;
const DEATH_REPLAY_MS = 3500;
const DANGER_CHECK_MS = 100;
const DANGER_RADIUS = 32 * 16;
const IO_ARENA = 8192;
const IO_PELLET_COLORS = ['#63e6a3', '#ff5c8a', '#f2cb45', '#47c6e8', '#a879ff', '#ff784f'];

const snakeList = new Map();
const nameplates = new Map();
let food = null;
let isSetup = false;
let gameOver = false;
let spectating = false;
let gameMode = 'arcade';
let errorTimeout = null;
let gameOverMenu = null;
let deathReplay = null;

// World pickups (supply drops, bonus apples, golden apple).
let world = { bonus: [], drops: [], golden: null, remains: [], feastTtl: 0, bountyId: null };
let roster = [];
let pendingIoRoster = null;
let localRosterIndex = -1;
let compactPlayers = [];
const compactById = new Map();
let lastSnapshotSequence = null;
const remoteInterpolation = new RemoteInterpolationClock(TICK_MS);
let shakeUntil = 0;
let lastFrameAt = 0;
let renderReady = false;
let framePending = false;
let cachedCanvasRect = null;
const prevScores = new Map();
const reducedMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)') || { matches: false };
let lastDangerCheck = -Infinity;
let dangerId = null;
let ioFrame = null;
let ioObstacleMask = null;

function requestFrame(resuming = false) {
    if (!renderReady || framePending) return;
    if (resuming) lastFrameAt = 0;
    framePending = true;
    requestAnimationFrame(frame);
}

function invalidateScreenLayout() {
    cachedCanvasRect = null;
    for (const plate of nameplates.values()) plate.measured = false;
}

function syncCanvasResolution() {
    const rect = canvas.getBoundingClientRect();
    const width = gameMode === 'snek_io' ? Math.max(1, Math.round(rect.width)) : CLASSIC_CANVAS_WIDTH;
    const height = gameMode === 'snek_io' ? Math.max(1, Math.round(rect.height)) : CLASSIC_CANVAS_HEIGHT;
    if (canvas.width === width && canvas.height === height) return;
    canvas.width = width;
    canvas.height = height;
    invalidateScreenLayout();
}

function handleViewportResize() {
    invalidateScreenLayout();
    syncCanvasResolution();
    requestFrame(true);
}

function screenRect() {
    if (cachedCanvasRect === null) cachedCanvasRect = canvas.getBoundingClientRect();
    return cachedCanvasRect;
}

// The arena is fixed to the viewport, so its screen geometry only changes on
// resize. Keeping it out of the 60/120 Hz render path avoids needless layout
// reads, especially when a full 32-player roster also has DOM nameplates.
window.addEventListener?.('resize', handleViewportResize, { passive: true });
window.visualViewport?.addEventListener?.('resize', handleViewportResize, { passive: true });
if (typeof ResizeObserver === 'function') new ResizeObserver(handleViewportResize).observe(canvas);

function showError(message) {
    let domError = document.getElementById('game_error');
    domError.textContent = message;
    domError.style.display = 'block';
    if (errorTimeout !== null) clearTimeout(errorTimeout);
    errorTimeout = setTimeout(() => {
        domError.style.display = 'none';
        errorTimeout = null;
    }, 1500);
}

function hideError() {
    const domError = document.getElementById('game_error');
    if (errorTimeout !== null) clearTimeout(errorTimeout);
    errorTimeout = null;
    if (domError !== null) domError.style.display = 'none';
}

// Translate a click into canvas coordinates, honouring CSS scaling.
function canvasPoint(event) {
    const rect = canvas.getBoundingClientRect();
    return {
        x: (event.clientX - rect.left) * (canvas.width / rect.width),
        y: (event.clientY - rect.top) * (canvas.height / rect.height)
    };
}

// Make the game over screen interactive (its buttons used to be pixels only).
canvas.addEventListener('click', (event) => {
    if (!gameOver || gameOverMenu === null) return;
    const point = canvasPoint(event);
    for (let button of gameOverMenu.buttonArray) {
        if (point.x >= button.x && point.x <= button.x + button.width &&
            point.y >= button.y && point.y <= button.y + button.height) {
            // Only one button exists for now: play again.
            window.location.reload();
            return;
        }
    }
});

function drawSprite(name, cellX, cellY, size, alpha = 1) {
    const img = Sprites.get(name);
    if (img === undefined) return;
    ctx.globalAlpha = alpha;
    ctx.drawImage(img, cellX, cellY, size, size);
    ctx.globalAlpha = 1;
}

function ensureNameplate(id, displayName) {
    let plate = nameplates.get(id);
    if (plate === undefined) {
        const element = document.createElement('span');
        element.className = 'player-nameplate';
        element.dir = 'auto';
        element.hidden = true;
        nameplateLayer.appendChild(element);
        plate = {
            element, displayName: '', screenX: 0, screenY: 0, below: false,
            width: 0, height: 28, measured: false, isLocal: false,
        };
        nameplates.set(id, plate);
    }
    if (plate.displayName !== displayName) {
        plate.displayName = displayName;
        plate.element.textContent = displayName;
        plate.measured = false;
    }
    const isLocal = id === socket.id;
    if (plate.isLocal !== isLocal) {
        plate.isLocal = isLocal;
        plate.measured = false;
    }
    plate.element.classList.toggle('is-local', isLocal);
    plate.element.classList.toggle('is-bounty', id === world.bountyId && gameMode === 'arcade');
}

function removeNameplate(id) {
    const plate = nameplates.get(id);
    if (plate === undefined) return;
    plate.element.remove();
    nameplates.delete(id);
}

function setBountyId(id) {
    const next = gameMode === 'arcade' && typeof id === 'string' ? id : null;
    if (world.bountyId === next) return;
    if (world.bountyId !== null) nameplates.get(world.bountyId)?.element.classList.toggle('is-bounty', false);
    world.bountyId = next;
    if (next !== null) nameplates.get(next)?.element.classList.toggle('is-bounty', true);
}

function prepareNameplate(snake, t, rect) {
    const plate = nameplates.get(snake.id);
    const current = snake.snake[0];
    if (plate === undefined || current === undefined) return;
    const previous = snake.interpolate && snake.prevSnake.length > 0 ? snake.prevSnake[0] : current;
    const worldX = previous.x + (current.x - previous.x) * t + snake.scale / 2;
    const worldY = previous.y + (current.y - previous.y) * t + snake.scale / 2;
    plate.screenX = rect.left + worldX * rect.width / canvas.width;
    plate.screenY = rect.top + worldY * rect.height / canvas.height;
    plate.element.hidden = false;
}

function placeNameplates(rect) {
    // Read every label's geometry before writing any positions. This prevents
    // one player's animation from forcing layout before the next is measured.
    const right = rect.right ?? rect.left + rect.width;
    for (const plate of nameplates.values()) {
        if (plate.element.hidden) continue;
        if (!plate.measured) {
            plate.width = plate.element.offsetWidth || 0;
            plate.height = plate.element.offsetHeight || 28;
            plate.measured = true;
        }
        const halfWidth = Math.min(plate.width / 2, Math.max(0, rect.width / 2 - 8));
        plate.screenX = Math.max(rect.left + halfWidth + 8, Math.min(right - halfWidth - 8, plate.screenX));
        plate.below = plate.screenY < rect.top + plate.height + 10;
    }
    for (const plate of nameplates.values()) {
        if (plate.element.hidden) continue;
        plate.element.style.translate = `${plate.screenX}px ${plate.screenY}px`;
        plate.element.classList.toggle('is-below', plate.below);
    }
}

// Immutable identity metadata arrives only on membership changes. Binary
// snapshots are positional records aligned to this roster.
function applyRoster(nextRoster) {
    const live = new Set();
    const nextPlayers = new Array(nextRoster.length);
    for (let i = 0; i < nextRoster.length; i++) {
        const meta = nextRoster[i];
        const id = meta[0];
        live.add(id);
        ensureNameplate(id, meta[1]);
        let state = compactById.get(id);
        if (state === undefined) {
            state = { id, displayName: meta[1], color: meta[2], score: 0, bodyLength: 0, snake: [] };
            compactById.set(id, state);
        } else {
            state.displayName = meta[1];
            state.color = meta[2];
        }
        nextPlayers[i] = state;
    }
    for (const id of compactById.keys()) {
        if (!live.has(id)) {
            compactById.delete(id);
            snakeList.delete(id);
            prevScores.delete(id);
            removeNameplate(id);
        }
    }
    if (world.bountyId !== null && !live.has(world.bountyId)) setBountyId(null);
    roster = nextRoster;
    compactPlayers = nextPlayers;
    localRosterIndex = roster.findIndex((meta) => meta[0] === socket.id);
    // The server follows every changed roster with an independent keyframe.
    lastSnapshotSequence = null;
}

socket.on("r", (nextRoster) => {
    // A retained roster may reach this module before its retained init when a
    // fast join beats module loading. Accept the protocol-wide bound here;
    // each binary decoder still enforces its mode-specific player ceiling.
    if (!Array.isArray(nextRoster) || nextRoster.length > 100) return;
    const ids = new Set();
    for (const meta of nextRoster) {
        if (!Array.isArray(meta) || meta.length !== 3 ||
            typeof meta[0] !== "string" || meta[0].length === 0 ||
            typeof meta[1] !== "string" || typeof meta[2] !== "string" || ids.has(meta[0])) return;
        ids.add(meta[0]);
    }
    // IO snapshots are positional. Keep rendering the previous complete
    // roster/frame pair until the server's immediately-following snapshot can
    // be committed atomically; otherwise bot scaling briefly paints names and
    // colors on the wrong snakes.
    if (gameMode === 'snek_io') pendingIoRoster = nextRoster;
    else applyRoster(nextRoster);
});

function resizeObjects(array, length) {
    while (array.length < length) array.push({ x: 0, y: 0 });
    array.length = length;
}

// The decoder validates the complete v5 frame into bounded scratch storage
// before any visible game state is committed here.
socket.on("b", (payload) => {
    if (!isSetup || gameOver) return;
    if (gameMode === 'snek_io') {
        const snapshotRoster = pendingIoRoster === null ? roster : pendingIoRoster;
        const frame = decodeIoSnapshot(payload, snapshotRoster.length);
        if (frame === null) return;
        if (pendingIoRoster !== null) {
            const nextRoster = pendingIoRoster;
            pendingIoRoster = null;
            applyRoster(nextRoster);
            // Slot identities may have shifted, so the paired full snapshot is
            // a complete state rather than an interpolation continuation.
            remoteInterpolation.reset();
        }
        ioFrame = frame;
        for (let index = 0; index < frame.playerCount; index++) {
            const state = compactPlayers[index];
            const update = frame.players[index];
            state.score = update.score;
            state.bodyLength = update.mass;
            state.snake = update.body;
        }
        world.players = compactPlayers;
        lastSnapshotSequence = frame.sequence;
        remoteInterpolation.snapshot(performance.now(), frame.sequence);
        try { Hud.update(compactPlayers, socket.id); } catch (_) {}
        return;
    }
    const frame = decodeSnapshot(payload, roster.length, lastSnapshotSequence, compactPlayers);
    if (frame === null) return;
    const scoreEffects = [];
    try {
        for (let index = 0; index < frame.playerCount; index++) {
            const meta = roster[index];
            const state = compactPlayers[index];
            const before = state.score;
            const update = frame.players[index];
            let snake = snakeList.get(meta[0]);
            if (snake === undefined) {
                snake = new Snake(ctx, meta);
                snakeList.set(meta[0], snake);
            }
            if (frame.kind === 0) snake.updateKeyframe(meta, frame.view, update);
            else snake.updateDelta(meta, update);
            if (meta[0] === socket.id) {
                const head = snake.snake[0];
                const previousHead = snake.prevSnake[0];
                if (head !== undefined && previousHead !== undefined) {
                    let dx = head.x - previousHead.x;
                    let dy = head.y - previousHead.y;
                    // Wraparound keyframes cross the numeric board seam even
                    // though the snake keeps moving in the same direction.
                    if (dx > canvas.width / 2) dx -= canvas.width;
                    else if (dx < -canvas.width / 2) dx += canvas.width;
                    if (dy > canvas.height / 2) dy -= canvas.height;
                    else if (dy < -canvas.height / 2) dy += canvas.height;
                    if (dx > 0 && dy === 0) syncDirection('ArrowRight');
                    else if (dx < 0 && dy === 0) syncDirection('ArrowLeft');
                    else if (dy > 0 && dx === 0) syncDirection('ArrowDown');
                    else if (dy < 0 && dx === 0) syncDirection('ArrowUp');
                }
            }
            state.score = update.score;
            state.bodyLength = update.cells;
            state.snake = snake.snake;
            if (update.score > before && update.cells > 0) {
                const head = snake.snake[0];
                scoreEffects.push({ x: head.x + 8, y: head.y + 8, color: state.color, local: state.id === socket.id });
            }
        }

        resizeObjects(world.bonus, frame.bonusCount);
        for (let index = 0; index < frame.bonusCount; index++) {
            world.bonus[index].x = frame.bonus[index].x * 16;
            world.bonus[index].y = frame.bonus[index].y * 16;
        }
        resizeObjects(world.drops, frame.dropCount);
        for (let index = 0; index < frame.dropCount; index++) {
            const drop = world.drops[index];
            drop.x = frame.drops[index].x * 16;
            drop.y = frame.drops[index].y * 16;
            drop.ttl = frame.drops[index].ttl;
        }
        if (!frame.hasGolden) world.golden = null;
        else {
            if (world.golden === null) world.golden = { x: 0, y: 0, ttl: 0 };
            world.golden.x = frame.goldenX * 16;
            world.golden.y = frame.goldenY * 16;
            world.golden.ttl = frame.goldenTtl;
        }
        resizeObjects(world.remains, gameMode === 'arcade' ? frame.remainsCount : 0);
        for (let index = 0; index < world.remains.length; index++) {
            const remain = world.remains[index];
            remain.x = frame.remains[index].x * 16;
            remain.y = frame.remains[index].y * 16;
            remain.ttl = frame.remains[index].ttl;
        }
        world.feastTtl = gameMode === 'arcade' ? frame.feastTtl : 0;
        setBountyId(gameMode === 'arcade' && frame.hasBounty ? roster[frame.bountySlot]?.[0] : null);
        world.players = compactPlayers;
        lastSnapshotSequence = frame.sequence;
        remoteInterpolation.snapshot(performance.now(), frame.sequence);
    } catch (_) {
        // DataView bounds checks are a final guard against hostile frames.
        return;
    }

    // Effects are best effort and run only after the authoritative state and
    // sequence are committed. A broken audio/HUD/particle effect must not
    // strand the decoder on an old base sequence with partially applied state.
    for (const effect of scoreEffects) {
        try { Particles.burst(effect.x, effect.y, effect.color, effect.local ? 18 : 8); } catch (_) {}
        if (effect.local) {
            try { Sfx.eat(); } catch (_) {}
            try { Hud.popScore(); } catch (_) {}
        }
    }
    try { Hud.update(compactPlayers, socket.id, { feastTtl: world.feastTtl, bountyId: world.bountyId }); } catch (_) {}
});

socket.on('init', (initData) => {
    hideError();
    document.getElementById('game_popup').style.display = 'none';
    gameMode = initData.mode === 'snek_io' ? 'snek_io'
        : initData.mode === 'arcade' ? 'arcade'
        : 'classical';
    Hud.setMode(gameMode);
    setGameMode(gameMode);

    if (gameMode === 'snek_io') food = null;
    else food = { x: initData.food.x, y: initData.food.y };
    ioFrame = null;
    pendingIoRoster = null;
    ioObstacleMask = null;
    canvas.classList?.toggle('io-arena', gameMode === 'snek_io');
    syncCanvasResolution();
    const footnote = document.querySelector('.popup-footnote');
    if (footnote !== null) footnote.textContent = gameMode === 'snek_io'
        ? 'Point or touch to steer. Hold Space to boost.'
        : 'Arrow keys or WASD to steer. Space activates your boost.';
    gameOver = false;
    spectating = false;
    deathReplay = null;
    world.remains.length = 0;
    world.feastTtl = 0;
    setBountyId(null);
    dangerId = null;
    lastDangerCheck = -Infinity;
    nameplateLayer.hidden = false;
    resetDirection();
    setGameplayEnabled(true);
    gameOverMenu?.destroy?.();
    gameOverMenu = null;
    isSetup = true;
    remoteInterpolation.reset();
    lastFrameAt = 0;
    Motion.canvas(canvas);
    requestFrame();
});

socket.on('game_error', (errorMessage) => {
    showError(errorMessage);
});

socket.on('updateFood', (data) => {
    if (!isSetup || gameOver) return;
    food = { x: data.x, y: data.y };
});

socket.on('feed', (item) => {
    if (item === null || typeof item !== 'object') return;
    Hud.feed(item);
    if (item.type === 'drop-open') Sfx.drop();
    else if (item.type === 'golden') Sfx.golden();
    else if (item.type === 'join') Sfx.join();
    else if (item.type === 'drop-incoming') Sfx.countIn();
    else if ((item.type === 'death' || item.type === 'kill') && item.who !== undefined) {
        // Arcade attribution is identity-based: display names are not unique.
        const victimId = item.victimId ?? item.whoId ?? item.id;
        const victim = typeof victimId === 'string'
            ? compactById.get(victimId)
            : gameMode === 'arcade' ? undefined : (world.players || []).find((p) => p.displayName === item.who);
        if (victim !== undefined) {
            Particles.burst(victim.snake[0].x + 8, victim.snake[0].y + 8, victim.color, 24, 4);
            requestFrame(true);
        }
    }
});

socket.on('death', (death) => {
    const score = typeof death === 'number' ? death : Number(death?.score) || 0;
    const replayMs = Number.isFinite(death?.spectateMs) && death.spectateMs > 0
        ? Math.min(10_000, death.spectateMs) : DEATH_REPLAY_MS;
    const now = performance.now();
    const me = snakeList.get(socket.id);
    const head = me !== undefined ? me.snake[0] : null;
    const focus = death?.focus && typeof death.focus === 'object' ? death.focus : death;
    const focusX = Number.isFinite(focus?.x) ? focus.x : head !== null ? head.x + 8 : canvas.width / 2;
    const focusY = Number.isFinite(focus?.y) ? focus.y : head !== null ? head.y + 8 : canvas.height / 2;

    releaseBoost();
    setGameplayEnabled(false);
    resetDirection();
    Sfx.death();
    shakeUntil = now + 450;
    // Burst where OUR snake actually died (last known head position).
    Particles.burst(gameMode === 'snek_io' ? canvas.width / 2 : focusX,
        gameMode === 'snek_io' ? canvas.height / 2 : focusY,
        me !== undefined ? me.color : '#e74c3c', 40, 5);
    gameOverMenu?.destroy?.();

    if (gameMode === 'arcade' || gameMode === 'snek_io') {
        gameOver = false;
        spectating = true;
        deathReplay = { x: focusX, y: focusY, startedAt: now, until: now + replayMs, duration: replayMs, finished: false };
        gameOverMenu = new GameOverMenu(ctx, { compact: true });
        gameOverMenu.setReplay(replayMs);
    } else {
        gameOver = true; // Established Classical terminal presentation.
        spectating = false;
        deathReplay = null;
        nameplateLayer.hidden = true;
        gameOverMenu = new GameOverMenu(ctx);
    }
    gameOverMenu.setScore(score);
    gameOverMenu.draw();
    requestFrame(true);
});

socket.on('disconnect', () => {
    // Freeze the last trustworthy picture and make every hot input inert until
    // a fresh init acknowledgement arrives. In particular, a held boost or a
    // queued IO steer must never leak into the replacement server session.
    isSetup = false;
    setGameplayEnabled(false);
    resetDirection();
    pendingIoRoster = null;
    ioFrame = null;
    ioObstacleMask = null;
    applyRoster([]);
    world.players = compactPlayers;
    try { Hud.update([], ''); } catch (_) {}
    if (!gameOver) showError('Disconnected from server');
});

// ---- Render loop: interpolated movement at display refresh rate ----
function drawWorld(now) {
    if (gameMode === 'snek_io') return;
    // Arcade remains stay deliberately quieter than apples: neutral matte
    // pellets communicate edible mass without turning a death into confetti.
    if (gameMode === 'arcade') {
        for (const remain of world.remains) {
            const alpha = remain.ttl < 2000 ? Math.max(0.25, remain.ttl / 2000) : 1;
            ctx.globalAlpha = alpha;
            ctx.fillStyle = '#756d63';
            ctx.fillRect(remain.x + 4, remain.y + 4, 9, 9);
            ctx.fillStyle = '#a69b8c';
            ctx.fillRect(remain.x + 5, remain.y + 5, 3, 2);
        }
        ctx.globalAlpha = 1;
    }

    // Main apple with a gentle bob so the board feels alive.
    if (food !== null) {
        const bob = Math.sin(now / 220) * 1.5;
        drawSprite('apple', food.x - 2, food.y - 2 + bob, 20);
    }

    // Bonus apples, slightly smaller with a soft pulse.
    for (const b of world.bonus) {
        const pulse = 14 + Math.sin(now / 180 + b.x) * 1.2;
        drawSprite('apple', b.x + (16 - pulse) / 2, b.y + (16 - pulse) / 2, pulse, 0.95);
    }

    // Supply crates: drop-in animation on arrival, blink before despawning.
    for (const d of world.drops) {
        const age = DROP_TTL_MS - d.ttl;
        let scale = 1;
        if (age < 600) scale = 1 + (1 - age / 600) * 0.9; // slam-in
        const blink = d.ttl < 5000 && Math.floor(now / 150) % 2 === 0;
        if (!blink) {
            const size = 20 * scale;
            drawSprite('crate', d.x + (16 - size) / 2, d.y + (16 - size) / 2, size);
        }
    }

    // Golden apple with a glow, blinking right before it vanishes.
    if (world.golden !== null) {
        const blink = world.golden.ttl < 3000 && Math.floor(now / 130) % 2 === 0;
        if (!blink) {
            ctx.save();
            ctx.shadowColor = 'rgba(255, 200, 0, 0.9)';
            ctx.shadowBlur = 12;
            drawSprite('golden', world.golden.x - 1, world.golden.y - 1, 18);
            ctx.restore();
        }
    }
}

function ioDelta(value, origin) {
    let delta = value - origin;
    if (delta > IO_ARENA / 2) delta -= IO_ARENA;
    else if (delta < -IO_ARENA / 2) delta += IO_ARENA;
    return delta;
}

function ioPointX(player, index, t) {
    const current = player.body[index];
    const previous = player.previous[Math.min(index, player.previous.length - 1)] || current;
    return (previous.x + ioDelta(current.x, previous.x) * t + IO_ARENA) % IO_ARENA;
}

function ioPointY(player, index, t) {
    const current = player.body[index];
    const previous = player.previous[Math.min(index, player.previous.length - 1)] || current;
    return (previous.y + ioDelta(current.y, previous.y) * t + IO_ARENA) % IO_ARENA;
}

function ioIntersectsViewport(x, y, halfExtent) {
    return x >= -halfExtent && x <= canvas.width + halfExtent &&
        y >= -halfExtent && y <= canvas.height + halfExtent;
}

function drawIoObstacle(x, y, radius, kind) {
    const art = IO_OBSTACLE_ART[kind];

    // This quiet ground marker is the obstacle's lethal core. The remaining
    // illustrated edge is a forgiving graze zone, so transparent sprite
    // padding can never kill a player who appears clear of the obstacle.
    const collisionRadius = radius * IO_OBSTACLE_HITBOX_SCALE;
    ctx.fillStyle = kind === 2 ? '#7d2830' : '#6a482b';
    ctx.globalAlpha = 0.16;
    ctx.beginPath();
    ctx.arc(x, y, collisionRadius, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = kind === 2 ? '#ed4d50' : '#e89a38';
    ctx.globalAlpha = 0.4;
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.globalAlpha = 1;

    if (art === null || art === undefined) return;
    const sprite = Sprites.get(art.sprite);
    if (sprite === undefined) return;
    let [sourceX, sourceY, sourceWidth, sourceHeight] = art.crop;
    const imageWidth = sprite.naturalWidth || sprite.width || 128;
    const imageHeight = sprite.naturalHeight || sprite.height || 128;
    if (sourceX + sourceWidth > imageWidth || sourceY + sourceHeight > imageHeight) {
        sourceX = 0;
        sourceY = 0;
        sourceWidth = imageWidth;
        sourceHeight = imageHeight;
    }
    const maxSize = radius * 2;
    const scale = Math.min(maxSize / sourceWidth, maxSize / sourceHeight);
    const width = sourceWidth * scale;
    const height = sourceHeight * scale;
    ctx.drawImage(sprite, sourceX, sourceY, sourceWidth, sourceHeight,
        x - width / 2, y - height / 2, width, height);
}

function drawIoArena(t) {
    if (ioFrame === null) return;
    const localIndex = localRosterIndex;
    const local = localIndex >= 0 ? ioFrame.players[localIndex] : ioFrame.players[0];
    if (local === undefined || local.body.length === 0) return;
    const replayCamera = localIndex < 0 && deathReplay !== null && !deathReplay.finished;
    const cameraX = replayCamera ? deathReplay.x : ioPointX(local, 0, t);
    const cameraY = replayCamera ? deathReplay.y : ioPointY(local, 0, t);
    const halfW = canvas.width / 2;
    const halfH = canvas.height / 2;

    if (ioObstacleMask !== null) {
        const removed = (ioObstacleMask & ~ioFrame.obstacleMask) >>> 0;
        for (let obstacleIndex = 0; obstacleIndex < IO_OBSTACLES.length; obstacleIndex++) {
            if ((removed & (1 << obstacleIndex)) === 0) continue;
            const [worldX, worldY, radius, kind] = IO_OBSTACLES[obstacleIndex];
            const x = halfW + ioDelta(worldX, cameraX);
            const y = halfH + ioDelta(worldY, cameraY);
            if (ioIntersectsViewport(x, y, radius)) {
                const burstX = Math.max(0, Math.min(canvas.width, x));
                const burstY = Math.max(0, Math.min(canvas.height, y));
                Particles.burst(burstX, burstY, ['#e89a38', '#87919d', '#ed4d50', '#67b64b'][kind], 20, 5);
            }
        }
    }
    ioObstacleMask = ioFrame.obstacleMask;

    ctx.fillStyle = '#121923';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.strokeStyle = 'rgba(158, 190, 179, 0.08)';
    ctx.lineWidth = 1;
    const grid = 96;
    const offsetX = ((-cameraX + halfW) % grid + grid) % grid;
    const offsetY = ((-cameraY + halfH) % grid + grid) % grid;
    ctx.beginPath();
    for (let x = offsetX; x < canvas.width; x += grid) { ctx.moveTo(x, 0); ctx.lineTo(x, canvas.height); }
    for (let y = offsetY; y < canvas.height; y += grid) { ctx.moveTo(0, y); ctx.lineTo(canvas.width, y); }
    ctx.stroke();

    for (let obstacleIndex = 0; obstacleIndex < IO_OBSTACLES.length; obstacleIndex++) {
        if ((ioFrame.obstacleMask & (1 << obstacleIndex)) === 0) continue;
        const [worldX, worldY, radius, kind] = IO_OBSTACLES[obstacleIndex];
        const x = halfW + ioDelta(worldX, cameraX);
        const y = halfH + ioDelta(worldY, cameraY);
        if (!ioIntersectsViewport(x, y, radius)) continue;
        drawIoObstacle(x, y, radius, kind);
    }

    for (let foodIndex = 0; foodIndex < ioFrame.foodCount; foodIndex++) {
        const slot = ioFrame.foodSlots[foodIndex];
        const mass = ioFrame.foodMass[slot];
        const x = halfW + ioDelta(ioFrame.foodX[slot], cameraX);
        const y = halfH + ioDelta(ioFrame.foodY[slot], cameraY);
        const pickupName = IO_PICKUP_SPRITES[mass];
        const size = pickupName !== null && pickupName !== undefined
            ? 18 + ioFoodGrowth(mass) * 1.7
            : mass === 1 ? 9 : 7;
        const halfSize = size / 2;
        if (!ioIntersectsViewport(x, y, halfSize)) continue;
        const pickup = pickupName === null || pickupName === undefined ? undefined : Sprites.get(pickupName);
        if (pickup !== undefined) {
            ctx.globalAlpha = 0.98;
            ctx.drawImage(pickup, x - size / 2, y - size / 2, size, size);
        } else {
            ctx.fillStyle = mass === 1 ? '#f2cb45' : IO_PELLET_COLORS[slot % IO_PELLET_COLORS.length];
            ctx.globalAlpha = mass === 1 ? 0.92 : 0.78;
            ctx.beginPath();
            ctx.arc(x, y, mass === 1 ? 4.5 : 3.5, 0, Math.PI * 2);
            ctx.fill();
        }
    }
    ctx.globalAlpha = 1;

    const rect = screenRect();
    for (let playerIndex = 0; playerIndex < ioFrame.playerCount; playerIndex++) {
        const player = ioFrame.players[playerIndex];
        const meta = roster[playerIndex];
        if (meta === undefined) continue;
        const style = snakeStyleIndex(meta[2], meta[0]);
        const bodySprite = Sprites.getIo?.('ioBody', style) || Sprites.get('ioBody');
        const tailSprite = Sprites.getIo?.('ioTail', style) || Sprites.get('ioTail');
        const headSprite = Sprites.getIo?.('ioHead', style) || Sprites.get('ioHead');
        const boostSprite = Sprites.get('ioBoost');
        const radius = ioSnakeRadius(player.mass);
        const bodySize = radius * 2;
        const tailSize = radius * 2.45;
        const headSize = radius * 3.05;
        ctx.save();
        for (let index = player.body.length - 1; index >= 0; index--) {
            const pointX = ioPointX(player, index, t);
            const pointY = ioPointY(player, index, t);
            const x = halfW + ioDelta(pointX, cameraX);
            const y = halfH + ioDelta(pointY, cameraY);
            if (index === 0) continue;
            if (index === player.body.length - 1 && tailSprite !== undefined && player.body.length > 1) {
                // The square tail sprite rotates, so its corner—not its
                // unrotated half-width—is the conservative viewport extent.
                const tailExtent = tailSize * Math.SQRT1_2;
                if (!ioIntersectsViewport(x, y, tailExtent)) continue;
                const nearX = ioPointX(player, index - 1, t);
                const nearY = ioPointY(player, index - 1, t);
                const angle = Math.atan2(ioDelta(pointY, nearY), ioDelta(pointX, nearX)) - Math.PI;
                ctx.save();
                ctx.translate(x, y);
                ctx.rotate(angle);
                ctx.drawImage(tailSprite, -tailSize / 2, -tailSize / 2, tailSize, tailSize);
                ctx.restore();
            } else if (bodySprite !== undefined) {
                if (!ioIntersectsViewport(x, y, radius)) continue;
                ctx.drawImage(bodySprite, x - radius, y - radius, bodySize, bodySize);
            }
        }

        const headX = ioPointX(player, 0, t);
        const headY = ioPointY(player, 0, t);
        const hx = halfW + ioDelta(headX, cameraX);
        const hy = halfH + ioDelta(headY, cameraY);
        // Head art rotates as a square. Use its diagonal extent, then widen
        // for the boost and shield effects when either reaches farther.
        const headHalfSize = Math.max(headSize * Math.SQRT1_2,
            player.boosting ? headSize * 0.75 : 0,
            player.shielded ? headSize * 0.72 + 2 : 0,
            radius * 1.35);
        const headVisible = ioIntersectsViewport(hx, hy, headHalfSize);
        if (headVisible) {
            if (player.boosting && boostSprite !== undefined) {
                const boostSize = headSize * 1.5;
                ctx.drawImage(boostSprite, hx - boostSize / 2, hy - boostSize / 2, boostSize, boostSize);
            }
            if (player.shielded) {
                ctx.strokeStyle = '#ff71ce';
                ctx.lineWidth = 3;
                ctx.globalAlpha = 0.85;
                ctx.beginPath();
                ctx.arc(hx, hy, headSize * 0.72, 0, Math.PI * 2);
                ctx.stroke();
                ctx.globalAlpha = 1;
            }
            if (headSprite !== undefined) {
                const predictedAngle = playerIndex === localIndex ? getPredictedSteerAngle() : null;
                const headAngle = predictedAngle === null
                    ? ioInterpolateAngle(player.previousAngle, player.angle, t)
                    : predictedAngle;
                ctx.translate(hx, hy);
                ctx.rotate(headAngle);
                ctx.drawImage(headSprite, -headSize / 2, -headSize / 2, headSize, headSize);
                ctx.rotate(-headAngle);
                ctx.translate(-hx, -hy);
            } else {
                ctx.fillStyle = meta[2];
                ctx.beginPath();
                ctx.arc(hx, hy, radius * 1.35, 0, Math.PI * 2);
                ctx.fill();
            }
        }
        ctx.restore();
        if (headVisible && meta[0] === socket.id && !player.boosting) {
            ctx.strokeStyle = '#fffaf1';
            ctx.lineWidth = 2.5;
            ctx.beginPath();
            ctx.arc(hx, hy, headSize / 2 + 2, 0, Math.PI * 2);
            ctx.stroke();
        }

        const plate = nameplates.get(meta[0]);
        if (plate !== undefined) {
            plate.screenX = rect.left + hx * rect.width / canvas.width;
            plate.screenY = rect.top + hy * rect.height / canvas.height;
            plate.element.hidden = hx < 0 || hx > canvas.width || hy < 0 || hy > canvas.height;
        }
    }
}

function refreshDanger(now) {
    if (gameMode !== 'arcade' || spectating || now - lastDangerCheck < DANGER_CHECK_MS) return;
    lastDangerCheck = now;
    dangerId = null;
    const local = snakeList.get(socket.id);
    const localHead = local?.snake[0];
    const localPrevious = local?.prevSnake?.[0];
    if (localHead === undefined || localPrevious === undefined) return;

    let nearestDistance = DANGER_RADIUS * DANGER_RADIUS;
    for (const [id, other] of snakeList) {
        if (id === socket.id) continue;
        const head = other.snake[0];
        const previous = other.prevSnake?.[0];
        if (head === undefined || previous === undefined) continue;
        const x = head.x - localHead.x;
        const y = head.y - localHead.y;
        const distance = x * x + y * y;
        if (distance === 0 || distance > nearestDistance) continue;
        const relativeX = (head.x - previous.x) - (localHead.x - localPrevious.x);
        const relativeY = (head.y - previous.y) - (localHead.y - localPrevious.y);
        if (x * relativeX + y * relativeY >= 0) continue;
        dangerId = id;
        nearestDistance = distance;
    }
}

function drawDanger(t, now) {
    if (gameMode !== 'arcade' || spectating) return;
    refreshDanger(now);
    if (dangerId === null) return;
    const local = snakeList.get(socket.id);
    const threat = snakeList.get(dangerId);
    const localHead = local?.snake[0], threatHead = threat?.snake[0];
    if (localHead === undefined || threatHead === undefined) return;
    const localPrev = local.interpolate && local.prevSnake?.[0] || localHead;
    const threatPrev = threat.interpolate && threat.prevSnake?.[0] || threatHead;
    // Both snakes use the same presentation clock. Keep the warning anchored
    // to the head the player can actually see rather than its next grid cell.
    const localX = localPrev.x + (localHead.x - localPrev.x) * t + 8;
    const localY = localPrev.y + (localHead.y - localPrev.y) * t + 8;
    const threatX = threatPrev.x + (threatHead.x - threatPrev.x) * t + 8;
    const threatY = threatPrev.y + (threatHead.y - threatPrev.y) * t + 8;
    const dx = threatX - localX, dy = threatY - localY;
    const length = Math.hypot(dx, dy);
    if (length === 0) return;
    const ux = dx / length, uy = dy / length;
    const px = -uy, py = ux;
    const tipX = localX + ux * 34, tipY = localY + uy * 34;
    const backX = tipX - ux * 8, backY = tipY - uy * 8;

    ctx.save();
    ctx.globalAlpha = 0.76;
    ctx.strokeStyle = '#b93d35';
    ctx.lineWidth = 2.5;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.beginPath();
    ctx.moveTo(backX + px * 5, backY + py * 5);
    ctx.lineTo(tipX, tipY);
    ctx.lineTo(backX - px * 5, backY - py * 5);
    ctx.stroke();
    ctx.restore();
}

function drawDeathReplay(now) {
    if (deathReplay === null || deathReplay.finished) return;
    const remaining = deathReplay.until - now;
    if (remaining <= 0) {
        deathReplay.finished = true;
        gameOverMenu?.finishReplay?.();
        return;
    }
    gameOverMenu?.setReplay?.(remaining);
    const progress = (now - deathReplay.startedAt) / deathReplay.duration;
    const radius = reducedMotion.matches ? 28 : 24 + Math.max(0, Math.min(1, progress)) * 14;
    ctx.save();
    ctx.globalAlpha = Math.max(0.25, remaining / deathReplay.duration);
    ctx.strokeStyle = '#f5efe6';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(gameMode === 'snek_io' ? canvas.width / 2 : deathReplay.x,
        gameMode === 'snek_io' ? canvas.height / 2 : deathReplay.y,
        radius, 0, Math.PI * 2);
    ctx.stroke();
    ctx.restore();
}

function frame(now) {
    framePending = false;
    const dt = lastFrameAt === 0 ? 16 : now - lastFrameAt;
    lastFrameAt = now;
    if (!isSetup) return;

    if (gameOver) {
        // Keep the game-over screen painted (the loop would otherwise wipe
        // the once-drawn menu) while particles finish flying.
        Particles.update(dt);
        Particles.draw(ctx);
        if (Particles.hasActive()) requestFrame();
        return;
    }

    // Active play always animates interpolation and world pickups. Queue the
    // next frame before drawing so an optional visual effect cannot strand the
    // authoritative game loop if it throws.
    requestFrame();

    const t = remoteInterpolation.progress(now);
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    ctx.save();
    if (now < shakeUntil) {
        const mag = (shakeUntil - now) / 450 * 6;
        ctx.translate((Math.random() - 0.5) * 2 * mag, (Math.random() - 0.5) * 2 * mag);
    }

    drawWorld(now);
    const canvasRect = screenRect();
    const localDirection = getPredictedDirection();
    if (gameMode === 'snek_io') {
        drawIoArena(t);
    } else for (let snake of snakeList.values()) {
        const isLocal = snake.id === socket.id;
        // Use one display-refresh presentation clock for every snake. Local
        // steering intent still updates the eyes on the next animation frame,
        // while its body and nameplate no longer jump one cell at 15 Hz.
        snake.draw(t, isLocal, isLocal ? localDirection : null);
        prepareNameplate(snake, t, canvasRect);
    }
    drawDanger(t, now);
    drawDeathReplay(now);
    placeNameplates(canvasRect);
    Particles.update(dt);
    Particles.draw(ctx);
    ctx.restore();
}

(async () => {
    await Sprites.load();
    Hud.init();
    Hud.setMuted(Sfx.muted);
    document.getElementById('hud_mute').addEventListener('click', () => {
        Hud.setMuted(Sfx.toggle());
    });
    Motion.popup(document.querySelector('#game_popup .popup'));
    renderReady = true;
    if (isSetup) requestFrame();
})();
