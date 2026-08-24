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
const MD = "text/markdown; charset=utf-8";

pub const assets = [_]Asset{
    .{ .path = "/", .ctype = HTML, .body = index_html },
    .{ .path = "/index.html", .ctype = HTML, .body = index_html },
    .{ .path = "/game.html", .ctype = HTML, .body = game_html },
    .{ .path = "/lobby.html", .ctype = HTML, .body = @embedFile("generated/client/lobby.html") },

    .{ .path = "/css/game.css", .ctype = CSS, .body = @embedFile("generated/client/css/game.css") },
    .{ .path = "/css/index.css", .ctype = CSS, .body = @embedFile("generated/client/css/index.css") },

    .{ .path = "/js/box.js", .ctype = JS, .body = @embedFile("generated/client/js/box.js") },
    .{ .path = "/js/food.js", .ctype = JS, .body = @embedFile("generated/client/js/food.js") },
    .{ .path = "/js/layout/animations.js", .ctype = JS, .body = @embedFile("generated/client/js/layout/animations.js") },
    .{ .path = "/js/menu/menu.js", .ctype = JS, .body = @embedFile("generated/client/js/menu/menu.js") },
    .{ .path = "/js/menu/gameOverMenu.js", .ctype = JS, .body = @embedFile("generated/client/js/menu/gameOverMenu.js") },
    .{ .path = "/js/overlays/feedElement.js", .ctype = JS, .body = @embedFile("generated/client/js/overlays/feedElement.js") },
    .{ .path = "/js/overlays/playerfeed.js", .ctype = JS, .body = @embedFile("generated/client/js/overlays/playerfeed.js") },
    .{ .path = "/js/resourceHandler.js", .ctype = JS, .body = @embedFile("generated/client/js/resourceHandler.js") },
    .{ .path = "/js/userInput.js", .ctype = JS, .body = @embedFile("generated/client/js/userInput.js") },
    .{ .path = "/js/gameObject.js", .ctype = JS, .body = @embedFile("generated/client/js/gameObject.js") },
    .{ .path = "/js/sprites.js", .ctype = JS, .body = @embedFile("generated/client/js/sprites.js") },
    .{ .path = "/js/audio.js", .ctype = JS, .body = @embedFile("generated/client/js/audio.js") },
    .{ .path = "/js/particles.js", .ctype = JS, .body = @embedFile("generated/client/js/particles.js") },
    .{ .path = "/js/snake.js", .ctype = JS, .body = @embedFile("generated/client/js/snake.js") },
    .{ .path = "/js/rendering.js", .ctype = JS, .body = @embedFile("generated/client/js/rendering.js") },
    .{ .path = "/js/hud.js", .ctype = JS, .body = @embedFile("generated/client/js/hud.js") },

    .{ .path = "/img/swords.png", .ctype = PNG, .body = @embedFile("generated/client/img/swords.png") },
    .{ .path = "/img/apple.png", .ctype = PNG, .body = @embedFile("generated/client/img/apple.png") },
    .{ .path = "/img/crate.png", .ctype = PNG, .body = @embedFile("generated/client/img/crate.png") },
    .{ .path = "/img/golden.png", .ctype = PNG, .body = @embedFile("generated/client/img/golden.png") },
    .{ .path = "/img/bolt.png", .ctype = PNG, .body = @embedFile("generated/client/img/bolt.png") },
    .{ .path = "/img/crown.png", .ctype = PNG, .body = @embedFile("generated/client/img/crown.png") },
    .{ .path = "/img/party.png", .ctype = PNG, .body = @embedFile("generated/client/img/party.png") },
    .{ .path = "/img/sparkles.png", .ctype = PNG, .body = @embedFile("generated/client/img/sparkles.png") },
    .{ .path = "/img/snek.png", .ctype = PNG, .body = @embedFile("generated/client/img/snek.png") },
    .{ .path = "/img/CREDITS.md", .ctype = MD, .body = @embedFile("generated/client/img/CREDITS.md") },

    .{ .path = "/vendor/gsap.min.js", .ctype = JS, .body = @embedFile("generated/client/vendor/gsap.min.js") },
    .{ .path = "/socket.io/socket.io.js", .ctype = JS, .body = @embedFile("generated/client/socket.io/socket.io.js") },
};

/// Linear scan is fine: the table has ~30 fixed entries.
pub fn find(route: []const u8) ?*const Asset {
    for (&assets) |*a| {
        if (std.mem.eql(u8, a.path, route)) return a;
    }
    return null;
}
