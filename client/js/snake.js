export default class Snake {
    constructor(ctx, data) {
        this.scale = 16;
        this.ctx = ctx;
        this.canvas = ctx.canvas;
        this.snake = [];
        this.prevSnake = [];
        this.update(data);
    }

    // Refresh the mutable state of an already existing snake. The previous
    // cell array is kept so the renderer can interpolate between ticks.
    update(data) {
        this.prevSnake = this.snake;
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

    roundRect(x, y, w, h, r) {
        const ctx = this.ctx;
        ctx.beginPath();
        ctx.moveTo(x + r, y);
        ctx.arcTo(x + w, y, x + w, y + h, r);
        ctx.arcTo(x + w, y + h, x, y + h, r);
        ctx.arcTo(x, y + h, x, y, r);
        ctx.arcTo(x, y, x + w, y, r);
        ctx.closePath();
        ctx.fill();
    }

    // t in [0, 1]: interpolation between the previous and current tick.
    draw(t) {
        const cur = this.snake;
        const prev = this.prevSnake !== undefined && this.prevSnake.length > 0 ? this.prevSnake : cur;
        const ctx = this.ctx;
        const s = this.scale;

        for (let i = cur.length - 1; i >= 0; i--) {
            const c = cur[i];
            const p = prev[Math.min(i, prev.length - 1)] || c;
            const x = p.x + (c.x - p.x) * t;
            const y = p.y + (c.y - p.y) * t;

            if (i === 0) {
                // Head: slightly larger, full colour, with eyes.
                ctx.fillStyle = this.color;
                this.roundRect(x + 0.5, y + 0.5, s - 1, s - 1, 4);
                const dx = c.x - (prev[0] ? prev[0].x : c.x);
                const dy = c.y - (prev[0] ? prev[0].y : c.y);
                const len = Math.abs(dx) + Math.abs(dy);
                const fx = len > 0 ? dx / len : 1;
                const fy = len > 0 ? dy / len : 0;
                // Eyes: offset forward and to both sides of the heading.
                const ex = x + s / 2 + fx * 3;
                const ey = y + s / 2 + fy * 3;
                const px = -fy * 3.2;
                const py = fx * 3.2;
                ctx.fillStyle = '#ffffff';
                ctx.beginPath();
                ctx.arc(ex + px, ey + py, 2.6, 0, Math.PI * 2);
                ctx.arc(ex - px, ey - py, 2.6, 0, Math.PI * 2);
                ctx.fill();
                ctx.fillStyle = '#111111';
                ctx.beginPath();
                ctx.arc(ex + px + fx * 1.1, ey + py + fy * 1.1, 1.3, 0, Math.PI * 2);
                ctx.arc(ex - px + fx * 1.1, ey - py + fy * 1.1, 1.3, 0, Math.PI * 2);
                ctx.fill();
            } else {
                // Body: alternating shade gives the segments definition.
                ctx.globalAlpha = i % 2 === 0 ? 1 : 0.78;
                ctx.fillStyle = this.color;
                this.roundRect(x + 1, y + 1, s - 2, s - 2, 3);
                ctx.globalAlpha = 1;
            }
        }
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
}
