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
        // Direction requested by the player, applied on the next tick.
        this.pendingDirection = null;
        // Per-player growth flag. The tail is kept exactly once after eating.
        this.growNextTick = false;
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
     * arrows and rejects 180 degree turns, which would instantly kill the snake.
     * Returns true when the direction was accepted.
     */
    setDirection(direction){
        if (!DIRECTIONS.includes(direction)) return false;
        if (this.direction !== null && direction === OPPOSITE[this.direction]) return false;
        if (direction === this.direction) return false;
        this.pendingDirection = direction;
        return true;
    }

    updatePosition(){
        // Only one queued turn is applied per tick, so two rapid key presses
        // cannot smuggle in a reversal within a single tick.
        if (this.pendingDirection !== null) {
            this.direction = this.pendingDirection;
            this.pendingDirection = null;
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
        if(this.growNextTick){
            this.growNextTick = false; // Keep the tail so the snake grows by one.
        }else{
            this.snake.pop();
        }
        this.snake.unshift(oldHead);
        this.bodyLength = this.snake.length;
    }

    eat(){
        this.growNextTick = true;
        this.score++;
        this.bodyLength = this.snake.length + 1;
    }
}
module.exports = Player;
