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
const COLS: i32 = GRID_W / CELL;
const ROWS: i32 = GRID_H / CELL;

const TICK_NS = config.TICK_NS;
const BACKGROUND_SNAPSHOT_MS = config.BACKGROUND_SNAPSHOT_MS;
const DEFAULT_MAX_PLAYERS_GLOBAL = config.DEFAULT_MAX_PLAYERS_GLOBAL;
const DEFAULT_MAX_PLAYERS_PER_LOBBY = config.DEFAULT_MAX_PLAYERS_PER_LOBBY;
const DEFAULT_MAX_LOBBIES = config.DEFAULT_MAX_LOBBIES;
const DEFAULT_LOBBIES_PER_WORKER = config.LOBBIES_PER_WORKER;
const GAME_WORKER_STACK = config.GAME_WORKER_STACK;
const DEFAULT_LOBBY_IDLE_DELETE_MS = config.LOBBY_IDLE_DELETE_MS;
const DEFAULT_LOBBY_ID = config.DEFAULT_LOBBY_ID;
const BONUS_CAP = config.BONUS_CAP;
const DROP_MAX = config.DROP_MAX;
const DROP_TTL_MS = config.DROP_TTL_MS;
const GOLDEN_TTL_MS = config.GOLDEN_TTL_MS;
const GOLDEN_POINTS = config.GOLDEN_POINTS;
const DROP_POINTS = config.DROP_POINTS;
const DROP_GROWTH = config.DROP_GROWTH;
const DROP_APPLES = config.DROP_APPLES;
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
var total_players: std.atomic.Value(usize) = .init(0);
var start_ms: i64 = 0;
var debug_enabled = false;
var shutting_down: std.atomic.Value(bool) = .init(false);
var listen_fd: posix.fd_t = -1;
var epoll_fd: posix.fd_t = -1;
var connections: std.AutoHashMapUnmanaged(posix.fd_t, *Conn) = .empty;
var network_bytes_sent: std.atomic.Value(u64) = .init(0);
var network_bytes_received: std.atomic.Value(u64) = .init(0);
var websocket_frames_sent: std.atomic.Value(u64) = .init(0);
var websocket_frames_received: std.atomic.Value(u64) = .init(0);
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
    _ = linux.clock_gettime(clock, &ts);
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

fn snakeOccupies(l: *Lobby, cell: CellPos) bool {
    for (l.players.values()) |p| {
        for (p.snake.items) |s| {
            if (s.x == cell.x and s.y == cell.y) return true;
        }
    }
    return false;
}

/// Free of snakes AND every pickup kind (SPEC "Free cell"), 200 attempts.
fn randomFreeCell(l: *Lobby) ?CellPos {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        const c = randomCell(l);
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
        if (!taken) return c;
    }
    return null;
}

/// Join spawn: avoid snakes (inner retries) and food, up to 100 attempts.
fn pickSpawnCell(l: *Lobby) CellPos {
    var pos = randomCell(l);
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        var t: usize = 0;
        while (t < 1000) : (t += 1) {
            pos = randomCell(l);
            if (!snakeOccupies(l, pos)) break;
        }
        if (!(pos.x == l.food.x and pos.y == l.food.y)) return pos;
    }
    return pos;
}

/// rcolor-style random hex colour (#rrggbb).
fn randomColorHex(aa: Allocator) []const u8 {
    const hue = rng_prng.random().float(f64) * 360.0;
    const sat = 0.5 + rng_prng.random().float(f64) * 0.25;
    const lig = 0.4 + rng_prng.random().float(f64) * 0.2;
    const q = lig + sat - (lig * sat);
    if (q == 0) return "#808080";
    const p = 2.0 * lig - q;
    const hk = @mod(hue, 360.0) / 360.0;
    const tr = hueToRgb(p, q, hk + (1.0 / 3.0));
    const tg = hueToRgb(p, q, hk);
    const tb = hueToRgb(p, q, hk - (1.0 / 3.0));
    return std.fmt.allocPrint(aa, "#{x:0>2}{x:0>2}{x:0>2}", .{
        colorByte(tr),
        colorByte(tg),
        colorByte(tb),
    }) catch "#808080";
}

fn colorByte(unit: f64) u8 {
    return @intFromFloat(std.math.clamp(unit, 0.0, 1.0) * 255.0);
}

fn hueToRgb(p: f64, q: f64, t_in: f64) f64 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + ((q - p) * 6.0 * t);
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + ((q - p) * (2.0 / 3.0 - t) * 6.0);
    return p;
}

// ------------------------------------------------------------------ collisions

fn collidedWall(h: CellPos) bool {
    return h.x > GRID_W - CELL or h.x < 0 or h.y > GRID_H - CELL or h.y < 0;
}

/// Exact high-cap override fallback. Canonical lobbies use collision.Index;
/// this retains semantics if an operator raises the cap above 16 players.
fn findCollidedOther(l: *Lobby, p: *Player) ?*Player {
    const head = p.snake.items[0];
    for (l.players.values()) |other| {
        if (other == p) continue;
        for (other.snake.items) |segment| {
            if (segment.x == head.x and segment.y == head.y) return other;
        }
    }
    return null;
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

fn prepareOutputAppend(c: *Conn) void {
    if (!outputEmpty(c)) return;
    c.output.clearRetainingCapacity();
    c.output_head = 0;
    c.output_offset = 0;
}

fn appendOwnedOutput(c: *Conn, first: []const u8, second: []const u8) bool {
    prepareOutputAppend(c);
    const size = first.len + second.len;
    if (c.output_bytes + size > MAX_QUEUE_BYTES) {
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
    if (c.output_bytes + bytes.len > MAX_QUEUE_BYTES) {
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
    var index: usize = c.output_head;
    while (index < c.output.items.len) {
        if (index == c.output_head and c.output_offset != 0) {
            index += 1;
            continue;
        }
        switch (c.output.items[index]) {
            .owned, .borrowed => index += 1,
            .shared => |frame| {
                c.output_bytes -= frame.len();
                releaseSharedFrame(frame);
                _ = c.output.orderedRemove(index);
            },
        }
    }
}

fn appendSharedOutput(c: *Conn, frame: *model.SharedFrame, offset: usize) bool {
    prepareOutputAppend(c);
    std.debug.assert(offset <= frame.len());
    if (frame.keyframe) coalesceForKeyframe(c);
    const remaining = frame.len() - offset;
    if (c.output_bytes + remaining > MAX_QUEUE_BYTES) {
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
            if (header_suffix.len > 0 and !appendOwnedOutput(connection, header_suffix, "")) return;
            if (body_suffix.len == 0) return;
            if (static) {
                _ = appendBorrowedOutput(connection, body_suffix);
            } else {
                _ = appendOwnedOutput(connection, body_suffix, "");
            }
        }
    }.append;

    if (!outputEmpty(c)) {
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

/// Fast path uses one writev syscall and performs no allocation or copy.
/// Infrequent control frames are copied only when a socket applies backpressure.
fn connEnqueueFrame(c: *Conn, opcode: u8, payload: []const u8) void {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    if (c.closing or c.poisoned) return;
    if (debug_enabled) _ = websocket_frames_sent.fetchAdd(1, .monotonic);
    var hdr: [10]u8 = undefined;
    const hlen = wsHeader(&hdr, opcode, payload.len);
    if (!outputEmpty(c)) {
        _ = appendOwnedOutput(c, hdr[0..hlen], payload);
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
                    _ = appendOwnedOutput(c, hdr[sent..hlen], payload);
                } else if (sent < hlen + payload.len) {
                    _ = appendOwnedOutput(c, payload[sent - hlen ..], "");
                }
                return;
            },
            .INTR => continue,
            .AGAIN => {
                _ = appendOwnedOutput(c, hdr[0..hlen], payload);
                return;
            },
            else => {
                c.poisoned = true;
                return;
            },
        }
    }
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
        _ = appendSharedOutput(c, frame, 0);
        return .{ .frames_sent = 1 };
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
                if (sent < frame.len()) _ = appendSharedOutput(c, frame, sent);
                return .{ .bytes_sent = sent, .frames_sent = 1 };
            },
            .INTR => continue,
            .AGAIN => {
                _ = appendSharedOutput(c, frame, 0);
                return .{ .frames_sent = 1 };
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

fn flushOutput(c: *Conn) bool {
    c.output_mutex.lockUncancelable(g_io);
    defer c.output_mutex.unlock(g_io);
    while (!outputEmpty(c)) {
        const output = c.output.items[c.output_head];
        const total = output.len();
        const rc = switch (output) {
            .owned => |bytes| linux.write(c.fd, bytes[c.output_offset..].ptr, total - c.output_offset),
            .borrowed => |bytes| linux.write(c.fd, bytes[c.output_offset..].ptr, total - c.output_offset),
            .shared => |frame| writeSharedFrame(c.fd, frame, c.output_offset),
        };
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                c.output_offset += sent;
                c.output_bytes -= sent;
                if (debug_enabled) _ = network_bytes_sent.fetchAdd(sent, .monotonic);
                if (c.output_offset == total) {
                    releasePending(output);
                    c.output_head += 1;
                    c.output_offset = 0;
                }
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }
    }
    c.output.clearRetainingCapacity();
    c.output_head = 0;
    updateConnInterest(c, false);
    return !c.close_after_write;
}

fn writeSharedFrame(fd: posix.fd_t, frame: *model.SharedFrame, offset: usize) usize {
    const hlen: usize = frame.header_len;
    if (offset >= hlen) {
        const payload_offset = offset - hlen;
        return linux.write(fd, frame.payload.items[payload_offset..].ptr, frame.payload.items.len - payload_offset);
    }
    const vec = [2]posix.iovec_const{
        .{ .base = frame.header[offset..hlen].ptr, .len = hlen - offset },
        .{ .base = frame.payload.items.ptr, .len = frame.payload.items.len },
    };
    return linux.writev(fd, &vec, vec.len);
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

fn broadcastLobby(l: *Lobby, frame: []const u8) void {
    for (l.players.values()) |p| connEnqueueText(p.conn, frame);
}

fn nextBackgroundSnapshot(now: i64) i64 {
    const interval = BACKGROUND_SNAPSHOT_MS;
    return now - @mod(now, interval) + interval;
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

    for (l.players.values()) |player| {
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
}

fn detachPlayer(l: *Lobby, p: *Player) void {
    if (!l.players.orderedRemove(p.id)) return;
    l.roster_dirty = true;
    _ = total_players.fetchSub(1, .acq_rel);
    p.conn.membership_mutex.lockUncancelable(g_io);
    p.conn.player = null; // allows same-socket rejoin (Retry without reload)
    p.conn.lobby = null;
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
    if (player) |p| {
        feedDeath(l, p, aa);
        detachPlayer(l, p);
        destroyPlayer(p);
    }
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
            if (lobby.players.count() > 0) tickLobby(lobby, tick_now, arena.allocator());
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
        total +|= worker_balance.estimatedLobbyCostNs(lobby.balance_ewma_ns, lobby.players.count());
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
        const cost = worker_balance.estimatedLobbyCostNs(lobby.balance_ewma_ns, lobby.players.count());
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
            const cost = worker_balance.estimatedLobbyCostNs(lobby.balance_ewma_ns, lobby.players.count());
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
/// players. Their ids remain joinable until the normal idle TTL expires; a
/// later join assigns a worker again before publishing the player.
fn deactivateEmptyLobbies() void {
    var worker_index: usize = 0;
    while (worker_index < game_workers.items.len) {
        const worker = game_workers.items[worker_index];
        worker.mutex.lockUncancelable(g_io);
        var lobby_index: usize = 0;
        while (lobby_index < worker.lobbies.items.len) {
            const lobby = worker.lobbies.items[lobby_index];
            lobby.mutex.lockUncancelable(g_io);
            const empty = lobby.players.count() == 0;
            if (empty) lobby.worker_assigned = false;
            lobby.mutex.unlock(g_io);
            if (empty) {
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
    l.drops.deinit(galloc);
    l.bonus.deinit(galloc);
    l.roster_wire.deinit(galloc);
    l.players.deinit(galloc);
    galloc.free(l.id);
    galloc.destroy(l);
}

fn createLobbyLocked(id: []u8) !*Lobby {
    const l = try galloc.create(Lobby);
    const seed = rng_prng.random().int(u64);
    l.* = .{ .id = id, .food = undefined };
    l.rng = std.Random.DefaultPrng.init(seed);
    l.food = randomCell(l);
    lobbies.put(galloc, id, l) catch |e| {
        galloc.destroy(l);
        return e;
    };
    return l;
}

fn feedDeath(l: *Lobby, p: *Player, aa: Allocator) void {
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"type\":\"death\",\"who\":") catch return;
    jsString(&args, aa, p.name) catch return;
    args.appendSlice(aa, ",\"score\":") catch return;
    jnum(&args, aa, p.score) catch return;
    args.appendSlice(aa, "}") catch return;
    const frame = eventFrame(aa, "feed", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

fn sendDeathEvent(c: *Conn, score: i64, aa: Allocator) void {
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.append(aa, ',') catch return;
    jnum(&args, aa, score) catch return;
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
    args.appendSlice(aa, ",{\"type\":\"golden\",\"who\":") catch return;
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
    p.color_hex = try galloc.dupe(u8, randomColorHex(aa));
    errdefer galloc.free(p.color_hex);
    try p.snake.append(galloc, pickSpawnCell(target));
    return p;
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

fn handleClientReady(c: *Conn, aa: Allocator, username_arg: ?[]const u8, lobby_arg: ?[]const u8) void {
    // Already playing on this socket: silently ignore (rejoin guard).
    c.membership_mutex.lockUncancelable(g_io);
    const already_playing = c.player != null;
    c.membership_mutex.unlock(g_io);
    if (already_playing) return;

    const bad_user = text.UsernameCheck{ .ok = false, .trimmed = "" };
    const chk = if (username_arg) |u| checkUsername(u) else bad_user;
    if (!chk.ok) {
        sendGameError(c, ERR_INVALID_USERNAME, aa);
        return;
    }
    const lobby = if (lobby_arg) |lid| lobbies.get(lid) else null;
    if (lobby == null) {
        sendGameError(c, ERR_UNKNOWN_GAME, aa);
        return;
    }
    const target = lobby.?;
    if (totalPlayersLocked() >= max_players_global) {
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    }
    target.mutex.lockUncancelable(g_io);

    // Recheck under the lobby ownership lock. This serializes joins with the
    // lobby worker and with disconnect/death cleanup.
    c.membership_mutex.lockUncancelable(g_io);
    const joined_while_waiting = c.player != null;
    c.membership_mutex.unlock(g_io);
    if (joined_while_waiting) {
        target.mutex.unlock(g_io);
        return;
    }
    if (totalPlayersLocked() >= max_players_global) {
        target.mutex.unlock(g_io);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    }
    if (target.players.count() >= max_players_per_lobby) {
        target.mutex.unlock(g_io);
        sendGameError(c, ERR_LOBBY_FULL, aa);
        return;
    }

    const p = createPlayerLocked(c, target, chk.trimmed, aa) catch {
        target.mutex.unlock(g_io);
        sendGameError(c, ERR_SERVER_FULL, aa);
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
    pf(&init_args, aa, ",{{\"scale\":16,\"food\":{{\"x\":{d},\"y\":{d}}}}}", .{ target.food.x, target.food.y }) catch {
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

    target.players.put(galloc, p.id, p) catch {
        discardPreparedPlayerLocked(target, p, activated_worker);
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    };
    _ = total_players.fetchAdd(1, .acq_rel);
    c.membership_mutex.lockUncancelable(g_io);
    c.player = p;
    c.lobby = target;
    c.membership_mutex.unlock(g_io);
    target.roster_dirty = true;
    target.last_empty_at = 0;

    // init goes to the joining socket only and remains ordered before the join
    // feed. Its frame was prepared before membership became externally visible.
    connEnqueueText(c, init_frame);

    // feed join to everyone in the room (including the joiner).
    var args: Buf = .empty;
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"type\":\"join\",\"who\":") catch return;
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
    c.membership_mutex.lockUncancelable(g_io);
    const player = if (c.lobby == l) c.player else null;
    c.membership_mutex.unlock(g_io);
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
    }
}

// ------------------------------------------------------------------ tick helpers

fn respawnFood(l: *Lobby) void {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        l.food = randomCell(l);
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
    args.appendSlice(aa, ",{\"type\":\"drop-open\",\"who\":") catch return;
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
    for (l.players.values(), 0..) |player, index| {
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

fn applyMoveAndCheckWall(player: *Player, slot: usize, collision_index: *collision.Index) bool {
    const before_move = collision.BeforeMove.capture(player);
    player.applyMove(galloc);
    collision_index.afterMove(slot, player, before_move);
    return collidedWall(player.snake.items[0]);
}

// ------------------------------------------------------------------ tick

fn tickLobby(l: *Lobby, now: i64, aa: Allocator) void {
    const t0 = monoNanos();

    // 1. expire pickups past their TTL
    {
        var di: usize = 0;
        while (di < l.drops.items.len) {
            if (l.drops.items[di].expires_at <= now) {
                _ = l.drops.orderedRemove(di);
            } else di += 1;
        }
        if (l.golden) |g| {
            if (g.expires_at <= now) l.golden = null;
        }
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

    // 3. per-player simulation, insertion order. Deaths are tombstoned and
    //    destroyed after the broadcast (the snapshot keeps borrowing them).
    const player_count = l.players.count();
    if (player_count > binary_snapshot.MAX_PLAYERS) return;
    var snapshot_storage: [binary_snapshot.MAX_PLAYERS]*Player = undefined;
    @memcpy(snapshot_storage[0..player_count], l.players.values());
    const snapshot = snapshot_storage[0..player_count];

    // Death processing mutates the ordered player map, so retain the initial
    // insertion order on the worker stack and destroy tombstones after fanout.
    var graveyard_storage: [binary_snapshot.MAX_PLAYERS]*Player = undefined;
    var graveyard_len: usize = 0;
    defer {
        for (graveyard_storage[0..graveyard_len]) |p| destroyPlayer(p);
    }
    var collision_index = collision.Index.build(snapshot);

    for (snapshot, 0..) |p, slot| {
        // skip players killed earlier in this same tick
        if (collision_index.tracksPlayers()) {
            if (!collision_index.isActive(slot)) continue;
        } else if (l.players.get(p.id) == null) continue;

        const head = p.snake.items[0];

        // a. wall / self collision
        if (collidedWall(head) or collision_index.selfHit(slot, p)) {
            sendDeathEvent(p.conn, p.score, aa);
            feedDeath(l, p, aa);
            collision_index.remove(slot, p);
            detachPlayer(l, p);
            graveyard_storage[graveyard_len] = p;
            graveyard_len += 1;
            continue;
        }

        // b. head vs any segment of another snake: both die
        const collision_hit: ?collision.Hit = if (collision_index.tracksPlayers())
            collision_index.otherAt(slot, p)
        else if (findCollidedOther(l, p)) |other|
            .{ .player = other, .slot = 0 }
        else
            null;
        if (collision_hit) |hit| {
            const other = hit.player;
            sendDeathEvent(p.conn, p.score, aa);
            sendDeathEvent(other.conn, other.score, aa);
            feedDeath(l, p, aa);
            feedDeath(l, other, aa);
            collision_index.remove(slot, p);
            collision_index.remove(hit.slot, other);
            detachPlayer(l, p);
            graveyard_storage[graveyard_len] = p;
            graveyard_len += 1;
            detachPlayer(l, other);
            graveyard_storage[graveyard_len] = other;
            graveyard_len += 1;
            continue;
        }

        // c. main food
        if (head.x == l.food.x and head.y == l.food.y) {
            p.eat(1, 1);
            respawnFood(l);
            broadcastUpdateFood(l, aa);
        }

        // d. bonus apples (every apple matching the head)
        {
            var bi = l.bonus.items.len;
            while (bi > 0) {
                bi -= 1;
                const bp = l.bonus.items[bi].pos;
                if (head.x == bp.x and head.y == bp.y) {
                    _ = l.bonus.swapRemove(bi);
                    p.eat(1, 1);
                }
            }
        }

        // e. golden apple
        if (l.golden) |g| {
            if (head.x == g.pos.x and head.y == g.pos.y) {
                l.golden = null;
                p.eat(GOLDEN_POINTS, 1);
                broadcastGoldenFeed(l, p, aa);
            }
        }

        // f. supply crates
        {
            var di = l.drops.items.len;
            while (di > 0) {
                di -= 1;
                const dp = l.drops.items[di].pos;
                if (head.x == dp.x and head.y == dp.y) {
                    _ = l.drops.swapRemove(di);
                    openDropLocked(l, p, aa);
                }
            }
        }

        // g. one queued turn, then move
        const crossed_wall = applyMoveAndCheckWall(p, slot, &collision_index);
        // Never publish an out-of-board head. The decoder deliberately rejects
        // invalid coordinates, so wall death must happen in the movement tick
        // rather than one snapshot later.
        if (crossed_wall) {
            sendDeathEvent(p.conn, p.score, aa);
            feedDeath(l, p, aa);
            collision_index.remove(slot, p);
            detachPlayer(l, p);
            graveyard_storage[graveyard_len] = p;
            graveyard_len += 1;
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

fn reapIdleLobbies(now: i64) void {
    var doomed: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (doomed.items) |dz| galloc.free(dz);
        doomed.deinit(galloc);
    }
    for (lobbies.values()) |l| {
        if (std.mem.eql(u8, l.id, DEFAULT_LOBBY_ID)) continue;
        l.mutex.lockUncancelable(g_io);
        const empty = l.players.count() == 0;
        if (!empty) {
            l.last_empty_at = 0;
        } else if (l.last_empty_at == 0) l.last_empty_at = now;
        const expired = empty and now - l.last_empty_at >= lobby_idle_delete_ms;
        l.mutex.unlock(g_io);
        if (expired) {
            const dup = galloc.dupe(u8, l.id) catch continue;
            doomed.append(galloc, dup) catch galloc.free(dup);
        }
    }
    for (doomed.items) |dz| {
        if (lobbies.fetchOrderedRemove(dz)) |kv| destroyLobby(kv.value);
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

fn buildStats(aa: Allocator) ![]u8 {
    const nsToUs = struct {
        fn convert(value: u64) f64 {
            return @as(f64, @floatFromInt(value)) / 1000.0;
        }
        fn average(total: u64, samples: u64) f64 {
            return if (samples == 0) 0 else convert(total) / @as(f64, @floatFromInt(samples));
        }
    };

    const worker_loads = try aa.alloc(stats_json.WorkerLoad, game_workers.items.len);
    for (game_workers.items, 0..) |worker, index| {
        worker.mutex.lockUncancelable(g_io);
        defer worker.mutex.unlock(g_io);
        worker_loads[index] = .{
            .lobbies = worker.lobbies.items.len,
            .estimatedTickUs = nsToUs.convert(workerEstimatedCostLocked(worker)),
        };
    }

    const lobby_stats = try aa.alloc(stats_json.LobbyStats, lobbies.count());
    var lobby_index: usize = 0;
    for (lobbies.values()) |l| {
        l.mutex.lockUncancelable(g_io);
        defer l.mutex.unlock(g_io);
        lobby_stats[lobby_index] = .{
            .id = l.id,
            .players = l.players.count(),
            .drops = l.drops.items.len,
            .bonus = l.bonus.items.len,
            .golden = l.golden != null,
            .lastTickMs = l.stats.last_tick_ms,
            .avgTickMs = l.stats.avg_tick_ms,
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

    return stats_json.encode(aa, .{
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
        .networkBytesReceived = network_bytes_received.load(.monotonic),
        .websocketFramesSent = websocket_frames_sent.load(.monotonic),
        .websocketFramesReceived = websocket_frames_received.load(.monotonic),
        .inputEvents = input_events,
        .avgInputEventUs = nsToUs.average(input_event_ns_total, input_events),
        .lobbies = lobby_stats[0..lobby_index],
    });
}

fn sendStats(c: *Conn, aa: Allocator, keep_alive: bool, head_only: bool) void {
    const js = buildStats(aa) catch {
        return sendServerError(c, aa);
    };
    defer aa.free(js);
    sendResponse(c, aa, .{
        .status = 200,
        .reason = "OK",
        .ctype = "application/json",
        .body = js,
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
            return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = assets.assets[0].ctype, .body = assets.index_html, .body_static = true, .keep_alive = keep_alive, .head_only = head_only });
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
                return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = "text/html; charset=utf-8", .body = assets.game_html, .body_static = true, .keep_alive = keep_alive, .head_only = head_only });
            }
            return sendRedirect(c, aa, 302, "/", keep_alive, head_only);
        }
        if (std.mem.eql(u8, dec_path, "/debug/stats")) {
            if (debug_enabled) return sendStats(c, aa, keep_alive, head_only);
            return sendNotFound(c, aa, keep_alive, head_only);
        }
        if (assets.find(dec_path)) |a| {
            return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = a.ctype, .body = a.body, .body_static = true, .keep_alive = keep_alive, .head_only = head_only });
        }
        return sendNotFound(c, aa, keep_alive, head_only);
    }

    if (is_post) {
        if (std.mem.eql(u8, dec_path, "/generateid")) {
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
            _ = createLobbyLocked(owned) catch {
                galloc.free(owned);
                return sendServerError(c, aa);
            };
            const enc = uriEncodeComponent(aa, new_id);
            const loc = std.fmt.allocPrint(aa, "/game/{s}", .{enc}) catch "/";
            return sendRedirect(c, aa, 303, loc, keep_alive, false);
        }
        if (std.mem.eql(u8, dec_path, "/joingame")) {
            var game_id: ?[]const u8 = null;
            if (body.len > 0) {
                if (body_is_json) game_id = extractJsonField(aa, body, "gameId");
                if (game_id == null) game_id = extractFormField(aa, body, "gameId");
            }
            var loc: []const u8 = "/?error=unknown-game";
            if (game_id) |raw| {
                const trimmed = jsTrim(raw);
                const exists = lobbies.contains(trimmed);
                if (exists) {
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
        .join => |join| handleClientReady(c, aa, join.username, join.lobby_id),
        .direction => |direction| handleKeyPress(c, direction),
        .visibility => |visible| handleVisibility(c, visible),
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
        if (debug_enabled) _ = websocket_frames_received.fetchAdd(1, .monotonic);

        switch (opcode) {
            0x1 => try websocket.validateTextPayload(payload), // text control packets are server-only
            0x2 => handleRawBinary(c, aa, payload),
            0x8 => { // close
                try websocket.validateClosePayload(payload);
                connEnqueueFrame(c, 0x8, payload);
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
    defer consumeInput(c, consumed);
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
                if (debug_enabled) _ = network_bytes_received.fetchAdd(count, .monotonic);
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
    _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, c.fd, null);
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
    setSockOpts(fd);
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

fn serviceHeartbeats(now: i64, arena: Allocator) void {
    var doomed: std.ArrayListUnmanaged(*Conn) = .empty;
    defer doomed.deinit(arena);
    var connection_it = connections.valueIterator();
    while (connection_it.next()) |connection_ptr| {
        const c = connection_ptr.*;
        if (connPoisoned(c)) {
            doomed.append(arena, c) catch {};
            continue;
        }
        if (c.mode == .http and now - c.last_activity_ms > HTTP_IDLE_MS) {
            doomed.append(arena, c) catch {};
            continue;
        }
        if (c.mode != .websocket) continue;
        if (c.awaiting_pong_since) |started| {
            if (now - started > PING_TIMEOUT_MS) {
                doomed.append(arena, c) catch {};
                continue;
            }
        }
        if (now >= c.next_ping_ms) {
            connEnqueueFrame(c, 0x9, "");
            c.awaiting_pong_since = now;
            c.next_ping_ms = now + PING_INTERVAL_MS;
        }
    }
    for (doomed.items) |c| teardownConn(c);
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
            serviceHeartbeats(now_ms, aa);
            reapIdleLobbies(now_ms);
            deactivateEmptyLobbies();
            rebalanceGameWorkers(now_ms, aa);
            next_maintenance = now_ms + 1000;
        }
    }
}

fn setSockOpts(fd: posix.fd_t) void {
    if (builtin.os.tag != .linux) return;
    const one: c_int = 1;
    posix.setsockopt(fd, 6, 1, std.mem.asBytes(&one)) catch {}; // TCP_NODELAY
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
    max_players_global = envUsize(init.minimal.environ, "SNEK_MAX_PLAYERS", DEFAULT_MAX_PLAYERS_GLOBAL, 100_000);
    max_players_per_lobby = envUsize(init.minimal.environ, "SNEK_MAX_PLAYERS_PER_LOBBY", DEFAULT_MAX_PLAYERS_PER_LOBBY, binary_snapshot.MAX_PLAYERS);
    max_players_per_lobby = @min(max_players_per_lobby, max_players_global);
    max_lobbies = envUsize(init.minimal.environ, "SNEK_MAX_LOBBIES", DEFAULT_MAX_LOBBIES, 100_000);
    lobbies_per_worker = envUsize(init.minimal.environ, "SNEK_LOBBIES_PER_WORKER", DEFAULT_LOBBIES_PER_WORKER, 10_000);
    lobby_idle_delete_ms = @intCast(envUsize(init.minimal.environ, "SNEK_LOBBY_IDLE_MS", @intCast(DEFAULT_LOBBY_IDLE_DELETE_MS), 24 * 60 * 60 * 1000));

    start_ms = unixMillis();
    const seed: u64 = @bitCast(monoNanos());
    rng_prng = std.Random.DefaultPrng.init(seed ^ @as(u64, @intCast(std.os.linux.getpid())));

    installSignalHandlers();

    const def_id = galloc.dupe(u8, DEFAULT_LOBBY_ID) catch unreachable;
    _ = createLobbyLocked(def_id) catch unreachable;

    const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    const srv = addr.listen(g_io, .{ .reuse_address = true }) catch |e| {
        std.debug.print("server error: {s}\n", .{@errorName(e)});
        return e;
    };
    listen_fd = srv.socket.handle;
    if (!setNonBlocking(listen_fd)) return error.NonBlockingSetupFailed;
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

test "color conversion clamps floating point edge values" {
    try std.testing.expectEqual(@as(u8, 0), colorByte(-0.000_001));
    try std.testing.expectEqual(@as(u8, 127), colorByte(0.5));
    try std.testing.expectEqual(@as(u8, 255), colorByte(1.000_001));
}

test "binary client packets reject malformed and partial input" {
    try std.testing.expect(websocket.clientPacket(&.{}) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 1, 5, 4, '1' }) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 1, 0, 1, 'x' }) == null);
    try std.testing.expect(websocket.clientPacket(&.{2}) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 2, 4 }) == null);
    try std.testing.expect(websocket.clientPacket(&.{3}) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 3, 2 }) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 3, 1, 0 }) == null);
    try std.testing.expect(websocket.clientPacket(&.{ 4, 0 }) == null);
    const joined = websocket.clientPacket(&.{ 1, 5, 4, '1', '2', '3', '4', '5', 'n', 'a', 'm', 'e' }).?;
    try std.testing.expectEqualStrings("12345", joined.join.lobby_id);
    try std.testing.expectEqualStrings("name", joined.join.username);
    try std.testing.expectEqual(Direction.left, websocket.clientPacket(&.{ 2, 2 }).?.direction);
    try std.testing.expectEqual(false, websocket.clientPacket(&.{ 3, 0 }).?.visibility);
    try std.testing.expectEqual(true, websocket.clientPacket(&.{ 3, 1 }).?.visibility);
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
    try lobby.players.put(galloc, player.id, &player);

    try std.testing.expectEqualStrings("[\"r\",[[\"sid\",\"name\",\"#abcdef\"]]]", try buildRoster(&lobby));
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(galloc);
    const result = try binary_snapshot.build(&wire, &lobby, 0, galloc);
    try std.testing.expectEqual(binary_snapshot.Kind.keyframe, result.kind);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', binary_snapshot.VERSION, 0 }, result.bytes[0..4]);
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
    const players = [_]*Player{&player};
    var collision_index = collision.Index.build(&players);
    try std.testing.expect(applyMoveAndCheckWall(&player, 0, &collision_index));
    try std.testing.expectEqual(GRID_W, player.snake.items[0].x);

    player.snake.items[0].x = 0;
    player.dir = .left;
    collision_index = collision.Index.build(&players);
    try std.testing.expect(applyMoveAndCheckWall(&player, 0, &collision_index));
    try std.testing.expectEqual(-model.CELL, player.snake.items[0].x);
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
