//! Stateless WebSocket framing and allocation-free binary input parsing.

const std = @import("std");
const config = @import("config.zig");
const model = @import("model.zig");

pub fn header(out: *[10]u8, opcode: u8, len: usize) usize {
    out[0] = 0x80 | opcode;
    if (len < 126) {
        out[1] = @intCast(len);
        return 2;
    }
    if (len <= 0xFFFF) {
        out[1] = 126;
        std.mem.writeInt(u16, out[2..4], @intCast(len), .big);
        return 4;
    }
    out[1] = 127;
    std.mem.writeInt(u64, out[2..10], len, .big);
    return 10;
}

pub const ClientPacket = union(enum) {
    join: struct { lobby_id: []const u8, username: []const u8 },
    direction: model.Direction,
    visibility: bool,
};

/// Validate a fully decoded client frame header before buffering its payload.
/// The application protocol never fragments messages, and rejecting that
/// unused feature prevents a peer from retaining MiB-sized fragment buffers.
pub fn validateClientFrame(fin: bool, opcode: u8, payload_len: usize) !void {
    switch (opcode) {
        0x1, 0x2 => {
            if (!fin) return error.FragmentedDataUnsupported;
            if (payload_len > config.MAX_WS_APP_PAYLOAD) return error.FrameTooBig;
        },
        0x0 => return error.FragmentedDataUnsupported,
        0x8, 0x9, 0xA => {
            if (!fin) return error.FragmentedControlFrame;
            if (payload_len > 125) return error.ControlFrameTooBig;
        },
        else => return error.UnsupportedOpcode,
    }
}

/// Parse the bounded client binary protocol without allocation. Slices borrow
/// the already-unmasked WebSocket input buffer and are consumed synchronously.
pub fn clientPacket(payload: []const u8) ?ClientPacket {
    if (payload.len == 0 or payload.len > config.MAX_WS_APP_PAYLOAD) return null;
    return switch (payload[0]) {
        1 => blk: {
            if (payload.len < 3) break :blk null;
            const lobby_len: usize = payload[1];
            const username_len: usize = payload[2];
            if (lobby_len == 0 or username_len == 0 or 3 + lobby_len + username_len != payload.len) break :blk null;
            break :blk .{ .join = .{
                .lobby_id = payload[3 .. 3 + lobby_len],
                .username = payload[3 + lobby_len ..],
            } };
        },
        2 => if (payload.len == 2) .{ .direction = switch (payload[1]) {
            0 => .up,
            1 => .down,
            2 => .left,
            3 => .right,
            else => return null,
        } } else null,
        // Visibility is only a delivery hint. It never pauses simulation or
        // changes whether inputs are accepted, so a forged packet cannot gain
        // an authoritative gameplay advantage.
        3 => if (payload.len == 2) .{ .visibility = switch (payload[1]) {
            0 => false,
            1 => true,
            else => return null,
        } } else null,
        else => null,
    };
}

test "client frame limits reject fragmentation and oversized payloads" {
    try validateClientFrame(true, 0x2, config.MAX_WS_APP_PAYLOAD);
    try std.testing.expectError(error.FrameTooBig, validateClientFrame(true, 0x2, config.MAX_WS_APP_PAYLOAD + 1));
    try std.testing.expectError(error.FragmentedDataUnsupported, validateClientFrame(false, 0x2, 2));
    try std.testing.expectError(error.FragmentedDataUnsupported, validateClientFrame(true, 0x0, 2));
    try validateClientFrame(true, 0x9, 125);
    try std.testing.expectError(error.ControlFrameTooBig, validateClientFrame(true, 0x9, 126));
    try std.testing.expectError(error.FragmentedControlFrame, validateClientFrame(false, 0x9, 0));
}

test "maximum join packet is 513 bytes and trailing bytes are rejected" {
    var maximum_join: [513]u8 = undefined;
    maximum_join[0] = 1;
    maximum_join[1] = 255;
    maximum_join[2] = 255;
    @memset(maximum_join[3..258], 'l');
    @memset(maximum_join[258..513], 'u');
    const parsed = clientPacket(&maximum_join).?.join;
    try std.testing.expectEqual(@as(usize, 255), parsed.lobby_id.len);
    try std.testing.expectEqual(@as(usize, 255), parsed.username.len);

    var trailing: [514]u8 = undefined;
    @memcpy(trailing[0..513], &maximum_join);
    trailing[513] = 0;
    try std.testing.expect(clientPacket(&trailing) == null);

    var oversized: [config.MAX_WS_APP_PAYLOAD + 1]u8 = @splat(0);
    oversized[0] = 2;
    oversized[1] = 0;
    try std.testing.expect(clientPacket(&oversized) == null);
}
