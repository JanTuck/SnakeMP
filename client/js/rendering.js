import Snake from "./snake.js";
import GameOverMenu from "./menu/gameOverMenu.js";
import { Sprites } from "./sprites.js";
import { Sfx } from "./audio.js";
import { Particles } from "./particles.js";
import { Hud, Motion } from "./hud.js";
import { decodeSnapshot } from "./snapshot.js";

// Module scripts run after the DOM is parsed, so the canvas/socket exist
// already. Wiring handlers here instead of inside window.onload avoids a
// soft-lock when slow render-blocking resources delay onload past the point
// where the player joins.
const canvas = document.getElementById("canvas");
const ctx = canvas.getContext('2d');

const TICK_MS = 1000 / 15; // must match the server game loop
const DROP_TTL_MS = 25000;

const snakeList = new Map();
let food = null;
let isSetup = false;
let gameOver = false;
let errorTimeout = null;
let gameOverMenu = null;

// World pickups (supply drops, bonus apples, golden apple).
let world = { bonus: [], drops: [], golden: null };
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

// Immutable identity metadata arrives only on membership changes. Binary
// snapshots are positional records aligned to this roster.
socket.on("r", (nextRoster) => {
    if (!Array.isArray(nextRoster) || nextRoster.length > 16) return;
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
        }
    }
    roster = nextRoster;
    compactPlayers = nextPlayers;
    // The server follows every changed roster with an independent keyframe.
    lastSnapshotSequence = null;
});

function resizeObjects(array, length) {
    while (array.length < length) array.push({ x: 0, y: 0 });
    array.length = length;
}

// The decoder validates the complete v3 frame into bounded scratch storage
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
    try { Hud.update(compactPlayers, socket.id); } catch (_) {}
});

socket.on('init', (initData) => {
    document.getElementById('game_popup').style.display = 'none';

    food = { x: initData.food.x, y: initData.food.y };
    gameOver = false;
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
    Hud.feed(item);
    if (item.type === 'drop-open') Sfx.drop();
    else if (item.type === 'golden') Sfx.golden();
    else if (item.type === 'join') Sfx.join();
    else if (item.type === 'drop-incoming') Sfx.countIn();
    else if (item.type === 'death' && item.who !== undefined) {
        // Burst at the victim's last known position (not our own screen centre).
        const victim = (world.players || []).find((p) => p.displayName === item.who);
        if (victim !== undefined) {
            Particles.burst(victim.snake[0].x + 8, victim.snake[0].y + 8, victim.color, 24, 4);
            requestFrame(true);
        }
    }
});

socket.on('death', (score) => {
    gameOver = true; // Stop drawing ticks over the game over screen.
    Sfx.death();
    shakeUntil = performance.now() + 450;
    // Burst where OUR snake actually died (last known head position).
    const me = snakeList.get(socket.id);
    const head = me !== undefined ? me.snake[0] : null;
    Particles.burst(head !== null ? head.x + 8 : canvas.width / 2,
                    head !== null ? head.y + 8 : canvas.height / 2,
                    me !== undefined ? me.color : '#e74c3c', 40, 5);
    gameOverMenu = new GameOverMenu(ctx);
    gameOverMenu.setScore(score);
    gameOverMenu.draw();
    requestFrame(true);
});

socket.on('disconnect', () => {
    if (!gameOver) showError('Disconnected from server');
});

// ---- Render loop: interpolated movement at display refresh rate ----
function drawWorld(now) {
    // Main apple with a gentle bob so the board feels alive.
    if (food !== null) {
        const bob = Math.sin(now / 220) * 1.5;
        drawSprite('apple', food.x, food.y + bob, 16);
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
    for (let snake of snakeList.values()) {
        snake.draw(t);
        snake.drawDisplayName();
    }
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
