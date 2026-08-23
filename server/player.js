const CONSTANTS = require("./constants");
const ARROW_DOWN = CONSTANTS.ARROW_DOWN;
const ARROW_UP = CONSTANTS.ARROW_UP;
const ARROW_LEFT = CONSTANTS.ARROW_LEFT;
const ARROW_RIGHT = CONSTANTS.ARROW_RIGHT;
const DIRECTIONS = [ARROW_UP, ARROW_DOWN, ARROW_LEFT, ARROW_RIGHT];
// A snake may never reverse into its own neck, so map every direction to its opposite.
const OPPOSITE = {
    [ARROW_UP]: ARROW_DOWN,
    [ARROW_DOWN]: ARROW_UP,
    [ARROW_LEFT]: ARROW_RIGHT,
    [ARROW_RIGHT]: ARROW_LEFT
};
const gridSize = CONSTANTS.gridSize;

class Player{
    constructor(id, displayName, x, y, color) {
        this.id = id;
        this.displayName = displayName;
        this.snake = [{
            x: x,
            y: y
        }];
        this.bodyLength = this.snake.length;
        this.score = 0;
        // Direction currently applied on the last game tick (null while stationary).
        this.direction = null;
        // Directions requested by the player. Up to two turns may be queued;
        // each is validated against the previous one, so fast L-shaped input
        // chains register instantly without ever allowing a reversal.
        this.directionQueue = [];
        // Pending growth in segments; consumed one per tick after eating.
        this.pendingGrowth = 0;
        this.color = color;
    }

    collided(){
        return this.collidedSelf() || this.collidedWall();
    }

    collidedWall(){
        const head = this.snake[0];
        if (head.x > CONSTANTS.gridWidth - gridSize || head.x < 0) return true;
        return head.y > CONSTANTS.gridHeight - gridSize || head.y < 0;
    }

    collidedSelf(){
        const head = this.snake[0];
        for (let i = 1; i < this.snake.length; i++) {
            if (head.x === this.snake[i].x && head.y === this.snake[i].y) {
                return true;
            }
        }
        return false;
    }

    /*check collisions with other players*/
    collidedOther(players){
        const head = this.snake[0];
        for (let player of players){
            if(player.id === this.id){
                continue;
            }
            for (let otherSnakeBodyPart of player.snake){
                if(head.x === otherSnakeBodyPart.x && head.y === otherSnakeBodyPart.y){
                    return player;
                }
            }
        }
        return null;
    }

    /**
     * Queue a direction change. Ignores values that are not one of the four
     * arrows and rejects 180 degree turns relative to the last queued
     * direction, which would instantly kill the snake. Returns true when the
     * direction was accepted.
     */
    setDirection(direction){
        if (!DIRECTIONS.includes(direction)) return false;
        const last = this.directionQueue.length > 0
            ? this.directionQueue[this.directionQueue.length - 1]
            : this.direction;
        if (last !== null && direction === OPPOSITE[last]) return false;
        if (direction === last) return false;
        if (this.directionQueue.length >= 2) return false; // bounded buffer
        this.directionQueue.push(direction);
        return true;
    }

    updatePosition(){
        // One queued turn is applied per tick; chained turns carry over to
        // following ticks so rapid key presses feel immediate.
        if (this.directionQueue.length > 0) {
            this.direction = this.directionQueue.shift();
        }
        if (this.direction === null) return; // Stationary until the first input.

        const oldHead = {
            x: this.snake[0].x,
            y: this.snake[0].y
        };
        switch (this.direction){
            case ARROW_RIGHT: oldHead.x += gridSize; break;
            case ARROW_LEFT:  oldHead.x -= gridSize; break;
            case ARROW_UP:    oldHead.y -= gridSize; break;
            case ARROW_DOWN:  oldHead.y += gridSize; break;
        }
        if(this.pendingGrowth > 0){
            this.pendingGrowth--; // Keep the tail so the snake grows by one.
        }else{
            this.snake.pop();
        }
        this.snake.unshift(oldHead);
        this.bodyLength = this.snake.length;
    }

    /**
     * Award points and queue growth. Supply crates can grant more of both.
     */
    eat(points = 1, growth = 1){
        this.score += points;
        this.pendingGrowth += growth;
        this.bodyLength = this.snake.length + this.pendingGrowth;
    }
}
module.exports = Player;
