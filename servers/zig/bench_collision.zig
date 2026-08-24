//! Focused worst-case collision benchmark:
//! 16 players, 256 non-overlapping cells each, all collision queries miss.
//! Run: zig run -O ReleaseFast bench_collision.zig

const std = @import("std");
const collision = @import("src/collision.zig");
const config = @import("src/config.zig");
const model = @import("src/model.zig");

const player_count = 16;
const max_snake_length = 256;
const iterations = 2_000;
const samples = 3;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

fn same(a: model.CellPos, b: model.CellPos) bool {
    return a.x == b.x and a.y == b.y;
}

fn legacyOther(players: []const *model.Player, player: *const model.Player) ?*model.Player {
    const head = player.snake.items[0];
    for (players) |other| {
        if (other == player) continue;
        for (other.snake.items) |segment| {
            if (same(segment, head)) return other;
        }
    }
    return null;
}

fn benchLegacy(players: []const *model.Player) u64 {
    const started = nowNs();
    var hits: usize = 0;
    for (0..iterations) |_| {
        for (players) |player| {
            hits += @intFromBool(collision.scanSelf(player));
            hits += @intFromBool(legacyOther(players, player) != null);
        }
    }
    std.mem.doNotOptimizeAway(hits);
    return nowNs() - started;
}

fn benchIndex(players: []const *model.Player) u64 {
    const started = nowNs();
    var hits: usize = 0;
    for (0..iterations) |_| {
        const index = collision.Index.buildForced(players);
        for (players, 0..) |player, slot| {
            hits += @intFromBool(index.selfHit(slot, player));
            hits += @intFromBool(index.otherAt(slot, player) != null);
        }
    }
    std.mem.doNotOptimizeAway(hits);
    return nowNs() - started;
}

fn lessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var conn: model.Conn = .{ .fd = -1 };
    var storage: [player_count]model.Player = undefined;
    var players: [player_count]*model.Player = undefined;

    for (&storage, 0..) |*player, player_index| {
        player.* = .{
            .id = @constCast("bench"),
            .name = @constCast("bench"),
            .color_hex = @constCast("#fff"),
            .conn = &conn,
        };
        players[player_index] = player;
        for (0..max_snake_length) |segment_index| {
            const cols: usize = @intCast(config.GRID_COLS);
            const local_row = segment_index / cols;
            const within_row = segment_index % cols;
            const x_cell = if ((local_row & 1) == 0) within_row else cols - 1 - within_row;
            try player.snake.append(allocator, .{
                .x = @intCast(x_cell * 16),
                .y = @intCast((player_index * 3 + local_row) * 16),
            });
        }
    }
    defer for (&storage) |*player| player.snake.deinit(allocator);

    std.debug.print(
        "collision benchmark: {d} players, {d} ticks/sample, median of {d}\n" ++
            "cells/player  legacy ns/tick  indexed ns/tick  speedup\n",
        .{ player_count, iterations, samples },
    );
    for ([_]usize{ 1, 4, 8, 16, 32, 64, 128, 256 }) |snake_length| {
        for (&storage) |*player| player.snake.items = player.snake.items.ptr[0..snake_length];

        // Prime code/data caches before collecting multiple samples.
        _ = benchLegacy(&players);
        _ = benchIndex(&players);

        var legacy_samples: [samples]u64 = undefined;
        var index_samples: [samples]u64 = undefined;
        for (0..samples) |sample| {
            legacy_samples[sample] = benchLegacy(&players);
            index_samples[sample] = benchIndex(&players);
        }
        std.mem.sort(u64, &legacy_samples, {}, lessThan);
        std.mem.sort(u64, &index_samples, {}, lessThan);
        const legacy_ns = legacy_samples[samples / 2] / iterations;
        const index_ns = index_samples[samples / 2] / iterations;
        const speedup = @as(f64, @floatFromInt(legacy_ns)) / @as(f64, @floatFromInt(index_ns));
        std.debug.print("{d:>12}  {d:>14}  {d:>15}  {d:>7.2}x\n", .{ snake_length, legacy_ns, index_ns, speedup });
    }
    std.debug.print("index stack bytes: {d}\n", .{@sizeOf(collision.Index)});
}
