//! Snek IO simulation state (design §2.1). main.zig allocates one Snek per
//! snek_io lobby behind Lobby.snek; classical/arcade lobbies keep it null and
//! pay zero cost for this module. Positions are f32 world units in [0, ARENA);
//! quantized u16 copies are made only inside the SI snapshot serializer (later
//! slice), never stored. All arrays are fixed-size and preallocated exactly
//! once at lobby creation — there is no growth path and no steady-state
//! allocation during ticks.
//!
//! Protocol notes for later slices (authoritative, from the slice-B contract):
//! - SI snapshot food deltas address pellets by their FOOD ARRAY SLOT INDEX
//!   (0..MAX_FOOD-1) as the stable pellet id. The Food struct intentionally
//!   carries no explicit id field; slot identity is the array position.
//! - SI player_count is the number of ALIVE snakes. Keyframe rows carry every
//!   roster slot; dead-but-retained spectators stay in the roster (chat /
//!   standings) but contribute no rows and no player_count.
//! - Kills are detected post-movement against the fully rebuilt spatial hash
//!   BEFORE any death is applied; no resolution mutates the hash or a body
//!   mid-pass, so slot order cannot bias who dies or who gets credit.
//!
//! Tick pipeline (design §2.1, later slice): apply steer -> move/sample/growth
//! /boost burn -> one @memset hash clear + full rebuild -> resolve kills ->
//! death bursts to food -> food pickups -> SI snapshot broadcast. Nothing here
//! implements that pipeline yet; this file ships the exact structs, the
//! fixed-size initialization, and the pure spawn/kill/turn-rate helpers.

const std = @import("std");

// §2.1 constants (exact).
pub const ARENA: f32 = 8192.0;
pub const SPACING: f32 = 8.0; // sample spacing px
pub const HIT_R: f32 = 13.0; // HIT_DISTANCE
pub const NECK_SKIP: usize = 6;
pub const MAX_MASS: u16 = 1000; // segments == length
pub const MAX_SNAKES: usize = 100; // roster slots 0..99
pub const MAX_FOOD: usize = 8192;
pub const FOOD_TARGET: usize = 5000;
pub const HASH_CELL: f32 = 32.0;
pub const HASH_BUCKETS: usize = 65_536; // (8192/32)^2

// §1.1 gameplay constants consumed by this slice's helpers.
pub const INITIAL_MASS: u16 = 30; // respawn length 240 px
pub const SPAWN_CLEAR_RADIUS: f32 = 300.0; // no body center inside
pub const SPAWN_ATTEMPTS: usize = 32; // then accept the last candidate
pub const FOOD_MASS_AMBIENT: u8 = 2;
pub const DEATH_DROP_STRIDE: usize = 2; // pellets dropped 16 px apart
pub const DEATH_DROP_CAP: usize = 150; // per death
pub const TURN_RATE_BASE: f32 = 4.5; // rad/s at length <= 30
pub const TURN_RATE_MIN: f32 = 1.2; // rad/s at length >= ~340
// The remaining §1.1 constants (BASE_SPEED, BOOST_MULT, MIN_BOOST_MASS,
// BOOST_BURN, GROWTH_RATE, FOOD_MASS_DROPPED) arrive with the tick slice.

pub const Sample = struct { x: f32, y: f32 }; // 8 bytes

pub const Snake = struct {
    slot: u16 = 0, // roster slot (palette color source)
    alive: bool = false,
    head_x: f32 = 0,
    head_y: f32 = 0,
    angle: f32 = 0, // facing, radians
    target_angle: f32 = 0, // from steer packet 6
    mass: u16 = INITIAL_MASS, // segments; length == mass
    mass_frac: u16 = 0, // boost-burn accumulator in /1024
    growth_pending: u16 = 0,
    boosting: bool = false,
    rb_head: usize = 0, // ring: newest sample index
    rb_len: usize = 0, // valid samples == mass (invariant)
    body: [MAX_MASS]Sample = undefined, // fixed ring buffer, preallocated
    // ~8_050 B/snake (metadata + 8 KB ring)
};

pub const Food = struct { // SoA, fixed capacity, freelist
    x: [MAX_FOOD]u16 = undefined, // 0..8191 quantum
    y: [MAX_FOOD]u16 = undefined,
    mass: [MAX_FOOD]u8 = undefined, // 1 | 2
    free: [MAX_FOOD]u16 = undefined, // freelist stack of dead slot indices
    count: usize = 0, // live pellets (target 5000)
};

pub const HASH_NODES: usize = 100_000; // 100 snakes x 1000 max segments

pub const NodePool = struct { // u32 id + u32 next = 8 B/node
    ids: [HASH_NODES]u32 = undefined, // node.id = slot << 14 | sample_index
    next: [HASH_NODES]u32 = undefined,
};

pub const Hash = struct { // spatial hash, deterministic, allocation-free
    heads: [HASH_BUCKETS]u32 = undefined, // cleared by one @memset per tick
    nodes: NodePool = .{},
    node_top: usize = 0,
};

/// The complete fixed-size simulation state for one snek_io lobby
/// (≈1.9 MB, all in this one allocation — design §2.1).
pub const Snek = struct {
    /// Roster slots 0..MAX_SNAKES-1; only alive snakes simulate. Default is
    /// zeroed so linear scans (e.g. the spawn-clear check) are safe at init.
    snakes: [MAX_SNAKES]Snake = [_]Snake{.{}} ** MAX_SNAKES,
    food: Food = .{},
    hash: Hash = .{},
    /// Ambient pellet population target and hard cap from the env knobs
    /// (defaults FOOD_TARGET / MAX_FOOD). Clamped at init so the fixed
    /// arrays can never overflow.
    food_target: usize = FOOD_TARGET,
    max_food: usize = MAX_FOOD,

    /// Allocate the sim and place `food_target` ambient pellets (mass 2) at
    /// deterministic RNG positions (design §1.2). Everything is preallocated
    /// here, exactly once; there is no growth path. The caller passes the
    /// lobby's seeded rng so ambient placement is reproducible per lobby seed.
    pub fn init(allocator: std.mem.Allocator, food_target: usize, max_food: usize, rng: *std.Random) !*Snek {
        const s = try allocator.create(Snek);
        errdefer allocator.destroy(s);
        s.* = .{};
        // Clamp ascending so every bound stays within the fixed arrays:
        // 1 <= max_food <= MAX_FOOD, then 1 <= food_target <= max_food.
        s.max_food = std.math.clamp(max_food, 1, MAX_FOOD);
        s.food_target = std.math.clamp(food_target, 1, s.max_food);
        s.spawnAmbientFood(rng);
        return s;
    }

    pub fn deinit(s: *Snek, allocator: std.mem.Allocator) void {
        allocator.destroy(s);
    }

    /// Fixed-size guarantee: every array is preallocated at init, so this is
    /// only an invariant check that a requested roster/food size fits before
    /// it is used. No growth happens anywhere in the module.
    pub fn ensureCapacity(s: *const Snek, players: usize, food: usize) !void {
        if (players > MAX_SNAKES or food > s.max_food) return error.CapacityExceeded;
    }

    /// Spawn or respawn the snake in `slot` (design §1.7). Up to SPAWN_ATTEMPTS
    /// random candidates keep every existing body sample outside
    /// SPAWN_CLEAR_RADIUS; the last candidate is accepted unconditionally.
    /// The body ring is seeded with INITIAL_MASS samples trailing behind the
    /// head opposite to the facing angle (sample k is k*SPACING behind).
    /// Deterministic for a given rng; allocation-free.
    pub fn spawnSnake(s: *Snek, slot: usize, rng: *std.Random) *Snake {
        std.debug.assert(slot < MAX_SNAKES);
        var head_x: f32 = 0;
        var head_y: f32 = 0;
        var attempt: usize = 0;
        while (attempt < SPAWN_ATTEMPTS) : (attempt += 1) {
            head_x = rng.float(f32) * ARENA;
            head_y = rng.float(f32) * ARENA;
            if (s.positionClear(head_x, head_y, slot) or attempt + 1 == SPAWN_ATTEMPTS) break;
        }
        const angle = rng.float(f32) * 2.0 * std.math.pi;
        const snake = &s.snakes[slot];
        snake.* = .{};
        snake.slot = @intCast(slot);
        snake.alive = true;
        snake.head_x = head_x;
        snake.head_y = head_y;
        snake.angle = angle;
        snake.target_angle = angle;
        snake.mass = INITIAL_MASS;
        snake.rb_head = 0;
        snake.rb_len = INITIAL_MASS;
        const dx = @cos(angle) * SPACING;
        const dy = @sin(angle) * SPACING;
        for (0..INITIAL_MASS) |k| {
            const step: f32 = @floatFromInt(k);
            snake.body[ringIndex(snake.rb_head, k)] = .{
                .x = wrap(head_x - step * dx),
                .y = wrap(head_y - step * dy),
            };
        }
        return snake;
    }

    /// Mark `slot`'s snake dead and collect its corpse-pellet sample indices
    /// into `scratch` (design §1.6): every DEATH_DROP_STRIDE-th sample walking
    /// the ring newest->oldest, excluding the head sample, capped at
    /// DEATH_DROP_CAP. Returns the number written. Pure: it touches only the
    /// snake's alive flag and the scratch; the tick slice converts the listed
    /// samples into dropped food (FOOD_MASS_DROPPED) against the food array.
    pub fn killSnake(s: *Snek, slot: usize, scratch: *[DEATH_DROP_CAP]u16) usize {
        const snake = &s.snakes[slot];
        if (!snake.alive) return 0;
        snake.alive = false;
        var count: usize = 0;
        var back: usize = 1; // the head sample itself never drops a pellet
        while (back < snake.rb_len and count < DEATH_DROP_CAP) : (back += DEATH_DROP_STRIDE) {
            scratch[count] = @intCast(ringIndex(snake.rb_head, back));
            count += 1;
        }
        return count;
    }

    /// turn_rate(mass) per design §1.1: clamp(TURN_RATE_BASE*sqrt(30/len),
    /// TURN_RATE_MIN, TURN_RATE_BASE) rad/s, len = mass in segments.
    pub fn turnRate(mass: u16) f32 {
        const len: f32 = @floatFromInt(@max(mass, 1));
        const rate: f32 = TURN_RATE_BASE * std.math.sqrt(30.0 / len);
        return std.math.clamp(rate, TURN_RATE_MIN, TURN_RATE_BASE);
    }

    // --- internals ---

    fn spawnAmbientFood(s: *Snek, rng: *std.Random) void {
        // Ambient pellets occupy slots 0..food_target-1; the freelist stacks
        // every higher slot. Invariant: free holds exactly MAX_FOOD - count
        // slot indices, its top at MAX_FOOD - count - 1.
        for (0..s.food_target) |i| {
            s.food.x[i] = @intFromFloat(rng.float(f32) * ARENA);
            s.food.y[i] = @intFromFloat(rng.float(f32) * ARENA);
            s.food.mass[i] = FOOD_MASS_AMBIENT;
        }
        for (s.food_target..MAX_FOOD) |i| s.food.free[i - s.food_target] = @intCast(i);
        s.food.count = s.food_target;
    }

    /// Pop one dead pellet slot from the freelist (used by the later food
    /// slice for respawns and death bursts). Allocation-free.
    pub fn foodAcquire(s: *Snek) usize {
        const free_len = MAX_FOOD - s.food.count;
        std.debug.assert(free_len > 0);
        const slot = s.food.free[free_len - 1];
        s.food.count += 1;
        return slot;
    }

    /// Return a pellet slot (its pellet's life ended) to the freelist.
    pub fn foodRelease(s: *Snek, slot: usize) void {
        s.food.free[MAX_FOOD - s.food.count] = @intCast(slot);
        s.food.count -= 1;
    }

    /// True when no other snake's body sample is within SPAWN_CLEAR_RADIUS of
    /// (x, y). Linear over the roster (100 snakes x 1000 samples worst case is
    /// fine per design §2.1); `slot` excludes its own samples.
    fn positionClear(s: *const Snek, x: f32, y: f32, slot: usize) bool {
        const radius2 = SPAWN_CLEAR_RADIUS * SPAWN_CLEAR_RADIUS;
        for (s.snakes, 0..) |candidate, index| {
            if (index == slot or !candidate.alive) continue;
            for (0..candidate.rb_len) |back| {
                const sample = candidate.body[ringIndex(candidate.rb_head, back)];
                const dx = sample.x - x;
                const dy = sample.y - y;
                if (dx * dx + dy * dy < radius2) return false;
            }
        }
        return true;
    }
};

/// Physical ring index `back` samples behind the newest sample at rb_head.
/// Valid while back < rb_len. The ring invariant: body[rb_head] is the newest
/// sample and increasing `back` walks toward the tail (oldest).
pub fn ringIndex(rb_head: usize, back: usize) usize {
    std.debug.assert(back < MAX_MASS);
    return (rb_head + MAX_MASS - back) % MAX_MASS;
}

/// Wrap a world coordinate into [0, ARENA). Sample spacing and per-tick head
/// steps are far smaller than ARENA, so a single wrap in each direction is
/// exact for every value this module produces.
fn wrap(x: f32) f32 {
    if (x < 0) return x + ARENA;
    if (x >= ARENA) return x - ARENA;
    return x;
}

test "init places the ambient food population deterministically" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    var rng = prng.random();
    const first = try Snek.init(std.testing.allocator, FOOD_TARGET, MAX_FOOD, &rng);
    defer Snek.deinit(first, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, FOOD_TARGET), first.food.count);
    try std.testing.expectEqual(FOOD_TARGET, first.food_target);
    try std.testing.expectEqual(MAX_FOOD, first.max_food);
    for (0..first.food.count) |i| {
        try std.testing.expect(first.food.x[i] < @as(u16, @intFromFloat(ARENA)));
        try std.testing.expect(first.food.y[i] < @as(u16, @intFromFloat(ARENA)));
        try std.testing.expectEqual(FOOD_MASS_AMBIENT, first.food.mass[i]);
    }

    // The freelist stacks exactly the dead slots above the live population.
    const free_len = MAX_FOOD - first.food.count;
    for (0..free_len) |k| try std.testing.expect(first.food.free[k] >= first.food.count);

    // Same seed, same positions: placement is deterministic per lobby seed.
    var prng2 = std.Random.DefaultPrng.init(0x5EED);
    var rng2 = prng2.random();
    const second = try Snek.init(std.testing.allocator, FOOD_TARGET, MAX_FOOD, &rng2);
    defer Snek.deinit(second, std.testing.allocator);
    try std.testing.expectEqualSlices(u16, first.food.x[0..10], second.food.x[0..10]);
    try std.testing.expectEqualSlices(u16, first.food.y[0..10], second.food.y[0..10]);

    // Env-style capacities clamp to the fixed arrays rather than overflow.
    var prng3 = std.Random.DefaultPrng.init(1);
    var rng3 = prng3.random();
    const clamped = try Snek.init(std.testing.allocator, 200_000, 400_000, &rng3);
    defer Snek.deinit(clamped, std.testing.allocator);
    try std.testing.expectEqual(MAX_FOOD, clamped.max_food);
    try std.testing.expectEqual(MAX_FOOD, clamped.food_target);
    try std.testing.expectEqual(@as(usize, MAX_FOOD), clamped.food.count);
}

test "food acquire and release keep the freelist population invariant" {
    var prng = std.Random.DefaultPrng.init(7);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, FOOD_TARGET, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const before = s.food.count;
    const slot = s.foodAcquire();
    try std.testing.expectEqual(before + 1, s.food.count);
    try std.testing.expect(slot < MAX_FOOD);
    s.foodRelease(slot);
    try std.testing.expectEqual(before, s.food.count);
}

test "spawn seeds a full body ring trailing the head opposite the heading" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 8, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const snake = s.spawnSnake(3, &rng);
    try std.testing.expectEqual(@as(u16, 3), snake.slot);
    try std.testing.expect(snake.alive);
    try std.testing.expectEqual(INITIAL_MASS, snake.mass);
    try std.testing.expectEqual(@as(usize, INITIAL_MASS), snake.rb_len);
    try std.testing.expect(snake.head_x >= 0 and snake.head_x < ARENA);
    try std.testing.expect(snake.head_y >= 0 and snake.head_y < ARENA);

    const head = snake.body[ringIndex(snake.rb_head, 0)];
    try std.testing.expectApproxEqAbs(snake.head_x, head.x, 0.001);
    try std.testing.expectApproxEqAbs(snake.head_y, head.y, 0.001);

    // The tail sample is ~(INITIAL_MASS-1)*SPACING behind the head, opposite
    // the facing angle (cos/sin of angle + pi).
    const tail = snake.body[ringIndex(snake.rb_head, INITIAL_MASS - 1)];
    const dx = tail.x - snake.head_x;
    const dy = tail.y - snake.head_y;
    const expected_len: f32 = @floatFromInt(INITIAL_MASS - 1);
    try std.testing.expectApproxEqAbs(expected_len * SPACING, @sqrt(dx * dx + dy * dy), 1.0);
    const heading_dot = @cos(snake.angle + std.math.pi) * dx + @sin(snake.angle + std.math.pi) * dy;
    try std.testing.expect(heading_dot > 0);

    // Collinear samples: each is exactly SPACING behind the previous one.
    const middle = snake.body[ringIndex(snake.rb_head, 1)];
    const dmx = middle.x - head.x;
    const dmy = middle.y - head.y;
    try std.testing.expectApproxEqAbs(SPACING, @sqrt(dmx * dmx + dmy * dmy), 1.0);
}

test "spawn clear check rejects bodies inside the safety radius" {
    var prng = std.Random.DefaultPrng.init(9);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 4, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.snakes[1] = .{};
    s.snakes[1].alive = true;
    s.snakes[1].head_x = 100;
    s.snakes[1].head_y = 100;
    s.snakes[1].rb_head = 0;
    s.snakes[1].rb_len = 3;
    s.snakes[1].body[0] = .{ .x = 100, .y = 100 };
    s.snakes[1].body[1] = .{ .x = 90, .y = 100 };
    s.snakes[1].body[2] = .{ .x = 80, .y = 100 };
    try std.testing.expect(!s.positionClear(105, 100, 2));
    try std.testing.expect(!s.positionClear(380, 100, 2)); // 280 < 300
    try std.testing.expect(s.positionClear(2000, 2000, 2));
}

test "kill walks the corpse newest-to-oldest and excludes the head" {
    var prng = std.Random.DefaultPrng.init(0xD1CE);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 8, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const snake = s.spawnSnake(0, &rng);
    const head_ring = snake.rb_head;
    var scratch: [DEATH_DROP_CAP]u16 = undefined;
    const count = s.killSnake(0, &scratch);
    try std.testing.expectEqual(INITIAL_MASS / 2, count); // backs 1,3,...,29
    try std.testing.expect(!snake.alive);
    try std.testing.expectEqual(ringIndex(head_ring, 1), scratch[0]);
    for (0..count) |i| {
        try std.testing.expectEqual(ringIndex(head_ring, 1 + i * 2), scratch[i]);
    }
    // Dead snakes yield nothing on a second call.
    try std.testing.expectEqual(@as(usize, 0), s.killSnake(0, &scratch));
}

test "turn rate follows the design table" {
    try std.testing.expectApproxEqAbs(TURN_RATE_BASE, Snek.turnRate(1), 0.001);
    try std.testing.expectApproxEqAbs(TURN_RATE_BASE, Snek.turnRate(30), 0.001);
    try std.testing.expectApproxEqAbs(1.336, Snek.turnRate(340), 0.01);
    try std.testing.expectApproxEqAbs(TURN_RATE_MIN, Snek.turnRate(1000), 0.001);
}
