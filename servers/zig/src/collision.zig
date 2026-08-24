//! Allocation-free collision index for the canonical <=16-player lobby.
//!
//! Each board cell stores a bit per player. Bits are assigned in the lobby's
//! stable insertion order, so `otherAt` preserves the old scan's first-match
//! semantics even when multiple snakes occupy a cell. The index is rebuilt on
//! the game-worker stack once per tick and updated after each ordered move.

const std = @import("std");
const config = @import("config.zig");
const model = @import("model.zig");

pub const max_indexed_players: usize = 16;
const cols: usize = @intCast(config.GRID_COLS);
const rows: usize = @intCast(config.GRID_ROWS);
const cell_count = config.MAX_CELLS;
const Mask = u16;
// Below this estimated scan work, the tiny direct loops beat clearing 9,216
// grid cells. This keeps one-cell/short-snake mass workloads on the lean path.
const min_estimated_comparisons: usize = 16_384;

pub const Hit = struct {
    player: *model.Player,
    slot: usize,
};

pub const BeforeMove = struct {
    head: model.CellPos,
    tail: model.CellPos,
    len: usize,

    pub fn capture(player: *const model.Player) BeforeMove {
        std.debug.assert(player.snake.items.len != 0);
        return .{
            .head = player.snake.items[0],
            .tail = player.snake.items[player.snake.items.len - 1],
            .len = player.snake.items.len,
        };
    }
};

pub const Index = struct {
    cells: [cell_count]Mask = undefined,
    players: [max_indexed_players]?*model.Player = undefined,
    self_hits: Mask = 0,
    active: Mask = 0,
    count: usize = 0,
    tracked: bool = false,
    enabled: bool = false,

    /// Build the current-tick view. Above 16 players, methods transparently
    /// use the exact scan fallback. Short-snake lobbies also keep the direct
    /// scan, which is faster than clearing the board-sized index.
    pub fn build(players: []const *model.Player) Index {
        return buildInternal(players, false);
    }

    pub fn buildForced(players: []const *model.Player) Index {
        return buildInternal(players, true);
    }

    fn buildInternal(players: []const *model.Player, force: bool) Index {
        var index: Index = .{};
        if (players.len > max_indexed_players) return index;
        index.count = players.len;
        index.tracked = true;
        @memset(&index.players, null);
        for (players, 0..) |player, slot| {
            index.players[slot] = player;
            index.active |= bit(slot);
        }
        var segments: usize = 0;
        for (players) |player| segments +|= player.snake.items.len;
        if (!force and players.len *| segments < min_estimated_comparisons) return index;

        @memset(&index.cells, 0);
        index.enabled = true;
        for (players, 0..) |player, slot| {
            if (scanSelf(player)) index.self_hits |= bit(slot);
            for (player.snake.items) |position| {
                if (cellIndexAligned(position)) |cell| index.cells[cell] |= bit(slot);
            }
        }
        return index;
    }

    pub inline fn selfHit(index: *const Index, slot: usize, player: *const model.Player) bool {
        if (!index.enabled) return scanSelf(player);
        return (index.self_hits & bit(slot)) != 0;
    }

    pub inline fn tracksPlayers(index: *const Index) bool {
        return index.tracked;
    }

    pub inline fn isActive(index: *const Index, slot: usize) bool {
        std.debug.assert(index.tracked);
        return (index.active & bit(slot)) != 0;
    }

    /// Return the first other player in stable lobby insertion order.
    pub fn otherAt(index: *const Index, slot: usize, player: *const model.Player) ?Hit {
        std.debug.assert(index.tracked);
        if (!index.enabled) return scanOther(index.players[0..index.count], index.active, player);
        const cell = cellIndexAligned(player.snake.items[0]) orelse return null;
        const candidates = index.cells[cell] & ~bit(slot);
        if (candidates == 0) return null;
        const other_slot: usize = @intCast(@ctz(candidates));
        return .{ .player = index.players[other_slot].?, .slot = other_slot };
    }

    /// Remove every occupied cell for a player killed during this ordered tick.
    pub fn remove(index: *Index, slot: usize, player: *const model.Player) void {
        if (!index.tracked) return;
        index.active &= ~bit(slot);
        if (!index.enabled) return;
        const keep = ~bit(slot);
        for (player.snake.items) |position| {
            if (cellIndexAligned(position)) |cell| index.cells[cell] &= keep;
        }
        index.self_hits &= keep;
    }

    /// Update only the changed ends after `Player.applyMove`: O(1) for the
    /// normal move and growth paths, versus rebuilding/scanning the snake.
    pub fn afterMove(index: *Index, slot: usize, player: *const model.Player, before: BeforeMove) void {
        if (!index.enabled or player.snake.items.len == 0) return;
        const new_head = player.snake.items[0];
        if (player.snake.items.len == before.len and same(new_head, before.head)) return;

        const player_bit = bit(slot);
        // A non-growth move drops the old tail before inserting the new head.
        // This intentionally permits moving into the cell just vacated by it.
        if (player.snake.items.len == before.len) {
            if (cellIndexAligned(before.tail)) |tail_cell| index.cells[tail_cell] &= ~player_bit;
        }

        index.self_hits &= ~player_bit;
        if (cellIndexAligned(new_head)) |head_cell| {
            if ((index.cells[head_cell] & player_bit) != 0) index.self_hits |= player_bit;
            index.cells[head_cell] |= player_bit;
        }
    }

    pub fn maskAt(index: *const Index, position: model.CellPos) Mask {
        if (!index.enabled) return 0;
        const cell = cellIndex(position) orelse return 0;
        return index.cells[cell];
    }
};

pub fn scanSelf(player: *const model.Player) bool {
    if (player.snake.items.len < 2) return false;
    const head = player.snake.items[0];
    for (player.snake.items[1..]) |segment| {
        if (same(segment, head)) return true;
    }
    return false;
}

fn scanOther(players: []const ?*model.Player, active: Mask, player: *const model.Player) ?Hit {
    const head = player.snake.items[0];
    for (players, 0..) |maybe_other, slot| {
        if ((active & bit(slot)) == 0) continue;
        const other = maybe_other.?;
        if (other == player) continue;
        for (other.snake.items) |segment| {
            if (same(segment, head)) return .{ .player = other, .slot = slot };
        }
    }
    return null;
}

inline fn bit(slot: usize) Mask {
    std.debug.assert(slot < max_indexed_players);
    return @as(Mask, 1) << @intCast(slot);
}

inline fn same(a: model.CellPos, b: model.CellPos) bool {
    return a.x == b.x and a.y == b.y;
}

inline fn cellIndex(position: model.CellPos) ?usize {
    if (@mod(position.x, model.CELL) != 0 or @mod(position.y, model.CELL) != 0) return null;
    return cellIndexAligned(position);
}

/// Authoritative snake coordinates originate on the cell grid and move by one
/// full cell. Keep the assertion in safety builds without rechecking the same
/// invariant for every segment in optimized production builds.
inline fn cellIndexAligned(position: model.CellPos) ?usize {
    std.debug.assert(@mod(position.x, model.CELL) == 0 and @mod(position.y, model.CELL) == 0);
    if (position.x < 0 or position.y < 0 or position.x >= config.GRID_W or position.y >= config.GRID_H) return null;
    const x: usize = @intCast(@divExact(position.x, model.CELL));
    const y: usize = @intCast(@divExact(position.y, model.CELL));
    return y * cols + x;
}

fn testPlayer(conn: *model.Conn, cells: []model.CellPos) model.Player {
    return .{
        .id = @constCast("id"),
        .name = @constCast("name"),
        .color_hex = @constCast("#fff"),
        .snake = .{ .items = cells, .capacity = cells.len },
        .conn = conn,
    };
}

test "index preserves overlapping players and insertion order" {
    var conn: model.Conn = .{ .fd = -1 };
    var a_cells = [_]model.CellPos{.{ .x = 16, .y = 16 }};
    var b_cells = [_]model.CellPos{.{ .x = 16, .y = 16 }};
    var c_cells = [_]model.CellPos{.{ .x = 16, .y = 16 }};
    var a = testPlayer(&conn, &a_cells);
    var b = testPlayer(&conn, &b_cells);
    var c = testPlayer(&conn, &c_cells);
    const players = [_]*model.Player{ &a, &b, &c };
    var index = Index.buildForced(&players);

    const first = index.otherAt(2, &c).?;
    try std.testing.expectEqual(@as(usize, 0), first.slot);
    try std.testing.expect(first.player == &a);

    index.remove(0, &a);
    try std.testing.expect(!index.isActive(0));
    try std.testing.expect(index.isActive(1));
    try std.testing.expectEqual(@as(Mask, 0b110), index.maskAt(.{ .x = 16, .y = 16 }));
    const second = index.otherAt(2, &c).?;
    try std.testing.expectEqual(@as(usize, 1), second.slot);
    try std.testing.expect(second.player == &b);
}

test "tail removal and head insertion update only changed cells" {
    var conn: model.Conn = .{ .fd = -1 };
    var cells = [_]model.CellPos{
        .{ .x = 32, .y = 0 },
        .{ .x = 16, .y = 0 },
        .{ .x = 0, .y = 0 },
    };
    var player = testPlayer(&conn, &cells);
    const players = [_]*model.Player{&player};
    var index = Index.buildForced(&players);
    const before = BeforeMove.capture(&player);
    cells = .{
        .{ .x = 48, .y = 0 },
        .{ .x = 32, .y = 0 },
        .{ .x = 16, .y = 0 },
    };
    index.afterMove(0, &player, before);

    try std.testing.expectEqual(@as(Mask, 0), index.maskAt(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(Mask, 1), index.maskAt(.{ .x = 48, .y = 0 }));
    try std.testing.expect(!index.selfHit(0, &player));
}

test "self collision is reported before movement" {
    var conn: model.Conn = .{ .fd = -1 };
    var cells = [_]model.CellPos{
        .{ .x = 16, .y = 16 },
        .{ .x = 32, .y = 16 },
        .{ .x = 16, .y = 16 },
    };
    var player = testPlayer(&conn, &cells);
    const players = [_]*model.Player{&player};
    const index = Index.buildForced(&players);
    try std.testing.expect(index.selfHit(0, &player));
}

test "short lobbies retain the exact lower-cost scan path" {
    var conn: model.Conn = .{ .fd = -1 };
    var a_cells = [_]model.CellPos{.{ .x = 0, .y = 0 }};
    var b_cells = [_]model.CellPos{.{ .x = 0, .y = 0 }};
    var a = testPlayer(&conn, &a_cells);
    var b = testPlayer(&conn, &b_cells);
    const players = [_]*model.Player{ &a, &b };
    const index = Index.build(&players);
    try std.testing.expect(!index.enabled);
    try std.testing.expectEqual(@as(Mask, 0), index.maskAt(.{ .x = 0, .y = 0 }));
    const hit = index.otherAt(0, &a).?;
    try std.testing.expectEqual(@as(usize, 1), hit.slot);
    try std.testing.expect(hit.player == &b);
    var mutable = index;
    mutable.remove(1, &b);
    try std.testing.expect(mutable.otherAt(0, &a) == null);
}

test "index stays comfortably within the 128 KiB worker stack" {
    try std.testing.expect(@sizeOf(Index) <= config.GAME_WORKER_STACK / 4);
}

test "index covers the full 128 by 72 canonical board" {
    try std.testing.expectEqual(@as(usize, 128), cols);
    try std.testing.expectEqual(@as(usize, 72), rows);
    try std.testing.expectEqual(@as(usize, 9_216), cell_count);

    var conn: model.Conn = .{ .fd = -1 };
    var cells = [_]model.CellPos{.{
        .x = config.GRID_W - model.CELL,
        .y = config.GRID_H - model.CELL,
    }};
    var player = testPlayer(&conn, &cells);
    const players = [_]*model.Player{&player};
    const index = Index.buildForced(&players);
    try std.testing.expectEqual(@as(Mask, 1), index.maskAt(cells[0]));
    try std.testing.expectEqual(@as(Mask, 0), index.maskAt(.{ .x = config.GRID_W, .y = cells[0].y }));
    try std.testing.expectEqual(@as(Mask, 0), index.maskAt(.{ .x = cells[0].x, .y = config.GRID_H }));
}

test "checked lookup rejects positions between authoritative cells" {
    var conn: model.Conn = .{ .fd = -1 };
    var cells = [_]model.CellPos{.{ .x = 16, .y = 16 }};
    var player = testPlayer(&conn, &cells);
    const players = [_]*model.Player{&player};
    const index = Index.buildForced(&players);
    try std.testing.expectEqual(@as(Mask, 0), index.maskAt(.{ .x = 17, .y = 16 }));
}
