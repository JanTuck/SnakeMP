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
let gameMode = "arcade";
let boostHeld = false;
let gameplayEnabled = false;
let steerFrame = 0;
let pendingSteer = null;
let predictedSteer = null;
const ioBoostButton = document.getElementById?.("io_boost") ?? null;
const ioCanvas = document.getElementById?.("canvas") ?? null;
let steeringCenterX = null;
let steeringCenterY = null;

function invalidateSteeringCenter() {
    steeringCenterX = null;
    steeringCenterY = null;
}

function refreshSteeringCenter() {
    if (steeringCenterX !== null && steeringCenterY !== null) return;
    const rect = ioCanvas?.getBoundingClientRect?.();
    if (rect !== undefined && rect.width > 0 && rect.height > 0) {
        steeringCenterX = rect.left + rect.width / 2;
        steeringCenterY = rect.top + rect.height / 2;
        return;
    }
    steeringCenterX = globalThis.innerWidth / 2;
    steeringCenterY = globalThis.innerHeight / 2;
}

function cancelPendingSteer() {
    pendingSteer = null;
    predictedSteer = null;
}

function isEditingTarget(target) {
    const tag = target && typeof target.tagName === "string" ? target.tagName.toUpperCase() : "";
    return Boolean((target && target.isContentEditable) || tag === "INPUT" || tag === "TEXTAREA" ||
        tag === "SELECT" || tag === "BUTTON" || tag === "A");
}

function emitBoost(active) {
    if (boostHeld === active) return;
    boostHeld = active;
    ioBoostButton?.setAttribute("aria-pressed", active ? "true" : "false");
    socket.emit("boost", active);
}

function syncIoBoostButton() {
    if (ioBoostButton === null) return;
    const available = gameplayEnabled && gameMode === "snek_io";
    ioBoostButton.hidden = !available;
    ioBoostButton.disabled = !available;
}

export function releaseBoost() {
    if (boostHeld) emitBoost(false);
}

export function setGameMode(mode) {
    // An init/rejoin starts a fresh input session. Clear any held state before
    // switching modes so a lost key/pointer-up cannot poison the next round.
    releaseBoost();
    cancelPendingSteer();
    invalidateSteeringCenter();
    gameMode = mode === "arcade" || mode === "snek_io" ? mode : "classical";
    syncIoBoostButton();
}

export function setGameplayEnabled(enabled) {
    gameplayEnabled = enabled === true;
    if (!gameplayEnabled) {
        releaseBoost();
        // A queued requestAnimationFrame may run after a very fast reconnect
        // and re-init. Drop its old-life steering intent now so that callback
        // cannot turn the newly spawned snake before the player moves again.
        cancelPendingSteer();
    }
    syncIoBoostButton();
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
    cancelPendingSteer();
}

export function getPredictedSteerAngle() {
    return predictedSteer === null ? null : predictedSteer / 65535 * Math.PI * 2;
}

function predictedDirection() {
    return queuedDirections.length === 0
        ? observedDirection
        : queuedDirections[queuedDirections.length - 1];
}

// Rendering reads the accepted local intent on the next animation frame. This
// gives the head immediate directional feedback without moving it ahead of the
// authoritative server position or changing collision geometry.
export function getPredictedDirection() {
    return queuedDirections.length === 0 ? observedDirection : queuedDirections[0];
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

    if (isEditingTarget(event.target) || gameMode === "snek_io") return;

    event.preventDefault();
    if (event.repeat) return;

    emitDirection(input);
}

function handleBoostDown(event) {
    if (event.code !== "Space" || !gameplayEnabled || gameMode === "classical" || isEditingTarget(event.target)) return;
    event.preventDefault();
    if (event.repeat || boostHeld) return;
    emitBoost(true);
}

function flushSteer() {
    steerFrame = 0;
    const angle = pendingSteer;
    pendingSteer = null;
    if (angle === null || !gameplayEnabled || gameMode !== "snek_io") return;
    socket.emit("steer", angle);
}

function handlePointer(event) {
    if (!gameplayEnabled || gameMode !== "snek_io" || isEditingTarget(event.target)) return;
    refreshSteeringCenter();
    const angle = Math.atan2(event.clientY - steeringCenterY, event.clientX - steeringCenterX);
    pendingSteer = Math.round(((angle + Math.PI * 2) % (Math.PI * 2)) / (Math.PI * 2) * 65535);
    predictedSteer = pendingSteer;
    if (!steerFrame) steerFrame = requestAnimationFrame(flushSteer);
}

function handleBoostUp(event) {
    if (event.code !== "Space" || !boostHeld) return;
    event.preventDefault();
    emitBoost(false);
}

function handleTouchBoostDown(event) {
    if (!gameplayEnabled || gameMode !== "snek_io") return;
    event.preventDefault();
    ioBoostButton?.setPointerCapture?.(event.pointerId);
    emitBoost(true);
}

function handleTouchBoostEnd(event) {
    if (!boostHeld) return;
    event.preventDefault?.();
    emitBoost(false);
}

document.addEventListener("keydown", handleDirection);
document.addEventListener("keydown", handleBoostDown);
document.addEventListener("keyup", handleBoostUp);
document.addEventListener("pointermove", handlePointer, { passive: true });
document.addEventListener("pointerdown", handlePointer, { passive: true });
ioBoostButton?.addEventListener("pointerdown", handleTouchBoostDown);
ioBoostButton?.addEventListener("pointerup", handleTouchBoostEnd);
ioBoostButton?.addEventListener("pointercancel", handleTouchBoostEnd);
ioBoostButton?.addEventListener("lostpointercapture", handleTouchBoostEnd);
ioBoostButton?.addEventListener("contextmenu", (event) => event.preventDefault());
document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
        releaseBoost();
        cancelPendingSteer();
    }
});
if (typeof window !== "undefined") window.addEventListener("blur", () => {
    releaseBoost();
    cancelPendingSteer();
});
if (typeof window !== "undefined") window.addEventListener("resize", invalidateSteeringCenter, { passive: true });
window.visualViewport?.addEventListener?.("resize", invalidateSteeringCenter, { passive: true });
