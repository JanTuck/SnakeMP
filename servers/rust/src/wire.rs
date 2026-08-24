//! Typed Socket.IO event payloads and JSON framing.

use std::collections::VecDeque;

use serde::Serialize;

use crate::game::Cell;

fn event<T: Serialize>(name: &str, payload: &T) -> String {
    let mut frame = Vec::with_capacity(128);
    frame.extend_from_slice(b"42");
    serde_json::to_writer(&mut frame, &(name, payload))
        .expect("serializing a protocol event cannot fail");
    String::from_utf8(frame).expect("serde_json always emits UTF-8")
}

pub fn error(message: &str) -> String {
    event("game_error", &message)
}

pub fn death(score: i64) -> String {
    event("death", &score)
}

pub fn update_food(food: &Cell) -> String {
    event("updateFood", food)
}

#[derive(Serialize)]
struct Init<'a> {
    scale: i32,
    food: &'a Cell,
}

pub fn init(scale: i32, food: &Cell) -> String {
    event("init", &Init { scale, food })
}

#[derive(Serialize)]
struct Feed<'a> {
    #[serde(rename = "type")]
    kind: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    who: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    score: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    apples: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    points: Option<i64>,
}

pub fn feed(
    kind: &str,
    who: Option<&str>,
    score: Option<i64>,
    apples: Option<usize>,
    points: Option<i64>,
) -> String {
    event(
        "feed",
        &Feed {
            kind,
            who,
            score,
            apples,
            points,
        },
    )
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TickPlayer<'a> {
    pub id: &'a str,
    pub display_name: &'a str,
    pub color: &'a str,
    pub snake: &'a VecDeque<Cell>,
    pub score: i64,
    pub body_length: i64,
}

#[derive(Serialize)]
pub struct TickDrop<'a> {
    pub id: &'a str,
    pub x: i32,
    pub y: i32,
    pub ttl: u64,
}

#[derive(Serialize)]
pub struct TickGolden {
    pub x: i32,
    pub y: i32,
    pub ttl: u64,
}

#[derive(Serialize)]
pub struct TickWorld<'a> {
    pub players: Vec<TickPlayer<'a>>,
    pub bonus: &'a [Cell],
    pub drops: Vec<TickDrop<'a>>,
    pub golden: Option<TickGolden>,
}

pub fn game_tick(world: &TickWorld<'_>) -> String {
    event("gameTick", world)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LobbyStats<'a> {
    pub id: &'a str,
    pub players: usize,
    pub drops: usize,
    pub bonus: usize,
    pub golden: bool,
    pub last_tick_ms: f64,
    pub avg_tick_ms: f64,
    pub max_tick_ms: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats<'a> {
    pub rss: u64,
    pub uptime: f64,
    pub total_players: usize,
    pub lobbies: Vec<LobbyStats<'a>>,
}

pub fn stats(stats: &Stats<'_>) -> String {
    serde_json::to_string(stats).expect("serializing debug stats cannot fail")
}
