import Snake from "./snake.js";
import GameOverMenu from "./menu/gameOverMenu.js";
import { Sprites } from "./sprites.js";
import { Sfx } from "./audio.js";
import { Particles } from "./particles.js";
import { Hud, Motion } from "./hud.js";
import { decodeSnapshot } from "./snapshot.js";
import { releaseBoost, resetDirection, setGameMode, setGameplayEnabled, syncDirection } from "./userInput.js";

// Module scripts run after the DOM is parsed, so the canvas/socket exist
// already. Wiring handlers here instead of inside window.onload avoids a
// soft-lock when slow render-blocking resources delay onload past the point
// where the player joins.
const canvas = document.getElementById("canvas");
const ctx = canvas.getContext('2d');
const nameplateLayer = document.getElementById("nameplates");

const TICK_MS = 1000 / 15; // must match the server game loop
const DROP_TTL_MS = 25000;
const DEATH_REPLAY_MS = 3500;
const DANGER_CHECK_MS = 100;
const DANGER_RADIUS = 32 * 16;

const snakeList = new Map();
const nameplates = new Map();
let food = null;
let isSetup = false;
let gameOver = false;
let spectating = false;
let gameMode = 'arcade_v1';
let errorTimeout = null;
let gameOverMenu = null;
let deathReplay = null;

// World pickups (supply drops, bonus apples, golden apple).
let world = { bonus: [], drops: [], golden: null, remains: [], feastTtl: 0, bountyId: null };
let roster = [];
let compactPlayers = [];
const compactById = new Map();
let lastSnapshotSequence = null;
let lastTickAt = 0;
let shakeUntil = 0;
let lastFrameAt = 0;
let renderReady = false;
let framePending = false;
const prevScores = new Map();
const reducedMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)') || { matches: false };
let lastDangerCheck = -Infinity;
let dangerId = null;

function requestFrame(resuming = false) {
    if (!renderReady || framePending) return;
    if (resuming) lastFrameAt = 0;
    framePending = true;
    requestAnimationFrame(frame);
}

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
        plate = { element, displayName: '', screenX: 0, screenY: 0, below: false };
        nameplates.set(id, plate);
    }
    if (plate.displayName !== displayName) {
        plate.displayName = displayName;
        plate.element.textContent = displayName;
    }
    plate.element.classList.toggle('is-local', id === socket.id);
    plate.element.classList.toggle('is-bounty', id === world.bountyId && gameMode === 'arcade_v2');
}

function removeNameplate(id) {
    const plate = nameplates.get(id);
    if (plate === undefined) return;
    plate.element.remove();
    nameplates.delete(id);
}

function setBountyId(id) {
    const next = gameMode === 'arcade_v2' && typeof id === 'string' ? id : null;
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
        const halfWidth = Math.min((plate.element.offsetWidth || 0) / 2, Math.max(0, rect.width / 2 - 8));
        plate.screenX = Math.max(rect.left + halfWidth + 8, Math.min(right - halfWidth - 8, plate.screenX));
        plate.below = plate.screenY < rect.top + (plate.element.offsetHeight || 28) + 10;
    }
    for (const plate of nameplates.values()) {
        if (plate.element.hidden) continue;
        plate.element.style.translate = `${plate.screenX}px ${plate.screenY}px`;
        plate.element.classList.toggle('is-below', plate.below);
    }
}

// Immutable identity metadata arrives only on membership changes. Binary
// snapshots are positional records aligned to this roster.
socket.on("r", (nextRoster) => {
    if (!Array.isArray(nextRoster) || nextRoster.length > 32) return;
    const ids = new Set();
    for (const meta of nextRoster) {
        if (!Array.isArray(meta) || meta.length !== 3 ||
            typeof meta[0] !== "string" || meta[0].length === 0 ||
            typeof meta[1] !== "string" || typeof meta[2] !== "string" || ids.has(meta[0])) return;
        ids.add(meta[0]);
    }
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
    // The server follows every changed roster with an independent keyframe.
    lastSnapshotSequence = null;
});

function resizeObjects(array, length) {
    while (array.length < length) array.push({ x: 0, y: 0 });
    array.length = length;
}

// The decoder validates the complete v5 frame into bounded scratch storage
// before any visible game state is committed here.
socket.on("b", (payload) => {
    if (!isSetup || gameOver) return;
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
        resizeObjects(world.remains, gameMode === 'arcade_v2' ? frame.remainsCount : 0);
        for (let index = 0; index < world.remains.length; index++) {
            const remain = world.remains[index];
            remain.x = frame.remains[index].x * 16;
            remain.y = frame.remains[index].y * 16;
            remain.ttl = frame.remains[index].ttl;
        }
        world.feastTtl = gameMode === 'arcade_v2' ? frame.feastTtl : 0;
        setBountyId(gameMode === 'arcade_v2' && frame.hasBounty ? roster[frame.bountySlot]?.[0] : null);
        world.players = compactPlayers;
        lastSnapshotSequence = frame.sequence;
        lastTickAt = performance.now();
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
    document.getElementById('game_popup').style.display = 'none';
    gameMode = initData.mode === 'arcade_v2'
        ? 'arcade_v2'
        : initData.mode === 'classical' || initData.classical === true ? 'classical' : 'arcade_v1';
    Hud.setMode(gameMode);
    setGameMode(gameMode);

    food = { x: initData.food.x, y: initData.food.y };
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
        // Arcade v2 attribution is identity-based: display names are not unique.
        const victimId = item.victimId ?? item.whoId ?? item.id;
        const victim = typeof victimId === 'string'
            ? compactById.get(victimId)
            : gameMode === 'arcade_v2' ? undefined : (world.players || []).find((p) => p.displayName === item.who);
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
    Particles.burst(focusX, focusY, me !== undefined ? me.color : '#e74c3c', 40, 5);
    gameOverMenu?.destroy?.();

    if (gameMode === 'arcade_v2') {
        gameOver = false;
        spectating = true;
        deathReplay = { x: focusX, y: focusY, startedAt: now, until: now + replayMs, duration: replayMs, finished: false };
        gameOverMenu = new GameOverMenu(ctx, { compact: true });
        gameOverMenu.setReplay(replayMs);
    } else {
        gameOver = true; // Established Classical / Arcade v1 terminal presentation.
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
    if (!gameOver) showError('Disconnected from server');
});

// ---- Render loop: interpolated movement at display refresh rate ----
function drawWorld(now) {
    // Arcade v2 remains stay deliberately quieter than apples: neutral matte
    // pellets communicate edible mass without turning a death into confetti.
    if (gameMode === 'arcade_v2') {
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

function refreshDanger(now) {
    if (gameMode !== 'arcade_v2' || spectating || now - lastDangerCheck < DANGER_CHECK_MS) return;
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
    if (gameMode !== 'arcade_v2' || spectating) return;
    refreshDanger(now);
    if (dangerId === null) return;
    const local = snakeList.get(socket.id);
    const threat = snakeList.get(dangerId);
    const localHead = local?.snake[0], threatHead = threat?.snake[0];
    if (localHead === undefined || threatHead === undefined) return;
    const localPrev = local.prevSnake?.[0] || localHead;
    const threatPrev = threat.prevSnake?.[0] || threatHead;
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
    ctx.arc(deathReplay.x, deathReplay.y, radius, 0, Math.PI * 2);
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

    const t = Math.min(1, (now - lastTickAt) / TICK_MS);
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    ctx.save();
    if (now < shakeUntil) {
        const mag = (shakeUntil - now) / 450 * 6;
        ctx.translate((Math.random() - 0.5) * 2 * mag, (Math.random() - 0.5) * 2 * mag);
    }

    drawWorld(now);
    const canvasRect = canvas.getBoundingClientRect();
    for (let snake of snakeList.values()) {
        snake.draw(t, snake.id === socket.id);
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
