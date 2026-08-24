//! Typed debug-metrics representation and JSON encoding.
//!
//! Gameplay snapshots use the binary protocol. This module keeps the
//! infrequent `/debug/stats` endpoint readable and delegates all JSON syntax,
//! escaping, and number formatting to Zig's standard library.

const std = @import("std");

pub const WorkerLoad = struct {
    lobbies: usize,
    estimatedTickUs: f64,
};

pub const LobbyStats = struct {
    id: []const u8,
    players: usize,
    drops: usize,
    bonus: usize,
    golden: bool,
    lastTickMs: f64,
    avgTickMs: f64,
    balanceEwmaUs: f64,
    maxTickMs: f64,
    serializeUs: f64,
    avgSerializeUs: f64,
    encodeUs: f64,
    avgEncodeUs: f64,
    fanoutUs: f64,
    avgFanoutUs: f64,
    wireBytes: usize,
};

pub const Stats = struct {
    rss: u64,
    uptime: f64,
    totalPlayers: usize,
    maxPlayers: usize,
    maxPlayersPerLobby: usize,
    connections: usize,
    lobbyWorkers: usize,
    lobbiesPerWorker: usize,
    workerMigrations: u64,
    workerTargetTickUs: f64,
    workerLoads: []const WorkerLoad,
    networkBytesSent: u64,
    networkBytesReceived: u64,
    websocketFramesSent: u64,
    websocketFramesReceived: u64,
    inputEvents: u64,
    avgInputEventUs: f64,
    lobbies: []const LobbyStats,
};

pub fn encode(allocator: std.mem.Allocator, value: Stats) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "typed stats JSON escapes strings and preserves field names" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerLoad{.{ .lobbies = 1, .estimatedTickUs = 2.5 }};
    const lobbies = [_]LobbyStats{.{
        .id = "quote\"line\n",
        .players = 3,
        .drops = 0,
        .bonus = 1,
        .golden = false,
        .lastTickMs = 0.1,
        .avgTickMs = 0.2,
        .balanceEwmaUs = 3,
        .maxTickMs = 0.4,
        .serializeUs = 5,
        .avgSerializeUs = 6,
        .encodeUs = 0.5,
        .avgEncodeUs = 0.6,
        .fanoutUs = 4.5,
        .avgFanoutUs = 5.4,
        .wireBytes = 42,
    }};
    const json = try encode(allocator, .{
        .rss = 1,
        .uptime = 2,
        .totalPlayers = 3,
        .maxPlayers = 4,
        .maxPlayersPerLobby = 5,
        .connections = 6,
        .lobbyWorkers = 7,
        .lobbiesPerWorker = 8,
        .workerMigrations = 9,
        .workerTargetTickUs = 10,
        .workerLoads = &workers,
        .networkBytesSent = 11,
        .networkBytesReceived = 12,
        .websocketFramesSent = 13,
        .websocketFramesReceived = 14,
        .inputEvents = 15,
        .avgInputEventUs = 16,
        .lobbies = &lobbies,
    });
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"maxPlayersPerLobby\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workerLoads\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "quote\\\"line\\n") != null);
}
