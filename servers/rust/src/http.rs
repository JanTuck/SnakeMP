//! Minimal HTTP/1.1 server-side plumbing: request parsing, response writing,
//! keep-alive, security headers. Std-only.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::net::TcpStream;

const MAX_HEADER_BYTES: usize = 32 * 1024;
const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;

pub struct Req {
    pub method: String,
    pub path: String,  // raw path, no query
    pub query: String, // raw query (no '?')
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
    pub version11: bool,
}

impl Req {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(|s| s.as_str())
    }

    pub fn query_param(&self, key: &str) -> Option<String> {
        for pair in self.query.split('&') {
            let mut it = pair.splitn(2, '=');
            let k = it.next().unwrap_or("");
            if k == key {
                return Some(decode_component(it.next().unwrap_or(""), true));
            }
        }
        None
    }
}

/// Read one request. Ok(None) on clean EOF before any bytes.
pub fn read_request(r: &mut dyn BufRead) -> std::io::Result<Option<Req>> {
    let mut line = String::new();
    // Skip stray blank lines between pipelined requests (RFC allows CRLF).
    loop {
        line.clear();
        let n = r.read_line(&mut line)?;
        if n == 0 {
            return Ok(None);
        }
        if !line.trim().is_empty() {
            break;
        }
    }
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("").to_ascii_uppercase();
    let target = parts.next().unwrap_or("/").to_string();
    let version = parts.next().unwrap_or("HTTP/1.1").to_string();

    let mut headers = HashMap::new();
    let mut total = 0usize;
    loop {
        let mut h = String::new();
        let n = r.read_line(&mut h)?;
        if n == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "eof in headers",
            ));
        }
        total += n;
        if total > MAX_HEADER_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "headers too large",
            ));
        }
        let t = h.trim_end_matches(['\u{000D}', '\u{000A}']);
        if t.is_empty() {
            break;
        }
        if let Some((k, v)) = t.split_once(':') {
            headers
                .entry(k.trim().to_ascii_lowercase())
                .or_insert_with(|| v.trim().to_string());
        }
    }

    let mut body = Vec::new();
    if let Some(cl) = headers.get("content-length") {
        if let Ok(len) = cl.parse::<usize>() {
            if len <= MAX_BODY_BYTES {
                body.resize(len, 0);
                r.read_exact(&mut body)?;
            }
        }
    }

    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target, String::new()),
    };

    Ok(Some(Req {
        method,
        path,
        query,
        headers,
        body,
        version11: version != "HTTP/1.0",
    }))
}

pub struct Resp {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Vec<u8>,
    pub extra_headers: Vec<(String, String)>,
}

impl Resp {
    pub fn text(status: u16, body: &str) -> Resp {
        Resp {
            status,
            content_type: "text/plain; charset=utf-8",
            body: body.as_bytes().to_vec(),
            extra_headers: Vec::new(),
        }
    }

    #[allow(dead_code)]
    pub fn html(status: u16, body: &[u8]) -> Resp {
        Resp {
            status,
            content_type: "text/html; charset=utf-8",
            body: body.to_vec(),
            extra_headers: Vec::new(),
        }
    }

    pub fn redirect(status: u16, location: &str) -> Resp {
        let extra = vec![("Location".to_string(), location.to_string())];
        let body = format!("Redirecting to {}...", location);
        Resp {
            status,
            content_type: "text/plain; charset=utf-8",
            body: body.into_bytes(),
            extra_headers: extra,
        }
    }

    pub fn json(status: u16, body: &str) -> Resp {
        Resp {
            status,
            content_type: "application/json; charset=utf-8",
            body: body.as_bytes().to_vec(),
            extra_headers: Vec::new(),
        }
    }

    pub fn bytes(status: u16, ctype: &'static str, body: &'static [u8]) -> Resp {
        Resp {
            status,
            content_type: ctype,
            body: body.to_vec(),
            extra_headers: Vec::new(),
        }
    }
}

pub fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        302 => "Found",
        303 => "See Other",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "OK",
    }
}

/// Write a response with the mandatory security headers. HEAD sends headers only.
pub fn write_resp(s: &mut TcpStream, req: &Req, resp: &Resp) -> std::io::Result<()> {
    let keep_alive = match req.header("connection") {
        Some(v) if v.eq_ignore_ascii_case("close") => false,
        _ => true, // HTTP/1.1 default; tolerate 1.0 keep-alive requests too
    };
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: {}\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n",
        resp.status,
        reason(resp.status),
        resp.content_type,
        resp.body.len(),
        if keep_alive { "keep-alive" } else { "close" }
    );
    for (k, v) in &resp.extra_headers {
        head.push_str(k);
        head.push_str(": ");
        head.push_str(v);
        head.push_str("\r\n");
    }
    head.push_str("\r\n");
    s.write_all(head.as_bytes())?;
    if req.method != "HEAD" {
        s.write_all(&resp.body)?;
    }
    s.flush()
}

// ------------------------------ decoding ------------------------------------

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// Percent-decode. With plus_as_space=true also map '+' to ' ' (form encoding).
pub fn decode_component(s: &str, plus_as_space: bool) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                if let (Some(h), Some(l)) = (hex_val(b[i + 1]), hex_val(b[i + 2])) {
                    out.push((h << 4) | l);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' if plus_as_space => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Parse application/x-www-form-urlencoded body, first value wins.
pub fn form_value(body: &[u8], key: &str) -> Option<String> {
    let s = std::str::from_utf8(body).ok()?;
    for pair in s.split('&') {
        let mut it = pair.splitn(2, '=');
        if it.next()? == key {
            return Some(decode_component(it.next().unwrap_or(""), true));
        }
    }
    None
}
