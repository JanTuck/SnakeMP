//! Snek multiplayer server - Zig port.
//! Wire protocol: engine.io v3 (EIO=3) websocket transport carrying
//! socket.io v2 frames, per docs/SPEC.md. Standard library only.
//!
//! Architecture:
//!   - thread-per-connection accept loop; each connection gets a reader
//!     thread (owns the connection) plus a companion writer thread that
//!     drains a per-connection outbound frame queue, so slow clients can
//!     never stall the ticker.
//!   - shared game state behind one mutex; a dedicated ticker thread steps
//!     every lobby at 66.67ms.
//!   - all public assets embedded at compile time via @embedFile.

const std = @import("std");
const posix = std.posix;
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

var gpa_state = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
const galloc = gpa_state.allocator();

var state_mtx: std.Thread.Mutex = .{};
var rng_prng: std.Random.DefaultPrng = undefined;
var lobbies: std.StringArrayHashMapUnmanaged(*Lobby) = .{};
var start_ms: i64 = 0;
var debug_enabled = false;
var shutting_down = false;
var listen_fd: posix.fd_t = -1;

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
    const s = try std.fmt.allocPrint(aa, "{d}", .{v});
    defer aa.free(s);
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

fn freeChunksLocked(c: *Conn) void {
    for (c.chunks.items) |ch| galloc.free(ch);
    c.chunks.clearRetainingCapacity();
    c.queued_bytes = 0;
}

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

/// Queue a websocket frame (header + payload copied into one allocation).
fn connEnqueueFrame(c: *Conn, opcode: u8, payload: []const u8) void {
    var hdr: [10]u8 = undefined;
    const hlen = wsHeader(&hdr, opcode, payload.len);

    c.qmtx.lock();
    defer c.qmtx.unlock();
    if (c.closing or c.poisoned) return;
    if (c.queued_bytes + payload.len + hlen > MAX_QUEUE_BYTES) {
        c.poisoned = true;
        c.qcond.signal();
        posix.shutdown(c.fd, .recv) catch {};
        return;
    }
    const buf = galloc.alloc(u8, hlen + payload.len) catch {
        c.poisoned = true;
        c.qcond.signal();
        posix.shutdown(c.fd, .recv) catch {};
        return;
    };
    @memcpy(buf[0..hlen], hdr[0..hlen]);
    @memcpy(buf[hlen..], payload);
    c.chunks.append(galloc, buf) catch {
        galloc.free(buf);
        c.poisoned = true;
        c.qcond.signal();
        posix.shutdown(c.fd, .recv) catch {};
        return;
    };
    c.queued_bytes += buf.len;
    c.qcond.signal();
}

fn connEnqueueText(c: *Conn, payload: []const u8) void {
    connEnqueueFrame(c, 0x1, payload);
}

fn writerMain(c: *Conn) void {
    var scratch: Buf = .{};
    defer scratch.deinit(galloc);

    while (true) {
        c.qmtx.lock();
        while (!(c.poisoned or c.closing or c.chunks.items.len > 0)) {
            c.qcond.wait(&c.qmtx);
        }
        if (c.poisoned or (c.closing and c.chunks.items.len == 0)) {
            freeChunksLocked(c);
            c.qmtx.unlock();
            break;
        }
        scratch.clearRetainingCapacity();
        var ok = true;
        for (c.chunks.items) |ch| {
            scratch.appendSlice(galloc, ch) catch {
                ok = false;
                break;
            };
        }
        freeChunksLocked(c);
        c.qmtx.unlock();

        if (!ok) {
            c.qmtx.lock();
            c.poisoned = true;
            freeChunksLocked(c);
            c.qmtx.unlock();
            posix.shutdown(c.fd, .recv) catch {};
            break;
        }

        var off: usize = 0;
        var failed = false;
        while (off < scratch.items.len) {
            const n = posix.write(c.fd, scratch.items[off..]) catch {
                failed = true;
                break;
            };
            if (n == 0) {
                failed = true;
                break;
            }
            off += n;
        }
        if (failed) {
            c.qmtx.lock();
            c.poisoned = true;
            freeChunksLocked(c);
            c.qmtx.unlock();
            posix.shutdown(c.fd, .recv) catch {}; // wake the reader
            break;
        }
    }
}

// ------------------------------------------------------- room ops (state_mtx held)

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
    var args: Buf = .{};
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
    var args: Buf = .{};
    defer args.deinit(aa);
    args.append(aa, ',') catch return;
    jnum(&args, aa, score) catch return;
    const frame = eventFrame(aa, "death", args.items) catch return;
    defer aa.free(frame);
    connEnqueueText(c, frame);
}

fn sendGameError(c: *Conn, msg: []const u8, aa: Allocator) void {
    var args: Buf = .{};
    defer args.deinit(aa);
    args.append(aa, ',') catch return;
    jsString(&args, aa, msg) catch return;
    const frame = eventFrame(aa, "game_error", args.items) catch return;
    defer aa.free(frame);
    connEnqueueText(c, frame);
}

fn broadcastUpdateFood(l: *Lobby, aa: Allocator) void {
    var args: Buf = .{};
    defer args.deinit(aa);
    pf(&args, aa, ",{{\"x\":{d},\"y\":{d}}}", .{ l.food.x, l.food.y }) catch return;
    const frame = eventFrame(aa, "updateFood", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

fn broadcastGoldenFeed(l: *Lobby, p: *Player, aa: Allocator) void {
    var args: Buf = .{};
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
    state_mtx.lock();
    defer state_mtx.unlock();

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
        var args: Buf = .{};
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

    // feed join to everyone in the room (including the joiner).
    var args: Buf = .{};
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"type\":\"join\",\"who\":") catch return;
    jsString(&args, aa, p.name) catch return;
    args.appendSlice(aa, "}") catch return;
    const frame = eventFrame(aa, "feed", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(target, frame);
}

fn handleKeyPress(c: *Conn, d: Direction) void {
    state_mtx.lock();
    defer state_mtx.unlock();
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
    var args: Buf = .{};
    defer args.deinit(aa);
    args.appendSlice(aa, ",{\"type\":\"drop-open\",\"who\":") catch return;
    jsString(&args, aa, p.name) catch return;
    pf(&args, aa, ",\"apples\":{d}}}", .{spawned}) catch return;
    const frame = eventFrame(aa, "feed", args.items) catch return;
    defer aa.free(frame);
    broadcastLobby(l, frame);
}

fn buildGameTick(l: *Lobby, now: i64, aa: Allocator) ![]u8 {
    const WirePlayer = struct {
        id: []const u8,
        displayName: []const u8,
        color: []const u8,
        snake: []const CellPos,
        score: i64,
        bodyLength: usize,
    };
    const WireDrop = struct { id: []const u8, x: i32, y: i32, ttl: i64 };
    const WireGolden = struct { x: i32, y: i32, ttl: i64 };
    const WireWorld = struct {
        players: []const WirePlayer,
        bonus: []const CellPos,
        drops: []const WireDrop,
        golden: ?WireGolden,
    };

    const players = try aa.alloc(WirePlayer, l.players.count());
    for (l.players.values(), 0..) |p, i| {
        players[i] = .{
            .id = p.id,
            .displayName = p.name,
            .color = p.color_hex,
            .snake = p.snake.items,
            .score = p.score,
            .bodyLength = p.body_length,
        };
    }

    const bonus = try aa.alloc(CellPos, l.bonus.items.len);
    for (l.bonus.items, 0..) |apple, i| bonus[i] = apple.pos;

    const drops = try aa.alloc(WireDrop, l.drops.items.len);
    for (l.drops.items, 0..) |drop, i| {
        drops[i] = .{
            .id = drop.id,
            .x = drop.pos.x,
            .y = drop.pos.y,
            .ttl = @max(0, drop.expires_at - now),
        };
    }

    const golden: ?WireGolden = if (l.golden) |item| .{
        .x = item.pos.x,
        .y = item.pos.y,
        .ttl = @max(0, item.expires_at - now),
    } else null;

    var b: Buf = .{};
    errdefer b.deinit(aa);
    try b.appendSlice(aa, "42[\"gameTick\",");
    try std.json.stringify(WireWorld{
        .players = players,
        .bonus = bonus,
        .drops = drops,
        .golden = golden,
    }, .{}, b.writer(aa));
    try b.append(aa, ']');
    return b.toOwnedSlice(aa);
}

// ------------------------------------------------------------------ tick

fn tickLobby(l: *Lobby, now: i64, aa: Allocator) void {
    const t0 = std.time.nanoTimestamp();

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
    var graveyard: std.ArrayListUnmanaged(*Player) = .{};
    defer {
        for (graveyard.items) |p| destroyPlayer(p);
        graveyard.deinit(galloc);
    }

    var snapshot = std.ArrayListUnmanaged(*Player){};
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

    // 5. broadcast world snapshot
    if (buildGameTick(l, now, aa)) |frame| {
        defer aa.free(frame);
        broadcastLobby(l, frame);
    } else |_| {}

    // stats
    const dur_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000.0;
    l.stats.last_tick_ms = dur_ms;
    l.stats.ticks += 1;
    const window: f64 = @floatFromInt(@min(l.stats.ticks, 200));
    l.stats.avg_tick_ms += (dur_ms - l.stats.avg_tick_ms) / window;
    l.stats.max_tick_ms = @max(l.stats.max_tick_ms, dur_ms);
}

fn tickAll() void {
    var arena = std.heap.ArenaAllocator.init(galloc);
    defer arena.deinit();
    const aa = arena.allocator();

    state_mtx.lock();
    defer state_mtx.unlock();

    const now = std.time.milliTimestamp();

    // reap idle non-default lobbies (60s with zero players)
    var doomed: std.ArrayListUnmanaged([]u8) = .{};
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

fn tickerMain() void {
    var next_ns = std.time.nanoTimestamp();
    while (!shutting_down) {
        next_ns += TICK_NS;
        const now = std.time.nanoTimestamp();
        if (next_ns > now) {
            const delta: u64 = @intCast(next_ns - now);
            std.time.sleep(delta);
        } else {
            next_ns = now; // fell behind; resync
        }
        tickAll();
    }
}

// ------------------------------------------------------------------ http plumbing

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try posix.write(fd, bytes[off..]);
        if (n == 0) return error.WriteFailed;
        off += n;
    }
}

fn pf(b: *Buf, aa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(aa, fmt, args);
    defer aa.free(s);
    try b.appendSlice(aa, s);
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
    var b: Buf = .{};
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
    writeAllFd(c.fd, b.items) catch {};
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
    var out: Buf = .{};
    return decodeInto(&out, aa, s, false);
}

fn formDecode(aa: Allocator, s: []const u8) []const u8 {
    var out: Buf = .{};
    return decodeInto(&out, aa, s, true);
}

/// encodeURIComponent equivalent.
fn uriEncodeComponent(aa: Allocator, s: []const u8) []const u8 {
    var out: Buf = .{};
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

fn writeBase36(w: anytype, v_in: u64) void {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var v = v_in;
    var tmp: [16]u8 = undefined;
    var n: usize = 0;
    if (v == 0) {
        w.writeAll("0") catch {};
        return;
    }
    while (v > 0) : (v /= 36) {
        tmp[n] = digits[@intCast(v % 36)];
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        w.writeAll(tmp[n .. n + 1]) catch {};
    }
}

/// Mirrors server/generateId.js: 'id-' + rand base36 (8 chars) + base36(now ms).
fn genLobbyId(buf: *[48]u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("id-") catch {};
    const alpha = "0123456789abcdefghijklmnopqrstuvwxyz";
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const r = rng_prng.random().uintLessThan(usize, alpha.len);
        w.writeByte(alpha[r]) catch {};
    }
    writeBase36(w, @intCast(std.time.milliTimestamp()));
    return fbs.getWritten();
}

// ------------------------------------------------------------------ stats

fn readRssBytes() u64 {
    blk: {
        const f = std.fs.openFileAbsolute("/proc/self/status", .{}) catch break :blk;
        defer f.close();
        var buf: [4096]u8 = undefined;
        const n = f.read(&buf) catch break :blk;
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
        const f = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch break :blk2;
        defer f.close();
        var buf: [256]u8 = undefined;
        const n = f.read(&buf) catch break :blk2;
        var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
        _ = it.next() orelse break :blk2;
        const pages_str = it.next() orelse break :blk2;
        const pages = std.fmt.parseInt(u64, pages_str, 10) catch break :blk2;
        return pages * 4096;
    }
    return 0;
}

fn buildStats(aa: Allocator) ![]u8 {
    state_mtx.lock();
    defer state_mtx.unlock();

    var b: Buf = .{};
    errdefer b.deinit(aa);
    try b.appendSlice(aa, "{\"rss\":");
    try jnum(&b, aa, readRssBytes());
    try b.appendSlice(aa, ",\"uptime\":");
    const uptime = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_ms)) / 1000.0;
    try pf(&b, aa, "{d:.3}", .{uptime});
    try b.appendSlice(aa, ",\"totalPlayers\":");
    try jnum(&b, aa, totalPlayersLocked());
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
            state_mtx.lock();
            const exists = lobbies.contains(gid);
            state_mtx.unlock();
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
            state_mtx.lock();
            var new_id: []const u8 = undefined;
            while (true) {
                new_id = genLobbyId(&idbuf);
                if (!lobbies.contains(new_id)) break;
            }
            const owned = galloc.dupe(u8, new_id) catch {
                state_mtx.unlock();
                return sendServerError(c, aa);
            };
            _ = createLobbyLocked(owned) catch {
                galloc.free(owned);
                state_mtx.unlock();
                return sendServerError(c, aa);
            };
            state_mtx.unlock();
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
                state_mtx.lock();
                const exists = lobbies.contains(trimmed);
                state_mtx.unlock();
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
    writeAllFd(c.fd, resp) catch return false;

    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
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

fn handleSioEvent(c: *Conn, aa: Allocator, json_text: []const u8) !void {
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
        handleClientReady(c, aa, uname, lid);
    } else if (std.mem.eql(u8, ev, "keyPress")) {
        if (items.len >= 2 and items[1] == .string) {
            const d = model.directionFromString(items[1].string) orelse return;
            handleKeyPress(c, d);
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
                    state_mtx.lock();
                    if (c.player) |p| {
                        const l = c.lobby.?;
                        feedDeath(l, p, aa);
                        detachPlayer(l, p);
                        destroyPlayer(p);
                    }
                    state_mtx.unlock();
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

fn parseWsFrames(c: *Conn, aa: Allocator, data: []const u8, frag: *Buf, frag_op: *u8) !WsResult {
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
        var payload: []const u8 = data[pstart .. pstart + len];
        if (len > 0) {
            const tmp = try aa.alloc(u8, len);
            @memcpy(tmp, payload);
            for (tmp, 0..) |*ch, i| ch.* ^= key[i & 3];
            payload = tmp;
        }
        off += hdr_len + 4 + len;

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
                    const whole = aa.dupe(u8, frag.items) catch return error.OutOfMemory;
                    frag.clearRetainingCapacity();
                    if (was_text) {
                        if (try handleEngineText(c, aa, whole)) return .{ .consumed = off, .closed = true };
                    }
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

fn wsLoop(c: *Conn, leftover: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(galloc);
    defer arena.deinit();

    var input: Buf = .{};
    defer input.deinit(galloc);
    input.appendSlice(galloc, leftover) catch return;

    var frag: Buf = .{};
    defer frag.deinit(galloc);
    var frag_op: u8 = 0;

    var next_ping_ms = std.time.milliTimestamp() + PING_INTERVAL_MS;
    var awaiting_pong_since: ?i64 = null;
    var rbuf: [16 * 1024]u8 = undefined;

    while (true) {
        const now = std.time.milliTimestamp();
        if (awaiting_pong_since) |ps| {
            if (now - ps > PING_TIMEOUT_MS) return; // no pong within pingTimeout
        }
        if (now >= next_ping_ms) {
            connEnqueueText(c, "2"); // server-initiated engine.io ping
            awaiting_pong_since = now;
            next_ping_ms = now + PING_INTERVAL_MS;
        }
        var wait_ms: i64 = next_ping_ms - now;
        if (wait_ms > 60_000) wait_ms = 60_000;
        if (awaiting_pong_since) |ps| {
            const dl = ps + PING_TIMEOUT_MS - now;
            if (dl < wait_ms) wait_ms = dl;
        }
        if (wait_ms < 0) wait_ms = 0;

        var fds = [1]posix.pollfd{.{ .fd = c.fd, .events = posix.POLL.IN, .revents = 0 }};
        const nready = posix.poll(&fds, @intCast(wait_ms)) catch return;
        if (shutting_down) return;
        if (nready == 0) continue;

        const rn = posix.read(c.fd, &rbuf) catch return;
        if (rn == 0) return; // TCP EOF
        awaiting_pong_since = null; // inbound traffic proves liveness

        input.appendSlice(galloc, rbuf[0..rn]) catch return;
        if (input.items.len > MAX_WS_INPUT) return;

        _ = arena.reset(.retain_capacity);
        const res = parseWsFrames(c, arena.allocator(), input.items, &frag, &frag_op) catch return;
        if (res.consumed > 0) {
            std.mem.copyForwards(u8, input.items[0 .. input.items.len - res.consumed], input.items[res.consumed..]);
            input.shrinkRetainingCapacity(input.items.len - res.consumed);
        }
        if (res.closed) return;
    }
}

// ------------------------------------------------------- connection lifecycle

const HttpReader = struct {
    fd: posix.fd_t,
    buf: [16 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn bufferedSlice(r: *HttpReader) []const u8 {
        return r.buf[r.start..r.end];
    }

    fn fill(r: *HttpReader) !void {
        if (r.start == r.end) {
            r.start = 0;
            r.end = 0;
        } else if (r.end == r.buf.len) {
            std.mem.copyForwards(u8, r.buf[0..], r.buf[r.start..r.end]);
            r.end -= r.start;
            r.start = 0;
        }
        if (r.end == r.buf.len) return error.HeadTooLarge;
        var fds = [1]posix.pollfd{.{ .fd = r.fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, HTTP_IDLE_MS) catch return error.Io;
        if (n == 0) return error.Timeout;
        const got = posix.read(r.fd, r.buf[r.end..]) catch return error.Io;
        if (got == 0) return error.Eof;
        r.end += got;
    }

    /// Reads a CRLF-terminated line. The returned slice borrows the internal
    /// buffer when the line fits (usual case), otherwise lives in `aa`.
    fn readLine(r: *HttpReader, aa: Allocator, max: usize) ![]const u8 {
        var acc: Buf = .{};
        while (true) {
            if (r.start < r.end) {
                const window = r.buf[r.start..r.end];
                if (std.mem.indexOfScalar(u8, window, '\n')) |idx| {
                    var piece = window[0..idx];
                    r.start += idx + 1;
                    if (piece.len > 0 and piece[piece.len - 1] == '\r') piece = piece[0 .. piece.len - 1];
                    if (acc.items.len == 0) return piece;
                    try acc.appendSlice(aa, piece);
                    if (acc.items.len > max) return error.HeadTooLarge;
                    return acc.items;
                }
                try acc.appendSlice(aa, window);
                r.start = r.end;
                if (acc.items.len > max) return error.HeadTooLarge;
            }
            try r.fill();
        }
    }

    fn readExact(r: *HttpReader, aa: Allocator, n: usize) ![]const u8 {
        const out = try aa.alloc(u8, n);
        var got: usize = 0;
        while (got < n) {
            const avail = r.end - r.start;
            if (avail > 0) {
                const take = @min(avail, n - got);
                @memcpy(out[got .. got + take], r.buf[r.start .. r.start + take]);
                r.start += take;
                got += take;
            } else {
                try r.fill();
            }
        }
        return out;
    }
};

const HttpOutcome = union(enum) {
    closed,
    upgraded: []const u8, // owned copy of pipelined websocket bytes, if any
};

fn serveHttp(c: *Conn, arena_ptr: *std.heap.ArenaAllocator) HttpOutcome {
    var rdr = HttpReader{ .fd = c.fd };
    while (true) {
        _ = arena_ptr.reset(.retain_capacity);
        const aa = arena_ptr.allocator();

        const req_line = rdr.readLine(aa, MAX_HTTP_HEAD_LINE) catch return .closed;
        const sp1 = std.mem.indexOfScalar(u8, req_line, ' ') orelse return .closed;
        const sp2 = std.mem.lastIndexOfScalar(u8, req_line, ' ') orelse return .closed;
        if (sp2 <= sp1 + 1) return .closed;
        const method = req_line[0..sp1];
        const target = req_line[sp1 + 1 .. sp2];
        const version = req_line[sp2 + 1 ..];
        if (!std.mem.startsWith(u8, version, "HTTP/")) return .closed;
        const http10 = std.mem.eql(u8, version, "HTTP/1.0");

        var content_length: usize = 0;
        var conn_close_hdr = false;
        var conn_keep_hdr = false;
        var upgrade_ws = false;
        var ws_key: []const u8 = "";
        var ws_version_ok = false;
        var body_is_json = false;
        var bad = false;

        var lines: usize = 0;
        while (true) {
            lines += 1;
            if (lines > 200) return .closed;
            const line = rdr.readLine(aa, MAX_HTTP_HEAD_LINE) catch return .closed;
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, val, 10) catch {
                    bad = true;
                    break;
                };
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.indexOfIgnoreCase(val, "close") != null) conn_close_hdr = true;
                if (std.ascii.indexOfIgnoreCase(val, "keep-alive") != null) conn_keep_hdr = true;
            } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                if (std.ascii.indexOfIgnoreCase(val, "websocket") != null) upgrade_ws = true;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
                ws_key = val;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
                ws_version_ok = std.mem.eql(u8, val, "13");
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                if (std.ascii.indexOfIgnoreCase(val, "application/json") != null) body_is_json = true;
            }
        }
        if (bad) {
            sendResponse(c, aa, .{ .status = 400, .reason = "Bad Request", .ctype = "text/html; charset=utf-8", .body = "<html><body><h1>Bad Request</h1></body></html>", .keep_alive = false });
            return .closed;
        }

        if (upgrade_ws) {
            const qpos = std.mem.indexOfScalar(u8, target, '?');
            const upath = if (qpos) |i| target[0..i] else target;
            const uquery = if (qpos) |i| target[i + 1 ..] else "";
            if (std.mem.startsWith(u8, upath, "/socket.io/") and
                queryHasParam(uquery, "transport", "websocket") and
                ws_key.len > 0 and ws_version_ok)
            {
                if (!doUpgrade(c, aa, ws_key)) return .closed;
                const left = galloc.dupe(u8, rdr.bufferedSlice()) catch return .closed;
                return .{ .upgraded = left };
            }
            sendResponse(c, aa, .{ .status = 400, .reason = "Bad Request", .ctype = "text/plain; charset=utf-8", .body = "websocket upgrade rejected", .keep_alive = false });
            return .closed;
        }

        const keep_alive = if (http10) (conn_keep_hdr and !conn_close_hdr) else !conn_close_hdr;

        var body: []const u8 = "";
        if (content_length > 0) {
            if (content_length > MAX_HTTP_BODY) {
                sendResponse(c, aa, .{ .status = 413, .reason = "Payload Too Large", .ctype = "text/html; charset=utf-8", .body = "<html><body><h1>Payload Too Large</h1></body></html>", .keep_alive = false });
                return .closed;
            }
            body = rdr.readExact(aa, content_length) catch return .closed;
        }

        routeAndRespond(c, aa, method, target, body, body_is_json, keep_alive);
        if (!keep_alive) return .closed;
    }
}

fn readerMain(c: *Conn) void {
    var arena = std.heap.ArenaAllocator.init(galloc);
    defer arena.deinit();

    switch (serveHttp(c, &arena)) {
        .closed => {},
        .upgraded => |leftover| {
            wsLoop(c, leftover);
            galloc.free(leftover);
        },
    }
    teardownConn(c);
}

fn teardownConn(c: *Conn) void {
    c.qmtx.lock();
    c.closing = true;
    c.qcond.signal();
    c.qmtx.unlock();
    if (c.wr_thread) |t| t.join();
    posix.close(c.fd);

    // SPEC: on socket close, remove the player and announce feed death.
    var arena = std.heap.ArenaAllocator.init(galloc);
    defer arena.deinit();
    state_mtx.lock();
    if (c.player) |p| {
        const l = c.lobby.?;
        feedDeath(l, p, arena.allocator());
        detachPlayer(l, p);
        destroyPlayer(p);
    }
    state_mtx.unlock();

    c.qmtx.lock();
    freeChunksLocked(c);
    c.qmtx.unlock();
    c.chunks.deinit(galloc);
    galloc.destroy(c);
}

fn setSockOpts(fd: posix.fd_t) void {
    if (builtin.os.tag != .linux) return;
    const one: c_int = 1;
    posix.setsockopt(fd, 6, 1, std.mem.asBytes(&one)) catch {}; // TCP_NODELAY
    var tvb: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u64, tvb[0..8], 3, builtin.cpu.arch.endian()); // SO_SNDTIMEO 3s
    posix.setsockopt(fd, 1, 20, &tvb) catch {};
}

fn spawnConnThreads(fd: posix.fd_t) void {
    setSockOpts(fd);
    const c = galloc.create(Conn) catch {
        posix.close(fd);
        return;
    };
    c.* = .{ .fd = fd };

    const wt = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, writerMain, .{c}) catch {
        posix.close(fd);
        galloc.destroy(c);
        return;
    };
    c.wr_thread = wt;

    const rt = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, readerMain, .{c}) catch {
        c.qmtx.lock();
        c.closing = true;
        c.qcond.signal();
        c.qmtx.unlock();
        wt.join();
        posix.close(fd);
        c.chunks.deinit(galloc);
        galloc.destroy(c);
        return;
    };
    rt.detach();
}

// ------------------------------------------------------------------ signals / main

fn onSignal(_: i32) callconv(.C) void {
    shutting_down = true;
    if (listen_fd >= 0) {
        posix.shutdown(listen_fd, .both) catch {};
    }
}

fn installSignalHandlers() void {
    var ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ign, null) catch {}; // writes to dead sockets must not kill us

    var term = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &term, null) catch {};
    posix.sigaction(posix.SIG.INT, &term, null) catch {};
}

pub fn main() !void {
    debug_enabled = if (std.posix.getenv("SNEK_DEBUG")) |v| std.mem.eql(u8, v, "1") else false;
    const port: u16 = if (std.posix.getenv("PORT")) |v| (std.fmt.parseInt(u16, v, 10) catch 3000) else 3000;

    start_ms = std.time.milliTimestamp();
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    rng_prng = std.Random.DefaultPrng.init(seed ^ @as(u64, @intCast(std.os.linux.getpid())));

    installSignalHandlers();

    state_mtx.lock();
    const def_id = galloc.dupe(u8, DEFAULT_LOBBY_ID) catch unreachable;
    _ = createLobbyLocked(def_id) catch unreachable;
    state_mtx.unlock();

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    var srv = addr.listen(.{ .reuse_address = true }) catch |e| {
        std.debug.print("server error: {s}\n", .{@errorName(e)});
        return e;
    };
    listen_fd = srv.stream.handle;

    const tk = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, tickerMain, .{});
    tk.detach();

    const stdout = std.io.getStdOut().writer();
    var bout = std.io.bufferedWriter(stdout);
    bout.writer().print("listening on *:{d}\n", .{port}) catch {};
    bout.flush() catch {};

    while (!shutting_down) {
        const inc = srv.accept() catch {
            if (shutting_down) break;
            std.time.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        spawnConnThreads(inc.stream.handle);
    }
    std.process.exit(0);
}
