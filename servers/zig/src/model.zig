//! Core game and connection state. Networking and world orchestration live in
//! main.zig; these types contain only local state transitions.

const std = @import("std");
const posix = std.posix;

pub const CELL: i32 = 16;
pub const SID_LEN = 22;

pub const Direction = enum { up, down, left, right };

pub fn opposite(direction: Direction) Direction {
    return switch (direction) {
        .up => .down,
        .down => .up,
        .left => .right,
        .right => .left,
    };
}

pub fn directionFromString(value: []const u8) ?Direction {
    if (std.mem.eql(u8, value, "ArrowUp")) return .up;
    if (std.mem.eql(u8, value, "ArrowDown")) return .down;
    if (std.mem.eql(u8, value, "ArrowLeft")) return .left;
    if (std.mem.eql(u8, value, "ArrowRight")) return .right;
    return null;
}

pub const CellPos = struct { x: i32, y: i32 };

pub const Player = struct {
    id: []u8,
    name: []u8,
    color_hex: []u8,
    snake: std.ArrayListUnmanaged(CellPos) = .{},
    body_length: usize = 1,
    score: i64 = 0,
    dir: ?Direction = null,
    queue: [2]Direction = undefined,
    queue_len: usize = 0,
    pending_growth: i64 = 0,
    conn: *Conn,

    pub fn pushTurn(player: *Player, direction: Direction) bool {
        const last = if (player.queue_len > 0) player.queue[player.queue_len - 1] else player.dir;
        if (last) |previous| {
            if (direction == previous or direction == opposite(previous)) return false;
        }
        if (player.queue_len >= player.queue.len) return false;
        player.queue[player.queue_len] = direction;
        player.queue_len += 1;
        return true;
    }

    pub fn eat(player: *Player, points: i64, growth: i64) void {
        player.score += points;
        player.pending_growth += growth;
        player.body_length = player.snake.items.len + @as(usize, @intCast(player.pending_growth));
    }

    pub fn applyMove(player: *Player, allocator: std.mem.Allocator) void {
        if (player.queue_len > 0) {
            player.dir = player.queue[0];
            player.queue[0] = player.queue[1];
            player.queue_len -= 1;
        }
        const direction = player.dir orelse return;
        var head = player.snake.items[0];
        switch (direction) {
            .up => head.y -= CELL,
            .down => head.y += CELL,
            .left => head.x -= CELL,
            .right => head.x += CELL,
        }
        if (player.pending_growth > 0) player.pending_growth -= 1 else _ = player.snake.pop();
        player.snake.insert(allocator, 0, head) catch return;
        player.body_length = player.snake.items.len;
    }
};

pub const BonusApple = struct { pos: CellPos };
pub const Drop = struct { id: []u8, pos: CellPos, expires_at: i64 };
pub const Golden = struct { pos: CellPos, expires_at: i64 };
pub const TickStats = struct {
    last_tick_ms: f64 = 0,
    avg_tick_ms: f64 = 0,
    max_tick_ms: f64 = 0,
    ticks: u64 = 0,
};

pub const Lobby = struct {
    id: []u8,
    players: std.StringArrayHashMapUnmanaged(*Player) = .{},
    food: CellPos,
    bonus: std.ArrayListUnmanaged(BonusApple) = .{},
    drops: std.ArrayListUnmanaged(Drop) = .{},
    golden: ?Golden = null,
    next_drop_at: i64 = 0,
    next_golden_at: i64 = 0,
    drop_seq: u64 = 1,
    last_empty_at: i64 = 0,
    stats: TickStats = .{},
};

pub const Conn = struct {
    fd: posix.fd_t,
    sid: [SID_LEN]u8 = undefined,
    qmtx: std.Thread.Mutex = .{},
    qcond: std.Thread.Condition = .{},
    chunks: std.ArrayListUnmanaged([]u8) = .{},
    queued_bytes: usize = 0,
    closing: bool = false,
    poisoned: bool = false,
    player: ?*Player = null,
    lobby: ?*Lobby = null,
    wr_thread: ?std.Thread = null,

    pub fn sidSlice(connection: *Conn) []const u8 {
        return connection.sid[0..SID_LEN];
    }
};
