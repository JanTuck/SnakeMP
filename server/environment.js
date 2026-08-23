const CONSTANTS = require('./constants');

class Environment {

    static getRanLocation() {
        return {
            x: Math.floor((Math.random() * CONSTANTS.gridWidth / CONSTANTS.gridSize)) * CONSTANTS.gridSize,
            y: Math.floor((Math.random() * CONSTANTS.gridHeight / CONSTANTS.gridSize)) * CONSTANTS.gridSize
        }
    };

    /**
     * Pick a random location that no player currently occupies.
     * The old recursive version discarded its own result, so overlaps were
     * still possible; this retries iteratively instead.
     */
    static startPosition(players) {
        const MAX_ATTEMPTS = 1000;
        let location = this.getRanLocation();
        for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
            let overlaps = false;
            for (let player of players) {
                for (let part of player.snake) {
                    if (location.x === part.x && location.y === part.y) {
                        overlaps = true;
                        break;
                    }
                }
                if (overlaps) break;
            }
            if (!overlaps) return {x: location.x, y: location.y};
            location = this.getRanLocation();
        }
        // Board is effectively saturated; any free-looking spot will do.
        return {x: location.x, y: location.y};
    }
}

module.exports = Environment;
