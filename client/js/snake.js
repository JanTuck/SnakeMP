export default class Snake {
    constructor(ctx, data, compact = false) {
        this.scale = 16;
        this.ctx = ctx;
        this.canvas = ctx.canvas;
        this.snake = [];
        this.prevSnake = [];
        if (compact) this.updateCompact(data[0], data[1]);
        else this.update(data);
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

    // Compact wire update. Reuse two cell-object buffers so a tick allocates
    // only the arrays produced by JSON.parse; interpolation still has both
    // the previous and current coordinates.
    updateCompact(meta, row) {
        const next = this.prevSnake;
        this.prevSnake = this.snake;
        this.snake = next;
        const coords = row[2];
        const cells = coords.length >> 1;
        this.snake.length = cells;
        for (let i = 0, c = 0; c < cells; c++, i += 2) {
            let cell = this.snake[c];
            if (cell === undefined) cell = this.snake[c] = { x: 0, y: 0 };
            cell.x = coords[i] * this.scale;
            cell.y = coords[i + 1] * this.scale;
        }
        this.id = meta[0];
        this.displayName = meta[1];
        this.color = meta[2];
        this.score = row[0];
        this.bodyLength = row[1];
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
