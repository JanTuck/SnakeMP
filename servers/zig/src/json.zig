//! Allocation-aware JSON encoding for infrequent control events.

const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const Buf = std.ArrayListUnmanaged(u8);

pub fn string(b: *Buf, allocator: Allocator, value: []const u8) !void {
    try b.append(allocator, '"');
    for (value) |ch| switch (ch) {
        '"' => try b.appendSlice(allocator, "\\\""),
        '\\' => try b.appendSlice(allocator, "\\\\"),
        '\n' => try b.appendSlice(allocator, "\\n"),
        '\r' => try b.appendSlice(allocator, "\\r"),
        '\t' => try b.appendSlice(allocator, "\\t"),
        0x08 => try b.appendSlice(allocator, "\\b"),
        0x0C => try b.appendSlice(allocator, "\\f"),
        else => if (ch < 0x20) {
            const hex = "0123456789abcdef";
            try b.appendSlice(allocator, "\\u00");
            try b.append(allocator, hex[ch >> 4]);
            try b.append(allocator, hex[ch & 0x0F]);
        } else try b.append(allocator, ch),
    };
    try b.append(allocator, '"');
}

pub fn number(b: *Buf, allocator: Allocator, value: anytype) !void {
    var scratch: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&scratch, "{d}", .{value});
    try b.appendSlice(allocator, rendered);
}

pub fn stringField(b: *Buf, allocator: Allocator, name: []const u8, value: []const u8) !void {
    try string(b, allocator, name);
    try b.append(allocator, ':');
    try string(b, allocator, value);
}

pub fn print(b: *Buf, allocator: Allocator, comptime format: []const u8, args: anytype) !void {
    var scratch: [256]u8 = undefined;
    const rendered = std.fmt.bufPrint(&scratch, format, args) catch {
        const allocated = try std.fmt.allocPrint(allocator, format, args);
        defer allocator.free(allocated);
        return b.appendSlice(allocator, allocated);
    };
    try b.appendSlice(allocator, rendered);
}

/// Raw WebSocket control event: ["<event>"<args-json>]
pub fn eventFrame(allocator: Allocator, event: []const u8, args_json: []const u8) ![]u8 {
    var frame: Buf = .empty;
    errdefer frame.deinit(allocator);

    // Control event names are currently static ASCII, so this reservation is
    // exact in production while `string` still keeps the helper safe for any
    // future event name.
    try frame.ensureTotalCapacity(allocator, event.len + args_json.len + 4);
    try frame.append(allocator, '[');
    try string(&frame, allocator, event);
    try frame.appendSlice(allocator, args_json);
    try frame.append(allocator, ']');
    return frame.toOwnedSlice(allocator);
}

test "control event names are JSON escaped" {
    const frame = try eventFrame(std.testing.allocator, "quoted\"event", ",123");
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("[\"quoted\\\"event\",123]", frame);
}
