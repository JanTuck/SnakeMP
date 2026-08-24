package main

import (
	"math"
	"math/rand/v2"
	"slices"
	"strconv"
	"sync"
	"time"
)

const (
	MaxPlayersGlobal   = 100
	MaxPlayersPerLobby = 16
	LobbyIdleDeleteMs  = 60000
	DefaultLobbyID     = "12345"

	BonusCap     = 12
	DropTTLms    = 25000
	GoldenTTLms  = 12000
	DropPoints   = 2
	DropGrowth   = 2
	DropApples   = 4
	GoldenPoints = 3

	// TickEvery = 1000ms / 15 == 66.67ms (15 fps).
	TickEvery = time.Minute / 900

	// Pickup scheduling, mirroring app.js: first schedule 8s/20s after the
	// first observed tick; later drops every 12-20s (max 2 alive) and golden
	// apples every 25-40s (one at a time).
	firstDropDelay   = 8000
	firstGoldenDelay = 20000
	dropMinGap       = 12000
	dropGapJitter    = 8000
	goldenMinGap     = 25000
	goldenGapJitter  = 15000
)

// Exact game_error messages.
const (
	ErrInvalidUsername = "Invalid username"
	ErrUnknownGame     = "That game does not exist any more"
	ErrServerFull      = "Server is full, try again later"
	ErrLobbyFull       = "This game is full"
)

type Drop struct {
	ID        string
	Pos       Cell
	ExpiresAt int64 // unix ms
}

// Lobby is one isolated arena: own players, pickups, timers and broadcast room.
type Lobby struct {
	ID           string
	members      []*Conn   // sockets currently in room lobby:<id> (joined players)
	players      []*Player // insertion order matters for tick iteration
	food         Cell
	bonus        []Cell
	drops        []*Drop
	golden       *Drop // nil when absent
	nextDropAt   int64
	nextGoldenAt int64
	dropSeq      int
	lastEmptyAt  int64
	lastTickMs   float64
	avgTickMs    float64
	maxTickMs    float64
	ticks        int64
}

// World is the whole game state behind a single mutex; a master ticker
// iterates all lobbies at 66.67ms.
type World struct {
	mu      sync.Mutex
	lobbies map[string]*Lobby
	order   []*Lobby // creation order (stable stats/debug output)
}

func NewWorld() *World {
	w := &World{lobbies: make(map[string]*Lobby)}
	w.createLobbyLocked(DefaultLobbyID)
	return w
}

func (w *World) createLobbyLocked(id string) *Lobby {
	l := &Lobby{
		ID:      id,
		food:    randLoc(),
		dropSeq: 1,
	}
	w.lobbies[id] = l
	w.order = append(w.order, l)
	return l
}

func (w *World) CreateLobbyUnique() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	for {
		id := GenLobbyID()
		if _, taken := w.lobbies[id]; taken {
			continue
		}
		w.createLobbyLocked(id)
		return id
	}
}

func (w *World) LobbyExists(id string) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	_, ok := w.lobbies[id]
	return ok
}

func (w *World) totalPlayersLocked() int {
	n := 0
	for _, l := range w.order {
		n += len(l.players)
	}
	return n
}

// ---------------------------------------------------------------------------

// clientReady handles the join flow per SPEC: username validation, lobby
// existence, global-then-lobby caps, init emit, spawn, room join, join feed.
func (w *World) ClientReady(c *Conn, args []any) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if c.player != nil {
		return // already joined; same-socket rejoin only after death/disconnect
	}
	var userRaw any
	if len(args) > 0 {
		userRaw = args[0]
	}
	name, ok := ValidUsername(userRaw)
	if !ok {
		SendTo(c, "game_error", ErrInvalidUsername)
		return
	}
	var lobbyRaw any
	if len(args) > 1 {
		lobbyRaw = args[1]
	}
	lobbyID, _ := lobbyRaw.(string)
	l := w.lobbies[lobbyID]
	if l == nil {
		SendTo(c, "game_error", ErrUnknownGame)
		return
	}
	if w.totalPlayersLocked() >= MaxPlayersGlobal {
		SendTo(c, "game_error", ErrServerFull)
		return
	}
	if len(l.players) >= MaxPlayersPerLobby {
		SendTo(c, "game_error", ErrLobbyFull)
		return
	}

	SendTo(c, "init", InitPayload{Scale: GridSize, Food: l.food})

	pos := chooseSpawn(l)
	p := NewPlayer(c.id, name, NextColor(), pos, c)
	c.player = p
	c.lobbyID = l.ID
	l.members = append(l.members, c)
	l.players = append(l.players, p)
	SendFeed(l, map[string]any{"type": "join", "who": p.DisplayName})
}

func (w *World) KeyPress(c *Conn, data any) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if c.player == nil {
		return // cannot steer before joining
	}
	c.player.SetDirection(data)
}

// Disconnect removes the socket's player and broadcasts feed death (SPEC:
// "On socket close: remove the player, broadcast feed death"). Called exactly
// once per connection by its read pump.
func (w *World) Disconnect(c *Conn) {
	w.mu.Lock()
	defer w.mu.Unlock()
	handled := false
	if c.lobbyID != "" {
		if l := w.lobbies[c.lobbyID]; l != nil && c.player != nil {
			SendFeed(l, map[string]any{
				"type":  "death",
				"who":   c.player.DisplayName,
				"score": c.player.Score,
			})
			w.removePlayerLocked(l, c.player)
			handled = true
		}
	}
	if !handled {
		for _, l := range w.order {
			if i := slices.Index(l.members, c); i >= 0 {
				l.members = slices.Delete(l.members, i, i+1)
			}
		}
	}
	c.player = nil
	c.lobbyID = ""
}

func (w *World) removePlayerLocked(l *Lobby, p *Player) bool {
	found := false
	if i := slices.Index(l.players, p); i >= 0 {
		l.players = slices.Delete(l.players, i, i+1)
		found = true
	}
	if p.conn != nil {
		if i := slices.Index(l.members, p.conn); i >= 0 {
			l.members = slices.Delete(l.members, i, i+1)
		}
		p.conn.player = nil // allow same-socket rejoin (Retry without reload)
		p.conn.lobbyID = ""
	}
	return found
}

// Run drives the master game timer until stop is closed.
func (w *World) Run(stop <-chan struct{}) {
	next := time.Now().Add(TickEvery)
	for {
		if d := time.Until(next); d > 0 {
			select {
			case <-stop:
				return
			case <-time.After(d):
			}
		} else {
			next = time.Now().Add(TickEvery) // fell behind; resync
		}
		next = next.Add(TickEvery)
		w.TickAll()
	}
}

func (w *World) TickAll() {
	w.mu.Lock()
	defer w.mu.Unlock()

	now := time.Now().UnixMilli()
	var dead []*Lobby
	for _, l := range w.order {
		if l.ID != DefaultLobbyID && len(l.players) == 0 {
			if l.lastEmptyAt == 0 {
				l.lastEmptyAt = now
			}
			if now-l.lastEmptyAt > LobbyIdleDeleteMs {
				dead = append(dead, l)
				continue
			}
		}
		if len(l.players) > 0 {
			w.tickLobby(l, now)
		}
	}
	for _, l := range dead {
		delete(w.lobbies, l.ID)
		if i := slices.Index(w.order, l); i >= 0 {
			w.order = slices.Delete(w.order, i, i+1)
		}
	}
}

// tickLobby follows the reference order exactly:
// expire pickups, schedule spawns, then per player (insertion order):
// wall/self death -> head-vs-other mutual death -> food -> bonus ->
// golden -> drops -> apply one queued turn + move; finally broadcast gameTick.
func (w *World) tickLobby(l *Lobby, now int64) {
	t0 := time.Now()

	// 1. Expire drops/golden past their TTL.
	if len(l.drops) > 0 {
		kept := l.drops[:0]
		for _, d := range l.drops {
			if d.ExpiresAt > now {
				kept = append(kept, d)
			}
		}
		l.drops = kept
	}
	if l.golden != nil && l.golden.ExpiresAt <= now {
		l.golden = nil
	}

	// 2. Schedule supply drop (12-20s gap, max 2) and golden apple (25-40s,
	//    one at a time), at a free cell.
	if l.nextDropAt == 0 {
		l.nextDropAt = now + firstDropDelay
	}
	if l.nextGoldenAt == 0 {
		l.nextGoldenAt = now + firstGoldenDelay
	}
	if now >= l.nextDropAt && len(l.drops) < 2 {
		spawnDrop(l, now)
		l.nextDropAt = now + dropMinGap + rand.Int64N(dropGapJitter)
	}
	if now >= l.nextGoldenAt && l.golden == nil {
		spawnGolden(l, now)
		l.nextGoldenAt = now + goldenMinGap + rand.Int64N(goldenGapJitter)
	}

	// 3./4. Per player in insertion order; players killed earlier in this tick
	// are no longer in l.players and are skipped.
	type entry struct {
		c *Conn
		p *Player
	}
	snap := make([]entry, 0, len(l.members))
	for _, c := range l.members {
		if p := c.player; p != nil {
			snap = append(snap, entry{c, p})
		}
	}
	inLobby := func(p *Player) bool { return slices.Contains(l.players, p) }

	for _, e := range snap {
		p := e.p
		if !inLobby(p) {
			continue
		}

		// a. Wall or self collision.
		if p.Collided() {
			SendTo(e.c, "death", p.Score)
			SendFeed(l, map[string]any{"type": "death", "who": p.DisplayName, "score": p.Score})
			w.removePlayerLocked(l, p)
			continue
		}

		// b. Head vs any other snake segment: both die.
		if other := p.CollidedOther(l.players); other != nil {
			SendTo(e.c, "death", p.Score)
			if oc := other.conn; oc != nil {
				SendTo(oc, "death", other.Score)
			}
			SendFeed(l, map[string]any{"type": "death", "who": p.DisplayName, "score": p.Score})
			SendFeed(l, map[string]any{"type": "death", "who": other.DisplayName, "score": other.Score})
			w.removePlayerLocked(l, p)
			w.removePlayerLocked(l, other)
			continue
		}

		head := p.Snake[0]

		// c. Main food: +1/+1, respawn, updateFood broadcast.
		if head == l.food {
			p.Eat(1, 1)
			respawnFood(l)
			BroadcastFrame(l, SioEvent("updateFood", l.food))
		}

		// d. Bonus apples from opened crates (+1/+1 each, no expiry).
		for i := len(l.bonus) - 1; i >= 0; i-- {
			if l.bonus[i] == head {
				l.bonus = slices.Delete(l.bonus, i, i+1)
				p.Eat(1, 1)
			}
		}

		// e. Golden apple: +3 score, +1 growth.
		if l.golden != nil && head == l.golden.Pos {
			l.golden = nil
			p.Eat(GoldenPoints, 1)
			SendFeed(l, map[string]any{"type": "golden", "who": p.DisplayName, "points": GoldenPoints})
		}

		// f. Supply crate: +2/+2 and up to 4 bonus apples (cap 12 total).
		for i := len(l.drops) - 1; i >= 0; i-- {
			if l.drops[i].Pos == head {
				l.drops = slices.Delete(l.drops, i, i+1)
				openDrop(l, p)
			}
		}

		// g. One queued turn, then move (growth model inside).
		p.UpdatePosition()
	}

	// 5. Broadcast the world snapshot to everyone still in the room.
	BroadcastFrame(l, SioEvent("gameTick", buildTickPayload(l, now)))

	dur := float64(time.Since(t0).Nanoseconds()) / 1e6
	l.ticks++
	l.lastTickMs = dur
	l.avgTickMs += (dur - l.avgTickMs) / math.Min(float64(l.ticks), 200)
	l.maxTickMs = math.Max(l.maxTickMs, dur)
}

// ---------------------------------------------------------------------------
// Payload views.

type InitPayload struct {
	Scale int  `json:"scale"`
	Food  Cell `json:"food"`
}

type tickPlayer struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Color       string `json:"color"`
	Snake       []Cell `json:"snake"`
	Score       int    `json:"score"`
	BodyLength  int    `json:"bodyLength"`
}

type tickDrop struct {
	ID  string `json:"id"`
	X   int    `json:"x"`
	Y   int    `json:"y"`
	TTL int64  `json:"ttl"`
}

type tickGolden struct {
	X   int   `json:"x"`
	Y   int   `json:"y"`
	TTL int64 `json:"ttl"`
}

type tickWorld struct {
	Players []tickPlayer `json:"players"`
	Bonus   []Cell       `json:"bonus"`
	Drops   []tickDrop   `json:"drops"`
	Golden  *tickGolden  `json:"golden"` // must stay present as null when absent
}

func buildTickPayload(l *Lobby, now int64) tickWorld {
	out := tickWorld{
		Players: make([]tickPlayer, 0, len(l.players)),
		Bonus:   make([]Cell, 0, len(l.bonus)),
		Drops:   make([]tickDrop, 0, len(l.drops)),
	}
	for _, p := range l.players {
		out.Players = append(out.Players, tickPlayer{
			ID:          p.ID,
			DisplayName: p.DisplayName,
			Color:       p.Color,
			Snake:       p.Snake,
			Score:       p.Score,
			BodyLength:  p.BodyLength,
		})
	}
	out.Bonus = append(out.Bonus, l.bonus...)
	for _, d := range l.drops {
		ttl := d.ExpiresAt - now
		if ttl < 0 {
			ttl = 0
		}
		out.Drops = append(out.Drops, tickDrop{ID: d.ID, X: d.Pos.X, Y: d.Pos.Y, TTL: ttl})
	}
	if l.golden != nil {
		ttl := l.golden.ExpiresAt - now
		if ttl < 0 {
			ttl = 0
		}
		out.Golden = &tickGolden{X: l.golden.Pos.X, Y: l.golden.Pos.Y, TTL: ttl}
	}
	return out
}

// ---------------------------------------------------------------------------
// Spawning helpers.

func spawnDrop(l *Lobby, now int64) {
	cell, ok := RandomFreeCell(l)
	if !ok {
		return
	}
	l.drops = append(l.drops, &Drop{
		ID:        "drop-" + strconv.Itoa(l.dropSeq),
		Pos:       cell,
		ExpiresAt: now + DropTTLms,
	})
	l.dropSeq++
	SendFeed(l, map[string]any{"type": "drop-incoming"})
}

func spawnGolden(l *Lobby, now int64) {
	cell, ok := RandomFreeCell(l)
	if !ok {
		return
	}
	l.golden = &Drop{Pos: cell, ExpiresAt: now + GoldenTTLms}
}

func openDrop(l *Lobby, p *Player) {
	p.Eat(DropPoints, DropGrowth)
	spawned := 0
	for i := 0; i < DropApples; i++ {
		if len(l.bonus) >= BonusCap {
			break
		}
		cell, ok := RandomFreeCell(l)
		if !ok {
			break
		}
		l.bonus = append(l.bonus, cell)
		spawned++
	}
	SendFeed(l, map[string]any{"type": "drop-open", "who": p.DisplayName, "apples": spawned})
}

// respawnFood rerolls the main food up to 100 times until it is not on any
// snake (matching the reference; other pickups are not considered here).
func respawnFood(l *Lobby) {
	for attempt := 0; attempt < 100; attempt++ {
		l.food = randLoc()
		occupied := false
		for _, p := range l.players {
			if slices.Contains(p.Snake, l.food) {
				occupied = true
				break
			}
		}
		if !occupied {
			return
		}
	}
}

// chooseSpawn mirrors the join path: a random cell free of snakes (1000
// attempts, fallback last try), re-rolled up to 100 more times while it lands
// on the main food.
func chooseSpawn(l *Lobby) Cell {
	pos := startPosition(l)
	for attempt := 0; attempt < 100; attempt++ {
		if pos != l.food {
			break
		}
		pos = startPosition(l)
	}
	return pos
}

func startPosition(l *Lobby) Cell {
	loc := randLoc()
	for attempt := 0; attempt < 1000; attempt++ {
		overlap := false
		for _, p := range l.players {
			if slices.Contains(p.Snake, loc) {
				overlap = true
				break
			}
		}
		if !overlap {
			return loc
		}
		loc = randLoc()
	}
	return loc
}

// RandomFreeCell finds a cell not on any snake, main food, bonus apple, drop
// or golden apple; up to 200 attempts (reference randomFreeCell).
func RandomFreeCell(l *Lobby) (Cell, bool) {
	for attempt := 0; attempt < 200; attempt++ {
		cell := randLoc()
		taken := false
		for _, p := range l.players {
			if slices.Contains(p.Snake, cell) {
				taken = true
				break
			}
		}
		if !taken && cell == l.food {
			taken = true
		}
		if !taken {
			for _, b := range l.bonus {
				if b == cell {
					taken = true
					break
				}
			}
		}
		if !taken {
			for _, d := range l.drops {
				if d.Pos == cell {
					taken = true
					break
				}
			}
		}
		if !taken && l.golden != nil && l.golden.Pos == cell {
			taken = true
		}
		if !taken {
			return cell, true
		}
	}
	return Cell{}, false
}

// ---------------------------------------------------------------------------
// Debug stats (/debug/stats).

type LobbyStat struct {
	ID         string  `json:"id"`
	Players    int     `json:"players"`
	Drops      int     `json:"drops"`
	Bonus      int     `json:"bonus"`
	Golden     bool    `json:"golden"`
	LastTickMs float64 `json:"lastTickMs"`
	AvgTickMs  float64 `json:"avgTickMs"`
	MaxTickMs  float64 `json:"maxTickMs"`
}

func (w *World) LobbyStats() ([]LobbyStat, int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	stats := make([]LobbyStat, 0, len(w.order))
	total := 0
	for _, l := range w.order {
		total += len(l.players)
		stats = append(stats, LobbyStat{
			ID:         l.ID,
			Players:    len(l.players),
			Drops:      len(l.drops),
			Bonus:      len(l.bonus),
			Golden:     l.golden != nil,
			LastTickMs: l.lastTickMs,
			AvgTickMs:  math.Round(l.avgTickMs*10) / 10,
			MaxTickMs:  l.maxTickMs,
		})
	}
	return stats, total
}
