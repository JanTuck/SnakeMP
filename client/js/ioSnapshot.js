const MAX_PLAYERS = 100;
const MAX_BODY = 1000;
const MAX_FOOD = 8192;
const ARENA = 8192;

const players = Array.from({ length: MAX_PLAYERS }, () => ({
    score: 0, mass: 0, angle: 0, previousAngle: 0,
    boosting: false, shielded: false, body: [], previous: []
}));
const foodX = new Uint16Array(MAX_FOOD);
const foodY = new Uint16Array(MAX_FOOD);
const foodMass = new Uint8Array(MAX_FOOD);
const foodSlots = new Uint16Array(MAX_FOOD);
const decoded = { sequence: 0, playerCount: 0, players, foodCount: 0, obstacleMask: 0, foodX, foodY, foodMass, foodSlots };

function viewFor(payload) {
    if (payload instanceof ArrayBuffer) return new DataView(payload);
    if (ArrayBuffer.isView(payload)) return new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    return null;
}

export function decodeIoSnapshot(payload, expectedPlayers) {
    const view = viewFor(payload);
    if (view === null || view.byteLength < 12 || !Number.isInteger(expectedPlayers) ||
        expectedPlayers < 0 || expectedPlayers > MAX_PLAYERS) return null;

    // Validate the complete frame before touching the module-owned render
    // buffers. A truncated packet must never swap a visible body buffer or
    // partially update a snake that is already on screen.
    let at = 0;
    const need = (count) => at + count <= view.byteLength;
    if (view.getUint8(at++) !== 0x53 || view.getUint8(at++) !== 0x49 || view.getUint8(at++) !== 2) return null;
    at += 2; // sequence
    const playerCount = view.getUint8(at++);
    const foodCount = view.getUint16(at, true); at += 2;
    const obstacleMask = view.getUint32(at, true); at += 4;
    if (playerCount !== expectedPlayers || playerCount > MAX_PLAYERS || foodCount > MAX_FOOD || (obstacleMask & ~0x07ffffff) !== 0) return null;

    for (let index = 0; index < playerCount; index++) {
        if (!need(11)) return null;
        at += 6; // score + mass
        const bodyCount = view.getUint16(at, true); at += 2;
        at += 2; // angle
        const flags = view.getUint8(at++);
        if ((flags & ~3) !== 0) return null;
        if (bodyCount === 0 || bodyCount > MAX_BODY || !need(bodyCount * 4)) return null;
        for (let bodyIndex = 0; bodyIndex < bodyCount; bodyIndex++) {
            const x = view.getUint16(at, true), y = view.getUint16(at + 2, true); at += 4;
            if (x >= ARENA || y >= ARENA) return null;
        }
    }

    for (let index = 0; index < foodCount; index++) {
        if (!need(7)) return null;
        const slot = view.getUint16(at, true); at += 2;
        const x = view.getUint16(at, true); at += 2;
        const y = view.getUint16(at, true); at += 2;
        const mass = view.getUint8(at++);
        if (slot >= MAX_FOOD || x >= ARENA || y >= ARENA || mass < 1 || mass > 10) return null;
    }
    if (at !== view.byteLength) return null;

    // The second pass cannot fail and commits directly into fixed reusable
    // buffers, keeping the 15 Hz snapshot path allocation-free.
    at = 3;
    const sequence = view.getUint16(at, true); at += 2;
    at += 1; // player count already validated
    at += 2; // food count already validated
    at += 4; // obstacle mask already validated
    for (let index = 0; index < playerCount; index++) {
        const player = players[index];
        player.score = view.getUint32(at, true); at += 4;
        player.mass = view.getUint16(at, true); at += 2;
        const bodyCount = view.getUint16(at, true); at += 2;
        player.previousAngle = player.angle;
        player.angle = view.getUint16(at, true) / 65535 * Math.PI * 2; at += 2;
        const flags = view.getUint8(at++);
        player.boosting = (flags & 1) !== 0;
        player.shielded = (flags & 2) !== 0;
        const swap = player.previous;
        player.previous = player.body;
        player.body = swap;
        player.body.length = bodyCount;
        for (let bodyIndex = 0; bodyIndex < bodyCount; bodyIndex++) {
            const x = view.getUint16(at, true), y = view.getUint16(at + 2, true); at += 4;
            let point = player.body[bodyIndex];
            if (point === undefined) point = player.body[bodyIndex] = { x: 0, y: 0 };
            point.x = x;
            point.y = y;
        }
    }

    foodMass.fill(0);
    for (let index = 0; index < foodCount; index++) {
        const slot = view.getUint16(at, true); at += 2;
        const x = view.getUint16(at, true); at += 2;
        const y = view.getUint16(at, true); at += 2;
        const mass = view.getUint8(at++);
        foodX[slot] = x;
        foodY[slot] = y;
        foodMass[slot] = mass;
        foodSlots[index] = slot;
    }
    decoded.sequence = sequence;
    decoded.playerCount = playerCount;
    decoded.foodCount = foodCount;
    decoded.obstacleMask = obstacleMask;
    return decoded;
}
