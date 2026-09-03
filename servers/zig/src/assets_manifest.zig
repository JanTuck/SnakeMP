//! Comptime asset manifest: every public file is embedded into the binary.
const std = @import("std");

pub const Asset = struct {
    /// Route path as served over HTTP (exact match).
    path: []const u8,
    /// Content-Type header value.
    ctype: []const u8,
    /// Embedded bytes.
    body: []const u8,
};

pub const index_html: []const u8 = @embedFile("generated/client/index.html");
pub const game_html: []const u8 = @embedFile("generated/client/game.html");

const HTML = "text/html; charset=utf-8";
const CSS = "text/css; charset=utf-8";
const JS = "application/javascript; charset=utf-8";
const PNG = "image/png";
const OTF = "font/otf";
const MD = "text/markdown; charset=utf-8";

pub const assets = [_]Asset{
    .{ .path = "/", .ctype = HTML, .body = index_html },
    .{ .path = "/index.html", .ctype = HTML, .body = index_html },
    .{ .path = "/game.html", .ctype = HTML, .body = game_html },
    .{ .path = "/css/chat.css", .ctype = CSS, .body = @embedFile("generated/client/css/chat.css") },
    .{ .path = "/css/game.css", .ctype = CSS, .body = @embedFile("generated/client/css/game.css") },
    .{ .path = "/css/index.css", .ctype = CSS, .body = @embedFile("generated/client/css/index.css") },

    .{ .path = "/js/menu/menu.js", .ctype = JS, .body = @embedFile("generated/client/js/menu/menu.js") },
    .{ .path = "/js/menu/gameOverMenu.js", .ctype = JS, .body = @embedFile("generated/client/js/menu/gameOverMenu.js") },
    .{ .path = "/js/chat.js", .ctype = JS, .body = @embedFile("generated/client/js/chat.js") },
    .{ .path = "/js/share.js", .ctype = JS, .body = @embedFile("generated/client/js/share.js") },
    .{ .path = "/js/status.js", .ctype = JS, .body = @embedFile("generated/client/js/status.js") },
    .{ .path = "/js/snapshot.js", .ctype = JS, .body = @embedFile("generated/client/js/snapshot.js") },
    .{ .path = "/js/ioSnapshot.js", .ctype = JS, .body = @embedFile("generated/client/js/ioSnapshot.js") },
    .{ .path = "/js/ioWorld.js", .ctype = JS, .body = @embedFile("generated/client/js/ioWorld.js") },
    .{ .path = "/js/transport.js", .ctype = JS, .body = @embedFile("generated/client/js/transport.js") },
    .{ .path = "/js/userInput.js", .ctype = JS, .body = @embedFile("generated/client/js/userInput.js") },
    .{ .path = "/js/sprites.js", .ctype = JS, .body = @embedFile("generated/client/js/sprites.js") },
    .{ .path = "/js/audio.js", .ctype = JS, .body = @embedFile("generated/client/js/audio.js") },
    .{ .path = "/js/particles.js", .ctype = JS, .body = @embedFile("generated/client/js/particles.js") },
    .{ .path = "/js/snake.js", .ctype = JS, .body = @embedFile("generated/client/js/snake.js") },
    .{ .path = "/js/rendering.js", .ctype = JS, .body = @embedFile("generated/client/js/rendering.js") },
    .{ .path = "/js/hud.js", .ctype = JS, .body = @embedFile("generated/client/js/hud.js") },

    .{ .path = "/img/apple.png", .ctype = PNG, .body = @embedFile("generated/client/img/apple.png") },
    .{ .path = "/img/crate.png", .ctype = PNG, .body = @embedFile("generated/client/img/crate.png") },
    .{ .path = "/img/golden.png", .ctype = PNG, .body = @embedFile("generated/client/img/golden.png") },
    .{ .path = "/img/snek.png", .ctype = PNG, .body = @embedFile("generated/client/img/snek.png") },
    .{ .path = "/img/landing-arena.png", .ctype = PNG, .body = @embedFile("generated/client/img/landing-arena.png") },
    .{ .path = "/img/mode-classical.png", .ctype = PNG, .body = @embedFile("generated/client/img/mode-classical.png") },
    .{ .path = "/img/mode-arcade.png", .ctype = PNG, .body = @embedFile("generated/client/img/mode-arcade.png") },
    .{ .path = "/img/mode-io.png", .ctype = PNG, .body = @embedFile("generated/client/img/mode-io.png") },
    .{ .path = "/img/io-360-head.png", .ctype = PNG, .body = @embedFile("generated/client/img/io-360-head.png") },
    .{ .path = "/img/io-360-body.png", .ctype = PNG, .body = @embedFile("generated/client/img/io-360-body.png") },
    .{ .path = "/img/io-360-tail.png", .ctype = PNG, .body = @embedFile("generated/client/img/io-360-tail.png") },
    .{ .path = "/img/io-360-boost-ring.png", .ctype = PNG, .body = @embedFile("generated/client/img/io-360-boost-ring.png") },
    .{ .path = "/img/io/apple.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/apple.png") },
    .{ .path = "/img/io/strawberry.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/strawberry.png") },
    .{ .path = "/img/io/cheese.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/cheese.png") },
    .{ .path = "/img/io/donut.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/donut.png") },
    .{ .path = "/img/io/golden-apple.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/golden-apple.png") },
    .{ .path = "/img/io/lightning-berry.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/lightning-berry.png") },
    .{ .path = "/img/io/rainbow-candy.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/rainbow-candy.png") },
    .{ .path = "/img/io/feast-platter.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/feast-platter.png") },
    .{ .path = "/img/io/crate.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/crate.png") },
    .{ .path = "/img/io/spike-mine.png", .ctype = PNG, .body = @embedFile("generated/client/img/io/spike-mine.png") },
    .{ .path = "/img/classic-green-head.png", .ctype = PNG, .body = @embedFile("generated/client/img/classic-green-head.png") },
    .{ .path = "/img/classic-green-body.png", .ctype = PNG, .body = @embedFile("generated/client/img/classic-green-body.png") },
    .{ .path = "/img/classic-green-tail.png", .ctype = PNG, .body = @embedFile("generated/client/img/classic-green-tail.png") },
    .{ .path = "/fonts/montserrat-black.otf", .ctype = OTF, .body = @embedFile("generated/client/fonts/montserrat-black.otf") },
    .{ .path = "/fonts/OFL-Montserrat.txt", .ctype = "text/plain; charset=utf-8", .body = @embedFile("generated/client/fonts/OFL-Montserrat.txt") },
    .{ .path = "/img/CREDITS.md", .ctype = MD, .body = @embedFile("generated/client/img/CREDITS.md") },
};

/// Linear scan is fine: the table has ~30 fixed entries.
pub fn find(route: []const u8) ?*const Asset {
    for (&assets) |*a| {
        if (std.mem.eql(u8, a.path, route)) return a;
    }
    return null;
}
