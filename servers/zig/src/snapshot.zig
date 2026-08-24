//! Versioned binary world snapshots with bounded, recoverable temporal deltas.
//!
//! Frame header (little endian):
//!   "SN", version:u8, sequence:u16, kind_and_players:u8
//! `kind_and_players` bit 7 selects a delta, bits 0..5 hold the player count,
//! and bit 6 is zero. Sequence continuity names the delta base implicitly.
//!
//! Keyframe player:
//!   score:i32, cells:u16, body
//! `cells` bit 15 selects a packed body: absolute head x/y followed by four
//! 2-bit segment directions per byte. Non-contiguous bodies safely fall back
//! to absolute x/y pairs.
//!
//! Delta player: flags:u8, optional score:i32. Bits 0..1 select unchanged,
//! shifted, shifted-and-grown, or shifted-and-shrunk; bit 2 marks a score;
//! bits 3..4 encode the new-head direction and bit 5 selects a straight
//! two-cell move. The client reconstructs both heads from its previous state,
//! avoiding boost ticks falling back to full-body keyframes.
//! World counts share one byte: bonus count in bits 0..3, drop count in bits
//! 4..5, golden presence in bit 6, and bit 7 selects the Arcade v2 extension.
//! The extension starts with a byte containing a 6-bit remains count, feast in
//! bit 6, and bounty presence in bit 7. Each remain is x/y/ttl:u16, followed by
//! optional feast ttl:u16 and bounty roster slot:u8.
//! A delta must be the wrapping successor of the client's accepted sequence.
//! Missed deltas are therefore ignored until the next periodic keyframe, and
//! roster changes invalidate history.

const std = @import("std");
const config = @import("config.zig");
const model = @import("model.zig");

pub const VERSION: u8 = 5;
pub const KEYFRAME_INTERVAL: u8 = 30;
pub const MAX_PLAYERS: usize = 32;
pub const PACKED_BIT: u16 = 0x8000;
pub const CELL_COUNT_MASK: u16 = 0x7fff;
const HEADER_KIND_BIT: u8 = 0x80;
const HEADER_PLAYER_MASK: u8 = 0x3f;
const WORLD_BONUS_MASK: u8 = 0x0f;
const WORLD_DROP_MASK: u8 = 0x03;
const WORLD_DROP_SHIFT: u3 = 4;
const WORLD_GOLDEN_BIT: u8 = 0x40;
const WORLD_ARCADE_BIT: u8 = 0x80;
const ARCADE_REMAINS_MASK: u8 = 0x3f;
const ARCADE_FEAST_BIT: u8 = 0x40;
const ARCADE_BOUNTY_BIT: u8 = 0x80;

comptime {
    if (config.GRID_COLS > @as(i32, std.math.maxInt(u8)) + 1 or config.GRID_ROWS > @as(i32, std.math.maxInt(u8)) + 1)
        @compileError("canonical board coordinates must fit in snapshot cell bytes");
    if (config.MAX_CELLS > @as(usize, CELL_COUNT_MASK))
        @compileError("canonical board cell count must fit in the snapshot cell count");
}

pub const Kind = enum(u8) { keyframe = 0, delta = 1 };
pub const BuildResult = struct { bytes: []const u8, kind: Kind, sequence: u16 };
const CellMode = enum(u2) { unchanged = 0, shift = 1, grow = 2, shrink = 3 };
const Transition = struct {
    mode: CellMode,
    direction: u2 = 0,
    double_step: bool = false,
    valid: bool = true,
};

fn appendInt(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try buffer.appendSlice(allocator, &encoded);
}

fn protocolScore(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn cell(value: i32) u8 {
    return @intCast(std.math.clamp(@divTrunc(value, model.CELL), 0, std.math.maxInt(u8)));
}

fn ttl(expires_at: i64, now: i64) u16 {
    return @intCast(std.math.clamp(expires_at - now, 0, std.math.maxInt(u16)));
}

/// Direction from one snake cell to the next cell toward its tail.
fn segmentDirection(from: model.CellPos, to: model.CellPos) ?u2 {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    if (dx == 0 and dy == -model.CELL) return 0;
    if (dx == 0 and dy == model.CELL) return 1;
    if (dx == -model.CELL and dy == 0) return 2;
    if (dx == model.CELL and dy == 0) return 3;
    return null;
}

fn canPack(positions: []const model.CellPos) bool {
    if (positions.len == 0) return false;
    for (positions[1..], 1..) |position, index| {
        if (segmentDirection(positions[index - 1], position) == null) return false;
    }
    return true;
}

fn appendPackedBody(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, positions: []const model.CellPos) !void {
    try buffer.append(allocator, cell(positions[0].x));
    try buffer.append(allocator, cell(positions[0].y));
    var index: usize = 1;
    while (index < positions.len) {
        var packed_byte: u8 = 0;
        var slot: u3 = 0;
        while (slot < 4 and index < positions.len) : ({
            slot += 1;
            index += 1;
        }) {
            const direction = segmentDirection(positions[index - 1], positions[index]) orelse unreachable;
            packed_byte |= @as(u8, direction) << @intCast(slot * 2);
        }
        try buffer.append(allocator, packed_byte);
    }
}

fn appendKeyframePlayer(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, player: *const model.Player) !void {
    try appendInt(buffer, allocator, i32, protocolScore(player.score));
    const count: u16 = @intCast(@min(player.snake.items.len, config.MAX_CELLS));
    const positions = player.snake.items[0..count];
    const is_packed = canPack(positions);
    try appendInt(buffer, allocator, u16, count | if (is_packed) PACKED_BIT else 0);
    if (is_packed) {
        try appendPackedBody(buffer, allocator, positions);
    } else {
        for (positions) |position| {
            try buffer.append(allocator, cell(position.x));
            try buffer.append(allocator, cell(position.y));
        }
    }
}

fn stateFor(player: *const model.Player) model.SnapshotPlayerState {
    const count: u16 = @intCast(@min(player.snake.items.len, config.MAX_CELLS));
    const head = player.snake.items[0];
    return .{
        .score = protocolScore(player.score),
        .cells = count,
        .head_x = cell(head.x),
        .head_y = cell(head.y),
    };
}

const Movement = struct { direction: u2, steps: u2 };

fn movement(previous: model.SnapshotPlayerState, current: model.SnapshotPlayerState) ?Movement {
    const dx = @as(i16, current.head_x) - @as(i16, previous.head_x);
    const dy = @as(i16, current.head_y) - @as(i16, previous.head_y);
    if (dx == 0 and (dy == -1 or dy == -2)) return .{ .direction = 0, .steps = @intCast(-dy) };
    if (dx == 0 and (dy == 1 or dy == 2)) return .{ .direction = 1, .steps = @intCast(dy) };
    if (dy == 0 and (dx == -1 or dx == -2)) return .{ .direction = 2, .steps = @intCast(-dx) };
    if (dy == 0 and (dx == 1 or dx == 2)) return .{ .direction = 3, .steps = @intCast(dx) };
    return null;
}

fn steppedCell(previous: model.SnapshotPlayerState, direction: u2) struct { x: u8, y: u8 } {
    var x = previous.head_x;
    var y = previous.head_y;
    switch (direction) {
        0 => y -= 1,
        1 => y += 1,
        2 => x -= 1,
        3 => x += 1,
    }
    return .{ .x = x, .y = y };
}

fn transition(player: *const model.Player, current: model.SnapshotPlayerState, previous: model.SnapshotPlayerState) Transition {
    if (player.snake.items.len == 0 or player.snake.items.len > config.MAX_CELLS) return .{ .mode = .unchanged, .valid = false };
    if (current.cells == previous.cells and current.head_x == previous.head_x and current.head_y == previous.head_y) return .{ .mode = .unchanged };
    const move = movement(previous, current) orelse return .{ .mode = .unchanged, .valid = false };
    const mode: CellMode = if (current.cells == previous.cells)
        .shift
    else if (@as(u32, current.cells) == @as(u32, previous.cells) + 1)
        .grow
    else if (@as(u32, current.cells) + 1 == @as(u32, previous.cells))
        .shrink
    else
        return .{ .mode = .unchanged, .valid = false };
    if (move.steps == 1) {
        if (current.cells > 1) {
            const second = player.snake.items[1];
            if (cell(second.x) != previous.head_x or cell(second.y) != previous.head_y)
                return .{ .mode = .unchanged, .valid = false };
        }
    } else {
        const middle = steppedCell(previous, move.direction);
        if (current.cells > 1) {
            const second = player.snake.items[1];
            if (cell(second.x) != middle.x or cell(second.y) != middle.y)
                return .{ .mode = .unchanged, .valid = false };
        }
        if (current.cells > 2) {
            const third = player.snake.items[2];
            if (cell(third.x) != previous.head_x or cell(third.y) != previous.head_y)
                return .{ .mode = .unchanged, .valid = false };
        }
    }
    return .{ .mode = mode, .direction = move.direction, .double_step = move.steps == 2 };
}

fn appendDeltaPlayer(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, current: model.SnapshotPlayerState, previous: model.SnapshotPlayerState, change: Transition) !void {
    std.debug.assert(change.valid);
    var flags: u8 = @intFromEnum(change.mode);
    if (current.score != previous.score) flags |= 1 << 2;
    if (change.mode != .unchanged) {
        flags |= @as(u8, change.direction) << 3;
        if (change.double_step) flags |= 1 << 5;
    }
    try buffer.append(allocator, flags);
    if (current.score != previous.score) try appendInt(buffer, allocator, i32, current.score);
}

fn appendHeader(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, kind: Kind, sequence: u16, player_count: usize) !void {
    std.debug.assert(player_count <= MAX_PLAYERS);
    try buffer.appendSlice(allocator, "SN");
    try buffer.append(allocator, VERSION);
    try appendInt(buffer, allocator, u16, sequence);
    const kind_bit: u8 = if (kind == .delta) HEADER_KIND_BIT else 0;
    try buffer.append(allocator, kind_bit | (@as(u8, @intCast(player_count)) & HEADER_PLAYER_MASK));
}

fn appendWorld(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, lobby: *model.Lobby, now: i64) !void {
    const bonus_count = @min(lobby.bonus.items.len, WORLD_BONUS_MASK);
    const drop_count = @min(lobby.drops.items.len, WORLD_DROP_MASK);
    const golden_bit: u8 = if (lobby.golden != null) WORLD_GOLDEN_BIT else 0;
    const has_arcade_extension = lobby.mode == .arcade_v2;
    const world = @as(u8, @intCast(bonus_count)) |
        (@as(u8, @intCast(drop_count)) << WORLD_DROP_SHIFT) | golden_bit |
        (if (has_arcade_extension) WORLD_ARCADE_BIT else 0);
    try buffer.append(allocator, world);
    for (lobby.bonus.items[0..bonus_count]) |bonus| {
        try buffer.append(allocator, cell(bonus.pos.x));
        try buffer.append(allocator, cell(bonus.pos.y));
    }
    for (lobby.drops.items[0..drop_count]) |drop| {
        try buffer.append(allocator, cell(drop.pos.x));
        try buffer.append(allocator, cell(drop.pos.y));
        try appendInt(buffer, allocator, u16, ttl(drop.expires_at, now));
    }
    if (lobby.golden) |golden| {
        try buffer.append(allocator, cell(golden.pos.x));
        try buffer.append(allocator, cell(golden.pos.y));
        try appendInt(buffer, allocator, u16, ttl(golden.expires_at, now));
    }
    if (has_arcade_extension) {
        const remains_count = @min(lobby.remains.items.len, model.MAX_REMAINS);
        const feast_active = lobby.feast_until > now;
        const player_count = @min(lobby.players.items.len, MAX_PLAYERS);
        const bounty_slot = if (lobby.bounty_slot) |slot|
            if (slot < player_count) slot else null
        else
            null;
        const arcade = @as(u8, @intCast(remains_count)) & ARCADE_REMAINS_MASK |
            (if (feast_active) ARCADE_FEAST_BIT else 0) |
            (if (bounty_slot != null) ARCADE_BOUNTY_BIT else 0);
        try buffer.append(allocator, arcade);
        for (lobby.remains.items[0..remains_count]) |remain| {
            try buffer.append(allocator, cell(remain.pos.x));
            try buffer.append(allocator, cell(remain.pos.y));
            try appendInt(buffer, allocator, u16, ttl(remain.expires_at, now));
        }
        if (feast_active) try appendInt(buffer, allocator, u16, ttl(lobby.feast_until, now));
        if (bounty_slot) |slot| try buffer.append(allocator, slot);
    }
}

pub fn invalidate(lobby: *model.Lobby) void {
    lobby.snapshot_valid = false;
}

/// Encode a complete keyframe at an existing global sequence without changing
/// the lobby's delta history. This is used for clients that intentionally
/// skipped foreground deltas while their document was hidden; all such clients
/// in a lobby share the same immutable recovery frame.
pub fn buildIndependentKeyframeInto(
    buffer: *std.ArrayListUnmanaged(u8),
    lobby: *model.Lobby,
    now: i64,
    sequence: u16,
    allocator: std.mem.Allocator,
) !BuildResult {
    const player_count = @min(lobby.players.items.len, MAX_PLAYERS);
    buffer.clearRetainingCapacity();
    try appendHeader(buffer, allocator, .keyframe, sequence, player_count);
    for (lobby.players.items[0..player_count]) |player| try appendKeyframePlayer(buffer, allocator, player);
    try appendWorld(buffer, allocator, lobby, now);
    return .{ .bytes = buffer.items, .kind = .keyframe, .sequence = sequence };
}

pub fn buildInto(buffer: *std.ArrayListUnmanaged(u8), lobby: *model.Lobby, now: i64, allocator: std.mem.Allocator) !BuildResult {
    const player_count = @min(lobby.players.items.len, MAX_PLAYERS);
    var current_states: [MAX_PLAYERS]model.SnapshotPlayerState = undefined;
    var changes: [MAX_PLAYERS]Transition = undefined;
    for (lobby.players.items[0..player_count], 0..) |player, index| current_states[index] = stateFor(player);

    var delta_ok = lobby.snapshot_valid and player_count == lobby.snapshot_player_count and lobby.snapshot_since_keyframe < KEYFRAME_INTERVAL - 1;
    if (delta_ok) {
        for (lobby.players.items[0..player_count], 0..) |player, index| {
            changes[index] = transition(player, current_states[index], lobby.snapshot_previous[index]);
            if (!changes[index].valid) {
                delta_ok = false;
                break;
            }
        }
    }
    const kind: Kind = if (delta_ok) .delta else .keyframe;
    const sequence = lobby.snapshot_sequence +% 1;

    buffer.clearRetainingCapacity();
    try appendHeader(buffer, allocator, kind, sequence, player_count);
    for (lobby.players.items[0..player_count], 0..) |player, index| {
        if (kind == .keyframe) try appendKeyframePlayer(buffer, allocator, player) else try appendDeltaPlayer(buffer, allocator, current_states[index], lobby.snapshot_previous[index], changes[index]);
    }
    try appendWorld(buffer, allocator, lobby, now);

    if (lobby.players.items.len <= MAX_PLAYERS) {
        @memcpy(lobby.snapshot_previous[0..player_count], current_states[0..player_count]);
        lobby.snapshot_valid = true;
        lobby.snapshot_player_count = @intCast(player_count);
        lobby.snapshot_sequence = sequence;
        lobby.snapshot_since_keyframe = if (kind == .keyframe) 0 else lobby.snapshot_since_keyframe + 1;
    } else lobby.snapshot_valid = false;
    return .{ .bytes = buffer.items, .kind = kind, .sequence = sequence };
}

pub fn build(buffer: *std.ArrayListUnmanaged(u8), lobby: *model.Lobby, now: i64, allocator: std.mem.Allocator) !BuildResult {
    return buildInto(buffer, lobby, now, allocator);
}

test "v5 header represents all 32 roster slots without colliding with delta bit" {
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try appendHeader(&wire, std.testing.allocator, .keyframe, 7, MAX_PLAYERS);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', VERSION, 7, 0, 0x20 }, wire.items);
    wire.clearRetainingCapacity();
    try appendHeader(&wire, std.testing.allocator, .delta, 8, MAX_PLAYERS);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', VERSION, 8, 0, 0xa0 }, wire.items);
}

test "v5 builder retains and deltas a complete 32-player roster" {
    const allocator = std.testing.allocator;
    var connection = model.Conn{ .fd = -1 };
    var storage: [MAX_PLAYERS]model.Player = undefined;
    var initialized: usize = 0;
    defer for (storage[0..initialized]) |*player| player.snake.deinit(allocator);

    var lobby = model.Lobby{ .id = @constCast("large"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(allocator);
    for (&storage, 0..) |*player, index| {
        player.* = .{
            .id = @constCast("player"),
            .name = @constCast("player"),
            .color_hex = @constCast("#123456"),
            .conn = &connection,
        };
        initialized += 1;
        try player.snake.append(allocator, .{ .x = @as(i32, @intCast(index)) * model.CELL, .y = 3 * model.CELL });
        try lobby.players.append(allocator, player);
    }

    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);
    const keyframe = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.keyframe, keyframe.kind);
    try std.testing.expectEqual(@as(u8, 0x20), keyframe.bytes[5]);
    try std.testing.expectEqual(@as(u8, 32), lobby.snapshot_player_count);
    try std.testing.expect(lobby.snapshot_valid);

    const delta = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.delta, delta.kind);
    try std.testing.expectEqual(@as(u8, 0xa0), delta.bytes[5]);
}

test "wall wrapping falls back to an absolute keyframe" {
    const allocator = std.testing.allocator;
    var connection = model.Conn{ .fd = -1 };
    var player = model.Player{
        .id = @constCast("wrap-player"),
        .name = @constCast("wrap-player"),
        .color_hex = @constCast("#123456"),
        .conn = &connection,
    };
    defer player.snake.deinit(allocator);
    try player.snake.append(allocator, .{
        .x = (config.GRID_COLS - 1) * model.CELL,
        .y = 10 * model.CELL,
    });
    var lobby = model.Lobby{ .id = @constCast("wrap"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(allocator);
    try lobby.players.append(allocator, &player);

    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);
    try std.testing.expectEqual(Kind.keyframe, (try buildInto(&wire, &lobby, 0, allocator)).kind);

    player.snake.items[0].x = 0;
    const wrapped = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.keyframe, wrapped.kind);
    try std.testing.expectEqual(@as(u8, 0), wrapped.bytes[12]);
    try std.testing.expectEqual(@as(u8, 10), wrapped.bytes[13]);
}

test "v5 keyframes and direction deltas have stable golden bytes" {
    const allocator = std.testing.allocator;
    var connection = model.Conn{ .fd = -1 };
    var player = model.Player{
        .id = @constCast("player"),
        .name = @constCast("player"),
        .color_hex = @constCast("#123456"),
        .conn = &connection,
    };
    defer player.snake.deinit(allocator);
    try player.snake.append(allocator, .{ .x = 2 * model.CELL, .y = 3 * model.CELL });
    var lobby = model.Lobby{ .id = @constCast("test"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(allocator);
    try lobby.players.append(allocator, &player);
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);

    const keyframe = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.keyframe, keyframe.kind);
    try std.testing.expectEqualSlices(u8, &.{
        'S', 'N', 5, 1, 0, 1,
        0,   0,   0, 0, 1, 0x80,
        2,   3,   0,
    }, keyframe.bytes);

    const unchanged = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.delta, unchanged.kind);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', 5, 2, 0, 0x81, 0, 0 }, unchanged.bytes);

    player.snake.items[0].x += model.CELL;
    const shifted = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', 5, 3, 0, 0x81, 0x19, 0 }, shifted.bytes);

    const old_head = player.snake.items[0];
    try player.snake.append(allocator, old_head);
    player.snake.items[0].x += model.CELL;
    player.score = 1;
    const grown = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqualSlices(u8, &.{
        'S',  'N', 5, 4, 0, 0x81,
        0x1e, 1,   0, 0, 0, 0,
    }, grown.bytes);
}

test "v5 boost deltas encode straight double steps and tail shrink without keyframes" {
    const allocator = std.testing.allocator;
    var connection = model.Conn{ .fd = -1 };
    var player = model.Player{
        .id = @constCast("boost"),
        .name = @constCast("boost"),
        .color_hex = @constCast("#123456"),
        .conn = &connection,
    };
    defer player.snake.deinit(allocator);
    try player.snake.appendSlice(allocator, &.{
        .{ .x = 5 * model.CELL, .y = 3 * model.CELL },
        .{ .x = 4 * model.CELL, .y = 3 * model.CELL },
        .{ .x = 3 * model.CELL, .y = 3 * model.CELL },
        .{ .x = 2 * model.CELL, .y = 3 * model.CELL },
        .{ .x = model.CELL, .y = 3 * model.CELL },
    });
    var lobby = model.Lobby{ .id = @constCast("boost"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(allocator);
    try lobby.players.append(allocator, &player);
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);

    _ = try buildInto(&wire, &lobby, 0, allocator);
    player.snake.items.len = 4;
    player.snake.items[0] = .{ .x = 7 * model.CELL, .y = 3 * model.CELL };
    player.snake.items[1] = .{ .x = 6 * model.CELL, .y = 3 * model.CELL };
    player.snake.items[2] = .{ .x = 5 * model.CELL, .y = 3 * model.CELL };
    player.snake.items[3] = .{ .x = 4 * model.CELL, .y = 3 * model.CELL };
    const shrunk = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.delta, shrunk.kind);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', 5, 2, 0, 0x81, 0x3b, 0 }, shrunk.bytes);

    try player.snake.append(allocator, .{ .x = 5 * model.CELL, .y = 3 * model.CELL });
    player.snake.items[0] = .{ .x = 9 * model.CELL, .y = 3 * model.CELL };
    player.snake.items[1] = .{ .x = 8 * model.CELL, .y = 3 * model.CELL };
    player.snake.items[2] = .{ .x = 7 * model.CELL, .y = 3 * model.CELL };
    player.snake.items[3] = .{ .x = 6 * model.CELL, .y = 3 * model.CELL };
    player.snake.items[4] = .{ .x = 5 * model.CELL, .y = 3 * model.CELL };
    const grown = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.delta, grown.kind);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', 5, 3, 0, 0x81, 0x3a, 0 }, grown.bytes);
}

test "v5 board-edge coordinates have stable golden bytes" {
    const allocator = std.testing.allocator;
    var connection = model.Conn{ .fd = -1 };
    var player = model.Player{
        .id = @constCast("edge"),
        .name = @constCast("edge"),
        .color_hex = @constCast("#123456"),
        .conn = &connection,
    };
    defer player.snake.deinit(allocator);
    try player.snake.append(allocator, .{
        .x = config.GRID_W - model.CELL,
        .y = config.GRID_H - model.CELL,
    });
    var lobby = model.Lobby{ .id = @constCast("edge"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(allocator);
    try lobby.players.append(allocator, &player);
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);

    const keyframe = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqualSlices(u8, &.{
        'S', 'N', 5, 1, 0, 1,
        0,   0,   0, 0, 1, 0x80,
        127, 71,  0,
    }, keyframe.bytes);
}

test "v5 packs world counts and golden presence into one stable byte" {
    const allocator = std.testing.allocator;
    var lobby = model.Lobby{ .id = @constCast("test"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.bonus.deinit(allocator);
    defer lobby.drops.deinit(allocator);
    try lobby.bonus.append(allocator, .{ .pos = .{ .x = 4 * model.CELL, .y = 5 * model.CELL } });
    try lobby.drops.append(allocator, .{
        .pos = .{ .x = 6 * model.CELL, .y = 7 * model.CELL },
        .expires_at = 1234,
    });
    lobby.golden = .{ .pos = .{ .x = 8 * model.CELL, .y = 9 * model.CELL }, .expires_at = 4321 };
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);

    const keyframe = try buildInto(&wire, &lobby, 100, allocator);
    try std.testing.expectEqualSlices(u8, &.{
        'S',  'N', 5, 1,    0,    0,
        0x51, 4,   5, 6,    7,    0x6e,
        0x04, 8,   9, 0x7d, 0x10,
    }, keyframe.bytes);
}

test "v5 Arcade extension has bounded remains feast and bounty bytes" {
    const allocator = std.testing.allocator;
    var connection = model.Conn{ .fd = -1 };
    var player = model.Player{
        .id = @constCast("player"),
        .name = @constCast("player"),
        .color_hex = @constCast("#123456"),
        .conn = &connection,
    };
    defer player.snake.deinit(allocator);
    try player.snake.append(allocator, .{ .x = 2 * model.CELL, .y = 3 * model.CELL });
    var lobby = model.Lobby{
        .id = @constCast("arcade-v2"),
        .food = .{ .x = 0, .y = 0 },
        .mode = .arcade_v2,
        .feast_until = 250,
        .bounty_slot = 0,
    };
    defer lobby.players.deinit(allocator);
    defer lobby.remains.deinit(allocator);
    try lobby.players.append(allocator, &player);
    try lobby.remains.append(allocator, .{ .pos = .{ .x = 4 * model.CELL, .y = 5 * model.CELL }, .expires_at = 200 });
    try lobby.remains.append(allocator, .{ .pos = .{ .x = 6 * model.CELL, .y = 7 * model.CELL }, .expires_at = std.math.maxInt(i64) });
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);

    const keyframe = try buildInto(&wire, &lobby, 100, allocator);
    try std.testing.expectEqualSlices(u8, &.{
        'S', 'N', 5,    1,    0,    1,
        0,   0,   0,    0,    1,    0x80,
        2,   3,   0x80, 0xc2, 4,    5,
        100, 0,   6,    7,    0xff, 0xff,
        150, 0,   0,
    }, keyframe.bytes);
}

test "independent keyframe preserves delta history and sequence wraps" {
    const allocator = std.testing.allocator;
    var connection = model.Conn{ .fd = -1 };
    var player = model.Player{
        .id = @constCast("player"),
        .name = @constCast("player"),
        .color_hex = @constCast("#123456"),
        .conn = &connection,
    };
    defer player.snake.deinit(allocator);
    try player.snake.append(allocator, .{ .x = model.CELL, .y = model.CELL });
    var lobby = model.Lobby{ .id = @constCast("test"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(allocator);
    try lobby.players.append(allocator, &player);
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);

    _ = try buildInto(&wire, &lobby, 0, allocator);
    const before_sequence = lobby.snapshot_sequence;
    const before_since = lobby.snapshot_since_keyframe;
    const before_state = lobby.snapshot_previous;
    const independent = try buildIndependentKeyframeInto(&wire, &lobby, 0, before_sequence, allocator);
    try std.testing.expectEqual(Kind.keyframe, independent.kind);
    try std.testing.expectEqual(before_sequence, lobby.snapshot_sequence);
    try std.testing.expectEqual(before_since, lobby.snapshot_since_keyframe);
    try std.testing.expectEqualSlices(model.SnapshotPlayerState, &before_state, &lobby.snapshot_previous);

    lobby.snapshot_sequence = std.math.maxInt(u16);
    lobby.snapshot_valid = true;
    lobby.snapshot_player_count = 1;
    lobby.snapshot_since_keyframe = 0;
    lobby.snapshot_previous[0] = stateFor(&player);
    const wrapped = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.delta, wrapped.kind);
    try std.testing.expectEqual(@as(u16, 0), wrapped.sequence);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x81 }, wrapped.bytes[3..6]);
}
