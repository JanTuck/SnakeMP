//! Snek multiplayer server. Native WebSocket control packets and versioned
//! binary snapshots, per docs/SPEC.md. Standard library only.
//!
//! Architecture:
//!   - one edge-triggered epoll reactor owns HTTP and WebSocket I/O;
//!   - direct writev on the ready-socket path, retained buffers only for
//!     backpressure, and reusable per-lobby serialization buffers;
//!   - adaptive workers each step up to a configurable number of lobbies;
//!   - all public assets embedded at compile time via @embedFile.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const builtin = @import("builtin");
const assets = @import("assets_manifest.zig");
const config = @import("config.zig");
const collision = @import("collision.zig");
const json = @import("json.zig");
const model = @import("model.zig");
const binary_snapshot = @import("snapshot.zig");
const stats_json = @import("stats.zig");
const text = @import("text.zig");
const websocket = @import("websocket.zig");
const worker_balance = @import("worker_balance.zig");

const Allocator = std.mem.Allocator;
const Buf = json.Buf;
const jsString = json.string;
const jnum = json.number;
const jstrField = json.stringField;
const pf = json.print;
const eventFrame = json.eventFrame;
const jsTrim = text.jsTrim;
const checkUsername = text.checkUsername;
const percentDecode = text.percentDecode;
const formDecode = text.formDecode;
const uriEncodeComponent = text.uriEncodeComponent;
const extractFormField = text.extractFormField;
const extractJsonField = text.extractJsonField;

// ------------------------------------------------------------------ tuning

const GRID_W = config.GRID_W;
const GRID_H = config.GRID_H;
const CELL: i32 = model.CELL;
const COLS: i32 = config.GRID_COLS;
const ROWS: i32 = config.GRID_ROWS;

comptime {
    if (GRID_W != COLS * CELL or GRID_H != ROWS * CELL)
        @compileError("world dimensions must be exact cell multiples");
    if (COLS > @as(i32, std.math.maxInt(u8)) + 1 or ROWS > @as(i32, std.math.maxInt(u8)) + 1)
        @compileError("snapshot cell coordinates must fit on the u8 wire");
}

const TICK_NS = config.TICK_NS;
const BACKGROUND_SNAPSHOT_MS = config.BACKGROUND_SNAPSHOT_MS;
const DEFAULT_MAX_PLAYERS_GLOBAL = config.DEFAULT_MAX_PLAYERS_GLOBAL;
const DEFAULT_MAX_PLAYERS_PER_LOBBY = config.DEFAULT_MAX_PLAYERS_PER_LOBBY;
const DEFAULT_MAX_LOBBIES = config.DEFAULT_MAX_LOBBIES;
const DEFAULT_LOBBIES_PER_WORKER = config.LOBBIES_PER_WORKER;
const GAME_WORKER_STACK = config.GAME_WORKER_STACK;
const DEFAULT_LOBBY_IDLE_DELETE_MS = config.LOBBY_IDLE_DELETE_MS;
const DEFAULT_LOBBY_ID = config.DEFAULT_LOBBY_ID;
const MAX_LOBBY_PASSWORD_BYTES = config.MAX_LOBBY_PASSWORD_BYTES;
const BONUS_CAP = config.BONUS_CAP;
const DROP_MAX = config.DROP_MAX;
const KILL_STREAK_WINDOW_MS: i64 = 15_000;
const DROP_TTL_MS = config.DROP_TTL_MS;
const GOLDEN_TTL_MS = config.GOLDEN_TTL_MS;
const GOLDEN_POINTS = config.GOLDEN_POINTS;
const DROP_POINTS = config.DROP_POINTS;
const DROP_GROWTH = config.DROP_GROWTH;
const DROP_APPLES = config.DROP_APPLES;
const REMAINS_TTL_MS = config.REMAINS_TTL_MS;
const FEAST_REMAINS_TTL_MS = config.FEAST_REMAINS_TTL_MS;
const FEAST_DURATION_MS = config.FEAST_DURATION_MS;
const CORPSE_REMAINS_MAX = config.CORPSE_REMAINS_MAX;
const BOOST_COST_TICKS = config.BOOST_COST_TICKS;
const BOOST_MIN_CELLS = config.BOOST_MIN_CELLS;
const SPECTATE_FOCUS_MS = config.SPECTATE_FOCUS_MS;
const BOUNTY_MIN_SCORE = config.BOUNTY_MIN_SCORE;
const PING_INTERVAL_MS = config.PING_INTERVAL_MS;
const PING_TIMEOUT_MS = config.PING_TIMEOUT_MS;
const ERR_INVALID_USERNAME = config.ERR_INVALID_USERNAME;
const ERR_UNKNOWN_GAME = config.ERR_UNKNOWN_GAME;
const ERR_SERVER_FULL = config.ERR_SERVER_FULL;
const ERR_LOBBY_FULL = config.ERR_LOBBY_FULL;
const WS_MAGIC = config.WS_MAGIC;
const SID_LEN = model.SID_LEN; // 16 random bytes -> base64url without padding
const MAX_HTTP_HEAD_LINE = config.MAX_HTTP_HEAD_LINE;
const MAX_HTTP_BODY = config.MAX_HTTP_BODY;
const MAX_HTTP_INPUT = config.MAX_HTTP_INPUT;
const MAX_WS_INPUT = config.MAX_WS_INPUT;
const MAX_QUEUE_BYTES = config.MAX_QUEUE_BYTES;
const MAX_QUEUE_ITEMS: usize = 4096;
const MAX_OUTPUT_IOVECS: usize = 64;
const OUTPUT_COMPACT_MIN_HEAD: usize = 64;
const OUTPUT_RETAINED_ITEMS: usize = 256;
const MAINTENANCE_BATCH: usize = 4096;
const HTTP_IDLE_MS = config.HTTP_IDLE_MS;

// ------------------------------------------------------------------ state

var galloc: Allocator = undefined;

var g_io: std.Io = undefined;
var rng_prng: std.Random.DefaultPrng = undefined;
var lobbies: std.StringArrayHashMapUnmanaged(*Lobby) = .empty;
var max_players_global: usize = DEFAULT_MAX_PLAYERS_GLOBAL;
var max_players_per_lobby: usize = DEFAULT_MAX_PLAYERS_PER_LOBBY;
var max_lobbies: usize = DEFAULT_MAX_LOBBIES;
var lobbies_per_worker: usize = DEFAULT_LOBBIES_PER_WORKER;
var lobby_idle_delete_ms: i64 = DEFAULT_LOBBY_IDLE_DELETE_MS;
/// Active snakes only; exported by /debug/stats as the gameplay population.
var total_players: std.atomic.Value(usize) = .init(0);
/// Every retained lobby identity, including game-over chat spectators. This is
/// the authoritative process-wide SNEK_MAX_PLAYERS capacity counter.
var total_lobby_members: std.atomic.Value(usize) = .init(0);
var start_ms: i64 = 0;
var debug_enabled = false;
var shutting_down: std.atomic.Value(bool) = .init(false);
var listen_fd: posix.fd_t = -1;
var epoll_fd: posix.fd_t = -1;
var connections: std.AutoHashMapUnmanaged(posix.fd_t, *Conn) = .empty;
// Bytes count successful kernel writes. Frames count complete direct writes or
// frames whose unsent bytes were accepted by the bounded output queue.
var network_bytes_sent: std.atomic.Value(u64) = .init(0);
// Only the epoll reactor reads sockets and builds the debug response, so these
// receive-side counters do not need cross-thread atomic read-modify-writes.
var network_bytes_received: u64 = 0;
var websocket_frames_sent: std.atomic.Value(u64) = .init(0);
var websocket_frames_received: u64 = 0;
var input_event_ns_total: u64 = 0;
var input_events: u64 = 0;
var snapshot_pool_mutex: std.Io.Mutex = .init;
var snapshot_pool: std.ArrayListUnmanaged(*model.SharedFrame) = .empty;
const SNAPSHOT_POOL_LIMIT: usize = 64;
const SNAPSHOT_POOL_MAX_CAPACITY: usize = 64 * 1024;

const GameWorker = struct {
    mutex: std.Io.Mutex = .init,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    lobbies: std.ArrayListUnmanaged(*Lobby) = .empty,
};

var game_workers: std.ArrayListUnmanaged(*GameWorker) = .empty;
var worker_migrations: u64 = 0;
var last_worker_resize_ms: i64 = 0;

inline fn clockNanos(clock: linux.clockid_t) i64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(clock, &ts)) != .SUCCESS) {
        @panic("clock_gettime failed");
    }
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

inline fn monoNanos() i64 {
    return clockNanos(.MONOTONIC);
}

inline fn unixMillis() i64 {
    return @divTrunc(clockNanos(.REALTIME), std.time.ns_per_ms);
}

inline fn closeFd(fd: posix.fd_t) void {
    _ = linux.close(fd);
}

fn sleepUntilMono(target_ns: i64) void {
    const request = linux.timespec{
        .sec = @intCast(@divTrunc(target_ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(target_ns, std.time.ns_per_s)),
    };
    while (true) {
        const rc = linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &request, null);
        if (linux.errno(rc) != .INTR) return;
    }
}

const Direction = model.Direction;
const CellPos = model.CellPos;
const Player = model.Player;
const Lobby = model.Lobby;
const Conn = model.Conn;

fn acquireSharedFrame() ?*model.SharedFrame {
    snapshot_pool_mutex.lockUncancelable(g_io);
    const reused = snapshot_pool.pop();
    snapshot_pool_mutex.unlock(g_io);
    const frame = reused orelse blk: {
        const created = galloc.create(model.SharedFrame) catch return null;
        created.* = .{};
        break :blk created;
    };
    frame.refs.store(1, .release);
    frame.header_len = 0;
    frame.keyframe = true;
    frame.payload.clearRetainingCapacity();
    return frame;
}

fn retainSharedFrame(frame: *model.SharedFrame) void {
    _ = frame.refs.fetchAdd(1, .monotonic);
}

fn releaseSharedFrame(frame: *model.SharedFrame) void {
    if (frame.refs.fetchSub(1, .acq_rel) != 1) return;
    snapshot_pool_mutex.lockUncancelable(g_io);
    if (snapshot_pool.items.len < SNAPSHOT_POOL_LIMIT and frame.payload.capacity <= SNAPSHOT_POOL_MAX_CAPACITY) {
        snapshot_pool.append(galloc, frame) catch {
            snapshot_pool_mutex.unlock(g_io);
            frame.payload.deinit(galloc);
            galloc.destroy(frame);
            return;
        };
        snapshot_pool_mutex.unlock(g_io);
        return;
    }
    snapshot_pool_mutex.unlock(g_io);
    frame.payload.deinit(galloc);
    galloc.destroy(frame);
}

fn drainSnapshotPool() void {
    snapshot_pool_mutex.lockUncancelable(g_io);
    defer snapshot_pool_mutex.unlock(g_io);
    for (snapshot_pool.items) |frame| {
        frame.payload.deinit(galloc);
        galloc.destroy(frame);
    }
    snapshot_pool.deinit(galloc);
    snapshot_pool = .empty;
}

// ------------------------------------------------------------------ rng helpers

fn randomCell(l: *Lobby) CellPos {
    const cx = l.rng.random().intRangeLessThan(i32, 0, COLS);
    const cy = l.rng.random().intRangeLessThan(i32, 0, ROWS);
    return .{ .x = cx * CELL, .y = cy * CELL };
}

const OBJECTIVE_EDGE_CELLS: i32 = 6;
const HUD_TOP_ROWS: i32 = ROWS / 6;
const HUD_LEFT_COLS: i32 = COLS * 2 / 3;
const HUD_LEFT_ROWS: i32 = ROWS / 2;
const HUD_MUTE_COL: i32 = COLS * 5 / 6;
const HUD_MUTE_ROW: i32 = ROWS * 5 / 6;
const HUD_CHAT_COL: i32 = COLS * 2 / 5;
const HUD_CHAT_ROW: i32 = ROWS * 3 / 5;
// Four cells preserve roughly a quarter-second of reaction time at 15 Hz while
// still allowing every advertised 32-player lobby slot to receive a safe spawn.
const SPAWN_HEAD_CLEARANCE_CELLS: i32 = 4;
const SPAWN_BODY_CLEARANCE_CELLS: i32 = 2;

/// Keep every mode's objectives comfortably inside the playable field and out
/// of the responsive HUD's conservative footprint. A shallow full-width band
/// covers score/feed notifications, the larger top-left block covers compact
/// standings, and the bottom-right corner covers the sound control.
fn objectiveCellSafe(cell: CellPos) bool {
    const cx = @divExact(cell.x, CELL);
    const cy = @divExact(cell.y, CELL);
    if (cx < OBJECTIVE_EDGE_CELLS or cx >= COLS - OBJECTIVE_EDGE_CELLS or
        cy < OBJECTIVE_EDGE_CELLS or cy >= ROWS - OBJECTIVE_EDGE_CELLS)
    {
        return false;
    }
    if (cy < HUD_TOP_ROWS) return false;
    if (cx < HUD_LEFT_COLS and cy < HUD_LEFT_ROWS) return false;
    if (cx < HUD_CHAT_COL and cy >= HUD_CHAT_ROW) return false;
    if (cx >= HUD_MUTE_COL and cy >= HUD_MUTE_ROW) return false;
    return true;
}

fn randomObjectiveCell(l: *Lobby) CellPos {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const cx = l.rng.random().intRangeLessThan(i32, OBJECTIVE_EDGE_CELLS, COLS - OBJECTIVE_EDGE_CELLS);
        const cy = l.rng.random().intRangeLessThan(i32, OBJECTIVE_EDGE_CELLS, ROWS - OBJECTIVE_EDGE_CELLS);
        const cell: CellPos = .{ .x = cx * CELL, .y = cy * CELL };
        if (objectiveCellSafe(cell)) return cell;
    }
    return .{ .x = (COLS / 2) * CELL, .y = (ROWS / 2) * CELL };
}

/// Keep new players in the central half of the arena. They still spawn at a
/// random free cell, but always have enough reaction room to choose an initial
/// direction before a wall can become an immediate hazard.
fn randomSpawnCell(l: *Lobby) CellPos {
    const cx = l.rng.random().intRangeLessThan(i32, COLS / 4, COLS - COLS / 4);
    const cy = l.rng.random().intRangeLessThan(i32, ROWS / 4, ROWS - ROWS / 4);
    return .{ .x = cx * CELL, .y = cy * CELL };
}

fn snakeOccupies(l: *Lobby, cell: CellPos) bool {
    for (l.players.items) |p| {
        for (p.snake.items) |s| {
            if (s.x == cell.x and s.y == cell.y) return true;
        }
    }
    return false;
}

fn pickupOccupies(l: *const Lobby, cell: CellPos) bool {
    if (sameCell(l.food, cell)) return true;
    for (l.bonus.items) |bonus| if (sameCell(bonus.pos, cell)) return true;
    for (l.drops.items) |drop| if (sameCell(drop.pos, cell)) return true;
    if (l.golden) |golden| if (sameCell(golden.pos, cell)) return true;
    for (l.remains.items) |remain| if (sameCell(remain.pos, cell)) return true;
    return false;
}

fn cellDistance(left: CellPos, right: CellPos) i32 {
    const dx = @abs(@divExact(left.x - right.x, CELL));
    const dy = @abs(@divExact(left.y - right.y, CELL));
    return @intCast(@max(dx, dy));
}

/// Authoritative join safety: the central half provides wall reaction room,
/// pickups are never hidden beneath a new snake, and existing heads/bodies get
/// separate buffers so a player cannot materialize into an unavoidable death.
fn spawnCellSafe(l: *const Lobby, cell: CellPos) bool {
    if (cell.x < (COLS / 4) * CELL or cell.x >= (COLS - COLS / 4) * CELL or
        cell.y < (ROWS / 4) * CELL or cell.y >= (ROWS - ROWS / 4) * CELL)
    {
        return false;
    }
    // A mathematically safe spawn is still unusable when the local head is
    // hidden beneath the standings, chat, feed, or sound controls.
    if (!objectiveCellSafe(cell)) return false;
    if (pickupOccupies(l, cell)) return false;
    for (l.players.items) |player| {
        for (player.snake.items, 0..) |segment, index| {
            const clearance = if (index == 0) SPAWN_HEAD_CLEARANCE_CELLS else SPAWN_BODY_CLEARANCE_CELLS;
            if (cellDistance(cell, segment) <= clearance) return false;
        }
    }
    return true;
}

/// Free of snakes AND every pickup kind (SPEC "Free cell"), 200 attempts.
fn randomFreeCell(l: *Lobby) ?CellPos {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        const c = randomObjectiveCell(l);
        var taken = snakeOccupies(l, c);
        if (!taken) taken = (l.food.x == c.x and l.food.y == c.y);
        if (!taken) {
            for (l.bonus.items) |b| {
                if (b.pos.x == c.x and b.pos.y == c.y) {
                    taken = true;
                    break;
                }
            }
        }
        if (!taken) {
            for (l.drops.items) |d| {
                if (d.pos.x == c.x and d.pos.y == c.y) {
                    taken = true;
                    break;
                }
            }
        }
        if (!taken) {
            if (l.golden) |g| {
                if (g.pos.x == c.x and g.pos.y == c.y) taken = true;
            }
        }
        if (!taken) {
            for (l.remains.items) |remain| {
                if (remain.pos.x == c.x and remain.pos.y == c.y) {
                    taken = true;
                    break;
                }
            }
        }
        if (!taken) return c;
    }
    return null;
}

/// Random probes preserve natural distribution. The exhaustive fallback makes
/// success/failure authoritative: null means no safe central cell exists, not
/// merely that the random retry budget was unlucky.
fn pickSpawnCell(l: *Lobby) ?CellPos {
    for (0..256) |_| {
        const candidate = randomSpawnCell(l);
        if (spawnCellSafe(l, candidate)) return candidate;
    }
    var cy: i32 = ROWS / 4;
    while (cy < ROWS - ROWS / 4) : (cy += 1) {
        var cx: i32 = COLS / 4;
        while (cx < COLS - COLS / 4) : (cx += 1) {
            const candidate: CellPos = .{ .x = cx * CELL, .y = cy * CELL };
            if (spawnCellSafe(l, candidate)) return candidate;
        }
    }
    return null;
}

// Thirty-two visually separated colors cover the complete live+spectator cap.
// Selection probes from a random offset but never reuses an exact color while
// its identity is still present in the lobby chat history membership.
const PLAYER_COLORS = [_][]const u8{
    "#ff6b6b", "#ff8787", "#f06595", "#f783ac", "#cc5de8", "#da77f2", "#845ef7", "#9775fa",
    "#5c7cfa", "#748ffc", "#339af0", "#4dabf7", "#22b8cf", "#3bc9db", "#20c997", "#38d9a9",
    "#51cf66", "#69db7c", "#94d82d", "#a9e34b", "#fcc419", "#ffd43b", "#ff922b", "#ffa94d",
    "#ffb4a2", "#f7b2d9", "#e5a9ff", "#b8c0ff", "#a5d8ff", "#99e9f2", "#96f2d7", "#c0eb75",
};

fn playerColorInUse(l: *const Lobby, color: []const u8) bool {
    for (l.players.items) |player| {
        if (std.mem.eql(u8, player.color_hex, color)) return true;
    }
    for (l.spectators.items) |connection| {
        if (connection.player) |player| {
            if (std.mem.eql(u8, player.color_hex, color)) return true;
        }
    }
    return false;
}

fn choosePlayerColor(l: *Lobby) []const u8 {
    const start = l.rng.random().uintLessThan(usize, PLAYER_COLORS.len);
    for (0..PLAYER_COLORS.len) |offset| {
        const color = PLAYER_COLORS[(start + offset) % PLAYER_COLORS.len];
        if (!playerColorInUse(l, color)) return color;
    }
    return PLAYER_COLORS[start];
}

// ------------------------------------------------------------------ collisions

fn collidedWall(h: CellPos) bool {
    return h.x > GRID_W - CELL or h.x < 0 or h.y > GRID_H - CELL or h.y < 0;
}

fn wrapPlayerHead(player: *Player) void {
    const head = &player.snake.items[0];
    head.x = @mod(head.x, GRID_W);
    head.y = @mod(head.y, GRID_H);
}

// ------------------------------------------------------------------ connection

const wsHeader = websocket.header;

fn updateConnInterest(c: *Conn, want_write: bool) void {
    if (c.want_write == want_write or epoll_fd < 0) return;
    c.want_write = want_write;
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.ET |
            @as(u32, if (want_write) linux.EPOLL.OUT else 0),
        .data = .{ .ptr = @intFromPtr(c) },
    };
    const rc = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_MOD, c.fd, &ev);
    if (linux.errno(rc) != .SUCCESS) c.poisoned = true;
}

fn releasePending(output: model.PendingOutput) void {
    switch (output) {
        .owned => |bytes| galloc.free(bytes),
        .borrowed => {},
        .shared => |frame| releaseSharedFrame(frame),
    }
}

fn outputEmpty(c: *const Conn) bool {
    return c.output_head == c.output.items.len;
}

fn resetOutputStorage(c: *Conn) void {
    std.debug.assert(outputEmpty(c));
    std.debug.assert(c.output_bytes == 0);
    if (c.output.capacity > OUTPUT_RETAINED_ITEMS) {
        c.output.deinit(galloc);
        c.output = .empty;
    } else {
        c.output.clearRetainingCapacity();
    }
    c.output_head = 0;
    c.output_offset = 0;
}

fn compactOutputPrefix(c: *Conn) void {
    if (c.output_head < OUTPUT_COMPACT_MIN_HEAD) return;
    const live = c.output.items.len - c.output_head;
    if (c.output_head < live) return;
    std.mem.copyForwards(model.PendingOutput, c.output.items[0..live], c.output.items[c.output_head..]);
    c.output.shrinkRetainingCapacity(live);
    c.output_head = 0;
}

fn prepareOutputAppend(c: *Conn) void {
    if (outputEmpty(c)) {
        resetOutputStorage(c);
    } else {
        compactOutputPrefix(c);
    }
}

fn outputItemLimitReached(c: *const Conn) bool {
    return c.mode == .websocket and c.output.items.len - c.output_head >= MAX_QUEUE_ITEMS;
}

fn appendOwnedOutput(c: *Conn, first: []const u8, second: []const u8) bool {
    prepareOutputAppend(c);
    const size = first.len + second.len;
    if (outputItemLimitReached(c) or c.output_bytes + size > MAX_QUEUE_BYTES) {
        c.poisoned = true;
        return false;
    }
    const bytes = galloc.alloc(u8, size) catch {
        c.poisoned = true;
        return false;
    };
    @memcpy(bytes[0..first.len], first);
    @memcpy(bytes[first.len..], second);
    c.output.append(galloc, .{ .owned = bytes }) catch {
        galloc.free(bytes);
        c.poisoned = true;
        return false;
    };
    c.output_bytes += size;
    updateConnInterest(c, true);
    return true;
}

fn appendBorrowedOutput(c: *Conn, bytes: []const u8) bool {
    prepareOutputAppend(c);
    if (bytes.len == 0) return true;
    if (outputItemLimitReached(c) or c.output_bytes + bytes.len > MAX_QUEUE_BYTES) {
        c.poisoned = true;
        return false;
    }
    c.output.append(galloc, .{ .borrowed = bytes }) catch {
        c.poisoned = true;
        return false;
    };
    c.output_bytes += bytes.len;
    updateConnInterest(c, true);
    return true;
}

/// A fresh keyframe makes every not-yet-started snapshot before it obsolete,
/// including dependent deltas. Never remove the head after a partial write:
/// websocket frame bytes may not be interleaved.
fn coalesceForKeyframe(c: *Conn) void {
    var read = c.output_head;
    var write = c.output_head;

    // A partially written websocket frame must remain at the head: emitting a
    // keyframe before its suffix would interleave frame bytes on the wire.
    if (read < c.output.items.len and c.output_offset != 0) {
        read += 1;
        write += 1;
    }

    // Compact retained controls in one stable pass. Repeated orderedRemove
    // shifted the remaining suffix once per stale snapshot and became
    // quadratic for deep backpressure queues.
    while (read < c.output.items.len) : (read += 1) {
        const output = c.output.items[read];
        switch (output) {
            .owned, .borrowed => {
                if (write != read) c.output.items[write] = output;
                write += 1;
            },
            .shared => |frame| {
                c.output_bytes -= frame.len();
                releaseSharedFrame(frame);
            },
        }
    }
    c.output.shrinkRetainingCapacity(write);
}

fn appendSharedOutput(c: *Conn, frame: *model.SharedFrame, offset: usize) bool {
    prepareOutputAppend(c);
    std.debug.assert(offset <= frame.len());
    if (frame.keyframe) coalesceForKeyframe(c);
    const remaining = frame.len() - offset;
    if (outputItemLimitReached(c) or c.output_bytes + remaining > MAX_QUEUE_BYTES) {
        c.poisoned = true;
        return false;
    }
    retainSharedFrame(frame);
    c.output.append(galloc, .{ .shared = frame }) catch {
        releaseSharedFrame(frame);
        c.poisoned = true;
        return false;
    };
    if (c.output.items.len - c.output_head == 1) c.output_offset = offset;
    c.output_bytes += remaining;
    updateConnInterest(c, true);
    return true;
}

/// Write immediately when the socket is ready; retain only the unsent suffix.
fn connQueueRaw(c: *Conn, bytes: []const u8) void {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    if (c.closing or c.poisoned or bytes.len == 0) return;
    if (!outputEmpty(c)) {
        _ = appendOwnedOutput(c, bytes, "");
        return;
    }
    while (true) {
        const rc = linux.write(c.fd, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                if (debug_enabled) _ = network_bytes_sent.fetchAdd(sent, .monotonic);
                if (sent < bytes.len) _ = appendOwnedOutput(c, bytes[sent..], "");
                return;
            },
            .INTR => continue,
            .AGAIN => {
                _ = appendOwnedOutput(c, bytes, "");
                return;
            },
            else => {
                c.poisoned = true;
                return;
            },
        }
    }
}

/// HTTP response fast path. The header is stack-backed by the caller, while
/// static bodies point into embedded process-lifetime storage. A ready socket
/// uses one writev without copying either slice; backpressure copies only the
/// short header and borrows static body bytes.
fn connQueueResponse(c: *Conn, header: []const u8, body: []const u8, body_static: bool) void {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    if (c.closing or c.poisoned) return;

    const queueSuffix = struct {
        fn append(connection: *Conn, header_suffix: []const u8, body_suffix: []const u8, static: bool) void {
            if (!static) {
                if (header_suffix.len > 0 or body_suffix.len > 0) {
                    _ = appendOwnedOutput(connection, header_suffix, body_suffix);
                }
                return;
            }
            if (header_suffix.len > 0 and !appendOwnedOutput(connection, header_suffix, "")) return;
            if (body_suffix.len == 0) return;
            _ = appendBorrowedOutput(connection, body_suffix);
        }
    }.append;

    if (c.http_batching or !outputEmpty(c)) {
        queueSuffix(c, header, body, body_static);
        return;
    }

    const vec = [2]posix.iovec_const{
        .{ .base = header.ptr, .len = header.len },
        .{ .base = body.ptr, .len = body.len },
    };
    while (true) {
        const rc = linux.writev(c.fd, &vec, if (body.len == 0) 1 else vec.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                if (debug_enabled) _ = network_bytes_sent.fetchAdd(sent, .monotonic);
                if (sent < header.len) {
                    queueSuffix(c, header[sent..], body, body_static);
                } else if (sent < header.len + body.len) {
                    queueSuffix(c, "", body[sent - header.len ..], body_static);
                }
                return;
            },
            .INTR => continue,
            .AGAIN => {
                queueSuffix(c, header, body, body_static);
                return;
            },
            else => {
                c.poisoned = true;
                return;
            },
        }
    }
}

/// Caller holds output_mutex. Fast path uses one writev syscall and performs no
/// allocation or copy; backpressured control frames retain an owned suffix.
fn connEnqueueFrameLocked(c: *Conn, opcode: u8, payload: []const u8) void {
    var accepted = false;
    defer {
        if (debug_enabled and accepted) _ = websocket_frames_sent.fetchAdd(1, .monotonic);
    }
    var hdr: [10]u8 = undefined;
    const hlen = wsHeader(&hdr, opcode, payload.len);
    if (!outputEmpty(c)) {
        accepted = appendOwnedOutput(c, hdr[0..hlen], payload);
        return;
    }

    const vec = [2]posix.iovec_const{
        .{ .base = hdr[0..hlen].ptr, .len = hlen },
        .{ .base = payload.ptr, .len = payload.len },
    };
    while (true) {
        const rc = linux.writev(c.fd, &vec, vec.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                if (debug_enabled) _ = network_bytes_sent.fetchAdd(sent, .monotonic);
                if (sent < hlen) {
                    accepted = appendOwnedOutput(c, hdr[sent..hlen], payload);
                } else if (sent < hlen + payload.len) {
                    accepted = appendOwnedOutput(c, payload[sent - hlen ..], "");
                } else accepted = true;
                return;
            },
            .INTR => continue,
            .AGAIN => {
                accepted = appendOwnedOutput(c, hdr[0..hlen], payload);
                return;
            },
            else => {
                c.poisoned = true;
                return;
            },
        }
    }
}

fn connEnqueueFrame(c: *Conn, opcode: u8, payload: []const u8) void {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    if (c.closing or c.poisoned) return;
    connEnqueueFrameLocked(c, opcode, payload);
}

/// Serialize the Close frame after every earlier publication, then seal the
/// output queue before releasing its mutex. Lobby workers can therefore never
/// publish a data frame after Close.
fn connEnqueueClose(c: *Conn, payload: []const u8) void {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    if (c.closing or c.poisoned) return;
    connEnqueueFrameLocked(c, 0x8, payload);
    c.closing = true;
}

/// Publish one immutable binary snapshot to a connection. All connections in
/// the lobby reference the same payload under backpressure; fast writes retain
/// no per-connection state at all.
const SharedFrameAccounting = struct {
    bytes_sent: usize = 0,
    frames_sent: usize = 0,
};

fn connEnqueueSharedFrame(c: *Conn, frame: *model.SharedFrame) SharedFrameAccounting {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    if (c.closing or c.poisoned) return .{};
    if (!outputEmpty(c)) {
        return .{ .frames_sent = @intFromBool(appendSharedOutput(c, frame, 0)) };
    }

    const hlen: usize = frame.header_len;
    const vec = [2]posix.iovec_const{
        .{ .base = frame.header[0..hlen].ptr, .len = hlen },
        .{ .base = frame.payload.items.ptr, .len = frame.payload.items.len },
    };
    while (true) {
        const rc = linux.writev(c.fd, &vec, vec.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                const accepted = sent == frame.len() or appendSharedOutput(c, frame, sent);
                return .{ .bytes_sent = sent, .frames_sent = @intFromBool(accepted) };
            },
            .INTR => continue,
            .AGAIN => {
                return .{ .frames_sent = @intFromBool(appendSharedOutput(c, frame, 0)) };
            },
            else => {
                c.poisoned = true;
                return .{};
            },
        }
    }
}

fn connEnqueueText(c: *Conn, payload: []const u8) void {
    connEnqueueFrame(c, 0x1, payload);
}

fn outputVectors(c: *const Conn, vectors: *[MAX_OUTPUT_IOVECS]posix.iovec_const) usize {
    var count: usize = 0;
    var index = c.output_head;
    while (index < c.output.items.len and count < vectors.len) : (index += 1) {
        const offset = if (index == c.output_head) c.output_offset else 0;
        switch (c.output.items[index]) {
            .owned => |bytes| {
                if (offset < bytes.len) {
                    vectors[count] = .{ .base = bytes[offset..].ptr, .len = bytes.len - offset };
                    count += 1;
                }
            },
            .borrowed => |bytes| {
                if (offset < bytes.len) {
                    vectors[count] = .{ .base = bytes[offset..].ptr, .len = bytes.len - offset };
                    count += 1;
                }
            },
            .shared => |frame| {
                const header_len: usize = frame.header_len;
                if (offset < header_len) {
                    vectors[count] = .{ .base = frame.header[offset..header_len].ptr, .len = header_len - offset };
                    count += 1;
                    if (count == vectors.len) break;
                    if (frame.payload.items.len > 0) {
                        vectors[count] = .{ .base = frame.payload.items.ptr, .len = frame.payload.items.len };
                        count += 1;
                    }
                } else {
                    const payload_offset = offset - header_len;
                    if (payload_offset < frame.payload.items.len) {
                        vectors[count] = .{
                            .base = frame.payload.items[payload_offset..].ptr,
                            .len = frame.payload.items.len - payload_offset,
                        };
                        count += 1;
                    }
                }
            },
        }
    }
    return count;
}

/// Advance across a completed or partial scatter/gather write, releasing every
/// fully consumed queue item exactly once. Caller holds output_mutex.
fn consumeOutputBytes(c: *Conn, sent: usize) void {
    std.debug.assert(sent <= c.output_bytes);
    var remaining = sent;
    while (remaining > 0) {
        std.debug.assert(!outputEmpty(c));
        const output = c.output.items[c.output_head];
        const available = output.len() - c.output_offset;
        if (remaining < available) {
            c.output_offset += remaining;
            remaining = 0;
        } else {
            remaining -= available;
            releasePending(output);
            c.output_head += 1;
            c.output_offset = 0;
        }
    }
    c.output_bytes -= sent;
}

fn flushOutput(c: *Conn) bool {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    while (!outputEmpty(c)) {
        var vectors: [MAX_OUTPUT_IOVECS]posix.iovec_const = undefined;
        const vector_count = outputVectors(c, &vectors);
        std.debug.assert(vector_count > 0);
        const rc = linux.writev(c.fd, &vectors, vector_count);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                consumeOutputBytes(c, sent);
                if (debug_enabled) _ = network_bytes_sent.fetchAdd(sent, .monotonic);
            },
            .INTR => continue,
            .AGAIN => {
                compactOutputPrefix(c);
                return true;
            },
            else => {
                c.poisoned = true;
                return false;
            },
        }
    }
    resetOutputStorage(c);
    updateConnInterest(c, false);
    return !c.close_after_write;
}

fn connPoisoned(c: *Conn) bool {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    return c.poisoned;
}

fn connOutputDrained(c: *Conn) bool {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    return outputEmpty(c);
}

// ------------------------------------------------------- room operations

fn totalPlayersLocked() usize {
    return total_players.load(.acquire);
}

fn totalLobbyMembersLocked() usize {
    return total_lobby_members.load(.acquire);
}

fn serverHasRetainedCapacity() bool {
    return totalLobbyMembersLocked() < max_players_global;
}

fn broadcastLobby(l: *Lobby, frame: []const u8) void {
    for (l.players.items) |p| connEnqueueText(p.conn, frame);
    for (l.spectators.items) |c| connEnqueueText(c, frame);
}

fn nextBackgroundSnapshot(now: i64) i64 {
    const interval = BACKGROUND_SNAPSHOT_MS;
    return now - @mod(now, interval) + interval;
}

fn spectatorReceivesSnapshot(c: *const Conn, now: i64) bool {
    return c.spectating_until > now;
}

fn lobbyNeedsGameWorkerLocked(l: *const Lobby, now: i64) bool {
    if (l.players.items.len != 0) return true;
    for (l.spectators.items) |c| {
        if (spectatorReceivesSnapshot(c, now)) return true;
    }
    return false;
}

fn recoverySnapshot(
    l: *Lobby,
    frame: *model.SharedFrame,
    now: i64,
    sequence: u16,
    cached: *?*model.SharedFrame,
) ?*model.SharedFrame {
    if (frame.keyframe) return frame;
    if (cached.*) |recovery| return recovery;

    const recovery = acquireSharedFrame() orelse return null;
    const result = binary_snapshot.buildIndependentKeyframeInto(&recovery.payload, l, now, sequence, galloc) catch {
        releaseSharedFrame(recovery);
        return null;
    };
    recovery.keyframe = true;
    recovery.header_len = @intCast(wsHeader(&recovery.header, 0x2, result.bytes.len));
    cached.* = recovery;
    return recovery;
}

/// Foreground clients receive the dependent 15 Hz stream. Hidden clients get
/// one complete keyframe per second, and a tab returning to the foreground
/// gets a complete keyframe before dependent deltas resume. A single lazily
/// built recovery frame is shared by every client that needs it on this tick.
fn broadcastBinarySnapshot(l: *Lobby, frame: *model.SharedFrame, now: i64, sequence: u16) void {
    var cached_recovery: ?*model.SharedFrame = null;
    defer if (cached_recovery) |recovery| releaseSharedFrame(recovery);
    var accounting: SharedFrameAccounting = .{};
    defer {
        if (debug_enabled and accounting.bytes_sent != 0) _ = network_bytes_sent.fetchAdd(accounting.bytes_sent, .monotonic);
        if (debug_enabled and accounting.frames_sent != 0) _ = websocket_frames_sent.fetchAdd(accounting.frames_sent, .monotonic);
    }

    for (l.players.items) |player| {
        const c = player.conn;
        if (c.snapshot_hidden.load(.acquire)) {
            if (c.next_background_snapshot_ms.load(.acquire) > now) continue;
            const recovery = recoverySnapshot(l, frame, now, sequence, &cached_recovery) orelse continue;
            const sent = connEnqueueSharedFrame(c, recovery);
            accounting.bytes_sent += sent.bytes_sent;
            accounting.frames_sent += sent.frames_sent;
            c.next_background_snapshot_ms.store(nextBackgroundSnapshot(now), .release);
            continue;
        }

        if (c.snapshot_needs_keyframe.swap(false, .acq_rel)) {
            const recovery = recoverySnapshot(l, frame, now, sequence, &cached_recovery) orelse {
                c.snapshot_needs_keyframe.store(true, .release);
                continue;
            };
            const sent = connEnqueueSharedFrame(c, recovery);
            accounting.bytes_sent += sent.bytes_sent;
            accounting.frames_sent += sent.frames_sent;
        } else {
            const sent = connEnqueueSharedFrame(c, frame);
            accounting.bytes_sent += sent.bytes_sent;
            accounting.frames_sent += sent.frames_sent;
        }
    }
    for (l.spectators.items) |c| {
        // The death camera is intentionally short-lived. The connection stays
        // in the lobby for text chat, but receives no more world snapshots
        // once the advertised wreckage/spectate interval has elapsed.
        if (!spectatorReceivesSnapshot(c, now)) continue;
        if (c.snapshot_hidden.load(.acquire)) {
            if (c.next_background_snapshot_ms.load(.acquire) > now) continue;
            const recovery = recoverySnapshot(l, frame, now, sequence, &cached_recovery) orelse continue;
            const sent = connEnqueueSharedFrame(c, recovery);
            accounting.bytes_sent += sent.bytes_sent;
            accounting.frames_sent += sent.frames_sent;
            c.next_background_snapshot_ms.store(nextBackgroundSnapshot(now), .release);
            continue;
        }
        if (c.snapshot_needs_keyframe.swap(false, .acq_rel)) {
            const recovery = recoverySnapshot(l, frame, now, sequence, &cached_recovery) orelse {
                c.snapshot_needs_keyframe.store(true, .release);
                continue;
            };
            const sent = connEnqueueSharedFrame(c, recovery);
            accounting.bytes_sent += sent.bytes_sent;
            accounting.frames_sent += sent.frames_sent;
        } else {
            const sent = connEnqueueSharedFrame(c, frame);
            accounting.bytes_sent += sent.bytes_sent;
            accounting.frames_sent += sent.frames_sent;
        }
    }
}

fn detachPlayer(l: *Lobby, p: *Player) void {
    const index = for (l.players.items, 0..) |candidate, at| {
        if (candidate == p) break at;
    } else return;
    _ = l.players.orderedRemove(index);
    l.roster_dirty = true;
    _ = total_players.fetchSub(1, .acq_rel);
    _ = total_lobby_members.fetchSub(1, .acq_rel);
    p.conn.membership_mutex.lockUncancelable(g_io);
    p.conn.player = null; // allows same-socket rejoin (Retry without reload)
    p.conn.lobby = null;
    p.conn.membership_mutex.unlock(g_io);
}

fn spectatorIndex(l: *const Lobby, c: *const Conn) ?usize {
    for (l.spectators.items, 0..) |candidate, index| {
        if (candidate == c) return index;
    }
    return null;
}

/// Eviction is membership eviction, not a socket close. The connection can
/// immediately join again, while the bounded lobby releases the retained
/// identity and never keeps a stale connection pointer.
fn evictSpectatorLocked(l: *Lobby, index: usize) void {
    const c = l.spectators.orderedRemove(index);
    c.membership_mutex.lockUncancelable(g_io);
    const retained = if (c.lobby == l) c.player else null;
    if (c.lobby == l) {
        c.player = null;
        c.lobby = null;
        c.spectating_until = 0;
        c.spectate_focus = null;
        c.spectate_score = 0;
    }
    c.membership_mutex.unlock(g_io);
    if (retained) |player| {
        _ = total_lobby_members.fetchSub(1, .acq_rel);
        destroyPlayer(player);
    }
}

/// Remove an active snake but retain its bounded identity on the connection.
/// Its body is released after corpse mass is sampled; snapshots end after the
/// death replay, while chat remains until Retry, disconnect, or cap eviction.
fn movePlayerToSpectatorsLocked(l: *Lobby, p: *Player, focus: CellPos, score: i64, now: i64) void {
    const active_index = for (l.players.items, 0..) |candidate, index| {
        if (candidate == p) break index;
    } else return;
    _ = l.players.orderedRemove(active_index);
    l.roster_dirty = true;
    _ = total_players.fetchSub(1, .acq_rel);

    if (l.spectators.items.len >= model.MAX_SPECTATORS) evictSpectatorLocked(l, 0);
    l.spectators.append(galloc, p.conn) catch {
        p.conn.membership_mutex.lockUncancelable(g_io);
        p.conn.player = null;
        p.conn.lobby = null;
        p.conn.membership_mutex.unlock(g_io);
        _ = total_lobby_members.fetchSub(1, .acq_rel);
        destroyPlayer(p);
        return;
    };
    p.snake.deinit(galloc);
    p.snake = .empty;
    p.boosting = false;
    p.conn.membership_mutex.lockUncancelable(g_io);
    p.conn.player = p;
    p.conn.lobby = l;
    p.conn.spectating_until = now + SPECTATE_FOCUS_MS;
    p.conn.spectate_focus = focus;
    p.conn.spectate_score = score;
    p.conn.membership_mutex.unlock(g_io);
}

fn destroyPlayer(p: *Player) void {
    p.snake.deinit(galloc);
    galloc.free(p.name);
    galloc.free(p.color_hex);
    galloc.destroy(p);
}

/// Detach and destroy the player, if any, while preserving the global lock
/// order: lobby -> membership -> output. The reactor owns connection lifetime;
/// the lobby worker owns all game-state mutation.
fn removeConnPlayer(c: *Conn, aa: Allocator) void {
    c.membership_mutex.lockUncancelable(g_io);
    const lobby = c.lobby;
    c.membership_mutex.unlock(g_io);
    const l = lobby orelse return;

    l.mutex.lockUncancelable(g_io);
    defer l.mutex.unlock(g_io);
    c.membership_mutex.lockUncancelable(g_io);
    const player = if (c.lobby == l) c.player else null;
    c.membership_mutex.unlock(g_io);
    const p = player orelse return;
    if (spectatorIndex(l, c)) |index| {
        _ = l.spectators.orderedRemove(index);
        c.membership_mutex.lockUncancelable(g_io);
        c.player = null;
        c.lobby = null;
        c.spectating_until = 0;
        c.spectate_focus = null;
        c.membership_mutex.unlock(g_io);
        _ = total_lobby_members.fetchSub(1, .acq_rel);
        destroyPlayer(p);
        return;
    }
    feedDeath(l, p, null, 0, aa);
    if (l.mode.isArcade()) spawnCorpseRemainsLocked(l, p, unixMillis());
    detachPlayer(l, p);
    destroyPlayer(p);
}

fn gameWorkerLoop(worker: *GameWorker) void {
    var arena = std.heap.ArenaAllocator.init(galloc);
    defer arena.deinit();
    var next_tick = monoNanos() + @as(i64, @intCast(TICK_NS));
    while (!worker.stop.load(.acquire)) {
        sleepUntilMono(next_tick);
        if (worker.stop.load(.acquire)) break;
        _ = arena.reset(.retain_capacity);
        worker.mutex.lockUncancelable(g_io);
        const tick_now = unixMillis();
        for (worker.lobbies.items) |lobby| {
            lobby.mutex.lockUncancelable(g_io);
            if (lobby.players.items.len > 0 or lobby.spectators.items.len > 0)
                tickLobby(lobby, tick_now, arena.allocator());
            lobby.mutex.unlock(g_io);
        }
        worker.mutex.unlock(g_io);
        const now = monoNanos();
        next_tick += @as(i64, @intCast(TICK_NS));
        if (next_tick <= now) next_tick = now + @as(i64, @intCast(TICK_NS));
    }
}

fn createGameWorker(initial_lobby: ?*Lobby) !*GameWorker {
    const worker = try galloc.create(GameWorker);
    errdefer galloc.destroy(worker);
    worker.* = .{};
    errdefer worker.lobbies.deinit(galloc);
    if (initial_lobby) |lobby| try worker.lobbies.append(galloc, lobby);
    try game_workers.append(galloc, worker);
    errdefer _ = game_workers.pop();
    worker.thread = std.Thread.spawn(.{ .stack_size = GAME_WORKER_STACK }, gameWorkerLoop, .{worker}) catch |err| {
        return err;
    };
    return worker;
}

/// Caller must hold the worker mutex. The owner thread is then outside every
/// lobby tick, so these otherwise owner-only measurements are race-free.
fn workerEstimatedCostLocked(worker: *GameWorker) u64 {
    var total: u64 = 0;
    for (worker.lobbies.items) |lobby| {
        total +|= worker_balance.estimatedLobbyCostNs(lobby.balance_ewma_ns, lobby.players.items.len);
    }
    return total;
}

fn assignGameWorker(lobby: *Lobby) !void {
    std.debug.assert(!lobby.worker_assigned);
    var best: ?*GameWorker = null;
    var best_cost: u64 = std.math.maxInt(u64);
    var best_count: usize = std.math.maxInt(usize);
    for (game_workers.items) |worker| {
        worker.mutex.lockUncancelable(g_io);
        if (worker.lobbies.items.len < lobbies_per_worker) {
            const cost = workerEstimatedCostLocked(worker);
            const count = worker.lobbies.items.len;
            if (cost < best_cost or (cost == best_cost and count < best_count)) {
                best = worker;
                best_cost = cost;
                best_count = count;
            }
        }
        worker.mutex.unlock(g_io);
    }
    if (best) |worker| {
        worker.mutex.lockUncancelable(g_io);
        defer worker.mutex.unlock(g_io);
        try worker.lobbies.append(galloc, lobby);
        lobby.worker_assigned = true;
        return;
    }
    _ = try createGameWorker(lobby);
    lobby.worker_assigned = true;
}

fn lockAllGameWorkers() void {
    for (game_workers.items) |worker| worker.mutex.lockUncancelable(g_io);
}

fn unlockAllGameWorkers() void {
    var i = game_workers.items.len;
    while (i > 0) {
        i -= 1;
        game_workers.items[i].mutex.unlock(g_io);
    }
}

/// Evacuate one lightly loaded worker while every worker is frozen between
/// ticks. Appending to the destination happens before removal from the source,
/// so allocation failure leaves ownership unchanged.
fn retireLightestGameWorker(now_ms: i64, aa: Allocator) bool {
    if (game_workers.items.len == 0) return false;
    const loads = aa.alloc(u64, game_workers.items.len) catch return false;
    lockAllGameWorkers();

    var source_index: usize = 0;
    for (game_workers.items, 0..) |worker, index| {
        loads[index] = workerEstimatedCostLocked(worker);
        if (loads[index] < loads[source_index]) source_index = index;
    }
    const source = game_workers.items[source_index];
    while (source.lobbies.items.len > 0) {
        const lobby = source.lobbies.items[source.lobbies.items.len - 1];
        const cost = worker_balance.estimatedLobbyCostNs(lobby.balance_ewma_ns, lobby.players.items.len);
        var target_index: ?usize = null;
        for (game_workers.items, 0..) |target, index| {
            if (index == source_index or target.lobbies.items.len >= lobbies_per_worker) continue;
            if (target_index == null or loads[index] < loads[target_index.?]) target_index = index;
        }
        const destination_index = target_index orelse break;
        const destination = game_workers.items[destination_index];
        destination.lobbies.append(galloc, lobby) catch break;
        _ = source.lobbies.pop();
        loads[source_index] -|= cost;
        loads[destination_index] +|= cost;
        lobby.last_migrated_ms = now_ms;
        worker_migrations +%= 1;
    }
    const retired = source.lobbies.items.len == 0;
    unlockAllGameWorkers();
    if (!retired) return false;

    const worker = game_workers.swapRemove(source_index);
    std.debug.assert(worker == source);
    worker.stop.store(true, .release);
    if (worker.thread) |thread| thread.join();
    worker.lobbies.deinit(galloc);
    galloc.destroy(worker);
    return true;
}

fn redistributeGameWorkers(now_ms: i64, aa: Allocator) void {
    if (game_workers.items.len < 2) return;
    const loads = aa.alloc(u64, game_workers.items.len) catch return;
    lockAllGameWorkers();
    var lobby_count: usize = 0;
    for (game_workers.items, 0..) |worker, index| {
        loads[index] = workerEstimatedCostLocked(worker);
        lobby_count += worker.lobbies.items.len;
    }

    var moves_left = lobby_count;
    while (moves_left > 0) : (moves_left -= 1) {
        var heavy_index: usize = 0;
        var light_index: ?usize = null;
        for (game_workers.items, 0..) |worker, index| {
            if (loads[index] > loads[heavy_index]) heavy_index = index;
            if (worker.lobbies.items.len < lobbies_per_worker and
                (light_index == null or loads[index] < loads[light_index.?])) light_index = index;
        }
        const destination_index = light_index orelse break;
        if (destination_index == heavy_index) break;

        const source = game_workers.items[heavy_index];
        var best_lobby_index: ?usize = null;
        var best_cost: u64 = 0;
        var best_improvement: u64 = 0;
        for (source.lobbies.items, 0..) |lobby, index| {
            if (lobby.last_migrated_ms != 0 and now_ms - lobby.last_migrated_ms < worker_balance.migration_cooldown_ms) continue;
            const cost = worker_balance.estimatedLobbyCostNs(lobby.balance_ewma_ns, lobby.players.items.len);
            const improvement = worker_balance.moveImprovementNs(loads[heavy_index], loads[destination_index], cost);
            if (improvement > best_improvement) {
                best_lobby_index = index;
                best_cost = cost;
                best_improvement = improvement;
            }
        }
        const lobby_index = best_lobby_index orelse break;
        if (!worker_balance.worthwhileMove(loads[heavy_index], loads[destination_index], best_cost)) break;

        const lobby = source.lobbies.items[lobby_index];
        const destination = game_workers.items[destination_index];
        destination.lobbies.append(galloc, lobby) catch break;
        _ = source.lobbies.swapRemove(lobby_index);
        loads[heavy_index] -|= best_cost;
        loads[destination_index] +|= best_cost;
        lobby.last_migrated_ms = now_ms;
        worker_migrations +%= 1;
    }
    unlockAllGameWorkers();
}

/// Re-evaluate the pool once per reactor maintenance interval. Expansion is
/// immediate; contraction is deliberately slower to avoid thread churn when a
/// transient expensive tick nudges an EWMA across the budget boundary.
fn rebalanceGameWorkers(now_ms: i64, aa: Allocator) void {
    lockAllGameWorkers();
    var total_cost_ns: u64 = 0;
    var lobby_count: usize = 0;
    for (game_workers.items) |worker| {
        total_cost_ns +|= workerEstimatedCostLocked(worker);
        lobby_count += worker.lobbies.items.len;
    }
    unlockAllGameWorkers();

    const target_ns = worker_balance.targetTickBudgetNs(TICK_NS);
    const desired = worker_balance.desiredWorkerCount(lobby_count, total_cost_ns, lobbies_per_worker, target_ns);
    while (game_workers.items.len < desired) {
        _ = createGameWorker(null) catch break;
        last_worker_resize_ms = now_ms;
    }
    if (game_workers.items.len > desired and now_ms - last_worker_resize_ms >= worker_balance.pool_shrink_cooldown_ms) {
        while (game_workers.items.len > desired) {
            if (!retireLightestGameWorker(now_ms, aa)) break;
            last_worker_resize_ms = now_ms;
        }
    }
    redistributeGameWorkers(now_ms, aa);
}

fn unassignGameWorker(lobby: *Lobby) void {
    if (!lobby.worker_assigned) return;
    var empty_index: ?usize = null;
    for (game_workers.items, 0..) |worker, worker_index| {
        worker.mutex.lockUncancelable(g_io);
        for (worker.lobbies.items, 0..) |candidate, lobby_index| {
            if (candidate == lobby) {
                _ = worker.lobbies.swapRemove(lobby_index);
                if (worker.lobbies.items.len == 0) empty_index = worker_index;
                worker.mutex.unlock(g_io);
                break;
            }
        } else {
            worker.mutex.unlock(g_io);
            continue;
        }
        break;
    }
    lobby.worker_assigned = false;
    if (empty_index) |index| {
        const worker = game_workers.swapRemove(index);
        worker.stop.store(true, .release);
        if (worker.thread) |thread| thread.join();
        worker.lobbies.deinit(galloc);
        galloc.destroy(worker);
    }
}

/// Freeze each worker between ticks and detach lobbies that no longer contain
/// active players or an unfinished death replay. Expired spectators retain
/// text chat membership without spending simulation or binary fan-out work.
/// A later Retry/join assigns a worker again before publishing the player.
fn deactivateEmptyLobbies() void {
    const now = unixMillis();
    var worker_index: usize = 0;
    while (worker_index < game_workers.items.len) {
        const worker = game_workers.items[worker_index];
        worker.mutex.lockUncancelable(g_io);
        var lobby_index: usize = 0;
        while (lobby_index < worker.lobbies.items.len) {
            const lobby = worker.lobbies.items[lobby_index];
            lobby.mutex.lockUncancelable(g_io);
            const inactive = !lobbyNeedsGameWorkerLocked(lobby, now);
            if (inactive) lobby.worker_assigned = false;
            lobby.mutex.unlock(g_io);
            if (inactive) {
                _ = worker.lobbies.swapRemove(lobby_index);
            } else {
                lobby_index += 1;
            }
        }
        const retire = worker.lobbies.items.len == 0;
        worker.mutex.unlock(g_io);

        if (!retire) {
            worker_index += 1;
            continue;
        }
        const removed = game_workers.swapRemove(worker_index);
        std.debug.assert(removed == worker);
        worker.stop.store(true, .release);
        if (worker.thread) |thread| thread.join();
        worker.lobbies.deinit(galloc);
        galloc.destroy(worker);
    }
}

fn destroyLobby(l: *Lobby) void {
    unassignGameWorker(l);
    while (l.spectators.items.len > 0) evictSpectatorLocked(l, l.spectators.items.len - 1);
    l.drops.deinit(galloc);
    l.bonus.deinit(galloc);
    l.remains.deinit(galloc);
    l.spectators.deinit(galloc);
    l.roster_wire.deinit(galloc);
    l.players.deinit(galloc);
    galloc.free(l.id);
    galloc.destroy(l);
}

const PasswordError = error{InvalidPassword};

fn checkedPassword(raw: ?[]const u8) PasswordError![]const u8 {
    const password = raw orelse "";
    if (password.len > MAX_LOBBY_PASSWORD_BYTES or !std.unicode.utf8ValidateSlice(password)) {
        return error.InvalidPassword;
    }
    // Control bytes are surprising in HTML forms and unsafe to copy through
    // logs or diagnostics. Printable ASCII and valid non-ASCII UTF-8 remain
    // otherwise unrestricted; spaces are significant and are not trimmed.
    for (password) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidPassword;
    }
    return password;
}

fn hashPassword(salt: *const [16]u8, password: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(salt);
    hasher.update(password);
    hasher.final(&digest);
    return digest;
}

fn constantTimeDigestEql(left: *const [32]u8, right: *const [32]u8) bool {
    return std.crypto.timing_safe.eql([32]u8, left.*, right.*);
}

fn lobbyAcceptsPassword(l: *const Lobby, supplied: []const u8) bool {
    if (!l.password_protected) return true;
    if (checkedPassword(supplied)) |password| {
        const supplied_hash = hashPassword(&l.password_salt, password);
        return constantTimeDigestEql(&l.password_hash, &supplied_hash);
    } else |_| return false;
}

fn parseGameMode(raw: ?[]const u8, legacy_classical: bool) ?model.GameMode {
    if (raw) |value| {
        if (std.mem.eql(u8, value, "classical")) return .classical;
        if (std.mem.eql(u8, value, "arcade")) return .arcade;
    }
    return if (raw == null) (if (legacy_classical) .classical else .arcade) else null;
}

fn parsePublicTarget(raw: ?[]const u8) ?u8 {
    const value = raw orelse return 0;
    const parsed = std.fmt.parseInt(u8, value, 10) catch return null;
    if (parsed == 0 or (parsed >= 2 and parsed <= binary_snapshot.MAX_PLAYERS)) return parsed;
    return null;
}

fn parseLobbyCapacity(raw: ?[]const u8) ?u8 {
    const value = raw orelse return 16;
    if (value.len == 0 or std.mem.eql(u8, value, "16")) return 16;
    if (std.mem.eql(u8, value, "32")) return 32;
    return null;
}

fn parseWrapWalls(raw: ?[]const u8) ?bool {
    const value = raw orelse return false;
    if (std.mem.eql(u8, value, "solid")) return false;
    if (std.mem.eql(u8, value, "wrap")) return true;
    return null;
}

fn createLobbyLocked(id: []u8, password: []const u8, mode: model.GameMode, public_target: u8, wrap_walls: bool, requested_capacity: u8) !*Lobby {
    const l = try galloc.create(Lobby);
    errdefer galloc.destroy(l);
    const seed = rng_prng.random().int(u64);
    var password_salt: [16]u8 = undefined;
    rng_prng.random().bytes(&password_salt);
    const lobby_capacity: u8 = @intCast(@min(@as(usize, requested_capacity), max_players_per_lobby));
    l.* = .{
        .id = id,
        .password_salt = password_salt,
        .password_hash = if (password.len == 0) @splat(0) else hashPassword(&password_salt, password),
        .password_protected = password.len != 0,
        .public_target = if (password.len == 0) @min(public_target, lobby_capacity) else 0,
        .max_players = lobby_capacity,
        .mode = mode,
        .wrap_walls = wrap_walls,
        .food = undefined,
    };
    l.rng = std.Random.DefaultPrng.init(seed);
    errdefer l.remains.deinit(galloc);
    errdefer l.spectators.deinit(galloc);
    // These are hard protocol/lifecycle caps. Reserving once keeps death,
    // boost shedding, and spectator retention allocation-free in game ticks.
    try l.remains.ensureTotalCapacityPrecise(galloc, model.MAX_REMAINS);
    try l.spectators.ensureTotalCapacityPrecise(galloc, model.MAX_SPECTATORS);
    l.food = randomObjectiveCell(l);
    try lobbies.put(galloc, id, l);
    return l;
}

fn quickJoinEligibleLocked(l: *const Lobby) bool {
    if (l.password_protected or l.public_target < 2) return false;
    const target = @min(@as(usize, l.public_target), @as(usize, l.max_players));
    return l.players.items.len < target;
}

/// Reactor-owned, race-tolerant matchmaking hint. No unauthenticated HTTP
/// request reserves a seat: WebSocket join validation and the retained-member
/// hard cap remain authoritative.
fn selectQuickJoinLobby() ?*Lobby {
    if (!serverHasRetainedCapacity()) return null;
    var best: ?*Lobby = null;
    var best_players: usize = 0;
    for (lobbies.values()) |l| {
        l.mutex.lockUncancelable(g_io);
        const players = l.players.items.len;
        const eligible = quickJoinEligibleLocked(l);
        l.mutex.unlock(g_io);
        if (!eligible) continue;
        if (best == null or players > best_players) {
            best = l;
            best_players = players;
        }
    }
    const chosen = best orelse return null;
    chosen.mutex.lockUncancelable(g_io);
    defer chosen.mutex.unlock(g_io);
    if (!quickJoinEligibleLocked(chosen)) return null;
    chosen.last_empty_at = 0;
    return chosen;
}

fn feedDeath(l: *Lobby, p: *Player, killer: ?*Player, bounty_points: i64, aa: Allocator) void {
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"type\":\"death\",\"id\":") catch return;
    jsString(&args, aa, p.id) catch return;
    args.appendSlice(aa, ",\"who\":") catch return;
    jsString(&args, aa, p.name) catch return;
    args.appendSlice(aa, ",\"score\":") catch return;
    jnum(&args, aa, p.score) catch return;
    if (killer) |credited| {
        args.appendSlice(aa, ",\"killerId\":") catch return;
        jsString(&args, aa, credited.id) catch return;
        args.appendSlice(aa, ",\"killer\":") catch return;
        jsString(&args, aa, credited.name) catch return;
        pf(&args, aa, ",\"streak\":{d},\"bounty\":{d}", .{ credited.streak, bounty_points }) catch return;
    }
    args.appendSlice(aa, "}") catch return;
    const frame = eventFrame(aa, "feed", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

fn sendDeathEvent(c: *Conn, score: i64, focus: CellPos, aa: Allocator) void {
    var args: Buf = .empty;
    defer args.deinit(aa);
    pf(&args, aa, ",{{\"score\":{d},\"focus\":{{\"x\":{d},\"y\":{d}}},\"spectateMs\":{d}}}", .{
        score,
        focus.x,
        focus.y,
        SPECTATE_FOCUS_MS,
    }) catch return;
    const frame = eventFrame(aa, "death", args.items) catch return;
    defer aa.free(frame);
    connEnqueueText(c, frame);
}

fn sendGameError(c: *Conn, msg: []const u8, aa: Allocator) void {
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.append(aa, ',') catch return;
    jsString(&args, aa, msg) catch return;
    const frame = eventFrame(aa, "game_error", args.items) catch return;
    defer aa.free(frame);
    connEnqueueText(c, frame);
}

fn broadcastUpdateFood(l: *Lobby, aa: Allocator) void {
    var args: Buf = .empty;
    defer args.deinit(aa);
    pf(&args, aa, ",{{\"x\":{d},\"y\":{d}}}", .{ l.food.x, l.food.y }) catch return;
    const frame = eventFrame(aa, "updateFood", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

fn broadcastGoldenFeed(l: *Lobby, p: *Player, aa: Allocator) void {
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"type\":\"golden\",\"id\":") catch return;
    jsString(&args, aa, p.id) catch return;
    args.appendSlice(aa, ",\"who\":") catch return;
    jsString(&args, aa, p.name) catch return;
    pf(&args, aa, ",\"points\":{d}}}", .{GOLDEN_POINTS}) catch return;
    const frame = eventFrame(aa, "feed", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

// ------------------------------------------------------------------ joining

/// Build all persistent player state before a lazy worker is acquired. The
/// caller holds the lobby mutex so spawn selection and lobby RNG use are safe.
fn createPlayerLocked(c: *Conn, target: *Lobby, username: []const u8, aa: Allocator) !*Player {
    const p = try galloc.create(Player);
    errdefer galloc.destroy(p);
    p.* = .{
        .id = c.sidSlice(),
        .name = undefined,
        .color_hex = undefined,
        .conn = c,
    };
    p.name = try galloc.dupe(u8, username);
    errdefer galloc.free(p.name);
    _ = aa;
    p.color_hex = try galloc.dupe(u8, choosePlayerColor(target));
    errdefer galloc.free(p.color_hex);
    try p.snake.append(galloc, pickSpawnCell(target) orelse return error.NoSafeSpawn);
    return p;
}

/// Return the retained identity only while the connection is still a spectator
/// in this lobby. The caller holds the lobby mutex before taking membership,
/// preserving the global lobby -> membership lock order.
fn retainedSpectatorLocked(target: *const Lobby, c: *Conn) ?*Player {
    if (spectatorIndex(target, c) == null) return null;
    c.membership_mutex.lockUncancelable(g_io);
    defer c.membership_mutex.unlock(g_io);
    if (c.lobby != target or c.spectate_focus == null) return null;
    return c.player;
}

/// Publish an already prepared player without exposing a half-converted Retry.
/// Appending can fail, but it happens before the old spectator is removed. Once
/// append succeeds, every remaining operation is allocation-free.
fn publishPreparedPlayerLocked(target: *Lobby, c: *Conn, player: *Player, retained: ?*Player) !bool {
    const spectator_index = if (retained) |old_player| blk: {
        const index = spectatorIndex(target, c) orelse return false;
        c.membership_mutex.lockUncancelable(g_io);
        const matches = c.lobby == target and c.player == old_player and c.spectate_focus != null;
        c.membership_mutex.unlock(g_io);
        if (!matches) return false;
        break :blk index;
    } else blk: {
        c.membership_mutex.lockUncancelable(g_io);
        const empty = c.player == null and c.lobby == null;
        c.membership_mutex.unlock(g_io);
        if (!empty) return false;
        break :blk null;
    };

    // This is the only remaining fallible operation. Membership is untouched
    // if it fails, so the caller can destroy the unpublished replacement.
    try target.players.append(galloc, player);

    if (retained) |old_player| {
        c.membership_mutex.lockUncancelable(g_io);
        std.debug.assert(c.lobby == target and c.player == old_player and c.spectate_focus != null);
        const index = spectator_index.?;
        _ = target.spectators.orderedRemove(index);
        c.player = player;
        c.lobby = target;
        c.spectating_until = 0;
        c.spectate_focus = null;
        c.spectate_score = 0;
        c.membership_mutex.unlock(g_io);
        destroyPlayer(old_player);
        // A Retry converts one retained identity in place. It consumes active
        // capacity, but not another slot in the authoritative global member cap.
        _ = total_players.fetchAdd(1, .acq_rel);
        return true;
    }

    c.membership_mutex.lockUncancelable(g_io);
    std.debug.assert(c.player == null and c.lobby == null);
    c.player = player;
    c.lobby = target;
    c.membership_mutex.unlock(g_io);
    _ = total_players.fetchAdd(1, .acq_rel);
    _ = total_lobby_members.fetchAdd(1, .acq_rel);
    return true;
}

/// Caller holds the lobby mutex. A worker acquired only for this unpublished
/// join must be released outside that mutex to preserve worker -> lobby order.
fn discardPreparedPlayerLocked(target: *Lobby, player: *Player, activated_worker: bool) void {
    destroyPlayer(player);
    if (!activated_worker) return;
    target.mutex.unlock(g_io);
    unassignGameWorker(target);
    target.mutex.lockUncancelable(g_io);
}

fn handleClientReady(c: *Conn, aa: Allocator, username_arg: ?[]const u8, lobby_arg: ?[]const u8, password: []const u8) void {
    // Active players cannot use another join packet to teleport or duplicate
    // membership. A spectator is retained until the replacement is completely
    // prepared, so validation or resource failures never throw them out of chat.
    c.membership_mutex.lockUncancelable(g_io);
    const existing_player = c.player;
    const existing_lobby = c.lobby;
    const active_membership = existing_player != null and c.spectate_focus == null;
    c.membership_mutex.unlock(g_io);
    if (active_membership) return;

    const bad_user = text.UsernameCheck{ .ok = false, .trimmed = "" };
    const chk = if (username_arg) |u| checkUsername(u) else bad_user;
    if (!chk.ok) {
        sendGameError(c, ERR_INVALID_USERNAME, aa);
        return;
    }
    const lobby = if (lobby_arg) |lid| lobbies.get(lid) else null;
    // Authentication failures deliberately share the unknown-lobby response:
    // neither HTTP nor WebSocket joins disclose whether an id is protected.
    if (lobby == null or !lobbyAcceptsPassword(lobby.?, password)) {
        sendGameError(c, ERR_UNKNOWN_GAME, aa);
        return;
    }
    const target = lobby.?;
    // Retry is an in-place conversion, not a cross-lobby move. Keeping this
    // invariant means one lobby mutex is sufficient for the atomic replacement
    // and a malformed join cannot strand the dead user's chat membership.
    const retrying = existing_player != null;
    if (retrying and existing_lobby != target) {
        sendGameError(c, ERR_UNKNOWN_GAME, aa);
        return;
    }
    if (!retrying and !serverHasRetainedCapacity()) {
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    }
    target.mutex.lockUncancelable(g_io);

    // Recheck under the lobby ownership lock. This serializes joins with the
    // lobby worker and with disconnect/death cleanup.
    c.membership_mutex.lockUncancelable(g_io);
    const current_player = c.player;
    const current_lobby = c.lobby;
    const currently_spectating = c.spectate_focus != null;
    c.membership_mutex.unlock(g_io);
    const retained = if (retrying and current_player == existing_player and current_lobby == target and currently_spectating)
        retainedSpectatorLocked(target, c)
    else
        null;
    if ((retrying and retained == null) or (!retrying and current_player != null)) {
        target.mutex.unlock(g_io);
        return;
    }
    if (!retrying and !serverHasRetainedCapacity()) {
        target.mutex.unlock(g_io);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    }
    if (target.players.items.len >= target.max_players) {
        target.mutex.unlock(g_io);
        sendGameError(c, ERR_LOBBY_FULL, aa);
        return;
    }

    const p = createPlayerLocked(c, target, chk.trimmed, aa) catch |err| {
        target.mutex.unlock(g_io);
        sendGameError(c, if (err == error.NoSafeSpawn) ERR_LOBBY_FULL else ERR_SERVER_FULL, aa);
        return;
    };

    // Worker locks precede lobby locks everywhere else. Release the lobby
    // while assigning its first worker, after every persistent allocation has
    // succeeded, then reacquire it before publishing membership.
    const activated_worker = !target.worker_assigned;
    if (activated_worker) {
        target.mutex.unlock(g_io);
        assignGameWorker(target) catch {
            destroyPlayer(p);
            sendGameError(c, ERR_SERVER_FULL, aa);
            return;
        };
        target.mutex.lockUncancelable(g_io);
    }
    defer target.mutex.unlock(g_io);

    var init_args: Buf = .empty;
    defer init_args.deinit(aa);
    init_args.appendSlice(aa, ",{\"scale\":16,\"food\":{") catch {
        discardPreparedPlayerLocked(target, p, activated_worker);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    };
    pf(&init_args, aa, "\"x\":{d},\"y\":{d}}},\"mode\":", .{ target.food.x, target.food.y }) catch {
        discardPreparedPlayerLocked(target, p, activated_worker);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    };
    jsString(&init_args, aa, target.mode.wireName()) catch {
        discardPreparedPlayerLocked(target, p, activated_worker);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    };
    pf(&init_args, aa, ",\"classical\":{},\"walls\":\"{s}\",\"wrapWalls\":{},\"capacity\":{d}}}", .{
        target.mode.isClassical(),
        if (target.wrap_walls) "wrap" else "solid",
        target.wrap_walls,
        target.max_players,
    }) catch {
        discardPreparedPlayerLocked(target, p, activated_worker);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    };
    const init_frame = eventFrame(aa, "init", init_args.items) catch {
        discardPreparedPlayerLocked(target, p, activated_worker);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    };
    defer aa.free(init_frame);

    const published = publishPreparedPlayerLocked(target, c, p, retained) catch {
        discardPreparedPlayerLocked(target, p, activated_worker);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    };
    if (!published) {
        discardPreparedPlayerLocked(target, p, activated_worker);
        return;
    }
    target.roster_dirty = true;
    target.last_empty_at = 0;

    // init goes to the joining socket only and remains ordered before the join
    // feed. Its frame was prepared before membership became externally visible.
    connEnqueueText(c, init_frame);

    // feed join to everyone in the room (including the joiner).
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"type\":\"join\",\"id\":") catch return;
    jsString(&args, aa, p.id) catch return;
    args.appendSlice(aa, ",\"who\":") catch return;
    jsString(&args, aa, p.name) catch return;
    args.appendSlice(aa, "}") catch return;
    const frame = eventFrame(aa, "feed", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(target, frame);
}

fn handleKeyPress(c: *Conn, d: Direction) void {
    c.membership_mutex.lockUncancelable(g_io);
    const lobby = c.lobby;
    c.membership_mutex.unlock(g_io);
    const l = lobby orelse return;

    l.mutex.lockUncancelable(g_io);
    defer l.mutex.unlock(g_io);
    if (spectatorIndex(l, c) != null) return;
    // Every cross-thread membership write also holds this lobby mutex. Joins
    // run only on this reactor thread, so no other writer can move the
    // connection to a different lobby while this handler is running.
    const player = if (c.lobby == l) c.player else null;
    if (player) |p| _ = p.pushTurn(d);
}

fn handleVisibility(c: *Conn, visible: bool) void {
    const was_hidden = c.snapshot_hidden.load(.acquire);
    if (visible) {
        // A background client deliberately misses dependent deltas. Mark it
        // before publishing foreground visibility so the lobby worker cannot
        // observe the foreground state without also seeing the resync flag.
        if (was_hidden) c.snapshot_needs_keyframe.store(true, .release);
        c.snapshot_hidden.store(false, .release);
    } else {
        // Make the first background keyframe immediate; subsequent delivery is
        // bounded by BACKGROUND_SNAPSHOT_MS. Publish the deadline first so a
        // lobby worker that sees the hidden state also sees the reset.
        if (!was_hidden) c.next_background_snapshot_ms.store(0, .release);
        c.snapshot_hidden.store(true, .release);
        // Treat a hidden document like key release. The server does not trust
        // the browser to send a later Space-up packet before simulation runs.
        handleBoost(c, false);
    }
}

fn handleBoost(c: *Conn, held: bool) void {
    c.membership_mutex.lockUncancelable(g_io);
    const lobby = c.lobby;
    c.membership_mutex.unlock(g_io);
    const l = lobby orelse return;
    l.mutex.lockUncancelable(g_io);
    defer l.mutex.unlock(g_io);
    if (!l.mode.isArcade() or spectatorIndex(l, c) != null) return;
    const player = if (c.lobby == l) c.player else null;
    if (player) |p| {
        p.boosting = held;
        if (!held) p.boost_substep = false;
    }
}

fn refillChatBucket(tokens: *u8, last_refill_ms: *i64, now: i64, capacity: u8, refill_ms: i64) void {
    if (last_refill_ms.* == 0) {
        last_refill_ms.* = now;
        return;
    }
    if (now <= last_refill_ms.*) return;
    const periods = @divTrunc(now - last_refill_ms.*, refill_ms);
    if (periods == 0) return;
    const refill: u8 = @intCast(@min(@as(i64, capacity), periods));
    tokens.* = @min(capacity, tokens.* +| refill);
    // Advance across every elapsed period, not merely the capacity-capped
    // refill. Otherwise repeated packets at one timestamp could spend the
    // same long idle interval more than once.
    last_refill_ms.* += periods * refill_ms;
}

/// Both buckets are refilled and checked before either is consumed. A message
/// denied by the room ceiling therefore does not silently spend the sender's
/// personal allowance. The caller holds the lobby mutex.
fn consumeChatToken(c: *Conn, l: *Lobby, now: i64) bool {
    refillChatBucket(&c.chat_tokens, &c.chat_last_refill_ms, now, model.CHAT_TOKEN_CAPACITY, model.CHAT_REFILL_MS);
    refillChatBucket(&l.chat_tokens, &l.chat_last_refill_ms, now, model.LOBBY_CHAT_TOKEN_CAPACITY, model.LOBBY_CHAT_REFILL_MS);
    if (c.chat_tokens == 0 or l.chat_tokens == 0) return false;
    c.chat_tokens -= 1;
    l.chat_tokens -= 1;
    return true;
}

fn handleChat(c: *Conn, message: []const u8, aa: Allocator) void {
    c.membership_mutex.lockUncancelable(g_io);
    const lobby = c.lobby;
    c.membership_mutex.unlock(g_io);
    const l = lobby orelse return;
    l.mutex.lockUncancelable(g_io);
    defer l.mutex.unlock(g_io);
    const player = if (c.lobby == l) c.player else null;
    const p = player orelse return;
    if (!consumeChatToken(c, l, unixMillis())) return;

    var args: Buf = .empty;
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"id\":") catch return;
    jsString(&args, aa, p.id) catch return;
    args.appendSlice(aa, ",\"who\":") catch return;
    jsString(&args, aa, p.name) catch return;
    args.appendSlice(aa, ",\"color\":") catch return;
    jsString(&args, aa, p.color_hex) catch return;
    args.appendSlice(aa, ",\"text\":") catch return;
    jsString(&args, aa, message) catch return;
    args.append(aa, '}') catch return;
    const frame = eventFrame(aa, "chat", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

// ------------------------------------------------------------------ tick helpers

fn respawnFood(l: *Lobby) void {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        l.food = randomObjectiveCell(l);
        if (!snakeOccupies(l, l.food)) return;
    }
}

fn spawnDropLocked(l: *Lobby, now: i64, aa: Allocator) void {
    const cell = randomFreeCell(l) orelse return;
    l.drops.append(galloc, .{ .pos = cell, .expires_at = now + DROP_TTL_MS }) catch return;
    const frame = eventFrame(aa, "feed", ",{\"type\":\"drop-incoming\"}") catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

fn spawnGoldenLocked(l: *Lobby, now: i64) void {
    const cell = randomFreeCell(l) orelse return;
    l.golden = .{ .pos = cell, .expires_at = now + GOLDEN_TTL_MS };
}

fn openDropLocked(l: *Lobby, p: *Player, aa: Allocator) void {
    p.eat(DROP_POINTS, DROP_GROWTH);
    var spawned: usize = 0;
    while (spawned < DROP_APPLES and l.bonus.items.len < BONUS_CAP) {
        const cell = randomFreeCell(l) orelse break;
        l.bonus.append(galloc, .{ .pos = cell }) catch break;
        spawned += 1;
    }
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"type\":\"drop-open\",\"id\":") catch return;
    jsString(&args, aa, p.id) catch return;
    args.appendSlice(aa, ",\"who\":") catch return;
    jsString(&args, aa, p.name) catch return;
    pf(&args, aa, ",\"apples\":{d}}}", .{spawned}) catch return;
    const frame = eventFrame(aa, "feed", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

/// Identity metadata is sent only when membership changes. Snapshot player
/// rows retain this insertion order and therefore need no repeated ids.
fn buildRoster(l: *Lobby) ![]const u8 {
    l.roster_wire.clearRetainingCapacity();
    try l.roster_wire.appendSlice(galloc, "[\"r\",[");
    for (l.players.items, 0..) |player, index| {
        if (index != 0) try l.roster_wire.append(galloc, ',');
        try l.roster_wire.append(galloc, '[');
        try jsString(&l.roster_wire, galloc, player.id);
        try l.roster_wire.append(galloc, ',');
        try jsString(&l.roster_wire, galloc, player.name);
        try l.roster_wire.append(galloc, ',');
        try jsString(&l.roster_wire, galloc, player.color_hex);
        try l.roster_wire.append(galloc, ']');
    }
    try l.roster_wire.appendSlice(galloc, "]]\n");
    return l.roster_wire.items[0 .. l.roster_wire.items.len - 1];
}

fn applyMoveAndCheckWall(l: *const Lobby, player: *Player, slot: usize, collision_index: *collision.Index) bool {
    const before_move = collision.BeforeMove.capture(player);
    player.applyMove(galloc);
    if (l.wrap_walls) wrapPlayerHead(player);
    collision_index.afterMove(slot, player, before_move);
    return !l.wrap_walls and collidedWall(player.snake.items[0]);
}

/// Resolve collisions from one immutable tick-start position set. A snake
/// dies when its own head occupies a wall, itself, or any cell of another
/// snake. The owner of a body that was hit is not killed merely for being hit.
/// Because every head is classified before anyone is removed, head-to-head
/// and mutual body crossings still kill every attacker without insertion-order
/// bias.
fn startingCollisionDeaths(players: []const *Player, collision_index: *const collision.Index) [binary_snapshot.MAX_PLAYERS]bool {
    var deaths = [_]bool{false} ** binary_snapshot.MAX_PLAYERS;
    for (players, 0..) |player, slot| {
        const head = player.snake.items[0];
        deaths[slot] = collidedWall(head) or collision_index.selfHit(slot, player) or
            collision_index.otherAt(slot, player) != null;
    }
    return deaths;
}

inline fn sameCell(left: CellPos, right: CellPos) bool {
    return left.x == right.x and left.y == right.y;
}

fn remnantCellAvailable(l: *const Lobby, cell: CellPos) bool {
    if (!objectiveCellSafe(cell) or sameCell(l.food, cell)) return false;
    for (l.bonus.items) |bonus| if (sameCell(bonus.pos, cell)) return false;
    for (l.drops.items) |drop| if (sameCell(drop.pos, cell)) return false;
    if (l.golden) |golden| if (sameCell(golden.pos, cell)) return false;
    for (l.remains.items) |remain| if (sameCell(remain.pos, cell)) return false;
    return true;
}

fn appendRemnantLocked(l: *Lobby, cell: CellPos, now: i64) void {
    if (l.remains.items.len >= model.MAX_REMAINS or !remnantCellAvailable(l, cell)) return;
    const ttl = if (l.feast_until > now) FEAST_REMAINS_TTL_MS else REMAINS_TTL_MS;
    l.remains.append(galloc, .{ .pos = cell, .expires_at = now + ttl }) catch {};
}

fn spawnCorpseRemainsLocked(l: *Lobby, p: *const Player, now: i64) void {
    if (!l.mode.isArcade() or p.snake.items.len <= 1 or l.remains.items.len >= model.MAX_REMAINS) return;
    const body_len = p.snake.items.len - 1;
    const adaptive = body_len / CORPSE_REMAINS_MAX;
    const stride = @max(@as(usize, 3), adaptive);
    var emitted: usize = 0;
    var index: usize = 1;
    while (index < p.snake.items.len and emitted < CORPSE_REMAINS_MAX and l.remains.items.len < model.MAX_REMAINS) : (index += stride) {
        const before = l.remains.items.len;
        appendRemnantLocked(l, p.snake.items[index], now);
        if (l.remains.items.len != before) emitted += 1;
    }
}

fn expireArcadeLocked(l: *Lobby, now: i64) void {
    var index: usize = 0;
    while (index < l.remains.items.len) {
        if (l.remains.items[index].expires_at <= now) {
            _ = l.remains.swapRemove(index);
        } else index += 1;
    }
}

fn broadcastFeastLocked(l: *Lobby, aa: Allocator) void {
    const frame = eventFrame(aa, "feed", ",{\"type\":\"feast\"}") catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

fn scheduleFeastLocked(l: *Lobby, now: i64, aa: Allocator) void {
    if (l.next_feast_at == 0) {
        l.next_feast_at = now + 60_000 + l.rng.random().intRangeLessThan(i64, 0, 30_001);
        return;
    }
    if (now < l.next_feast_at) return;
    l.feast_until = now + FEAST_DURATION_MS;
    l.next_feast_at = l.feast_until + 75_000 + l.rng.random().intRangeLessThan(i64, 0, 30_001);
    const cap = now + FEAST_REMAINS_TTL_MS;
    for (l.remains.items) |*remain|
        remain.expires_at = @min(cap, remain.expires_at + 10_000);
    broadcastFeastLocked(l, aa);
}

fn collectAtHeadLocked(l: *Lobby, p: *Player, aa: Allocator) void {
    const head = p.snake.items[0];
    if (sameCell(head, l.food)) {
        p.eat(1, 1);
        respawnFood(l);
        broadcastUpdateFood(l, aa);
    }

    var bi = l.bonus.items.len;
    while (bi > 0) {
        bi -= 1;
        if (sameCell(head, l.bonus.items[bi].pos)) {
            _ = l.bonus.swapRemove(bi);
            p.eat(1, 1);
        }
    }
    if (l.golden) |golden| {
        if (sameCell(head, golden.pos)) {
            l.golden = null;
            p.eat(GOLDEN_POINTS, 1);
            broadcastGoldenFeed(l, p, aa);
        }
    }
    var di = l.drops.items.len;
    while (di > 0) {
        di -= 1;
        if (sameCell(head, l.drops.items[di].pos)) {
            _ = l.drops.swapRemove(di);
            openDropLocked(l, p, aa);
        }
    }

    var ri = l.remains.items.len;
    while (ri > 0) {
        ri -= 1;
        if (!sameCell(head, l.remains.items[ri].pos)) continue;
        _ = l.remains.swapRemove(ri);
        if (p.mass_progress == config.REMAINS_PER_GROWTH - 1) {
            p.mass_progress = 0;
            p.eat(1, 1);
        } else {
            p.mass_progress += 1;
        }
    }
}

fn currentBounty(l: *Lobby) ?*Player {
    if (l.players.items.len < 2) return null;
    var best: ?*Player = null;
    var tied = false;
    for (l.players.items) |player| {
        if (player.score < BOUNTY_MIN_SCORE) continue;
        if (best == null or player.score > best.?.score) {
            best = player;
            tied = false;
        } else if (player.score == best.?.score) tied = true;
    }
    return if (tied) null else best;
}

fn updateBountySlot(l: *Lobby) void {
    l.bounty_slot = null;
    const target = currentBounty(l) orelse return;
    for (l.players.items, 0..) |player, slot| {
        if (player == target) {
            l.bounty_slot = @intCast(slot);
            return;
        }
    }
}

const DeathResolution = struct {
    dead: bool = false,
    killer_slot: ?usize = null,
};

/// Attribution is deliberately stricter than collision death. Only one
/// opponent's non-head body can earn credit; head overlap, self collision,
/// walls, and multiple body owners all produce an unattributed death.
fn classifyDeaths(players: []const *Player) [binary_snapshot.MAX_PLAYERS]DeathResolution {
    var result = [_]DeathResolution{.{}} ** binary_snapshot.MAX_PLAYERS;
    for (players, 0..) |player, slot| {
        const head = player.snake.items[0];
        const wall = collidedWall(head);
        const self = collision.scanSelf(player);
        var opposing_head = false;
        var ambiguous = false;
        var body_owner: ?usize = null;
        var hit_other = false;
        for (players, 0..) |other, other_slot| {
            if (slot == other_slot) continue;
            if (sameCell(head, other.snake.items[0])) {
                hit_other = true;
                opposing_head = true;
            }
            for (other.snake.items[1..]) |segment| {
                if (!sameCell(head, segment)) continue;
                hit_other = true;
                if (body_owner) |known| {
                    if (known != other_slot) ambiguous = true;
                } else body_owner = other_slot;
                break;
            }
        }
        result[slot].dead = wall or self or hit_other;
        if (!wall and !self and !opposing_head and !ambiguous and body_owner != null)
            result[slot].killer_slot = body_owner;
    }
    return result;
}

fn bountyPayout(victim: *const Player, killer: *const Player) i64 {
    const gap = @max(@as(i64, 0), victim.score - killer.score);
    return std.math.clamp(@as(i64, 1) + @divTrunc(gap, 5), 1, 5);
}

fn recordCreditedKill(killer: *Player, now: i64) void {
    killer.kills +|= 1;
    if (killer.last_kill_at == 0 or now - killer.last_kill_at > KILL_STREAK_WINDOW_MS)
        killer.streak = 0;
    killer.streak +|= 1;
    killer.last_kill_at = now;
}

fn eliminateResolvedLocked(l: *Lobby, players: []const *Player, deaths: *const [binary_snapshot.MAX_PLAYERS]DeathResolution, bounty: ?*Player, now: i64, aa: Allocator) bool {
    var any = false;
    var bounty_awards = [_]i64{0} ** binary_snapshot.MAX_PLAYERS;
    for (players, 0..) |victim, slot| {
        if (!deaths[slot].dead) continue;
        any = true;
        if (deaths[slot].killer_slot) |killer_slot| {
            const killer = players[killer_slot];
            recordCreditedKill(killer, now);
            if (bounty == victim) {
                bounty_awards[slot] = bountyPayout(victim, killer);
                killer.score +|= bounty_awards[slot];
            }
        }
    }
    if (!any) return false;

    for (players, 0..) |victim, slot| {
        if (!deaths[slot].dead) continue;
        const focus = victim.snake.items[0];
        const score = victim.score;
        const killer = if (deaths[slot].killer_slot) |killer_slot| players[killer_slot] else null;
        spawnCorpseRemainsLocked(l, victim, now);
        sendDeathEvent(victim.conn, score, focus, aa);
        feedDeath(l, victim, killer, bounty_awards[slot], aa);
        movePlayerToSpectatorsLocked(l, victim, focus, score, now);
    }
    return true;
}

fn resolveCurrentArcadeDeathsLocked(l: *Lobby, bounty: ?*Player, now: i64, aa: Allocator) bool {
    if (l.players.items.len == 0) return false;
    var storage: [binary_snapshot.MAX_PLAYERS]*Player = undefined;
    const count = l.players.items.len;
    @memcpy(storage[0..count], l.players.items);
    const players = storage[0..count];
    const deaths = classifyDeaths(players);
    return eliminateResolvedLocked(l, players, &deaths, bounty, now, aa);
}

fn arcadeBoostEligibleLocked(l: *Lobby, p: *Player, now: i64) bool {
    if (!p.boosting) {
        p.boost_substep = false;
        return false;
    }
    p.boost_cost_ticks +|= 1;
    if (p.boost_cost_ticks >= BOOST_COST_TICKS) {
        if (p.pending_growth > 0) {
            p.pending_growth -= 1;
        } else if (p.shedTail(BOOST_MIN_CELLS)) |tail| {
            appendRemnantLocked(l, tail, now);
        } else {
            p.boost_cost_ticks = BOOST_COST_TICKS - 1;
            return false;
        }
        p.boost_cost_ticks = 0;
    }
    p.boost_substep = !p.boost_substep;
    return !p.boost_substep;
}

fn simulateArcadeLocked(l: *Lobby, now: i64, aa: Allocator) void {
    const bounty = currentBounty(l);
    _ = resolveCurrentArcadeDeathsLocked(l, bounty, now, aa);

    for (l.players.items) |player| collectAtHeadLocked(l, player, aa);
    for (l.players.items) |player| {
        player.applyMove(galloc);
        if (l.wrap_walls) wrapPlayerHead(player);
    }
    _ = resolveCurrentArcadeDeathsLocked(l, bounty, now, aa);

    var extra: [binary_snapshot.MAX_PLAYERS]*Player = undefined;
    var extra_len: usize = 0;
    for (l.players.items) |player| {
        if (arcadeBoostEligibleLocked(l, player, now)) {
            extra[extra_len] = player;
            extra_len += 1;
        }
    }
    for (extra[0..extra_len]) |player| {
        // A simultaneous normal-step collision may have removed this player.
        if (player.snake.items.len == 0) continue;
        collectAtHeadLocked(l, player, aa);
        player.applyMove(galloc);
        if (l.wrap_walls) wrapPlayerHead(player);
    }
    _ = resolveCurrentArcadeDeathsLocked(l, bounty, now, aa);
    updateBountySlot(l);
}

// ------------------------------------------------------------------ tick

fn tickLobby(l: *Lobby, now: i64, aa: Allocator) void {
    const t0 = monoNanos();

    // Classical lobbies contain only main food, so their hot path skips all
    // special-pickup expiry and scheduling work as well as their game rules.
    if (l.mode.isArcade()) {
        // 1. expire pickups past their TTL
        var di: usize = 0;
        while (di < l.drops.items.len) {
            if (l.drops.items[di].expires_at <= now) {
                _ = l.drops.orderedRemove(di);
            } else di += 1;
        }
        if (l.golden) |g| {
            if (g.expires_at <= now) l.golden = null;
        }
        // 2. schedules: first drop ~8s, first golden ~20s, then 12-20s / 25-40s
        if (l.next_drop_at == 0) l.next_drop_at = now + 8000;
        if (l.next_golden_at == 0) l.next_golden_at = now + 20000;
        if (now >= l.next_drop_at and l.drops.items.len < DROP_MAX) {
            spawnDropLocked(l, now, aa);
            l.next_drop_at = now + 12000 + l.rng.random().intRangeLessThan(i64, 0, 8000);
        }
        if (now >= l.next_golden_at and l.golden == null) {
            spawnGoldenLocked(l, now);
            l.next_golden_at = now + 25000 + l.rng.random().intRangeLessThan(i64, 0, 15000);
        }
    }

    if (l.mode.isArcade()) {
        expireArcadeLocked(l, now);
        scheduleFeastLocked(l, now, aa);
        simulateArcadeLocked(l, now, aa);
    } else {
        // Classical retains its established single-step order:
        // collision at tick start, pickup at the current head, then movement.
        // The only lifecycle change is retaining the eliminated connection as
        // a spectator so Game Over can keep receiving snapshots and chat.
        const player_count = l.players.items.len;
        if (player_count > binary_snapshot.MAX_PLAYERS) return;
        var snapshot_storage: [binary_snapshot.MAX_PLAYERS]*Player = undefined;
        @memcpy(snapshot_storage[0..player_count], l.players.items);
        const snapshot = snapshot_storage[0..player_count];
        var collision_index = collision.Index.build(snapshot);
        const starting_deaths = startingCollisionDeaths(snapshot, &collision_index);

        for (snapshot, 0..) |p, slot| {
            if (!collision_index.isActive(slot)) continue;
            if (starting_deaths[slot]) {
                const focus = p.snake.items[0];
                sendDeathEvent(p.conn, p.score, focus, aa);
                feedDeath(l, p, null, 0, aa);
                collision_index.remove(slot, p);
                movePlayerToSpectatorsLocked(l, p, focus, p.score, now);
                continue;
            }

            const head = p.snake.items[0];
            if (sameCell(head, l.food)) {
                p.eat(1, 1);
                respawnFood(l);
                broadcastUpdateFood(l, aa);
            }
            if (l.mode.isArcade()) {
                var bi = l.bonus.items.len;
                while (bi > 0) {
                    bi -= 1;
                    if (sameCell(head, l.bonus.items[bi].pos)) {
                        _ = l.bonus.swapRemove(bi);
                        p.eat(1, 1);
                    }
                }
                if (l.golden) |golden| {
                    if (sameCell(head, golden.pos)) {
                        l.golden = null;
                        p.eat(GOLDEN_POINTS, 1);
                        broadcastGoldenFeed(l, p, aa);
                    }
                }
                var di = l.drops.items.len;
                while (di > 0) {
                    di -= 1;
                    if (sameCell(head, l.drops.items[di].pos)) {
                        _ = l.drops.swapRemove(di);
                        openDropLocked(l, p, aa);
                    }
                }
            }

            if (applyMoveAndCheckWall(l, p, slot, &collision_index)) {
                const focus = p.snake.items[0];
                sendDeathEvent(p.conn, p.score, focus, aa);
                feedDeath(l, p, null, 0, aa);
                collision_index.remove(slot, p);
                movePlayerToSpectatorsLocked(l, p, focus, p.score, now);
            }
        }
    }

    // 5. broadcast membership metadata only when it changed, followed by the
    // compact world snapshot. Ordered websocket delivery keeps them aligned.
    const serialize_t0 = monoNanos();
    l.stats.encode_ns = 0;
    l.stats.fanout_ns = 0;
    if (l.roster_dirty) {
        binary_snapshot.invalidate(l);
        if (buildRoster(l)) |frame| {
            broadcastLobby(l, frame);
            l.roster_dirty = false;
        } else |_| {}
    }
    if (acquireSharedFrame()) |frame| {
        const encode_t0 = if (debug_enabled) monoNanos() else 0;
        if (binary_snapshot.buildInto(&frame.payload, l, now, galloc)) |result| {
            frame.keyframe = result.kind == .keyframe;
            frame.header_len = @intCast(wsHeader(&frame.header, 0x2, result.bytes.len));
            l.stats.wire_bytes = result.bytes.len;
            if (debug_enabled) {
                const encode_ns: u64 = @intCast(@max(0, monoNanos() - encode_t0));
                l.stats.encode_ns = encode_ns;
                l.stats.encode_ns_total +%= encode_ns;
            }
            const fanout_t0 = if (debug_enabled) monoNanos() else 0;
            broadcastBinarySnapshot(l, frame, now, result.sequence);
            if (debug_enabled) {
                const fanout_ns: u64 = @intCast(@max(0, monoNanos() - fanout_t0));
                l.stats.fanout_ns = fanout_ns;
                l.stats.fanout_ns_total +%= fanout_ns;
            }
        } else |_| {}
        releaseSharedFrame(frame);
    }
    const serialize_ns: u64 = @intCast(@max(0, monoNanos() - serialize_t0));
    l.stats.serialize_ns = serialize_ns;
    l.stats.serialize_ns_total +%= serialize_ns;

    // stats
    const dur_ns: u64 = @intCast(@max(0, monoNanos() - t0));
    const dur_ms = @as(f64, @floatFromInt(dur_ns)) / 1_000_000.0;
    l.balance_ewma_ns = if (l.balance_ewma_ns == 0)
        dur_ns
    else
        (l.balance_ewma_ns *| 7 +| dur_ns) / 8;
    l.stats.last_tick_ms = dur_ms;
    l.stats.ticks += 1;
    const window: f64 = @floatFromInt(@min(l.stats.ticks, 200));
    l.stats.avg_tick_ms += (dur_ms - l.stats.avg_tick_ms) / window;
    l.stats.max_tick_ms = @max(l.stats.max_tick_ms, dur_ms);
}

fn idleLobbyExpired(empty: bool, last_empty_at: i64, now: i64, ttl: i64) bool {
    return empty and now - last_empty_at >= ttl;
}

fn reapIdleLobbies(now: i64) void {
    var index: usize = 0;
    while (index < lobbies.count()) {
        const l = lobbies.values()[index];
        if (std.mem.eql(u8, l.id, DEFAULT_LOBBY_ID)) {
            index += 1;
            continue;
        }
        l.mutex.lockUncancelable(g_io);
        const empty = l.players.items.len == 0 and l.spectators.items.len == 0;
        if (!empty) {
            l.last_empty_at = 0;
        } else if (l.last_empty_at == 0) l.last_empty_at = now;
        const expired = idleLobbyExpired(empty, l.last_empty_at, now, lobby_idle_delete_ms);
        l.mutex.unlock(g_io);
        if (expired) {
            lobbies.swapRemoveAt(index);
            destroyLobby(l);
        } else {
            index += 1;
        }
    }
}

// ------------------------------------------------------------------ http plumbing

const SendOpts = struct {
    status: u16,
    reason: []const u8,
    ctype: ?[]const u8 = null,
    body: []const u8 = "",
    body_static: bool = false,
    location: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    keep_alive: bool,
    head_only: bool = false,
};

fn sendResponse(c: *Conn, aa: Allocator, o: SendOpts) void {
    _ = aa;
    var header_storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&header_storage);
    const header_allocator = fixed.allocator();
    var b: Buf = .empty;
    defer b.deinit(header_allocator);
    pf(&b, header_allocator, "HTTP/1.1 {d} {s}" ++ CRLF, .{ o.status, o.reason }) catch return;
    b.appendSlice(header_allocator, "X-Content-Type-Options: nosniff" ++ CRLF) catch return;
    b.appendSlice(header_allocator, "X-Frame-Options: DENY" ++ CRLF) catch return;
    b.appendSlice(header_allocator, "Referrer-Policy: no-referrer" ++ CRLF) catch return;
    if (o.location) |loc| {
        b.appendSlice(header_allocator, "Location: ") catch return;
        b.appendSlice(header_allocator, loc) catch return;
        b.appendSlice(header_allocator, CRLF) catch return;
    }
    if (o.ctype) |ct| {
        b.appendSlice(header_allocator, "Content-Type: ") catch return;
        b.appendSlice(header_allocator, ct) catch return;
        b.appendSlice(header_allocator, CRLF) catch return;
    }
    if (o.cache_control) |value| {
        b.appendSlice(header_allocator, "Cache-Control: ") catch return;
        b.appendSlice(header_allocator, value) catch return;
        b.appendSlice(header_allocator, CRLF) catch return;
    }
    pf(&b, header_allocator, "Content-Length: {d}" ++ CRLF, .{o.body.len}) catch return;
    const conn_hdr: []const u8 = if (o.keep_alive) "Connection: keep-alive" ++ CRLF else "Connection: close" ++ CRLF;
    b.appendSlice(header_allocator, conn_hdr) catch return;
    b.appendSlice(header_allocator, CRLF) catch return;
    connQueueResponse(c, b.items, if (o.head_only) "" else o.body, o.body_static);
    if (!o.keep_alive) c.close_after_write = true;
}

const CRLF = "\r\n";

fn sendNotFound(c: *Conn, aa: Allocator, keep_alive: bool, head_only: bool) void {
    sendResponse(c, aa, .{
        .status = 404,
        .reason = "Not Found",
        .ctype = "text/html; charset=utf-8",
        .body = "<html><body><h1>Not Found</h1></body></html>",
        .keep_alive = keep_alive,
        .head_only = head_only,
    });
}

fn sendServerError(c: *Conn, aa: Allocator) void {
    sendResponse(c, aa, .{
        .status = 500,
        .reason = "Internal Server Error",
        .ctype = "text/html; charset=utf-8",
        .body = "<html><body><h1>Internal Server Error</h1></body></html>",
        .keep_alive = false,
    });
}

fn sendRedirect(c: *Conn, aa: Allocator, status: u16, loc: []const u8, keep_alive: bool, head_only: bool) void {
    const body = std.fmt.allocPrint(aa, "Found. Redirecting to {s}", .{loc}) catch loc;
    sendResponse(c, aa, .{
        .status = status,
        .reason = if (status == 303) "See Other" else "Found",
        .ctype = "text/plain; charset=utf-8",
        .body = body,
        .location = loc,
        .keep_alive = keep_alive,
        .head_only = head_only,
    });
}

// ------------------------------------------------------------------ lobby ids

/// Mirrors server/generateId.js: 'id-' + rand base36 (8 chars) + base36(now ms).
fn genLobbyId(buf: *[48]u8) []const u8 {
    @memcpy(buf[0..3], "id-");
    const alpha = "0123456789abcdefghijklmnopqrstuvwxyz";
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const r = rng_prng.random().uintLessThan(usize, alpha.len);
        buf[3 + i] = alpha[r];
    }
    const suffix_len = text.writeBase36(buf[11..], @intCast(unixMillis()));
    return buf[0 .. 11 + suffix_len];
}

// ------------------------------------------------------------------ stats

fn readRssBytes() u64 {
    blk: {
        const f = std.Io.Dir.openFileAbsolute(g_io, "/proc/self/status", .{}) catch break :blk;
        defer f.close(g_io);
        var buf: [4096]u8 = undefined;
        var bufs = [1][]u8{&buf};
        const n = f.readStreaming(g_io, &bufs) catch break :blk;
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "VmRSS:")) {
                var toks = std.mem.tokenizeAny(u8, line["VmRSS:".len..], " \t");
                const num = toks.next() orelse break :blk;
                const kb = std.fmt.parseInt(u64, num, 10) catch break :blk;
                return kb * 1024;
            }
        }
    }
    blk2: {
        const f = std.Io.Dir.openFileAbsolute(g_io, "/proc/self/statm", .{}) catch break :blk2;
        defer f.close(g_io);
        var buf: [256]u8 = undefined;
        var bufs = [1][]u8{&buf};
        const n = f.readStreaming(g_io, &bufs) catch break :blk2;
        var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
        _ = it.next() orelse break :blk2;
        const pages_str = it.next() orelse break :blk2;
        const pages = std.fmt.parseInt(u64, pages_str, 10) catch break :blk2;
        return pages * 4096;
    }
    return 0;
}

const StatsPayload = struct {
    json: []u8,
    lobby_stats: []stats_json.LobbyStats,
    worker_loads: []stats_json.WorkerLoad,

    fn deinit(payload: StatsPayload, allocator: Allocator) void {
        allocator.free(payload.json);
        allocator.free(payload.lobby_stats);
        allocator.free(payload.worker_loads);
    }
};

fn buildStats(aa: Allocator) !StatsPayload {
    const nsToUs = struct {
        fn convert(value: u64) f64 {
            return @as(f64, @floatFromInt(value)) / 1000.0;
        }
        fn average(total: u64, samples: u64) f64 {
            if (samples == 0) return 0;
            return roundToThousandth(convert(total) / @as(f64, @floatFromInt(samples)));
        }
        fn roundToThousandth(value: f64) f64 {
            return @round(value * 1000.0) / 1000.0;
        }
    };

    const worker_loads = try aa.alloc(stats_json.WorkerLoad, game_workers.items.len);
    errdefer aa.free(worker_loads);
    for (game_workers.items, 0..) |worker, index| {
        worker.mutex.lockUncancelable(g_io);
        defer worker.mutex.unlock(g_io);
        worker_loads[index] = .{
            .lobbies = worker.lobbies.items.len,
            .estimatedTickUs = nsToUs.convert(workerEstimatedCostLocked(worker)),
        };
    }

    const lobby_stats = try aa.alloc(stats_json.LobbyStats, lobbies.count());
    errdefer aa.free(lobby_stats);
    var lobby_index: usize = 0;
    for (lobbies.values()) |l| {
        l.mutex.lockUncancelable(g_io);
        defer l.mutex.unlock(g_io);
        lobby_stats[lobby_index] = .{
            .id = l.id,
            .players = l.players.items.len,
            .drops = l.drops.items.len,
            .bonus = l.bonus.items.len,
            .golden = l.golden != null,
            .lastTickMs = l.stats.last_tick_ms,
            .avgTickMs = nsToUs.roundToThousandth(l.stats.avg_tick_ms),
            .balanceEwmaUs = nsToUs.convert(l.balance_ewma_ns),
            .maxTickMs = l.stats.max_tick_ms,
            .serializeUs = nsToUs.convert(l.stats.serialize_ns),
            .avgSerializeUs = nsToUs.average(l.stats.serialize_ns_total, l.stats.ticks),
            .encodeUs = nsToUs.convert(l.stats.encode_ns),
            .avgEncodeUs = nsToUs.average(l.stats.encode_ns_total, l.stats.ticks),
            .fanoutUs = nsToUs.convert(l.stats.fanout_ns),
            .avgFanoutUs = nsToUs.average(l.stats.fanout_ns_total, l.stats.ticks),
            .wireBytes = l.stats.wire_bytes,
        };
        lobby_index += 1;
    }

    const encoded = try stats_json.encode(aa, .{
        .rss = readRssBytes(),
        .uptime = @as(f64, @floatFromInt(unixMillis() - start_ms)) / 1000.0,
        .totalPlayers = totalPlayersLocked(),
        .maxPlayers = max_players_global,
        .maxPlayersPerLobby = max_players_per_lobby,
        .maxLobbies = max_lobbies,
        .connections = connections.count(),
        .lobbyWorkers = game_workers.items.len,
        .lobbiesPerWorker = lobbies_per_worker,
        .workerMigrations = worker_migrations,
        .workerTargetTickUs = nsToUs.convert(worker_balance.targetTickBudgetNs(TICK_NS)),
        .workerLoads = worker_loads,
        .networkBytesSent = network_bytes_sent.load(.monotonic),
        .networkBytesReceived = network_bytes_received,
        .websocketFramesSent = websocket_frames_sent.load(.monotonic),
        .websocketFramesReceived = websocket_frames_received,
        .inputEvents = input_events,
        .avgInputEventUs = nsToUs.average(input_event_ns_total, input_events),
        .lobbies = lobby_stats[0..lobby_index],
    });
    return .{
        .json = encoded,
        .lobby_stats = lobby_stats,
        .worker_loads = worker_loads,
    };
}

fn sendStats(c: *Conn, aa: Allocator, keep_alive: bool, head_only: bool) void {
    const payload = buildStats(aa) catch {
        return sendServerError(c, aa);
    };
    defer payload.deinit(aa);
    sendResponse(c, aa, .{
        .status = 200,
        .reason = "OK",
        .ctype = "application/json",
        .body = payload.json,
        .keep_alive = keep_alive,
        .head_only = head_only,
    });
}

fn writePublicStatus(out: []u8, players: usize, lobby_count: usize) ![]const u8 {
    return std.fmt.bufPrint(out, "{{\"players\":{d},\"lobbies\":{d}}}", .{ players, lobby_count });
}

/// The landing page only needs two bounded counters. Keep this separate from
/// the allocation-heavy debug payload and explicitly prevent intermediary or
/// browser caches from presenting stale population figures.
fn sendPublicStatus(c: *Conn, aa: Allocator, keep_alive: bool, head_only: bool) void {
    var storage: [96]u8 = undefined;
    const body = writePublicStatus(&storage, totalPlayersLocked(), lobbies.count()) catch
        return sendServerError(c, aa);
    sendResponse(c, aa, .{
        .status = 200,
        .reason = "OK",
        .ctype = "application/json; charset=utf-8",
        .body = body,
        .cache_control = "no-store",
        .keep_alive = keep_alive,
        .head_only = head_only,
    });
}

// ------------------------------------------------------------------ routing

fn routeAndRespond(c: *Conn, aa: Allocator, method: []const u8, target: []const u8, body: []const u8, body_is_json: bool, keep_alive: bool) void {
    const is_get = std.mem.eql(u8, method, "GET");
    const is_head = std.mem.eql(u8, method, "HEAD");
    const is_post = std.mem.eql(u8, method, "POST");

    const qi = std.mem.indexOfScalar(u8, target, '?');
    const raw_path = if (qi) |i| target[0..i] else target;
    const dec_path = percentDecode(aa, raw_path);
    const head_only = is_head;

    if (is_get or is_head) {
        if (std.mem.eql(u8, dec_path, "/")) {
            return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = assets.assets[0].ctype, .body = assets.index_html, .body_static = true, .cache_control = "no-store", .keep_alive = keep_alive, .head_only = head_only });
        }
        if (std.mem.eql(u8, dec_path, "/game.html")) {
            // lobby gate: direct requests bounce home
            return sendRedirect(c, aa, 302, "/", keep_alive, head_only);
        }
        if (std.mem.startsWith(u8, dec_path, "/game/")) {
            const raw_id = raw_path["/game/".len..];
            if (raw_id.len == 0 or std.mem.indexOfScalar(u8, raw_id, '/') != null) {
                return sendNotFound(c, aa, keep_alive, head_only);
            }
            const gid = percentDecode(aa, raw_id);
            const exists = lobbies.contains(gid);
            if (exists) {
                return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = "text/html; charset=utf-8", .body = assets.game_html, .body_static = true, .cache_control = "no-store", .keep_alive = keep_alive, .head_only = head_only });
            }
            return sendRedirect(c, aa, 302, "/", keep_alive, head_only);
        }
        if (std.mem.eql(u8, dec_path, "/debug/stats")) {
            if (debug_enabled) return sendStats(c, aa, keep_alive, head_only);
            return sendNotFound(c, aa, keep_alive, head_only);
        }
        if (std.mem.eql(u8, dec_path, "/status")) {
            return sendPublicStatus(c, aa, keep_alive, head_only);
        }
        if (assets.find(dec_path)) |a| {
            const cache_control = if (std.mem.startsWith(u8, a.ctype, "text/html"))
                "no-store"
            else
                "no-cache, must-revalidate";
            return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = a.ctype, .body = a.body, .body_static = true, .cache_control = cache_control, .keep_alive = keep_alive, .head_only = head_only });
        }
        return sendNotFound(c, aa, keep_alive, head_only);
    }

    if (is_post) {
        if (std.mem.eql(u8, dec_path, "/quickjoin")) {
            const lobby = selectQuickJoinLobby() orelse
                return sendRedirect(c, aa, 303, "/?error=no-open-lobby", keep_alive, false);
            const enc = uriEncodeComponent(aa, lobby.id);
            const loc = std.fmt.allocPrint(aa, "/game/{s}", .{enc}) catch "/?error=no-open-lobby";
            return sendRedirect(c, aa, 303, loc, keep_alive, false);
        }
        if (std.mem.eql(u8, dec_path, "/generateid")) {
            const raw_password = if (body.len > 0) extractFormField(aa, body, "password") else null;
            const password = checkedPassword(raw_password) catch {
                return sendResponse(c, aa, .{
                    .status = 400,
                    .reason = "Bad Request",
                    .ctype = "text/plain; charset=utf-8",
                    .body = "Password must be valid text of at most 64 bytes",
                    .keep_alive = keep_alive,
                });
            };
            const classical_value = if (body.len > 0) extractFormField(aa, body, "classical") else null;
            const classical = if (classical_value) |value|
                std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "on") or std.ascii.eqlIgnoreCase(value, "true")
            else
                false;
            const mode_value = if (body.len > 0) extractFormField(aa, body, "mode") else null;
            const mode = parseGameMode(mode_value, classical) orelse {
                return sendResponse(c, aa, .{
                    .status = 400,
                    .reason = "Bad Request",
                    .ctype = "text/plain; charset=utf-8",
                    .body = "Unknown game mode",
                    .keep_alive = keep_alive,
                });
            };
            const capacity_value = if (body.len > 0) extractFormField(aa, body, "capacity") else null;
            const capacity = parseLobbyCapacity(capacity_value) orelse {
                return sendResponse(c, aa, .{
                    .status = 400,
                    .reason = "Bad Request",
                    .ctype = "text/plain; charset=utf-8",
                    .body = "Lobby capacity must be 16 or 32",
                    .keep_alive = keep_alive,
                });
            };
            const target_value = if (body.len > 0) extractFormField(aa, body, "publicTarget") else null;
            // Passwordless lobbies are discoverable until their selected
            // capacity. Explicit legacy targets remain accepted for old clients.
            const public_target = if (target_value) |legacy_target|
                (parsePublicTarget(legacy_target) orelse {
                    return sendResponse(c, aa, .{
                        .status = 400,
                        .reason = "Bad Request",
                        .ctype = "text/plain; charset=utf-8",
                        .body = "Quick Join target must be 0 or 2 through 32",
                        .keep_alive = keep_alive,
                    });
                })
            else
                capacity;
            if (public_target > capacity) {
                return sendResponse(c, aa, .{
                    .status = 400,
                    .reason = "Bad Request",
                    .ctype = "text/plain; charset=utf-8",
                    .body = "Quick Join target cannot exceed lobby capacity",
                    .keep_alive = keep_alive,
                });
            }
            const walls_value = if (body.len > 0) extractFormField(aa, body, "walls") else null;
            const wrap_walls = parseWrapWalls(walls_value) orelse {
                return sendResponse(c, aa, .{
                    .status = 400,
                    .reason = "Bad Request",
                    .ctype = "text/plain; charset=utf-8",
                    .body = "Walls must be solid or wrap",
                    .keep_alive = keep_alive,
                });
            };
            if (lobbies.count() >= max_lobbies) {
                return sendResponse(c, aa, .{
                    .status = 503,
                    .reason = "Service Unavailable",
                    .ctype = "text/plain; charset=utf-8",
                    .body = "Lobby capacity reached; try again later",
                    .keep_alive = keep_alive,
                });
            }
            var idbuf: [48]u8 = undefined;
            var new_id: []const u8 = undefined;
            while (true) {
                new_id = genLobbyId(&idbuf);
                if (!lobbies.contains(new_id)) break;
            }
            const owned = galloc.dupe(u8, new_id) catch {
                return sendServerError(c, aa);
            };
            _ = createLobbyLocked(owned, password, mode, public_target, wrap_walls, capacity) catch {
                galloc.free(owned);
                return sendServerError(c, aa);
            };
            const enc = uriEncodeComponent(aa, new_id);
            const loc = std.fmt.allocPrint(aa, "/game/{s}", .{enc}) catch "/";
            return sendRedirect(c, aa, 303, loc, keep_alive, false);
        }
        if (std.mem.eql(u8, dec_path, "/joingame")) {
            var game_id: ?[]const u8 = null;
            var password: []const u8 = "";
            if (body.len > 0) {
                if (body_is_json) game_id = extractJsonField(aa, body, "gameId");
                if (game_id == null) game_id = extractFormField(aa, body, "gameId");
                if (body_is_json) password = extractJsonField(aa, body, "password") orelse "";
                if (password.len == 0) password = extractFormField(aa, body, "password") orelse "";
            }
            var loc: []const u8 = "/?error=unknown-game";
            if (game_id) |raw| {
                const trimmed = jsTrim(raw);
                const lobby = lobbies.get(trimmed);
                if (lobby != null and lobbyAcceptsPassword(lobby.?, password)) {
                    const enc = uriEncodeComponent(aa, trimmed);
                    loc = std.fmt.allocPrint(aa, "/game/{s}", .{enc}) catch "/?error=unknown-game";
                }
            }
            return sendRedirect(c, aa, 303, loc, keep_alive, false);
        }
        return sendNotFound(c, aa, keep_alive, false);
    }

    return sendNotFound(c, aa, keep_alive, false);
}

// ------------------------------------------------------------------ websocket

fn doUpgrade(c: *Conn, aa: Allocator, key: []const u8) bool {
    var concat_buf: [512]u8 = undefined;
    if (key.len == 0 or key.len + WS_MAGIC.len > concat_buf.len) return false;
    @memcpy(concat_buf[0..key.len], key);
    @memcpy(concat_buf[key.len..][0..WS_MAGIC.len], WS_MAGIC);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat_buf[0 .. key.len + WS_MAGIC.len], &digest, .{});
    var accept_buf: [32]u8 = undefined;
    const acc = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    const resp = std.fmt.allocPrint(
        aa,
        "HTTP/1.1 101 Switching Protocols" ++ CRLF ++ "Upgrade: websocket" ++ CRLF ++ "Connection: Upgrade" ++ CRLF ++ "Sec-WebSocket-Accept: {s}" ++ CRLF ++ CRLF,
        .{acc},
    ) catch return false;
    defer aa.free(resp);

    var raw: [16]u8 = undefined;
    g_io.random(&raw);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&c.sid, &raw);
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.append(aa, ',') catch return false;
    jsString(&args, aa, c.sidSlice()) catch return false;
    const hello = eventFrame(aa, "id", args.items) catch return false;
    defer aa.free(hello);

    // Do not publish an irreversible protocol switch until every fallible
    // piece of the initial WebSocket exchange has been prepared.
    connQueueRaw(c, resp);
    connEnqueueText(c, hello);
    return true;
}

fn handleRawBinary(c: *Conn, aa: Allocator, payload: []const u8) void {
    const parse_t0 = monoNanos();
    defer {
        input_event_ns_total +%= @intCast(@max(0, monoNanos() - parse_t0));
        input_events +%= 1;
    }
    const packet = websocket.clientPacket(payload) orelse return;
    switch (packet) {
        .join => |join| handleClientReady(c, aa, join.username, join.lobby_id, join.password),
        .direction => |direction| handleKeyPress(c, direction),
        .visibility => |visible| handleVisibility(c, visible),
        .boost => |held| handleBoost(c, held),
        .chat => |message| handleChat(c, message, aa),
    }
}

const WsResult = struct {
    consumed: usize,
    closed: bool,
};

fn parseWsFrames(c: *Conn, aa: Allocator, data: []u8) !WsResult {
    var off: usize = 0;
    while (data.len - off >= 2) {
        const b0 = data[off];
        const b1 = data[off + 1];
        const fin = (b0 & 0x80) != 0;
        const reserved_bits = b0 & 0x70;
        const opcode = b0 & 0x0F;
        const masked = (b1 & 0x80) != 0;
        const length_marker = b1 & 0x7F;
        var len: usize = length_marker;
        var hdr_len: usize = 2;
        if (length_marker == 126) {
            if (data.len - off < 4) break;
            const extended = std.mem.readInt(u16, data[off + 2 ..][0..2], .big);
            len = try websocket.payloadLength(length_marker, extended);
            hdr_len = 4;
        } else if (length_marker == 127) {
            if (data.len - off < 10) break;
            const v = std.mem.readInt(u64, data[off + 2 ..][0..8], .big);
            len = try websocket.payloadLength(length_marker, v);
            hdr_len = 10;
        }
        try websocket.validateClientFrame(fin, reserved_bits, opcode, len);
        if (!masked) return error.UnmaskedClientFrame; // clients MUST mask
        if (data.len - off < hdr_len + 4 + len) break;
        const key = data[off + hdr_len ..][0..4].*;
        const pstart = off + hdr_len + 4;
        const payload = data[pstart .. pstart + len];
        for (payload, 0..) |*ch, i| ch.* ^= key[i & 3];
        off += hdr_len + 4 + len;
        if (debug_enabled) websocket_frames_received +%= 1;

        switch (opcode) {
            0x1 => try websocket.validateTextPayload(payload), // text control packets are server-only
            0x2 => handleRawBinary(c, aa, payload),
            0x8 => { // close
                try websocket.validateClosePayload(payload);
                connEnqueueClose(c, payload);
                return .{ .consumed = off, .closed = true };
            },
            0x9 => connEnqueueFrame(c, 0xA, payload), // ws ping -> ws pong
            0xA => c.awaiting_pong_since = null, // ws pong
            else => {},
        }
    }
    return .{ .consumed = off, .closed = false };
}

// ------------------------------------------------------- connection lifecycle

fn consumeInput(c: *Conn, count: usize) void {
    if (count == 0) return;
    const remain = c.input.items.len - count;
    std.mem.copyForwards(u8, c.input.items[0..remain], c.input.items[count..]);
    c.input.shrinkRetainingCapacity(remain);
}

fn processWsInput(c: *Conn, aa: Allocator) bool {
    if (c.input.items.len > MAX_WS_INPUT) return false;
    const result = parseWsFrames(c, aa, c.input.items) catch return false;
    consumeInput(c, result.consumed);
    if (result.closed) c.close_after_write = true;
    return true;
}

fn processHttpInput(c: *Conn, aa: Allocator, peer_eof: bool) bool {
    // Parse a complete pipeline with an offset and compact once on exit. The
    // previous per-request memmove made an N-request batch copy O(N²) bytes.
    var consumed: usize = 0;
    defer {
        consumeInput(c, consumed);
        if (c.http_batching) {
            c.http_batching = false;
            _ = flushOutput(c);
        }
    }
    while (c.mode == .http and !c.close_after_write) {
        const input = c.input.items[consumed..];
        const head_at = std.mem.indexOf(u8, input, CRLF ++ CRLF) orelse {
            if (!peer_eof) return input.len <= MAX_HTTP_HEAD_LINE;
            // A FIN can arrive as a separate epoll notification after its
            // requests were parsed. Drain their queued responses; discard
            // only an incomplete trailing request.
            if (input.len == 0 or consumed != 0) {
                c.close_after_write = true;
                return true;
            }
            return false;
        };
        if (head_at > MAX_HTTP_HEAD_LINE) return false;
        const head = input[0..head_at];
        // With no headers, the CRLF that terminates the request line is also
        // the first half of the CRLFCRLF delimiter and lies just past `head`.
        const request_line_end = std.mem.indexOf(u8, head, CRLF) orelse head.len;
        const request_line = head[0..request_line_end];
        const sp1 = std.mem.indexOfScalar(u8, request_line, ' ') orelse return false;
        const sp2 = std.mem.lastIndexOfScalar(u8, request_line, ' ') orelse return false;
        if (sp2 <= sp1 + 1) return false;
        const method = request_line[0..sp1];
        const target = request_line[sp1 + 1 .. sp2];
        const version = request_line[sp2 + 1 ..];
        const http10 = std.mem.eql(u8, version, "HTTP/1.0");
        const http11 = std.mem.eql(u8, version, "HTTP/1.1");
        if (!http10 and !http11) return false;

        var content_length: ?usize = null;
        var connection_close = false;
        var connection_keep = false;
        var connection_upgrade = false;
        var upgrade_ws = false;
        var ws_key: []const u8 = "";
        var ws_key_seen = false;
        var ws_version_ok = false;
        var ws_version_seen = false;
        var body_is_json = false;
        var header_count: usize = 0;
        const headers_at = @min(head.len, request_line_end + CRLF.len);
        var lines = std.mem.splitSequence(u8, head[headers_at..], CRLF);
        while (lines.next()) |line| {
            header_count += 1;
            if (header_count > 200) return false;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                const parsed = std.fmt.parseInt(usize, value, 10) catch return false;
                if (content_length) |known| {
                    if (known != parsed) return false;
                } else content_length = parsed;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                // Chunked request bodies are intentionally unsupported. Never
                // combine TE with this Content-Length framing parser.
                return false;
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                connection_close = connection_close or websocket.headerHasToken(value, "close");
                connection_keep = connection_keep or websocket.headerHasToken(value, "keep-alive");
                connection_upgrade = connection_upgrade or websocket.headerHasToken(value, "upgrade");
            } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                upgrade_ws = upgrade_ws or websocket.headerHasToken(value, "websocket");
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
                if (ws_key_seen) return false;
                ws_key_seen = true;
                ws_key = value;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
                if (ws_version_seen) return false;
                ws_version_seen = true;
                ws_version_ok = std.mem.eql(u8, value, "13");
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                body_is_json = std.ascii.indexOfIgnoreCase(value, "application/json") != null;
            }
        }

        const body_len = content_length orelse 0;
        if (body_len > MAX_HTTP_BODY) {
            sendResponse(c, aa, .{ .status = 413, .reason = "Payload Too Large", .ctype = "text/html; charset=utf-8", .body = "<html><body><h1>Payload Too Large</h1></body></html>", .keep_alive = false });
            return true;
        }
        const body_at = head_at + 2 * CRLF.len;
        const request_len = body_at + body_len;
        if (input.len < request_len) {
            if (!peer_eof) return true;
            if (consumed != 0) {
                c.close_after_write = true;
                return true;
            }
            return false;
        }
        const body = input[body_at..request_len];

        if (upgrade_ws) {
            const qpos = std.mem.indexOfScalar(u8, target, '?');
            const path = if (qpos) |i| target[0..i] else target;
            if (!http11 or !std.mem.eql(u8, method, "GET") or !connection_upgrade or !std.mem.eql(u8, path, "/ws") or
                !websocket.validClientKey(ws_key) or !ws_version_ok or !doUpgrade(c, aa, ws_key))
            {
                sendResponse(c, aa, .{ .status = 400, .reason = "Bad Request", .ctype = "text/plain; charset=utf-8", .body = "websocket upgrade rejected", .keep_alive = false });
                return true;
            }
            consumed += request_len;
            consumeInput(c, consumed);
            consumed = 0;
            c.mode = .websocket;
            c.next_ping_ms = unixMillis() + PING_INTERVAL_MS;
            if (c.input.items.len == 0) {
                c.input.deinit(galloc);
                c.input = .empty;
            }
            return processWsInput(c, aa);
        }

        const final_half_closed_request = peer_eof and input.len == request_len;
        const keep_alive = (if (http10) connection_keep and !connection_close else !connection_close) and
            !final_half_closed_request;
        // If another request is already coalesced in this read, retain this
        // response so all complete responses can share bounded writev calls.
        // A standalone request continues to use connQueueResponse's direct
        // zero-copy syscall path.
        c.http_batching = c.http_batching or input.len > request_len;
        routeAndRespond(c, aa, method, target, body, body_is_json, keep_alive);
        consumed += request_len;
        if (connPoisoned(c)) return false;
    }
    return true;
}

fn readAvailable(c: *Conn, aa: Allocator, peer_shutdown: bool) bool {
    var scratch: [16 * 1024]u8 = undefined;
    var peer_eof = peer_shutdown;
    while (true) {
        const rc = linux.read(c.fd, &scratch, scratch.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                if (count == 0) {
                    peer_eof = true;
                    break;
                }
                if (debug_enabled) network_bytes_received +%= count;
                c.last_activity_ms = unixMillis();
                c.input.appendSlice(galloc, scratch[0..count]) catch return false;
                const max_input = if (c.mode == .http) MAX_HTTP_INPUT else MAX_WS_INPUT;
                if (c.input.items.len > max_input) return false;
            },
            .INTR => continue,
            .AGAIN => break,
            else => return false,
        }
    }
    const parsed = switch (c.mode) {
        .http => processHttpInput(c, aa, peer_eof),
        .websocket => processWsInput(c, aa),
    };
    if (!parsed) return false;
    if (!peer_eof) return true;

    // A TCP FIN closes only the peer's write side. Preserve any response
    // generated from the final buffered request, then close our side after it
    // drains. WebSocket EOF without a pending reply remains terminal.
    if (!connOutputDrained(c)) {
        c.close_after_write = true;
        return true;
    }
    return false;
}

fn teardownConn(c: *Conn) void {
    // Closing the only fd for this open-file description automatically removes
    // it from epoll. Accepted sockets are never duped, so EPOLL_CTL_DEL would
    // be one redundant syscall per connection.
    _ = connections.remove(c.fd);

    var arena = std.heap.ArenaAllocator.init(galloc);
    defer arena.deinit();
    removeConnPlayer(c, arena.allocator());

    // No lobby can enqueue after removal. Serialize the final close with any
    // write already in progress on the owning lobby thread.
    c.output_mutex.lockUncancelable(g_io);
    c.closing = true;
    closeFd(c.fd);
    for (c.output.items[c.output_head..]) |output| releasePending(output);
    c.output.deinit(galloc);
    c.output_mutex.unlock(g_io);
    c.input.deinit(galloc);
    galloc.destroy(c);
}

fn setNonBlocking(fd: posix.fd_t) bool {
    const current = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(current) != .SUCCESS) return false;
    const rc = linux.fcntl(fd, linux.F.SETFL, current | linux.SOCK.NONBLOCK);
    return linux.errno(rc) == .SUCCESS;
}

fn registerConn(fd: posix.fd_t) void {
    const c = galloc.create(Conn) catch {
        closeFd(fd);
        return;
    };
    c.* = .{ .fd = fd, .last_activity_ms = unixMillis() };
    connections.put(galloc, fd, c) catch {
        closeFd(fd);
        galloc.destroy(c);
        return;
    };
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.ET,
        .data = .{ .ptr = @intFromPtr(c) },
    };
    const rc = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
    if (linux.errno(rc) != .SUCCESS) teardownConn(c);
}

fn acceptReady() void {
    var accepted: usize = 0;
    while (accepted < 256) : (accepted += 1) {
        const rc = linux.accept4(listen_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => registerConn(@intCast(rc)),
            .INTR => continue,
            .AGAIN => return,
            else => return,
        }
    }
}

fn serviceHeartbeats(now: i64) void {
    // Cleanup must remain available under allocator pressure. Remove fixed
    // batches between map scans because teardown invalidates its iterator.
    while (true) {
        var doomed: [MAINTENANCE_BATCH]*Conn = undefined;
        var doomed_len: usize = 0;
        var connection_it = connections.valueIterator();
        while (connection_it.next()) |connection_ptr| {
            const c = connection_ptr.*;
            if (connPoisoned(c)) {
                doomed[doomed_len] = c;
                doomed_len += 1;
                if (doomed_len == doomed.len) break;
                continue;
            }
            if (c.mode == .http and now - c.last_activity_ms > HTTP_IDLE_MS) {
                doomed[doomed_len] = c;
                doomed_len += 1;
                if (doomed_len == doomed.len) break;
                continue;
            }
            if (c.mode != .websocket) continue;
            if (c.awaiting_pong_since) |started| {
                if (now - started > PING_TIMEOUT_MS) {
                    doomed[doomed_len] = c;
                    doomed_len += 1;
                    if (doomed_len == doomed.len) break;
                    continue;
                }
            }
            if (now >= c.next_ping_ms) {
                connEnqueueFrame(c, 0x9, "");
                c.awaiting_pong_since = now;
                c.next_ping_ms = now + PING_INTERVAL_MS;
            }
        }
        for (doomed[0..doomed_len]) |c| teardownConn(c);
        if (doomed_len < doomed.len) return;
    }
}

fn reactorLoop() void {
    var events: [256]linux.epoll_event = undefined;
    var arena = std.heap.ArenaAllocator.init(galloc);
    defer arena.deinit();
    var next_maintenance = unixMillis() + 1000;

    while (!shutting_down.load(.acquire)) {
        const rc = linux.epoll_wait(epoll_fd, &events, events.len, 1000);
        const ready: usize = switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => 0,
            else => break,
        };

        _ = arena.reset(.retain_capacity);
        const aa = arena.allocator();
        for (events[0..ready]) |event| {
            if (event.data.ptr == 0) {
                acceptReady();
                continue;
            }
            const c: *Conn = @ptrFromInt(event.data.ptr);
            const peer_shutdown = (event.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP)) != 0;
            var alive = (event.events & linux.EPOLL.ERR) == 0;
            if (alive and ((event.events & linux.EPOLL.IN) != 0 or peer_shutdown)) {
                alive = readAvailable(c, aa, peer_shutdown);
            }
            if (alive and (event.events & linux.EPOLL.OUT) != 0) alive = flushOutput(c);
            if (alive and connPoisoned(c)) alive = false;
            if (alive and c.close_after_write and connOutputDrained(c)) alive = false;
            if (!alive) teardownConn(c);
        }

        const now_ms = unixMillis();
        if (now_ms >= next_maintenance) {
            serviceHeartbeats(now_ms);
            reapIdleLobbies(now_ms);
            deactivateEmptyLobbies();
            rebalanceGameWorkers(now_ms, aa);
            next_maintenance = now_ms + 1000;
        }
    }
}

fn setSockOpts(fd: posix.fd_t) bool {
    if (builtin.os.tag != .linux) return true;
    const one: c_int = 1;
    posix.setsockopt(fd, 6, 1, std.mem.asBytes(&one)) catch return false; // TCP_NODELAY
    return true;
}

// ------------------------------------------------------------------ signals / main

fn onSignal(_: posix.SIG) callconv(.c) void {
    shutting_down.store(true, .release);
    if (listen_fd >= 0) {
        _ = linux.shutdown(listen_fd, linux.SHUT.RDWR);
    }
}

fn installSignalHandlers() void {
    var ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ign, null); // writes to dead sockets must not kill us

    var term = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &term, null);
    posix.sigaction(posix.SIG.INT, &term, null);
}

fn envUsize(environ: std.process.Environ, name: []const u8, fallback: usize, ceiling: usize) usize {
    const raw = environ.getPosix(name) orelse return fallback;
    const parsed = std.fmt.parseInt(usize, raw, 10) catch return fallback;
    return std.math.clamp(parsed, 1, ceiling);
}

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    galloc = init.gpa;
    debug_enabled = if (init.minimal.environ.getPosix("SNEK_DEBUG")) |v| std.mem.eql(u8, v, "1") else false;
    const port: u16 = if (init.minimal.environ.getPosix("PORT")) |v| (std.fmt.parseInt(u16, v, 10) catch 3000) else 3000;
    max_players_global = envUsize(init.minimal.environ, "SNEK_MAX_PLAYERS", DEFAULT_MAX_PLAYERS_GLOBAL, binary_snapshot.MAX_PLAYERS);
    max_players_per_lobby = envUsize(init.minimal.environ, "SNEK_MAX_PLAYERS_PER_LOBBY", DEFAULT_MAX_PLAYERS_PER_LOBBY, binary_snapshot.MAX_PLAYERS);
    max_players_per_lobby = @min(max_players_per_lobby, max_players_global);
    max_lobbies = envUsize(init.minimal.environ, "SNEK_MAX_LOBBIES", DEFAULT_MAX_LOBBIES, 100_000);
    lobbies_per_worker = envUsize(init.minimal.environ, "SNEK_LOBBIES_PER_WORKER", DEFAULT_LOBBIES_PER_WORKER, 10_000);
    lobby_idle_delete_ms = @intCast(envUsize(init.minimal.environ, "SNEK_LOBBY_IDLE_MS", @intCast(DEFAULT_LOBBY_IDLE_DELETE_MS), 24 * 60 * 60 * 1000));

    start_ms = unixMillis();
    const seed: u64 = @bitCast(monoNanos());
    rng_prng = std.Random.DefaultPrng.init(seed ^ @as(u64, @intCast(std.os.linux.getpid())));

    installSignalHandlers();

    {
        const def_id = try galloc.dupe(u8, DEFAULT_LOBBY_ID);
        errdefer galloc.free(def_id);
        _ = try createLobbyLocked(def_id, "", .arcade, 16, false, 16);
    }

    const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    const srv = addr.listen(g_io, .{ .reuse_address = true }) catch |e| {
        std.debug.print("server error: {s}\n", .{@errorName(e)});
        return e;
    };
    listen_fd = srv.socket.handle;
    if (!setNonBlocking(listen_fd)) return error.NonBlockingSetupFailed;
    // Linux inherits TCP_NODELAY from the listening socket, avoiding one
    // setsockopt syscall for every accepted connection.
    if (!setSockOpts(listen_fd)) return error.TcpNoDelaySetupFailed;
    const epoll_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(epoll_rc) != .SUCCESS) return error.EpollCreateFailed;
    epoll_fd = @intCast(epoll_rc);
    var listen_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .ptr = 0 },
    };
    if (linux.errno(linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &listen_event)) != .SUCCESS) {
        return error.EpollRegisterFailed;
    }

    std.debug.print("listening on *:{d}\n", .{port});
    reactorLoop();
    std.process.exit(0);
}

test {
    _ = binary_snapshot;
    _ = collision;
    _ = stats_json;
    _ = worker_balance;
}

test "websocket headers use minimal RFC lengths" {
    var header: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), wsHeader(&header, 2, 17));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 17 }, header[0..2]);
    try std.testing.expectEqual(@as(usize, 4), wsHeader(&header, 2, 126));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 126, 0, 126 }, header[0..4]);
}

test "output queue compacts released prefixes and drops oversized idle storage" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    defer connection.output.deinit(galloc);

    for (0..80) |_| try connection.output.append(galloc, .{ .borrowed = "a" });
    try connection.output.append(galloc, .{ .borrowed = "xy" });
    for (0..49) |_| try connection.output.append(galloc, .{ .borrowed = "b" });
    connection.output_head = 80;
    connection.output_offset = 1;
    connection.output_bytes = 50;
    compactOutputPrefix(&connection);
    try std.testing.expectEqual(@as(usize, 50), connection.output.items.len);
    try std.testing.expectEqual(@as(usize, 0), connection.output_head);
    try std.testing.expectEqual(@as(usize, 1), connection.output_offset);
    try std.testing.expectEqual(@as(usize, 50), connection.output_bytes);
    try std.testing.expectEqualStrings("xy", connection.output.items[0].borrowed);

    connection.output.clearRetainingCapacity();
    connection.output_head = 0;
    connection.output_offset = 0;
    connection.output_bytes = 0;
    try connection.output.ensureTotalCapacity(galloc, OUTPUT_RETAINED_ITEMS + 1);
    resetOutputStorage(&connection);
    try std.testing.expectEqual(@as(usize, 0), connection.output.capacity);
}

test "batched output vectors preserve order and partial-write accounting" {
    galloc = std.testing.allocator;
    defer drainSnapshotPool();
    var connection = Conn{ .fd = -1 };
    defer connection.output.deinit(galloc);

    try connection.output.append(galloc, .{ .borrowed = "abcd" });
    const owned = try galloc.dupe(u8, "EFGH");
    try connection.output.append(galloc, .{ .owned = owned });
    const shared = try galloc.create(model.SharedFrame);
    shared.* = .{};
    try shared.payload.appendSlice(galloc, "snap");
    shared.header_len = @intCast(wsHeader(&shared.header, 0x2, shared.payload.items.len));
    try connection.output.append(galloc, .{ .shared = shared });
    try connection.output.append(galloc, .{ .borrowed = "ij" });
    connection.output_offset = 2;
    connection.output_bytes = 2 + owned.len + shared.len() + 2;

    var vectors: [MAX_OUTPUT_IOVECS]posix.iovec_const = undefined;
    const vector_count = outputVectors(&connection, &vectors);
    try std.testing.expectEqual(@as(usize, 5), vector_count);
    try std.testing.expectEqualStrings("cd", vectors[0].base[0..vectors[0].len]);
    try std.testing.expectEqualStrings("EFGH", vectors[1].base[0..vectors[1].len]);
    try std.testing.expectEqualSlices(u8, shared.header[0..shared.header_len], vectors[2].base[0..vectors[2].len]);
    try std.testing.expectEqualStrings("snap", vectors[3].base[0..vectors[3].len]);
    try std.testing.expectEqualStrings("ij", vectors[4].base[0..vectors[4].len]);

    consumeOutputBytes(&connection, 3);
    try std.testing.expectEqual(@as(usize, 1), connection.output_head);
    try std.testing.expectEqual(@as(usize, 1), connection.output_offset);
    try std.testing.expectEqual(@as(usize, 11), connection.output_bytes);

    consumeOutputBytes(&connection, 5);
    try std.testing.expectEqual(@as(usize, 2), connection.output_head);
    try std.testing.expectEqual(@as(usize, shared.header_len), connection.output_offset);
    try std.testing.expectEqual(@as(usize, 6), connection.output_bytes);

    consumeOutputBytes(&connection, 6);
    try std.testing.expect(outputEmpty(&connection));
    try std.testing.expectEqual(@as(usize, 0), connection.output_offset);
    try std.testing.expectEqual(@as(usize, 0), connection.output_bytes);
}

test "websocket close seals output after all earlier frames" {
    galloc = std.testing.allocator;
    g_io = std.testing.io;
    var connection = Conn{ .fd = -1, .mode = .websocket };
    defer connection.output.deinit(galloc);

    const prior = try galloc.dupe(u8, "data");
    try connection.output.append(galloc, .{ .owned = prior });
    connection.output_bytes = prior.len - 2;
    connection.output_offset = 2;

    connEnqueueClose(&connection, "\x03\xe8bye");
    try std.testing.expect(connection.closing);
    try std.testing.expectEqual(@as(usize, 2), connection.output.items.len);
    try std.testing.expectEqual(@as(usize, 2), connection.output_offset);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 5, 0x03, 0xe8, 'b', 'y', 'e' }, connection.output.items[1].owned);

    connEnqueueFrame(&connection, 0x1, "must-not-follow-close");
    try std.testing.expectEqual(@as(usize, 2), connection.output.items.len);

    for (connection.output.items) |output| releasePending(output);
    connection.output.clearRetainingCapacity();
    connection.output_bytes = 0;
    connection.output_offset = 0;
}

test "websocket sent counter excludes rejected queue publications" {
    galloc = std.testing.allocator;
    g_io = std.testing.io;
    const previous_debug = debug_enabled;
    const previous_frames = websocket_frames_sent.load(.monotonic);
    defer {
        debug_enabled = previous_debug;
        websocket_frames_sent.store(previous_frames, .monotonic);
    }
    debug_enabled = true;
    websocket_frames_sent.store(0, .monotonic);

    var connection = Conn{ .fd = -1, .mode = .websocket };
    defer {
        for (connection.output.items[connection.output_head..]) |output| releasePending(output);
        connection.output.deinit(galloc);
    }
    const prior = try galloc.dupe(u8, "prior");
    try connection.output.append(galloc, .{ .owned = prior });
    connection.output_bytes = prior.len;

    connEnqueueFrame(&connection, 0x1, "accepted");
    try std.testing.expectEqual(@as(u64, 1), websocket_frames_sent.load(.monotonic));

    connection.output_bytes = MAX_QUEUE_BYTES;
    connEnqueueFrame(&connection, 0x1, "rejected");
    try std.testing.expect(connection.poisoned);
    try std.testing.expectEqual(@as(u64, 1), websocket_frames_sent.load(.monotonic));

    var shared: model.SharedFrame = .{};
    shared.payload.items = @constCast("snapshot");
    shared.header_len = @intCast(wsHeader(&shared.header, 0x2, shared.payload.items.len));
    connection.poisoned = false;
    const accounting = connEnqueueSharedFrame(&connection, &shared);
    try std.testing.expectEqual(@as(usize, 0), accounting.frames_sent);
    try std.testing.expect(connection.poisoned);
}

test "binary client packets reject malformed and partial input" {
    try std.testing.expect(websocket.clientPacket(&.{}) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 1, 5, 4, 0, '1' }) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 1, 0, 1, 0, 'x' }) == null);
    try std.testing.expect(websocket.clientPacket(&.{2}) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 2, 4 }) == null);
    try std.testing.expect(websocket.clientPacket(&.{3}) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 3, 2 }) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 3, 1, 0 }) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 6, 0 }) == null);
    const joined = websocket.clientPacket(&.{ 1, 5, 4, 2, '1', '2', '3', '4', '5', 'n', 'a', 'm', 'e', 'p', 'w' }).?;
    try std.testing.expectEqualStrings("12345", joined.join.lobby_id);
    try std.testing.expectEqualStrings("name", joined.join.username);
    try std.testing.expectEqualStrings("pw", joined.join.password);
    try std.testing.expectEqual(Direction.left, websocket.clientPacket(&.{ 2, 2 }).?.direction);
    try std.testing.expectEqual(false, websocket.clientPacket(&.{ 3, 0 }).?.visibility);
    try std.testing.expectEqual(true, websocket.clientPacket(&.{ 3, 1 }).?.visibility);
    try std.testing.expectEqual(true, websocket.clientPacket(&.{ 4, 1 }).?.boost);
}

test "lobby passwords are bounded, validated, and authenticated exactly" {
    var oversized: [MAX_LOBBY_PASSWORD_BYTES + 1]u8 = @splat('p');
    try std.testing.expectError(error.InvalidPassword, checkedPassword(&oversized));
    try std.testing.expectError(error.InvalidPassword, checkedPassword("bad\x00password"));
    try std.testing.expectError(error.InvalidPassword, checkedPassword("bad\xc0\x80"));
    try std.testing.expectEqualStrings(" exact pass ", try checkedPassword(" exact pass "));

    const salt = [_]u8{0x5a} ** 16;
    var protected = Lobby{
        .id = @constCast("protected"),
        .password_salt = salt,
        .password_hash = hashPassword(&salt, "correct horse"),
        .password_protected = true,
        .food = .{ .x = 0, .y = 0 },
    };
    try std.testing.expect(!lobbyAcceptsPassword(&protected, ""));
    try std.testing.expect(!lobbyAcceptsPassword(&protected, "wrong horse"));
    try std.testing.expect(lobbyAcceptsPassword(&protected, "correct horse"));

    protected.password_protected = false;
    try std.testing.expect(lobbyAcceptsPassword(&protected, ""));
}

test "all mode objectives avoid arena edges and the responsive HUD footprint" {
    try std.testing.expect(!objectiveCellSafe(.{ .x = 0, .y = 0 }));
    try std.testing.expect(!objectiveCellSafe(.{
        .x = OBJECTIVE_EDGE_CELLS * CELL,
        .y = OBJECTIVE_EDGE_CELLS * CELL,
    }));
    try std.testing.expect(!objectiveCellSafe(.{
        .x = (COLS - OBJECTIVE_EDGE_CELLS) * CELL,
        .y = (ROWS / 2) * CELL,
    }));
    try std.testing.expect(!objectiveCellSafe(.{
        .x = (COLS / 2) * CELL,
        .y = OBJECTIVE_EDGE_CELLS * CELL,
    }));
    try std.testing.expect(!objectiveCellSafe(.{
        .x = HUD_MUTE_COL * CELL,
        .y = HUD_MUTE_ROW * CELL,
    }));
    try std.testing.expect(!objectiveCellSafe(.{
        .x = (HUD_CHAT_COL - 1) * CELL,
        .y = HUD_CHAT_ROW * CELL,
    }));
    try std.testing.expect(objectiveCellSafe(.{
        .x = (COLS * 3 / 4) * CELL,
        .y = (ROWS / 3) * CELL,
    }));

    for ([_]bool{ false, true }) |classical| {
        var lobby = Lobby{
            .id = @constCast("objective-test"),
            .mode = if (classical) .classical else .arcade,
            .food = .{ .x = (COLS / 2) * CELL, .y = (ROWS / 2) * CELL },
        };
        lobby.rng = std.Random.DefaultPrng.init(if (classical) 0xc1a551c else 0xa4cade);
        for (0..10_000) |_| {
            try std.testing.expect(objectiveCellSafe(randomObjectiveCell(&lobby)));
            try std.testing.expect(objectiveCellSafe(randomFreeCell(&lobby).?));
        }
    }
}

test "join spawns stay central and clear of players and every pickup" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var existing = Player{
        .id = @constCast("existing"),
        .name = @constCast("existing"),
        .color_hex = @constCast("#abcdef"),
        .conn = &connection,
    };
    defer existing.snake.deinit(galloc);
    var lobby = Lobby{
        .id = @constCast("spawn-test"),
        .food = .{ .x = 0, .y = 0 },
    };
    lobby.rng = std.Random.DefaultPrng.init(0x5afe);
    defer lobby.players.deinit(galloc);
    defer lobby.bonus.deinit(galloc);
    defer lobby.drops.deinit(galloc);
    defer lobby.remains.deinit(galloc);
    try lobby.players.append(galloc, &existing);

    const candidate: CellPos = .{ .x = (COLS / 2) * CELL, .y = (ROWS / 2) * CELL };
    try existing.snake.appendSlice(galloc, &.{
        .{ .x = candidate.x + 9 * CELL, .y = candidate.y },
        .{ .x = candidate.x + 3 * CELL, .y = candidate.y },
    });
    try std.testing.expect(spawnCellSafe(&lobby, candidate));

    existing.snake.items[0].x = candidate.x + SPAWN_HEAD_CLEARANCE_CELLS * CELL;
    try std.testing.expect(!spawnCellSafe(&lobby, candidate));
    existing.snake.items[0].x = candidate.x + 9 * CELL;
    existing.snake.items[1].x = candidate.x + SPAWN_BODY_CLEARANCE_CELLS * CELL;
    try std.testing.expect(!spawnCellSafe(&lobby, candidate));
    existing.snake.items[1].x = candidate.x + 3 * CELL;

    lobby.food = candidate;
    try std.testing.expect(!spawnCellSafe(&lobby, candidate));
    lobby.food = .{ .x = 0, .y = 0 };
    try lobby.bonus.append(galloc, .{ .pos = candidate });
    try std.testing.expect(!spawnCellSafe(&lobby, candidate));
    lobby.bonus.clearRetainingCapacity();
    try lobby.drops.append(galloc, .{ .pos = candidate, .expires_at = 1 });
    try std.testing.expect(!spawnCellSafe(&lobby, candidate));
    lobby.drops.clearRetainingCapacity();
    lobby.golden = .{ .pos = candidate, .expires_at = 1 };
    try std.testing.expect(!spawnCellSafe(&lobby, candidate));
    lobby.golden = null;
    try lobby.remains.append(galloc, .{ .pos = candidate, .expires_at = 1 });
    try std.testing.expect(!spawnCellSafe(&lobby, candidate));
    lobby.remains.clearRetainingCapacity();

    try std.testing.expect(!spawnCellSafe(&lobby, .{ .x = 0, .y = 0 }));
    try std.testing.expect(!spawnCellSafe(&lobby, .{
        .x = (COLS / 3) * CELL,
        .y = (ROWS / 3) * CELL,
    }));
    const picked = pickSpawnCell(&lobby).?;
    try std.testing.expect(spawnCellSafe(&lobby, picked));
}

test "join spawn fails safely when the central arena is saturated" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var blocker = Player{
        .id = @constCast("blocker"),
        .name = @constCast("blocker"),
        .color_hex = @constCast("#abcdef"),
        .conn = &connection,
    };
    defer blocker.snake.deinit(galloc);
    var cy: i32 = ROWS / 4;
    while (cy < ROWS - ROWS / 4) : (cy += 1) {
        var cx: i32 = COLS / 4;
        while (cx < COLS - COLS / 4) : (cx += 1)
            try blocker.snake.append(galloc, .{ .x = cx * CELL, .y = cy * CELL });
    }
    var lobby = Lobby{
        .id = @constCast("saturated"),
        .food = .{ .x = 0, .y = 0 },
    };
    lobby.rng = std.Random.DefaultPrng.init(0x5a7);
    defer lobby.players.deinit(galloc);
    try lobby.players.append(galloc, &blocker);
    try std.testing.expectEqual(@as(?CellPos, null), pickSpawnCell(&lobby));
}

test "all 32 lobby slots receive visible unobstructed spawns" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var players: [binary_snapshot.MAX_PLAYERS]Player = undefined;
    var initialized: usize = 0;
    defer for (players[0..initialized]) |*player| player.snake.deinit(galloc);

    var lobby = Lobby{
        .id = @constCast("full-spawn-test"),
        .max_players = binary_snapshot.MAX_PLAYERS,
        .food = .{ .x = 0, .y = 0 },
    };
    lobby.rng = std.Random.DefaultPrng.init(0x32afe);
    defer lobby.players.deinit(galloc);

    for (&players, 0..) |*player, index| {
        player.* = .{
            .id = @constCast("player"),
            .name = @constCast("player"),
            .color_hex = @constCast("#abcdef"),
            .conn = &connection,
        };
        initialized += 1;
        const spawn = pickSpawnCell(&lobby) orelse return error.TestUnexpectedResult;
        try std.testing.expect(spawnCellSafe(&lobby, spawn));
        try player.snake.append(galloc, spawn);
        try lobby.players.append(galloc, player);
        try std.testing.expectEqual(index + 1, lobby.players.items.len);
    }
}

test "classical lobby ticks never schedule special pickups" {
    galloc = std.testing.allocator;
    g_io = std.testing.io;
    defer drainSnapshotPool();

    var lobby = Lobby{
        .id = @constCast("classical"),
        .mode = .classical,
        .food = .{ .x = 0, .y = 0 },
        // These would cause immediate spawns in a standard lobby.
        .next_drop_at = 1,
        .next_golden_at = 1,
    };
    lobby.rng = std.Random.DefaultPrng.init(42);
    defer lobby.drops.deinit(galloc);
    defer lobby.bonus.deinit(galloc);
    defer lobby.roster_wire.deinit(galloc);
    defer lobby.players.deinit(galloc);
    defer lobby.spectators.deinit(galloc);
    defer lobby.remains.deinit(galloc);

    for (0..8) |index| tickLobby(&lobby, 100_000 + @as(i64, @intCast(index)), std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), lobby.drops.items.len);
    try std.testing.expectEqual(@as(usize, 0), lobby.bonus.items.len);
    try std.testing.expectEqual(@as(?model.Golden, null), lobby.golden);
    try std.testing.expectEqual(@as(i64, 1), lobby.next_drop_at);
    try std.testing.expectEqual(@as(i64, 1), lobby.next_golden_at);
}

test "keypress queues a turn for the current lobby membership" {
    g_io = std.testing.io;
    var connection = Conn{ .fd = -1 };
    var lobby = Lobby{ .id = @constCast("test"), .food = .{ .x = 0, .y = 0 } };
    var player = Player{
        .id = "sid",
        .name = @constCast("name"),
        .color_hex = @constCast("#abcdef"),
        .conn = &connection,
    };
    connection.lobby = &lobby;
    connection.player = &player;

    handleKeyPress(&connection, .right);
    try std.testing.expectEqual(@as(usize, 1), player.queue_len);
    try std.testing.expectEqual(Direction.right, player.queue[0]);

    connection.lobby = null;
    connection.player = null;
    handleKeyPress(&connection, .up);
    try std.testing.expectEqual(@as(usize, 1), player.queue_len);
}

test "only a websocket pong satisfies the heartbeat" {
    var connection = Conn{ .fd = -1, .awaiting_pong_since = 123 };
    var ignored_text = [_]u8{ 0x81, 0x80, 1, 2, 3, 4 };
    const text_result = try parseWsFrames(&connection, std.testing.allocator, &ignored_text);
    try std.testing.expectEqual(ignored_text.len, text_result.consumed);
    try std.testing.expectEqual(@as(?i64, 123), connection.awaiting_pong_since);

    var pong = [_]u8{ 0x8a, 0x80, 5, 6, 7, 8 };
    const pong_result = try parseWsFrames(&connection, std.testing.allocator, &pong);
    try std.testing.expectEqual(pong.len, pong_result.consumed);
    try std.testing.expectEqual(@as(?i64, null), connection.awaiting_pong_since);
}

test "visibility hint throttles delivery and requires foreground resync" {
    var connection = Conn{ .fd = -1 };
    handleVisibility(&connection, false);
    try std.testing.expect(connection.snapshot_hidden.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), connection.next_background_snapshot_ms.load(.acquire));
    try std.testing.expect(!connection.snapshot_needs_keyframe.load(.acquire));

    connection.next_background_snapshot_ms.store(42, .release);
    handleVisibility(&connection, false);
    try std.testing.expectEqual(@as(i64, 42), connection.next_background_snapshot_ms.load(.acquire));

    handleVisibility(&connection, true);
    try std.testing.expect(!connection.snapshot_hidden.load(.acquire));
    try std.testing.expect(connection.snapshot_needs_keyframe.load(.acquire));
}

test "compact roster and tick preserve world information" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var player = Player{
        .id = @constCast("sid"),
        .name = @constCast("name"),
        .color_hex = @constCast("#abcdef"),
        .conn = &connection,
    };
    defer player.snake.deinit(galloc);
    try player.snake.append(galloc, .{ .x = 32, .y = 48 });
    var lobby = Lobby{ .id = @constCast("test"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(galloc);
    defer lobby.roster_wire.deinit(galloc);
    try lobby.players.append(galloc, &player);

    try std.testing.expectEqualStrings("[\"r\",[[\"sid\",\"name\",\"#abcdef\"]]]", try buildRoster(&lobby));
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(galloc);
    const result = try binary_snapshot.build(&wire, &lobby, 0, galloc);
    try std.testing.expectEqual(binary_snapshot.Kind.keyframe, result.kind);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', binary_snapshot.VERSION, 1, 0, 1 }, result.bytes[0..6]);
}

test "movement reports a wall crossing before snapshot publication" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var player = Player{
        .id = @constCast("sid"),
        .name = @constCast("name"),
        .color_hex = @constCast("#abcdef"),
        .dir = .right,
        .conn = &connection,
    };
    defer player.snake.deinit(galloc);
    try player.snake.append(galloc, .{ .x = GRID_W - model.CELL, .y = 10 * model.CELL });
    var lobby = Lobby{ .id = @constCast("solid"), .food = .{ .x = 0, .y = 0 } };
    const players = [_]*Player{&player};
    var collision_index = collision.Index.build(&players);
    try std.testing.expect(applyMoveAndCheckWall(&lobby, &player, 0, &collision_index));
    try std.testing.expectEqual(GRID_W, player.snake.items[0].x);

    player.snake.items[0].x = 0;
    player.dir = .left;
    collision_index = collision.Index.build(&players);
    try std.testing.expect(applyMoveAndCheckWall(&lobby, &player, 0, &collision_index));
    try std.testing.expectEqual(-model.CELL, player.snake.items[0].x);
}

test "wrap walls transport heads across every arena edge" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var player = Player{
        .id = @constCast("sid"),
        .name = @constCast("name"),
        .color_hex = @constCast("#abcdef"),
        .dir = .right,
        .conn = &connection,
    };
    defer player.snake.deinit(galloc);
    try player.snake.append(galloc, .{ .x = GRID_W - CELL, .y = 10 * CELL });
    var lobby = Lobby{
        .id = @constCast("wrap"),
        .wrap_walls = true,
        .food = .{ .x = 0, .y = 0 },
    };
    const players = [_]*Player{&player};
    var collision_index = collision.Index.build(&players);
    try std.testing.expect(!applyMoveAndCheckWall(&lobby, &player, 0, &collision_index));
    try std.testing.expectEqual(@as(i32, 0), player.snake.items[0].x);

    player.snake.items[0] = .{ .x = 0, .y = 10 * CELL };
    player.dir = .left;
    collision_index = collision.Index.build(&players);
    try std.testing.expect(!applyMoveAndCheckWall(&lobby, &player, 0, &collision_index));
    try std.testing.expectEqual(GRID_W - CELL, player.snake.items[0].x);

    player.snake.items[0] = .{ .x = 10 * CELL, .y = 0 };
    player.dir = .up;
    collision_index = collision.Index.build(&players);
    try std.testing.expect(!applyMoveAndCheckWall(&lobby, &player, 0, &collision_index));
    try std.testing.expectEqual(GRID_H - CELL, player.snake.items[0].y);

    player.snake.items[0] = .{ .x = 10 * CELL, .y = GRID_H - CELL };
    player.dir = .down;
    collision_index = collision.Index.build(&players);
    try std.testing.expect(!applyMoveAndCheckWall(&lobby, &player, 0, &collision_index));
    try std.testing.expectEqual(@as(i32, 0), player.snake.items[0].y);
}

test "Arcade wraps before authoritative death classification" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var player = Player{
        .id = @constCast("sid"),
        .name = @constCast("name"),
        .color_hex = @constCast("#abcdef"),
        .dir = .right,
        .conn = &connection,
    };
    defer player.snake.deinit(galloc);
    try player.snake.append(galloc, .{ .x = GRID_W - CELL, .y = 10 * CELL });
    var lobby = Lobby{
        .id = @constCast("wrap-v2"),
        .mode = .arcade,
        .wrap_walls = true,
        .food = .{ .x = 20 * CELL, .y = 20 * CELL },
    };
    defer lobby.players.deinit(galloc);
    try lobby.players.append(galloc, &player);

    simulateArcadeLocked(&lobby, 1000, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), lobby.players.items.len);
    try std.testing.expectEqual(@as(i32, 0), player.snake.items[0].x);
    try std.testing.expectEqual(@as(i32, 10 * CELL), player.snake.items[0].y);
}

test "collision deaths belong to attackers rather than body owners" {
    var connection = Conn{ .fd = -1 };
    var owner_cells = [_]model.CellPos{
        .{ .x = 64, .y = 64 },
        .{ .x = 48, .y = 64 },
        .{ .x = 32, .y = 64 },
    };
    var attacker_cells = [_]model.CellPos{.{ .x = 32, .y = 64 }};
    var second_attacker_cells = [_]model.CellPos{.{ .x = 48, .y = 64 }};
    var owner = Player{
        .id = @constCast("owner"),
        .name = @constCast("owner"),
        .color_hex = @constCast("#abcdef"),
        .snake = .{ .items = &owner_cells, .capacity = owner_cells.len },
        .conn = &connection,
    };
    var attacker = Player{
        .id = @constCast("attacker"),
        .name = @constCast("attacker"),
        .color_hex = @constCast("#fedcba"),
        .snake = .{ .items = &attacker_cells, .capacity = attacker_cells.len },
        .conn = &connection,
    };
    var second_attacker = Player{
        .id = @constCast("attacker-2"),
        .name = @constCast("attacker-2"),
        .color_hex = @constCast("#ffffff"),
        .snake = .{ .items = &second_attacker_cells, .capacity = second_attacker_cells.len },
        .conn = &connection,
    };

    const players = [_]*Player{ &owner, &attacker, &second_attacker };
    const scan_index = collision.Index.build(&players);
    const scan_deaths = startingCollisionDeaths(&players, &scan_index);
    try std.testing.expect(!scan_deaths[0]);
    try std.testing.expect(scan_deaths[1]);
    try std.testing.expect(scan_deaths[2]);

    const indexed = collision.Index.buildForced(&players);
    const indexed_deaths = startingCollisionDeaths(&players, &indexed);
    try std.testing.expectEqualSlices(bool, scan_deaths[0..players.len], indexed_deaths[0..players.len]);

    const reversed = [_]*Player{ &attacker, &second_attacker, &owner };
    const reversed_index = collision.Index.build(&reversed);
    const reversed_deaths = startingCollisionDeaths(&reversed, &reversed_index);
    try std.testing.expect(reversed_deaths[0]);
    try std.testing.expect(reversed_deaths[1]);
    try std.testing.expect(!reversed_deaths[2]);
}

test "head-to-head and mutual body collisions kill every attacker simultaneously" {
    var connection = Conn{ .fd = -1 };
    var a_cells = [_]model.CellPos{
        .{ .x = 80, .y = 80 },
        .{ .x = 96, .y = 80 },
    };
    var b_cells = [_]model.CellPos{
        .{ .x = 80, .y = 80 },
        .{ .x = 64, .y = 80 },
    };
    var a = Player{
        .id = @constCast("a"),
        .name = @constCast("a"),
        .color_hex = @constCast("#abcdef"),
        .snake = .{ .items = &a_cells, .capacity = a_cells.len },
        .conn = &connection,
    };
    var b = Player{
        .id = @constCast("b"),
        .name = @constCast("b"),
        .color_hex = @constCast("#fedcba"),
        .snake = .{ .items = &b_cells, .capacity = b_cells.len },
        .conn = &connection,
    };
    const players = [_]*Player{ &a, &b };
    var index = collision.Index.build(&players);
    var deaths = startingCollisionDeaths(&players, &index);
    try std.testing.expect(deaths[0] and deaths[1]);

    a_cells = .{
        .{ .x = 64, .y = 64 },
        .{ .x = 80, .y = 64 },
    };
    b_cells = .{
        .{ .x = 80, .y = 64 },
        .{ .x = 64, .y = 64 },
    };
    index = collision.Index.buildForced(&players);
    deaths = startingCollisionDeaths(&players, &index);
    try std.testing.expect(deaths[0] and deaths[1]);
}

test "mode parsing defaults to arcade and rejects legacy and unknown values" {
    try std.testing.expectEqual(model.GameMode.arcade, parseGameMode(null, false).?);
    try std.testing.expectEqual(model.GameMode.classical, parseGameMode(null, true).?);
    try std.testing.expectEqual(model.GameMode.classical, parseGameMode("classical", false).?);
    try std.testing.expectEqual(model.GameMode.arcade, parseGameMode("arcade", false).?);
    try std.testing.expect(parseGameMode("arcade-v1", false) == null);
    try std.testing.expect(parseGameMode("arcade_v2", false) == null);
    try std.testing.expect(parseGameMode("future-mode", false) == null);
}

test "wall rule parsing defaults solid and rejects unknown values" {
    try std.testing.expectEqual(@as(?bool, false), parseWrapWalls(null));
    try std.testing.expectEqual(@as(?bool, false), parseWrapWalls("solid"));
    try std.testing.expectEqual(@as(?bool, true), parseWrapWalls("wrap"));
    try std.testing.expect(parseWrapWalls("portal") == null);
}

test "public Quick Join target is private by default and strictly bounded" {
    try std.testing.expectEqual(@as(?u8, 0), parsePublicTarget(null));
    try std.testing.expectEqual(@as(?u8, 0), parsePublicTarget("0"));
    try std.testing.expectEqual(@as(?u8, 2), parsePublicTarget("2"));
    try std.testing.expectEqual(@as(?u8, 16), parsePublicTarget("16"));
    try std.testing.expectEqual(@as(?u8, 32), parsePublicTarget("32"));
    try std.testing.expect(parsePublicTarget("1") == null);
    try std.testing.expect(parsePublicTarget("33") == null);
    try std.testing.expect(parsePublicTarget("many") == null);
}

test "lobby capacity defaults to 16 and accepts only supported sizes" {
    try std.testing.expectEqual(binary_snapshot.MAX_PLAYERS, DEFAULT_MAX_PLAYERS_GLOBAL);
    try std.testing.expectEqual(binary_snapshot.MAX_PLAYERS, DEFAULT_MAX_PLAYERS_PER_LOBBY);
    try std.testing.expectEqual(@as(?u8, 16), parseLobbyCapacity(null));
    try std.testing.expectEqual(@as(?u8, 16), parseLobbyCapacity(""));
    try std.testing.expectEqual(@as(?u8, 16), parseLobbyCapacity("16"));
    try std.testing.expectEqual(@as(?u8, 32), parseLobbyCapacity("32"));
    try std.testing.expect(parseLobbyCapacity("2") == null);
    try std.testing.expect(parseLobbyCapacity("64") == null);
}

test "public landing status JSON is compact exact and bounded" {
    var storage: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"players\":0,\"lobbies\":1}",
        try writePublicStatus(&storage, 0, 1),
    );
    const maximum = try writePublicStatus(&storage, std.math.maxInt(usize), std.math.maxInt(usize));
    try std.testing.expect(maximum.len <= storage.len);
    try std.testing.expect(std.mem.startsWith(u8, maximum, "{\"players\":"));
    try std.testing.expect(std.mem.endsWith(u8, maximum, "}"));
}

test "Arcade collision credit requires one non-head body owner" {
    var connection = Conn{ .fd = -1 };
    var owner_cells = [_]CellPos{
        .{ .x = 10 * CELL, .y = 10 * CELL },
        .{ .x = 9 * CELL, .y = 10 * CELL },
    };
    var attacker_cells = [_]CellPos{.{ .x = 9 * CELL, .y = 10 * CELL }};
    var owner = Player{
        .id = @constCast("owner"),
        .name = @constCast("owner"),
        .color_hex = @constCast("#fff"),
        .snake = .{ .items = &owner_cells, .capacity = owner_cells.len },
        .conn = &connection,
    };
    var attacker = Player{
        .id = @constCast("attacker"),
        .name = @constCast("attacker"),
        .color_hex = @constCast("#000"),
        .snake = .{ .items = &attacker_cells, .capacity = attacker_cells.len },
        .conn = &connection,
    };
    const body_players = [_]*Player{ &owner, &attacker };
    var deaths = classifyDeaths(&body_players);
    try std.testing.expect(!deaths[0].dead);
    try std.testing.expect(deaths[1].dead);
    try std.testing.expectEqual(@as(?usize, 0), deaths[1].killer_slot);

    attacker_cells[0] = owner_cells[0];
    deaths = classifyDeaths(&body_players);
    try std.testing.expect(deaths[0].dead and deaths[1].dead);
    try std.testing.expectEqual(@as(?usize, null), deaths[0].killer_slot);
    try std.testing.expectEqual(@as(?usize, null), deaths[1].killer_slot);
}

test "credited kill streak resets after fifteen seconds" {
    var connection = Conn{ .fd = -1 };
    var player = Player{
        .id = @constCast("id"),
        .name = @constCast("name"),
        .color_hex = @constCast("#fff"),
        .conn = &connection,
    };
    recordCreditedKill(&player, 1_000);
    recordCreditedKill(&player, 16_000);
    try std.testing.expectEqual(@as(u16, 2), player.streak);
    recordCreditedKill(&player, 31_001);
    try std.testing.expectEqual(@as(u16, 3), player.kills);
    try std.testing.expectEqual(@as(u16, 1), player.streak);
}

test "corpse remains are adaptively sampled capped and HUD safe" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var player = Player{
        .id = @constCast("id"),
        .name = @constCast("name"),
        .color_hex = @constCast("#fff"),
        .conn = &connection,
    };
    defer player.snake.deinit(galloc);
    for (0..64) |index| try player.snake.append(galloc, .{
        .x = @as(i32, @intCast(7 + index)) * CELL,
        .y = 40 * CELL,
    });
    var lobby = Lobby{
        .id = @constCast("v2"),
        .mode = .arcade,
        .food = .{ .x = 120 * CELL, .y = 60 * CELL },
    };
    defer lobby.remains.deinit(galloc);
    spawnCorpseRemainsLocked(&lobby, &player, 1000);
    try std.testing.expectEqual(@as(usize, CORPSE_REMAINS_MAX), lobby.remains.items.len);
    for (lobby.remains.items) |remain| {
        try std.testing.expect(objectiveCellSafe(remain.pos));
        try std.testing.expectEqual(@as(i64, 1000 + REMAINS_TTL_MS), remain.expires_at);
    }
}

test "three remains convert once and boost is one extra step every other held tick" {
    galloc = std.testing.allocator;
    var connection = Conn{ .fd = -1 };
    var player = Player{
        .id = @constCast("id"),
        .name = @constCast("name"),
        .color_hex = @constCast("#fff"),
        .boosting = true,
        .conn = &connection,
    };
    defer player.snake.deinit(galloc);
    for (0..6) |index| try player.snake.append(galloc, .{
        .x = @as(i32, @intCast(30 - index)) * CELL,
        .y = 40 * CELL,
    });
    var lobby = Lobby{
        .id = @constCast("v2"),
        .mode = .arcade,
        .food = .{ .x = 100 * CELL, .y = 50 * CELL },
    };
    defer lobby.remains.deinit(galloc);
    for (0..3) |_| try lobby.remains.append(galloc, .{
        .pos = player.snake.items[0],
        .expires_at = 20_000,
    });
    collectAtHeadLocked(&lobby, &player, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), player.score);
    try std.testing.expectEqual(@as(i64, 1), player.pending_growth);
    try std.testing.expectEqual(@as(u2, 0), player.mass_progress);

    // Spend the pending growth first at the fifteenth held tick.
    var extra_steps: usize = 0;
    for (0..BOOST_COST_TICKS) |_| {
        if (arcadeBoostEligibleLocked(&lobby, &player, 1000)) extra_steps += 1;
    }
    try std.testing.expectEqual(@as(usize, BOOST_COST_TICKS / 2), extra_steps);
    try std.testing.expectEqual(@as(i64, 0), player.pending_growth);
    try std.testing.expectEqual(@as(usize, 6), player.snake.items.len);
    try std.testing.expectEqual(@as(usize, 0), lobby.remains.items.len);

    // The next complete cost window sheds exactly one real tail cell.
    for (0..BOOST_COST_TICKS) |_| _ = arcadeBoostEligibleLocked(&lobby, &player, 2000);
    try std.testing.expectEqual(@as(usize, BOOST_MIN_CELLS), player.snake.items.len);
    try std.testing.expectEqual(@as(usize, 1), lobby.remains.items.len);
}

test "death spectator releases active capacity but retains global lobby capacity" {
    galloc = std.testing.allocator;
    g_io = std.testing.io;
    total_players.store(1, .release);
    total_lobby_members.store(1, .release);
    defer total_players.store(0, .release);
    defer total_lobby_members.store(0, .release);
    var connection = Conn{ .fd = -1 };
    const player = try galloc.create(Player);
    player.* = .{
        .id = "retained-id",
        .name = try galloc.dupe(u8, "retained-name"),
        .color_hex = try galloc.dupe(u8, "#e53935"),
        .conn = &connection,
    };
    try player.snake.append(galloc, .{ .x = 20 * CELL, .y = 20 * CELL });
    var lobby = Lobby{ .id = @constCast("spectate"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(galloc);
    defer lobby.spectators.deinit(galloc);
    try lobby.players.append(galloc, player);
    connection.player = player;
    connection.lobby = &lobby;

    movePlayerToSpectatorsLocked(&lobby, player, .{ .x = 20 * CELL, .y = 20 * CELL }, 7, 1000);
    try std.testing.expectEqual(@as(usize, 0), lobby.players.items.len);
    try std.testing.expectEqual(@as(usize, 1), lobby.spectators.items.len);
    try std.testing.expect(connection.player == player and connection.lobby == &lobby);
    try std.testing.expectEqual(@as(usize, 0), player.snake.items.len);
    try std.testing.expectEqual(@as(i64, 1000 + SPECTATE_FOCUS_MS), connection.spectating_until);
    try std.testing.expectEqual(@as(usize, 0), total_players.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), total_lobby_members.load(.acquire));
    evictSpectatorLocked(&lobby, 0);
    try std.testing.expect(connection.player == null and connection.lobby == null);
    try std.testing.expectEqual(@as(usize, 0), total_lobby_members.load(.acquire));
}

test "retry publication failure preserves game-over chat membership" {
    galloc = std.testing.allocator;
    g_io = std.testing.io;
    var connection = Conn{ .fd = -1 };
    var retained = Player{
        .id = "retained-id",
        .name = @constCast("retained-name"),
        .color_hex = @constCast("#ff6b6b"),
        .conn = &connection,
    };
    var replacement = Player{
        .id = "retained-id",
        .name = @constCast("replacement-name"),
        .color_hex = @constCast("#4dabf7"),
        .conn = &connection,
    };
    var lobby = Lobby{ .id = @constCast("retry"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(std.testing.allocator);
    defer lobby.spectators.deinit(std.testing.allocator);
    try lobby.spectators.append(std.testing.allocator, &connection);
    connection.player = &retained;
    connection.lobby = &lobby;
    connection.spectate_focus = .{ .x = 10 * CELL, .y = 10 * CELL };
    connection.spectate_score = 9;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    galloc = failing.allocator();
    const result = publishPreparedPlayerLocked(&lobby, &connection, &replacement, &retained);
    galloc = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, result);

    try std.testing.expectEqual(@as(usize, 0), lobby.players.items.len);
    try std.testing.expectEqual(@as(usize, 1), lobby.spectators.items.len);
    try std.testing.expect(connection.player == &retained and connection.lobby == &lobby);
    try std.testing.expect(connection.spectate_focus != null);
    try std.testing.expectEqual(@as(i64, 9), connection.spectate_score);
}

test "retained lobby members enforce the global capacity" {
    const previous_max = max_players_global;
    defer max_players_global = previous_max;
    defer total_lobby_members.store(0, .release);
    max_players_global = 2;
    total_lobby_members.store(1, .release);
    try std.testing.expect(serverHasRetainedCapacity());
    total_lobby_members.store(2, .release);
    try std.testing.expect(!serverHasRetainedCapacity());
}

test "quick join target counts active snakes and ignores chat spectators" {
    galloc = std.testing.allocator;
    const previous_per_lobby = max_players_per_lobby;
    defer max_players_per_lobby = previous_per_lobby;
    max_players_per_lobby = binary_snapshot.MAX_PLAYERS;

    var connection = Conn{ .fd = -1 };
    var first = Player{ .id = "one", .name = @constCast("one"), .color_hex = @constCast("#fff"), .conn = &connection };
    var second = Player{ .id = "two", .name = @constCast("two"), .color_hex = @constCast("#eee"), .conn = &connection };
    var lobby = Lobby{
        .id = @constCast("public"),
        .public_target = 2,
        .food = .{ .x = 0, .y = 0 },
    };
    defer lobby.players.deinit(galloc);
    defer lobby.spectators.deinit(galloc);
    try lobby.players.append(galloc, &first);
    try lobby.spectators.append(galloc, &connection);
    try std.testing.expect(quickJoinEligibleLocked(&lobby));
    try lobby.players.append(galloc, &second);
    try std.testing.expect(!quickJoinEligibleLocked(&lobby));
}

test "empty generated lobby survives the full thirty minute waiting window" {
    const created_at: i64 = 123_456;
    const ttl = config.LOBBY_IDLE_DELETE_MS;
    try std.testing.expectEqual(@as(i64, 30 * 60_000), ttl);
    try std.testing.expect(!idleLobbyExpired(true, created_at, created_at + ttl - 1, ttl));
    try std.testing.expect(idleLobbyExpired(true, created_at, created_at + ttl, ttl));
    try std.testing.expect(!idleLobbyExpired(false, created_at, created_at + ttl, ttl));
}

test "quick join respects the creator-selected lobby capacity" {
    var connection = Conn{ .fd = -1 };
    var first = Player{ .id = "one", .name = @constCast("one"), .color_hex = @constCast("#fff"), .conn = &connection };
    var second = Player{ .id = "two", .name = @constCast("two"), .color_hex = @constCast("#eee"), .conn = &connection };
    var lobby = Lobby{
        .id = @constCast("capacity"),
        .public_target = 32,
        .max_players = 2,
        .food = .{ .x = 0, .y = 0 },
    };
    defer lobby.players.deinit(std.testing.allocator);
    try lobby.players.append(std.testing.allocator, &first);
    try std.testing.expect(quickJoinEligibleLocked(&lobby));
    try lobby.players.append(std.testing.allocator, &second);
    try std.testing.expect(!quickJoinEligibleLocked(&lobby));
}

test "dead members stop receiving snapshots at the advertised cutoff" {
    var connection = Conn{ .fd = -1, .spectating_until = 12_000 };
    try std.testing.expect(spectatorReceivesSnapshot(&connection, 11_999));
    try std.testing.expect(!spectatorReceivesSnapshot(&connection, 12_000));
    try std.testing.expect(!spectatorReceivesSnapshot(&connection, 12_001));

    var lobby = Lobby{ .id = @constCast("worker-cutoff"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.spectators.deinit(std.testing.allocator);
    try lobby.spectators.append(std.testing.allocator, &connection);
    try std.testing.expect(lobbyNeedsGameWorkerLocked(&lobby, 11_999));
    try std.testing.expect(!lobbyNeedsGameWorkerLocked(&lobby, 12_000));
}

test "chat token bucket is bounded and refills lazily" {
    var connection = Conn{ .fd = -1, .chat_last_refill_ms = 1000 };
    var lobby = Lobby{ .id = @constCast("chat-rate"), .food = .{ .x = 0, .y = 0 }, .chat_last_refill_ms = 1000 };
    for (0..model.CHAT_TOKEN_CAPACITY) |_| try std.testing.expect(consumeChatToken(&connection, &lobby, 1000));
    try std.testing.expect(!consumeChatToken(&connection, &lobby, 1000));
    try std.testing.expect(!consumeChatToken(&connection, &lobby, 1000 + model.CHAT_REFILL_MS - 1));
    try std.testing.expect(consumeChatToken(&connection, &lobby, 1000 + model.CHAT_REFILL_MS));
    try std.testing.expect(!consumeChatToken(&connection, &lobby, 1000 + model.CHAT_REFILL_MS));
}

test "lobby chat bucket bounds reconnect amplification and refill boundaries" {
    var lobby = Lobby{ .id = @constCast("shared-chat-rate"), .food = .{ .x = 0, .y = 0 }, .chat_last_refill_ms = 1000 };
    var participants: [4]Conn = undefined;
    for (&participants) |*connection| connection.* = .{ .fd = -1, .chat_last_refill_ms = 1000 };

    // Three fresh connections can spend the shared burst, but a fourth fresh
    // identity cannot reset it by reconnecting.
    for (participants[0..3]) |*connection| {
        for (0..model.CHAT_TOKEN_CAPACITY) |_| try std.testing.expect(consumeChatToken(connection, &lobby, 1000));
    }
    try std.testing.expectEqual(@as(u8, 0), lobby.chat_tokens);
    try std.testing.expect(!consumeChatToken(&participants[3], &lobby, 1000));
    try std.testing.expectEqual(model.CHAT_TOKEN_CAPACITY, participants[3].chat_tokens);

    try std.testing.expect(!consumeChatToken(&participants[3], &lobby, 1000 + model.LOBBY_CHAT_REFILL_MS - 1));
    try std.testing.expect(consumeChatToken(&participants[3], &lobby, 1000 + model.LOBBY_CHAT_REFILL_MS));
    try std.testing.expect(!consumeChatToken(&participants[3], &lobby, 1000 + model.LOBBY_CHAT_REFILL_MS));

    // A long idle interval fills once and is fully accounted; it cannot be
    // replayed by multiple calls carrying the same timestamp.
    const later = 1000 + 100 * model.LOBBY_CHAT_REFILL_MS;
    refillChatBucket(&lobby.chat_tokens, &lobby.chat_last_refill_ms, later, model.LOBBY_CHAT_TOKEN_CAPACITY, model.LOBBY_CHAT_REFILL_MS);
    try std.testing.expectEqual(model.LOBBY_CHAT_TOKEN_CAPACITY, lobby.chat_tokens);
    lobby.chat_tokens = 0;
    refillChatBucket(&lobby.chat_tokens, &lobby.chat_last_refill_ms, later, model.LOBBY_CHAT_TOKEN_CAPACITY, model.LOBBY_CHAT_REFILL_MS);
    try std.testing.expectEqual(@as(u8, 0), lobby.chat_tokens);
}

test "shared keyframe coalescing preserves partial frames and controls" {
    galloc = std.testing.allocator;
    defer drainSnapshotPool();
    var connection = Conn{ .fd = -1 };
    defer connection.output.deinit(galloc);

    const partial = acquireSharedFrame().?;
    partial.keyframe = false;
    try partial.payload.appendSlice(galloc, "delta-a");
    partial.header_len = @intCast(wsHeader(&partial.header, 0x2, partial.payload.items.len));
    const stale = acquireSharedFrame().?;
    stale.keyframe = false;
    try stale.payload.appendSlice(galloc, "delta-b");
    stale.header_len = @intCast(wsHeader(&stale.header, 0x2, stale.payload.items.len));
    const fresh = acquireSharedFrame().?;
    fresh.keyframe = true;
    try fresh.payload.appendSlice(galloc, "keyframe");
    fresh.header_len = @intCast(wsHeader(&fresh.header, 0x2, fresh.payload.items.len));

    try std.testing.expect(appendSharedOutput(&connection, partial, 3));
    try std.testing.expect(appendSharedOutput(&connection, stale, 0));
    try std.testing.expect(appendOwnedOutput(&connection, "control", ""));
    try std.testing.expect(appendSharedOutput(&connection, fresh, 0));

    try std.testing.expectEqual(@as(usize, 3), connection.output.items.len);
    try std.testing.expectEqual(@as(usize, 3), connection.output_offset);
    try std.testing.expect(connection.output.items[0].shared == partial);
    try std.testing.expectEqualStrings("control", connection.output.items[1].owned);
    try std.testing.expect(connection.output.items[2].shared == fresh);
    try std.testing.expectEqual(partial.len() - 3 + "control".len + fresh.len(), connection.output_bytes);

    for (connection.output.items) |output| releasePending(output);
    connection.output.clearRetainingCapacity();
    releaseSharedFrame(partial);
    releaseSharedFrame(stale);
    releaseSharedFrame(fresh);
    try std.testing.expectEqual(@as(usize, 3), snapshot_pool.items.len);
    const reused = acquireSharedFrame().?;
    try std.testing.expectEqual(@as(usize, 2), snapshot_pool.items.len);
    releaseSharedFrame(reused);
    try std.testing.expectEqual(@as(usize, 3), snapshot_pool.items.len);
}

test "keyframe coalescing is stable and releases every stale shared reference once" {
    galloc = std.testing.allocator;
    defer drainSnapshotPool();
    var connection = Conn{ .fd = -1 };
    defer connection.output.deinit(galloc);

    // Retain a realistic consumed prefix to ensure coalescing touches only the
    // live suffix and preserves output_head/output_offset semantics.
    for (0..70) |_| try connection.output.append(galloc, .{ .borrowed = "consumed" });
    connection.output_head = 70;

    const partial = acquireSharedFrame().?;
    partial.keyframe = false;
    try partial.payload.appendSlice(galloc, "partial-delta");
    partial.header_len = @intCast(wsHeader(&partial.header, 0x2, partial.payload.items.len));
    retainSharedFrame(partial);
    try connection.output.append(galloc, .{ .shared = partial });
    connection.output_offset = 3;

    const stale = acquireSharedFrame().?;
    stale.keyframe = false;
    try stale.payload.appendSlice(galloc, "stale-delta");
    stale.header_len = @intCast(wsHeader(&stale.header, 0x2, stale.payload.items.len));

    const control_a = try galloc.dupe(u8, "control-a");
    const control_c = try galloc.dupe(u8, "control-c");
    const controls = [_]model.PendingOutput{
        .{ .owned = control_a },
        .{ .borrowed = "control-b" },
        .{ .owned = control_c },
        .{ .borrowed = "control-d" },
    };
    var control_bytes: usize = 0;
    for (controls) |control| control_bytes += control.len();

    for (controls) |control| {
        for (0..32) |_| {
            retainSharedFrame(stale);
            try connection.output.append(galloc, .{ .shared = stale });
        }
        try connection.output.append(galloc, control);
    }

    const stale_count: usize = 4 * 32;
    connection.output_bytes = partial.len() - connection.output_offset + stale_count * stale.len() + control_bytes;
    try std.testing.expectEqual(@as(usize, stale_count + 1), stale.refs.load(.monotonic));

    coalesceForKeyframe(&connection);

    try std.testing.expectEqual(@as(usize, 70), connection.output_head);
    try std.testing.expectEqual(@as(usize, 3), connection.output_offset);
    try std.testing.expectEqual(@as(usize, 75), connection.output.items.len);
    try std.testing.expect(connection.output.items[70].shared == partial);
    try std.testing.expectEqualStrings("control-a", connection.output.items[71].owned);
    try std.testing.expectEqualStrings("control-b", connection.output.items[72].borrowed);
    try std.testing.expectEqualStrings("control-c", connection.output.items[73].owned);
    try std.testing.expectEqualStrings("control-d", connection.output.items[74].borrowed);
    try std.testing.expectEqual(partial.len() - connection.output_offset + control_bytes, connection.output_bytes);
    try std.testing.expectEqual(@as(usize, 1), stale.refs.load(.monotonic));

    for (connection.output.items[connection.output_head..]) |output| releasePending(output);
    connection.output.clearRetainingCapacity();
    connection.output_head = 0;
    connection.output_offset = 0;
    connection.output_bytes = 0;
    releaseSharedFrame(partial);
    releaseSharedFrame(stale);
    try std.testing.expectEqual(@as(usize, 2), snapshot_pool.items.len);
}
