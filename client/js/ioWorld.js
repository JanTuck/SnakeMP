// Immutable IO party-world landmarks. Keep coordinates in sync with
// servers/zig/src/snek.zig; io-snapshot-test.js enforces exact parity.
export const IO_OBSTACLE_HITBOX_SCALE = 0.70;

export const IO_OBSTACLES = Object.freeze([
    [620, 760, 64, 0], [1420, 1180, 52, 2], [2380, 620, 64, 0],
    [3440, 1320, 52, 2], [4680, 690, 64, 0], [5860, 1460, 64, 0],
    [7140, 840, 52, 2], [7860, 1810, 52, 2], [1040, 2720, 64, 0],
    [2180, 3280, 64, 0], [3180, 2460, 52, 2], [4240, 3380, 52, 2],
    [5480, 2640, 64, 0], [6660, 3480, 64, 0], [7600, 2860, 52, 2],
    [540, 4560, 52, 2], [1640, 5220, 64, 0], [2840, 4380, 64, 0],
    [3920, 5460, 52, 2], [5120, 4520, 52, 2], [6240, 5320, 64, 0],
    [7420, 4460, 64, 0], [1120, 6720, 52, 2], [2520, 7340, 52, 2],
    [4080, 6500, 64, 0], [5580, 7480, 64, 0], [7040, 6680, 52, 2],
]);

// Generated obstacle art has transparent padding and non-square visible bounds.
// Cropping to these measured alpha bounds lets the renderer center and contain
// the visible pixels inside the authoritative circular collision footprint.
// Kinds 1 and 3 are intentionally absent: IO uses only piñata crates and spike bombs.
export const IO_OBSTACLE_ART = Object.freeze([
    Object.freeze({ sprite: 'ioCrate', crop: Object.freeze([22, 19, 84, 89]) }),
    null,
    Object.freeze({ sprite: 'ioMine', crop: Object.freeze([8, 10, 112, 108]) }),
]);
export const IO_PICKUP_SPRITES = Object.freeze([
    null, null, null, 'ioStrawberry', 'ioApple', 'ioCheese', 'ioDonut',
    'ioGoldenApple', 'ioLightning', 'ioRainbow', 'ioFeast',
]);

export function ioSnakeRadius(mass) {
    return Math.max(10, Math.min(72, 10 + Math.sqrt(Math.max(0, mass - 30)) * 2.2));
}

export function ioFoodGrowth(kind) {
    return [0, 2, 2, 3, 5, 7, 10, 12, 6, 9, 14][kind] || 0;
}

export function ioInterpolateAngle(previous, current, t) {
    const turn = Math.PI * 2;
    const delta = ((current - previous + Math.PI) % turn + turn) % turn - Math.PI;
    return previous + delta * t;
}
