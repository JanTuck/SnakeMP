//! Core game and connection state. Networking and world orchestration live in
//! main.zig; these types contain only local state transitions.

const std = @import("std");
const posix = std.posix;
const snek = @import("snek.zig");

pub const CELL: i32 = 16;
pub const SID_LEN = 22;
pub const MAX_REMAINS: usize = 63;
pub const MAX_SPECTATORS: usize = 16;

pub const CHAT_TOKEN_CAPACITY: u8 = 4;
pub const CHAT_REFILL_MS: i64 = 750;
/// A room-wide ceiling prevents reconnecting peers from multiplying the
/// per-connection burst allowance. Four messages per second remains usable
/// for a full lobby while bounding fan-out work independently of joins.
pub const LOBBY_CHAT_TOKEN_CAPACITY: u8 = 12;
pub const LOBBY_CHAT_REFILL_MS: i64 = 250;

/// Lobby rules are fixed when the lobby is created. Classical is apples-only;
/// Arcade adds golden apples, supply drops, boost, remains, feasts, and
/// bounties; Snek IO is the continuous battle arena simulated in snek.zig.
/// The mode never changes for the lifetime of a lobby.
pub const GameMode = enum(u8) {
    classical = 0,
    arcade = 1,
    snek_io = 2,

    /// The only wire spelling for each mode; "snek_io" has no aliases.
    pub fn wireName(mode: GameMode) []const u8 {
        return switch (mode) {
            .classical => "classical",
            .arcade => "arcade",
            .snek_io => "snek_io",
        };
    }

    pub fn isClassical(mode: GameMode) bool {
        return mode == .classical;
    }

    pub fn isArcade(mode: GameMode) bool {
        return mode == .arcade;
    }
    // Snek IO is neither classical nor arcade; isClassical/isArcade above stay
    // strict and call sites that want continuous-mode behavior compare == .snek_io.
};

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
    /// Borrowed from `conn.sid`; the connection owns and outlives its player.
    id: []const u8,
    name: []u8,
    color_hex: []u8,
    snake: std.ArrayListUnmanaged(CellPos) = .empty,
    score: i64 = 0,
    dir: ?Direction = null,
    queue: [2]Direction = undefined,
    queue_len: usize = 0,
    pending_growth: i64 = 0,
    /// Three remains convert into one growth/score award. A two-bit counter
    /// represents the complete 0...2 accumulation range without padding the
    /// gameplay contract with an unbounded resource balance.
    mass_progress: u2 = 0,
    boosting: bool = false,
    /// Alternates the bounded extra movement substep while boost is held.
    boost_substep: bool = false,
    /// Counts boosted substeps until the next tail-cost/remnant shed.
    boost_cost_ticks: u8 = 0,
    kills: u16 = 0,
    streak: u16 = 0,
    last_kill_at: i64 = 0,
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
        const direction = if (player.queue_len > 0) player.queue[0] else player.dir orelse return;
        // Reserve before consuming the turn. Allocation failure must not leave
        // a player facing a new direction without performing the matching move.
        if (player.pending_growth > 0) player.snake.ensureUnusedCapacity(allocator, 1) catch return;

        if (player.queue_len > 0) {
            player.dir = direction;
            if (player.queue_len > 1) player.queue[0] = player.queue[1];
            player.queue_len -= 1;
        }
        var head = player.snake.items[0];
        switch (direction) {
            .up => head.y -= CELL,
            .down => head.y += CELL,
            .left => head.x -= CELL,
            .right => head.x += CELL,
        }
        if (player.pending_growth > 0) {
            const tail = player.snake.items[player.snake.items.len - 1];
            player.snake.appendAssumeCapacity(tail);
            player.pending_growth -= 1;
        }
        var i = player.snake.items.len - 1;
        while (i > 0) : (i -= 1) player.snake.items[i] = player.snake.items[i - 1];
        player.snake.items[0] = head;
    }

    /// Removes and returns one real body cell while preserving a playable
    /// minimum length. The caller owns any remnant created from the returned
    /// cell; this type intentionally performs no lobby allocation.
    pub fn shedTail(player: *Player, min_cells: usize) ?CellPos {
        if (player.snake.items.len <= min_cells) return null;
        return player.snake.pop();
    }
};

test "growth allocation failure leaves movement state unchanged" {
    var storage: [@sizeOf(CellPos)]u8 align(@alignOf(CellPos)) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();

    var connection: Conn = .{ .fd = -1 };
    var player: Player = .{
        .id = "id",
        .name = @constCast("name"),
        .color_hex = @constCast("#fff"),
        .conn = &connection,
    };
    defer player.snake.deinit(allocator);
    try player.snake.ensureTotalCapacityPrecise(allocator, 1);
    player.snake.appendAssumeCapacity(.{ .x = CELL, .y = CELL });
    player.pending_growth = 1;
    player.queue[0] = .right;
    player.queue_len = 1;

    player.applyMove(allocator);

    try std.testing.expectEqual(@as(?Direction, null), player.dir);
    try std.testing.expectEqual(@as(usize, 1), player.queue_len);
    try std.testing.expectEqual(@as(i64, 1), player.pending_growth);
    try std.testing.expectEqualSlices(CellPos, &.{.{ .x = CELL, .y = CELL }}, player.snake.items);
}

test "game modes expose distinct classical arcade and snek_io behavior" {
    // classical / arcade remain strictly themselves; snek_io is neither.
    try std.testing.expect(GameMode.classical.isClassical());
    try std.testing.expect(!GameMode.classical.isArcade());
    try std.testing.expect(!GameMode.arcade.isClassical());
    try std.testing.expect(GameMode.arcade.isArcade());
    try std.testing.expect(!GameMode.snek_io.isClassical());
    try std.testing.expect(!GameMode.snek_io.isArcade());
    try std.testing.expect(GameMode.arcade != GameMode.snek_io);
    try std.testing.expect(GameMode.classical != GameMode.snek_io);
    try std.testing.expectEqualStrings("classical", GameMode.classical.wireName());
    try std.testing.expectEqualStrings("arcade", GameMode.arcade.wireName());
    try std.testing.expectEqualStrings("snek_io", GameMode.snek_io.wireName());
    try std.testing.expect(@intFromEnum(GameMode.snek_io) == 2);
}

test "tail shedding preserves the configured minimum length" {
    const allocator = std.testing.allocator;
    var connection: Conn = .{ .fd = -1 };
    var player: Player = .{
        .id = "id",
        .name = @constCast("name"),
        .color_hex = @constCast("#fff"),
        .conn = &connection,
    };
    defer player.snake.deinit(allocator);
    try player.snake.appendSlice(allocator, &.{
        .{ .x = 3 * CELL, .y = CELL },
        .{ .x = 2 * CELL, .y = CELL },
        .{ .x = CELL, .y = CELL },
    });

    try std.testing.expectEqual(CellPos{ .x = CELL, .y = CELL }, player.shedTail(2).?);
    try std.testing.expectEqual(@as(usize, 2), player.snake.items.len);
    try std.testing.expectEqual(@as(?CellPos, null), player.shedTail(2));
    try std.testing.expectEqual(@as(usize, 2), player.snake.items.len);
}

pub const BonusApple = struct { pos: CellPos };
pub const Drop = struct { pos: CellPos, expires_at: i64 };
pub const Golden = struct { pos: CellPos, expires_at: i64 };
pub const Remnant = struct { pos: CellPos, expires_at: i64 };
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
    /// Lobby passwords are never retained in plaintext. A fixed-size digest
    /// also keeps every lobby allocation-free regardless of protection.
    password_salt: [16]u8 = @splat(0),
    password_hash: [32]u8 = @splat(0),
    password_protected: bool = false,
    /// Zero keeps a room invite-only. Values 2...32 make a passwordless room
    /// discoverable by Quick Join until its active snakes reach this soft
    /// target; retained game-over chat members do not make a room look full.
    public_target: u8 = 0,
    /// Creator-selected active-player ceiling. Public creation exposes 16 or
    /// 32; an operator-level limit may clamp the stored value lower.
    max_players: u8 = 16,
    /// Shared, allocation-free chat token bucket. Access is serialized by the
    /// lobby mutex alongside membership and broadcast fan-out.
    chat_tokens: u8 = LOBBY_CHAT_TOKEN_CAPACITY,
    chat_last_refill_ms: i64 = 0,
    /// The creator fixes this for the lobby lifetime. Classical must be
    /// explicit; Arcade is the default mode for new lobbies.
    mode: GameMode = .arcade,
    /// Snek IO simulation state, allocated only for snek_io lobbies in
    /// main.createLobbyLocked and freed by main.destroyLobby. Null for
    /// classical/arcade lobbies, which pay zero cost for the snek module.
    snek: ?*snek.Snek = null,
    /// Optional arena rule chosen by the lobby creator. Crossing any edge
    /// re-enters on the opposite edge instead of counting as a wall death.
    wrap_walls: bool = false,
    /// Reactor-owned. Generated lobbies do not acquire a simulation thread
    /// until their first successful player join.
    worker_assigned: bool = false,
    mutex: std.Io.Mutex = .init,
    rng: std.Random.DefaultPrng = undefined,
    /// Stable insertion order is protocol-significant; membership is capped at
    /// 32, so a pointer list is smaller and cheaper than a string hash map.
    players: std.ArrayListUnmanaged(*Player) = .empty,
    /// Eliminated connections remain attached for game-over chat, while their
    /// binary death replay ends at Conn.spectating_until. Callers enforce
    /// MAX_SPECTATORS and the process-wide retained-member cap before append;
    /// pointers never outlive their reactor-owned connections.
    spectators: std.ArrayListUnmanaged(*Conn) = .empty,
    food: CellPos,
    bonus: std.ArrayListUnmanaged(BonusApple) = .empty,
    drops: std.ArrayListUnmanaged(Drop) = .empty,
    golden: ?Golden = null,
    next_drop_at: i64 = 0,
    next_golden_at: i64 = 0,
    remains: std.ArrayListUnmanaged(Remnant) = .empty,
    feast_until: i64 = 0,
    next_feast_at: i64 = 0,
    bounty_slot: ?u8 = null,
    last_empty_at: i64 = 0,
    roster_wire: std.ArrayListUnmanaged(u8) = .empty,
    roster_dirty: bool = true,
    snapshot_valid: bool = false,
    snapshot_sequence: u16 = 0,
    snapshot_since_keyframe: u8 = 0,
    snapshot_player_count: u8 = 0,
    snapshot_previous: [32]SnapshotPlayerState = [_]SnapshotPlayerState{.{}} ** 32,
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
    /// Reactor-only hint: retain complete HTTP responses until the current
    /// pipelined input batch can be emitted with one bounded writev.
    http_batching: bool = false,
    mode: enum { http, websocket } = .http,
    want_write: bool = false,
    close_after_write: bool = false,
    closing: bool = false,
    poisoned: bool = false,
    next_ping_ms: i64 = 0,
    awaiting_pong_since: ?i64 = null,
    last_activity_ms: i64 = 0,
    /// Per-connection token bucket for live lobby chat. New connections start
    /// full; main.zig refills lazily from `chat_last_refill_ms`.
    chat_tokens: u8 = CHAT_TOKEN_CAPACITY,
    chat_last_refill_ms: i64 = 0,
    spectating_until: i64 = 0,
    spectate_focus: ?CellPos = null,
    spectate_score: i64 = 0,
    /// Visibility affects snapshot delivery only. The lobby worker continues
    /// to simulate this player's snake at the normal authoritative tick rate.
    snapshot_hidden: std.atomic.Value(bool) = .init(false),
    /// Latest absolute Snek IO steer angle (packet 6) in u16 quantum,
    /// 0..65535 -> [0, 2*pi) when the tick slice applies it. Single
    /// latest-wins slot: bursts coalesce and are never queued (design §2.5).
    steer_angle: ?u16 = null,
    snapshot_needs_keyframe: std.atomic.Value(bool) = .init(false),
    next_background_snapshot_ms: std.atomic.Value(i64) = .init(0),
    player: ?*Player = null,
    lobby: ?*Lobby = null,

    pub fn sidSlice(connection: *Conn) []const u8 {
        return connection.sid[0..SID_LEN];
    }
};
