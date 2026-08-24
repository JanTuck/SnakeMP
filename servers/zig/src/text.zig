//! User-input validation and URL/form codecs. These functions are pure apart
//! from writing into the caller-provided arena.

const std = @import("std");
const config = @import("config.zig");
const json = @import("json.zig");
const unicode_letters = @import("unicode_letters.zig");

const Allocator = std.mem.Allocator;
const Buf = json.Buf;

pub const UsernameCheck = struct { ok: bool, trimmed: []const u8 };

/// Code points that can alter visual order, hide content, or create a second
/// logical line without contributing visible text. Keep this predicate shared
/// by usernames and chat so a name cannot spoof the layout beside an otherwise
/// safe message. ZWJ (U+200D) is deliberately allowed for emoji sequences, and
/// ordinary RTL letters remain valid.
pub fn isForbiddenDisplayCodepoint(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or
        cp == 0x061c or cp == 0x200b or cp == 0x200e or cp == 0x200f or
        cp == 0x2028 or cp == 0x2029 or
        (cp >= 0x202a and cp <= 0x202e) or
        cp == 0x2060 or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xfeff;
}

fn isJsSpace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0B or cp == 0x0C or
        cp == 0x85 or cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or
        cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000 or cp == 0xFEFF;
}

pub fn jsTrim(value: []const u8) []const u8 {
    var begin: usize = 0;
    var end: usize = value.len;
    while (begin < end) {
        const len = std.unicode.utf8ByteSequenceLength(value[begin]) catch break;
        if (begin + len > end) break;
        const cp = std.unicode.utf8Decode(value[begin .. begin + len]) catch break;
        if (!isJsSpace(cp)) break;
        begin += len;
    }
    while (end > begin) {
        var start = end - 1;
        while (start > begin and (value[start] & 0xC0) == 0x80) start -= 1;
        const len = std.unicode.utf8ByteSequenceLength(value[start]) catch break;
        if (start + len != end) break;
        const cp = std.unicode.utf8Decode(value[start..end]) catch break;
        if (!isJsSpace(cp)) break;
        end = start;
    }
    return value[begin..end];
}

/// Approximation of ^[\p{L}\p{N}_\- ]+$ on a bounded, trimmed value.
pub fn checkUsername(raw: []const u8) UsernameCheck {
    const trimmed = jsTrim(raw);
    if (trimmed.len > config.MAX_USERNAME_BYTES) return .{ .ok = false, .trimmed = trimmed };
    var count: usize = 0;
    var non_letters: usize = 0;
    var index: usize = 0;
    while (index < trimmed.len) {
        const len = std.unicode.utf8ByteSequenceLength(trimmed[index]) catch return .{ .ok = false, .trimmed = trimmed };
        if (index + len > trimmed.len) return .{ .ok = false, .trimmed = trimmed };
        const cp = std.unicode.utf8Decode(trimmed[index .. index + len]) catch return .{ .ok = false, .trimmed = trimmed };
        if (isForbiddenDisplayCodepoint(cp)) return .{ .ok = false, .trimmed = trimmed };
        const allowed = cp == '_' or cp == '-' or cp == ' ' or
            (cp >= '0' and cp <= '9') or (cp >= 'A' and cp <= 'Z') or
            (cp >= 'a' and cp <= 'z') or cp >= 0x80;
        if (!allowed) return .{ .ok = false, .trimmed = trimmed };
        if (!unicode_letters.isLetter(cp)) {
            non_letters += 1;
            if (non_letters > config.MAX_USERNAME_NON_LETTERS) return .{ .ok = false, .trimmed = trimmed };
        }
        count += 1;
        index += len;
    }
    return .{
        .ok = count >= config.MIN_USERNAME_CODEPOINTS and count <= config.MAX_USERNAME_CODEPOINTS,
        .trimmed = trimmed,
    };
}

test "username validation accepts long Unicode names within wire bounds" {
    try std.testing.expect(!checkUsername("x").ok);
    try std.testing.expect(!checkUsername("界界").ok);
    try std.testing.expect(checkUsername("界界界").ok);
    try std.testing.expect(checkUsername("abcdefghijklmnopqrstuvwx").ok);
    try std.testing.expect(!checkUsername("abcdefghijklmnopqrstuvwxy").ok);
    try std.testing.expect(!checkUsername("😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀").ok);
    try std.testing.expect(!checkUsername("bad.name").ok);
    try std.testing.expect(checkUsername("abc 1_-").ok);
    try std.testing.expect(!checkUsername("abc 12_-").ok);
    try std.testing.expect(checkUsername("abc😀😀😀😀").ok);
    try std.testing.expect(!checkUsername("abc😀😀😀😀😀").ok);
    try std.testing.expect(checkUsername("Καλημέρα").ok);
    try std.testing.expect(!checkUsername("عربيّّّّّ").ok);
    try std.testing.expectEqualStrings("trimmed", checkUsername("  trimmed  ").trimmed);
}

test "username validation rejects controls and directional layout spoofing" {
    try std.testing.expect(!checkUsername("ab\x01cd").ok);
    try std.testing.expect(!checkUsername("ab\xc2\x85cd").ok); // C1 NEL
    try std.testing.expect(!checkUsername("abc\xe2\x80\x8bdef").ok); // zero-width space
    try std.testing.expect(!checkUsername("abc\xe2\x80\x8edef").ok); // LRM
    try std.testing.expect(!checkUsername("abc\xe2\x80\xaedef").ok); // RLO
    try std.testing.expect(!checkUsername("abc\xe2\x81\xa6def").ok); // LRI
    try std.testing.expect(checkUsername("مرحبا").ok);
    try std.testing.expect(checkUsername("abc👩‍💻").ok);
}
fn hexValue(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn decodeInto(out: *Buf, allocator: Allocator, value: []const u8, plus_as_space: bool) []const u8 {
    if (std.mem.indexOfAny(u8, value, if (plus_as_space) "%+" else "%") == null) return value;

    var decoded_len: usize = 0;
    var scan: usize = 0;
    while (scan < value.len) {
        if (value[scan] == '%' and scan + 2 < value.len and
            hexValue(value[scan + 1]) != null and hexValue(value[scan + 2]) != null)
        {
            scan += 3;
        } else {
            scan += 1;
        }
        decoded_len += 1;
    }
    out.ensureTotalCapacityPrecise(allocator, decoded_len) catch return value;

    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '%' and index + 2 < value.len) {
            if (hexValue(value[index + 1])) |high| if (hexValue(value[index + 2])) |low| {
                out.appendAssumeCapacity((high << 4) | low);
                index += 3;
                continue;
            };
        }
        out.appendAssumeCapacity(if (plus_as_space and value[index] == '+') ' ' else value[index]);
        index += 1;
    }
    return out.items;
}

pub fn percentDecode(allocator: Allocator, value: []const u8) []const u8 {
    var out: Buf = .empty;
    return decodeInto(&out, allocator, value, false);
}

pub fn formDecode(allocator: Allocator, value: []const u8) []const u8 {
    var out: Buf = .empty;
    return decodeInto(&out, allocator, value, true);
}

fn isUriComponentSafe(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or
        ch == '!' or ch == '~' or ch == '*' or ch == '\'' or ch == '(' or ch == ')';
}

pub fn uriEncodeComponent(allocator: Allocator, value: []const u8) []const u8 {
    var encoded_len: usize = 0;
    for (value) |ch| {
        const width: usize = if (isUriComponentSafe(ch)) 1 else 3;
        if (encoded_len > std.math.maxInt(usize) - width) return value;
        encoded_len += width;
    }
    if (encoded_len == value.len) return value;

    var out: Buf = .empty;
    out.ensureTotalCapacityPrecise(allocator, encoded_len) catch return value;
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (isUriComponentSafe(ch)) out.appendAssumeCapacity(ch) else {
            out.appendAssumeCapacity('%');
            out.appendAssumeCapacity(hex[ch >> 4]);
            out.appendAssumeCapacity(hex[ch & 15]);
        }
    }
    return out.items;
}

pub fn extractFormField(allocator: Allocator, body: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const equal = std.mem.indexOfScalar(u8, pair, '=');
        const raw_key = if (equal) |at| pair[0..at] else pair;
        const raw_value = if (equal) |at| pair[at + 1 ..] else "";
        if (std.mem.eql(u8, formDecode(allocator, raw_key), name)) return formDecode(allocator, raw_value);
    }
    return null;
}

pub fn extractJsonField(allocator: Allocator, body: []const u8, name: []const u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(name) orelse return null;
    if (value != .string) return null;

    // The parser may allocate decoded strings (for example, when escapes are
    // present). Return independent storage instead of a slice invalidated by
    // `parsed.deinit()`. Request handlers pass an arena, so callers retain the
    // same simple request-lifetime ownership model.
    return allocator.dupe(u8, value.string) catch null;
}

pub fn writeBase36(out: []u8, input: u64) usize {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var value = input;
    var reversed: [16]u8 = undefined;
    var count: usize = 0;
    if (value == 0) {
        out[0] = '0';
        return 1;
    }
    while (value > 0) : (value /= 36) {
        reversed[count] = digits[@intCast(value % 36)];
        count += 1;
    }
    const len = count;
    for (0..len) |index| out[index] = reversed[len - index - 1];
    return len;
}

test "JSON field extraction survives parser deinit" {
    const value = extractJsonField(std.testing.allocator, "{\"gameId\":\"lobby\\u002d42\"}", "gameId") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("lobby-42", value);
}

test "URL codecs avoid safe-input allocation and decode exactly" {
    const safe = "lobby-42";
    const unchanged = uriEncodeComponent(std.testing.allocator, safe);
    try std.testing.expectEqual(@intFromPtr(safe.ptr), @intFromPtr(unchanged.ptr));

    const encoded = uriEncodeComponent(std.testing.allocator, "lobby 42");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("lobby%2042", encoded);

    const decoded = percentDecode(std.testing.allocator, "lobby%2D42");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(safe, decoded);

    const form = formDecode(std.testing.allocator, "lobby+42");
    defer std.testing.allocator.free(form);
    try std.testing.expectEqualStrings("lobby 42", form);
}
