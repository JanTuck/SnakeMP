package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	wsGUID      = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	maxFrameLen = 1 << 20 // 1 MiB inbound frame cap

	wsOpCont   = 0x0
	wsOpText   = 0x1
	wsOpBinary = 0x2
	wsOpClose  = 0x8
	wsOpPing   = 0x9
	wsOpPong   = 0xA

	pingInterval    = 20 * time.Second // engine.io v3 pingInterval advertised
	pingTimeout     = 15 * time.Second // engine.io v3 pingTimeout advertised
	readIdleTimeout = 90 * time.Second // hard cap on a fully silent TCP peer

	outboxSize = 512 // frames; slow consumers beyond this are dropped
)

// Conn is one engine.io v3 / socket.io v2 session over a hijacked TCP conn.
// player/lobbyID are guarded by World.mu; everything else by its own lifecycle.
type Conn struct {
	id       string
	nc       net.Conn
	br       *bufio.Reader
	out      chan []byte // complete socket.io/engine.io payloads as text frames
	ctl      chan ctlFrame
	dead     chan struct{}
	killOnce sync.Once
	wmu      sync.Mutex // serializes raw frame writes
	lastRecv atomic.Int64

	world *World

	player  *Player // guarded by world.mu
	lobbyID string  // guarded by world.mu
}

type ctlFrame struct {
	op   byte
	data []byte
}

func (c *Conn) touch() { c.lastRecv.Store(time.Now().UnixNano()) }

func (c *Conn) kill() {
	c.killOnce.Do(func() {
		close(c.dead)
		c.nc.Close()
	})
}

func (c *Conn) writeFrameSafe(op byte, payload []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return writeWSFrame(c.nc, op, payload)
}

// trySendFrame enqueues a text frame; a full outbox marks the connection as a
// slow consumer and it is dropped (keeps memory bounded under load).
func trySendFrame(c *Conn, frame []byte) {
	select {
	case c.out <- frame:
	default:
		c.kill()
	}
}

func SendTo(c *Conn, event string, arg any) { trySendFrame(c, SioEvent(event, arg)) }

func BroadcastFrame(l *Lobby, frame []byte) {
	for _, m := range l.members {
		trySendFrame(m, frame)
	}
}

func SendFeed(l *Lobby, obj any) { BroadcastFrame(l, SioEvent("feed", obj)) }

// SioEvent builds a socket.io v2 EVENT frame: 42["name",arg].
func SioEvent(name string, arg any) []byte {
	b := marshalNoEsc([]any{name, arg})
	out := make([]byte, 0, len(b)+2)
	out = append(out, '4', '2')
	return append(out, b...)
}

func openPacket(sid string) []byte {
	return []byte(fmt.Sprintf(
		"0{\"sid\":\"%s\",\"upgrades\":[],\"pingInterval\":20000,\"pingTimeout\":15000}", sid))
}

// ---------------------------------------------------------------------------
// HTTP upgrade + session pumps.

func (s *Server) HandleSocketIO(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	q := r.URL.Query()
	if q.Get("transport") != "websocket" {
		// Only the websocket transport is implemented (SPEC §Wire protocol).
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"code":3,"message":"unsupported transport"}`))
		return
	}
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
		!connectionHasUpgrade(r.Header.Get("Connection")) {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	nc, brw, err := hj.Hijack()
	if err != nil {
		return
	}
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + acceptKey(key) + "\r\n\r\n"
	if _, err := nc.Write([]byte(resp)); err != nil {
		nc.Close()
		return
	}
	if tc, ok := nc.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}

	c := &Conn{
		id:    NewSID(),
		nc:    nc,
		br:    brw.Reader,
		out:   make(chan []byte, outboxSize),
		ctl:   make(chan ctlFrame, 16),
		dead:  make(chan struct{}),
		world: s.world,
	}
	c.touch()
	go c.writePump()
	go c.readPump()

	// engine.io open packet followed by the socket.io namespace CONNECT.
	trySendFrame(c, openPacket(c.id))
	trySendFrame(c, []byte("40"))
}

func connectionHasUpgrade(h string) bool {
	for _, part := range strings.Split(h, ",") {
		if strings.EqualFold(strings.TrimSpace(part), "Upgrade") {
			return true
		}
	}
	return false
}

func acceptKey(key string) string {
	h := sha1.New()
	h.Write([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// NewSID returns an engine.io-style session id: 16 random bytes, base64url,
// i.e. 22 chars of [A-Za-z0-9_-].
func NewSID() string {
	var b [16]byte
	rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}

func (c *Conn) writePump() {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.dead:
			return
		case f := <-c.out:
			if err := c.writeFrameSafe(wsOpText, f); err != nil {
				c.kill()
				return
			}
		case cf := <-c.ctl:
			if err := c.writeFrameSafe(cf.op, cf.data); err != nil {
				c.kill()
				return
			}
		case <-ticker.C:
			age := time.Since(time.Unix(0, c.lastRecv.Load()))
			if age > pingInterval+pingTimeout {
				c.kill() // no pong within pingTimeout: close
				return
			}
			if err := c.writeFrameSafe(wsOpText, []byte("2")); err != nil {
				c.kill()
				return
			}
		}
	}
}

func (c *Conn) readPump() {
	defer func() {
		c.kill()
		c.world.Disconnect(c)
	}()

	var (
		fragOp byte
		frag   []byte
	)
	for {
		c.nc.SetReadDeadline(time.Now().Add(readIdleTimeout))
		op, data, fin, err := readWSFrame(c.br)
		if err != nil {
			return
		}
		if os.Getenv("SNEK_WS_DEBUG") == "1" {
		}
		switch op {
		case wsOpClose:
			echo := data
			if len(echo) > 125 {
				echo = echo[:125]
			}
			_ = c.writeFrameSafe(wsOpClose, echo) // RFC: echo close, then go away
			return
		case wsOpPing:
			c.touch()
			select {
			case c.ctl <- ctlFrame{op: wsOpPong, data: data}:
			default:
				c.kill()
				return
			}
		case wsOpPong:
			c.touch() // resets the heartbeat timer per SPEC
		case wsOpBinary:
			c.touch() // tolerated, ignored
		case wsOpText:
			c.touch()
			if fin {
				c.handleMessage(data)
			} else {
				fragOp, frag = op, append([]byte(nil), data...)
			}
		case wsOpCont:
			if fragOp == 0 {
				return // continuation without a started message
			}
			frag = append(frag, data...)
			if fin {
				msg := frag
				fragOp, frag = 0, nil
				c.handleMessage(msg)
			}
		default:
			return
		}
	}
}

// handleMessage dispatches engine.io packets: 2 ping, 3 pong, 4 message.
func (c *Conn) handleMessage(b []byte) {
	if os.Getenv("SNEK_WS_DEBUG") == "1" {
	}
	if len(b) == 0 {
		return
	}
	switch b[0] {
	case '2': // client-initiated engine ping -> pong
		trySendFrame(c, []byte("3"))
	case '3': // engine pong (heartbeat already recorded via touch)
	case '4':
		c.handleSIO(b[1:])
	}
}

// handleSIO dispatches socket.io v2 packets carried in engine messages:
// 40 CONNECT, 41 DISCONNECT, 42 EVENT.
func (c *Conn) handleSIO(b []byte) {
	if len(b) == 0 {
		return
	}
	switch b[0] {
	case '0':
		// Namespace CONNECT from the client; the default namespace was
		// connected server-side already, nothing to do.
	case '1':
		c.kill() // namespace disconnect == end of session here
	case '2':
		// EVENT. Must be 42[...json array...]; other namespaces ignored.
		if len(b) < 3 || b[1] != '[' {
			return
		}
		var ev []any
		if err := json.Unmarshal(b[1:], &ev); err != nil { // JSON array follows the type digit
			return
		}
		if len(ev) == 0 {
			return
		}
		name, _ := ev[0].(string)
		args := ev[min(1, len(ev)):]
		switch name {
		case "clientReady":
			c.world.ClientReady(c, args)
		case "keyPress":
			var data any
			if len(args) > 0 {
				data = args[0]
			}
			c.world.KeyPress(c, data)
		}
	}
}

// ---------------------------------------------------------------------------
// WebSocket framing (RFC 6455 subset sufficient for engine.io v3).

// readWSFrame reads one frame, unmasks client payload, and reports FIN.
func readWSFrame(br *bufio.Reader) (opcode byte, payload []byte, fin bool, err error) {
	var hdr [8]byte
	if _, err = ioReadFull(br, hdr[:2]); err != nil {
		return
	}
	fin = hdr[0]&0x80 != 0
	opcode = hdr[0] & 0x0f
	masked := hdr[1]&0x80 != 0
	length := uint64(hdr[1] & 0x7f)
	switch length {
	case 126:
		if _, err = ioReadFull(br, hdr[:2]); err != nil {
			return
		}
		length = uint64(binary.BigEndian.Uint16(hdr[:2]))
	case 127:
		if _, err = ioReadFull(br, hdr[:8]); err != nil {
			return
		}
		length = binary.BigEndian.Uint64(hdr[:8])
		if length&(1<<63) != 0 {
			err = errProtocol
			return
		}
	}
	if length > maxFrameLen {
		err = errTooLarge
		return
	}
	var mk []byte
	if masked {
		mk = make([]byte, 4)
		if _, err = ioReadFull(br, mk); err != nil { // masking key precedes payload (RFC 6455 §5.3)
			return
		}
	}
	payload = make([]byte, length)
	if _, err = ioReadFull(br, payload); err != nil {
		return
	}
	if masked {
		for i := range payload {
			payload[i] ^= mk[i&3]
		}
	}
	return
}

var errProtocol = fmt.Errorf("websocket protocol error")
var errTooLarge = fmt.Errorf("frame too large")

func ioReadFull(r *bufio.Reader, buf []byte) (int, error) {
	n := 0
	for n < len(buf) {
		nn, err := r.Read(buf[n:])
		n += nn
		if err != nil {
			return n, err
		}
	}
	return n, nil
}

// writeWSFrame writes one unmasked server frame (single Write per frame).
func writeWSFrame(w net.Conn, op byte, payload []byte) error {
	n := len(payload)
	hdr := make([]byte, 0, 10)
	hdr = append(hdr, 0x80|op)
	switch {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n < 65536:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		ext := make([]byte, 8)
		binary.BigEndian.PutUint64(ext, uint64(n))
		hdr = append(hdr, 127)
		hdr = append(hdr, ext...)
	}
	buf := make([]byte, 0, len(hdr)+n)
	buf = append(buf, hdr...)
	buf = append(buf, payload...)
	_, err := w.Write(buf)
	return err
}
