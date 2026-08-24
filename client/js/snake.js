export default class Snake {
    constructor(ctx, meta) {
        this.scale = 16;
        this.ctx = ctx;
        this.canvas = ctx.canvas;
        this.snake = [];
        this.prevSnake = [];
        this.id = meta[0];
        this.displayName = meta[1];
        this.color = meta[2];
        this.score = 0;
        this.bodyLength = 0;
        this.interpolate = false;
        // New snakes are visually oriented right before their first move.
        this.heading = "ArrowRight";
    }

    // Commit a fully validated v3 absolute keyframe. Packed paths store the
    // head followed by 2-bit directions toward the tail.
    updateKeyframe(meta, view, player) {
        const next = this.prevSnake;
        this.prevSnake = this.snake;
        this.snake = next;
        this.snake.length = player.cells;
        let offset = player.bodyOffset;
        let x = 0, y = 0;
        if (player.packed) {
            x = view.getUint8(offset++);
            y = view.getUint8(offset++);
        }
        for (let index = 0; index < player.cells; index++) {
            let cell = this.snake[index];
            if (cell === undefined) cell = this.snake[index] = { x: 0, y: 0 };
            if (player.packed) {
                if (index !== 0) {
                    const direction = (view.getUint8(offset + ((index - 1) >> 2)) >> (((index - 1) & 3) * 2)) & 3;
                    if (direction === 0) y--; else if (direction === 1) y++;
                    else if (direction === 2) x--; else x++;
                }
                cell.x = x * this.scale;
                cell.y = y * this.scale;
            } else {
                cell.x = view.getUint8(offset++) * this.scale;
                cell.y = view.getUint8(offset++) * this.scale;
            }
        }
        const head = this.snake[0];
        const previousHead = this.prevSnake[0];
        let dx = previousHead === undefined || head === undefined ? 0 : head.x - previousHead.x;
        let dy = previousHead === undefined || head === undefined ? 0 : head.y - previousHead.y;
        // The neck also reveals heading when there is no previous moving frame.
        if (dx === 0 && dy === 0 && player.cells > 1) {
            dx = head.x - this.snake[1].x;
            dy = head.y - this.snake[1].y;
        }
        if (Math.abs(dx) > Math.abs(dy)) this.heading = dx < 0 ? "ArrowLeft" : "ArrowRight";
        else if (dy !== 0) this.heading = dy < 0 ? "ArrowUp" : "ArrowDown";
        this.id = meta[0];
        this.displayName = meta[1];
        this.color = meta[2];
        this.score = player.score;
        this.bodyLength = player.cells;
        // A recovery keyframe may jump several cells after dropped deltas;
        // interpolate only an adjacent (or unchanged) authoritative update.
        this.interpolate = Math.abs(dx) + Math.abs(dy) <= this.scale;
    }

    // Commit one validated delta. Body transitions are deterministic shifts,
    // so only the new head crosses the wire even for very long snakes.
    updateDelta(meta, player) {
        if (player.mode !== 0) {
            const old = this.snake;
            const next = this.prevSnake;
            this.prevSnake = old;
            this.snake = next;
            this.snake.length = player.cells;
            let head = this.snake[0];
            if (head === undefined) head = this.snake[0] = { x: 0, y: 0 };
            head.x = player.headX * this.scale;
            head.y = player.headY * this.scale;
            for (let index = 1; index < player.cells; index++) {
                let cell = this.snake[index];
                if (cell === undefined) cell = this.snake[index] = { x: 0, y: 0 };
                cell.x = old[index - 1].x;
                cell.y = old[index - 1].y;
            }
            const dx = this.snake[0].x - old[0].x;
            const dy = this.snake[0].y - old[0].y;
            if (Math.abs(dx) > Math.abs(dy)) this.heading = dx < 0 ? "ArrowLeft" : "ArrowRight";
            else if (dy !== 0) this.heading = dy < 0 ? "ArrowUp" : "ArrowDown";
            this.interpolate = true;
        } else {
            this.interpolate = false;
        }
        this.id = meta[0];
        this.displayName = meta[1];
        this.color = meta[2];
        this.score = player.score;
        this.bodyLength = player.cells;
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
        const prev = this.interpolate && this.prevSnake !== undefined && this.prevSnake.length > 0 ? this.prevSnake : cur;
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
