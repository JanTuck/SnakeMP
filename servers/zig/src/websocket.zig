//! Stateless WebSocket framing and allocation-free binary input parsing.

const std = @import("std");
const config = @import("config.zig");
const model = @import("model.zig");
const text = @import("text.zig");

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
    join: struct { lobby_id: []const u8, username: []const u8, password: []const u8 },
    direction: model.Direction,
    visibility: bool,
    boost: bool,
    chat: []const u8,
};

pub const MAX_CHAT_BYTES: usize = 160;
pub const MAX_CHAT_CODEPOINTS: usize = 96;

/// Validate a single-line chat message without allocating. The returned slice
/// borrows the caller-owned WebSocket payload and excludes surrounding ASCII
/// spaces. Newlines, tabs, control characters, and directional formatting
/// controls are rejected rather than normalized so one logical packet always
/// renders as one bounded message.
fn chatMessage(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " ");
    if (trimmed.len == 0 or trimmed.len > MAX_CHAT_BYTES) return null;

    var count: usize = 0;
    var index: usize = 0;
    while (index < trimmed.len) {
        const len = std.unicode.utf8ByteSequenceLength(trimmed[index]) catch return null;
        if (index + len > trimmed.len) return null;
        const cp = std.unicode.utf8Decode(trimmed[index .. index + len]) catch return null;
        if (text.isForbiddenDisplayCodepoint(cp)) return null;
        count += 1;
        if (count > MAX_CHAT_CODEPOINTS) return null;
        index += len;
    }
    return trimmed;
}

/// Validate a fully decoded client frame header before buffering its payload.
/// The application protocol never fragments messages, and rejecting that
/// unused feature prevents a peer from retaining MiB-sized fragment buffers.
pub fn validateClientFrame(fin: bool, reserved_bits: u8, opcode: u8, payload_len: usize) !void {
    if (reserved_bits != 0) return error.ReservedBitsSet;
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

/// Decode and enforce RFC 6455's canonical payload-length representation.
pub fn payloadLength(marker: u8, extended: u64) !usize {
    if (marker < 126) return marker;
    if (marker == 126) {
        if (extended < 126) return error.NonCanonicalLength;
    } else if (marker == 127) {
        if ((extended & (@as(u64, 1) << 63)) != 0) return error.InvalidPayloadLength;
        if (extended < 65_536) return error.NonCanonicalLength;
    } else return error.InvalidPayloadLength;
    if (extended > std.math.maxInt(usize)) return error.FrameTooBig;
    return @intCast(extended);
}

pub fn headerHasToken(value: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(token, wanted)) return true;
    }
    return false;
}

pub fn validClientKey(key: []const u8) bool {
    const size = std.base64.standard.Decoder.calcSizeForSlice(key) catch return false;
    if (size != 16) return false;
    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, key) catch return false;
    return true;
}

pub fn validateTextPayload(payload: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
}

pub fn validateClosePayload(payload: []const u8) !void {
    if (payload.len == 1) return error.InvalidClosePayload;
    if (payload.len == 0) return;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    const standard = code >= 1000 and code <= 1014 and code != 1004 and code != 1005 and code != 1006;
    const application = code >= 3000 and code <= 4999;
    if (!standard and !application) return error.InvalidCloseCode;
    try validateTextPayload(payload[2..]);
}

/// Parse the bounded client binary protocol without allocation. Slices borrow
/// the already-unmasked WebSocket input buffer and are consumed synchronously.
pub fn clientPacket(payload: []const u8) ?ClientPacket {
    if (payload.len == 0 or payload.len > config.MAX_WS_APP_PAYLOAD) return null;
    return switch (payload[0]) {
        1 => blk: {
            if (payload.len < 4) break :blk null;
            const lobby_len: usize = payload[1];
            const username_len: usize = payload[2];
            const password_len: usize = payload[3];
            if (lobby_len == 0 or username_len == 0 or password_len > config.MAX_LOBBY_PASSWORD_BYTES or
                4 + lobby_len + username_len + password_len != payload.len) break :blk null;
            const username_at = 4 + lobby_len;
            const password_at = username_at + username_len;
            break :blk .{ .join = .{
                .lobby_id = payload[4..username_at],
                .username = payload[username_at..password_at],
                .password = payload[password_at..],
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
        // Boost is held state rather than an edge-triggered action. Exact
        // packets make release unambiguous and reject stale/trailing input.
        4 => if (payload.len == 2) .{ .boost = switch (payload[1]) {
            0 => false,
            1 => true,
            else => return null,
        } } else null,
        // The WebSocket frame already carries an exact length, so chat needs
        // no redundant length byte. Validation keeps the returned slice
        // borrowed from the unmasked input buffer.
        5 => if (chatMessage(payload[1..])) |message| .{ .chat = message } else null,
        else => null,
    };
}

test "client frame limits reject fragmentation and oversized payloads" {
    try validateClientFrame(true, 0, 0x2, config.MAX_WS_APP_PAYLOAD);
    try std.testing.expectError(error.FrameTooBig, validateClientFrame(true, 0, 0x2, config.MAX_WS_APP_PAYLOAD + 1));
    try std.testing.expectError(error.FragmentedDataUnsupported, validateClientFrame(false, 0, 0x2, 2));
    try std.testing.expectError(error.FragmentedDataUnsupported, validateClientFrame(true, 0, 0x0, 2));
    try validateClientFrame(true, 0, 0x9, 125);
    try std.testing.expectError(error.ControlFrameTooBig, validateClientFrame(true, 0, 0x9, 126));
    try std.testing.expectError(error.FragmentedControlFrame, validateClientFrame(false, 0, 0x9, 0));
    try std.testing.expectError(error.ReservedBitsSet, validateClientFrame(true, 0x40, 0x2, 2));
}

test "client lengths, headers, text, and close payloads are canonical" {
    try std.testing.expectEqual(@as(usize, 125), try payloadLength(125, 0));
    try std.testing.expectEqual(@as(usize, 126), try payloadLength(126, 126));
    try std.testing.expectEqual(@as(usize, 65_535), try payloadLength(126, 65_535));
    try std.testing.expectEqual(@as(usize, 65_536), try payloadLength(127, 65_536));
    try std.testing.expectError(error.NonCanonicalLength, payloadLength(126, 125));
    try std.testing.expectError(error.NonCanonicalLength, payloadLength(127, 65_535));
    try std.testing.expectError(error.InvalidPayloadLength, payloadLength(127, @as(u64, 1) << 63));

    try std.testing.expect(headerHasToken(" keep-alive, UpGrAdE ", "upgrade"));
    try std.testing.expect(!headerHasToken("notupgrade, keep-alive", "upgrade"));
    try std.testing.expect(validClientKey("dGhlIHNhbXBsZSBub25jZQ=="));
    try std.testing.expect(!validClientKey("x"));
    try std.testing.expect(!validClientKey("dGhlIHNhbXBsZSBub25jZQ=A"));

    try validateTextPayload("valid \xe2\x98\x83");
    try std.testing.expectError(error.InvalidUtf8, validateTextPayload("\xc0\x80"));
    try validateClosePayload("");
    try validateClosePayload("\x03\xe8done");
    try validateClosePayload("\x0b\xb8app");
    try std.testing.expectError(error.InvalidClosePayload, validateClosePayload("\x03"));
    try std.testing.expectError(error.InvalidCloseCode, validateClosePayload("\x03\xed"));
    try std.testing.expectError(error.InvalidCloseCode, validateClosePayload("\x07\xd0"));
    try std.testing.expectError(error.InvalidUtf8, validateClosePayload("\x03\xe8\xc0\x80"));
}

test "maximum join packet includes bounded password and rejects trailing bytes" {
    var maximum_join: [578]u8 = undefined;
    maximum_join[0] = 1;
    maximum_join[1] = 255;
    maximum_join[2] = 255;
    maximum_join[3] = config.MAX_LOBBY_PASSWORD_BYTES;
    @memset(maximum_join[4..259], 'l');
    @memset(maximum_join[259..514], 'u');
    @memset(maximum_join[514..578], 'p');
    const parsed = clientPacket(&maximum_join).?.join;
    try std.testing.expectEqual(@as(usize, 255), parsed.lobby_id.len);
    try std.testing.expectEqual(@as(usize, 255), parsed.username.len);
    try std.testing.expectEqual(@as(usize, config.MAX_LOBBY_PASSWORD_BYTES), parsed.password.len);

    var trailing: [579]u8 = undefined;
    @memcpy(trailing[0..578], &maximum_join);
    trailing[578] = 0;
    try std.testing.expect(clientPacket(&trailing) == null);

    var oversized_password = maximum_join;
    oversized_password[3] = config.MAX_LOBBY_PASSWORD_BYTES + 1;
    try std.testing.expect(clientPacket(&oversized_password) == null);

    var oversized: [config.MAX_WS_APP_PAYLOAD + 1]u8 = @splat(0);
    oversized[0] = 2;
    oversized[1] = 0;
    try std.testing.expect(clientPacket(&oversized) == null);
}

test "boost packets are exact held state" {
    try std.testing.expect(!(clientPacket(&.{ 4, 0 }).?.boost));
    try std.testing.expect(clientPacket(&.{ 4, 1 }).?.boost);
    try std.testing.expect(clientPacket(&.{4}) == null);
    try std.testing.expect(clientPacket(&.{ 4, 0, 0 }) == null);
    try std.testing.expect(clientPacket(&.{ 4, 2 }) == null);
    try std.testing.expect(clientPacket(&.{ 4, 255 }) == null);
}

test "chat packets trim spaces and retain borrowed Unicode payloads" {
    const packet = "\x05  hello \xf0\x9f\x90\x8d  ";
    const message = clientPacket(packet).?.chat;
    try std.testing.expectEqualStrings("hello \xf0\x9f\x90\x8d", message);
    try std.testing.expect(@intFromPtr(message.ptr) > @intFromPtr(packet.ptr));
    try std.testing.expect(@intFromPtr(message.ptr) < @intFromPtr(packet.ptr) + packet.len);

    var max_bytes: [1 + MAX_CHAT_BYTES]u8 = undefined;
    max_bytes[0] = 5;
    for (0..40) |index| @memcpy(max_bytes[1 + index * 4 ..][0..4], "\xf0\x9f\x90\x8d");
    const maximum = clientPacket(&max_bytes).?.chat;
    try std.testing.expectEqual(@as(usize, MAX_CHAT_BYTES), maximum.len);
    try std.testing.expectEqual(@intFromPtr(&max_bytes) + 1, @intFromPtr(maximum.ptr));
}

test "chat packets enforce byte and Unicode scalar bounds" {
    var scalar_limit: [1 + MAX_CHAT_CODEPOINTS]u8 = undefined;
    scalar_limit[0] = 5;
    @memset(scalar_limit[1..], 'a');
    try std.testing.expectEqual(@as(usize, MAX_CHAT_CODEPOINTS), clientPacket(&scalar_limit).?.chat.len);

    var too_many_scalars: [2 + MAX_CHAT_CODEPOINTS]u8 = undefined;
    too_many_scalars[0] = 5;
    @memset(too_many_scalars[1..], 'a');
    try std.testing.expect(clientPacket(&too_many_scalars) == null);

    var too_many_bytes: [1 + MAX_CHAT_BYTES + 4]u8 = undefined;
    too_many_bytes[0] = 5;
    for (0..41) |index| @memcpy(too_many_bytes[1 + index * 4 ..][0..4], "\xf0\x9f\x90\x8d");
    try std.testing.expect(clientPacket(&too_many_bytes) == null);

    // Byte limits apply after surrounding spaces are removed.
    var padded: [1 + MAX_CHAT_BYTES + 2]u8 = undefined;
    padded[0] = 5;
    padded[1] = ' ';
    for (0..40) |index| @memcpy(padded[2 + index * 4 ..][0..4], "\xf0\x9f\x90\x8d");
    padded[padded.len - 1] = ' ';
    try std.testing.expectEqual(@as(usize, MAX_CHAT_BYTES), clientPacket(&padded).?.chat.len);
}

test "chat packets reject empty malformed and layout-control text" {
    try std.testing.expect(clientPacket(&.{5}) == null);
    try std.testing.expect(clientPacket("\x05     ") == null);
    try std.testing.expect(clientPacket("\x05\xc0\x80") == null);
    try std.testing.expect(clientPacket("\x05\xf0\x9f\x90") == null);

    const forbidden = [_][]const u8{
        "\x05line\nline",
        "\x05tab\ttext",
        "\x05\x00hidden",
        "\x05\xc2\x85",
        "\x05\xe2\x80\xa8",
        "\x05\xe2\x80\xa9",
        "\x05\xd8\x9cmark",
        "\x05\xe2\x80\x8bhidden",
        "\x05\xe2\x80\x8emark",
        "\x05\xe2\x80\x8fmark",
        "\x05\xe2\x80\xaaoverride",
        "\x05\xe2\x80\xaeoverride",
        "\x05\xe2\x81\xa0hidden",
        "\x05\xe2\x81\xa6isolate",
        "\x05\xe2\x81\xa9isolate",
        "\x05\xef\xbb\xbfhidden",
    };
    for (forbidden) |packet| try std.testing.expect(clientPacket(packet) == null);
}
