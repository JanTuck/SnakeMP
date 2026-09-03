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
pub const HIT_R: f32 = 13.0; // base collision distance at spawn mass
pub const MAX_MASS: u16 = 1000; // segments == length
pub const MAX_SNAKES: usize = 100; // roster slots 0..99
pub const MAX_FOOD: usize = 8192;
pub const FOOD_TARGET: usize = 5000;
pub const HASH_CELL: f32 = 32.0;
pub const HASH_BUCKETS: usize = 65_536; // (8192/32)^2

// §1.1 gameplay constants consumed by this slice's helpers.
pub const INITIAL_MASS: u16 = 30; // respawn length 240 px
pub const SPAWN_CLEAR_RADIUS: f32 = 300.0; // no body center inside
pub const SPAWN_ATTEMPTS: usize = 32; // bounded search, then shield fallback
pub const SPAWN_SHIELD_TICKS: u16 = 60; // two seconds; initial tail is gone after 30
pub const FALLBACK_SPAWN_SHIELD_TICKS: u16 = 90;
pub const FOOD_KIND_CORPSE: u8 = 1;
pub const FOOD_KIND_PELLET: u8 = 2;
pub const FOOD_KIND_PARTY_FIRST: u8 = 3;
pub const FOOD_KIND_PARTY_LAST: u8 = 10;
pub const DEATH_DROP_STRIDE: usize = 2; // pellets dropped 16 px apart
pub const DEATH_DROP_CAP: usize = 150; // per death
pub const TURN_RATE_BASE: f32 = 5.6; // rad/s at length <= 30
pub const TURN_RATE_MIN: f32 = 1.8; // large snakes stay party-game responsive
pub const BASE_SPEED: f32 = 180.0;
pub const BOOST_MULT: f32 = 2.0;
pub const MIN_BOOST_MASS: u16 = 22;
pub const BOOST_BURN_TICKS: u8 = 8;
pub const FOOD_MASS_DROPPED: u8 = FOOD_KIND_CORPSE;
pub const PARTY_SLOT_STRIDE: usize = 97;
pub const OBSTACLE_RESPAWN_TICKS: u16 = 900; // 30 seconds at 30 Hz
pub const OBSTACLE_RESPAWN_MARGIN: f32 = 24.0;
pub const OBSTACLE_HITBOX_SCALE: f32 = 0.70;
pub const CRATE_EAT_RADIUS: f32 = 64.0;
pub const MINE_EAT_RADIUS: f32 = 70.0;
pub const CRATE_BURST_COUNT: usize = 24;
pub const LIGHTNING_TICKS: u16 = 120; // four seconds of free turbo
pub const RAINBOW_SHIELD_TICKS: u16 = 150; // five seconds of hazard smashing

pub const Obstacle = struct { x: f32, y: f32, radius: f32, kind: u8 };

/// One shared, immutable IO party map. It costs no per-lobby allocation and
/// the browser mirrors these exact landmarks from client/js/ioWorld.js.
pub const OBSTACLES = [_]Obstacle{
    .{ .x = 620, .y = 760, .radius = 64, .kind = 0 },
    .{ .x = 1420, .y = 1180, .radius = 52, .kind = 2 },
    .{ .x = 2380, .y = 620, .radius = 64, .kind = 0 },
    .{ .x = 3440, .y = 1320, .radius = 52, .kind = 2 },
    .{ .x = 4680, .y = 690, .radius = 64, .kind = 0 },
    .{ .x = 5860, .y = 1460, .radius = 64, .kind = 0 },
    .{ .x = 7140, .y = 840, .radius = 52, .kind = 2 },
    .{ .x = 7860, .y = 1810, .radius = 52, .kind = 2 },
    .{ .x = 1040, .y = 2720, .radius = 64, .kind = 0 },
    .{ .x = 2180, .y = 3280, .radius = 64, .kind = 0 },
    .{ .x = 3180, .y = 2460, .radius = 52, .kind = 2 },
    .{ .x = 4240, .y = 3380, .radius = 52, .kind = 2 },
    .{ .x = 5480, .y = 2640, .radius = 64, .kind = 0 },
    .{ .x = 6660, .y = 3480, .radius = 64, .kind = 0 },
    .{ .x = 7600, .y = 2860, .radius = 52, .kind = 2 },
    .{ .x = 540, .y = 4560, .radius = 52, .kind = 2 },
    .{ .x = 1640, .y = 5220, .radius = 64, .kind = 0 },
    .{ .x = 2840, .y = 4380, .radius = 64, .kind = 0 },
    .{ .x = 3920, .y = 5460, .radius = 52, .kind = 2 },
    .{ .x = 5120, .y = 4520, .radius = 52, .kind = 2 },
    .{ .x = 6240, .y = 5320, .radius = 64, .kind = 0 },
    .{ .x = 7420, .y = 4460, .radius = 64, .kind = 0 },
    .{ .x = 1120, .y = 6720, .radius = 52, .kind = 2 },
    .{ .x = 2520, .y = 7340, .radius = 52, .kind = 2 },
    .{ .x = 4080, .y = 6500, .radius = 64, .kind = 0 },
    .{ .x = 5580, .y = 7480, .radius = 64, .kind = 0 },
    .{ .x = 7040, .y = 6680, .radius = 52, .kind = 2 },
};

pub const Sample = struct { x: f32, y: f32 }; // 8 bytes

pub const Snake = struct {
    slot: u16 = 0, // roster slot (palette color source)
    alive: bool = false,
    head_x: f32 = 0,
    head_y: f32 = 0,
    angle: f32 = 0, // facing, radians
    target_angle: f32 = 0, // from steer packet 6
    mass: u16 = INITIAL_MASS, // segments; length == mass
    mass_frac: u16 = 0, // cumulative active boost ticks toward one mass burn
    growth_pending: u16 = 0,
    boosting: bool = false,
    turbo_ticks: u16 = 0,
    shield_ticks: u16 = 0,
    rb_head: usize = 0, // ring: newest sample index
    rb_len: usize = 0, // valid samples == mass (invariant)
    body: [MAX_MASS]Sample = undefined, // fixed ring buffer, preallocated
    // ~8_050 B/snake (metadata + 8 KB ring)
};

pub const Food = struct { // SoA, fixed capacity, freelist
    x: [MAX_FOOD]u16 = undefined, // 0..8191 quantum
    y: [MAX_FOOD]u16 = undefined,
    mass: [MAX_FOOD]u8 = undefined, // compact food kind 1..10; 0 is unused
    free: [MAX_FOOD]u16 = undefined, // freelist stack of dead slot indices
    // Two packed grace bits per slot keep fresh corpse/crate drops visible for
    // a publication without pausing unrelated pickups across the whole map.
    grace: [MAX_FOOD / 4]u8 = [_]u8{0} ** (MAX_FOOD / 4),
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

pub const Death = struct {
    slot: u8,
    killer_slot: ?u8,
    x: f32,
    y: f32,
};

pub const TickResult = struct {
    deaths: [MAX_SNAKES]Death = undefined,
    death_count: usize = 0,
};

const CollisionHit = struct { killer_slot: ?u8 };

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
    obstacle_alive_mask: u32 = (@as(u32, 1) << OBSTACLES.len) - 1,
    obstacle_respawn_ticks: [OBSTACLES.len]u16 = [_]u16{0} ** OBSTACLES.len,

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
    /// SPAWN_CLEAR_RADIUS; a saturated-arena fallback receives brief shielding.
    /// The body ring is seeded with INITIAL_MASS samples trailing behind the
    /// head opposite to the facing angle (sample k is k*SPACING behind).
    /// Deterministic for a given rng; allocation-free.
    pub fn spawnSnake(s: *Snek, slot: usize, rng: *std.Random) *Snake {
        std.debug.assert(slot < MAX_SNAKES);
        var head_x: f32 = 0;
        var head_y: f32 = 0;
        var attempt: usize = 0;
        var found_clear = false;
        while (attempt < SPAWN_ATTEMPTS) : (attempt += 1) {
            head_x = rng.float(f32) * ARENA;
            head_y = rng.float(f32) * ARENA;
            if (s.positionClear(head_x, head_y, slot)) {
                found_clear = true;
                break;
            }
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
        // Every spawn gets a short, visible neutral window. The initial body
        // is materialized behind the head all at once; without this window it
        // could cut off a nearby player before either player had a chance to
        // react. After 30 ticks the entire initial ring has been replaced by
        // movement samples, so two seconds is ample without slowing play.
        snake.shield_ticks = if (found_clear) SPAWN_SHIELD_TICKS else FALLBACK_SPAWN_SHIELD_TICKS;
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

    /// Render/collision radius grows sublinearly with mass, preserving clear
    /// steering at high scores while making successful snakes visibly wider.
    pub fn snakeRadius(mass: u16) f32 {
        const extra: f32 = @floatFromInt(mass -| INITIAL_MASS);
        return std.math.clamp(10.0 + std.math.sqrt(extra) * 2.2, 10.0, 72.0);
    }

    pub fn foodGrowth(kind: u8) u16 {
        return switch (kind) {
            // Corpse trails are the PvP comeback reward. Two growth per fixed
            // slot returns 100% of a <=300-mass victim and is capped at 300
            // total growth for larger victims by DEATH_DROP_CAP. That makes a
            // big takedown worthwhile without letting one kill mint an
            // unbounded leader snowball or allocate more food storage.
            FOOD_KIND_CORPSE => 2,
            FOOD_KIND_PELLET => 2,
            3 => 3, // strawberry
            4 => 5, // apple
            5 => 7, // cheese
            6 => 10, // donut
            7 => 12, // golden apple
            8 => 6, // lightning berry
            9 => 9, // rainbow candy
            10 => 14, // feast platter
            else => 0,
        };
    }

    pub fn obstacleEatRadius(kind: u8) f32 {
        return switch (kind) {
            0 => CRATE_EAT_RADIUS,
            2 => MINE_EAT_RADIUS,
            else => std.math.inf(f32),
        };
    }

    pub fn obstacleReward(kind: u8) u16 {
        return switch (kind) {
            0 => 16,
            2 => 60,
            else => 0,
        };
    }

    /// Advance one continuous-world simulation step. Movement, spatial-hash
    /// collision classification, corpse conversion, and pellet collection are
    /// allocation-free; all deaths are classified before any snake is removed.
    pub fn tick(s: *Snek, dt: f32, rng: *std.Random) TickResult {
        var result: TickResult = .{};

        for (&s.obstacle_respawn_ticks, 0..) |*remaining, obstacle_index| {
            if (remaining.* == 0) continue;
            remaining.* -= 1;
            if (remaining.* == 0) {
                if (s.obstacleRespawnClear(obstacle_index)) {
                    s.obstacle_alive_mask |= @as(u32, 1) << @intCast(obstacle_index);
                } else {
                    // Retry next tick rather than materializing a hazard under
                    // a live player and causing an unavoidable instant death.
                    remaining.* = 1;
                }
            }
        }

        var previous_heads: [MAX_SNAKES]Sample = undefined;
        for (&s.snakes, 0..) |*snake, slot| {
            if (!snake.alive) continue;
            previous_heads[slot] = .{ .x = snake.head_x, .y = snake.head_y };
            const max_turn = Snek.turnRate(snake.mass) * dt;
            const delta = angleDelta(snake.angle, snake.target_angle);
            snake.angle = normalizeAngle(snake.angle + std.math.clamp(delta, -max_turn, max_turn));

            const turbo = snake.turbo_ticks > 0;
            const can_boost = turbo or (snake.boosting and snake.mass > MIN_BOOST_MASS);
            const speed = BASE_SPEED * (if (can_boost) BOOST_MULT else 1.0);
            snake.head_x = wrap(snake.head_x + @cos(snake.angle) * speed * dt);
            snake.head_y = wrap(snake.head_y + @sin(snake.angle) * speed * dt);
            snake.rb_head = (snake.rb_head + 1) % MAX_MASS;
            snake.body[snake.rb_head] = .{ .x = snake.head_x, .y = snake.head_y };

            if (snake.growth_pending > 0) {
                if (snake.mass < MAX_MASS) {
                    snake.growth_pending -= 1;
                    snake.mass += 1;
                    snake.rb_len = snake.mass;
                } else {
                    // The size cap is a real cap, not a hidden mass bank.
                    // Otherwise a capped snake can hoard thousands of queued
                    // growth points and fund nearly free boost long after it
                    // leaves the food that earned them.
                    snake.growth_pending = 0;
                }
            }
            if (can_boost and !turbo) {
                snake.mass_frac +%= 1;
                if (snake.mass_frac >= BOOST_BURN_TICKS) {
                    snake.mass_frac = 0;
                    snake.mass -= 1;
                    snake.rb_len = snake.mass;
                }
            }
        }

        s.rebuildHash();
        var dead = [_]bool{false} ** MAX_SNAKES;
        var killers = [_]?u8{null} ** MAX_SNAKES;
        var obstacle_eats = [_]?u8{null} ** MAX_SNAKES;
        for (&s.snakes, 0..) |*snake, slot| {
            if (!snake.alive) continue;
            const obstacle_hit = s.obstacleCollision(snake, previous_heads[slot]);
            if (obstacle_hit) |obstacle_index| {
                const obstacle = OBSTACLES[obstacle_index];
                if (snake.shield_ticks == 0 and Snek.snakeRadius(snake.mass) < Snek.obstacleEatRadius(obstacle.kind)) {
                    dead[slot] = true;
                    killers[slot] = null;
                }
            }
            if (!dead[slot] and snake.shield_ticks == 0) {
                if (s.headCollision(slot, snake, &previous_heads)) |hit| {
                    dead[slot] = true;
                    killers[slot] = hit.killer_slot;
                }
            }
            if (!dead[slot] and obstacle_hit != null) obstacle_eats[slot] = @intCast(obstacle_hit.?);
        }

        var obstacle_winners = [_]?u8{null} ** OBSTACLES.len;
        var obstacle_winner_distance2 = [_]f32{std.math.inf(f32)} ** OBSTACLES.len;
        for (obstacle_eats, 0..) |maybe_obstacle, slot| {
            const obstacle_index: usize = maybe_obstacle orelse continue;
            const obstacle = OBSTACLES[obstacle_index];
            const distance2 = sweptPointDistance2(
                previous_heads[slot],
                .{ .x = s.snakes[slot].head_x, .y = s.snakes[slot].head_y },
                .{ .x = obstacle.x, .y = obstacle.y },
            );
            const current = obstacle_winners[obstacle_index];
            if (distance2 < obstacle_winner_distance2[obstacle_index] or
                (distance2 == obstacle_winner_distance2[obstacle_index] and
                    (current == null or slot < current.?)))
            {
                obstacle_winner_distance2[obstacle_index] = distance2;
                obstacle_winners[obstacle_index] = @intCast(slot);
            }
        }

        var crate_burst_mask: u32 = 0;
        for (obstacle_winners, 0..) |maybe_winner, obstacle_index| {
            const slot: usize = maybe_winner orelse continue;
            const bit = @as(u32, 1) << @intCast(obstacle_index);
            if (s.obstacle_alive_mask & bit == 0) continue;
            s.obstacle_alive_mask &= ~bit;
            s.obstacle_respawn_ticks[obstacle_index] = OBSTACLE_RESPAWN_TICKS;
            s.snakes[slot].growth_pending +|= Snek.obstacleReward(OBSTACLES[obstacle_index].kind);
            if (OBSTACLES[obstacle_index].kind == 0) crate_burst_mask |= bit;
        }

        for (dead, 0..) |is_dead, slot| {
            if (!is_dead) continue;
            const snake = &s.snakes[slot];
            result.deaths[result.death_count] = .{
                .slot = @intCast(slot),
                .killer_slot = killers[slot],
                .x = snake.head_x,
                .y = snake.head_y,
            };
            result.death_count += 1;
            var corpse: [DEATH_DROP_CAP]u16 = undefined;
            const drop_count = s.killSnake(slot, &corpse);
            for (corpse[0..drop_count]) |body_index| {
                if (s.food.count >= s.max_food) break;
                const food_slot = s.foodAcquire();
                const sample = snake.body[body_index];
                s.food.x[food_slot] = quantizeCoordinate(sample.x);
                s.food.y[food_slot] = quantizeCoordinate(sample.y);
                s.food.mass[food_slot] = FOOD_MASS_DROPPED;
                s.setFoodGrace(food_slot, 2);
            }
        }

        // Existing effects cover this complete tick. Countdown happens after
        // movement and collision, but before pickups, so a newly collected
        // effect receives its full advertised duration starting next tick.
        for (&s.snakes) |*snake| {
            if (!snake.alive) continue;
            if (snake.turbo_ticks > 0) snake.turbo_ticks -= 1;
            if (snake.shield_ticks > 0) snake.shield_ticks -= 1;
        }

        // Resolve each pellet once, awarding a simultaneous pickup to the
        // closest eligible head (then stable slot order for an exact tie).
        // This removes roster-order advantage without changing the bounded
        // O(food * snakes) work the old snake-first scan already performed.
        var food_slot: usize = 0;
        while (food_slot < MAX_FOOD) : (food_slot += 1) {
            const mass = s.food.mass[food_slot];
            if (mass == 0 or s.foodGrace(food_slot) > 0) continue;
            const growth = Snek.foodGrowth(mass);
            var winner: ?usize = null;
            var winner_distance2 = std.math.inf(f32);
            for (&s.snakes, 0..) |*snake, snake_slot| {
                if (!snake.alive) continue;
                const distance2 = sweptPointDistance2(
                    previous_heads[snake_slot],
                    .{ .x = snake.head_x, .y = snake.head_y },
                    .{
                        .x = @floatFromInt(s.food.x[food_slot]),
                        .y = @floatFromInt(s.food.y[food_slot]),
                    },
                );
                const pickup_r = Snek.snakeRadius(snake.mass) + 5.0 + @as(f32, @floatFromInt(growth)) * 0.8;
                if (distance2 > pickup_r * pickup_r) continue;
                if (distance2 < winner_distance2 or
                    (distance2 == winner_distance2 and (winner == null or snake_slot < winner.?)))
                {
                    winner = snake_slot;
                    winner_distance2 = distance2;
                }
            }
            const snake = &s.snakes[winner orelse continue];
            snake.growth_pending +|= growth;
            if (mass == 8) snake.turbo_ticks = @max(snake.turbo_ticks, LIGHTNING_TICKS);
            if (mass == 9) snake.shield_ticks = @max(snake.shield_ticks, RAINBOW_SHIELD_TICKS);
            s.food.mass[food_slot] = 0;
            s.foodRelease(food_slot);
        }
        s.ageFoodGrace();
        // Materialize crate loot after this tick's pickup pass so the snake
        // that broke it cannot consume the whole shower before clients ever
        // see it.
        for (OBSTACLES, 0..) |obstacle, obstacle_index| {
            if (crate_burst_mask & (@as(u32, 1) << @intCast(obstacle_index)) != 0) s.burstCrateFood(obstacle, rng);
        }
        while (s.food.count < s.food_target) {
            const slot = s.foodAcquire();
            s.placeAmbientFood(slot, rng);
        }
        return result;
    }

    pub fn despawnSnake(s: *Snek, slot: usize) void {
        if (slot < MAX_SNAKES) s.snakes[slot].alive = false;
    }

    // --- internals ---

    fn spawnAmbientFood(s: *Snek, rng: *std.Random) void {
        // Ambient pellets occupy slots 0..food_target-1; the freelist stacks
        // every higher slot. Invariant: free holds exactly MAX_FOOD - count
        // slot indices, its top at MAX_FOOD - count - 1.
        for (0..s.food_target) |i| {
            s.placeAmbientFood(i, rng);
        }
        for (s.food_target..MAX_FOOD) |i| s.food.free[i - s.food_target] = @intCast(i);
        @memset(s.food.mass[s.food_target..], 0);
        @memset(&s.food.grace, 0);
        s.food.count = s.food_target;
    }

    /// Pop one dead pellet slot from the freelist (used by the later food
    /// slice for respawns and death bursts). Allocation-free.
    pub fn foodAcquire(s: *Snek) usize {
        const free_len = MAX_FOOD - s.food.count;
        std.debug.assert(free_len > 0);
        const slot = s.food.free[free_len - 1];
        s.food.count += 1;
        s.setFoodGrace(slot, 0);
        return slot;
    }

    /// Return a pellet slot (its pellet's life ended) to the freelist.
    pub fn foodRelease(s: *Snek, slot: usize) void {
        s.setFoodGrace(slot, 0);
        s.food.free[MAX_FOOD - s.food.count] = @intCast(slot);
        s.food.count -= 1;
    }

    /// True when no other snake's body sample is within SPAWN_CLEAR_RADIUS of
    /// (x, y). Linear over the roster (100 snakes x 1000 samples worst case is
    /// fine per design §2.1); `slot` excludes its own samples.
    fn positionClear(s: *const Snek, x: f32, y: f32, slot: usize) bool {
        const radius2 = SPAWN_CLEAR_RADIUS * SPAWN_CLEAR_RADIUS;
        for (&s.snakes, 0..) |*candidate, index| {
            if (index == slot or !candidate.alive) continue;
            for (0..candidate.rb_len) |back| {
                const sample = candidate.body[ringIndex(candidate.rb_head, back)];
                const dx = wrappedDelta(sample.x, x);
                const dy = wrappedDelta(sample.y, y);
                if (dx * dx + dy * dy < radius2) return false;
            }
        }
        for (OBSTACLES, 0..) |obstacle, obstacle_index| {
            if (s.obstacle_alive_mask & (@as(u32, 1) << @intCast(obstacle_index)) == 0) continue;
            const dx = wrappedDelta(x, obstacle.x);
            const dy = wrappedDelta(y, obstacle.y);
            const clear_r = SPAWN_CLEAR_RADIUS + obstacle.radius;
            if (dx * dx + dy * dy < clear_r * clear_r) return false;
        }
        return true;
    }

    fn placeAmbientFood(s: *Snek, slot: usize, rng: *std.Random) void {
        const party = slot % PARTY_SLOT_STRIDE == 0;
        const kind: u8 = if (party) @intCast(FOOD_KIND_PARTY_FIRST + (slot / PARTY_SLOT_STRIDE) % (FOOD_KIND_PARTY_LAST - FOOD_KIND_PARTY_FIRST + 1)) else FOOD_KIND_PELLET;
        if (party) {
            const obstacle = OBSTACLES[(slot / PARTY_SLOT_STRIDE) % OBSTACLES.len];
            const angle = rng.float(f32) * 2.0 * std.math.pi;
            const distance = obstacle.radius + 90.0 + rng.float(f32) * 170.0;
            s.food.x[slot] = quantizeCoordinate(wrap(obstacle.x + @cos(angle) * distance));
            s.food.y[slot] = quantizeCoordinate(wrap(obstacle.y + @sin(angle) * distance));
        } else {
            s.food.x[slot] = @intFromFloat(rng.float(f32) * ARENA);
            s.food.y[slot] = @intFromFloat(rng.float(f32) * ARENA);
        }
        s.food.mass[slot] = kind;
    }

    fn rebuildHash(s: *Snek) void {
        @memset(&s.hash.heads, std.math.maxInt(u32));
        s.hash.node_top = 0;
        for (&s.snakes, 0..) |*snake, slot| {
            if (!snake.alive) continue;
            for (0..snake.rb_len) |back| {
                if (s.hash.node_top >= HASH_NODES) return;
                const sample = snake.body[ringIndex(snake.rb_head, back)];
                const bucket = hashBucket(sample.x, sample.y);
                const node = s.hash.node_top;
                s.hash.node_top += 1;
                s.hash.nodes.ids[node] = (@as(u32, @intCast(slot)) << 14) | @as(u32, @intCast(back));
                s.hash.nodes.next[node] = s.hash.heads[bucket];
                s.hash.heads[bucket] = @intCast(node);
            }
        }
    }

    fn headCollision(
        s: *const Snek,
        slot: usize,
        snake: *const Snake,
        previous_heads: *const [MAX_SNAKES]Sample,
    ) ?CollisionHit {
        // Heads live at back == 0 in the same spatial index as body samples,
        // but a head clash is not a body hit: the larger snake wins and equal
        // masses trade. Classify these first so hash insertion order cannot
        // turn the loser's head into a lethal body sample for the winner.
        var head_killer: ?usize = null;
        var won_head_clash = [_]bool{false} ** MAX_SNAKES;
        for (&s.snakes, 0..) |*owner_snake, owner| {
            // Shielded snakes are neutral: they neither die nor eliminate
            // someone else while spawning (or while a rainbow shield is up).
            if (owner == slot or !owner_snake.alive or owner_snake.shield_ticks > 0) continue;
            const hit_r = snakeContactRadius(snake, owner_snake);
            if (sweptHeadDistance2(
                previous_heads[slot],
                .{ .x = snake.head_x, .y = snake.head_y },
                previous_heads[owner],
                .{ .x = owner_snake.head_x, .y = owner_snake.head_y },
            ) > hit_r * hit_r) continue;
            if (snake.mass > owner_snake.mass) {
                won_head_clash[owner] = true;
                continue;
            }

            const current = head_killer orelse {
                head_killer = owner;
                continue;
            };
            const current_snake = &s.snakes[current];
            if (owner_snake.mass > current_snake.mass or
                (owner_snake.mass == current_snake.mass and owner < current))
            {
                head_killer = owner;
            }
        }
        if (head_killer) |owner| return .{ .killer_slot = @intCast(owner) };

        const cells_per_axis: i32 = @intFromFloat(ARENA / HASH_CELL);
        const cx: i32 = @intFromFloat(@floor(snake.head_x / HASH_CELL));
        const cy: i32 = @intFromFloat(@floor(snake.head_y / HASH_CELL));
        // A boosted head sweeps 12 px and the maximum contact radius is 75 px.
        // Their 87 px total reach still fits a three-cell search with 32 px
        // hash cells, including when the current head sits on a cell edge.
        var body_killer: ?usize = null;
        var closest_body_hit2 = std.math.inf(f32);
        var oy: i32 = -3;
        while (oy <= 3) : (oy += 1) {
            var ox: i32 = -3;
            while (ox <= 3) : (ox += 1) {
                const bx = @mod(cx + ox, cells_per_axis);
                const by = @mod(cy + oy, cells_per_axis);
                var node = s.hash.heads[@intCast(by * cells_per_axis + bx)];
                while (node != std.math.maxInt(u32)) {
                    const id = s.hash.nodes.ids[node];
                    const owner: usize = @intCast(id >> 14);
                    const back: usize = @intCast(id & 0x3fff);
                    node = s.hash.nodes.next[node];
                    // IO follows the snake.io rule: your own body is safe.
                    // Only another snake's body can eliminate you.
                    if (owner == slot) continue;
                    if (s.snakes[owner].shield_ticks > 0) continue;
                    // Pairwise head-clash resolution takes precedence over
                    // the loser's freshly sampled neck/body in this same
                    // immutable frame. Other opponents' bodies remain lethal.
                    if (won_head_clash[owner]) continue;
                    // Current heads were resolved above. `back == 1` is the
                    // owner's previous head, inserted only at the end of this
                    // step; treating it as stationary for the whole swept
                    // interval creates a one-tick ghost collision when the
                    // heads visibly miss. The older ring is genuine body.
                    if (back <= 1) continue;
                    const owner_snake = &s.snakes[owner];
                    const sample = owner_snake.body[ringIndex(owner_snake.rb_head, back)];
                    const hit_r = snakeContactRadius(snake, owner_snake);
                    const hit2 = hit_r * hit_r;
                    const distance2 = sweptPointDistance2(
                        previous_heads[slot],
                        .{ .x = snake.head_x, .y = snake.head_y },
                        sample,
                    );
                    if (distance2 > hit2) continue;
                    const current = body_killer;
                    if (distance2 < closest_body_hit2 or
                        (distance2 == closest_body_hit2 and (current == null or owner < current.?)))
                    {
                        closest_body_hit2 = distance2;
                        body_killer = owner;
                    }
                }
            }
        }
        if (body_killer) |owner| return .{ .killer_slot = @intCast(owner) };
        return null;
    }

    fn obstacleCollision(s: *const Snek, snake: *const Snake, previous_head: Sample) ?usize {
        const snake_r = Snek.snakeRadius(snake.mass);
        for (OBSTACLES, 0..) |obstacle, obstacle_index| {
            if (s.obstacle_alive_mask & (@as(u32, 1) << @intCast(obstacle_index)) == 0) continue;
            // The source PNGs contain transparent padding. Keep the lethal
            // core comfortably inside the visible art so contact is always
            // readable instead of feeling like an invisible wall.
            const hit_r = snake_r + obstacle.radius * OBSTACLE_HITBOX_SCALE;
            if (sweptPointDistance2(
                previous_head,
                .{ .x = snake.head_x, .y = snake.head_y },
                .{ .x = obstacle.x, .y = obstacle.y },
            ) <= hit_r * hit_r) return obstacle_index;
        }
        return null;
    }

    fn obstacleRespawnClear(s: *const Snek, obstacle_index: usize) bool {
        const obstacle = OBSTACLES[obstacle_index];
        for (&s.snakes) |*snake| {
            if (!snake.alive) continue;
            const clear_r = obstacle.radius + Snek.snakeRadius(snake.mass) + OBSTACLE_RESPAWN_MARGIN;
            for (0..snake.rb_len) |back| {
                const sample = snake.body[ringIndex(snake.rb_head, back)];
                const dx = wrappedDelta(sample.x, obstacle.x);
                const dy = wrappedDelta(sample.y, obstacle.y);
                if (dx * dx + dy * dy <= clear_r * clear_r) return false;
            }
        }
        return true;
    }

    fn burstCrateFood(s: *Snek, obstacle: Obstacle, rng: *std.Random) void {
        const available = s.max_food - s.food.count;
        const count = @min(CRATE_BURST_COUNT, available);
        for (0..count) |index| {
            const slot = s.foodAcquire();
            const angle = (@as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(CRATE_BURST_COUNT))) * 2.0 * std.math.pi;
            const distance = obstacle.radius * (0.36 + rng.float(f32) * 0.34);
            s.food.x[slot] = quantizeCoordinate(wrap(obstacle.x + @cos(angle) * distance));
            s.food.y[slot] = quantizeCoordinate(wrap(obstacle.y + @sin(angle) * distance));
            // Mostly substantial apples with a few high-value donuts: a
            // smashed crate visibly showers useful feed into the arena.
            s.food.mass[slot] = if (index % 6 == 0) 6 else 4;
            s.setFoodGrace(slot, 2);
        }
    }

    fn foodGrace(s: *const Snek, slot: usize) u8 {
        const shift: u3 = @intCast((slot & 3) * 2);
        return (s.food.grace[slot / 4] >> shift) & 3;
    }

    fn setFoodGrace(s: *Snek, slot: usize, value: u8) void {
        std.debug.assert(value <= 3);
        const shift: u3 = @intCast((slot & 3) * 2);
        const mask: u8 = @as(u8, 3) << shift;
        s.food.grace[slot / 4] = (s.food.grace[slot / 4] & ~mask) | (value << shift);
    }

    fn ageFoodGrace(s: *Snek) void {
        for (0..MAX_FOOD) |slot| {
            const remaining = s.foodGrace(slot);
            if (remaining > 0) s.setFoodGrace(slot, remaining - 1);
        }
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
pub fn wrap(x: f32) f32 {
    if (x < 0) return x + ARENA;
    if (x >= ARENA) return x - ARENA;
    return x;
}

pub fn quantizeCoordinate(x: f32) u16 {
    const rounded = @floor(wrap(x) + 0.5);
    return @intFromFloat(if (rounded >= ARENA) 0 else rounded);
}

fn snakeCollisionCoreRadius(snake: *const Snake) f32 {
    return HIT_R * 0.5 + (Snek.snakeRadius(snake.mass) - 10.0) * 0.5;
}

fn snakeContactRadius(attacker: *const Snake, owner: *const Snake) f32 {
    return snakeCollisionCoreRadius(attacker) + snakeCollisionCoreRadius(owner);
}

fn hashBucket(x: f32, y: f32) usize {
    const cells: usize = @intFromFloat(ARENA / HASH_CELL);
    const cx: usize = @intFromFloat(@floor(x / HASH_CELL));
    const cy: usize = @intFromFloat(@floor(y / HASH_CELL));
    return cy * cells + cx;
}

fn wrappedDelta(a: f32, b: f32) f32 {
    var delta = a - b;
    if (delta > ARENA / 2) delta -= ARENA;
    if (delta < -ARENA / 2) delta += ARENA;
    return delta;
}

/// Minimum toroidal squared distance between two heads during one fixed step.
/// Each head moves at most 12 px, far below half the world, so unwrapping both
/// short movements around their start points yields the exact relative line.
fn sweptHeadDistance2(a0: Sample, a1: Sample, b0: Sample, b1: Sample) f32 {
    const rx = wrappedDelta(a0.x, b0.x);
    const ry = wrappedDelta(a0.y, b0.y);
    const vx = wrappedDelta(a1.x, a0.x) - wrappedDelta(b1.x, b0.x);
    const vy = wrappedDelta(a1.y, a0.y) - wrappedDelta(b1.y, b0.y);
    const speed2 = vx * vx + vy * vy;
    if (speed2 == 0) return rx * rx + ry * ry;
    const t = std.math.clamp(-(rx * vx + ry * vy) / speed2, 0.0, 1.0);
    const dx = rx + vx * t;
    const dy = ry + vy * t;
    return dx * dx + dy * dy;
}

/// Minimum toroidal squared distance from a moving head to one fixed body or
/// obstacle center during the same fixed step.
fn sweptPointDistance2(head0: Sample, head1: Sample, point: Sample) f32 {
    const rx = wrappedDelta(head0.x, point.x);
    const ry = wrappedDelta(head0.y, point.y);
    const vx = wrappedDelta(head1.x, head0.x);
    const vy = wrappedDelta(head1.y, head0.y);
    const speed2 = vx * vx + vy * vy;
    if (speed2 == 0) return rx * rx + ry * ry;
    const t = std.math.clamp(-(rx * vx + ry * vy) / speed2, 0.0, 1.0);
    const dx = rx + vx * t;
    const dy = ry + vy * t;
    return dx * dx + dy * dy;
}

fn normalizeAngle(angle: f32) f32 {
    const tau = 2.0 * std.math.pi;
    var result = @mod(angle, tau);
    if (result < 0) result += tau;
    return result;
}

fn angleDelta(from: f32, to: f32) f32 {
    var delta = normalizeAngle(to) - normalizeAngle(from);
    if (delta > std.math.pi) delta -= 2.0 * std.math.pi;
    if (delta < -std.math.pi) delta += 2.0 * std.math.pi;
    return delta;
}

fn seedTestSnake(snake: *Snake, mass: u16, x: f32, y: f32) void {
    seedTestSnakeFacing(snake, mass, x, y, 0);
}

fn seedTestSnakeFacing(snake: *Snake, mass: u16, x: f32, y: f32, angle: f32) void {
    snake.* = .{};
    snake.alive = true;
    snake.mass = mass;
    snake.rb_len = mass;
    snake.head_x = x;
    snake.head_y = y;
    snake.angle = angle;
    snake.target_angle = angle;
    for (0..mass) |back| {
        const distance: f32 = @floatFromInt(back);
        snake.body[ringIndex(0, back)] = .{
            .x = wrap(x - @cos(angle) * distance * SPACING),
            .y = wrap(y - @sin(angle) * distance * SPACING),
        };
    }
}

test "wire coordinate quantization uses the nearest toroidal pixel" {
    try std.testing.expectEqual(@as(u16, 11), quantizeCoordinate(10.75));
    try std.testing.expectEqual(@as(u16, 10), quantizeCoordinate(10.25));
    try std.testing.expectEqual(@as(u16, 0), quantizeCoordinate(ARENA - 0.25));
    try std.testing.expectEqual(@as(u16, 8191), quantizeCoordinate(ARENA - 0.75));
}

test "toroidal deltas are symmetric at half-world and exact across the seam" {
    try std.testing.expectEqual(@as(f32, -4096), wrappedDelta(0, ARENA / 2));
    try std.testing.expectEqual(@as(f32, 4096), wrappedDelta(ARENA / 2, 0));
    try std.testing.expectEqual(@as(f32, 3), wrappedDelta(1, ARENA - 2));
    try std.testing.expectEqual(@as(f32, -3), wrappedDelta(ARENA - 2, 1));
}

test "snake contact is the exact sum of both collision core radii" {
    var first: Snake = .{};
    var second: Snake = .{};
    for ([_]u16{ INITIAL_MASS, 31, 140, MAX_MASS }) |first_mass| {
        for ([_]u16{ INITIAL_MASS, 80, 633, MAX_MASS }) |second_mass| {
            first.mass = first_mass;
            second.mass = second_mass;
            try std.testing.expectEqual(
                snakeCollisionCoreRadius(&first) + snakeCollisionCoreRadius(&second),
                snakeContactRadius(&first, &second),
            );
        }
    }
}

test "squared-distance collision boundaries include contact and exclude outside" {
    var prng = std.Random.DefaultPrng.init(0xB0A0D);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;
    seedTestSnake(&s.snakes[0], INITIAL_MASS, 0, 100);
    seedTestSnake(&s.snakes[1], INITIAL_MASS, HIT_R, 100);
    s.snakes[0].rb_len = 1;
    s.snakes[1].rb_len = 1;
    var previous: [MAX_SNAKES]Sample = undefined;
    previous[0] = .{ .x = s.snakes[0].head_x, .y = s.snakes[0].head_y };
    previous[1] = .{ .x = s.snakes[1].head_x, .y = s.snakes[1].head_y };
    s.rebuildHash();
    try std.testing.expect(s.headCollision(0, &s.snakes[0], &previous) != null);

    const outside = std.math.nextAfter(f32, HIT_R, std.math.inf(f32));
    s.snakes[1].head_x = outside;
    s.snakes[1].body[s.snakes[1].rb_head].x = outside;
    previous[1].x = outside;
    s.rebuildHash();
    try std.testing.expectEqual(@as(?CollisionHit, null), s.headCollision(0, &s.snakes[0], &previous));
}

test "three-cell spatial search includes the maximum contact radius" {
    var prng = std.Random.DefaultPrng.init(0xCE11);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;
    seedTestSnake(&s.snakes[0], MAX_MASS, 31.75, 100);
    seedTestSnake(&s.snakes[1], MAX_MASS, 4000, 4000);
    s.snakes[0].rb_len = 1;
    s.snakes[1].rb_len = 3;
    const maximum_contact = snakeContactRadius(&s.snakes[0], &s.snakes[1]);
    try std.testing.expectEqual(@as(f32, 75), maximum_contact);
    s.snakes[1].body[ringIndex(s.snakes[1].rb_head, 2)] = .{ .x = 31.75 + maximum_contact, .y = 100 };
    var previous: [MAX_SNAKES]Sample = undefined;
    previous[0] = .{ .x = s.snakes[0].head_x, .y = s.snakes[0].head_y };
    previous[1] = .{ .x = s.snakes[1].head_x, .y = s.snakes[1].head_y };
    s.rebuildHash();
    try std.testing.expect(s.headCollision(0, &s.snakes[0], &previous) != null);

    s.snakes[1].body[ringIndex(s.snakes[1].rb_head, 2)].x += 0.01;
    s.rebuildHash();
    try std.testing.expectEqual(@as(?CollisionHit, null), s.headCollision(0, &s.snakes[0], &previous));
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
        try std.testing.expect(first.food.mass[i] >= FOOD_KIND_PELLET and first.food.mass[i] <= FOOD_KIND_PARTY_LAST);
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

test "party landmarks avoid clusters and toroidal dead zones" {
    var minimum_pair2 = std.math.inf(f32);
    for (OBSTACLES, 0..) |first, first_index| {
        for (OBSTACLES[first_index + 1 ..]) |second| {
            const dx = wrappedDelta(first.x, second.x);
            const dy = wrappedDelta(first.y, second.y);
            minimum_pair2 = @min(minimum_pair2, dx * dx + dy * dy);
        }
    }
    // The closest pair is currently 903.5 px apart: hazards read as isolated
    // decisions, never an accidental unavoidable cluster.
    try std.testing.expect(minimum_pair2 >= 900.0 * 900.0);

    var maximum_nearest2: f32 = 0;
    var y: f32 = 0;
    while (y < ARENA) : (y += 128) {
        var x: f32 = 0;
        while (x < ARENA) : (x += 128) {
            var nearest2 = std.math.inf(f32);
            for (OBSTACLES) |obstacle| {
                const dx = wrappedDelta(x, obstacle.x);
                const dy = wrappedDelta(y, obstacle.y);
                nearest2 = @min(nearest2, dx * dx + dy * dy);
            }
            maximum_nearest2 = @max(maximum_nearest2, nearest2);
        }
    }
    // Coarse coverage includes the wrap seam; the measured maximum is under
    // 1,470 px, well below one fifth of the arena width.
    try std.testing.expect(maximum_nearest2 <= 1500.0 * 1500.0);
}

test "five through fifty five spawns find full clearances without fallback" {
    for ([_]usize{ 5, 15, 30, 55 }) |population| {
        var prng = std.Random.DefaultPrng.init(0x5A11CE + population);
        var rng = prng.random();
        const s = try Snek.init(std.testing.allocator, FOOD_TARGET, MAX_FOOD, &rng);
        defer Snek.deinit(s, std.testing.allocator);
        for (0..population) |slot| {
            const snake = s.spawnSnake(slot, &rng);
            try std.testing.expectEqual(SPAWN_SHIELD_TICKS, snake.shield_ticks);
        }
    }
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
    try std.testing.expectEqual(@as(u8, 0), s.foodGrace(slot));
}

test "food freelist never duplicates or loses slots through sustained churn" {
    var prng = std.Random.DefaultPrng.init(0xF8EE1157);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 7, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    var live = [_]bool{false} ** MAX_FOOD;
    @memset(live[0..s.food_target], true);
    var expected_count = s.food.count;

    for (0..2048) |step| {
        if ((step % 3 != 0 and expected_count < s.max_food) or expected_count == 0) {
            const slot = s.foodAcquire();
            try std.testing.expect(!live[slot]);
            live[slot] = true;
            expected_count += 1;
        } else {
            var slot = (step * PARTY_SLOT_STRIDE) % MAX_FOOD;
            while (!live[slot]) slot = (slot + 1) % MAX_FOOD;
            s.foodRelease(slot);
            live[slot] = false;
            expected_count -= 1;
        }
        try std.testing.expectEqual(expected_count, s.food.count);
    }

    var observed_count: usize = 0;
    for (live) |is_live| observed_count += @intFromBool(is_live);
    try std.testing.expectEqual(expected_count, observed_count);
}

test "simultaneous food pickup goes to the closest snake, including across the seam" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    // Both snakes can reach this feast, but slot one is substantially closer.
    s.food.x[0] = 4000;
    s.food.y[0] = 4000;
    s.food.mass[0] = 10;
    seedTestSnake(&s.snakes[0], INITIAL_MASS, 3975, 4000);
    seedTestSnake(&s.snakes[1], INITIAL_MASS, 4010, 4000);
    _ = s.tick(0, &rng);
    try std.testing.expectEqual(@as(u16, 0), s.snakes[0].growth_pending);
    try std.testing.expectEqual(Snek.foodGrowth(10), s.snakes[1].growth_pending);

    // Slot identity remains irrelevant at the toroidal boundary too.
    s.food.x[0] = @intFromFloat(ARENA - 2);
    s.food.y[0] = 2000;
    s.food.mass[0] = 4;
    seedTestSnakeFacing(&s.snakes[0], INITIAL_MASS, 18, 2000, std.math.pi);
    seedTestSnakeFacing(&s.snakes[1], INITIAL_MASS, 3, 2000, 0);
    _ = s.tick(0, &rng);
    try std.testing.expectEqual(@as(u16, 0), s.snakes[0].growth_pending);
    try std.testing.expectEqual(Snek.foodGrowth(4), s.snakes[1].growth_pending);
}

test "boosted glancing path cannot tunnel past collectible food" {
    var prng = std.Random.DefaultPrng.init(0xF00D7);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;
    s.food.x[0] = 4006;
    s.food.y[0] = 4016;
    s.food.mass[0] = FOOD_KIND_PELLET;
    seedTestSnakeFacing(&s.snakes[0], INITIAL_MASS, 4000, 4000, 0);
    s.snakes[0].boosting = true;

    _ = s.tick(1.0 / 30.0, &rng);
    try std.testing.expectEqual(Snek.foodGrowth(FOOD_KIND_PELLET), s.snakes[0].growth_pending);
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
    try std.testing.expectEqual(SPAWN_SHIELD_TICKS, snake.shield_ticks);
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

test "corpse rewards make kills valuable while staying absolutely capped" {
    var prng = std.Random.DefaultPrng.init(0xB0A7E);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    var scratch: [DEATH_DROP_CAP]u16 = undefined;

    const masses = [_]u16{ 30, 300, 633, MAX_MASS };
    const expected_drops = [_]usize{ 15, 150, 150, 150 };
    const expected_growth = [_]usize{ 30, 300, 300, 300 };
    for (masses, expected_drops, expected_growth) |mass, drops, growth| {
        seedTestSnake(&s.snakes[0], mass, 4000, 4000);
        const count = s.killSnake(0, &scratch);
        try std.testing.expectEqual(drops, count);
        try std.testing.expectEqual(growth, count * Snek.foodGrowth(FOOD_KIND_CORPSE));
    }
    // Recovery is 100% at mass 300, 47.4% at the 128px piñata milestone,
    // and 30% at the cap. Fixed drop slots keep all three memory-bounded.
    try std.testing.expectEqual(@as(usize, 300), DEATH_DROP_CAP * Snek.foodGrowth(FOOD_KIND_CORPSE));
}

test "turn rate follows the design table" {
    try std.testing.expectApproxEqAbs(TURN_RATE_BASE, Snek.turnRate(1), 0.001);
    try std.testing.expectApproxEqAbs(TURN_RATE_BASE, Snek.turnRate(30), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.067), Snek.turnRate(100), 0.01);
    try std.testing.expectApproxEqAbs(TURN_RATE_MIN, Snek.turnRate(340), 0.001);
    try std.testing.expectApproxEqAbs(TURN_RATE_MIN, Snek.turnRate(1000), 0.001);
}

test "snake radius grows with mass and remains capped" {
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), Snek.snakeRadius(INITIAL_MASS), 0.001);
    try std.testing.expect(Snek.snakeRadius(200) > Snek.snakeRadius(INITIAL_MASS));
    try std.testing.expect(Snek.snakeRadius(700) > Snek.snakeRadius(200));
    try std.testing.expectApproxEqAbs(@as(f32, 72.0), Snek.snakeRadius(MAX_MASS), 0.01);
    try std.testing.expect(Snek.snakeRadius(633) * 2.0 >= 128.0);
}

test "IO growth steering and obstacle milestones stay monotonic and playable" {
    var previous_radius = Snek.snakeRadius(INITIAL_MASS);
    var previous_turn = Snek.turnRate(INITIAL_MASS);
    var mass: u16 = INITIAL_MASS + 1;
    while (mass <= MAX_MASS) : (mass += 1) {
        const radius = Snek.snakeRadius(mass);
        const turn = Snek.turnRate(mass);
        try std.testing.expect(radius >= previous_radius and radius <= 72.0);
        try std.testing.expect(turn <= previous_turn and turn >= TURN_RATE_MIN);
        previous_radius = radius;
        previous_turn = turn;
        if (mass == MAX_MASS) break;
    }

    // Width crosses each obstacle's full illustrated diameter, never merely
    // its smaller lethal core. These exact one-mass boundaries make the
    // progression legible instead of intermittently rounding either way.
    try std.testing.expect(Snek.snakeRadius(632) * 2.0 < CRATE_EAT_RADIUS * 2.0);
    try std.testing.expect(Snek.snakeRadius(633) * 2.0 >= CRATE_EAT_RADIUS * 2.0);
    try std.testing.expect(Snek.snakeRadius(773) * 2.0 < MINE_EAT_RADIUS * 2.0);
    try std.testing.expect(Snek.snakeRadius(774) * 2.0 >= MINE_EAT_RADIUS * 2.0);

    // Even a capped snake can complete a normal-speed U-turn in under 1.75s;
    // the mass curve never creates an unsteerable late-game dead zone.
    try std.testing.expect(std.math.pi / Snek.turnRate(MAX_MASS) < 1.75);
}

test "short boost bursts pay their cumulative mass cost" {
    var prng = std.Random.DefaultPrng.init(0xB0057);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;
    s.food.x[0] = 1000;
    s.food.y[0] = 1000;
    seedTestSnake(&s.snakes[0], INITIAL_MASS, 4000, 4000);
    const snake = &s.snakes[0];

    // Seven one-tick taps, each separated by a release, remain unpaid but the
    // fraction persists. The eighth active tick pays exactly one mass.
    for (0..BOOST_BURN_TICKS - 1) |_| {
        snake.boosting = true;
        _ = s.tick(0, &rng);
        snake.boosting = false;
        _ = s.tick(0, &rng);
    }
    try std.testing.expectEqual(INITIAL_MASS, snake.mass);
    try std.testing.expectEqual(BOOST_BURN_TICKS - 1, snake.mass_frac);
    snake.boosting = true;
    _ = s.tick(0, &rng);
    try std.testing.expectEqual(INITIAL_MASS - 1, snake.mass);
    try std.testing.expectEqual(@as(u16, 0), snake.mass_frac);
}

test "maximum mass cannot bank queued growth as future boost fuel" {
    var prng = std.Random.DefaultPrng.init(0xCA9);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;
    s.food.x[0] = 1000;
    s.food.y[0] = 1000;
    seedTestSnake(&s.snakes[0], MAX_MASS, 4000, 4000);
    const snake = &s.snakes[0];
    snake.growth_pending = 600;

    _ = s.tick(0, &rng);
    try std.testing.expectEqual(MAX_MASS, snake.mass);
    try std.testing.expectEqual(@as(u16, 0), snake.growth_pending);

    snake.boosting = true;
    for (0..BOOST_BURN_TICKS) |_| _ = s.tick(0, &rng);
    try std.testing.expectEqual(MAX_MASS - 1, snake.mass);
}

test "steering takes the shortest path across the angle seam" {
    var prng = std.Random.DefaultPrng.init(17);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const snake = &s.snakes[0];
    seedTestSnake(snake, INITIAL_MASS, 4000, 4000);
    snake.angle = 2.0 * std.math.pi - 0.05;
    snake.target_angle = 0.05;

    _ = s.tick(1.0 / 30.0, &rng);
    try std.testing.expect(snake.alive);
    try std.testing.expect(snake.angle < 0.2);
}

test "obstacles kill small snakes and are eaten at their mass threshold" {
    var prng = std.Random.DefaultPrng.init(18);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const obstacle = OBSTACLES[0];

    const snake = &s.snakes[0];
    seedTestSnake(snake, 632, obstacle.x, obstacle.y);
    const killed = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 1), killed.death_count);
    try std.testing.expect(!snake.alive);
    try std.testing.expect(s.obstacle_alive_mask & 1 != 0);

    var apples_before: usize = 0;
    var donuts_before: usize = 0;
    for (s.food.mass) |kind| {
        if (kind == 4) apples_before += 1;
        if (kind == 6) donuts_before += 1;
    }
    seedTestSnake(snake, 633, obstacle.x, obstacle.y);
    const survived = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 0), survived.death_count);
    try std.testing.expect(snake.alive);
    // Nearby corpse crumbs from the first collision may be collected in the
    // same party tick; the obstacle's reward must always be included.
    try std.testing.expect(snake.growth_pending >= Snek.obstacleReward(obstacle.kind));
    try std.testing.expect(s.obstacle_alive_mask & 1 == 0);
    try std.testing.expectEqual(OBSTACLE_RESPAWN_TICKS, s.obstacle_respawn_ticks[0]);
    var apple_count: usize = 0;
    var donut_count: usize = 0;
    for (s.food.mass) |kind| {
        if (kind == 4) apple_count += 1;
        if (kind == 6) donut_count += 1;
    }
    try std.testing.expectEqual(apples_before + 20, apple_count);
    try std.testing.expectEqual(donuts_before + 4, donut_count);
}

test "closest eligible snake wins a simultaneously contested obstacle" {
    var prng = std.Random.DefaultPrng.init(185);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const obstacle = OBSTACLES[0];

    // Both heads overlap the same crate without overlapping each other. Slot
    // zero is farther away, so array order must not award it the pickup.
    seedTestSnakeFacing(&s.snakes[0], 633, obstacle.x - 80, obstacle.y, 0);
    seedTestSnakeFacing(&s.snakes[1], 633, obstacle.x + 60, obstacle.y, std.math.pi);
    const result = s.tick(0, &rng);

    try std.testing.expectEqual(@as(usize, 0), result.death_count);
    try std.testing.expectEqual(@as(u16, 0), s.snakes[0].growth_pending);
    try std.testing.expect(s.snakes[1].growth_pending >= Snek.obstacleReward(obstacle.kind));
    try std.testing.expect(s.obstacle_alive_mask & 1 == 0);
}

test "contested obstacle ignores an ineligible closer snake" {
    var prng = std.Random.DefaultPrng.init(186);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const obstacle = OBSTACLES[0];

    seedTestSnakeFacing(&s.snakes[0], INITIAL_MASS, obstacle.x, obstacle.y, std.math.pi);
    seedTestSnakeFacing(&s.snakes[1], 633, obstacle.x - 80, obstacle.y, 0);
    const result = s.tick(0, &rng);

    try std.testing.expectEqual(@as(usize, 1), result.death_count);
    try std.testing.expectEqual(@as(u8, 0), result.deaths[0].slot);
    try std.testing.expect(s.snakes[1].alive);
    try std.testing.expect(s.snakes[1].growth_pending >= Snek.obstacleReward(obstacle.kind));
    try std.testing.expect(s.obstacle_alive_mask & 1 == 0);
}

test "crate feed survives both publication substeps and respects a full pool" {
    var prng = std.Random.DefaultPrng.init(183);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const crate = OBSTACLES[0];
    s.food.x[0] = 4000;
    s.food.y[0] = 4000;
    const snake = &s.snakes[0];
    seedTestSnake(snake, 633, crate.x, crate.y);

    _ = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 1 + CRATE_BURST_COUNT), s.food.count);
    var protected_count: usize = 0;
    for (0..MAX_FOOD) |slot| {
        if (s.food.mass[slot] != 0 and s.foodGrace(slot) == 2) protected_count += 1;
    }
    try std.testing.expectEqual(CRATE_BURST_COUNT, protected_count);
    _ = s.tick(0, &rng);
    _ = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 1 + CRATE_BURST_COUNT), s.food.count);
    for (0..MAX_FOOD) |slot| try std.testing.expectEqual(@as(u8, 0), s.foodGrace(slot));

    var full_prng = std.Random.DefaultPrng.init(184);
    var full_rng = full_prng.random();
    const full = try Snek.init(std.testing.allocator, 1, 1, &full_rng);
    defer Snek.deinit(full, std.testing.allocator);
    full.food.x[0] = 4000;
    full.food.y[0] = 4000;
    seedTestSnake(&full.snakes[0], 633, crate.x, crate.y);
    _ = full.tick(0, &full_rng);
    try std.testing.expectEqual(@as(usize, 1), full.food.count);
}

test "crate grace never freezes unrelated food elsewhere in the arena" {
    var prng = std.Random.DefaultPrng.init(0xC8A7E);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const crate = OBSTACLES[0];
    s.food.x[0] = 4000;
    s.food.y[0] = 4000;
    s.food.mass[0] = 10;
    seedTestSnake(&s.snakes[0], 633, crate.x, crate.y);
    seedTestSnake(&s.snakes[1], INITIAL_MASS, 5000, 4000);

    _ = s.tick(0, &rng);
    try std.testing.expectEqual(@as(u8, 10), s.food.mass[0]);
    seedTestSnake(&s.snakes[1], INITIAL_MASS, 4000, 4000);
    _ = s.tick(0, &rng);
    try std.testing.expectEqual(@as(u8, 0), s.food.mass[0]);
    try std.testing.expectEqual(Snek.foodGrowth(10), s.snakes[1].growth_pending);
}

test "corpse food survives a publication before becoming collectible" {
    var prng = std.Random.DefaultPrng.init(0xC0A55E);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;
    s.food.x[0] = 1000;
    s.food.y[0] = 1000;
    seedTestSnake(&s.snakes[0], INITIAL_MASS, 4000, 4000);
    seedTestSnake(&s.snakes[1], 140, 6000, 6000);
    s.snakes[1].body[ringIndex(s.snakes[1].rb_head, 20)] = .{ .x = 4000, .y = 4000 };

    _ = s.tick(0, &rng);
    try std.testing.expect(!s.snakes[0].alive);
    var corpse_slot: ?usize = null;
    for (0..MAX_FOOD) |slot| {
        if (s.food.mass[slot] == FOOD_KIND_CORPSE) {
            corpse_slot = slot;
            break;
        }
    }
    const drop = corpse_slot orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 1), s.foodGrace(drop));

    seedTestSnake(&s.snakes[1], INITIAL_MASS, @floatFromInt(s.food.x[drop]), @floatFromInt(s.food.y[drop]));
    _ = s.tick(0, &rng);
    try std.testing.expectEqual(FOOD_KIND_CORPSE, s.food.mass[drop]);
    try std.testing.expectEqual(@as(u8, 0), s.foodGrace(drop));
    _ = s.tick(0, &rng);
    try std.testing.expectEqual(@as(u8, 0), s.food.mass[drop]);
}

test "obstacle hitbox stays inside its telegraphed art" {
    var prng = std.Random.DefaultPrng.init(180);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const obstacle = OBSTACLES[0];
    const snake = &s.snakes[0];
    const hit_distance = obstacle.radius * OBSTACLE_HITBOX_SCALE + Snek.snakeRadius(INITIAL_MASS);

    seedTestSnake(snake, INITIAL_MASS, obstacle.x + hit_distance + 0.1, obstacle.y);
    try std.testing.expectEqual(@as(?usize, null), s.obstacleCollision(snake, .{ .x = snake.head_x, .y = snake.head_y }));
    seedTestSnake(snake, INITIAL_MASS, obstacle.x + hit_distance - 0.1, obstacle.y);
    try std.testing.expectEqual(@as(?usize, 0), s.obstacleCollision(snake, .{ .x = snake.head_x, .y = snake.head_y }));
}

test "boosted glancing path cannot tunnel through an obstacle core" {
    var prng = std.Random.DefaultPrng.init(0x0B57AC1E);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const obstacle = OBSTACLES[0];
    const hit_r = Snek.snakeRadius(INITIAL_MASS) + obstacle.radius * OBSTACLE_HITBOX_SCALE;

    // Both endpoints sit outside the circular core, but the 12 px boosted
    // segment passes through it near the midpoint.
    seedTestSnakeFacing(&s.snakes[0], INITIAL_MASS, obstacle.x - 6, obstacle.y + hit_r - 0.1, 0);
    s.snakes[0].boosting = true;
    const result = s.tick(1.0 / 30.0, &rng);
    try std.testing.expectEqual(@as(usize, 1), result.death_count);
    try std.testing.expect(!s.snakes[0].alive);
}

test "IO snakes never die on their own body even at maximum width" {
    var prng = std.Random.DefaultPrng.init(181);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    // Keep all obstacles inactive so this isolates body collision geometry.
    s.obstacle_alive_mask = 0;
    const snake = &s.snakes[0];
    seedTestSnake(snake, MAX_MASS, 4000, 4000);
    // Force an old body segment directly under the head. In snake.io-style
    // play this is a legal tight curl, not an unexplained environment death.
    snake.body[ringIndex(snake.rb_head, 100)] = .{ .x = snake.head_x, .y = snake.head_y };
    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 0), result.death_count);
    try std.testing.expect(snake.alive);
}

test "IO snakes still die on an opponent body" {
    var prng = std.Random.DefaultPrng.init(182);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;
    const attacker = &s.snakes[0];
    const opponent = &s.snakes[1];
    seedTestSnake(attacker, INITIAL_MASS, 4000, 4000);
    seedTestSnake(opponent, 140, 6000, 6000);
    opponent.body[ringIndex(opponent.rb_head, 100)] = .{ .x = attacker.head_x, .y = attacker.head_y };

    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 1), result.death_count);
    try std.testing.expectEqual(@as(u8, 0), result.deaths[0].slot);
    try std.testing.expectEqual(@as(?u8, 1), result.deaths[0].killer_slot);
    try std.testing.expect(!attacker.alive);
    try std.testing.expect(opponent.alive);
}

test "retreating larger IO snake wins a simultaneous head clash regardless of slot order" {
    const Case = struct { large_slot: usize, small_slot: usize };
    for ([_]Case{
        .{ .large_slot = 0, .small_slot = 1 },
        .{ .large_slot = 1, .small_slot = 0 },
    }) |case| {
        var prng = std.Random.DefaultPrng.init(0xC0111DE + case.large_slot);
        var rng = prng.random();
        const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
        defer Snek.deinit(s, std.testing.allocator);
        s.obstacle_alive_mask = 0;

        // The larger snake is already retreating to the left. The smaller
        // snake boosts after it and closes the final six pixels this tick.
        // Both heads are moved before collision classification, so this is a
        // simultaneous head clash rather than the retreating snake attacking
        // the newcomer's freshly inserted neck sample.
        const large = &s.snakes[case.large_slot];
        const small = &s.snakes[case.small_slot];
        seedTestSnakeFacing(large, 140, 4000, 4000, std.math.pi);
        seedTestSnakeFacing(small, INITIAL_MASS, 4030, 4000, std.math.pi);
        small.boosting = true;

        const result = s.tick(1.0 / 30.0, &rng);
        try std.testing.expectEqual(@as(usize, 1), result.death_count);
        try std.testing.expectEqual(@as(u8, @intCast(case.small_slot)), result.deaths[0].slot);
        try std.testing.expect(large.alive);
        try std.testing.expect(!small.alive);
    }
}

test "larger IO snake survives a true head clash even when the loser neck overlaps" {
    const Case = struct { large_slot: usize, small_slot: usize };
    for ([_]Case{
        .{ .large_slot = 0, .small_slot = 1 },
        .{ .large_slot = 1, .small_slot = 0 },
    }) |case| {
        var prng = std.Random.DefaultPrng.init(0xC0111DF + case.large_slot);
        var rng = prng.random();
        const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
        defer Snek.deinit(s, std.testing.allocator);
        s.obstacle_alive_mask = 0;

        // Both snakes face the same direction with touching heads. The small
        // snake's first neck sample is necessarily also inside the larger
        // head's contact radius. Pairwise head-clash precedence must keep that
        // fresh neck sample from turning the legitimate winner into a trade.
        seedTestSnakeFacing(&s.snakes[case.large_slot], 140, 4000, 4000, 0);
        seedTestSnakeFacing(&s.snakes[case.small_slot], INITIAL_MASS, 4012, 4000, 0);

        const result = s.tick(0, &rng);
        try std.testing.expectEqual(@as(usize, 1), result.death_count);
        try std.testing.expectEqual(@as(u8, @intCast(case.small_slot)), result.deaths[0].slot);
        try std.testing.expect(s.snakes[case.large_slot].alive);
        try std.testing.expect(!s.snakes[case.small_slot].alive);
    }
}

test "boosted diagonal head paths cannot tunnel and turn a larger win into a trade" {
    var prng = std.Random.DefaultPrng.init(0x7A11);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    // The endpoints are 14.42 px apart, just outside the 14.10 px contact
    // radius, but the two boosted heads cross within eight pixels mid-tick.
    // Endpoint-only collision misses the true head clash and misclassifies
    // each previous head sample as body, incorrectly killing both snakes.
    seedTestSnakeFacing(&s.snakes[0], 31, 4000, 4000, 0);
    seedTestSnakeFacing(&s.snakes[1], INITIAL_MASS, 4012, 4008, std.math.pi);
    s.snakes[0].boosting = true;
    s.snakes[1].boosting = true;

    const result = s.tick(1.0 / 30.0, &rng);
    try std.testing.expectEqual(@as(usize, 1), result.death_count);
    try std.testing.expect(s.snakes[0].alive);
    try std.testing.expect(!s.snakes[1].alive);
}

test "boosted glancing path cannot tunnel through an opponent body" {
    var prng = std.Random.DefaultPrng.init(0xB0D7);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    seedTestSnakeFacing(&s.snakes[0], INITIAL_MASS, 4000, 4000, 0);
    seedTestSnake(&s.snakes[1], INITIAL_MASS, 6000, 6000);
    s.snakes[0].boosting = true;
    s.snakes[1].rb_len = 4;
    s.snakes[1].body[ringIndex(s.snakes[1].rb_head, 2)] = .{ .x = 4006, .y = 4012 };

    const result = s.tick(1.0 / 30.0, &rng);
    try std.testing.expectEqual(@as(usize, 1), result.death_count);
    try std.testing.expectEqual(@as(u8, 0), result.deaths[0].slot);
    try std.testing.expectEqual(@as(?u8, 1), result.deaths[0].killer_slot);
}

test "a moving opponent's previous head is not a stationary ghost body" {
    var prng = std.Random.DefaultPrng.init(0x6A057);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    // The larger snake moves right while the smaller snake turns upward.
    // Their moving heads remain 24.64 px apart, just outside their 24.54 px
    // contact radius. The larger head does pass within 23.9 px of the
    // smaller snake's *old* head coordinate; back 1 must not freeze that old
    // coordinate for the whole tick and manufacture a body collision.
    seedTestSnakeFacing(&s.snakes[0], 140, 4000, 4000, 0);
    seedTestSnakeFacing(&s.snakes[1], INITIAL_MASS, 4029.9, 4000, std.math.pi / 2.0);

    const result = s.tick(1.0 / 30.0, &rng);
    try std.testing.expectEqual(@as(usize, 0), result.death_count);
    try std.testing.expect(s.snakes[0].alive);
    try std.testing.expect(s.snakes[1].alive);
}

test "freshly spawned snakes stay neutral until their materialized tail is replaced" {
    var prng = std.Random.DefaultPrng.init(0x5A17E);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    seedTestSnake(&s.snakes[0], INITIAL_MASS, 4000, 4000);
    seedTestSnake(&s.snakes[1], INITIAL_MASS, 6000, 6000);
    s.snakes[1].shield_ticks = SPAWN_SHIELD_TICKS;
    s.snakes[1].body[ringIndex(s.snakes[1].rb_head, 20)] = .{ .x = 4000, .y = 4000 };

    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 0), result.death_count);
    try std.testing.expect(s.snakes[0].alive);
    try std.testing.expect(s.snakes[1].alive);
}

test "head and body contacts resolve correctly across the world seam" {
    var head_prng = std.Random.DefaultPrng.init(0x5EA0);
    var head_rng = head_prng.random();
    const head_sim = try Snek.init(std.testing.allocator, 1, 64, &head_rng);
    defer Snek.deinit(head_sim, std.testing.allocator);
    head_sim.obstacle_alive_mask = 0;
    seedTestSnakeFacing(&head_sim.snakes[0], 140, 4, 4000, std.math.pi);
    seedTestSnakeFacing(&head_sim.snakes[1], INITIAL_MASS, ARENA - 2, 4000, std.math.pi);

    const head_result = head_sim.tick(0, &head_rng);
    try std.testing.expectEqual(@as(usize, 1), head_result.death_count);
    try std.testing.expect(head_sim.snakes[0].alive);
    try std.testing.expect(!head_sim.snakes[1].alive);

    var body_prng = std.Random.DefaultPrng.init(0x5EA1);
    var body_rng = body_prng.random();
    const body_sim = try Snek.init(std.testing.allocator, 1, 64, &body_rng);
    defer Snek.deinit(body_sim, std.testing.allocator);
    body_sim.obstacle_alive_mask = 0;
    seedTestSnake(&body_sim.snakes[0], INITIAL_MASS, 2, 4000);
    seedTestSnake(&body_sim.snakes[1], 140, 4000, 6000);
    body_sim.snakes[1].body[ringIndex(body_sim.snakes[1].rb_head, 20)] = .{ .x = ARENA - 2, .y = 4000 };

    const body_result = body_sim.tick(0, &body_rng);
    try std.testing.expectEqual(@as(usize, 1), body_result.death_count);
    try std.testing.expectEqual(@as(?u8, 1), body_result.deaths[0].killer_slot);
}

test "largest snake wins a three-way simultaneous head contact" {
    var prng = std.Random.DefaultPrng.init(0x3EAD);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    seedTestSnake(&s.snakes[0], INITIAL_MASS, 3990, 4000);
    seedTestSnake(&s.snakes[1], 80, 4010, 4000);
    seedTestSnake(&s.snakes[2], 200, 4000, 4000);

    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 2), result.death_count);
    try std.testing.expect(!s.snakes[0].alive);
    try std.testing.expect(!s.snakes[1].alive);
    try std.testing.expect(s.snakes[2].alive);
}

test "winning one head clash does not hide a different opponent body hit" {
    var prng = std.Random.DefaultPrng.init(0x0A11);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    seedTestSnakeFacing(&s.snakes[0], 140, 4000, 4000, 0);
    seedTestSnakeFacing(&s.snakes[1], INITIAL_MASS, 4012, 4000, 0);
    seedTestSnake(&s.snakes[2], 80, 6000, 6000);
    s.snakes[2].body[ringIndex(s.snakes[2].rb_head, 20)] = .{ .x = 4000, .y = 4000 };

    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 2), result.death_count);
    try std.testing.expectEqual(@as(u8, 0), result.deaths[0].slot);
    try std.testing.expectEqual(@as(?u8, 2), result.deaths[0].killer_slot);
    try std.testing.expectEqual(@as(u8, 1), result.deaths[1].slot);
    try std.testing.expectEqual(@as(?u8, 0), result.deaths[1].killer_slot);
    try std.testing.expect(s.snakes[2].alive);
}

test "nearest opponent body receives collision credit independent of hash insertion" {
    var prng = std.Random.DefaultPrng.init(0xB0D1);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    const attacker = &s.snakes[0];
    const nearest = &s.snakes[1];
    const farther = &s.snakes[2];
    seedTestSnake(attacker, INITIAL_MASS, 4000, 4000);
    seedTestSnake(nearest, 140, 6000, 6000);
    seedTestSnake(farther, 40, 7000, 7000);
    nearest.body[ringIndex(nearest.rb_head, 20)] = .{ .x = 4000, .y = 4000 };
    farther.body[ringIndex(farther.rb_head, 20)] = .{ .x = 4005, .y = 4000 };

    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 1), result.death_count);
    try std.testing.expectEqual(@as(?u8, 1), result.deaths[0].killer_slot);
}

test "equidistant body contacts use lower owner slot as the stable tie break" {
    var prng = std.Random.DefaultPrng.init(0x71E);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    seedTestSnake(&s.snakes[0], INITIAL_MASS, 4000, 4000);
    seedTestSnake(&s.snakes[1], 80, 6000, 6000);
    seedTestSnake(&s.snakes[2], 80, 7000, 7000);
    // The higher slot lives in the earlier hash cell and is encountered first.
    s.snakes[1].body[ringIndex(s.snakes[1].rb_head, 20)] = .{ .x = 4005, .y = 4000 };
    s.snakes[2].body[ringIndex(s.snakes[2].rb_head, 20)] = .{ .x = 3995, .y = 4000 };

    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 1), result.death_count);
    try std.testing.expectEqual(@as(?u8, 1), result.deaths[0].killer_slot);
}

test "equal-mass IO head clash still eliminates both snakes simultaneously" {
    var prng = std.Random.DefaultPrng.init(0xE0A1);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, 64, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    s.obstacle_alive_mask = 0;

    seedTestSnakeFacing(&s.snakes[0], INITIAL_MASS, 4000, 4000, 0);
    seedTestSnakeFacing(&s.snakes[1], INITIAL_MASS, 4012, 4000, std.math.pi);

    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 2), result.death_count);
    try std.testing.expectEqual(@as(u8, 0), result.deaths[0].slot);
    try std.testing.expectEqual(@as(u8, 1), result.deaths[1].slot);
    try std.testing.expect(!s.snakes[0].alive);
    try std.testing.expect(!s.snakes[1].alive);
}

test "obstacle respawn defers under a player and succeeds once clear" {
    var prng = std.Random.DefaultPrng.init(19);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const obstacle = OBSTACLES[0];
    const snake = &s.snakes[0];
    seedTestSnake(snake, INITIAL_MASS, obstacle.x, obstacle.y);
    s.obstacle_alive_mask &= ~@as(u32, 1);
    s.obstacle_respawn_ticks[0] = 1;

    _ = s.tick(0, &rng);
    try std.testing.expect(s.obstacle_alive_mask & 1 == 0);
    try std.testing.expectEqual(@as(u16, 1), s.obstacle_respawn_ticks[0]);
    snake.alive = false;
    _ = s.tick(0, &rng);
    try std.testing.expect(s.obstacle_alive_mask & 1 != 0);
    try std.testing.expectEqual(@as(u16, 0), s.obstacle_respawn_ticks[0]);
}

test "obstacle respawn waits for body samples, not only the head" {
    var prng = std.Random.DefaultPrng.init(0x0B57AC1E);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const obstacle_index = 7;
    const obstacle = OBSTACLES[obstacle_index];
    const bit = @as(u32, 1) << obstacle_index;
    seedTestSnake(&s.snakes[0], 140, 4000, 4000);
    s.snakes[0].body[ringIndex(s.snakes[0].rb_head, 20)] = .{ .x = obstacle.x + 20, .y = obstacle.y };
    s.obstacle_alive_mask &= ~bit;
    s.obstacle_respawn_ticks[obstacle_index] = 1;

    _ = s.tick(0, &rng);
    try std.testing.expect(s.obstacle_alive_mask & bit == 0);
    try std.testing.expectEqual(@as(u16, 1), s.obstacle_respawn_ticks[obstacle_index]);
    s.snakes[0].alive = false;
    _ = s.tick(0, &rng);
    try std.testing.expect(s.obstacle_alive_mask & bit != 0);
}

test "a final shield tick smashes hazards before expiring" {
    var prng = std.Random.DefaultPrng.init(20);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const obstacle = OBSTACLES[0];
    const snake = &s.snakes[0];
    seedTestSnake(snake, INITIAL_MASS, obstacle.x, obstacle.y);
    snake.shield_ticks = 1;

    const result = s.tick(0, &rng);
    try std.testing.expectEqual(@as(usize, 0), result.death_count);
    try std.testing.expect(snake.alive);
    try std.testing.expectEqual(@as(u16, 0), snake.shield_ticks);
    try std.testing.expect(s.obstacle_alive_mask & 1 == 0);
}

test "power-up pickups receive their full timer and turbo covers its last tick" {
    var prng = std.Random.DefaultPrng.init(21);
    var rng = prng.random();
    const s = try Snek.init(std.testing.allocator, 1, MAX_FOOD, &rng);
    defer Snek.deinit(s, std.testing.allocator);
    const snake = &s.snakes[0];
    seedTestSnake(snake, INITIAL_MASS, 4000, 4000);
    s.food.x[0] = 4000;
    s.food.y[0] = 4000;
    s.food.mass[0] = 8;

    _ = s.tick(0, &rng);
    try std.testing.expectEqual(LIGHTNING_TICKS, snake.turbo_ticks);
    const before = snake.head_x;
    snake.turbo_ticks = 1;
    _ = s.tick(1.0 / 30.0, &rng);
    try std.testing.expectApproxEqAbs(BASE_SPEED * BOOST_MULT / 30.0, wrappedDelta(snake.head_x, before), 0.01);
    try std.testing.expectEqual(@as(u16, 0), snake.turbo_ticks);
}
