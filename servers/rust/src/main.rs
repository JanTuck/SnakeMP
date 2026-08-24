//! snek-rust: self-contained Snek server (SPEC parity port).
//! Std-only: TcpListener + thread-per-connection + one 66.67ms ticker.

mod base64;
mod embedded;
mod game;
mod http;
mod json;
mod rng;
mod sha1;
mod wire;
mod ws;

use std::io::BufReader;
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

use http::{read_request, write_resp, Resp};
use ws::Out;

fn debug_enabled() -> bool {
    static D: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *D.get_or_init(|| std::env::var("SNEK_DEBUG").as_deref() == Ok("1"))
}

// ------------------------------ HTTP routes ---------------------------------

fn route(req: &http::Req) -> Resp {
    let get_like = req.method == "GET" || req.method == "HEAD";

    if req.path == "/socket.io/" || req.path == "/socket.io" {
        return Resp::json(400, "{\"code\":0,\"message\":\"Transport unknown\"}");
    }

    if get_like {
        // Lobby gate first: /game.html always bounces home.
        if req.path == "/game.html" {
            return Resp::redirect(302, "/");
        }
        if req.path == "/" {
            let (_, bytes, mime) = *embedded::lookup("/index.html").unwrap();
            return Resp::bytes(200, mime, bytes);
        }
        if let Some(rest) = req.path.strip_prefix("/game/") {
            // Single-segment ids only (express :id semantics).
            if !rest.is_empty() && !rest.contains('/') {
                let id = http::decode_component(rest, false);
                let ok = ws::with_game(|g| g.lobby_exists(&id));
                if ok {
                    let (_, bytes, mime) = *embedded::lookup("/game.html").unwrap();
                    return Resp::bytes(200, mime, bytes);
                }
                return Resp::redirect(302, "/");
            }
        }
        if req.path == "/debug/stats" && debug_enabled() {
            let body = ws::with_game(|g| g.stats_json());
            return Resp::json(200, &body);
        }
        // Static assets (also /vendor/gsap.min.js and /socket.io/socket.io.js,
        // plus /index.html directly). /game.html never reaches here: it is
        // redirected before any static lookup.
        if !req.path.contains("..") {
            if let Some((_, bytes, mime)) = embedded::lookup(&req.path) {
                return Resp::bytes(200, mime, bytes);
            }
        }
    }

    if req.method == "POST" {
        if req.path == "/generateid" {
            let id = ws::with_game(|g| g.create_game_id());
            let mut loc = String::from("/game/");
            for c in id.chars() {
                match c {
                    'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' => loc.push(c),
                    _ => {
                        loc.push('%');
                        loc.push_str(&format!("{:02X}", c as u32));
                    }
                }
            }
            return Resp::redirect(303, &loc);
        }
        if req.path == "/joingame" {
            if let Some(raw) = http::form_value(&req.body, "gameId") {
                let id = raw.trim().to_string();
                let ok = ws::with_game(|g| g.lobby_exists(&id));
                if ok {
                    let loc = format!("/game/{}", urlencode_component(&id));
                    return Resp::redirect(303, &loc);
                }
            }
            return Resp::redirect(303, "/?error=unknown-game");
        }
    }

    Resp::text(404, "Not Found")
}

fn urlencode_component(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' => out.push(c),
            _ => {
                out.push('%');
                out.push_str(&format!("{:02X}", c as u32));
            }
        }
    }
    out
}

// ------------------------------ connections ---------------------------------

const READ_TIMEOUT: Duration = Duration::from_secs(75);

fn handle_conn(stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
    let mut sock = stream;
    let mut reader = BufReader::with_capacity(
        16 * 1024,
        match sock.try_clone() {
            Ok(s) => s,
            Err(_) => return,
        },
    );

    loop {
        let req = match read_request(&mut reader) {
            Ok(Some(r)) => r,
            Ok(None) => return,
            Err(_) => return,
        };

        // Engine.io websocket upgrade?
        let is_ws_target = req.path == "/socket.io/";
        let wants_ws = is_ws_target
            && req.query_param("transport").as_deref() == Some("websocket")
            && req
                .header("upgrade")
                .map(|v| v.eq_ignore_ascii_case("websocket"))
                .unwrap_or(false)
            && req.header("sec-websocket-key").is_some();

        if wants_ws {
            ws::run_session(sock, &mut reader, &req);
            return;
        }

        // Any other /socket.io/ request: engine.io-style transport error.
        if req.path == "/socket.io/" {
            let resp = Resp::json(400, "{\"code\":0,\"message\":\"Transport unknown\"}");
            let _ = write_resp(&mut sock, &req, &resp);
            if resp.status >= 400 && !req.version11 {
                return;
            }
            continue;
        }

        let resp = route(&req);
        let closing = req
            .header("connection")
            .map(|v| v.eq_ignore_ascii_case("close"))
            .unwrap_or(!req.version11);
        if write_resp(&mut sock, &req, &resp).is_err() || closing {
            return;
        }
    }
}

// ------------------------------ ticker --------------------------------------

/// 1000ms / 15 ticks = 66.6667ms; nanosecond cadence keeps long-run rate.
const TICK_NANOS: u64 = 66_666_667;

fn spawn_ticker() {
    let reg = ws_registry_clone();
    std::thread::Builder::new()
        .name("ticker".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            let tick = Duration::from_nanos(TICK_NANOS);
            let mut next = Instant::now();
            loop {
                next += tick;
                let now_i = Instant::now();
                if next > now_i {
                    std::thread::sleep(next - now_i);
                } else {
                    next = now_i; // we fell behind; do not spiral
                }
                let now_ms = now_unix_millis();
                let out = ws::with_game(|g| g.tick(now_ms));
                ws_dispatch(out, &reg);
            }
        })
        .expect("spawn ticker");
}

fn now_unix_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// Small shims so main.rs does not need the registry type directly.
fn ws_registry_clone() -> ws::RegistryHandle {
    ws::registry_handle()
}
fn ws_dispatch(out: Vec<(String, String)>, reg: &ws::RegistryHandle) {
    ws::dispatch_handle(out, reg)
}

fn main() {
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3000);

    let addr = format!("0.0.0.0:{}", port);
    let listener = match TcpListener::bind(&addr) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("server error: {}", e);
            std::process::exit(1);
        }
    };
    println!("listening on *:{}", port);

    spawn_ticker();

    for conn in listener.incoming() {
        match conn {
            Ok(s) => {
                let _ = std::thread::Builder::new()
                    .name("conn".into())
                    .stack_size(256 * 1024)
                    .spawn(move || handle_conn(s));
            }
            Err(_) => continue,
        }
    }

    // Keep Out referenced (used inside handle_conn).
    let _: Option<Out> = None;
}
