const MAX_PLAYERS = 16;
const MAX_BONUS = 12;
const MAX_DROPS = 2;
const COLS = 128;
const ROWS = 72;
const MAX_CELLS = COLS * ROWS;

const players = Array.from({ length: MAX_PLAYERS }, () => ({
    score: 0, cells: 0, packed: false, bodyOffset: 0,
    mode: 0, headX: 0, headY: 0
}));
const bonus = Array.from({ length: MAX_BONUS }, () => ({ x: 0, y: 0 }));
const drops = Array.from({ length: MAX_DROPS }, () => ({ x: 0, y: 0, ttl: 0 }));
const decoded = {
    view: null, kind: 0, sequence: 0, playerCount: 0, players,
    bonusCount: 0, bonus, dropCount: 0, drops,
    hasGolden: false, goldenX: 0, goldenY: 0, goldenTtl: 0
};

function dataView(payload) {
    if (payload instanceof ArrayBuffer) return new DataView(payload);
    if (ArrayBuffer.isView(payload)) return new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    return null;
}

function validCell(x, y) {
    return x >= 0 && x < COLS && y >= 0 && y < ROWS;
}

/**
 * Parse and validate a complete v4 snapshot into module-owned scratch state.
 * No caller-visible game state is mutated unless this function succeeds.
 */
export function decodeSnapshot(payload, expectedPlayers, lastSequence, currentPlayers) {
    const view = dataView(payload);
    if (view === null || view.byteLength < 7 || expectedPlayers > MAX_PLAYERS) return null;
    let at = 0;
    const need = (bytes) => bytes >= 0 && at + bytes <= view.byteLength;
    if (view.getUint8(at++) !== 0x53 || view.getUint8(at++) !== 0x4e || view.getUint8(at++) !== 4) return null;
    if (!need(3)) return null;
    const sequence = view.getUint16(at, true); at += 2;
    const header = view.getUint8(at++);
    if ((header & 0x60) !== 0) return null;
    const kind = header >>> 7;
    const playerCount = header & 0x1f;
    if (playerCount !== expectedPlayers || playerCount > MAX_PLAYERS) return null;
    if (kind === 1 && (!Number.isInteger(lastSequence) || sequence !== ((lastSequence + 1) & 0xffff))) return null;

    for (let index = 0; index < playerCount; index++) {
        const out = players[index];
        if (kind === 0) {
            if (!need(6)) return null;
            out.score = view.getInt32(at, true); at += 4;
            const encodedCells = view.getUint16(at, true); at += 2;
            out.packed = (encodedCells & 0x8000) !== 0;
            out.cells = encodedCells & 0x7fff;
            if (out.cells === 0 || out.cells > MAX_CELLS) return null;
            out.bodyOffset = at;
            if (out.packed) {
                const pathBytes = Math.ceil((out.cells - 1) / 4);
                if (!need(2 + pathBytes)) return null;
                let x = view.getUint8(at++);
                let y = view.getUint8(at++);
                if (!validCell(x, y)) return null;
                for (let cell = 1; cell < out.cells; cell++) {
                    const direction = (view.getUint8(at + ((cell - 1) >> 2)) >> (((cell - 1) & 3) * 2)) & 3;
                    if (direction === 0) y--; else if (direction === 1) y++;
                    else if (direction === 2) x--; else x++;
                    if (!validCell(x, y)) return null;
                }
                if (pathBytes > 0 && ((out.cells - 1) & 3) !== 0) {
                    const usedBits = ((out.cells - 1) & 3) * 2;
                    if ((view.getUint8(at + pathBytes - 1) >> usedBits) !== 0) return null;
                }
                at += pathBytes;
            } else {
                if (!need(out.cells * 2)) return null;
                for (let cell = 0; cell < out.cells; cell++) {
                    if (!validCell(view.getUint8(at + cell * 2), view.getUint8(at + cell * 2 + 1))) return null;
                }
                at += out.cells * 2;
            }
        } else {
            if (!need(1)) return null;
            const flags = view.getUint8(at++);
            if ((flags & 0xe0) !== 0) return null;
            out.mode = flags & 3;
            if (out.mode === 3) return null;
            const current = currentPlayers[index];
            if (current === undefined || !Array.isArray(current.snake) || current.snake.length === 0) return null;
            out.cells = current.snake.length + (out.mode === 2 ? 1 : 0);
            if (out.cells > MAX_CELLS) return null;
            out.score = current.score;
            if ((flags & 4) !== 0) {
                if (!need(4)) return null;
                out.score = view.getInt32(at, true); at += 4;
            }
            if (out.mode === 1 || out.mode === 2) {
                const direction = (flags >> 3) & 3;
                out.headX = current.snake[0].x / 16;
                out.headY = current.snake[0].y / 16;
                if (direction === 0) out.headY--; else if (direction === 1) out.headY++;
                else if (direction === 2) out.headX--; else out.headX++;
                if (!validCell(out.headX, out.headY)) return null;
            } else if ((flags & 0x18) !== 0) return null;
        }
    }

    if (!need(1)) return null;
    const worldHeader = view.getUint8(at++);
    if ((worldHeader & 0x80) !== 0) return null;
    const bonusCount = worldHeader & 0x0f;
    const dropCount = (worldHeader >>> 4) & 3;
    const hasGolden = (worldHeader & 0x40) !== 0;
    if (bonusCount > MAX_BONUS || !need(bonusCount * 2)) return null;
    for (let index = 0; index < bonusCount; index++) {
        const x = view.getUint8(at++), y = view.getUint8(at++);
        if (!validCell(x, y)) return null;
        bonus[index].x = x; bonus[index].y = y;
    }
    if (dropCount > MAX_DROPS || !need(dropCount * 4)) return null;
    for (let index = 0; index < dropCount; index++) {
        const x = view.getUint8(at++), y = view.getUint8(at++);
        if (!validCell(x, y)) return null;
        drops[index].x = x; drops[index].y = y;
        drops[index].ttl = view.getUint16(at, true); at += 2;
    }
    let goldenX = 0, goldenY = 0, goldenTtl = 0;
    if (hasGolden) {
        if (!need(4)) return null;
        goldenX = view.getUint8(at++); goldenY = view.getUint8(at++);
        if (!validCell(goldenX, goldenY)) return null;
        goldenTtl = view.getUint16(at, true); at += 2;
    }
    if (at !== view.byteLength) return null;

    decoded.view = view;
    decoded.kind = kind;
    decoded.sequence = sequence;
    decoded.playerCount = playerCount;
    decoded.bonusCount = bonusCount;
    decoded.dropCount = dropCount;
    decoded.hasGolden = hasGolden;
    decoded.goldenX = goldenX;
    decoded.goldenY = goldenY;
    decoded.goldenTtl = goldenTtl;
    return decoded;
}
