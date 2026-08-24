//! Minimal recursive-descent parser for inbound socket.io event frames.

/// Full JSON value model; some variants exist so the parser accepts any
/// well-formed payload (hostile or otherwise) without crashing.
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }
}

// ------------------------------- parser ------------------------------------

pub fn parse(s: &str) -> Result<Json, ()> {
    let b = s.as_bytes();
    let mut i = 0usize;
    let v = parse_value(b, &mut i, 0)?;
    skip_ws(b, &mut i);
    if i != b.len() {
        return Err(());
    }
    Ok(v)
}

fn skip_ws(b: &[u8], i: &mut usize) {
    while *i < b.len() && matches!(b[*i], b' ' | b'\t' | b'\n' | b'\r') {
        *i += 1;
    }
}

fn parse_value(b: &[u8], i: &mut usize, depth: usize) -> Result<Json, ()> {
    if depth > 100 {
        return Err(());
    }
    skip_ws(b, i);
    match b.get(*i).copied() {
        None => Err(()),
        Some(b'n') => lit(b, i, b"null", Json::Null),
        Some(b't') => lit(b, i, b"true", Json::Bool(true)),
        Some(b'f') => lit(b, i, b"false", Json::Bool(false)),
        Some(b'"') => Ok(Json::Str(parse_string(b, i)?)),
        Some(b'[') => {
            *i += 1;
            let mut arr = Vec::new();
            skip_ws(b, i);
            if b.get(*i) == Some(&b']') {
                *i += 1;
                return Ok(Json::Arr(arr));
            }
            loop {
                arr.push(parse_value(b, i, depth + 1)?);
                skip_ws(b, i);
                match b.get(*i) {
                    Some(b',') => *i += 1,
                    Some(b']') => {
                        *i += 1;
                        return Ok(Json::Arr(arr));
                    }
                    _ => return Err(()),
                }
            }
        }
        Some(b'{') => {
            *i += 1;
            let mut obj = Vec::new();
            skip_ws(b, i);
            if b.get(*i) == Some(&b'}') {
                *i += 1;
                return Ok(Json::Obj(obj));
            }
            loop {
                skip_ws(b, i);
                let key = parse_string(b, i)?;
                skip_ws(b, i);
                if b.get(*i) != Some(&b':') {
                    return Err(());
                }
                *i += 1;
                let val = parse_value(b, i, depth + 1)?;
                obj.push((key, val));
                skip_ws(b, i);
                match b.get(*i) {
                    Some(b',') => *i += 1,
                    Some(b'}') => {
                        *i += 1;
                        return Ok(Json::Obj(obj));
                    }
                    _ => return Err(()),
                }
            }
        }
        Some(_) => parse_number(b, i),
    }
}

fn lit(b: &[u8], i: &mut usize, word: &[u8], v: Json) -> Result<Json, ()> {
    if b.len() >= *i + word.len() && &b[*i..*i + word.len()] == word {
        *i += word.len();
        Ok(v)
    } else {
        Err(())
    }
}

fn parse_hex4(b: &[u8], i: &mut usize) -> Result<u32, ()> {
    if *i + 4 > b.len() {
        return Err(());
    }
    let mut v = 0u32;
    for k in 0..4 {
        let c = b[*i + k];
        let d = match c {
            b'0'..=b'9' => (c - b'0') as u32,
            b'a'..=b'f' => (c - b'a' + 10) as u32,
            b'A'..=b'F' => (c - b'A' + 10) as u32,
            _ => return Err(()),
        };
        v = (v << 4) | d;
    }
    *i += 4;
    Ok(v)
}

fn parse_string(b: &[u8], i: &mut usize) -> Result<String, ()> {
    if b.get(*i) != Some(&b'"') {
        return Err(());
    }
    *i += 1;
    let mut out = String::new();
    loop {
        let c = *b.get(*i).ok_or(())?;
        *i += 1;
        match c {
            b'"' => return Ok(out),
            b'\\' => {
                let e = *b.get(*i).ok_or(())?;
                *i += 1;
                match e {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{08}'),
                    b'f' => out.push('\u{0c}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        let mut u = parse_hex4(b, i)?;
                        if (0xD800..=0xDBFF).contains(&u) {
                            // High surrogate; expect \uDC00-\uDFFF low pair.
                            if b.get(*i) == Some(&b'\\') && b.get(*i + 1) == Some(&b'u') {
                                *i += 2;
                                let lo = parse_hex4(b, i)?;
                                if (0xDC00..=0xDFFF).contains(&lo) {
                                    u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                                } else {
                                    return Err(());
                                }
                            } else {
                                out.push('\u{FFFD}');
                                continue;
                            }
                        } else if (0xDC00..=0xDFFF).contains(&u) {
                            out.push('\u{FFFD}');
                            continue;
                        }
                        out.push(char::from_u32(u).unwrap_or('\u{FFFD}'));
                    }
                    _ => return Err(()),
                }
            }
            _ => {
                // Re-assemble multi-byte UTF-8 sequences byte by byte.
                let len = utf8_len(c);
                if len == 0 || *i - 1 + len > b.len() {
                    return Err(());
                }
                let start = *i - 1;
                *i += len - 1;
                let s = std::str::from_utf8(&b[start..start + len]).map_err(|_| ())?;
                out.push_str(s);
            }
        }
    }
}

fn utf8_len(first: u8) -> usize {
    match first {
        0x00..=0x7F => 1,
        0xC2..=0xDF => 2,
        0xE0..=0xEF => 3,
        0xF0..=0xF4 => 4,
        _ => 0,
    }
}

fn parse_number(b: &[u8], i: &mut usize) -> Result<Json, ()> {
    let start = *i;
    if b.get(*i) == Some(&b'-') {
        *i += 1;
    }
    while matches!(
        b.get(*i),
        Some(b'0'..=b'9') | Some(b'.') | Some(b'e') | Some(b'E') | Some(b'+') | Some(b'-')
    ) {
        *i += 1;
    }
    let txt = std::str::from_utf8(&b[start..*i]).map_err(|_| ())?;
    txt.parse::<f64>().map(Json::Num).map_err(|_| ())
}
