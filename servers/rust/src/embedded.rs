//! Embedded shared-client asset table (include_bytes!).
//! URL path -> (bytes, content-type). Served by main.rs.

pub type Asset = (&'static str, &'static [u8], &'static str);

pub static ASSETS: &[Asset] = &[
    (
        "/css/game.css",
        include_bytes!("../../../client/css/game.css"),
        "text/css; charset=utf-8",
    ),
    (
        "/css/index.css",
        include_bytes!("../../../client/css/index.css"),
        "text/css; charset=utf-8",
    ),
    (
        "/game.html",
        include_bytes!("../../../client/game.html"),
        "text/html; charset=utf-8",
    ),
    (
        "/img/apple.png",
        include_bytes!("../../../client/img/apple.png"),
        "image/png",
    ),
    (
        "/img/bolt.png",
        include_bytes!("../../../client/img/bolt.png"),
        "image/png",
    ),
    (
        "/img/crate.png",
        include_bytes!("../../../client/img/crate.png"),
        "image/png",
    ),
    (
        "/img/CREDITS.md",
        include_bytes!("../../../client/img/CREDITS.md"),
        "text/markdown; charset=utf-8",
    ),
    (
        "/img/crown.png",
        include_bytes!("../../../client/img/crown.png"),
        "image/png",
    ),
    (
        "/img/golden.png",
        include_bytes!("../../../client/img/golden.png"),
        "image/png",
    ),
    (
        "/img/party.png",
        include_bytes!("../../../client/img/party.png"),
        "image/png",
    ),
    (
        "/img/snek.png",
        include_bytes!("../../../client/img/snek.png"),
        "image/png",
    ),
    (
        "/img/sparkles.png",
        include_bytes!("../../../client/img/sparkles.png"),
        "image/png",
    ),
    (
        "/img/swords.png",
        include_bytes!("../../../client/img/swords.png"),
        "image/png",
    ),
    (
        "/index.html",
        include_bytes!("../../../client/index.html"),
        "text/html; charset=utf-8",
    ),
    (
        "/lobby.html",
        include_bytes!("../../../client/lobby.html"),
        "text/html; charset=utf-8",
    ),
    (
        "/js/audio.js",
        include_bytes!("../../../client/js/audio.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/box.js",
        include_bytes!("../../../client/js/box.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/food.js",
        include_bytes!("../../../client/js/food.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/gameObject.js",
        include_bytes!("../../../client/js/gameObject.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/hud.js",
        include_bytes!("../../../client/js/hud.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/layout/animations.js",
        include_bytes!("../../../client/js/layout/animations.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/menu/gameOverMenu.js",
        include_bytes!("../../../client/js/menu/gameOverMenu.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/menu/menu.js",
        include_bytes!("../../../client/js/menu/menu.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/overlays/feedElement.js",
        include_bytes!("../../../client/js/overlays/feedElement.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/overlays/playerfeed.js",
        include_bytes!("../../../client/js/overlays/playerfeed.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/particles.js",
        include_bytes!("../../../client/js/particles.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/rendering.js",
        include_bytes!("../../../client/js/rendering.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/resourceHandler.js",
        include_bytes!("../../../client/js/resourceHandler.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/snake.js",
        include_bytes!("../../../client/js/snake.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/sprites.js",
        include_bytes!("../../../client/js/sprites.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/js/userInput.js",
        include_bytes!("../../../client/js/userInput.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/socket.io/socket.io.js",
        include_bytes!("../../../client/socket.io/socket.io.js"),
        "application/javascript; charset=utf-8",
    ),
    (
        "/vendor/gsap.min.js",
        include_bytes!("../../../client/vendor/gsap.min.js"),
        "application/javascript; charset=utf-8",
    ),
];

/// Exact-match lookup of a request path (leading slash kept).
pub fn lookup(path: &str) -> Option<&'static Asset> {
    ASSETS.iter().find(|(p, _, _)| *p == path)
}
