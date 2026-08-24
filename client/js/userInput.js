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
function handleDirection(event) {
    const input = INPUTS.get(event.code);
    if (input === undefined) return;

    const target = event.target;
    const tag = target && typeof target.tagName === "string" ? target.tagName.toUpperCase() : "";
    if ((target && target.isContentEditable) || tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;

    event.preventDefault();
    if (event.repeat) return;

    // Arrow/WASD controls are absolute. The authoritative server owns repeat,
    // reversal, and two-turn queue validation; snapshot latency must not make
    // the browser discard an otherwise legal human input.
    socket.emit("keyPress", input);
}

document.addEventListener("keydown", handleDirection);
