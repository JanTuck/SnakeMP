export default class Snake {
    constructor(ctx, data) {
        this.scale = 16;
        this.ctx = ctx;
        this.canvas = ctx.canvas;
        this.snake = [];
        this.update(data);
    }

    // Refresh the mutable state of an already existing snake.
    update(data) {
        this.color = data.color;
        this.snake = data.snake;
        this.id = data.id;
        this.displayName = data.displayName;
        this.bodyLength = data.bodyLength;
        this.score = data.score;
    }
    setDirection(direction) {
        // Direction is authoritative on the server; kept for future use.
        this.direction = direction;
    }

    //TODO finish
    draw() {
        for (let i = 0; i < this.snake.length; i++) {
            this.ctx.fillStyle = this.color;
            this.ctx.fillRect(this.snake[i].x, this.snake[i].y, this.scale, this.scale);
        }
    }
    setHeadCoordinates(x,y){
        this.snake[0].x = x;
        this.snake[0].y = y;
    }
    getOldHead() {
        return {
            x: this.snake[0].x,
            y: this.snake[0].y
        };
    }
    drawDisplayName(){
        this.ctx.fillStyle = "black";
        this.ctx.font = "15px Arial";
        this.ctx.textAlign = "center";
        const head = this.snake[0];
        // Flip the label below the head when it would clip at the top edge.
        const y = head.y < 30 ? head.y + this.scale + 18 : head.y - 10;
        this.ctx.fillText(this.displayName, head.x, y);
    }
    setDisplayName(name){
        this.displayName = name;
    }
    getLength() {
        return this.snake.length;
    }
}