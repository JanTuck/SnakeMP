const HEADING_VECTOR = Object.freeze({
    ArrowRight: Object.freeze([1, 0]),
    ArrowLeft: Object.freeze([-1, 0]),
    ArrowDown: Object.freeze([0, 1]),
    ArrowUp: Object.freeze([0, -1])
});

// Keep remote presentation time independent from packet-arrival jitter. The
// server still advances at 15 Hz; this clock merely lets requestAnimationFrame
// distribute each authoritative cell step evenly across the display refreshes.
export class RemoteInterpolationClock {
    constructor(tickMs, maxExtrapolation = 0.35) {
        this.tickMs = tickMs;
        this.maxExtrapolation = maxExtrapolation;
        this.reset();
    }

    reset() {
        this.sequence = null;
        this.baseAt = 0;
        this.baseProgress = 1;
        this.running = false;
    }

    progress(now) {
        if (!this.running) return 1;
        const elapsed = Math.max(0, now - this.baseAt);
        return Math.max(-1, Math.min(1 + this.maxExtrapolation,
            this.baseProgress + elapsed / this.tickMs));
    }

    snapshot(now, sequence) {
        const adjacent = this.sequence !== null &&
            sequence === ((this.sequence + 1) & 0xffff);
        if (!adjacent) {
            // First and recovery keyframes are already complete states. Show
            // them immediately and wait for one adjacent update before moving.
            this.baseProgress = 1;
            this.running = false;
        } else {
            // Advancing the authoritative endpoints changes the interpolation
            // basis by exactly one tick. Subtracting one preserves the current
            // straight-line screen position instead of resetting to zero at a
            // jittery packet-arrival boundary.
            this.baseProgress = this.progress(now) - 1;
            this.running = true;
        }
        this.baseAt = now;
        this.sequence = sequence;
    }
}

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
        const motionDx = previousHead === undefined || head === undefined ? 0 : head.x - previousHead.x;
        const motionDy = previousHead === undefined || head === undefined ? 0 : head.y - previousHead.y;
        this.id = meta[0];
        this.displayName = meta[1];
        this.color = meta[2];
        this.score = player.score;
        this.bodyLength = player.cells;
        // A recovery keyframe may jump several cells after dropped deltas;
        // interpolate only an adjacent (or unchanged) authoritative update.
        this.interpolate = Math.abs(motionDx) + Math.abs(motionDy) <= this.scale;
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
            const steps = player.steps === 2 ? 2 : 1;
            if (steps === 2 && player.cells > 1) {
                let middle = this.snake[1];
                if (middle === undefined) middle = this.snake[1] = { x: 0, y: 0 };
                middle.x = (old[0].x + head.x) / 2;
                middle.y = (old[0].y + head.y) / 2;
            }
            for (let index = steps; index < player.cells; index++) {
                let cell = this.snake[index];
                if (cell === undefined) cell = this.snake[index] = { x: 0, y: 0 };
                cell.x = old[index - steps].x;
                cell.y = old[index - steps].y;
            }
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
    draw(t, isLocal = false, localDirection = null) {
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
                // The arena scales as a single 128 x 72 world at every
                // resolution. A quiet, world-space locator keeps the local
                // head findable without changing its hitbox or game geometry.
                if (isLocal) {
                    ctx.save();
                    ctx.globalAlpha = 0.96;
                    ctx.strokeStyle = '#fffaf1';
                    ctx.lineWidth = 2.4;
                    ctx.shadowColor = 'rgba(10, 12, 17, 0.48)';
                    ctx.shadowBlur = 5;
                    ctx.beginPath();
                    ctx.arc(x + s / 2, y + s / 2, s / 2 + 5, 0, Math.PI * 2);
                    ctx.stroke();
                    ctx.restore();
                }
                // Head: slightly larger, full colour, with eyes.
                ctx.fillStyle = this.color;
                ctx.save();
                ctx.shadowColor = "rgba(10, 12, 17, 0.34)";
                ctx.shadowBlur = 3;
                this.roundRect(x - 1, y - 1, s + 2, s + 2, 5);
                ctx.shadowBlur = 0;
                ctx.strokeStyle = "rgba(10, 12, 17, 0.7)";
                ctx.lineWidth = 1.25;
                ctx.stroke();
                ctx.restore();
                const predicted = isLocal && localDirection !== null ? HEADING_VECTOR[localDirection] : undefined;
                const dx = c.x - (prev[0] ? prev[0].x : c.x);
                const dy = c.y - (prev[0] ? prev[0].y : c.y);
                const len = Math.abs(dx) + Math.abs(dy);
                const fx = predicted !== undefined ? predicted[0] : len > 0 ? dx / len : 1;
                const fy = predicted !== undefined ? predicted[1] : len > 0 ? dy / len : 0;
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

}
