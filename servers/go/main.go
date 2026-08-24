package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"strconv"
	"strings"
	"syscall"
	"time"
)

//go:generate ./build-assets.sh
//go:embed all:internal/generated/client
var embeddedFS embed.FS

type asset struct {
	data  []byte
	ctype string
}

// Server wires the HTTP surface to the World. All client files and the two
// vendor bundles are served from the generated embedded staging tree.
type Server struct {
	world  *World
	assets map[string]asset
	start  time.Time
	debug  bool
}

func main() {
	port := strings.TrimSpace(os.Getenv("PORT"))
	if port == "" {
		port = "3000"
	}
	s := &Server{
		world:  NewWorld(),
		assets: loadAssets(),
		start:  time.Now(),
		debug:  os.Getenv("SNEK_DEBUG") == "1",
	}

	go s.world.Run(make(chan struct{}))

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		os.Exit(0)
	}()

	httpServer := &http.Server{
		Addr:              ":" + port,
		Handler:           withSecurityHeaders(s.routes()),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("listening on *:%s", port)
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

// withSecurityHeaders applies the SPEC-mandated headers to every HTTP response.
func withSecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		s.serveAsset(w, "index.html")
	})
	mux.HandleFunc("GET /index.html", func(w http.ResponseWriter, r *http.Request) {
		s.serveAsset(w, "index.html")
	})
	mux.HandleFunc("GET /lobby.html", func(w http.ResponseWriter, r *http.Request) {
		s.serveAsset(w, "lobby.html")
	})

	mux.HandleFunc("GET /game/{id}", s.serveGame)
	mux.HandleFunc("GET /game.html", func(w http.ResponseWriter, r *http.Request) {
		// The lobby id gate also applies when game.html is requested directly.
		http.Redirect(w, r, "/", http.StatusFound)
	})

	mux.HandleFunc("POST /generateid", s.generateID)
	mux.HandleFunc("POST /joingame", s.joinGame)

	// socket.io endpoint (websocket upgrade); the literal file route is more
	// specific and wins over this prefix for /socket.io/socket.io.js.
	mux.HandleFunc("/socket.io/", s.HandleSocketIO)
	mux.HandleFunc("GET /socket.io/socket.io.js", func(w http.ResponseWriter, r *http.Request) {
		s.serveAsset(w, "socket.io/socket.io.js")
	})
	mux.HandleFunc("GET /vendor/gsap.min.js", func(w http.ResponseWriter, r *http.Request) {
		s.serveAsset(w, "vendor/gsap.min.js")
	})
	mux.HandleFunc("GET /css/{path...}", s.assetPrefix("css/"))
	mux.HandleFunc("GET /js/{path...}", s.assetPrefix("js/"))
	mux.HandleFunc("GET /img/{path...}", s.assetPrefix("img/"))

	if s.debug {
		mux.HandleFunc("GET /debug/stats", s.debugStats)
	}
	return mux
}

func loadAssets() map[string]asset {
	sub, err := fs.Sub(embeddedFS, "internal/generated/client")
	if err != nil {
		panic(err)
	}
	assets := make(map[string]asset)
	err = fs.WalkDir(sub, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, err := fs.ReadFile(sub, p)
		if err != nil {
			return err
		}
		name := strings.TrimPrefix(p, "./")
		assets[name] = asset{data: data, ctype: mimeFor(name)}
		return nil
	})
	if err != nil {
		panic(err)
	}
	return assets
}

func mimeFor(name string) string {
	switch strings.ToLower(path.Ext(name)) {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "application/javascript; charset=UTF-8"
	case ".json":
		return "application/json"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".svg":
		return "image/svg+xml"
	case ".ico":
		return "image/x-icon"
	case ".md":
		return "text/markdown; charset=utf-8"
	default:
		return "application/octet-stream"
	}
}

func (s *Server) serveAsset(w http.ResponseWriter, name string) {
	a, ok := s.assets[name]
	if !ok {
		http.NotFound(w, nil)
		return
	}
	w.Header().Set("Content-Type", a.ctype)
	w.Write(a.data)
}

func (s *Server) assetPrefix(prefix string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.serveAsset(w, prefix+r.PathValue("path"))
	}
}

// serveGame serves the game page only for existing lobbies; otherwise it
// redirects home (lobby gate).
func (s *Server) serveGame(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.world.LobbyExists(id) {
		s.serveAsset(w, "game.html")
		return
	}
	http.Redirect(w, r, "/", http.StatusFound)
}

// generateID creates a fresh lobby and redirects 303 to its game page so a
// refresh of the landing page cannot re-submit the POST.
func (s *Server) generateID(w http.ResponseWriter, r *http.Request) {
	id := s.world.CreateLobbyUnique()
	http.Redirect(w, r, "/game/"+url.PathEscape(id), http.StatusSeeOther)
}

// joinGame handles the form post from the landing page.
func (s *Server) joinGame(w http.ResponseWriter, r *http.Request) {
	gameID := extractGameID(w, r)
	if gameID != "" && s.world.LobbyExists(gameID) {
		http.Redirect(w, r, "/game/"+url.PathEscape(gameID), http.StatusSeeOther)
		return
	}
	// Unknown/bad id: back home with feedback instead of a silent bounce.
	http.Redirect(w, r, "/?error=unknown-game", http.StatusSeeOther)
}

func extractGameID(w http.ResponseWriter, r *http.Request) string {
	ct := r.Header.Get("Content-Type")
	switch {
	case strings.HasPrefix(ct, "application/x-www-form-urlencoded"):
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		_ = r.ParseForm()
		return strings.TrimSpace(r.PostFormValue("gameId"))
	case strings.HasPrefix(ct, "application/json"):
		var m map[string]any
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
		_ = dec.Decode(&m)
		if v, ok := m["gameId"].(string); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// debugStats serves GET /debug/stats when SNEK_DEBUG=1. RSS comes straight
// from the kernel counters; the benchmark harness parses this JSON.
func (s *Server) debugStats(w http.ResponseWriter, r *http.Request) {
	lobbies, total := s.world.LobbyStats()
	resp := struct {
		RSS          int64       `json:"rss"`
		Uptime       float64     `json:"uptime"`
		TotalPlayers int         `json:"totalPlayers"`
		Lobbies      []LobbyStat `json:"lobbies"`
	}{
		RSS:          rssBytes(),
		Uptime:       time.Since(s.start).Seconds(),
		TotalPlayers: total,
		Lobbies:      lobbies,
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(marshalNoEsc(resp))
}

// rssBytes reads resident set size from /proc (VmRSS in status, falling back
// to statm's resident field).
func rssBytes() int64 {
	pageSize := int64(os.Getpagesize())
	if b, err := os.ReadFile("/proc/self/status"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(line, "VmRSS:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					if kb, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
						return kb * 1024
					}
				}
			}
		}
	}
	if b, err := os.ReadFile("/proc/self/statm"); err == nil {
		fields := strings.Fields(string(b))
		if len(fields) >= 2 {
			if pages, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
				return pages * pageSize
			}
		}
	}
	return 0
}
