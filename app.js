const createError = require('http-errors');
const CONSTANTS = require("./server/constants");
const express = require('express');
const path = require('path');
const cookieParser = require('cookie-parser');
const logger = require('morgan');
const Player = require('./server/player');
const uniqueId = require('./server/generateId');
const color = require('rcolor');
const Environment = require("./server/environment");
const Food = require("./server/food");
const InputValidation = require("./server/inputvalidation");

const app = express();

const http = require('http').createServer(app);
const io = require('socket.io')(http);

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
app.use(cookieParser());
app.use(express.static(path.join(__dirname, "public")));

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'client', 'index.html'));
});
app.post('/generateid', (req, res) => {
    let gameId;
    do {
        gameId = uniqueId();
    } while (LOBBY_LIST.has(gameId));
    LOBBY_LIST.set(gameId, {createdAt: Date.now()});
    // 303 so a refresh of the landing page cannot re-submit the POST.
    res.redirect(303, `/game/${encodeURIComponent(gameId)}`);
});
app.post('/joingame', (req, res) => {
    const rawGameId = req.body && req.body.gameId;
    if (typeof rawGameId === 'string') {
        const gameId = rawGameId.trim();
        if (LOBBY_LIST.has(gameId)) {
            res.redirect(303, `/game/${encodeURIComponent(gameId)}`);
            return;
        }
    }
    // Unknown/bad id: back home with feedback instead of a silent bounce.
    res.redirect(303, '/?error=unknown-game');
});

app.get('/game/:id', (req, res) => {
    if (LOBBY_LIST.has(req.params.id))
        res.sendFile(path.join(__dirname, 'client', 'game.html'));
    else
        res.redirect('/');
});
// The lobby id gate must also apply when /game.html is requested directly,
// otherwise express.static below would serve it to anyone.
app.get('/game.html', (req, res) => {
    res.redirect('/');
});
app.use(express.static(path.join(__dirname, 'client')));

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

const SOCKET_LIST = new Map();
const LOBBY_LIST = new Map();
// Room that receives game state broadcasts; departed players are removed.
const LOBBY_ROOM = 'lobby';

// Seed one default lobby so the join form works out of the box.
LOBBY_LIST.set("12345", {createdAt: Date.now()});

// Single shared food item for the default lobby.
let food = new Food();

const activePlayers = () => [...SOCKET_LIST.values()].map((socket) => socket.player);

io.on('connection', (socket) => {
    let player = null;
    console.log("Player connected on " + socket.id);

    socket.on('clientReady', (username) => {
        if (player !== null) return; // This socket already joined.
        if (typeof username !== 'string' || !InputValidation.isValidUsername(username)) {
            socket.emit('game_error', CONSTANTS.ERRORS.INVALID_USERNAME);
            return;
        }

        const initObj = {scale: CONSTANTS.gridSize, food: {x: food.x, y: food.y}};
        socket.emit('init', initObj);

        // Spawn away from other players AND from the current food item.
        let playerPosition;
        for (let attempt = 0; attempt < 100; attempt++) {
            playerPosition = Environment.startPosition(activePlayers());
            if (playerPosition.x !== food.x || playerPosition.y !== food.y) break;
        }
        player = new Player(socket.id, username.trim(), playerPosition.x, playerPosition.y, color());
        socket.player = player;
        SOCKET_LIST.set(socket.id, socket);
        // Live players receive the periodic broadcasts; dead ones stop.
        socket.join(LOBBY_ROOM);
        ensureGameLoopRunning();
    });

    socket.on('keyPress', (data) => {
        if (player === null) return; // Cannot steer before joining.
        player.setDirection(data);
    });

    socket.on('disconnect', () => {
        console.log(socket.id + " disconnected");
        if (player !== null) removePlayer(player);
        player = null;
    });
});

const removePlayer = (player) => {
    const socket = SOCKET_LIST.get(player.id);
    if (socket) socket.leave(LOBBY_ROOM);
    return SOCKET_LIST.delete(player.id);
};

/**
 * Respawn the food somewhere no snake is currently occupying.
 */
const respawnFood = () => {
    for (let attempt = 0; attempt < 100; attempt++) {
        food.generateRandom();
        const occupied = activePlayers().some((p) =>
            p.snake.some((part) => part.x === food.x && part.y === food.y));
        if (!occupied) return;
    }
};

//Set the game tick to 15fps
const TICK_MS = 1000 / 15;
let gameLoop = null;

const ensureGameLoopRunning = () => {
    if (gameLoop === null) {
        gameLoop = setInterval(gameTick, TICK_MS);
    }
};

const stopGameLoopIfIdle = () => {
    if (gameLoop !== null && SOCKET_LIST.size === 0) {
        clearInterval(gameLoop);
        gameLoop = null;
    }
};

const gameTick = () => {
    // Snapshot: players that die mid-tick must not keep acting this tick.
    const sockets = [...SOCKET_LIST.values()];

    for (let socket of sockets) {
        // Skip players already killed earlier in this same tick.
        if (SOCKET_LIST.get(socket.id) !== socket) continue;

        let player = socket.player;

        //Player collides with himself or the wall.
        if (player.collided()) {
            socket.emit('death', player.score);
            removePlayer(player);
            continue;
        }

        //Player collides with someone else
        let collided = player.collidedOther(activePlayers());
        if (collided !== null) {
            socket.emit('death', player.score);
            const otherSocket = SOCKET_LIST.get(collided.id);
            if (otherSocket) {
                otherSocket.emit('death', collided.score);
            }
            removePlayer(player);
            removePlayer(collided);
            continue;
        }

        if (player.snake[0].x === food.x && player.snake[0].y === food.y) {
            //Player hits food
            player.eat();
            respawnFood();
            io.to(LOBBY_ROOM).emit('updateFood', {x: food.x, y: food.y});
        }

        player.updatePosition();
    }

    // One broadcast of plain data objects instead of an emit per socket;
    // also avoids leaking internal player fields over the wire.
    io.to(LOBBY_ROOM).emit('gameTick', activePlayers().map((p) => ({
        id: p.id,
        displayName: p.displayName,
        color: p.color,
        snake: p.snake,
        score: p.score,
        bodyLength: p.bodyLength,
    })));
    stopGameLoopIfIdle();
};
