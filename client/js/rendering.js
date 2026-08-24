import Snake from "./snake.js";
import GameOverMenu from "./menu/gameOverMenu.js";
import Food from "./food.js";
import ResourceHandler from "./resourceHandler.js";
import { Sprites } from "./sprites.js";
import { Sfx } from "./audio.js";
import { Particles } from "./particles.js";
import { Hud } from "./hud.js";

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
let lastTickAt = 0;
let shakeUntil = 0;
let lastFrameAt = 0;
const prevScores = new Map();

let resourceHandler = new ResourceHandler();
resourceHandler.loadImages();

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

socket.on("gameTick", (data) => {
    if (!isSetup || gameOver) return;

    // Score-delta detection: particle burst + sound for every eat.
    const seen = new Set();
    for (const playerData of data.players) {
        seen.add(playerData.id);
        const before = prevScores.has(playerData.id) ? prevScores.get(playerData.id) : playerData.score;
        if (playerData.score > before) {
            const head = playerData.snake[0];
            Particles.burst(head.x + 8, head.y + 8, playerData.color, playerData.id === socket.id ? 18 : 8);
            if (playerData.id === socket.id) {
                Sfx.eat();
                Hud.popScore();
            }
        }
        prevScores.set(playerData.id, playerData.score);
    }
    for (const id of [...prevScores.keys()]) {
        if (!seen.has(id)) prevScores.delete(id);
    }

    // Reuse existing Snake objects instead of rebuilding everything,
    // and drop snakes for players that are gone.
    for (let i = 0; i < data.players.length; i++) {
        let snake = snakeList.get(data.players[i].id);
        if (snake === undefined) {
            snakeList.set(data.players[i].id, new Snake(ctx, data.players[i]));
        } else {
            snake.update(data.players[i]);
        }
    }
    for (let id of [...snakeList.keys()]) {
        if (!data.players.some((p) => p.id === id)) snakeList.delete(id);
    }

    world = data;
    lastTickAt = performance.now();
    Hud.update(data.players, socket.id);
});

// Zig protocol v2: immutable identity metadata arrives only on membership
// changes. The following compact ticks are positional arrays aligned to it.
socket.on("r", (nextRoster) => {
    if (!Array.isArray(nextRoster)) return;
    const live = new Set();
    const nextPlayers = new Array(nextRoster.length);
    for (let i = 0; i < nextRoster.length; i++) {
        const meta = nextRoster[i];
        if (!Array.isArray(meta) || meta.length < 3) return;
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
});

function resizeObjects(array, length) {
    while (array.length < length) array.push({ x: 0, y: 0 });
    array.length = length;
}

socket.on("tick", (tick) => {
    if (!isSetup || gameOver || !Array.isArray(tick) || tick.length < 4) return;
    const rows = tick[0];
    if (!Array.isArray(rows) || rows.length !== roster.length) return;

    for (let i = 0; i < rows.length; i++) {
        const meta = roster[i];
        const row = rows[i];
        if (!Array.isArray(row) || !Array.isArray(row[2])) return;
        const state = compactPlayers[i];
        const before = state.score;
        let snake = snakeList.get(meta[0]);
        if (snake === undefined) {
            snake = new Snake(ctx, [meta, row], true);
            snakeList.set(meta[0], snake);
        } else snake.updateCompact(meta, row);
        state.score = row[0];
        state.bodyLength = row[1];
        state.snake = snake.snake;
        if (state.score > before && snake.snake.length > 0) {
            const head = snake.snake[0];
            Particles.burst(head.x + 8, head.y + 8, state.color, state.id === socket.id ? 18 : 8);
            if (state.id === socket.id) {
                Sfx.eat();
                Hud.popScore();
            }
        }
    }

    const bonus = tick[1];
    if (!Array.isArray(bonus) || (bonus.length & 1) !== 0) return;
    resizeObjects(world.bonus, bonus.length >> 1);
    for (let i = 0, c = 0; i < bonus.length; i += 2, c++) {
        world.bonus[c].x = bonus[i] * 16;
        world.bonus[c].y = bonus[i + 1] * 16;
    }

    const drops = tick[2];
    if (!Array.isArray(drops)) return;
    resizeObjects(world.drops, drops.length);
    for (let i = 0; i < drops.length; i++) {
        const row = drops[i];
        const drop = world.drops[i];
        drop.id = row[0];
        drop.x = row[1] * 16;
        drop.y = row[2] * 16;
        drop.ttl = row[3];
    }
    const golden = tick[3];
    if (golden === null) world.golden = null;
    else {
        if (world.golden === null) world.golden = { x: 0, y: 0, ttl: 0 };
        world.golden.x = golden[0] * 16;
        world.golden.y = golden[1] * 16;
        world.golden.ttl = golden[2];
    }
    world.players = compactPlayers;
    lastTickAt = performance.now();
    Hud.update(compactPlayers, socket.id);
});

socket.on('init', (initData) => {
    document.getElementById('game_popup').style.display = 'none';

    food = new Food(ctx, initData.food.x, initData.food.y);
    gameOver = false;
    gameOverMenu = null;
    isSetup = true;
    if (window.gsap) window.gsap.fromTo(canvas, { opacity: 0.4 }, { opacity: 1, duration: 0.4 });
});

socket.on('game_error', (errorMessage) => {
    showError(errorMessage);
});

socket.on('updateFood', (data) => {
    if (!isSetup || gameOver) return;
    food = new Food(ctx, data.x, data.y);
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
    requestAnimationFrame(frame);
    const dt = lastFrameAt === 0 ? 16 : now - lastFrameAt;
    lastFrameAt = now;
    if (!isSetup) return;

    if (gameOver) {
        // Keep the game-over screen painted (the loop would otherwise wipe
        // the once-drawn menu) while particles finish flying.
        Particles.update(dt);
        Particles.draw(ctx);
        return;
    }

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
    if (window.gsap) {
        window.gsap.from('#game_popup .popup', { y: -50, opacity: 0, duration: 0.5, ease: 'back.out(1.6)' });
    }
    requestAnimationFrame(frame);
})();
