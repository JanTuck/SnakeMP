//! Versioned binary world snapshots with bounded, recoverable temporal deltas.
//!
//! Frame header (little endian):
//!   "SN", version:u8, kind:u8, sequence:u16, base_sequence:u16, players:u8
//!
//! Keyframe player:
//!   score:i32, cells:u16, body
//! `cells` bit 15 selects a packed body: absolute head x/y followed by four
//! 2-bit segment directions per byte. Non-contiguous bodies safely fall back
//! to absolute x/y pairs.
//!
//! Delta player: flags:u8, optional score:i32. Bits 0..1 select unchanged,
//! shifted, or shifted-and-grown; bit 2 marks a score; bits 3..4 encode the
//! new-head direction for a moving snake. The client reconstructs the adjacent
//! head from its previous state, avoiding two coordinate bytes per move.
//! A delta names its exact base sequence. Missed deltas are therefore ignored
//! until the next periodic keyframe, and roster changes invalidate history.

const std = @import("std");
const model = @import("model.zig");

pub const VERSION: u8 = 3;
pub const KEYFRAME_INTERVAL: u8 = 30;
pub const MAX_PLAYERS: usize = 16;
pub const PACKED_BIT: u16 = 0x8000;
pub const CELL_COUNT_MASK: u16 = 0x7fff;

pub const Kind = enum(u8) { keyframe = 0, delta = 1 };
pub const BuildResult = struct { bytes: []const u8, kind: Kind, sequence: u16 };
const CellMode = enum(u2) { unchanged = 0, shift = 1, grow = 2, invalid = 3 };
const Transition = struct { mode: CellMode, direction: u2 = 0 };

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
    const count: u16 = @intCast(@min(player.snake.items.len, CELL_COUNT_MASK));
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
    const count: u16 = @intCast(@min(player.snake.items.len, CELL_COUNT_MASK));
    const head = player.snake.items[0];
    return .{
        .score = protocolScore(player.score),
        .cells = count,
        .head_x = cell(head.x),
        .head_y = cell(head.y),
    };
}

fn movementDirection(previous: model.SnapshotPlayerState, current: model.SnapshotPlayerState) ?u2 {
    const dx = @as(i16, current.head_x) - @as(i16, previous.head_x);
    const dy = @as(i16, current.head_y) - @as(i16, previous.head_y);
    if (dx == 0 and dy == -1) return 0;
    if (dx == 0 and dy == 1) return 1;
    if (dx == -1 and dy == 0) return 2;
    if (dx == 1 and dy == 0) return 3;
    return null;
}

fn transition(player: *const model.Player, current: model.SnapshotPlayerState, previous: model.SnapshotPlayerState) Transition {
    if (player.snake.items.len == 0 or player.snake.items.len > CELL_COUNT_MASK) return .{ .mode = .invalid };
    if (current.cells == previous.cells and current.head_x == previous.head_x and current.head_y == previous.head_y) return .{ .mode = .unchanged };
    const direction = movementDirection(previous, current) orelse return .{ .mode = .invalid };
    const mode: CellMode = if (current.cells == previous.cells)
        .shift
    else if (@as(u32, current.cells) == @as(u32, previous.cells) + 1)
        .grow
    else
        return .{ .mode = .invalid };
    if (current.cells > 1) {
        const second = player.snake.items[1];
        if (cell(second.x) != previous.head_x or cell(second.y) != previous.head_y) return .{ .mode = .invalid };
    }
    return .{ .mode = mode, .direction = direction };
}

fn appendDeltaPlayer(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, current: model.SnapshotPlayerState, previous: model.SnapshotPlayerState, change: Transition) !void {
    std.debug.assert(change.mode != .invalid);
    var flags: u8 = @intFromEnum(change.mode);
    if (current.score != previous.score) flags |= 1 << 2;
    if (change.mode == .shift or change.mode == .grow) flags |= @as(u8, change.direction) << 3;
    try buffer.append(allocator, flags);
    if (current.score != previous.score) try appendInt(buffer, allocator, i32, current.score);
}

fn appendWorld(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, lobby: *model.Lobby, now: i64) !void {
    const bonus_count = @min(lobby.bonus.items.len, std.math.maxInt(u8));
    try buffer.append(allocator, @intCast(bonus_count));
    for (lobby.bonus.items[0..bonus_count]) |bonus| {
        try buffer.append(allocator, cell(bonus.pos.x));
        try buffer.append(allocator, cell(bonus.pos.y));
    }
    const drop_count = @min(lobby.drops.items.len, std.math.maxInt(u8));
    try buffer.append(allocator, @intCast(drop_count));
    for (lobby.drops.items[0..drop_count]) |drop| {
        try buffer.append(allocator, cell(drop.pos.x));
        try buffer.append(allocator, cell(drop.pos.y));
        try appendInt(buffer, allocator, u16, ttl(drop.expires_at, now));
    }
    if (lobby.golden) |golden| {
        try buffer.append(allocator, 1);
        try buffer.append(allocator, cell(golden.pos.x));
        try buffer.append(allocator, cell(golden.pos.y));
        try appendInt(buffer, allocator, u16, ttl(golden.expires_at, now));
    } else try buffer.append(allocator, 0);
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
    try buffer.appendSlice(allocator, "SN");
    try buffer.append(allocator, VERSION);
    try buffer.append(allocator, @intFromEnum(Kind.keyframe));
    try appendInt(buffer, allocator, u16, sequence);
    try appendInt(buffer, allocator, u16, sequence);
    try buffer.append(allocator, @intCast(player_count));
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
            if (changes[index].mode == .invalid) {
                delta_ok = false;
                break;
            }
        }
    }
    const kind: Kind = if (delta_ok) .delta else .keyframe;
    const base_sequence = lobby.snapshot_sequence;
    const sequence = base_sequence +% 1;

    buffer.clearRetainingCapacity();
    try buffer.appendSlice(allocator, "SN");
    try buffer.append(allocator, VERSION);
    try buffer.append(allocator, @intFromEnum(kind));
    try appendInt(buffer, allocator, u16, sequence);
    try appendInt(buffer, allocator, u16, if (kind == .keyframe) sequence else base_sequence);
    try buffer.append(allocator, @intCast(player_count));
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

test "v3 keyframes and direction deltas have stable golden bytes" {
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
        'S', 'N', 3, 0, 1, 0,    1, 0, 1,
        0,   0,   0, 0, 1, 0x80, 2, 3, 0,
        0,   0,
    }, keyframe.bytes);

    const unchanged = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqual(Kind.delta, unchanged.kind);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', 3, 1, 2, 0, 1, 0, 1, 0, 0, 0, 0 }, unchanged.bytes);

    player.snake.items[0].x += model.CELL;
    const shifted = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'N', 3, 1, 3, 0, 2, 0, 1, 0x19, 0, 0, 0 }, shifted.bytes);

    const old_head = player.snake.items[0];
    try player.snake.append(allocator, old_head);
    player.snake.items[0].x += model.CELL;
    player.score = 1;
    const grown = try buildInto(&wire, &lobby, 0, allocator);
    try std.testing.expectEqualSlices(u8, &.{
        'S',  'N', 3, 1, 4, 0, 3, 0, 1,
        0x1e, 1,   0, 0, 0, 0, 0, 0,
    }, grown.bytes);
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
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0xff, 0xff }, wrapped.bytes[4..8]);
}
