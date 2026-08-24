//! Isolated benchmark for a lobby's bounded player container.
//!
//! Compares the former id-keyed StringArrayHashMap with the current ordered
//! pointer ArrayList at the production maximum of exactly 16 players. Join
//! measurements include container growth; remove/refill measurements retain
//! capacity and remove a known player while preserving the other players'
//! order.
//!
//! Run: zig run -O ReleaseFast bench_player_container.zig

const std = @import("std");
const linux = std.os.linux;

const Allocator = std.mem.Allocator;
const player_count = 16;
const sample_count = 9;
const join_repetitions = 50_000;
const cycle_repetitions = 2_000_000;

const Player = struct {
    id: [4]u8,
    ordinal: usize,
};

const PlayerMap = std.StringArrayHashMapUnmanaged(*Player);
const PlayerList = std.ArrayListUnmanaged(*Player);

const CountingAllocator = struct {
    child: Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    allocation_count: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn recordGrowth(self: *CountingAllocator, bytes: usize) void {
        self.live_bytes += bytes;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.recordGrowth(len);
        self.allocation_count += 1;
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len >= memory.len) {
            self.recordGrowth(new_len - memory.len);
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        if (new_len >= memory.len) {
            self.recordGrowth(new_len - memory.len);
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, return_address);
        self.live_bytes -= memory.len;
    }
};

fn initPlayers(players: *[player_count]Player) void {
    for (players, 0..) |*player, index| {
        player.* = .{
            .id = .{
                'p',
                '0' + @as(u8, @intCast(index / 100)),
                '0' + @as(u8, @intCast((index / 10) % 10)),
                '0' + @as(u8, @intCast(index % 10)),
            },
            .ordinal = index,
        };
    }
}

fn nowNs() u64 {
    var timestamp: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &timestamp);
    return @intCast(timestamp.sec * std.time.ns_per_s + timestamp.nsec);
}

fn median(values: *[sample_count]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[sample_count / 2];
}

fn fillMap(map: *PlayerMap, allocator: Allocator, players: *[player_count]Player) !void {
    for (players) |*player| try map.put(allocator, &player.id, player);
}

fn fillList(list: *PlayerList, allocator: Allocator, players: *[player_count]Player) !void {
    for (players) |*player| try list.append(allocator, player);
}

fn removeListKnown(list: *PlayerList, target: *Player) !void {
    const index = for (list.items, 0..) |candidate, at| {
        if (candidate == target) break at;
    } else return error.KnownPlayerMissing;
    _ = list.orderedRemove(index);
}

fn expectSameOrder(map: *const PlayerMap, list: *const PlayerList) !void {
    if (map.count() != player_count or list.items.len != player_count) return error.InvalidPlayerCount;
    for (map.values(), list.items) |map_player, list_player| {
        if (map_player != list_player) return error.OrderMismatch;
    }
}

fn validateSemantics(allocator: Allocator, players: *[player_count]Player) !void {
    var map: PlayerMap = .empty;
    defer map.deinit(allocator);
    var list: PlayerList = .empty;
    defer list.deinit(allocator);
    try fillMap(&map, allocator, players);
    try fillList(&list, allocator, players);
    try expectSameOrder(&map, &list);

    for (0..257) |cycle| {
        const target = &players[(cycle * 7 + 3) % player_count];
        const removed = map.fetchOrderedRemove(&target.id) orelse return error.KnownPlayerMissing;
        if (removed.value != target) return error.WrongPlayerRemoved;
        try removeListKnown(&list, target);
        try map.put(allocator, &target.id, target);
        try list.append(allocator, target);
        try expectSameOrder(&map, &list);
    }
}

const Capacity = struct {
    requested_bytes: usize,
    peak_requested_bytes: usize,
    allocations: usize,
    slots: usize,
};

fn mapCapacity(players: *[player_count]Player) !Capacity {
    var counter: CountingAllocator = .{ .child = std.heap.smp_allocator };
    const allocator = counter.allocator();
    var map: PlayerMap = .empty;
    try fillMap(&map, allocator, players);
    const result: Capacity = .{
        .requested_bytes = counter.live_bytes,
        .peak_requested_bytes = counter.peak_bytes,
        .allocations = counter.allocation_count,
        .slots = map.capacity(),
    };
    map.deinit(allocator);
    if (counter.live_bytes != 0) return error.ContainerAllocationLeak;
    return result;
}

fn listCapacity(players: *[player_count]Player) !Capacity {
    var counter: CountingAllocator = .{ .child = std.heap.smp_allocator };
    const allocator = counter.allocator();
    var list: PlayerList = .empty;
    try fillList(&list, allocator, players);
    const result: Capacity = .{
        .requested_bytes = counter.live_bytes,
        .peak_requested_bytes = counter.peak_bytes,
        .allocations = counter.allocation_count,
        .slots = list.capacity,
    };
    list.deinit(allocator);
    if (counter.live_bytes != 0) return error.ContainerAllocationLeak;
    return result;
}

fn measureMapJoin(allocator: Allocator, players: *[player_count]Player) !u64 {
    var sink: usize = 0;
    const started = nowNs();
    for (0..join_repetitions) |_| {
        var map: PlayerMap = .empty;
        try fillMap(&map, allocator, players);
        sink +%= map.values()[0].ordinal + map.values()[player_count - 1].ordinal + map.capacity();
        map.deinit(allocator);
    }
    const elapsed = nowNs() - started;
    std.mem.doNotOptimizeAway(sink);
    return elapsed / join_repetitions;
}

fn measureListJoin(allocator: Allocator, players: *[player_count]Player) !u64 {
    var sink: usize = 0;
    const started = nowNs();
    for (0..join_repetitions) |_| {
        var list: PlayerList = .empty;
        try fillList(&list, allocator, players);
        sink +%= list.items[0].ordinal + list.items[player_count - 1].ordinal + list.capacity;
        list.deinit(allocator);
    }
    const elapsed = nowNs() - started;
    std.mem.doNotOptimizeAway(sink);
    return elapsed / join_repetitions;
}

fn measureMapCycles(allocator: Allocator, players: *[player_count]Player) !u64 {
    var map: PlayerMap = .empty;
    defer map.deinit(allocator);
    try fillMap(&map, allocator, players);

    var sink: usize = 0;
    const started = nowNs();
    for (0..cycle_repetitions) |cycle| {
        const target = &players[(cycle * 7 + 3) % player_count];
        const removed = map.fetchOrderedRemove(&target.id) orelse return error.KnownPlayerMissing;
        try map.put(allocator, &target.id, target);
        sink +%= removed.value.ordinal + map.values()[0].ordinal;
    }
    const elapsed = nowNs() - started;
    std.mem.doNotOptimizeAway(sink);
    std.mem.doNotOptimizeAway(&map);
    return elapsed / cycle_repetitions;
}

fn measureListCycles(allocator: Allocator, players: *[player_count]Player) !u64 {
    var list: PlayerList = .empty;
    defer list.deinit(allocator);
    try fillList(&list, allocator, players);

    var sink: usize = 0;
    const started = nowNs();
    for (0..cycle_repetitions) |cycle| {
        const target = &players[(cycle * 7 + 3) % player_count];
        try removeListKnown(&list, target);
        try list.append(allocator, target);
        sink +%= target.ordinal + list.items[0].ordinal;
    }
    const elapsed = nowNs() - started;
    std.mem.doNotOptimizeAway(sink);
    std.mem.doNotOptimizeAway(&list);
    return elapsed / cycle_repetitions;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var players: [player_count]Player = undefined;
    initPlayers(&players);
    try validateSemantics(allocator, &players);

    const map_capacity = try mapCapacity(&players);
    const list_capacity = try listCapacity(&players);

    var map_join_samples: [sample_count]u64 = undefined;
    var list_join_samples: [sample_count]u64 = undefined;
    var map_cycle_samples: [sample_count]u64 = undefined;
    var list_cycle_samples: [sample_count]u64 = undefined;
    for (0..sample_count) |sample| {
        if (sample % 2 == 0) {
            map_join_samples[sample] = try measureMapJoin(allocator, &players);
            list_join_samples[sample] = try measureListJoin(allocator, &players);
            map_cycle_samples[sample] = try measureMapCycles(allocator, &players);
            list_cycle_samples[sample] = try measureListCycles(allocator, &players);
        } else {
            list_join_samples[sample] = try measureListJoin(allocator, &players);
            map_join_samples[sample] = try measureMapJoin(allocator, &players);
            list_cycle_samples[sample] = try measureListCycles(allocator, &players);
            map_cycle_samples[sample] = try measureMapCycles(allocator, &players);
        }
    }

    const map_join_ns = median(&map_join_samples);
    const list_join_ns = median(&list_join_samples);
    const map_cycle_ns = median(&map_cycle_samples);
    const list_cycle_ns = median(&list_cycle_samples);

    std.debug.print("player container: exactly {d} entries (ReleaseFast, median of {d})\n", .{ player_count, sample_count });
    std.debug.print("semantics: identical insertion order and ordered known-pointer removal/refill validated\n", .{});
    std.debug.print("container       slots  live requested B  peak requested B  allocations\n", .{});
    std.debug.print("StringArrayMap  {d:5}  {d:16}  {d:16}  {d:11}\n", .{ map_capacity.slots, map_capacity.requested_bytes, map_capacity.peak_requested_bytes, map_capacity.allocations });
    std.debug.print("ArrayList       {d:5}  {d:16}  {d:16}  {d:11}\n", .{ list_capacity.slots, list_capacity.requested_bytes, list_capacity.peak_requested_bytes, list_capacity.allocations });
    std.debug.print("\noperation                    StringArrayMap  ArrayList  list speedup\n", .{});
    std.debug.print("join/fill 16 (ns/fill)       {d:14}  {d:9}  {d:10.2}x\n", .{ map_join_ns, list_join_ns, @as(f64, @floatFromInt(map_join_ns)) / @as(f64, @floatFromInt(list_join_ns)) });
    std.debug.print("remove/refill (ns/cycle)     {d:14}  {d:9}  {d:10.2}x\n", .{ map_cycle_ns, list_cycle_ns, @as(f64, @floatFromInt(map_cycle_ns)) / @as(f64, @floatFromInt(list_cycle_ns)) });
}
