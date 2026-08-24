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
    if (input === undefined) return;

    const target = event.target;
    const tag = target && typeof target.tagName === "string" ? target.tagName.toUpperCase() : "";
    if ((target && target.isContentEditable) || tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;

    event.preventDefault();
    if (event.repeat) return;

    emitDirection(input);
}

document.addEventListener("keydown", handleDirection);
