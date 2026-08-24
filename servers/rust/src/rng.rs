//! xorshift64* PRNG seeded from the OS. Std-only.
use std::sync::Mutex;
use std::sync::OnceLock;

pub struct Rng {
    s: u64,
}

fn seed_from_os() -> u64 {
    use std::io::Read;
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let mut v = [0u8; 8];
        if f.read_exact(&mut v).is_ok() {
            let s = u64::from_le_bytes(v);
            if s != 0 {
                return s;
            }
        }
    }
    // Fallback: time + address entropy.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9E3779B97F4A7C15);
    let stack = &nanos as *const _ as u64;
    (nanos ^ stack.rotate_left(17) ^ (std::process::id() as u64) << 32) | 1
}

impl Rng {
    pub fn new() -> Self {
        let mut s = seed_from_os();
        if s == 0 {
            s = 0x9E3779B97F4A7C15;
        }
        Rng { s }
    }

    pub fn next_u64(&mut self) -> u64 {
        // xorshift64*
        let mut x = self.s;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.s = x;
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }

    /// Uniform float in [0, 1). (Kept for parity with Math.random uses.)
    #[allow(dead_code)]
    pub fn f64(&mut self) -> f64 {
        ((self.next_u64() >> 11) as f64) / ((1u64 << 53) as f64)
    }

    /// Uniform integer in [0, n). Callers guarantee n > 0.
    pub fn below(&mut self, n: u64) -> u64 {
        self.next_u64() % n
    }

    pub fn hex_color(&mut self) -> String {
        let v = self.next_u64();
        format!("#{:06x}", (v & 0xFFFFFF) as u32)
    }

    /// Lowercase base36 digits, like Math.random().toString(36).
    pub fn base36(&mut self, len: usize) -> String {
        const D: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
        let mut out = String::with_capacity(len);
        for _ in 0..len {
            out.push(D[self.below(36) as usize] as char);
        }
        out
    }

    /// engine.io-style sid: 16 random bytes, base64url, no padding (22 chars).
    pub fn sid(&mut self) -> String {
        crate::base64::encode_url_nopad(
            &self
                .next_u64()
                .to_le_bytes()
                .iter()
                .chain(self.next_u64().to_le_bytes().iter())
                .cloned()
                .collect::<Vec<u8>>(),
        )
    }
}

static RNG: OnceLock<Mutex<Rng>> = OnceLock::new();

pub fn global() -> &'static Mutex<Rng> {
    RNG.get_or_init(|| Mutex::new(Rng::new()))
}
