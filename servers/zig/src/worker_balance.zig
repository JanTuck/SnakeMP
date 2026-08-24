//! Pure load-balancing policy for the lobby worker pool.
//!
//! The orchestration and locking stay in main.zig. Keeping the arithmetic here
//! makes the migration policy deterministic and unit-testable without threads.

const std = @import("std");

/// Keep enough of the 66.7 ms tick interval free for reactor contention,
/// scheduler noise, and an occasional expensive lobby tick.
pub const target_utilization_numerator: u64 = 3;
pub const target_utilization_denominator: u64 = 5;

/// A newly populated lobby has no measured history yet. This estimate closely
/// matches the normal 1-16 player tick range and is replaced by the measured
/// EWMA as soon as ticks complete.
const cold_base_ns: u64 = 15_000;
const cold_per_player_ns: u64 = 10_000;

pub const migration_cooldown_ms: i64 = 5_000;
pub const pool_shrink_cooldown_ms: i64 = 10_000;
pub const minimum_move_improvement_ns: u64 = 25_000;

pub fn targetTickBudgetNs(tick_ns: u64) u64 {
    return tick_ns / target_utilization_denominator * target_utilization_numerator;
}

pub fn estimatedLobbyCostNs(measured_ewma_ns: u64, players: usize) u64 {
    if (players == 0) return 0;
    const player_estimate = cold_base_ns +| @as(u64, @intCast(players)) *| cold_per_player_ns;
    return @max(measured_ewma_ns, player_estimate);
}

fn ceilDiv(numerator: u64, denominator: u64) u64 {
    if (numerator == 0) return 0;
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

/// Count is still a hard safety bound: even idle lobbies must have room to all
/// become active. Measured work may request additional workers before that
/// bound is reached.
pub fn desiredWorkerCount(lobby_count: usize, total_cost_ns: u64, max_lobbies_per_worker: usize, target_ns: u64) usize {
    const by_count = ceilDiv(@intCast(lobby_count), @intCast(@max(1, max_lobbies_per_worker)));
    const by_cost = ceilDiv(total_cost_ns, @max(1, target_ns));
    const wanted = @max(@as(u64, 1), @max(by_count, by_cost));
    return @intCast(@min(wanted, @as(u64, @intCast(@max(1, lobby_count)))));
}

fn absDiff(a: u64, b: u64) u64 {
    return if (a >= b) a - b else b - a;
}

/// Returns how much moving `candidate_ns` from the heavier worker to the
/// lighter worker would reduce their load gap. Zero rejects swaps/overshoots.
pub fn moveImprovementNs(heavy_ns: u64, light_ns: u64, candidate_ns: u64) u64 {
    if (heavy_ns <= light_ns or candidate_ns > heavy_ns) return 0;
    const before = heavy_ns - light_ns;
    const after = absDiff(heavy_ns - candidate_ns, light_ns +| candidate_ns);
    return before -| after;
}

pub fn worthwhileMove(heavy_ns: u64, light_ns: u64, candidate_ns: u64) bool {
    const before = heavy_ns -| light_ns;
    const improvement = moveImprovementNs(heavy_ns, light_ns, candidate_ns);
    return improvement >= @max(minimum_move_improvement_ns, before / 10);
}

test "worker count observes count capacity and measured tick budget" {
    const target = targetTickBudgetNs(66_666_667);
    try std.testing.expectEqual(@as(u64, 39_999_999), target);
    try std.testing.expectEqual(@as(usize, 1), desiredWorkerCount(0, 0, 128, target));
    try std.testing.expectEqual(@as(usize, 6), desiredWorkerCount(750, 0, 128, target));
    try std.testing.expectEqual(@as(usize, 3), desiredWorkerCount(100, 81_000_000, 128, target));
}

test "cold player estimate gives populated lobbies nonzero weight" {
    try std.testing.expectEqual(@as(u64, 0), estimatedLobbyCostNs(900_000, 0));
    try std.testing.expectEqual(@as(u64, 25_000), estimatedLobbyCostNs(0, 1));
    try std.testing.expectEqual(@as(u64, 175_000), estimatedLobbyCostNs(0, 16));
    try std.testing.expectEqual(@as(u64, 900_000), estimatedLobbyCostNs(900_000, 16));
}

test "migration rejects swaps and accepts meaningful gap reductions" {
    try std.testing.expectEqual(@as(u64, 0), moveImprovementNs(1_000_000, 100_000, 900_000));
    try std.testing.expectEqual(@as(u64, 500_000), moveImprovementNs(1_000_000, 100_000, 250_000));
    try std.testing.expect(worthwhileMove(1_000_000, 100_000, 250_000));
    try std.testing.expect(!worthwhileMove(1_000_000, 990_000, 5_000));
}
