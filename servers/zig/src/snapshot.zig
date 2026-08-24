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
//! Delta player: flags:u8, optional score:i32, optional new head x/y. Bits
//! 0..1 select unchanged, shifted, or shifted-and-grown.
//! A delta names its exact base sequence. Missed deltas are therefore ignored
//! until the next periodic keyframe, and roster changes invalidate history.

const std = @import("std");
const model = @import("model.zig");

pub const VERSION: u8 = 2;
pub const KEYFRAME_INTERVAL: u8 = 30;
pub const MAX_PLAYERS: usize = 16;
pub const PACKED_BIT: u16 = 0x8000;
pub const CELL_COUNT_MASK: u16 = 0x7fff;

pub const Kind = enum(u8) { keyframe = 0, delta = 1 };
pub const BuildResult = struct { bytes: []const u8, kind: Kind, sequence: u16 };
const CellMode = enum(u2) { unchanged = 0, shift = 1, grow = 2, invalid = 3 };

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

fn transition(player: *const model.Player, previous: model.SnapshotPlayerState) CellMode {
    if (player.snake.items.len == 0 or player.snake.items.len > CELL_COUNT_MASK) return .invalid;
    const current = stateFor(player);
    if (current.cells == previous.cells and current.head_x == previous.head_x and current.head_y == previous.head_y) return .unchanged;
    if (current.head_x == previous.head_x and current.head_y == previous.head_y) return .invalid;
    const mode: CellMode = if (current.cells == previous.cells)
        .shift
    else if (@as(u32, current.cells) == @as(u32, previous.cells) + 1)
        .grow
    else
        return .invalid;
    if (current.cells > 1) {
        const second = player.snake.items[1];
        if (cell(second.x) != previous.head_x or cell(second.y) != previous.head_y) return .invalid;
    }
    return mode;
}

fn canDelta(lobby: *model.Lobby, player_count: usize) bool {
    if (!lobby.snapshot_valid or player_count > MAX_PLAYERS or player_count != lobby.snapshot_player_count) return false;
    if (lobby.snapshot_since_keyframe >= KEYFRAME_INTERVAL - 1) return false;
    for (lobby.players.values(), 0..) |player, index| {
        if (transition(player, lobby.snapshot_previous[index]) == .invalid) return false;
    }
    return true;
}

fn appendDeltaPlayer(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, player: *const model.Player, previous: model.SnapshotPlayerState) !void {
    const current = stateFor(player);
    const mode = transition(player, previous);
    std.debug.assert(mode != .invalid);
    var flags: u8 = @intFromEnum(mode);
    if (current.score != previous.score) flags |= 1 << 2;
    try buffer.append(allocator, flags);
    if (current.score != previous.score) try appendInt(buffer, allocator, i32, current.score);
    if (mode == .shift or mode == .grow) {
        try buffer.append(allocator, current.head_x);
        try buffer.append(allocator, current.head_y);
    }
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
    const player_count = @min(lobby.players.count(), MAX_PLAYERS);
    buffer.clearRetainingCapacity();
    try buffer.appendSlice(allocator, "SN");
    try buffer.append(allocator, VERSION);
    try buffer.append(allocator, @intFromEnum(Kind.keyframe));
    try appendInt(buffer, allocator, u16, sequence);
    try appendInt(buffer, allocator, u16, sequence);
    try buffer.append(allocator, @intCast(player_count));
    for (lobby.players.values()[0..player_count]) |player| try appendKeyframePlayer(buffer, allocator, player);
    try appendWorld(buffer, allocator, lobby, now);
    return .{ .bytes = buffer.items, .kind = .keyframe, .sequence = sequence };
}

pub fn buildInto(buffer: *std.ArrayListUnmanaged(u8), lobby: *model.Lobby, now: i64, allocator: std.mem.Allocator) !BuildResult {
    const player_count = @min(lobby.players.count(), MAX_PLAYERS);
    const kind: Kind = if (canDelta(lobby, player_count)) .delta else .keyframe;
    const base_sequence = lobby.snapshot_sequence;
    const sequence = base_sequence +% 1;

    buffer.clearRetainingCapacity();
    try buffer.appendSlice(allocator, "SN");
    try buffer.append(allocator, VERSION);
    try buffer.append(allocator, @intFromEnum(kind));
    try appendInt(buffer, allocator, u16, sequence);
    try appendInt(buffer, allocator, u16, if (kind == .keyframe) sequence else base_sequence);
    try buffer.append(allocator, @intCast(player_count));
    for (lobby.players.values()[0..player_count], 0..) |player, index| {
        if (kind == .keyframe) try appendKeyframePlayer(buffer, allocator, player) else try appendDeltaPlayer(buffer, allocator, player, lobby.snapshot_previous[index]);
    }
    try appendWorld(buffer, allocator, lobby, now);

    if (lobby.players.count() <= MAX_PLAYERS) {
        for (lobby.players.values(), 0..) |player, index| lobby.snapshot_previous[index] = stateFor(player);
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
