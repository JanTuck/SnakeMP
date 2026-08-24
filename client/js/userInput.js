export const ARROW_RIGHT = "ArrowRight";
export const ARROW_LEFT = "ArrowLeft";
export const ARROW_UP = "ArrowUp";
export const ARROW_DOWN = "ArrowDown";

const DIRECTIONS = new Set([ARROW_RIGHT, ARROW_LEFT, ARROW_UP, ARROW_DOWN]);
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
const LEFT_OF = {
    [ARROW_RIGHT]: ARROW_UP,
    [ARROW_UP]: ARROW_LEFT,
    [ARROW_LEFT]: ARROW_DOWN,
    [ARROW_DOWN]: ARROW_RIGHT
};
const RIGHT_OF = {
    [ARROW_RIGHT]: ARROW_DOWN,
    [ARROW_DOWN]: ARROW_LEFT,
    [ARROW_LEFT]: ARROW_UP,
    [ARROW_UP]: ARROW_RIGHT
};

// The server accepts two queued turns. Mirroring that limit keeps a burst of
// local input from making the client predict turns the server will discard.
const pending = [];
let confirmedHeading = ARROW_RIGHT;
let predictedHeading = ARROW_RIGHT;

/**
 * Map a control relative to the snake's heading to the absolute direction the
 * wire protocol expects. Up/forward deliberately keeps the current heading;
 * down/backward is invalid in Snake and therefore produces no command.
 */
export function relativeDirection(heading, input) {
    const current = DIRECTIONS.has(heading) ? heading : ARROW_RIGHT;
    if (input === ARROW_LEFT) return LEFT_OF[current];
    if (input === ARROW_RIGHT) return RIGHT_OF[current];
    if (input === ARROW_UP) return current;
    return null;
}

/** Reconcile local prediction with the direction observed in a game snapshot. */
export function confirmHeading(nextHeading) {
    if (!DIRECTIONS.has(nextHeading)) return;

    if (pending.length === 0) {
        confirmedHeading = nextHeading;
        predictedHeading = nextHeading;
        return;
    }

    if (pending[0] === nextHeading) {
        confirmedHeading = nextHeading;
        pending.shift();
        predictedHeading = pending.length > 0 ? pending[pending.length - 1] : confirmedHeading;
        return;
    }

    // A snapshot may still show the heading from before the queued turn.
    if (nextHeading === confirmedHeading) return;

    // An unexpected server-authoritative direction wins over local prediction.
    confirmedHeading = nextHeading;
    predictedHeading = nextHeading;
    pending.length = 0;
}

export function resetHeading() {
    confirmedHeading = ARROW_RIGHT;
    predictedHeading = ARROW_RIGHT;
    pending.length = 0;
}

function handleDirection(event) {
    const input = INPUTS.get(event.code);
    if (input === undefined) return;

    if (event.repeat) return;
    event.preventDefault();

    // Forward is already happening; backward would reverse into the neck.
    if (input === ARROW_UP || input === ARROW_DOWN || pending.length >= 2) return;

    const next = relativeDirection(predictedHeading, input);
    if (next === null) return;
    socket.emit("keyPress", next);
    pending.push(next);
    predictedHeading = next;
}

document.addEventListener("keydown", handleDirection);
socket.on("disconnect", resetHeading);
