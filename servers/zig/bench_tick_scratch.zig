//! Exact microbenchmark for tick scratch storage and worker timestamp sampling.
//! Run: zig run -O ReleaseFast bench_tick_scratch.zig

const std = @import("std");
const linux = std.os.linux;

const players_per_lobby = 16;
const lobbies_per_worker = 128;
const samples = 5;

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

fn oldScratch(iterations: usize) u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const source = [_]usize{1} ** players_per_lobby;
    var sink: usize = 0;
    const started = nowNs();
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        for (0..lobbies_per_worker) |_| {
            var snapshot: std.ArrayListUnmanaged(usize) = .empty;
            snapshot.appendSlice(arena.allocator(), &source) catch unreachable;
            var graveyard: std.ArrayListUnmanaged(usize) = .empty;
            graveyard.ensureTotalCapacity(arena.allocator(), snapshot.items.len) catch unreachable;
            for (snapshot.items) |value| graveyard.appendAssumeCapacity(value);
            sink +%= snapshot.items[0] + graveyard.items[graveyard.items.len - 1];
            snapshot.deinit(arena.allocator());
            graveyard.deinit(arena.allocator());
        }
    }
    std.mem.doNotOptimizeAway(sink);
    return nowNs() - started;
}

fn fixedScratch(iterations: usize) u64 {
    const source = [_]usize{1} ** players_per_lobby;
    var sink: usize = 0;
    const started = nowNs();
    for (0..iterations) |_| {
        for (0..lobbies_per_worker) |_| {
            var snapshot: [players_per_lobby]usize = undefined;
            @memcpy(&snapshot, &source);
            var graveyard: [players_per_lobby]usize = undefined;
            for (snapshot, 0..) |value, index| graveyard[index] = value;
            sink +%= snapshot[0] + graveyard[graveyard.len - 1];
            std.mem.doNotOptimizeAway(&snapshot);
            std.mem.doNotOptimizeAway(&graveyard);
        }
    }
    std.mem.doNotOptimizeAway(sink);
    return nowNs() - started;
}

fn repeatedClock(iterations: usize, batched: bool) u64 {
    var sink: i64 = 0;
    const started = nowNs();
    for (0..iterations) |_| {
        if (batched) {
            var ts: linux.timespec = undefined;
            _ = linux.clock_gettime(.REALTIME, &ts);
            sink +%= ts.nsec;
        } else {
            for (0..lobbies_per_worker) |_| {
                var ts: linux.timespec = undefined;
                _ = linux.clock_gettime(.REALTIME, &ts);
                sink +%= ts.nsec;
            }
        }
    }
    std.mem.doNotOptimizeAway(sink);
    return nowNs() - started;
}

fn median(values: *[samples]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[samples / 2];
}

pub fn main() void {
    const scratch_iterations = 20_000;
    const clock_iterations = 20_000;
    var old_results: [samples]u64 = undefined;
    var fixed_results: [samples]u64 = undefined;
    var repeated_clock_results: [samples]u64 = undefined;
    var batched_clock_results: [samples]u64 = undefined;
    for (0..samples) |sample| {
        old_results[sample] = oldScratch(scratch_iterations);
        fixed_results[sample] = fixedScratch(scratch_iterations);
        repeated_clock_results[sample] = repeatedClock(clock_iterations, false);
        batched_clock_results[sample] = repeatedClock(clock_iterations, true);
    }
    const lobby_ops: u64 = scratch_iterations * lobbies_per_worker;
    std.debug.print("tick scratch: {d} players, {d} lobbies/worker, median of {d}\n", .{ players_per_lobby, lobbies_per_worker, samples });
    std.debug.print("arena lists  {d:.2} ns/lobby\n", .{@as(f64, @floatFromInt(median(&old_results))) / @as(f64, @floatFromInt(lobby_ops))});
    std.debug.print("fixed arrays {d:.2} ns/lobby\n", .{@as(f64, @floatFromInt(median(&fixed_results))) / @as(f64, @floatFromInt(lobby_ops))});
    std.debug.print("clock x128   {d:.2} ns/worker tick\n", .{@as(f64, @floatFromInt(median(&repeated_clock_results))) / clock_iterations});
    std.debug.print("clock x1     {d:.2} ns/worker tick\n", .{@as(f64, @floatFromInt(median(&batched_clock_results))) / clock_iterations});
}
