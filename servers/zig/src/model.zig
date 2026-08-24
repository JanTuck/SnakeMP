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

pub const CellPos = struct { x: i32, y: i32 };

pub const Player = struct {
    id: []u8,
    name: []u8,
    color_hex: []u8,
    snake: std.ArrayListUnmanaged(CellPos) = .empty,
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
    }

    pub fn applyMove(player: *Player, allocator: std.mem.Allocator) void {
        if (player.queue_len > 0) {
            player.dir = player.queue[0];
            if (player.queue_len > 1) player.queue[0] = player.queue[1];
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
        if (player.pending_growth > 0) {
            const tail = player.snake.items[player.snake.items.len - 1];
            player.snake.append(allocator, tail) catch return;
            player.pending_growth -= 1;
        }
        var i = player.snake.items.len - 1;
        while (i > 0) : (i -= 1) player.snake.items[i] = player.snake.items[i - 1];
        player.snake.items[0] = head;
    }
};

pub const BonusApple = struct { pos: CellPos };
pub const Drop = struct { pos: CellPos, expires_at: i64 };
pub const Golden = struct { pos: CellPos, expires_at: i64 };
pub const TickStats = struct {
    last_tick_ms: f64 = 0,
    avg_tick_ms: f64 = 0,
    max_tick_ms: f64 = 0,
    ticks: u64 = 0,
    serialize_ns: u64 = 0,
    serialize_ns_total: u64 = 0,
    /// Binary snapshot construction only. This deliberately excludes roster
    /// JSON and socket fan-out so profiling can distinguish compute from I/O.
    encode_ns: u64 = 0,
    encode_ns_total: u64 = 0,
    /// Synchronous fast-path publication to every connection in the lobby.
    /// Backpressured suffixes are completed later by the epoll reactor.
    fanout_ns: u64 = 0,
    fanout_ns_total: u64 = 0,
    wire_bytes: usize = 0,
};

/// Minimal history needed to encode the next deterministic snake transition.
/// Full snake bodies are not retained: a legal tick either keeps the body
/// unchanged, shifts it behind a new head, or shifts and grows by one cell.
pub const SnapshotPlayerState = struct {
    score: i32 = 0,
    cells: u16 = 0,
    head_x: u8 = 0,
    head_y: u8 = 0,
};

/// One immutable websocket frame shared by every connection in a lobby
/// broadcast. The payload is constructed before publication; references are
/// retained only by connections that hit socket backpressure.
pub const SharedFrame = struct {
    refs: std.atomic.Value(usize) = .init(1),
    header: [10]u8 = undefined,
    header_len: u8 = 0,
    keyframe: bool = true,
    payload: std.ArrayListUnmanaged(u8) = .empty,

    pub fn len(frame: *const SharedFrame) usize {
        return @as(usize, frame.header_len) + frame.payload.items.len;
    }
};

pub const PendingOutput = union(enum) {
    owned: []u8,
    /// Immutable process-lifetime bytes, currently embedded HTTP assets.
    borrowed: []const u8,
    shared: *SharedFrame,

    pub fn len(output: PendingOutput) usize {
        return switch (output) {
            .owned => |bytes| bytes.len,
            .borrowed => |bytes| bytes.len,
            .shared => |frame| frame.len(),
        };
    }
};

pub const Lobby = struct {
    id: []u8,
    /// Reactor-owned. Generated lobbies do not acquire a simulation thread
    /// until their first successful player join.
    worker_assigned: bool = false,
    mutex: std.Io.Mutex = .init,
    rng: std.Random.DefaultPrng = undefined,
    players: std.StringArrayHashMapUnmanaged(*Player) = .{},
    food: CellPos,
    bonus: std.ArrayListUnmanaged(BonusApple) = .empty,
    drops: std.ArrayListUnmanaged(Drop) = .empty,
    golden: ?Golden = null,
    next_drop_at: i64 = 0,
    next_golden_at: i64 = 0,
    last_empty_at: i64 = 0,
    roster_wire: std.ArrayListUnmanaged(u8) = .empty,
    roster_dirty: bool = true,
    snapshot_valid: bool = false,
    snapshot_sequence: u16 = 0,
    snapshot_since_keyframe: u8 = 0,
    snapshot_player_count: u8 = 0,
    snapshot_previous: [16]SnapshotPlayerState = [_]SnapshotPlayerState{.{}} ** 16,
    /// Fast EWMA of complete tick cost, written only by the owning worker.
    /// The reactor reads it while worker mutexes are held during rebalancing.
    balance_ewma_ns: u64 = 0,
    last_migrated_ms: i64 = 0,
    stats: TickStats = .{},
};

pub const Conn = struct {
    fd: posix.fd_t,
    output_mutex: std.Io.Mutex = .init,
    membership_mutex: std.Io.Mutex = .init,
    sid: [SID_LEN]u8 = undefined,
    input: std.ArrayListUnmanaged(u8) = .empty,
    output: std.ArrayListUnmanaged(PendingOutput) = .empty,
    output_head: usize = 0,
    output_offset: usize = 0,
    output_bytes: usize = 0,
    mode: enum { http, websocket } = .http,
    want_write: bool = false,
    close_after_write: bool = false,
    closing: bool = false,
    poisoned: bool = false,
    next_ping_ms: i64 = 0,
    awaiting_pong_since: ?i64 = null,
    last_activity_ms: i64 = 0,
    /// Visibility affects snapshot delivery only. The lobby worker continues
    /// to simulate this player's snake at the normal authoritative tick rate.
    snapshot_hidden: std.atomic.Value(bool) = .init(false),
    snapshot_needs_keyframe: std.atomic.Value(bool) = .init(false),
    next_background_snapshot_ms: std.atomic.Value(i64) = .init(0),
    player: ?*Player = null,
    lobby: ?*Lobby = null,

    pub fn sidSlice(connection: *Conn) []const u8 {
        return connection.sid[0..SID_LEN];
    }
};
