//! Game world: lobbies, players, and tick-loop logic per docs/SPEC.md.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::Instant;

use crate::json::Json;
use crate::rng;
use crate::wire;

pub const CELL: i32 = 16;
pub const GRID_W: i32 = 1920;
pub const GRID_H: i32 = 960;
pub const COLS: i64 = (GRID_W / CELL) as i64; // 120
pub const ROWS: i64 = (GRID_H / CELL) as i64; // 60

pub const MAX_PLAYERS_GLOBAL: usize = 100;
pub const MAX_PLAYERS_PER_LOBBY: usize = 16;
pub const LOBBY_IDLE_DELETE_MS: u64 = 60_000;
pub const DEFAULT_LOBBY_ID: &str = "12345";

pub const BONUS_CAP: usize = 12;
pub const DROP_TTL_MS: u64 = 25_000;
pub const GOLDEN_TTL_MS: u64 = 12_000;
pub const DROP_POINTS: i64 = 2;
pub const DROP_GROWTH: i64 = 2;
pub const DROP_APPLES: usize = 4;
pub const GOLDEN_POINTS: i64 = 3;
/// First drop of a fresh lobby comes after 8s, first golden after 20s
/// (matches the Node reference's initial scheduling).
pub const FIRST_DROP_DELAY_MS: u64 = 8_000;
pub const FIRST_GOLDEN_DELAY_MS: u64 = 20_000;

const ERR_INVALID_USERNAME: &str = "Invalid username";
const ERR_UNKNOWN_GAME: &str = "That game does not exist any more";
const ERR_SERVER_FULL: &str = "Server is full, try again later";
const ERR_LOBBY_FULL: &str = "This game is full";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Dir {
    Up,
    Down,
    Left,
    Right,
}

impl Dir {
    pub fn from_arrow(s: &str) -> Option<Dir> {
        match s {
            "ArrowUp" => Some(Dir::Up),
            "ArrowDown" => Some(Dir::Down),
            "ArrowLeft" => Some(Dir::Left),
            "ArrowRight" => Some(Dir::Right),
            _ => None,
        }
    }

    fn opposite(self) -> Dir {
        match self {
            Dir::Up => Dir::Down,
            Dir::Down => Dir::Up,
            Dir::Left => Dir::Right,
            Dir::Right => Dir::Left,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct Cell {
    pub x: i32,
    pub y: i32,
}

struct PlayerState {
    sid: String,
    name: String,
    color: String,
    snake: VecDeque<Cell>,
    dir: Option<Dir>,
    queue: VecDeque<Dir>,
    pending_growth: i64,
    score: i64,
    body_len: i64,
}

impl PlayerState {
    fn head(&self) -> Cell {
        *self.snake.front().expect("snake never empty")
    }

    /// Port of Player.setDirection: queue capped at 2; reject unknown values,
    /// same direction and 180-degree reversals relative to the last queued
    /// direction (or the applied one when the queue is empty).
    fn set_direction(&mut self, d: Dir) -> bool {
        if let Some(l) = self.queue.back().copied().or(self.dir) {
            if d == l || d == l.opposite() {
                return false;
            }
        }
        if self.queue.len() >= 2 {
            return false;
        }
        self.queue.push_back(d);
        true
    }

    fn collided_wall(&self) -> bool {
        let h = self.head();
        h.x > GRID_W - CELL || h.x < 0 || h.y > GRID_H - CELL || h.y < 0
    }

    fn collided_self(&self) -> bool {
        let h = self.head();
        self.snake.iter().skip(1).any(|s| *s == h)
    }

    fn collided_other<'a>(&self, players: &'a [PlayerState]) -> Option<&'a PlayerState> {
        let h = self.head();
        players
            .iter()
            .filter(|o| o.sid != self.sid)
            .find(|o| o.snake.iter().any(|s| *s == h))
    }

    /// Apply one queued turn, then move. Stationary snakes do not move.
    fn update_position(&mut self) {
        if let Some(d) = self.queue.pop_front() {
            self.dir = Some(d);
        }
        let dir = match self.dir {
            Some(d) => d,
            None => return,
        };
        let mut head = *self.snake.front().unwrap();
        match dir {
            Dir::Right => head.x += CELL,
            Dir::Left => head.x -= CELL,
            Dir::Up => head.y -= CELL,
            Dir::Down => head.y += CELL,
        }
        if self.pending_growth > 0 {
            self.pending_growth -= 1;
        } else {
            self.snake.pop_back();
        }
        self.snake.push_front(head);
        self.body_len = self.snake.len() as i64;
    }

    fn eat(&mut self, points: i64, growth: i64) {
        self.score += points;
        self.pending_growth += growth;
        self.body_len = self.snake.len() as i64 + self.pending_growth;
    }
}

struct Drop {
    id: String,
    x: i32,
    y: i32,
    expires_at: u64,
}

struct Lobby {
    id: String,
    players: Vec<PlayerState>,
    food: Cell,
    bonus: Vec<Cell>,
    drops: Vec<Drop>,
    golden: Option<(Cell, u64)>,
    next_drop_at: u64,
    next_golden_at: u64,
    drop_seq: u64,
    last_empty_at: u64,
    st_last_ms: f64,
    st_avg_ms: f64,
    st_max_ms: f64,
    st_ticks: u64,
}

impl Lobby {
    fn new(id: &str, food: Cell) -> Lobby {
        Lobby {
            id: id.to_string(),
            players: Vec::new(),
            food,
            bonus: Vec::new(),
            drops: Vec::new(),
            golden: None,
            next_drop_at: 0,
            next_golden_at: 0,
            drop_seq: 1,
            last_empty_at: 0,
            st_last_ms: 0.0,
            st_avg_ms: 0.0,
            st_max_ms: 0.0,
            st_ticks: 0,
        }
    }

    fn random_cell(r: &mut rng::Rng) -> Cell {
        Cell {
            x: (r.below(COLS as u64) as i64 * CELL as i64) as i32,
            y: (r.below(ROWS as u64) as i64 * CELL as i64) as i32,
        }
    }

    /// Random cell not on any snake or pickup (200 attempts, like the reference).
    fn random_free_cell(&self, r: &mut rng::Rng) -> Option<Cell> {
        for _ in 0..200 {
            let c = Self::random_cell(r);
            let taken = self.players.iter().any(|p| p.snake.iter().any(|s| *s == c))
                || self.food == c
                || self.bonus.contains(&c)
                || self.drops.iter().any(|d| d.x == c.x && d.y == c.y)
                || matches!(self.golden, Some((g, _)) if g == c);
            if !taken {
                return Some(c);
            }
        }
        None
    }

    /// Spawn: random cell free of snakes and main food, up to 100 attempts.
    fn spawn_position(&self, r: &mut rng::Rng) -> Cell {
        let mut pos = Self::random_cell(r);
        for _ in 0..100 {
            pos = Self::random_cell(r);
            let on_snake = self
                .players
                .iter()
                .any(|p| p.snake.iter().any(|s| *s == pos));
            if !on_snake && self.food != pos {
                break;
            }
        }
        pos
    }

    fn respawn_food(&mut self, r: &mut rng::Rng) {
        for _ in 0..100 {
            self.food = Self::random_cell(r);
            let occupied = self
                .players
                .iter()
                .any(|p| p.snake.iter().any(|s| *s == self.food));
            if !occupied {
                return;
            }
        }
    }
}

pub struct GameServer {
    lobbies: HashMap<String, Lobby>,
    order: Vec<String>, // insertion order, like the JS Map
    closed_sids: HashSet<String>,
    start: Instant,
}

/// Outbound engine.io message payload addressed to a socket id:
/// (sid, payload-after-the-message-prefix-4).
pub type OutMsg = (String, String);

impl GameServer {
    pub fn new() -> Self {
        let mut g = GameServer {
            lobbies: HashMap::new(),
            order: Vec::new(),
            closed_sids: HashSet::new(),
            start: Instant::now(),
        };
        g.create_lobby(DEFAULT_LOBBY_ID);
        g
    }

    fn create_lobby(&mut self, id: &str) {
        let food = Lobby::random_cell(&mut rng::global().lock().unwrap_or_else(|e| e.into_inner()));
        self.lobbies.insert(id.to_string(), Lobby::new(id, food));
        self.order.push(id.to_string());
    }

    fn total_players(&self) -> usize {
        self.lobbies.values().map(|l| l.players.len()).sum()
    }

    pub fn mark_closed(&mut self, sid: &str) {
        self.closed_sids.insert(sid.to_string());
    }

    pub fn lobby_exists(&self, id: &str) -> bool {
        self.lobbies.contains_key(id)
    }

    pub fn create_game_id(&mut self) -> String {
        loop {
            let now_ms = now_millis();
            let id = {
                let mut r = rng::global().lock().unwrap_or_else(|e| e.into_inner());
                format!("id-{}{}", r.base36(8), to_base36(now_ms))
            };
            if !self.lobbies.contains_key(&id) {
                self.create_lobby(&id);
                return id;
            }
        }
    }

    /// Handle a socket.io event from 'sid'. Mirrors the io.on('connection')
    /// handlers in the Node reference.
    pub fn handle_event(&mut self, sid: &str, event: &str, args: &[Json], out: &mut Vec<OutMsg>) {
        match event {
            "clientReady" => self.client_ready(sid, args, out),
            "keyPress" => {
                let dir = args
                    .first()
                    .and_then(|a| a.as_str())
                    .and_then(Dir::from_arrow);
                if let Some(d) = dir {
                    for id in self.order.clone() {
                        if let Some(l) = self.lobbies.get_mut(&id) {
                            if let Some(p) = l.players.iter_mut().find(|p| p.sid == sid) {
                                p.set_direction(d);
                                return;
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn client_ready(&mut self, sid: &str, args: &[Json], out: &mut Vec<OutMsg>) {
        // Already alive on this socket? Ignore silently. A socket may rejoin
        // (Retry without reload) once death removed its player.
        for l in self.lobbies.values() {
            if l.players.iter().any(|p| p.sid == sid) {
                return;
            }
        }

        let username_arg = args.first();
        let username = username_arg.and_then(|a| a.as_str());
        let valid = username.map(valid_username).unwrap_or(false);
        if !valid {
            out.push((sid.to_string(), wire::error(ERR_INVALID_USERNAME)));
            return;
        }
        let username = username.unwrap();

        let lobby_id = args.get(1).and_then(|a| a.as_str());
        let exists = lobby_id.map(|id| self.lobby_exists(id)).unwrap_or(false);
        if !exists {
            out.push((sid.to_string(), wire::error(ERR_UNKNOWN_GAME)));
            return;
        }
        let lobby_id = lobby_id.unwrap();

        if self.total_players() >= MAX_PLAYERS_GLOBAL {
            out.push((sid.to_string(), wire::error(ERR_SERVER_FULL)));
            return;
        }
        let lobby_full = self
            .lobbies
            .get(lobby_id)
            .map(|l| l.players.len())
            .unwrap_or(usize::MAX)
            >= MAX_PLAYERS_PER_LOBBY;
        if lobby_full {
            out.push((sid.to_string(), wire::error(ERR_LOBBY_FULL)));
            return;
        }

        // init goes to the joining socket before it is added to the room.
        let food = { self.lobbies.get(lobby_id).unwrap().food };
        out.push((sid.to_string(), wire::init(CELL, &food)));

        let (spawn, color) = {
            let mut r = rng::global().lock().unwrap_or_else(|e| e.into_inner());
            let spawn = self.lobbies.get(lobby_id).unwrap().spawn_position(&mut r);
            let color = r.hex_color();
            (spawn, color)
        };

        let player = PlayerState {
            sid: sid.to_string(),
            name: username.trim().to_string(),
            color,
            snake: VecDeque::from(vec![spawn]),
            dir: None,
            queue: VecDeque::new(),
            pending_growth: 0,
            score: 0,
            body_len: 1,
        };
        let name = player.name.clone();

        let lobby = self.lobbies.get_mut(lobby_id).unwrap();
        lobby.players.push(player);

        // Join feed broadcast reaches the room, joiner included.
        let feed = wire::feed("join", Some(&name), None, None, None);
        let room: Vec<String> = lobby.players.iter().map(|p| p.sid.clone()).collect();
        for s in room {
            out.push((s, feed.clone()));
        }
    }

    // ----------------------------- ticking ----------------------------------

    pub fn tick(&mut self, now: u64) -> Vec<OutMsg> {
        let mut out = Vec::new();
        if self.total_players() == 0 {
            return out;
        }
        let mut r = rng::global().lock().unwrap_or_else(|e| e.into_inner());

        // Pass 1: reap sockets whose transport died without a clean leave.
        let closed: HashSet<String> = std::mem::take(&mut self.closed_sids);
        for id in self.order.clone() {
            let Some(lobby) = self.lobbies.get_mut(&id) else {
                continue;
            };
            if !closed.is_empty() {
                let before = lobby.players.len();
                let removed: Vec<PlayerState> = {
                    let (kept, gone): (Vec<_>, Vec<_>) = lobby
                        .players
                        .drain(..)
                        .partition(|p| !closed.contains(&p.sid));
                    lobby.players = kept;
                    gone
                };
                if lobby.players.len() != before {
                    for dead in &removed {
                        let payload =
                            wire::feed("death", Some(&dead.name), Some(dead.score), None, None);
                        broadcast(&mut out, &lobby.players, &payload);
                    }
                }
            }
            maybe_mark_empty(lobby, now);
        }

        // Pass 2: delete idle non-default lobbies.
        let mut to_delete: Vec<String> = Vec::new();
        for id in &self.order {
            if let Some(lobby) = self.lobbies.get(id) {
                if lobby.id != DEFAULT_LOBBY_ID
                    && lobby.players.is_empty()
                    && lobby.last_empty_at != 0
                    && now.saturating_sub(lobby.last_empty_at) > LOBBY_IDLE_DELETE_MS
                {
                    to_delete.push(id.clone());
                }
            }
        }
        for id in to_delete {
            self.lobbies.remove(&id);
            self.order.retain(|x| x != &id);
        }

        // Pass 3: tick every lobby that has players.
        for id in self.order.clone() {
            let Some(lobby) = self.lobbies.get_mut(&id) else {
                continue;
            };
            if lobby.players.is_empty() {
                continue;
            }
            let t0 = Instant::now();
            tick_lobby(lobby, now, &mut r, &mut out);
            let dur = t0.elapsed().as_secs_f64() * 1000.0;
            lobby.st_ticks += 1;
            lobby.st_last_ms = dur;
            lobby.st_avg_ms += (dur - lobby.st_avg_ms) / (lobby.st_ticks.min(200) as f64);
            lobby.st_max_ms = lobby.st_max_ms.max(dur);
        }
        out
    }

    /// GET /debug/stats body (only reachable when SNEK_DEBUG=1).
    pub fn stats_json(&self) -> String {
        let stats = wire::Stats {
            rss: read_rss_bytes(),
            uptime: self.start.elapsed().as_secs_f64(),
            total_players: self.total_players(),
            lobbies: self
                .order
                .iter()
                .filter_map(|id| self.lobbies.get(id))
                .map(|lobby| wire::LobbyStats {
                    id: &lobby.id,
                    players: lobby.players.len(),
                    drops: lobby.drops.len(),
                    bonus: lobby.bonus.len(),
                    golden: lobby.golden.is_some(),
                    last_tick_ms: round1(lobby.st_last_ms),
                    avg_tick_ms: round1(lobby.st_avg_ms),
                    max_tick_ms: round1(lobby.st_max_ms),
                })
                .collect(),
        };
        wire::stats(&stats)
    }
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn maybe_mark_empty(lobby: &mut Lobby, now: u64) {
    if lobby.players.is_empty() && lobby.id != DEFAULT_LOBBY_ID && lobby.last_empty_at == 0 {
        lobby.last_empty_at = now;
    }
}

/// Username rule: trimmed length 4..=16 (counted like JS UTF-16 units),
/// charset [unicode letters | unicode numbers | '_' | '-' | ' '].
pub fn valid_username(raw: &str) -> bool {
    let t = raw.trim();
    let mut utf16_len: usize = 0;
    for ch in t.chars() {
        let ok = ch == '_' || ch == '-' || ch == ' ' || ch.is_alphanumeric();
        if !ok {
            return false;
        }
        utf16_len += if (ch as u32) > 0xFFFF { 2 } else { 1 };
    }
    (4..=16).contains(&utf16_len)
}

fn to_base36(mut v: u64) -> String {
    const D: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    if v == 0 {
        return "0".to_string();
    }
    let mut buf = Vec::new();
    while v > 0 {
        buf.push(D[(v % 36) as usize] as char);
        v /= 36;
    }
    buf.iter().rev().collect()
}

/// RSS in bytes: /proc/self/status VmRSS first, then statm resident pages.
fn read_rss_bytes() -> u64 {
    use std::io::Read;
    if let Ok(mut f) = std::fs::File::open("/proc/self/status") {
        let mut txt = String::new();
        if f.read_to_string(&mut txt).is_ok() {
            for line in txt.lines() {
                if let Some(rest) = line.strip_prefix("VmRSS:") {
                    let kb: u64 = rest
                        .trim()
                        .trim_end_matches("kB")
                        .trim()
                        .parse()
                        .unwrap_or(0);
                    if kb > 0 {
                        return kb * 1024;
                    }
                }
            }
        }
    }
    if let Ok(txt) = std::fs::read_to_string("/proc/self/statm") {
        if let Some(second) = txt.split_whitespace().nth(1) {
            if let Ok(pages) = second.parse::<u64>() {
                return pages * 4096;
            }
        }
    }
    0
}

fn broadcast(out: &mut Vec<OutMsg>, room: &[PlayerState], payload: &str) {
    for p in room {
        out.push((p.sid.clone(), payload.to_string()));
    }
}

// ------------------------------ tick lobby ----------------------------------

fn tick_lobby(lobby: &mut Lobby, now: u64, r: &mut rng::Rng, out: &mut Vec<OutMsg>) {
    // 1. Expire stale pickups.
    lobby.drops.retain(|d| d.expires_at > now);
    if let Some((_, exp)) = lobby.golden {
        if exp <= now {
            lobby.golden = None;
        }
    }

    // 2. Schedule supply drops / golden apples.
    if lobby.next_drop_at == 0 {
        lobby.next_drop_at = now + FIRST_DROP_DELAY_MS;
    }
    if lobby.next_golden_at == 0 {
        lobby.next_golden_at = now + FIRST_GOLDEN_DELAY_MS;
    }
    if now >= lobby.next_drop_at && lobby.drops.len() < 2 {
        if let Some(c) = lobby.random_free_cell(r) {
            let d = Drop {
                id: format!("drop-{}", lobby.drop_seq),
                x: c.x,
                y: c.y,
                expires_at: now + DROP_TTL_MS,
            };
            lobby.drop_seq += 1;
            lobby.drops.push(d);
            let payload = wire::feed("drop-incoming", None, None, None, None);
            broadcast(out, &lobby.players, &payload);
        }
        lobby.next_drop_at = now + 12_000 + r.below(8_000);
    }
    if now >= lobby.next_golden_at && lobby.golden.is_none() {
        if let Some(c) = lobby.random_free_cell(r) {
            lobby.golden = Some((c, now + GOLDEN_TTL_MS));
        }
        lobby.next_golden_at = now + 25_000 + r.below(15_000);
    }

    // 3./4. Per player, in insertion order; skip anyone already dead this tick.
    let sids: Vec<String> = lobby.players.iter().map(|p| p.sid.clone()).collect();
    for sid in sids {
        let idx = match lobby.players.iter().position(|p| p.sid == sid) {
            Some(i) => i,
            None => continue, // died earlier this tick
        };

        // a. wall / self collision
        let (dead, score, name) = {
            let p = &lobby.players[idx];
            (
                p.collided_wall() || p.collided_self(),
                p.score,
                p.name.clone(),
            )
        };
        if dead {
            out.push((sid.clone(), wire::death(score)));
            let payload = wire::feed("death", Some(&name), Some(score), None, None);
            broadcast(out, &lobby.players, &payload);
            lobby.players.remove(idx);
            continue;
        }

        // b. head vs any other snake segment -> both die
        let other_hit: Option<(String, String, i64)> = {
            let me = &lobby.players[idx];
            me.collided_other(&lobby.players)
                .map(|o| (o.sid.clone(), o.name.clone(), o.score))
        };
        if let Some((osid, oname, oscore)) = other_hit {
            let (mscore, mname) = {
                let me = &lobby.players[idx];
                (me.score, me.name.clone())
            };
            out.push((sid.clone(), wire::death(mscore)));
            out.push((osid.clone(), wire::death(oscore)));
            let f1 = wire::feed("death", Some(&mname), Some(mscore), None, None);
            broadcast(out, &lobby.players, &f1);
            let f2 = wire::feed("death", Some(&oname), Some(oscore), None, None);
            broadcast(out, &lobby.players, &f2);
            let oi = lobby.players.iter().position(|p| p.sid == osid).unwrap();
            if oi > idx {
                lobby.players.remove(oi);
                lobby.players.remove(idx);
            } else {
                lobby.players.remove(idx);
                lobby.players.remove(oi);
            }
            continue;
        }

        // c. main food
        {
            let head = lobby.players[idx].head();
            if head == lobby.food {
                lobby.players[idx].eat(1, 1);
                lobby.respawn_food(r);
                let uf = wire::update_food(&lobby.food);
                broadcast(out, &lobby.players, &uf);
            }
        }

        // d. bonus apples
        {
            let head = lobby.players[idx].head();
            if let Some(i) = lobby.bonus.iter().position(|b| *b == head) {
                lobby.bonus.remove(i);
                lobby.players[idx].eat(1, 1);
            }
        }

        // e. golden apple
        {
            let head = lobby.players[idx].head();
            let hit = matches!(lobby.golden, Some((g, _)) if g == head);
            if hit {
                lobby.golden = None;
                lobby.players[idx].eat(GOLDEN_POINTS, 1);
                let name = lobby.players[idx].name.clone();
                let payload = wire::feed("golden", Some(&name), None, None, Some(GOLDEN_POINTS));
                broadcast(out, &lobby.players, &payload);
            }
        }

        // f. supply crates
        {
            let head = lobby.players[idx].head();
            if let Some(i) = lobby
                .drops
                .iter()
                .position(|d| d.x == head.x && d.y == head.y)
            {
                lobby.drops.remove(i);
                lobby.players[idx].eat(DROP_POINTS, DROP_GROWTH);
                let mut spawned = 0usize;
                for _ in 0..DROP_APPLES {
                    if lobby.bonus.len() >= BONUS_CAP {
                        break;
                    }
                    match lobby.random_free_cell(r) {
                        Some(c) => {
                            lobby.bonus.push(c);
                            spawned += 1;
                        }
                        None => break,
                    }
                }
                let name = lobby.players[idx].name.clone();
                let payload = wire::feed("drop-open", Some(&name), None, Some(spawned), None);
                broadcast(out, &lobby.players, &payload);
            }
        }

        // g. apply one queued turn, then move.
        lobby.players[idx].update_position();
    }

    // 5. Broadcast gameTick to everyone still in the room.
    let gt = build_game_tick(lobby, now);
    broadcast(out, &lobby.players, &gt);
}

fn build_game_tick(lobby: &Lobby, now: u64) -> String {
    let world = wire::TickWorld {
        players: lobby
            .players
            .iter()
            .map(|p| wire::TickPlayer {
                id: &p.sid,
                display_name: &p.name,
                color: &p.color,
                snake: &p.snake,
                score: p.score,
                body_length: p.body_len,
            })
            .collect(),
        bonus: &lobby.bonus,
        drops: lobby
            .drops
            .iter()
            .map(|d| wire::TickDrop {
                id: &d.id,
                x: d.x,
                y: d.y,
                ttl: d.expires_at.saturating_sub(now),
            })
            .collect(),
        golden: lobby.golden.map(|(g, expires_at)| wire::TickGolden {
            x: g.x,
            y: g.y,
            ttl: expires_at.saturating_sub(now),
        }),
    };

    wire::game_tick(&world)
}
