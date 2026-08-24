//! WebSocket (RFC 6455) server-side codec plus the engine.io v3 /
//! socket.io v2 session layer, per SPEC wire protocol section.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::base64;
use crate::http::Req;
use crate::json::Json;
use crate::rng;
use crate::sha1;

pub const PING_INTERVAL_MS: u64 = 20_000;
pub const PING_TIMEOUT_MS: u64 = 15_000;
const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;
const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Messages sent from readers/game threads to a connection writer thread.
pub enum Out {
    /// Full wire payload of an engine.io text packet, e.g. "42[\"init\",...]".
    Text(String),
    /// Reader saw an engine.io pong ('3') - reset the ping timeout.
    GotPong,
    /// Reader saw an engine.io ping ('2') - reply with '3'.
    ReplyPong,
    /// Reply to a WebSocket-level ping.
    WsPong(Vec<u8>),
    /// Echo the peer close code and finish.
    CloseEcho(Vec<u8>),
    Close,
}

type Registry = Arc<Mutex<HashMap<String, Sender<Out>>>>;

fn registry() -> Registry {
    static REG: std::sync::OnceLock<Registry> = std::sync::OnceLock::new();
    REG.get_or_init(|| Arc::new(Mutex::new(HashMap::new())))
        .clone()
}

fn game() -> &'static Mutex<crate::game::GameServer> {
    static G: std::sync::OnceLock<Mutex<crate::game::GameServer>> = std::sync::OnceLock::new();
    G.get_or_init(|| Mutex::new(crate::game::GameServer::new()))
}

fn dispatch(out: Vec<crate::game::OutMsg>, reg: &Registry) {
    if out.is_empty() {
        return;
    }
    let reg = reg.lock().unwrap_or_else(|e| e.into_inner());
    for (sid, payload) in out {
        if let Some(tx) = reg.get(&sid) {
            let _ = tx.send(Out::Text(payload));
        }
    }
}

pub fn with_game<T>(f: impl FnOnce(&mut crate::game::GameServer) -> T) -> T {
    let mut g = game().lock().unwrap_or_else(|e| e.into_inner());
    f(&mut g)
}

fn compute_accept(key: &str) -> String {
    base64::encode_std(&sha1::sha1(format!("{}{}", key, WS_GUID).as_bytes()))
}

// ------------------------------ frame codec ---------------------------------

struct Frame {
    opcode: u8,
    fin: bool,
    payload: Vec<u8>,
}

fn read_frame(r: &mut dyn BufRead) -> std::io::Result<Option<Frame>> {
    let mut hdr = [0u8; 2];
    match r.read_exact(&mut hdr) {
        Ok(_) => {}
        Err(e) => return Err(e),
    }
    let fin = hdr[0] & 0x80 != 0;
    let rsv = hdr[0] & 0x70;
    let opcode = hdr[0] & 0x0F;
    let masked = hdr[1] & 0x80 != 0;
    let mut len = (hdr[1] & 0x7F) as usize;
    if rsv != 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "rsv bits set",
        ));
    }
    if len == 126 {
        let mut ext = [0u8; 2];
        r.read_exact(&mut ext)?;
        len = u16::from_be_bytes(ext) as usize;
    } else if len == 127 {
        let mut ext = [0u8; 8];
        r.read_exact(&mut ext)?;
        len = u64::from_be_bytes(ext) as usize;
    }
    if len > MAX_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    let mask = if masked {
        let mut m = [0u8; 4];
        r.read_exact(&mut m)?;
        Some(m)
    } else {
        None
    };
    let mut payload = vec![0u8; len];
    if len > 0 {
        r.read_exact(&mut payload)?;
    }
    if let Some(m) = mask {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= m[i % 4];
        }
    }
    Ok(Some(Frame {
        opcode,
        fin,
        payload,
    }))
}

fn write_frame(w: &mut TcpStream, opcode: u8, payload: &[u8]) -> std::io::Result<()> {
    let mut head = Vec::with_capacity(10);
    head.push(0x80 | opcode);
    let len = payload.len();
    if len < 126 {
        head.push(len as u8);
    } else if len <= u16::MAX as usize {
        head.push(126);
        head.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        head.push(127);
        head.extend_from_slice(&(len as u64).to_be_bytes());
    }
    w.write_all(&head)?;
    w.write_all(payload)?;
    w.flush()
}

// ------------------------------ session -------------------------------------

/// Handle a GET /socket.io/?EIO=3&transport=websocket upgrade for this
/// connection. Takes ownership of the stream; returns when the socket dies.
pub fn run_session(mut sock: TcpStream, reader: &mut dyn BufRead, req: &Req) {
    let key = match req.header("sec-websocket-key") {
        Some(k) if !k.is_empty() => k.to_string(),
        _ => return,
    };
    let accept = compute_accept(&key);
    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
        accept
    );
    if sock.write_all(resp.as_bytes()).is_err() {
        return;
    }

    let mut writer_sock = match sock.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };

    let sid = {
        let mut r = rng::global().lock().unwrap_or_else(|e| e.into_inner());
        r.sid()
    };
    let (tx, rx) = channel::<Out>();

    // Writer thread: the ONLY place frames are written once the session runs.
    let writer = std::thread::Builder::new()
        .name("ws-writer".into())
        .stack_size(128 * 1024)
        .spawn(move || {
            // Engine.io v3 semantics (matching the reference stack): the
            // client pings every interval and ANY inbound packet proves
            // liveness; a silent peer is closed after interval+timeout.
            // We additionally emit our own "2" every interval (SPEC §Wire).
            let mut last_ping = Instant::now();
            let mut last_seen = Instant::now();
            loop {
                let now = Instant::now();
                if now.duration_since(last_ping) >= Duration::from_millis(PING_INTERVAL_MS) {
                    if write_frame(&mut writer_sock, 0x1, b"2").is_err() {
                        break;
                    }
                    last_ping = now;
                }
                if now.duration_since(last_seen)
                    >= Duration::from_millis(PING_INTERVAL_MS + PING_TIMEOUT_MS)
                {
                    let _ = write_frame(&mut writer_sock, 0x8, &[0x03, 0xE8]);
                    break;
                }
                match rx.recv_timeout(Duration::from_millis(50)) {
                    Ok(Out::Text(payload)) => {
                        if write_frame(&mut writer_sock, 0x1, payload.as_bytes()).is_err() {
                            break;
                        }
                    }
                    Ok(Out::GotPong) => last_seen = Instant::now(),
                    Ok(Out::ReplyPong) => {
                        if write_frame(&mut writer_sock, 0x1, b"3").is_err() {
                            break;
                        }
                    }
                    Ok(Out::WsPong(p)) => {
                        if write_frame(&mut writer_sock, 0xA, &p).is_err() {
                            break;
                        }
                    }
                    Ok(Out::CloseEcho(code)) => {
                        let _ = write_frame(&mut writer_sock, 0x8, &code);
                        break;
                    }
                    Ok(Out::Close) | Err(RecvTimeoutError::Disconnected) => {
                        let _ = write_frame(&mut writer_sock, 0x8, &[0x03, 0xE8]);
                        break;
                    }
                    Err(RecvTimeoutError::Timeout) => continue,
                }
            }
            let _ = writer_sock.shutdown(Shutdown::Both);
        });
    if writer.is_err() {
        return;
    }

    // Register before anything can be sent to this sid.
    registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(sid.clone(), tx.clone());

    // Engine.io open packet, then the socket.io CONNECT frame.
    let open_packet = format!(
        "0{{\"sid\":\"{}\",\"upgrades\":[],\"pingInterval\":{},\"pingTimeout\":{}}}",
        sid, PING_INTERVAL_MS, PING_TIMEOUT_MS
    );
    let _ = tx.send(Out::Text(open_packet));
    let _ = tx.send(Out::Text("40".to_string()));

    // ---- reader loop (this thread) ----
    let mut frag: Vec<u8> = Vec::new();
    'read: while let Ok(Some(frame)) = read_frame(reader) {
        match frame.opcode {
            0x0 => {
                frag.extend_from_slice(&frame.payload);
                if frame.fin {
                    let text = String::from_utf8_lossy(&frag).into_owned();
                    frag.clear();
                    if handle_text(&tx, &sid, &text) == Flow::Stop {
                        break 'read;
                    }
                } else if frag.len() > MAX_FRAME_BYTES {
                    break 'read;
                }
            }
            0x1 | 0x2 => {
                let text = String::from_utf8_lossy(&frame.payload).into_owned();
                if frame.fin {
                    if handle_text(&tx, &sid, &text) == Flow::Stop {
                        break 'read;
                    }
                } else {
                    frag = text.into_bytes();
                }
            }
            0x8 => {
                let code: Vec<u8> = if frame.payload.len() >= 2 {
                    frame.payload[..2].to_vec()
                } else {
                    vec![0x03, 0xE8]
                };
                let _ = tx.send(Out::CloseEcho(code));
                break 'read;
            }
            0x9 => {
                let _ = tx.send(Out::WsPong(frame.payload));
            }
            0xA => {}
            _ => {}
        }
    }

    // ---- cleanup ----
    registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&sid);
    with_game(|g| g.mark_closed(&sid));
    let _ = tx.send(Out::Close);
    drop(tx);
    let _ = sock.shutdown(Shutdown::Both); // wakes the blocked read
}

#[derive(PartialEq)]
enum Flow {
    Continue,
    Stop,
}

/// Process one engine.io text packet. Returns Stop when the session must end.
fn handle_text(tx: &Sender<Out>, sid: &str, text: &str) -> Flow {
    let Some(first) = text.bytes().next() else {
        return Flow::Continue;
    };
    // Any inbound engine.io packet is a sign of life (engine.io v3 server
    // behaviour). The reply mapping below follows the packet type.
    let _ = tx.send(Out::GotPong);
    match first {
        b'2' => {
            let _ = tx.send(Out::ReplyPong);
            Flow::Continue
        }
        b'3' => {
            let _ = tx.send(Out::GotPong);
            Flow::Continue
        }
        b'4' => handle_message(sid, &text[1..]),
        _ => Flow::Continue,
    }
}

fn handle_message(sid: &str, rest: &str) -> Flow {
    let Some(second) = rest.bytes().next() else {
        return Flow::Continue;
    };
    match second {
        b'0' => Flow::Continue, // client nsp CONNECT; we already answered
        b'1' => Flow::Stop,     // client nsp DISCONNECT: treat the session as over
        b'2' => {
            // Event: 42["name",arg,...]; tolerate an ack id between 42 and [.
            let payload = &rest[1..];
            let Some(pos) = payload.find('[') else {
                return Flow::Continue;
            };
            let arr = match crate::json::parse(&payload[pos..]) {
                Ok(Json::Arr(a)) => a,
                _ => return Flow::Continue,
            };
            let Some(name) = arr.first().and_then(|v| v.as_str()) else {
                return Flow::Continue;
            };
            let args: &[Json] = if arr.len() > 1 { &arr[1..] } else { &[] };
            let mut out: Vec<crate::game::OutMsg> = Vec::new();
            with_game(|g| g.handle_event(sid, name, args, &mut out));
            dispatch(out, &registry());
            Flow::Continue
        }
        _ => Flow::Continue,
    }
}

// --------------------- handles for main.rs / ticker --------------------------

pub type RegistryHandle = Registry;

pub fn registry_handle() -> RegistryHandle {
    registry().clone()
}

pub fn dispatch_handle(out: Vec<crate::game::OutMsg>, reg: &RegistryHandle) {
    dispatch(out, reg)
}
