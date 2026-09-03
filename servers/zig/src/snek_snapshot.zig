//! Full-state snapshots for the continuous Snek IO arena. This protocol is
//! deliberately separate from the compact 128x72 grid protocol: coordinates
//! are world-space u16 values and player bodies may contain 1,000 samples.

const std = @import("std");
const model = @import("model.zig");
const snek = @import("snek.zig");

pub const VERSION: u8 = 2;

pub const Result = struct {
    bytes: []const u8,
    sequence: u16,
};

fn appendInt(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try buffer.appendSlice(allocator, &bytes);
}

fn appendSnake(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, snake: *const snek.Snake, score: u32) !void {
    if (!snake.alive or snake.rb_len == 0) return error.InactivePlayer;
    try appendInt(buffer, allocator, u32, score);
    try appendInt(buffer, allocator, u16, snake.mass);
    try appendInt(buffer, allocator, u16, @intCast(snake.rb_len));
    const angle: u16 = @intFromFloat(@floor(snake.angle / (2.0 * std.math.pi) * 65535.0));
    try appendInt(buffer, allocator, u16, angle);
    var flags: u8 = 0;
    if (snake.turbo_ticks > 0 or (snake.boosting and snake.mass > snek.MIN_BOOST_MASS)) flags |= 1;
    if (snake.shield_ticks > 0) flags |= 2;
    try buffer.append(allocator, flags);
    for (0..snake.rb_len) |back| {
        const sample = snake.body[snek.ringIndex(snake.rb_head, back)];
        try appendInt(buffer, allocator, u16, snek.quantizeCoordinate(sample.x));
        try appendInt(buffer, allocator, u16, snek.quantizeCoordinate(sample.y));
    }
}

pub fn buildInto(buffer: *std.ArrayListUnmanaged(u8), lobby: *model.Lobby, allocator: std.mem.Allocator) !Result {
    const sim = lobby.snek orelse return error.MissingSimulation;
    const bot_count: usize = if (lobby.io_bots) |population| population.count else 0;
    const player_count = lobby.players.items.len + bot_count;
    if (player_count > snek.MAX_SNAKES) return error.TooManyPlayers;

    buffer.clearRetainingCapacity();
    const sequence = lobby.snapshot_sequence +% 1;
    try buffer.appendSlice(allocator, "SI");
    try buffer.append(allocator, VERSION);
    try appendInt(buffer, allocator, u16, sequence);
    try buffer.append(allocator, @intCast(player_count));
    try appendInt(buffer, allocator, u16, @intCast(sim.food.count));
    try appendInt(buffer, allocator, u32, sim.obstacle_alive_mask);

    for (lobby.players.items) |player| {
        const slot = player.io_slot orelse return error.MissingSlot;
        const snake = &sim.snakes[slot];
        try appendSnake(buffer, allocator, snake, @intCast(@max(player.score, 0)));
    }
    if (lobby.io_bots) |population| for (population.bots[0..population.count]) |bot| {
        const snake = &sim.snakes[bot.io_slot];
        try appendSnake(buffer, allocator, snake, snake.mass -| snek.INITIAL_MASS);
    };

    var emitted_food: usize = 0;
    for (0..snek.MAX_FOOD) |slot| {
        const mass = sim.food.mass[slot];
        if (mass == 0) continue;
        try appendInt(buffer, allocator, u16, @intCast(slot));
        try appendInt(buffer, allocator, u16, sim.food.x[slot]);
        try appendInt(buffer, allocator, u16, sim.food.y[slot]);
        try buffer.append(allocator, mass);
        emitted_food += 1;
    }
    if (emitted_food != sim.food.count) return error.FoodInvariant;
    lobby.snapshot_sequence = sequence;
    return .{ .bytes = buffer.items, .sequence = sequence };
}

test "continuous snapshot carries world coordinates bodies and food" {
    var prng = std.Random.DefaultPrng.init(3);
    var rng = prng.random();
    const sim = try snek.Snek.init(std.testing.allocator, 3, 8, &rng);
    defer sim.deinit(std.testing.allocator);
    _ = sim.spawnSnake(0, &rng);
    var conn: model.Conn = .{ .fd = -1 };
    var player: model.Player = .{
        .id = "id",
        .name = @constCast("name"),
        .color_hex = @constCast("#fff"),
        .conn = &conn,
        .io_slot = 0,
    };
    var lobby: model.Lobby = .{
        .id = @constCast("io"),
        .mode = .snek_io,
        .snek = sim,
        .food = .{ .x = 0, .y = 0 },
    };
    defer lobby.players.deinit(std.testing.allocator);
    try lobby.players.append(std.testing.allocator, &player);
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    const result = try buildInto(&wire, &lobby, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "SI\x02", result.bytes[0..3]);
    try std.testing.expectEqual(@as(u8, 1), result.bytes[5]);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, result.bytes[6..8], .little));
    try std.testing.expectEqual(sim.obstacle_alive_mask, std.mem.readInt(u32, result.bytes[8..12], .little));
}

test "continuous snapshot keeps human then native bot roster capacity aligned" {
    var prng = std.Random.DefaultPrng.init(17);
    var rng = prng.random();
    const sim = try snek.Snek.init(std.testing.allocator, 1, 8, &rng);
    defer sim.deinit(std.testing.allocator);
    _ = sim.spawnSnake(0, &rng);
    _ = sim.spawnSnake(98, &rng);
    _ = sim.spawnSnake(99, &rng);
    var conn: model.Conn = .{ .fd = -1 };
    var player: model.Player = .{
        .id = "human",
        .name = @constCast("Human"),
        .color_hex = @constCast("#fff"),
        .conn = &conn,
        .score = 99,
        .io_slot = 0,
    };
    var population: model.IoBotPopulation = .{ .count = 2, .target = 2 };
    population.bots[0].io_slot = 98;
    population.bots[1].io_slot = 99;
    var lobby: model.Lobby = .{
        .id = @constCast("io"),
        .mode = .snek_io,
        .snek = sim,
        .io_bots = &population,
        .food = .{ .x = 0, .y = 0 },
    };
    defer lobby.players.deinit(std.testing.allocator);
    try lobby.players.append(std.testing.allocator, &player);
    var wire: std.ArrayListUnmanaged(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    const result = try buildInto(&wire, &lobby, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 3), result.bytes[5]);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, result.bytes[12..16], .little));

    // Population changes publish a new full frame with the exact current row
    // count. Human rows remain first; tail-removing a bot cannot leave a stale
    // count or an inactive row behind for clients that dropped older frames.
    population.count = 1;
    sim.despawnSnake(99);
    const after_bot_leave = try buildInto(&wire, &lobby, std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 2), after_bot_leave.sequence);
    try std.testing.expectEqual(@as(u8, 2), after_bot_leave.bytes[5]);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, after_bot_leave.bytes[12..16], .little));

    _ = lobby.players.orderedRemove(0);
    const bot_only = try buildInto(&wire, &lobby, std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 3), bot_only.sequence);
    try std.testing.expectEqual(@as(u8, 1), bot_only.bytes[5]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bot_only.bytes[12..16], .little));
}
