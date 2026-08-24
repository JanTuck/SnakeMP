//! Runtime-independent server and game tuning. Environment overrides are
//! parsed by main.zig; protocol constants stay centralized here.

/// Canonical 16:9 world. Coordinates remain pixel-based on the wire while the
/// simulation moves in 16-pixel cells, so both axes fit in one cell byte.
pub const GRID_COLS: i32 = 128;
pub const GRID_ROWS: i32 = 72;
pub const GRID_W: i32 = 2048;
pub const GRID_H: i32 = 1152;
pub const MAX_CELLS: usize = @intCast(GRID_COLS * GRID_ROWS);
pub const TICK_NS: u64 = 66_666_667;
/// Hidden browser tabs still receive an authoritative keyframe often enough
/// to stay warm without paying the foreground 15 Hz fan-out cost.
pub const BACKGROUND_SNAPSHOT_MS: i64 = 1_000;

pub const DEFAULT_MAX_PLAYERS_GLOBAL: usize = 100;
pub const DEFAULT_MAX_PLAYERS_PER_LOBBY: usize = 16;
/// Includes the permanent default lobby. Empty generated lobbies are cheap,
/// but still retain ids, maps, and debug-metric rows until their idle TTL.
pub const DEFAULT_MAX_LOBBIES: usize = 4096;
pub const LOBBIES_PER_WORKER: usize = 128;
pub const GAME_WORKER_STACK: usize = 128 * 1024;
pub const LOBBY_IDLE_DELETE_MS: i64 = 60_000;
pub const DEFAULT_LOBBY_ID = "12345";
/// Passwords are request- and packet-bounded before hashing. This is a byte
/// limit (not a code-point limit), matching HTTP and WebSocket wire lengths.
pub const MAX_LOBBY_PASSWORD_BYTES: usize = 64;
/// Display names are counted as Unicode code points, with the independent
/// byte ceiling inherited from the one-byte WebSocket field length.
pub const MIN_USERNAME_CODEPOINTS: usize = 1;
pub const MAX_USERNAME_CODEPOINTS: usize = 64;
pub const MAX_USERNAME_BYTES: usize = 255;

pub const BONUS_CAP: usize = 12;
pub const DROP_MAX: usize = 2;
pub const DROP_TTL_MS: i64 = 25_000;
pub const GOLDEN_TTL_MS: i64 = 12_000;
pub const GOLDEN_POINTS: i64 = 3;
pub const DROP_POINTS: i64 = 2;
pub const DROP_GROWTH: i64 = 2;
pub const DROP_APPLES: usize = 4;

pub const PING_INTERVAL_MS: i64 = 20_000;
pub const PING_TIMEOUT_MS: i64 = 15_000;

pub const ERR_INVALID_USERNAME = "Invalid username";
pub const ERR_UNKNOWN_GAME = "That game does not exist any more";
pub const ERR_SERVER_FULL = "Server is full, try again later";
pub const ERR_LOBBY_FULL = "This game is full";

pub const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
pub const MAX_HTTP_HEAD_LINE: usize = 16 * 1024;
// The only body-bearing route accepts a short lobby id. Four KiB leaves ample
// JSON/form headroom without allowing a slow client to pin a MiB per socket.
pub const MAX_HTTP_BODY: usize = 4 * 1024;
// Aggregate buffered input may contain several complete pipelined requests.
// Keep that compatibility without restoring the former ~1 MiB per-socket cap.
pub const MAX_HTTP_INPUT: usize = 128 * 1024;
// The largest application packet is a 578-byte join (4-byte prefix, two
// u8-length strings, and the bounded 64-byte password). Leave bounded headroom
// for future packet kinds while keeping per-connection retention in KiB.
pub const MAX_WS_APP_PAYLOAD: usize = 1024;
pub const MAX_WS_INPUT: usize = 2 * 1024;
pub const MAX_QUEUE_BYTES: usize = 4 * 1024 * 1024;
pub const HTTP_IDLE_MS: i32 = 65_000;
