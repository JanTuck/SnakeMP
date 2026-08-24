export const ARROW_RIGHT = "ArrowRight";
export const ARROW_LEFT = "ArrowLeft";
export const ARROW_UP = "ArrowUp";
export const ARROW_DOWN = "ArrowDown";

const INPUTS = new Map([
    [ARROW_RIGHT, ARROW_RIGHT],
    [ARROW_LEFT, ARROW_LEFT],
    [ARROW_UP, ARROW_UP],
    [ARROW_DOWN, ARROW_DOWN],
    ["KeyD", ARROW_RIGHT],
    ["KeyA", ARROW_LEFT],
    ["KeyW", ARROW_UP],
    ["KeyS", ARROW_DOWN]
]);

const OPPOSITE = new Map([
    [ARROW_UP, ARROW_DOWN],
    [ARROW_DOWN, ARROW_UP],
    [ARROW_LEFT, ARROW_RIGHT],
    [ARROW_RIGHT, ARROW_LEFT]
]);

let observedDirection = null;
const queuedDirections = [];
let gameMode = "arcade_v1";
let boostHeld = false;
let gameplayEnabled = false;

function isEditingTarget(target) {
    const tag = target && typeof target.tagName === "string" ? target.tagName.toUpperCase() : "";
    return Boolean((target && target.isContentEditable) || tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT");
}

function emitBoost(active) {
    if (boostHeld === active) return;
    boostHeld = active;
    socket.emit("boost", active);
}

export function releaseBoost() {
    if (boostHeld) emitBoost(false);
}

export function setGameMode(mode) {
    gameMode = mode === "arcade_v2" ? "arcade_v2" : mode === "classical" ? "classical" : "arcade_v1";
    if (gameMode !== "arcade_v2") releaseBoost();
}

export function setGameplayEnabled(enabled) {
    gameplayEnabled = enabled === true;
    if (!gameplayEnabled) releaseBoost();
}

// Reconcile the local turn predictor with authoritative movement. Keeping
// unobserved turns queued is important: a snapshot for the old heading can
// arrive between two rapid key presses without changing what the second turn
// is relative to.
export function syncDirection(direction) {
    if (!OPPOSITE.has(direction)) return;

    if (queuedDirections.length !== 0 && queuedDirections[0] === direction) {
        queuedDirections.shift();
    } else if (observedDirection !== null && observedDirection !== direction) {
        // A discontinuity not produced by our predictor means the server has
        // moved on (for example after a reconnect). Drop stale local intent.
        queuedDirections.length = 0;
    }
    observedDirection = direction;
}

export function resetDirection() {
    observedDirection = null;
    queuedDirections.length = 0;
}

function predictedDirection() {
    return queuedDirections.length === 0
        ? observedDirection
        : queuedDirections[queuedDirections.length - 1];
}

function emitDirection(direction) {
    const previous = predictedDirection();
    if (previous !== null && (direction === previous || direction === OPPOSITE.get(previous))) return;
    // Mirror the server's two-turn queue. More intent than this cannot be
    // represented authoritatively and would make local prediction drift.
    if (queuedDirections.length >= 2) return;
    socket.emit("keyPress", direction);
    queuedDirections.push(direction);
}

function handleDirection(event) {
    const input = INPUTS.get(event.code);
    if (input === undefined || !gameplayEnabled) return;

    if (isEditingTarget(event.target)) return;

    event.preventDefault();
    if (event.repeat) return;

    emitDirection(input);
}

function handleBoostDown(event) {
    if (event.code !== "Space" || !gameplayEnabled || gameMode !== "arcade_v2" || isEditingTarget(event.target)) return;
    event.preventDefault();
    if (event.repeat || boostHeld) return;
    emitBoost(true);
}

function handleBoostUp(event) {
    if (event.code !== "Space" || !boostHeld) return;
    event.preventDefault();
    emitBoost(false);
}

document.addEventListener("keydown", handleDirection);
document.addEventListener("keydown", handleBoostDown);
document.addEventListener("keyup", handleBoostUp);
document.addEventListener("visibilitychange", () => {
    if (document.hidden) releaseBoost();
});
if (typeof window !== "undefined") window.addEventListener("blur", releaseBoost);
