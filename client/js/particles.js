// Lightweight particle bursts for eats, crates and deaths.
const parts = [];

export const Particles = {
    hasActive() {
        return parts.length !== 0;
    },

    burst(x, y, color, n = 12, speed = 2.6) {
        for (let i = 0; i < n; i++) {
            const angle = Math.random() * Math.PI * 2;
            const v = speed * (0.4 + Math.random() * 0.8);
            parts.push({
                x, y,
                vx: Math.cos(angle) * v,
                vy: Math.sin(angle) * v,
                life: 1,
                decay: 0.03 + Math.random() * 0.03,
                size: 2 + Math.random() * 3,
                color,
            });
        }
        if (parts.length > 400) parts.splice(0, parts.length - 400);
    },

    update(dtMs) {
        const dt = Math.min(50, dtMs) / 16.7;
        for (let i = parts.length - 1; i >= 0; i--) {
            const p = parts[i];
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            p.vx *= 0.96;
            p.vy *= 0.96;
            p.life -= p.decay * dt;
            if (p.life <= 0) parts.splice(i, 1);
        }
    },

    draw(ctx) {
        for (const p of parts) {
            ctx.globalAlpha = Math.max(0, p.life);
            ctx.fillStyle = p.color;
            ctx.fillRect(p.x - p.size / 2, p.y - p.size / 2, p.size, p.size);
        }
        ctx.globalAlpha = 1;
    },
};
