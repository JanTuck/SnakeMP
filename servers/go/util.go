package main

import (
	"bytes"
	crand "crypto/rand"
	"encoding/json"
	"fmt"
	"math"
	"math/rand/v2"
	"strings"
	"sync/atomic"
	"time"
	"unicode"
)

// randLoc mirrors Environment.getRanLocation: a uniformly random grid cell.
func randLoc() Cell {
	return Cell{
		X: rand.IntN(GridWidth/GridSize) * GridSize,
		Y: rand.IntN(GridHeight/GridSize) * GridSize,
	}
}

// GenLobbyID mirrors server/generateId.js:
// "id-" + 8 base36 random chars + base36 unix-millis timestamp.
func GenLobbyID() string {
	const digits = "0123456789abcdefghijklmnopqrstuvwxyz"
	b := make([]byte, 8)
	crand.Read(b)
	for i := range b {
		b[i] = digits[b[i]%36]
	}
	return "id-" + string(b) + strconvFormatMillis(time.Now().UnixMilli())
}

func strconvFormatMillis(ms int64) string {
	return strconvIta36(ms)
}

// Small base36 formatter (avoids pulling strconv into more call sites).
func strconvIta36(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	u := uint64(v)
	if neg {
		u = uint64(-v)
	}
	var buf [24]byte
	i := len(buf)
	for u > 0 {
		i--
		buf[i] = "0123456789abcdefghijklmnopqrstuvwxyz"[u%36]
		u /= 36
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// NextColor produces rcolor-style #rrggbb values via a golden-angle hue walk.
func NextColor() string {
	n := colorCounter.Add(1)
	hue := math.Mod(float64(n)*137.508, 360)
	return hslToHex(hue, 0.68, 0.52)
}

var colorCounter atomic.Int64

func hslToHex(h, s, l float64) string {
	c := (1 - math.Abs(2*l-1)) * s
	hp := h / 60
	x := c * (1 - math.Abs(math.Mod(hp, 2)-1))
	var r1, g1, b1 float64
	switch {
	case hp < 1:
		r1, g1, b1 = c, x, 0
	case hp < 2:
		r1, g1, b1 = x, c, 0
	case hp < 3:
		r1, g1, b1 = 0, c, x
	case hp < 4:
		r1, g1, b1 = 0, x, c
	case hp < 5:
		r1, g1, b1 = x, 0, c
	default:
		r1, g1, b1 = c, 0, x
	}
	m := l - c/2
	to255 := func(v float64) int64 {
		v = math.Round((v + m) * 255)
		if v < 0 {
			return 0
		}
		if v > 255 {
			return 255
		}
		return int64(v)
	}
	return fmt.Sprintf("#%02x%02x%02x", to255(r1), to255(g1), to255(b1))
}

// ValidUsername ports InputValidation.isValidUsername: trimmed length 4..16
// (UTF-16 units like JS .length), charset [\p{L}\p{N}_\- ]+ over unicode.
// The returned name is the trimmed value used as displayName.
func ValidUsername(v any) (string, bool) {
	s, ok := v.(string)
	if !ok {
		return "", false
	}
	t := jsTrim(s)
	n := utf16Len(t)
	if n < 4 || n > 16 {
		return "", false
	}
	for _, r := range t {
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && r != '_' && r != '-' && r != ' ' {
			return "", false
		}
	}
	return t, true
}

// jsTrim trims exactly the whitespace set of ECMAScript String.prototype.trim.
func jsTrim(s string) string {
	isJSWhitespace := func(r rune) bool {
		switch r {
		case 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0,
			0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
			return true
		}
		return r >= 0x2000 && r <= 0x200A
	}
	return strings.TrimFunc(s, isJSWhitespace)
}

// utf16Len counts UTF-16 code units (astral runes count as 2), matching JS
// string .length semantics for the username length check.
func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		if r > 0xFFFF {
			n += 2
		} else {
			n++
		}
	}
	return n
}

// marshalNoEsc JSON-encodes without HTML escaping (keeps payloads byte-clean).
func marshalNoEsc(v any) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return []byte("null")
	}
	return bytes.TrimRight(buf.Bytes(), "\n")
}
