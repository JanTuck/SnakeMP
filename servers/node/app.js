const createError = require('http-errors');
const CONSTANTS = require("./src/constants");
const express = require('express');
const path = require('path');
const logger = require('morgan');
const Player = require('./src/player');
const uniqueId = require('./src/generateId');
const color = require('rcolor');
const Environment = require("./src/environment");
const Food = require("./src/food");
const InputValidation = require("./src/inputvalidation");

const app = express();

const http = require('http').createServer(app);
const io = require('socket.io')(http, {
    // Heartbeats reap clients that vanished without a disconnect (closed tab,
    // dropped network) within roughly pingInterval + pingTimeout.
    pingInterval: 20000,
    pingTimeout: 15000,
});

// view engine setup
app.set('views', path.join(__dirname, 'views'));
app.set('view engine', 'pug');

app.disable('x-powered-by');
app.use((req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    next();
});

app.use(logger('dev'));
app.use(express.urlencoded({extended: false}));
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));
const sharedClient = path.join(__dirname, '..', '..', 'client');

app.get('/', (req, res) => {
    res.sendFile(path.join(sharedClient, 'index.html'));
});
app.post('/generateid', (req, res) => {
    let gameId;
    do {
        gameId = uniqueId();
    } while (lobbies.has(gameId));
    createLobby(gameId);
    // 303 so a refresh of the landing page cannot re-submit the POST.
    res.redirect(303, `/game/${encodeURIComponent(gameId)}`);
});
app.post('/joingame', (req, res) => {
    const rawGameId = req.body && req.body.gameId;
    if (typeof rawGameId === 'string') {
        const gameId = rawGameId.trim();
        if (lobbies.has(gameId)) {
            res.redirect(303, `/game/${encodeURIComponent(gameId)}`);
            return;
        }
    }
    // Unknown/bad id: back home with feedback instead of a silent bounce.
    res.redirect(303, '/?error=unknown-game');
});

app.get('/game/:id', (req, res) => {
    if (lobbies.has(req.params.id))
        res.sendFile(path.join(sharedClient, 'game.html'));
    else
        res.redirect('/');
});
// The lobby id gate must also apply when /game.html is requested directly,
// otherwise express.static below would serve it to anyone.
app.get('/game.html', (req, res) => {
    res.redirect('/');
});
app.use(express.static(sharedClient));

// Optional debug endpoint for benchmarking; never on in normal deployments.
if (process.env.SNEK_DEBUG === '1') {
    app.get('/debug/stats', (req, res) => {
        res.json({
            rss: process.memoryUsage().rss,
            uptime: process.uptime(),
            totalPlayers: totalPlayers(),
            lobbies: [...lobbies.values()].map((l) => ({
                id: l.id,
                players: l.players.size,
                drops: l.drops.length,
                bonus: l.bonusFoods.length,
                golden: l.golden !== null,
                lastTickMs: l.stats.lastTickMs,
                avgTickMs: Math.round(l.stats.avgTickMs * 10) / 10,
                maxTickMs: l.stats.maxTickMs,
            })),
        });
    });
}

// catch 404 and forward to error handler
app.use(function (req, res, next) {
    next(createError(404));
});

// error handler
app.use((err, req, res, next) => {
    // set locals, only providing error in development
    res.locals.message = err.message;
    res.locals.error = req.app.get('env') === 'development' ? err : {};

    // render the error page
    const status = err.status || 500;
    res.status(status);
    res.render('error', {status});
});


const PORT = process.env.PORT || 3000;
http.on('error', (err) => {
    console.error('server error:', err.message);
    process.exit(1);
});
http.listen(PORT, function () {
    console.log(`listening on *:${PORT}`);
});

// Graceful shutdown: stop ticking and close everything cleanly.
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
function shutdown() {
    if (gameLoop !== null) clearInterval(gameLoop);
    io.close();
    http.close(() => process.exit(0));
    // Fallback exit if connections refuse to drain.
    setTimeout(() => process.exit(0), 2000).unref();
}

// ---------------------------------------------------------------------------
// Lobbies: every game id is an isolated arena with its own food, pickups,
// tick state and broadcast room.
// ---------------------------------------------------------------------------
const MAX_PLAYERS_GLOBAL = 100;   // concurrent players across all lobbies
const MAX_PLAYERS_PER_LOBBY = 16; // keeps a single arena playable
const LOBBY_IDLE_DELETE_MS = 60000;
const DEFAULT_LOBBY_ID = '12345';

const lobbies = new Map();        // id -> lobby
const LOBBY_ROOM = (id) => 'lobby:' + id;

function createLobby(id) {
    const lobby = {
        id,
        sockets: new Map(),         // socketId -> socket
        players: new Map(),         // socketId -> Player
        food: new Food(),
        bonusFoods: [],             // [{x, y}]
        drops: [],                  // [{id, x, y, expiresAt}]
        golden: null,               // {x, y, expiresAt} | null
        nextDropAt: 0,
        nextGoldenAt: 0,
        dropSeq: 1,
        lastEmptyAt: 0,
        stats: {lastTickMs: 0, avgTickMs: 0, maxTickMs: 0, ticks: 0},
    };
    lobbies.set(id, lobby);
    return lobby;
}
createLobby(DEFAULT_LOBBY_ID); // always-available public lobby

const totalPlayers = () => [...lobbies.values()].reduce((n, l) => n + l.players.size, 0);

// ---- Bonus world constants ----
const BONUS_CAP = 12;
const DROP_TTL = 25000;          // crates despawn 25s after landing
const GOLDEN_TTL = 12000;        // golden apple lasts 12s
const DROP_POINTS = 2;           // opening a crate scores this much...
const DROP_GROWTH = 2;           // ...and grows the snake by this much
const DROP_APPLES = 4;           // apples released when a crate opens
const GOLDEN_POINTS = 3;

const activePlayers = (lobby) => [...lobby.players.values()];

/**
 * Find a random cell in this lobby free of snakes and every pickup kind.
 */
const randomFreeCell = (lobby) => {
    for (let attempt = 0; attempt < 200; attempt++) {
        const cell = Environment.getRanLocation();
        const taken =
            activePlayers(lobby).some((p) => p.snake.some((s) => s.x === cell.x && s.y === cell.y)) ||
            (lobby.food.x === cell.x && lobby.food.y === cell.y) ||
            lobby.bonusFoods.some((b) => b.x === cell.x && b.y === cell.y) ||
            lobby.drops.some((d) => d.x === cell.x && d.y === cell.y) ||
            (lobby.golden !== null && lobby.golden.x === cell.x && lobby.golden.y === cell.y);
        if (!taken) return cell;
    }
    return null;
};

const spawnDrop = (lobby) => {
    const cell = randomFreeCell(lobby);
    if (cell === null) return;
    lobby.drops.push({id: 'drop-' + (lobby.dropSeq++), x: cell.x, y: cell.y, expiresAt: Date.now() + DROP_TTL});
    io.to(LOBBY_ROOM(lobby.id)).emit('feed', {type: 'drop-incoming'});
};

const spawnGolden = (lobby) => {
    const cell = randomFreeCell(lobby);
    if (cell === null) return;
    lobby.golden = {x: cell.x, y: cell.y, expiresAt: Date.now() + GOLDEN_TTL};
};

const openDrop = (lobby, player) => {
    player.eat(DROP_POINTS, DROP_GROWTH);
    let spawned = 0;
    for (let i = 0; i < DROP_APPLES; i++) {
        if (lobby.bonusFoods.length >= BONUS_CAP) break;
        const cell = randomFreeCell(lobby);
        if (cell === null) break;
        lobby.bonusFoods.push(cell);
        spawned++;
    }
    io.to(LOBBY_ROOM(lobby.id)).emit('feed', {type: 'drop-open', who: player.displayName, apples: spawned});
};

const respawnFood = (lobby) => {
    for (let attempt = 0; attempt < 100; attempt++) {
        lobby.food.generateRandom();
        const occupied = activePlayers(lobby).some((p) =>
            p.snake.some((part) => part.x === lobby.food.x && part.y === lobby.food.y));
        if (!occupied) return;
    }
};

const removePlayer = (lobby, player) => {
    const socket = lobby.sockets.get(player.id);
    if (socket) {
        socket.leave(LOBBY_ROOM(lobby.id));
        // Allow the same socket to join again (Retry without reload).
        socket.player = null;
        socket.lobbyId = null;
    }
    lobby.sockets.delete(player.id);
    return lobby.players.delete(player.id);
};

//Set the game tick to 15fps
const TICK_MS = 1000 / 15;
let gameLoop = null;

const ensureGameLoopRunning = () => {
    if (gameLoop === null) {
        gameLoop = setInterval(tickAllLobbies, TICK_MS);
    }
};

const stopGameLoopIfIdle = () => {
    if (gameLoop !== null && totalPlayers() === 0) {
        clearInterval(gameLoop);
        gameLoop = null;
    }
};

io.on('connection', (socket) => {
    console.log("Player connected on " + socket.id);

    socket.on('clientReady', (username, lobbyId) => {
        // socket.player is cleared on death and disconnect, so a client may
        // rejoin on the same socket (e.g. pressing Retry without a reload).
        if (socket.player) return;
        if (typeof username !== 'string' || !InputValidation.isValidUsername(username)) {
            socket.emit('game_error', CONSTANTS.ERRORS.INVALID_USERNAME);
            return;
        }
        const target = (typeof lobbyId === 'string' && lobbies.has(lobbyId)) ? lobbies.get(lobbyId) : null;
        if (target === null) {
            socket.emit('game_error', CONSTANTS.ERRORS.UNKNOWN_GAME);
            return;
        }
        if (totalPlayers() >= MAX_PLAYERS_GLOBAL) {
            socket.emit('game_error', CONSTANTS.ERRORS.SERVER_FULL);
            return;
        }
        if (target.players.size >= MAX_PLAYERS_PER_LOBBY) {
            socket.emit('game_error', CONSTANTS.ERRORS.LOBBY_FULL);
            return;
        }

        const initObj = {scale: CONSTANTS.gridSize, food: {x: target.food.x, y: target.food.y}};
        socket.emit('init', initObj);

        // Spawn away from other players AND from the current food item.
        let playerPosition;
        for (let attempt = 0; attempt < 100; attempt++) {
            playerPosition = Environment.startPosition(activePlayers(target));
            if (playerPosition.x !== target.food.x || playerPosition.y !== target.food.y) break;
        }
        const player = new Player(socket.id, username.trim(), playerPosition.x, playerPosition.y, color());
        socket.player = player;
        socket.lobbyId = target.id;
        target.sockets.set(socket.id, socket);
        target.players.set(socket.id, player);
        // Live players receive the periodic broadcasts; dead ones stop.
        socket.join(LOBBY_ROOM(target.id));
        io.to(LOBBY_ROOM(target.id)).emit('feed', {type: 'join', who: player.displayName});
        ensureGameLoopRunning();
    });

    socket.on('keyPress', (data) => {
        const player = socket.player;
        if (player === undefined || player === null) return; // Cannot steer before joining.
        player.setDirection(data);
    });

    socket.on('disconnect', () => {
        console.log(socket.id + " disconnected");
        const lobby = socket.lobbyId ? lobbies.get(socket.lobbyId) : null;
        if (lobby !== null && socket.player) {
            removePlayer(lobby, socket.player);
            if (lobby.players.size === 0 && lobby.id !== DEFAULT_LOBBY_ID) {
                lobby.lastEmptyAt = Date.now();
            }
        }
        socket.player = null;
        socket.lobbyId = null;
    });
});

/**
 * Tick one lobby: collisions, pickups, drops, movement, broadcast.
 */
const tickLobby = (lobby, now) => {
    const t0 = process.hrtime.bigint();

    // Expire stale pickups and schedule the next supply drop / golden apple.
    lobby.drops = lobby.drops.filter((d) => d.expiresAt > now);
    if (lobby.golden !== null && lobby.golden.expiresAt <= now) lobby.golden = null;
    if (lobby.nextDropAt === 0) lobby.nextDropAt = now + 8000;
    if (lobby.nextGoldenAt === 0) lobby.nextGoldenAt = now + 20000;
    if (now >= lobby.nextDropAt && lobby.drops.length < 2) {
        spawnDrop(lobby);
        lobby.nextDropAt = now + 12000 + Math.floor(Math.random() * 8000);
    }
    if (now >= lobby.nextGoldenAt && lobby.golden === null) {
        spawnGolden(lobby);
        lobby.nextGoldenAt = now + 25000 + Math.floor(Math.random() * 15000);
    }

    // Snapshot: players that die mid-tick must not keep acting this tick.
    const sockets = [...lobby.sockets.values()];

    for (let socket of sockets) {
        // Skip players already killed earlier in this same tick.
        if (lobby.sockets.get(socket.id) !== socket) continue;

        let player = socket.player;

        //Player collides with himself or the wall.
        if (player.collided()) {
            socket.emit('death', player.score);
            io.to(LOBBY_ROOM(lobby.id)).emit('feed', {type: 'death', who: player.displayName, score: player.score});
            removePlayer(lobby, player);
            continue;
        }

        //Player collides with someone else
        let collided = player.collidedOther(activePlayers(lobby));
        if (collided !== null) {
            socket.emit('death', player.score);
            const otherSocket = lobby.sockets.get(collided.id);
            if (otherSocket) {
                otherSocket.emit('death', collided.score);
            }
            io.to(LOBBY_ROOM(lobby.id)).emit('feed', {type: 'death', who: player.displayName, score: player.score});
            io.to(LOBBY_ROOM(lobby.id)).emit('feed', {type: 'death', who: collided.displayName, score: collided.score});
            removePlayer(lobby, player);
            removePlayer(lobby, collided);
            continue;
        }

        if (player.snake[0].x === lobby.food.x && player.snake[0].y === lobby.food.y) {
            //Player hits food
            player.eat();
            respawnFood(lobby);
            io.to(LOBBY_ROOM(lobby.id)).emit('updateFood', {x: lobby.food.x, y: lobby.food.y});
        }

        // Bonus apples from opened supply crates.
        for (let i = lobby.bonusFoods.length - 1; i >= 0; i--) {
            if (player.snake[0].x === lobby.bonusFoods[i].x && player.snake[0].y === lobby.bonusFoods[i].y) {
                lobby.bonusFoods.splice(i, 1);
                player.eat();
            }
        }

        // Golden apple: rare, timed, worth extra.
        if (lobby.golden !== null && player.snake[0].x === lobby.golden.x && player.snake[0].y === lobby.golden.y) {
            lobby.golden = null;
            player.eat(GOLDEN_POINTS);
            io.to(LOBBY_ROOM(lobby.id)).emit('feed', {type: 'golden', who: player.displayName, points: GOLDEN_POINTS});
        }

        // Supply crates.
        for (let i = lobby.drops.length - 1; i >= 0; i--) {
            if (player.snake[0].x === lobby.drops[i].x && player.snake[0].y === lobby.drops[i].y) {
                lobby.drops.splice(i, 1);
                openDrop(lobby, player);
            }
        }

        player.updatePosition();
    }

    // One broadcast of plain data objects instead of an emit per socket;
    // also avoids leaking internal player fields over the wire.
    io.to(LOBBY_ROOM(lobby.id)).emit('gameTick', {
        players: activePlayers(lobby).map((p) => ({
            id: p.id,
            displayName: p.displayName,
            color: p.color,
            snake: p.snake,
            score: p.score,
            bodyLength: p.bodyLength,
        })),
        bonus: lobby.bonusFoods,
        drops: lobby.drops.map((d) => ({id: d.id, x: d.x, y: d.y, ttl: Math.max(0, d.expiresAt - now)})),
        golden: lobby.golden === null ? null : {x: lobby.golden.x, y: lobby.golden.y, ttl: Math.max(0, lobby.golden.expiresAt - now)},
    });

    const durMs = Number(process.hrtime.bigint() - t0) / 1e6;
    lobby.stats.lastTickMs = durMs;
    lobby.stats.ticks++;
    lobby.stats.avgTickMs = lobby.stats.avgTickMs + (durMs - lobby.stats.avgTickMs) / Math.min(lobby.stats.ticks, 200);
    lobby.stats.maxTickMs = Math.max(lobby.stats.maxTickMs, durMs);
};

const tickAllLobbies = () => {
    const now = Date.now();

    // Reap players whose socket died without a disconnect event (zombies).
    for (let lobby of lobbies.values()) {
        for (const socket of [...lobby.sockets.values()]) {
            if (socket.connected === false) {
                io.to(LOBBY_ROOM(lobby.id)).emit('feed', {type: 'death', who: socket.player.displayName, score: socket.player.score});
                removePlayer(lobby, socket.player);
            }
        }
        if (lobby.players.size === 0 && lobby.id !== DEFAULT_LOBBY_ID) {
            if (lobby.lastEmptyAt === 0) lobby.lastEmptyAt = now;
        }
    }

    // Delete idle non-default lobbies.
    for (let lobby of lobbies.values()) {
        if (lobby.id !== DEFAULT_LOBBY_ID && lobby.players.size === 0 &&
            lobby.lastEmptyAt !== 0 && now - lobby.lastEmptyAt > LOBBY_IDLE_DELETE_MS) {
            lobbies.delete(lobby.id);
        }
    }

    for (let lobby of lobbies.values()) {
        if (lobby.players.size > 0) tickLobby(lobby, now);
    }
    stopGameLoopIfIdle();
};
