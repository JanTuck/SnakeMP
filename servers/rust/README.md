# Rust server

The Rust implementation keeps HTTP, WebSocket framing, game simulation, JSON
parsing, typed wire serialization, randomness, and cryptographic helpers in
separate modules. Outbound protocol payloads use `serde`/`serde_json`; the small
custom JSON module is only for tolerant inbound Socket.IO parsing.

The canonical `client/` assets are embedded directly with `include_bytes!`.

```bash
cargo build --release --manifest-path servers/rust/Cargo.toml
PORT=3000 SNEK_DEBUG=1 servers/rust/target/release/snek-rust
```
