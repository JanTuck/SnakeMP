export const ARROW_RIGHT = "ArrowRight";
export const ARROW_LEFT = "ArrowLeft";
export const ARROW_UP = "ArrowUp";
export const ARROW_DOWN = "ArrowDown";

const ARROWS = new Set([ARROW_RIGHT, ARROW_LEFT, ARROW_UP, ARROW_DOWN]);
const OPPOSITE = {
    [ARROW_RIGHT]: ARROW_LEFT,
    [ARROW_LEFT]: ARROW_RIGHT,
    [ARROW_UP]: ARROW_DOWN,
    [ARROW_DOWN]: ARROW_UP
};
let dir;

const direction = (event) => {
    //Only track certain keys, as we dont need anything else from you. Yet.
    if (!ARROWS.has(event.code)) return;

    //Ignore key auto-repeat; one press is enough.
    if (event.repeat) return;

    //Keep the arrows from scrolling the page.
    event.preventDefault();

    //Only send the key if its not the same.
    if (event.code === dir) return;

    //Dont allow the snake to backtrack. As it would literally kill itself.
    //The server enforces this too, this is only a nicety.
    if (dir !== undefined && event.code === OPPOSITE[dir]) return;

    socket.emit("keyPress", event.code);
    dir = event.code;
};
document.addEventListener("keydown", direction);
