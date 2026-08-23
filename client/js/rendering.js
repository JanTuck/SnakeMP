import Snake from "./snake.js";
import GameOverMenu from "./menu/gameOverMenu.js";
import Food from "./food.js";
import ResourceHandler from "./resourceHandler.js";

// Module scripts run after the DOM is parsed, so the canvas/socket exist
// already. Wiring handlers here instead of inside window.onload avoids a
// soft-lock when slow render-blocking resources delay onload past the point
// where the player joins.
const canvas = document.getElementById("canvas");
const ctx = canvas.getContext('2d');

const snakeList = new Map();
let food = null;
let isSetup = false;
let gameOver = false;
let errorTimeout = null;
let gameOverMenu = null;

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

socket.on("gameTick", (data) => {
    if (!isSetup || gameOver) return;
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    // Reuse existing Snake objects instead of rebuilding everything,
    // and drop snakes for players that are gone.
    const seenIds = new Set();
    for (let i = 0; i < data.length; i++) {
        seenIds.add(data[i].id);
        let snake = snakeList.get(data[i].id);
        if (snake === undefined) {
            snakeList.set(data[i].id, new Snake(ctx, data[i]));
        } else {
            snake.update(data[i]);
        }
    }
    for (let id of [...snakeList.keys()]) {
        if (!seenIds.has(id)) snakeList.delete(id);
    }

    for (let snake of snakeList.values()) {
        snake.draw();
        snake.drawDisplayName();
    }
    if (food !== null) food.draw();
});

socket.on('init', (initData) => {
    document.getElementById('game_popup').style.display = 'none';

    // Grid size comes from the server payload; the drawing helpers keep their
    // own matching default so there is no circular module binding anymore.
    food = new Food(ctx, initData.food.x, initData.food.y);
    gameOver = false;
    gameOverMenu = null;
    isSetup = true;
});

socket.on('game_error', (errorMessage) => {
    showError(errorMessage);
});

socket.on('updateFood', (data) => {
    if (!isSetup || gameOver) return;
    food = new Food(ctx, data.x, data.y);
});

socket.on('death', (score) => {
    gameOver = true; // Stop drawing ticks over the game over screen.
    gameOverMenu = new GameOverMenu(ctx);
    gameOverMenu.setScore(score);
    gameOverMenu.draw();
});

socket.on('disconnect', () => {
    if (!gameOver) showError('Disconnected from server');
});
