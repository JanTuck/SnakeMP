//! Isolated benchmark for expired-lobby removal.
//!
//! Compares the previous two-pass implementation (duplicate every expired key,
//! then ordered-remove it) with the current single-pass swap removal. Map setup
//! and teardown are deliberately outside each timed interval.
//!
//! Run: zig run -O ReleaseFast bench_lobby_reap.zig

const std = @import("std");
const linux = std.os.linux;

const Allocator = std.mem.Allocator;
const LobbyMap = std.StringArrayHashMapUnmanaged(usize);
const default_lobby_id = "default";
const sample_count = 7;

const Fixture = struct {
    map: LobbyMap = .empty,
    keys: std.ArrayListUnmanaged([]u8) = .empty,

    fn init(allocator: Allocator, temporary_count: usize) !Fixture {
        var fixture: Fixture = .{};
        errdefer fixture.deinit(allocator);

        try fixture.add(allocator, default_lobby_id, 0);
        for (0..temporary_count) |index| {
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "temporary-{d}", .{index});
            try fixture.add(allocator, key, index + 1);
        }
        return fixture;
    }

    fn add(fixture: *Fixture, allocator: Allocator, key_source: []const u8, value: usize) !void {
        const key = try allocator.dupe(u8, key_source);
        errdefer allocator.free(key);
        try fixture.keys.ensureUnusedCapacity(allocator, 1);
        try fixture.map.put(allocator, key, value);
        fixture.keys.appendAssumeCapacity(key);
    }

    fn validate(fixture: *const Fixture, expected_removed: usize, removed_sum: usize) !void {
        if (fixture.map.count() != 1) return error.InvalidSurvivorCount;
        if (fixture.map.get(default_lobby_id) != 0) return error.DefaultLobbyMissing;
        const expected_sum = expected_removed * (expected_removed + 1) / 2;
        if (removed_sum != expected_sum) return error.InvalidRemovedValues;
    }

    fn deinit(fixture: *Fixture, allocator: Allocator) void {
        fixture.map.deinit(allocator);
        for (fixture.keys.items) |key| allocator.free(key);
        fixture.keys.deinit(allocator);
        fixture.* = .{};
    }
};

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

fn previousReap(map: *LobbyMap, allocator: Allocator) !usize {
    var doomed: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (doomed.items) |key| allocator.free(key);
        doomed.deinit(allocator);
    }

    for (map.keys()) |key| {
        if (std.mem.eql(u8, key, default_lobby_id)) continue;
        const duplicate = try allocator.dupe(u8, key);
        errdefer allocator.free(duplicate);
        try doomed.append(allocator, duplicate);
    }

    var removed_sum: usize = 0;
    for (doomed.items) |key| {
        const removed = map.fetchOrderedRemove(key) orelse return error.MissingExpiredLobby;
        removed_sum +%= removed.value;
    }
    return removed_sum;
}

fn swapReap(map: *LobbyMap) !usize {
    var removed_sum: usize = 0;
    var index: usize = 0;
    while (index < map.count()) {
        if (std.mem.eql(u8, map.keys()[index], default_lobby_id)) {
            index += 1;
            continue;
        }
        removed_sum +%= map.values()[index];
        map.swapRemoveAt(index);
    }
    return removed_sum;
}

const Method = enum { previous, swap };

fn measure(allocator: Allocator, temporary_count: usize, repetitions: usize, method: Method) !u64 {
    var elapsed: u64 = 0;
    var sink: usize = 0;
    for (0..repetitions) |_| {
        var fixture = try Fixture.init(allocator, temporary_count);
        defer fixture.deinit(allocator);

        const started = nowNs();
        const removed_sum = switch (method) {
            .previous => try previousReap(&fixture.map, allocator),
            .swap => try swapReap(&fixture.map),
        };
        elapsed += nowNs() - started;
        try fixture.validate(temporary_count, removed_sum);
        sink +%= removed_sum;
    }
    std.mem.doNotOptimizeAway(sink);
    return elapsed / repetitions;
}

fn median(values: *[sample_count]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[sample_count / 2];
}

fn repetitionsFor(temporary_count: usize) usize {
    return switch (temporary_count) {
        64 => 128,
        1000 => 8,
        4095 => 1,
        else => unreachable,
    };
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const cases = [_]usize{ 64, 1000, 4095 };

    std.debug.print("expired-lobby reap (ReleaseFast, median of {d}; setup excluded)\n", .{sample_count});
    std.debug.print("temporary  previous us/reap  swap us/reap  speedup\n", .{});

    for (cases) |temporary_count| {
        const repetitions = repetitionsFor(temporary_count);
        var previous_samples: [sample_count]u64 = undefined;
        var swap_samples: [sample_count]u64 = undefined;
        for (0..sample_count) |sample| {
            // Alternate order to avoid consistently favoring the second method.
            if (sample % 2 == 0) {
                previous_samples[sample] = try measure(allocator, temporary_count, repetitions, .previous);
                swap_samples[sample] = try measure(allocator, temporary_count, repetitions, .swap);
            } else {
                swap_samples[sample] = try measure(allocator, temporary_count, repetitions, .swap);
                previous_samples[sample] = try measure(allocator, temporary_count, repetitions, .previous);
            }
        }

        const previous_ns = median(&previous_samples);
        const swap_ns = median(&swap_samples);
        const previous_us = @as(f64, @floatFromInt(previous_ns)) / 1000.0;
        const swap_us = @as(f64, @floatFromInt(swap_ns)) / 1000.0;
        const speedup = @as(f64, @floatFromInt(previous_ns)) / @as(f64, @floatFromInt(swap_ns));
        std.debug.print("{d:9}  {d:16.3}  {d:12.3}  {d:7.2}x\n", .{ temporary_count, previous_us, swap_us, speedup });
    }
}
