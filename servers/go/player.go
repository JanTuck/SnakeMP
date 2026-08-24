package main

// Board geometry (logical units). Grid is 120 x 60 cells of 16px,
// matching the reference server constants and the game canvas.
const (
	GridSize   = 16
	GridWidth  = 1920
	GridHeight = 960
)

// The four movement directions as sent by clients via keyPress.
const (
	DirUp    = "ArrowUp"
	DirDown  = "ArrowDown"
	DirLeft  = "ArrowLeft"
	DirRight = "ArrowRight"
)

var oppositeDir = map[string]string{
	DirUp:    DirDown,
	DirDown:  DirUp,
	DirLeft:  DirRight,
	DirRight: DirLeft,
}

func isDirection(d string) bool {
	switch d {
	case DirUp, DirDown, DirLeft, DirRight:
		return true
	}
	return false
}

// Cell is one grid cell; coordinates are multiples of GridSize.
// Index 0 of a snake is the head.
type Cell struct {
	X int `json:"x"`
	Y int `json:"y"`
}

// Player mirrors server/player.js of the reference implementation.
type Player struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Color       string `json:"color"`
	Snake       []Cell `json:"snake"`
	Score       int    `json:"score"`
	BodyLength  int    `json:"bodyLength"`

	direction     string   // direction applied on the last tick; "" = stationary
	queue         []string // pending turns, at most 2
	pendingGrowth int      // segments still to grow
	conn          *Conn
}

func NewPlayer(id, name, color string, pos Cell, c *Conn) *Player {
	return &Player{
		ID:          id,
		DisplayName: name,
		Color:       color,
		Snake:       []Cell{pos},
		BodyLength:  1,
		conn:        c,
	}
}

// SetDirection queues a turn: rejects non-arrows, repeats and 180-degree
// reversals relative to the last queued (or applied) direction; bounded to 2.
func (p *Player) SetDirection(v any) {
	d, ok := v.(string)
	if !ok || !isDirection(d) {
		return
	}
	last := p.direction
	if n := len(p.queue); n > 0 {
		last = p.queue[n-1]
	}
	if last != "" && (d == last || d == oppositeDir[last]) {
		return
	}
	if len(p.queue) >= 2 {
		return
	}
	p.queue = append(p.queue, d)
}

// UpdatePosition applies ONE queued turn per tick, then moves 16px, growing by
// consuming pendingGrowth instead of popping the tail. A stationary snake (no
// input yet) does not move.
func (p *Player) UpdatePosition() {
	if len(p.queue) > 0 {
		p.direction = p.queue[0]
		p.queue = p.queue[1:]
	}
	if p.direction == "" {
		return
	}
	head := p.Snake[0]
	switch p.direction {
	case DirRight:
		head.X += GridSize
	case DirLeft:
		head.X -= GridSize
	case DirUp:
		head.Y -= GridSize
	case DirDown:
		head.Y += GridSize
	}
	if p.pendingGrowth > 0 {
		p.pendingGrowth--
	} else {
		p.Snake = p.Snake[:len(p.Snake)-1]
	}
	body := make([]Cell, len(p.Snake)+1)
	body[0] = head
	copy(body[1:], p.Snake)
	p.Snake = body
	p.BodyLength = len(p.Snake)
}

// Eat awards points and queues growth (reference eat(points=1, growth=1)).
func (p *Player) Eat(points, growth int) {
	p.Score += points
	p.pendingGrowth += growth
	p.BodyLength = len(p.Snake) + p.pendingGrowth
}

func (p *Player) CollidedSelf() bool {
	h := p.Snake[0]
	for _, s := range p.Snake[1:] {
		if s == h {
			return true
		}
	}
	return false
}

func (p *Player) CollidedWall() bool {
	h := p.Snake[0]
	return h.X > GridWidth-GridSize || h.X < 0 ||
		h.Y > GridHeight-GridSize || h.Y < 0
}

func (p *Player) Collided() bool { return p.CollidedSelf() || p.CollidedWall() }

// CollidedOther returns the player whose ANY segment (head included) matches
// our head, or nil. Self is skipped.
func (p *Player) CollidedOther(players []*Player) *Player {
	h := p.Snake[0]
	for _, o := range players {
		if o.ID == p.ID {
			continue
		}
		for _, seg := range o.Snake {
			if seg == h {
				return o
			}
		}
	}
	return nil
}
