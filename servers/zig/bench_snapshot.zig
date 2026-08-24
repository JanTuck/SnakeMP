//! Production snapshot encoder microbenchmark.
//! Run: zig run -O ReleaseFast bench_snapshot.zig

const std = @import("std");
const model = @import("src/model.zig");
const snapshot = @import("src/snapshot.zig");

const player_count = 16;
const samples = 5;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

fn squareCell(player_index: usize, phase: usize) model.CellPos {
    const base_x: i32 = 20;
    const base_y: i32 = @intCast(2 + player_index * 3);
    return switch (phase & 3) {
        0 => .{ .x = base_x * model.CELL, .y = base_y * model.CELL },
        1 => .{ .x = (base_x + 1) * model.CELL, .y = base_y * model.CELL },
        2 => .{ .x = (base_x + 1) * model.CELL, .y = (base_y + 1) * model.CELL },
        else => .{ .x = base_x * model.CELL, .y = (base_y + 1) * model.CELL },
    };
}

fn resetBodies(players: []const *model.Player, length: usize) !void {
    for (players, 0..) |player, player_index| {
        player.snake.clearRetainingCapacity();
        try player.snake.ensureTotalCapacity(std.heap.page_allocator, length);
        for (0..length) |cell_index| {
            // Walking backward around the square produces a contiguous body
            // of any requested length while staying inside the board.
            const phase = (4 - (cell_index & 3)) & 3;
            player.snake.appendAssumeCapacity(squareCell(player_index, phase));
        }
    }
}

fn moveBodies(players: []const *model.Player, tick: usize) void {
    const phase = (tick + 1) & 3;
    for (players, 0..) |player, player_index| {
        std.mem.copyBackwards(model.CellPos, player.snake.items[1..], player.snake.items[0 .. player.snake.items.len - 1]);
        player.snake.items[0] = squareCell(player_index, phase);
    }
}

const Result = struct {
    elapsed_ns: u64,
    bytes: u64,
    keyframes: usize,
};

fn runKeyframes(lobby: *model.Lobby, buffer: *std.ArrayListUnmanaged(u8), iterations: usize) !Result {
    var bytes: u64 = 0;
    const started = nowNs();
    for (0..iterations) |_| {
        snapshot.invalidate(lobby);
        const result = try snapshot.buildInto(buffer, lobby, 0, std.heap.page_allocator);
        bytes += result.bytes.len;
    }
    return .{ .elapsed_ns = nowNs() - started, .bytes = bytes, .keyframes = iterations };
}

fn runStream(lobby: *model.Lobby, players: []const *model.Player, buffer: *std.ArrayListUnmanaged(u8), iterations: usize, moving: bool) !Result {
    snapshot.invalidate(lobby);
    var bytes: u64 = 0;
    var keyframes: usize = 0;
    const started = nowNs();
    for (0..iterations) |tick| {
        if (moving and tick != 0) moveBodies(players, tick - 1);
        const result = try snapshot.buildInto(buffer, lobby, 0, std.heap.page_allocator);
        bytes += result.bytes.len;
        keyframes += @intFromBool(result.kind == .keyframe);
    }
    return .{ .elapsed_ns = nowNs() - started, .bytes = bytes, .keyframes = keyframes };
}

fn lessThan(_: void, a: Result, b: Result) bool {
    return a.elapsed_ns < b.elapsed_ns;
}

fn report(label: []const u8, results: *[samples]Result, iterations: usize) void {
    std.mem.sort(Result, results, {}, lessThan);
    const result = results[samples / 2];
    std.debug.print("{s:<12} {d:>12} {d:>12.2} {d:>10}\n", .{
        label,
        result.elapsed_ns / iterations,
        @as(f64, @floatFromInt(result.bytes)) / @as(f64, @floatFromInt(iterations)),
        result.keyframes,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var connection: model.Conn = .{ .fd = -1 };
    var storage: [player_count]model.Player = undefined;
    var players: [player_count]*model.Player = undefined;
    var ids: [player_count][8]u8 = undefined;
    var lobby = model.Lobby{ .id = @constCast("benchmark"), .food = .{ .x = 0, .y = 0 } };
    defer lobby.players.deinit(allocator);
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(allocator);

    for (&storage, 0..) |*player, index| {
        const id = try std.fmt.bufPrint(&ids[index], "p-{d}", .{index});
        player.* = .{
            .id = id,
            .name = @constCast("benchmark"),
            .color_hex = @constCast("#123456"),
            .conn = &connection,
        };
        players[index] = player;
        try lobby.players.append(allocator, player);
    }
    defer for (&storage) |*player| player.snake.deinit(allocator);

    std.debug.print(
        "snapshot v{d}: {d} players, median of {d}\n" ++
            "cells mode          ns/frame  bytes/frame  keyframes\n",
        .{ snapshot.VERSION, player_count, samples },
    );
    for ([_]usize{ 1, 18, 256 }) |length| {
        try resetBodies(&players, length);
        const iterations: usize = if (length <= 18) 100_000 else 20_000;

        var keyframe_results: [samples]Result = undefined;
        var stationary_results: [samples]Result = undefined;
        var moving_results: [samples]Result = undefined;
        for (0..samples) |sample| {
            keyframe_results[sample] = try runKeyframes(&lobby, &wire, iterations);
            stationary_results[sample] = try runStream(&lobby, &players, &wire, iterations, false);
            try resetBodies(&players, length);
            moving_results[sample] = try runStream(&lobby, &players, &wire, iterations, true);
        }
        std.debug.print("{d:>5} ", .{length});
        report("keyframe", &keyframe_results, iterations);
        std.debug.print("{d:>5} ", .{length});
        report("stationary", &stationary_results, iterations);
        std.debug.print("{d:>5} ", .{length});
        report("moving", &moving_results, iterations);
    }
}
