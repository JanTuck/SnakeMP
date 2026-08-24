//! Snek multiplayer server - Zig port.
//! Wire protocol: engine.io v3 (EIO=3) websocket transport carrying
//! socket.io v2 frames, per docs/SPEC.md. Standard library only.
//!
//! Architecture:
//!   - one edge-triggered epoll reactor owns HTTP, WebSocket, and game state;
//!   - direct writev on the ready-socket path, retained buffers only for
//!     backpressure, and reusable per-lobby serialization buffers;
//!   - one 66.67ms reactor deadline steps every lobby;
//!   - all public assets embedded at compile time via @embedFile.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const builtin = @import("builtin");
const assets = @import("assets_manifest.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Buf = std.ArrayListUnmanaged(u8);

// ------------------------------------------------------------------ tuning

const GRID_W: i32 = 1920; // logical units (120 cells)
const GRID_H: i32 = 960; // logical units (60 cells)
const CELL: i32 = model.CELL;
const COLS: i32 = GRID_W / CELL;
const ROWS: i32 = GRID_H / CELL;

const TICK_NS: u64 = 66_666_667; // 15 fps

const MAX_PLAYERS_GLOBAL: usize = 100;
const MAX_PLAYERS_PER_LOBBY: usize = 16;
const LOBBY_IDLE_DELETE_MS: i64 = 60_000;
const DEFAULT_LOBBY_ID = "12345";

const BONUS_CAP: usize = 12;
const DROP_MAX: usize = 2;
const DROP_TTL_MS: i64 = 25_000;
const GOLDEN_TTL_MS: i64 = 12_000;
const GOLDEN_POINTS: i64 = 3;
const DROP_POINTS: i64 = 2;
const DROP_GROWTH: i64 = 2;
const DROP_APPLES: usize = 4;

const PING_INTERVAL_MS: i64 = 20_000;
const PING_TIMEOUT_MS: i64 = 15_000;

const ERR_INVALID_USERNAME = "Invalid username";
const ERR_UNKNOWN_GAME = "That game does not exist any more";
const ERR_SERVER_FULL = "Server is full, try again later";
const ERR_LOBBY_FULL = "This game is full";

const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const SID_LEN = model.SID_LEN; // 16 random bytes -> base64url without padding

const MAX_HTTP_HEAD_LINE: usize = 16 * 1024;
const MAX_HTTP_BODY: usize = 1024 * 1024;
const MAX_WS_FRAME: u64 = 1024 * 1024;
const MAX_WS_INPUT: usize = 2 * 1024 * 1024;
const MAX_QUEUE_BYTES: usize = 4 * 1024 * 1024; // slow-consumer cutoff
const HTTP_IDLE_MS: i32 = 65_000;

// ------------------------------------------------------------------ state

var galloc: Allocator = undefined;
var tick_arena: std.heap.ArenaAllocator = undefined;

var g_io: std.Io = undefined;
var rng_prng: std.Random.DefaultPrng = undefined;
var lobbies: std.StringArrayHashMapUnmanaged(*Lobby) = .empty;
var start_ms: i64 = 0;
var debug_enabled = false;
var shutting_down = false;
var listen_fd: posix.fd_t = -1;
var epoll_fd: posix.fd_t = -1;
var connections: std.AutoHashMapUnmanaged(posix.fd_t, *Conn) = .empty;
var network_bytes_sent: u64 = 0;
var network_bytes_received: u64 = 0;
var websocket_frames_sent: u64 = 0;
var websocket_frames_received: u64 = 0;
var input_event_ns_total: u64 = 0;
var input_events: u64 = 0;

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

const Direction = model.Direction;
const CellPos = model.CellPos;
const Player = model.Player;
const Lobby = model.Lobby;
const Conn = model.Conn;

// ------------------------------------------------------------------ rng helpers

fn randomCell() CellPos {
    const cx = rng_prng.random().intRangeLessThan(i32, 0, COLS);
    const cy = rng_prng.random().intRangeLessThan(i32, 0, ROWS);
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
        const c = randomCell();
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
    var pos = randomCell();
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        var t: usize = 0;
        while (t < 1000) : (t += 1) {
            pos = randomCell();
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
        @as(u8, @intFromFloat(tr * 255.0)),
        @as(u8, @intFromFloat(tg * 255.0)),
        @as(u8, @intFromFloat(tb * 255.0)),
    }) catch "#808080";
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

fn collidedSelf(p: *Player) bool {
    const head = p.snake.items[0];
    for (p.snake.items[1..]) |seg| {
        if (seg.x == head.x and seg.y == head.y) return true;
    }
    return false;
}

fn findCollidedOther(l: *Lobby, p: *Player) ?*Player {
    const head = p.snake.items[0];
    for (l.players.values()) |o| {
        if (o == p) continue;
        for (o.snake.items) |seg| {
            if (seg.x == head.x and seg.y == head.y) return o;
        }
    }
    return null;
}

// ------------------------------------------------------------------ json emit

fn jsString(b: *Buf, aa: Allocator, s: []const u8) !void {
    try b.append(aa, '"');
    for (s) |ch| {
        switch (ch) {
            '"', '\\' => {
                try b.append(aa, '\\');
                try b.append(aa, ch);
            },
            0x08 => try b.appendSlice(aa, "\\b"),
            0x0C => try b.appendSlice(aa, "\\f"),
            '\n' => try b.appendSlice(aa, "\\n"),
            '\r' => try b.appendSlice(aa, "\\r"),
            '\t' => try b.appendSlice(aa, "\\t"),
            else => {
                if (ch < 0x20) {
                    var tmp: [8]u8 = undefined;
                    const t = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{ch}) catch unreachable;
                    try b.appendSlice(aa, t);
                } else {
                    try b.append(aa, ch); // UTF-8 passes through untouched
                }
            },
        }
    }
    try b.append(aa, '"');
}

fn jnum(b: *Buf, aa: Allocator, v: anytype) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    try b.appendSlice(aa, s);
}

fn jstrField(b: *Buf, aa: Allocator, name: []const u8, value: []const u8) !void {
    try b.append(aa, '"');
    try b.appendSlice(aa, name);
    try b.appendSlice(aa, "\":");
    try jsString(b, aa, value);
}

/// socket.io event frame: 42["<event>"<args-json>]
fn eventFrame(aa: Allocator, event: []const u8, args_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(aa, "42[\"{s}\"{s}]", .{ event, args_json });
}

// ------------------------------------------------------------------ connection

fn wsHeader(hdr: *[10]u8, opcode: u8, len: usize) usize {
    hdr[0] = 0x80 | opcode; // FIN + opcode, unmasked (server -> client)
    if (len < 126) {
        hdr[1] = @intCast(len);
        return 2;
    }
    if (len <= 0xFFFF) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(len), .big);
        return 4;
    }
    hdr[1] = 127;
    std.mem.writeInt(u64, hdr[2..10], len, .big);
    return 10;
}

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

fn appendOutput(c: *Conn, bytes: []const u8) bool {
    const pending = c.output.items.len - c.output_offset;
    if (pending + bytes.len > MAX_QUEUE_BYTES) {
        c.poisoned = true;
        return false;
    }
    if (pending == 0) {
        c.output.clearRetainingCapacity();
        c.output_offset = 0;
    }
    c.output.appendSlice(galloc, bytes) catch {
        c.poisoned = true;
        return false;
    };
    updateConnInterest(c, true);
    return true;
}

/// Write immediately when the socket is ready; retain only the unsent suffix.
fn connQueueRaw(c: *Conn, bytes: []const u8) void {
    if (c.closing or c.poisoned or bytes.len == 0) return;
    if (c.output.items.len != c.output_offset) {
        _ = appendOutput(c, bytes);
        return;
    }
    while (true) {
        const rc = linux.write(c.fd, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                network_bytes_sent +%= sent;
                if (sent < bytes.len) _ = appendOutput(c, bytes[sent..]);
                return;
            },
            .INTR => continue,
            .AGAIN => {
                _ = appendOutput(c, bytes);
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
/// Backpressure copies only the unsent suffix into the retained output buffer.
fn connEnqueueFrame(c: *Conn, opcode: u8, payload: []const u8) void {
    if (c.closing or c.poisoned) return;
    websocket_frames_sent +%= 1;
    var hdr: [10]u8 = undefined;
    const hlen = wsHeader(&hdr, opcode, payload.len);
    if (c.output.items.len != c.output_offset) {
        if (appendOutput(c, hdr[0..hlen])) _ = appendOutput(c, payload);
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
                network_bytes_sent +%= sent;
                if (sent < hlen) {
                    if (appendOutput(c, hdr[sent..hlen])) _ = appendOutput(c, payload);
                } else if (sent < hlen + payload.len) {
                    _ = appendOutput(c, payload[sent - hlen ..]);
                }
                return;
            },
            .INTR => continue,
            .AGAIN => {
                if (appendOutput(c, hdr[0..hlen])) _ = appendOutput(c, payload);
                return;
            },
            else => {
                c.poisoned = true;
                return;
            },
        }
    }
}

fn connEnqueueText(c: *Conn, payload: []const u8) void {
    connEnqueueFrame(c, 0x1, payload);
}

fn flushOutput(c: *Conn) bool {
    while (c.output_offset < c.output.items.len) {
        const pending = c.output.items[c.output_offset..];
        const rc = linux.write(c.fd, pending.ptr, pending.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                c.output_offset += sent;
                network_bytes_sent +%= sent;
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }
    }
    c.output.clearRetainingCapacity();
    c.output_offset = 0;
    updateConnInterest(c, false);
    return !c.close_after_write;
}

// ------------------------------------------------------- room operations

fn totalPlayersLocked() usize {
    var n: usize = 0;
    for (lobbies.values()) |l| n += l.players.count();
    return n;
}

fn broadcastLobby(l: *Lobby, frame: []const u8) void {
    for (l.players.values()) |p| connEnqueueText(p.conn, frame);
}

fn detachPlayer(l: *Lobby, p: *Player) void {
    _ = l.players.orderedRemove(p.id);
    l.roster_dirty = true;
    p.conn.player = null; // allows same-socket rejoin (Retry without reload)
    p.conn.lobby = null;
}

fn destroyPlayer(p: *Player) void {
    p.snake.deinit(galloc);
    galloc.free(p.id);
    galloc.free(p.name);
    galloc.free(p.color_hex);
    galloc.destroy(p);
}

fn destroyLobby(l: *Lobby) void {
    for (l.drops.items) |d| galloc.free(d.id);
    l.drops.deinit(galloc);
    l.bonus.deinit(galloc);
    l.wire.deinit(galloc);
    l.players.deinit(galloc);
    galloc.free(l.id);
    galloc.destroy(l);
}

fn createLobbyLocked(id: []u8) !*Lobby {
    const l = try galloc.create(Lobby);
    l.* = .{ .id = id, .food = randomCell() };
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

const UsernameCheck = struct {
    ok: bool,
    trimmed: []const u8,
};

fn isJsSpace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0B or cp == 0x0C or
        cp == 0x85 or cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or
        cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000 or cp == 0xFEFF;
}

/// Approximation of JS String.prototype.trim().
fn jsTrim(s: []const u8) []const u8 {
    var begin: usize = 0;
    var end: usize = s.len;
    while (begin < end) {
        const len = std.unicode.utf8ByteSequenceLength(s[begin]) catch break;
        if (begin + len > end) break;
        const cp = std.unicode.utf8Decode(s[begin .. begin + len]) catch break;
        if (!isJsSpace(cp)) break;
        begin += len;
    }
    while (end > begin) {
        var st = end - 1;
        while (st > begin and (s[st] & 0xC0) == 0x80) st -= 1;
        const len = std.unicode.utf8ByteSequenceLength(s[st]) catch break;
        if (st + len != end) break;
        const cp = std.unicode.utf8Decode(s[st..end]) catch break;
        if (!isJsSpace(cp)) break;
        end = st;
    }
    return s[begin..end];
}

/// ^[\p{L}\p{N}_\- ]+$ on the trimmed value, length 4..16 codepoints.
/// Deviation (documented): any codepoint >= U+0080 counts as letter/number.
fn checkUsername(raw: []const u8) UsernameCheck {
    const t = jsTrim(raw);
    var count: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        const len = std.unicode.utf8ByteSequenceLength(t[i]) catch return .{ .ok = false, .trimmed = t };
        if (i + len > t.len) return .{ .ok = false, .trimmed = t };
        const cp = std.unicode.utf8Decode(t[i .. i + len]) catch return .{ .ok = false, .trimmed = t };
        const allowed =
            cp == '_' or cp == '-' or cp == ' ' or
            (cp >= '0' and cp <= '9') or
            (cp >= 'A' and cp <= 'Z') or
            (cp >= 'a' and cp <= 'z') or
            cp >= 0x80;
        if (!allowed) return .{ .ok = false, .trimmed = t };
        count += 1;
        i += len;
    }
    return .{ .ok = count >= 4 and count <= 16, .trimmed = t };
}

fn handleClientReady(c: *Conn, aa: Allocator, username_arg: ?[]const u8, lobby_arg: ?[]const u8) void {

    // Already playing on this socket: silently ignore (rejoin guard).
    if (c.player != null) return;

    const bad_user = UsernameCheck{ .ok = false, .trimmed = "" };
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
    if (totalPlayersLocked() >= MAX_PLAYERS_GLOBAL) {
        sendGameError(c, ERR_SERVER_FULL, aa);
        return;
    }
    if (lobby.?.players.count() >= MAX_PLAYERS_PER_LOBBY) {
        sendGameError(c, ERR_LOBBY_FULL, aa);
        return;
    }
    const target = lobby.?;

    // init goes to the joining socket only, before the join feed.
    {
        var args: Buf = .empty;
        defer args.deinit(aa);
        pf(&args, aa, ",{{\"scale\":16,\"food\":{{\"x\":{d},\"y\":{d}}}}}", .{ target.food.x, target.food.y }) catch return;
        const frame = eventFrame(aa, "init", args.items) catch return;
        defer aa.free(frame);
        connEnqueueText(c, frame);
    }

    const pos = pickSpawnCell(target);
    const col = randomColorHex(aa);

    const p = galloc.create(Player) catch return;
    p.* = .{
        .id = undefined,
        .name = undefined,
        .color_hex = undefined,
        .conn = c,
    };
    p.id = galloc.dupe(u8, c.sidSlice()) catch {
        galloc.destroy(p);
        return;
    };
    p.name = galloc.dupe(u8, chk.trimmed) catch {
        galloc.free(p.id);
        galloc.destroy(p);
        return;
    };
    p.color_hex = galloc.dupe(u8, col) catch {
        galloc.free(p.id);
        galloc.free(p.name);
        galloc.destroy(p);
        return;
    };
    p.snake.append(galloc, pos) catch {
        destroyPlayer(p);
        return;
    };

    c.player = p;
    c.lobby = target;
    target.players.put(galloc, p.id, p) catch {
        c.player = null;
        c.lobby = null;
        destroyPlayer(p);
        return;
    };
    target.roster_dirty = true;

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
    if (c.player) |p| _ = p.pushTurn(d);
}

// ------------------------------------------------------------------ tick helpers

fn respawnFood(l: *Lobby) void {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        l.food = randomCell();
        if (!snakeOccupies(l, l.food)) return;
    }
}

fn spawnDropLocked(l: *Lobby, now: i64, aa: Allocator) void {
    const cell = randomFreeCell(l) orelse return;
    const id = std.fmt.allocPrint(galloc, "drop-{d}", .{l.drop_seq}) catch return;
    l.drop_seq += 1;
    l.drops.append(galloc, .{ .id = id, .pos = cell, .expires_at = now + DROP_TTL_MS }) catch {
        galloc.free(id);
        return;
    };
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

inline fn appendCellCoord(b: *Buf, value: i32) !void {
    try jnum(b, galloc, @divTrunc(value, CELL));
}

/// Membership metadata is sent only when players join or leave. Player order
/// is then stable and acts as the key for compact snapshots.
fn buildRoster(l: *Lobby) ![]const u8 {
    l.wire.clearRetainingCapacity();
    try l.wire.appendSlice(galloc, "42[\"r\",[");
    for (l.players.values(), 0..) |p, i| {
        if (i != 0) try l.wire.append(galloc, ',');
        try l.wire.append(galloc, '[');
        try jsString(&l.wire, galloc, p.id);
        try l.wire.append(galloc, ',');
        try jsString(&l.wire, galloc, p.name);
        try l.wire.append(galloc, ',');
        try jsString(&l.wire, galloc, p.color_hex);
        try l.wire.append(galloc, ']');
    }
    try l.wire.appendSlice(galloc, "]]\n");
    return l.wire.items[0 .. l.wire.items.len - 1];
}

/// Compact tick: [players, bonus, drops, golden]. Coordinates are grid-cell
/// integers and the browser multiplies once by CELL while applying the tick.
fn buildGameTick(l: *Lobby, now: i64) ![]const u8 {
    l.wire.clearRetainingCapacity();
    try l.wire.appendSlice(galloc, "42[\"tick\",[[");
    for (l.players.values(), 0..) |p, pi| {
        if (pi != 0) try l.wire.append(galloc, ',');
        try l.wire.append(galloc, '[');
        try jnum(&l.wire, galloc, p.score);
        try l.wire.append(galloc, ',');
        try jnum(&l.wire, galloc, p.body_length);
        try l.wire.appendSlice(galloc, ",[");
        for (p.snake.items, 0..) |cell, ci| {
            if (ci != 0) try l.wire.append(galloc, ',');
            try appendCellCoord(&l.wire, cell.x);
            try l.wire.append(galloc, ',');
            try appendCellCoord(&l.wire, cell.y);
        }
        try l.wire.appendSlice(galloc, "]]");
    }
    try l.wire.appendSlice(galloc, "],[");
    for (l.bonus.items, 0..) |apple, i| {
        if (i != 0) try l.wire.append(galloc, ',');
        try appendCellCoord(&l.wire, apple.pos.x);
        try l.wire.append(galloc, ',');
        try appendCellCoord(&l.wire, apple.pos.y);
    }
    try l.wire.appendSlice(galloc, "],[");
    for (l.drops.items, 0..) |drop, i| {
        if (i != 0) try l.wire.append(galloc, ',');
        try l.wire.append(galloc, '[');
        try jsString(&l.wire, galloc, drop.id);
        try l.wire.append(galloc, ',');
        try appendCellCoord(&l.wire, drop.pos.x);
        try l.wire.append(galloc, ',');
        try appendCellCoord(&l.wire, drop.pos.y);
        try l.wire.append(galloc, ',');
        try jnum(&l.wire, galloc, @max(0, drop.expires_at - now));
        try l.wire.append(galloc, ']');
    }
    try l.wire.appendSlice(galloc, "],");
    if (l.golden) |golden| {
        try l.wire.append(galloc, '[');
        try appendCellCoord(&l.wire, golden.pos.x);
        try l.wire.append(galloc, ',');
        try appendCellCoord(&l.wire, golden.pos.y);
        try l.wire.append(galloc, ',');
        try jnum(&l.wire, galloc, @max(0, golden.expires_at - now));
        try l.wire.append(galloc, ']');
    } else try l.wire.appendSlice(galloc, "null");
    try l.wire.appendSlice(galloc, "]]\n");
    return l.wire.items[0 .. l.wire.items.len - 1];
}

// ------------------------------------------------------------------ tick

fn tickLobby(l: *Lobby, now: i64, aa: Allocator) void {
    const t0 = monoNanos();

    // 1. expire pickups past their TTL
    {
        var di: usize = 0;
        while (di < l.drops.items.len) {
            if (l.drops.items[di].expires_at <= now) {
                galloc.free(l.drops.items[di].id);
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
        l.next_drop_at = now + 12000 + rng_prng.random().intRangeLessThan(i64, 0, 8000);
    }
    if (now >= l.next_golden_at and l.golden == null) {
        spawnGoldenLocked(l, now);
        l.next_golden_at = now + 25000 + rng_prng.random().intRangeLessThan(i64, 0, 15000);
    }

    // 3. per-player simulation, insertion order. Deaths are tombstoned and
    //    destroyed after the broadcast (the snapshot keeps borrowing them).
    var graveyard: std.ArrayListUnmanaged(*Player) = .empty;
    defer {
        for (graveyard.items) |p| destroyPlayer(p);
        graveyard.deinit(galloc);
    }

    var snapshot: std.ArrayListUnmanaged(*Player) = .empty;
    defer snapshot.deinit(aa);
    snapshot.appendSlice(aa, l.players.values()) catch return;

    for (snapshot.items) |p| {
        // skip players killed earlier in this same tick
        if (l.players.get(p.id) == null) continue;

        const head = p.snake.items[0];

        // a. wall / self collision
        if (collidedWall(head) or collidedSelf(p)) {
            sendDeathEvent(p.conn, p.score, aa);
            feedDeath(l, p, aa);
            detachPlayer(l, p);
            graveyard.append(galloc, p) catch destroyPlayer(p);
            continue;
        }

        // b. head vs any segment of another snake: both die
        if (findCollidedOther(l, p)) |other| {
            sendDeathEvent(p.conn, p.score, aa);
            sendDeathEvent(other.conn, other.score, aa);
            feedDeath(l, p, aa);
            feedDeath(l, other, aa);
            detachPlayer(l, p);
            graveyard.append(galloc, p) catch destroyPlayer(p);
            detachPlayer(l, other);
            graveyard.append(galloc, other) catch destroyPlayer(other);
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
                    galloc.free(l.drops.items[di].id);
                    _ = l.drops.swapRemove(di);
                    openDropLocked(l, p, aa);
                }
            }
        }

        // g. one queued turn, then move
        p.applyMove(galloc);
    }

    // 5. broadcast membership metadata only when it changed, followed by the
    // compact world snapshot. Ordered websocket delivery keeps them aligned.
    const serialize_t0 = monoNanos();
    if (l.roster_dirty) {
        if (buildRoster(l)) |frame| {
            broadcastLobby(l, frame);
            l.roster_dirty = false;
        } else |_| {}
    }
    if (buildGameTick(l, now)) |frame| {
        l.stats.wire_bytes = frame.len;
        broadcastLobby(l, frame);
    } else |_| {}
    const serialize_ns: u64 = @intCast(@max(0, monoNanos() - serialize_t0));
    l.stats.serialize_ns = serialize_ns;
    l.stats.serialize_ns_total +%= serialize_ns;

    // stats
    const dur_ms = @as(f64, @floatFromInt(monoNanos() - t0)) / 1_000_000.0;
    l.stats.last_tick_ms = dur_ms;
    l.stats.ticks += 1;
    const window: f64 = @floatFromInt(@min(l.stats.ticks, 200));
    l.stats.avg_tick_ms += (dur_ms - l.stats.avg_tick_ms) / window;
    l.stats.max_tick_ms = @max(l.stats.max_tick_ms, dur_ms);
}

fn tickAll() void {
    _ = tick_arena.reset(.retain_capacity);
    const aa = tick_arena.allocator();

    const now = unixMillis();

    // reap idle non-default lobbies (60s with zero players)
    var doomed: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (doomed.items) |dz| galloc.free(dz);
        doomed.deinit(galloc);
    }
    for (lobbies.values()) |l| {
        if (std.mem.eql(u8, l.id, DEFAULT_LOBBY_ID)) continue;
        if (l.players.count() != 0) continue;
        if (l.last_empty_at == 0) {
            l.last_empty_at = now;
        } else if (now - l.last_empty_at >= LOBBY_IDLE_DELETE_MS) {
            const dup = galloc.dupe(u8, l.id) catch continue;
            doomed.append(galloc, dup) catch galloc.free(dup);
        }
    }
    for (doomed.items) |dz| {
        if (lobbies.fetchOrderedRemove(dz)) |kv| destroyLobby(kv.value);
    }

    for (lobbies.values()) |l| {
        if (l.players.count() > 0) tickLobby(l, now, aa);
    }
}

// ------------------------------------------------------------------ http plumbing

fn pf(b: *Buf, aa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var scratch: [256]u8 = undefined;
    const rendered = std.fmt.bufPrint(&scratch, fmt, args) catch {
        const allocated = try std.fmt.allocPrint(aa, fmt, args);
        defer aa.free(allocated);
        return b.appendSlice(aa, allocated);
    };
    try b.appendSlice(aa, rendered);
}

const SendOpts = struct {
    status: u16,
    reason: []const u8,
    ctype: ?[]const u8 = null,
    body: []const u8 = "",
    location: ?[]const u8 = null,
    keep_alive: bool,
    head_only: bool = false,
};

fn sendResponse(c: *Conn, aa: Allocator, o: SendOpts) void {
    var b: Buf = .empty;
    defer b.deinit(aa);
    pf(&b, aa, "HTTP/1.1 {d} {s}" ++ CRLF, .{ o.status, o.reason }) catch return;
    b.appendSlice(aa, "X-Content-Type-Options: nosniff" ++ CRLF) catch return;
    b.appendSlice(aa, "X-Frame-Options: DENY" ++ CRLF) catch return;
    b.appendSlice(aa, "Referrer-Policy: no-referrer" ++ CRLF) catch return;
    if (o.location) |loc| {
        b.appendSlice(aa, "Location: ") catch return;
        b.appendSlice(aa, loc) catch return;
        b.appendSlice(aa, CRLF) catch return;
    }
    if (o.ctype) |ct| {
        b.appendSlice(aa, "Content-Type: ") catch return;
        b.appendSlice(aa, ct) catch return;
        b.appendSlice(aa, CRLF) catch return;
    }
    pf(&b, aa, "Content-Length: {d}" ++ CRLF, .{o.body.len}) catch return;
    const conn_hdr: []const u8 = if (o.keep_alive) "Connection: keep-alive" ++ CRLF else "Connection: close" ++ CRLF;
    b.appendSlice(aa, conn_hdr) catch return;
    b.appendSlice(aa, CRLF) catch return;
    if (!o.head_only) b.appendSlice(aa, o.body) catch return;
    connQueueRaw(c, b.items);
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

// ------------------------------------------------------------------ url helpers

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn decodeInto(out: *Buf, aa: Allocator, s: []const u8, plus_as_space: bool) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                out.append(aa, (hi.? << 4) | lo.?) catch return out.items;
                i += 3;
                continue;
            }
        }
        if (plus_as_space and ch == '+') {
            out.append(aa, ' ') catch return out.items;
        } else {
            out.append(aa, ch) catch return out.items;
        }
        i += 1;
    }
    return out.items;
}

fn percentDecode(aa: Allocator, s: []const u8) []const u8 {
    var out: Buf = .empty;
    return decodeInto(&out, aa, s, false);
}

fn formDecode(aa: Allocator, s: []const u8) []const u8 {
    var out: Buf = .empty;
    return decodeInto(&out, aa, s, true);
}

/// encodeURIComponent equivalent.
fn uriEncodeComponent(aa: Allocator, s: []const u8) []const u8 {
    var out: Buf = .empty;
    for (s) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '_' or ch == '.' or ch == '!' or ch == '~' or ch == '*' or
            ch == '\'' or ch == '(' or ch == ')';
        if (safe) {
            out.append(aa, ch) catch return out.items;
        } else {
            var tmp: [4]u8 = undefined;
            const t = std.fmt.bufPrint(&tmp, "%{X:0>2}", .{ch}) catch unreachable;
            out.appendSlice(aa, t) catch return out.items;
        }
    }
    return out.items;
}

fn queryHasParam(query: []const u8, name: []const u8, value: []const u8) bool {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name) and std.mem.eql(u8, pair[eq + 1 ..], value)) return true;
    }
    return false;
}

fn extractFormField(aa: Allocator, body: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const k_raw = if (eq) |e| pair[0..e] else pair;
        const v_raw = if (eq) |e| pair[e + 1 ..] else "";
        if (std.mem.eql(u8, formDecode(aa, k_raw), name)) return formDecode(aa, v_raw);
    }
    return null;
}

fn extractJsonField(aa: Allocator, body: []const u8, name: []const u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch return null;
    defer parsed.deinit();
    switch (parsed.value) {
        .object => |obj| {
            const v = obj.get(name) orelse return null;
            switch (v) {
                .string => |st| return st,
                else => return null,
            }
        },
        else => return null,
    }
}

// ------------------------------------------------------------------ lobby ids

fn writeBase36(out: []u8, v_in: u64) usize {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var v = v_in;
    var tmp: [16]u8 = undefined;
    var n: usize = 0;
    if (v == 0) {
        out[0] = '0';
        return 1;
    }
    while (v > 0) : (v /= 36) {
        tmp[n] = digits[@intCast(v % 36)];
        n += 1;
    }
    const len = n;
    var at: usize = 0;
    while (n > 0) {
        n -= 1;
        out[at] = tmp[n];
        at += 1;
    }
    return len;
}

/// Mirrors server/generateId.js: 'id-' + rand base36 (8 chars) + base36(now ms).
fn genLobbyId(buf: *[48]u8) []const u8 {
    @memcpy(buf[0..3], "id-");
    const alpha = "0123456789abcdefghijklmnopqrstuvwxyz";
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const r = rng_prng.random().uintLessThan(usize, alpha.len);
        buf[3 + i] = alpha[r];
    }
    const suffix_len = writeBase36(buf[11..], @intCast(unixMillis()));
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
    var b: Buf = .empty;
    errdefer b.deinit(aa);
    try b.appendSlice(aa, "{\"rss\":");
    try jnum(&b, aa, readRssBytes());
    try b.appendSlice(aa, ",\"uptime\":");
    const uptime = @as(f64, @floatFromInt(unixMillis() - start_ms)) / 1000.0;
    try pf(&b, aa, "{d:.3}", .{uptime});
    try b.appendSlice(aa, ",\"totalPlayers\":");
    try jnum(&b, aa, totalPlayersLocked());
    try b.appendSlice(aa, ",\"connections\":");
    try jnum(&b, aa, connections.count());
    try b.appendSlice(aa, ",\"networkBytesSent\":");
    try jnum(&b, aa, network_bytes_sent);
    try b.appendSlice(aa, ",\"networkBytesReceived\":");
    try jnum(&b, aa, network_bytes_received);
    try b.appendSlice(aa, ",\"websocketFramesSent\":");
    try jnum(&b, aa, websocket_frames_sent);
    try b.appendSlice(aa, ",\"websocketFramesReceived\":");
    try jnum(&b, aa, websocket_frames_received);
    try b.appendSlice(aa, ",\"inputEvents\":");
    try jnum(&b, aa, input_events);
    try b.appendSlice(aa, ",\"avgInputEventUs\":");
    const avg_input_ns = if (input_events == 0) 0.0 else @as(f64, @floatFromInt(input_event_ns_total)) / @as(f64, @floatFromInt(input_events));
    try pf(&b, aa, "{d:.3}", .{avg_input_ns / 1000.0});
    try b.appendSlice(aa, ",\"lobbies\":[");
    var first = true;
    for (lobbies.values()) |l| {
        if (!first) try b.append(aa, ',');
        first = false;
        try b.appendSlice(aa, "{\"id\":");
        try jsString(&b, aa, l.id);
        try b.appendSlice(aa, ",\"players\":");
        try jnum(&b, aa, l.players.count());
        try b.appendSlice(aa, ",\"drops\":");
        try jnum(&b, aa, l.drops.items.len);
        try b.appendSlice(aa, ",\"bonus\":");
        try jnum(&b, aa, l.bonus.items.len);
        const gold: []const u8 = if (l.golden != null) "true" else "false";
        try b.appendSlice(aa, ",\"golden\":");
        try b.appendSlice(aa, gold);
        try b.appendSlice(aa, ",\"lastTickMs\":");
        try pf(&b, aa, "{d}", .{l.stats.last_tick_ms});
        try b.appendSlice(aa, ",\"avgTickMs\":");
        try pf(&b, aa, "{d:.1}", .{l.stats.avg_tick_ms});
        try b.appendSlice(aa, ",\"maxTickMs\":");
        try pf(&b, aa, "{d}", .{l.stats.max_tick_ms});
        try b.appendSlice(aa, ",\"serializeUs\":");
        try pf(&b, aa, "{d:.3}", .{@as(f64, @floatFromInt(l.stats.serialize_ns)) / 1000.0});
        try b.appendSlice(aa, ",\"avgSerializeUs\":");
        const avg_serialize_ns = if (l.stats.ticks == 0) 0.0 else @as(f64, @floatFromInt(l.stats.serialize_ns_total)) / @as(f64, @floatFromInt(l.stats.ticks));
        try pf(&b, aa, "{d:.3}", .{avg_serialize_ns / 1000.0});
        try b.appendSlice(aa, ",\"wireBytes\":");
        try jnum(&b, aa, l.stats.wire_bytes);
        try b.append(aa, '}');
    }
    try b.appendSlice(aa, "]}");
    return b.toOwnedSlice(aa);
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
    const query = if (qi) |i| target[i + 1 ..] else "";
    const dec_path = percentDecode(aa, raw_path);
    const head_only = is_head;

    if (is_get or is_head) {
        if (std.mem.eql(u8, dec_path, "/")) {
            return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = assets.assets[0].ctype, .body = assets.index_html, .keep_alive = keep_alive, .head_only = head_only });
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
                return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = "text/html; charset=utf-8", .body = assets.game_html, .keep_alive = keep_alive, .head_only = head_only });
            }
            return sendRedirect(c, aa, 302, "/", keep_alive, head_only);
        }
        if (std.mem.eql(u8, dec_path, "/debug/stats")) {
            if (debug_enabled) return sendStats(c, aa, keep_alive, head_only);
            return sendNotFound(c, aa, keep_alive, head_only);
        }
        if (std.mem.startsWith(u8, dec_path, "/socket.io/")) {
            // embedded client bundle ships under the same prefix
            if (assets.find(dec_path)) |a| {
                return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = a.ctype, .body = a.body, .keep_alive = keep_alive, .head_only = head_only });
            }
            // engine.io request without a websocket upgrade: websocket-only here.
            if (queryHasParam(query, "transport", "polling")) {
                return sendResponse(c, aa, .{
                    .status = 400,
                    .reason = "Bad Request",
                    .ctype = "text/plain; charset=utf-8",
                    .body = "this server supports the websocket transport only",
                    .keep_alive = false,
                });
            }
            return sendNotFound(c, aa, keep_alive, head_only);
        }
        if (assets.find(dec_path)) |a| {
            return sendResponse(c, aa, .{ .status = 200, .reason = "OK", .ctype = a.ctype, .body = a.body, .keep_alive = keep_alive, .head_only = head_only });
        }
        return sendNotFound(c, aa, keep_alive, head_only);
    }

    if (is_post) {
        if (std.mem.eql(u8, dec_path, "/generateid")) {
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
    connQueueRaw(c, resp);

    var raw: [16]u8 = undefined;
    g_io.random(&raw);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&c.sid, &raw);

    // engine.io open packet followed immediately by the merged socket.io
    // CONNECT ("40") -- exactly how the reference server handshakes.
    const open = std.fmt.allocPrint(
        aa,
        "0{{\"sid\":\"{s}\",\"upgrades\":[],\"pingInterval\":{d},\"pingTimeout\":{d}}}",
        .{ c.sidSlice(), PING_INTERVAL_MS, PING_TIMEOUT_MS },
    ) catch return false;
    defer aa.free(open);
    connEnqueueText(c, open);
    connEnqueueText(c, "40");
    return true;
}

fn plainStringArray(text: []const u8, out: *[3][]const u8) ?usize {
    var at: usize = 0;
    while (at < text.len and std.ascii.isWhitespace(text[at])) at += 1;
    if (at >= text.len or text[at] != '[') return null;
    at += 1;
    var count: usize = 0;
    while (true) {
        while (at < text.len and std.ascii.isWhitespace(text[at])) at += 1;
        if (at < text.len and text[at] == ']') {
            at += 1;
            while (at < text.len and std.ascii.isWhitespace(text[at])) at += 1;
            return if (at == text.len) count else null;
        }
        if (count == out.len or at >= text.len or text[at] != '"') return null;
        at += 1;
        const start = at;
        while (at < text.len and text[at] != '"') : (at += 1) {
            if (text[at] == '\\' or text[at] < 0x20) return null;
        }
        if (at >= text.len) return null;
        out[count] = text[start..at];
        count += 1;
        at += 1;
        while (at < text.len and std.ascii.isWhitespace(text[at])) at += 1;
        if (at >= text.len) return null;
        if (text[at] == ',') {
            at += 1;
            continue;
        }
        if (text[at] != ']') return null;
    }
}

fn handleParsedEvent(c: *Conn, aa: Allocator, ev: []const u8, uname: ?[]const u8, lid: ?[]const u8) void {
    if (std.mem.eql(u8, ev, "clientReady")) {
        handleClientReady(c, aa, uname, lid);
    } else if (std.mem.eql(u8, ev, "keyPress")) {
        const value = uname orelse return;
        const d = model.directionFromString(value) orelse return;
        handleKeyPress(c, d);
    }
}

fn handleSioEvent(c: *Conn, aa: Allocator, json_text: []const u8) !void {
    const parse_t0 = monoNanos();
    defer {
        input_event_ns_total +%= @intCast(@max(0, monoNanos() - parse_t0));
        input_events +%= 1;
    }
    var strings: [3][]const u8 = undefined;
    if (plainStringArray(json_text, &strings)) |count| {
        if (count == 0) return;
        return handleParsedEvent(c, aa, strings[0], if (count > 1) strings[1] else null, if (count > 2) strings[2] else null);
    }

    // Escaped strings and non-string hostile payloads take the general parser;
    // the overwhelmingly common input path above is allocation-free.
    var parsed = std.json.parseFromSlice(std.json.Value, aa, json_text, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return;
    const items = root.array.items;
    if (items.len == 0) return;
    if (items[0] != .string) return;
    const ev = items[0].string;

    if (std.mem.eql(u8, ev, "clientReady")) {
        var uname: ?[]const u8 = null;
        var lid: ?[]const u8 = null;
        if (items.len >= 2) {
            if (items[1] == .string) uname = items[1].string;
        }
        if (items.len >= 3) {
            if (items[2] == .string) lid = items[2].string;
        }
        handleParsedEvent(c, aa, ev, uname, lid);
    } else if (std.mem.eql(u8, ev, "keyPress")) {
        if (items.len >= 2 and items[1] == .string) {
            handleParsedEvent(c, aa, ev, items[1].string, null);
        }
    }
}

/// Returns true when the connection must close.
fn handleEngineText(c: *Conn, aa: Allocator, payload: []const u8) !bool {
    if (payload.len == 0) return false;
    switch (payload[0]) {
        '2' => connEnqueueText(c, "3"), // engine ping -> pong
        '3' => {}, // pong: liveness tracked by the reader loop
        '4' => {
            if (payload.len < 2) return false;
            switch (payload[1]) {
                '0' => {}, // namespace connect: we auto-connect on upgrade
                '1' => {
                    if (c.player) |p| {
                        const l = c.lobby.?;
                        feedDeath(l, p, aa);
                        detachPlayer(l, p);
                        destroyPlayer(p);
                    }
                },
                '2' => try handleSioEvent(c, aa, payload[2..]),
                else => {},
            }
        },
        '1' => return true, // engine close packet
        else => {},
    }
    return false;
}

const WsResult = struct {
    consumed: usize,
    closed: bool,
};

fn parseWsFrames(c: *Conn, aa: Allocator, data: []u8, frag: *Buf, frag_op: *u8) !WsResult {
    var off: usize = 0;
    while (data.len - off >= 2) {
        const b0 = data[off];
        const b1 = data[off + 1];
        const fin = (b0 & 0x80) != 0;
        const opcode = b0 & 0x0F;
        const masked = (b1 & 0x80) != 0;
        var len: usize = b1 & 0x7F;
        var hdr_len: usize = 2;
        if (len == 126) {
            if (data.len - off < 4) break;
            len = (@as(usize, data[off + 2]) << 8) | data[off + 3];
            hdr_len = 4;
        } else if (len == 127) {
            if (data.len - off < 10) break;
            const v = std.mem.readInt(u64, data[off + 2 ..][0..8], .big);
            if (v > MAX_WS_FRAME) return error.FrameTooBig;
            len = @intCast(v);
            hdr_len = 10;
        }
        if (!masked) return error.UnmaskedClientFrame; // clients MUST mask
        if (data.len - off < hdr_len + 4 + len) break;
        const key = data[off + hdr_len ..][0..4].*;
        const pstart = off + hdr_len + 4;
        const payload = data[pstart .. pstart + len];
        for (payload, 0..) |*ch, i| ch.* ^= key[i & 3];
        off += hdr_len + 4 + len;
        websocket_frames_received +%= 1;

        switch (opcode) {
            0x1 => { // text
                if (fin) {
                    frag_op.* = 0;
                    if (try handleEngineText(c, aa, payload)) return .{ .consumed = off, .closed = true };
                } else {
                    frag_op.* = 1;
                    frag.clearRetainingCapacity();
                    try frag.appendSlice(galloc, payload);
                }
            },
            0x2 => {}, // binary: unused by engine.io v3 text sessions
            0x0 => { // continuation
                if (frag_op.* == 0) return error.UnexpectedContinuation;
                try frag.appendSlice(galloc, payload);
                if (frag.items.len > MAX_WS_FRAME) return error.FrameTooBig;
                if (fin) {
                    const was_text = frag_op.* == 1;
                    frag_op.* = 0;
                    if (was_text) {
                        if (try handleEngineText(c, aa, frag.items)) return .{ .consumed = off, .closed = true };
                    }
                    frag.clearRetainingCapacity();
                }
            },
            0x8 => { // close
                const echo: []const u8 = if (payload.len >= 2) payload[0..2] else "";
                connEnqueueFrame(c, 0x8, echo);
                return .{ .consumed = off, .closed = true };
            },
            0x9 => connEnqueueFrame(c, 0xA, payload), // ws ping -> ws pong
            0xA => {}, // ws pong
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
    const result = parseWsFrames(c, aa, c.input.items, &c.fragment, &c.fragment_opcode) catch return false;
    consumeInput(c, result.consumed);
    if (result.closed) c.close_after_write = true;
    return true;
}

fn processHttpInput(c: *Conn, aa: Allocator) bool {
    while (c.mode == .http and !c.close_after_write) {
        const head_at = std.mem.indexOf(u8, c.input.items, CRLF ++ CRLF) orelse {
            return c.input.items.len <= MAX_HTTP_HEAD_LINE;
        };
        const head = c.input.items[0..head_at];
        const request_line_end = std.mem.indexOf(u8, head, CRLF) orelse return false;
        const request_line = head[0..request_line_end];
        const sp1 = std.mem.indexOfScalar(u8, request_line, ' ') orelse return false;
        const sp2 = std.mem.lastIndexOfScalar(u8, request_line, ' ') orelse return false;
        if (sp2 <= sp1 + 1) return false;
        const method = request_line[0..sp1];
        const target = request_line[sp1 + 1 .. sp2];
        const version = request_line[sp2 + 1 ..];
        if (!std.mem.startsWith(u8, version, "HTTP/")) return false;

        var content_length: usize = 0;
        var connection_close = false;
        var connection_keep = false;
        var upgrade_ws = false;
        var ws_key: []const u8 = "";
        var ws_version_ok = false;
        var body_is_json = false;
        var header_count: usize = 0;
        var lines = std.mem.splitSequence(u8, head[request_line_end + CRLF.len ..], CRLF);
        while (lines.next()) |line| {
            header_count += 1;
            if (header_count > 200) return false;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch return false;
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                connection_close = std.ascii.indexOfIgnoreCase(value, "close") != null;
                connection_keep = std.ascii.indexOfIgnoreCase(value, "keep-alive") != null;
            } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                upgrade_ws = std.ascii.indexOfIgnoreCase(value, "websocket") != null;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
                ws_key = value;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
                ws_version_ok = std.mem.eql(u8, value, "13");
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                body_is_json = std.ascii.indexOfIgnoreCase(value, "application/json") != null;
            }
        }

        if (content_length > MAX_HTTP_BODY) {
            sendResponse(c, aa, .{ .status = 413, .reason = "Payload Too Large", .ctype = "text/html; charset=utf-8", .body = "<html><body><h1>Payload Too Large</h1></body></html>", .keep_alive = false });
            return true;
        }
        const body_at = head_at + 2 * CRLF.len;
        const request_len = body_at + content_length;
        if (c.input.items.len < request_len) return true;
        const body = c.input.items[body_at..request_len];

        if (upgrade_ws) {
            const qpos = std.mem.indexOfScalar(u8, target, '?');
            const path = if (qpos) |i| target[0..i] else target;
            const query = if (qpos) |i| target[i + 1 ..] else "";
            if (!std.mem.startsWith(u8, path, "/socket.io/") or
                !queryHasParam(query, "transport", "websocket") or
                ws_key.len == 0 or !ws_version_ok or !doUpgrade(c, aa, ws_key))
            {
                sendResponse(c, aa, .{ .status = 400, .reason = "Bad Request", .ctype = "text/plain; charset=utf-8", .body = "websocket upgrade rejected", .keep_alive = false });
                return true;
            }
            consumeInput(c, request_len);
            c.mode = .websocket;
            c.next_ping_ms = unixMillis() + PING_INTERVAL_MS;
            return processWsInput(c, aa);
        }

        const http10 = std.mem.eql(u8, version, "HTTP/1.0");
        const keep_alive = if (http10) connection_keep and !connection_close else !connection_close;
        routeAndRespond(c, aa, method, target, body, body_is_json, keep_alive);
        consumeInput(c, request_len);
    }
    return true;
}

fn readAvailable(c: *Conn, aa: Allocator) bool {
    var scratch: [16 * 1024]u8 = undefined;
    while (true) {
        const rc = linux.read(c.fd, &scratch, scratch.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                if (count == 0) return false;
                network_bytes_received +%= count;
                c.awaiting_pong_since = null;
                c.input.appendSlice(galloc, scratch[0..count]) catch return false;
                if (c.input.items.len > MAX_WS_INPUT) return false;
            },
            .INTR => continue,
            .AGAIN => break,
            else => return false,
        }
    }
    return switch (c.mode) {
        .http => processHttpInput(c, aa),
        .websocket => processWsInput(c, aa),
    };
}

fn teardownConn(c: *Conn) void {
    if (c.closing) return;
    c.closing = true;
    _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, c.fd, null);
    _ = connections.remove(c.fd);
    closeFd(c.fd);

    var arena = std.heap.ArenaAllocator.init(galloc);
    defer arena.deinit();
    if (c.player) |p| {
        const l = c.lobby.?;
        feedDeath(l, p, arena.allocator());
        detachPlayer(l, p);
        destroyPlayer(p);
    }

    c.input.deinit(galloc);
    c.output.deinit(galloc);
    c.fragment.deinit(galloc);
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
    c.* = .{ .fd = fd };
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
        if (c.poisoned) {
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
            connEnqueueText(c, "2");
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
    var next_tick = monoNanos() + @as(i64, @intCast(TICK_NS));
    var next_heartbeat = unixMillis() + 1000;

    while (!shutting_down) {
        const before_wait = monoNanos();
        const wait_ns = @max(0, next_tick - before_wait);
        const timeout_ms: i32 = @intCast(@min(1000, @divTrunc(wait_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        const rc = linux.epoll_wait(epoll_fd, &events, events.len, timeout_ms);
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
            var alive = (event.events & (linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP)) == 0;
            if (alive and (event.events & linux.EPOLL.IN) != 0) alive = readAvailable(c, aa);
            if (alive and (event.events & linux.EPOLL.OUT) != 0) alive = flushOutput(c);
            if (alive and c.poisoned) alive = false;
            if (alive and c.close_after_write and c.output.items.len == c.output_offset) alive = false;
            if (!alive) teardownConn(c);
        }

        const now_ns = monoNanos();
        if (now_ns >= next_tick) {
            tickAll();
            next_tick += @as(i64, @intCast(TICK_NS));
            if (next_tick <= now_ns) next_tick = now_ns + @as(i64, @intCast(TICK_NS));
        }
        const now_ms = unixMillis();
        if (now_ms >= next_heartbeat) {
            serviceHeartbeats(now_ms, aa);
            next_heartbeat = now_ms + 1000;
        }
    }
}

fn setSockOpts(fd: posix.fd_t) void {
    if (builtin.os.tag != .linux) return;
    const one: c_int = 1;
    posix.setsockopt(fd, 6, 1, std.mem.asBytes(&one)) catch {}; // TCP_NODELAY
    var tvb: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u64, tvb[0..8], 3, builtin.cpu.arch.endian()); // SO_SNDTIMEO 3s
    posix.setsockopt(fd, 1, 20, &tvb) catch {};
}

// ------------------------------------------------------------------ signals / main

fn onSignal(_: posix.SIG) callconv(.c) void {
    shutting_down = true;
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

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    galloc = init.gpa;
    tick_arena = std.heap.ArenaAllocator.init(galloc);
    debug_enabled = if (init.minimal.environ.getPosix("SNEK_DEBUG")) |v| std.mem.eql(u8, v, "1") else false;
    const port: u16 = if (init.minimal.environ.getPosix("PORT")) |v| (std.fmt.parseInt(u16, v, 10) catch 3000) else 3000;

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

test "plain input parser accepts hot-path events and rejects malformed JSON" {
    var values: [3][]const u8 = undefined;
    const count = plainStringArray(" [ \"clientReady\" , \"player-one\" , \"12345\" ] ", &values);
    try std.testing.expectEqual(@as(?usize, 3), count);
    try std.testing.expectEqualStrings("clientReady", values[0]);
    try std.testing.expectEqualStrings("player-one", values[1]);
    try std.testing.expect(plainStringArray("[\"keyPress\",\"ArrowUp\"] trailing", &values) == null);
    try std.testing.expect(plainStringArray("[\"keyPress\",42]", &values) == null);
    try std.testing.expect(plainStringArray("[\"unterminated]", &values) == null);
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
    defer lobby.wire.deinit(galloc);
    try lobby.players.put(galloc, player.id, &player);

    try std.testing.expectEqualStrings("42[\"r\",[[\"sid\",\"name\",\"#abcdef\"]]]", try buildRoster(&lobby));
    try std.testing.expectEqualStrings("42[\"tick\",[[[0,1,[2,3]]],[],[],null]]", try buildGameTick(&lobby, 0));
}
