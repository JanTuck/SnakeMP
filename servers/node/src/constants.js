const CONSTANTS = {
    ARROW_RIGHT: "ArrowRight",
    ARROW_LEFT: "ArrowLeft",
    ARROW_UP: "ArrowUp",
    ARROW_DOWN: "ArrowDown",
    gridSize: 16,
    gridHeight: 960,
    gridWidth: 1920,
    collision: {HEAD_TO_HEAD: 0, HEAD_TO_BODY: 1, HEAD_TO_WALL: 2 },
    ERRORS: {
        INVALID_USERNAME: "Invalid username",
        UNKNOWN_GAME: "That game does not exist any more",
        SERVER_FULL: "Server is full, try again later",
        LOBBY_FULL: "This game is full"
    }
};

module.exports = CONSTANTS;