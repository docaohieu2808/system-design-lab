// Command shortener is the course's demo app: a tiny URL shortener.
//
//	POST /api/links {"url": "..."}  -> 201 {"code": "..."}
//	GET  /{code}                     -> 302 to the long URL
//	GET  /page/{code}                -> 200, a small preview page: the same lookup plus ~1 ms of CPU (Module 3)
//	GET  /healthz                    -> 200 when the database answers
//	GET  /api/lookup, /api/recent    -> Module 5 database lessons (db.go)
//	GET  /api/limited                -> Module 9 rate limiter (ratelimit.go)
//	GET  /api/enrich/{code}          -> Module 11 dependency + circuit breaker (overload.go)
//	GET  /stats, POST /stats/reset   -> counters: database queries, cache hits and misses (Module 4)
//
// It is deliberately plain (one process, one Postgres) so every later module
// can change one thing and measure the difference.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

// base62 turns a row id into a short code; db/init.sql has the same function for the seed rows.
func base62(n int64) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{alphabet[n%62]}, b...)
		n /= 62
	}
	return string(b)
}

type server struct {
	db    *pgxpool.Pool
	work  int // hash rounds per preview page; PAGE_WORK sets it, the default costs about 1 ms of CPU
	cache *pageCache
	delay time.Duration
}

func (s *server) redirect(w http.ResponseWriter, r *http.Request) {
	var long string
	stats.dbQueries.Add(1)
	db := s.readDB(r)
	if sp := shardFor(r.PathValue("code")); sp != nil {
		db = sp
	}
	err := db.QueryRow(r.Context(), "SELECT url FROM links WHERE code = $1", r.PathValue("code")).Scan(&long)
	if errors.Is(err, pgx.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, "database error", http.StatusServiceUnavailable)
		return
	}
	http.Redirect(w, r, long, http.StatusFound)
}

func (s *server) create(w http.ResponseWriter, r *http.Request) {
	var in struct {
		URL string `json:"url"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.URL == "" {
		http.Error(w, `want {"url": "..."}`, http.StatusBadRequest)
		return
	}
	tx, err := s.db.Begin(r.Context())
	if err != nil {
		http.Error(w, "database error", http.StatusServiceUnavailable)
		return
	}
	defer tx.Rollback(r.Context())
	var id int64
	if err := tx.QueryRow(r.Context(), "SELECT nextval('links_id_seq')").Scan(&id); err != nil {
		http.Error(w, "database error", http.StatusServiceUnavailable)
		return
	}
	code := base62(id)
	if _, err := tx.Exec(r.Context(), "INSERT INTO links (id, code, url) VALUES ($1, $2, $3)", id, code, in.URL); err != nil {
		http.Error(w, "database error", http.StatusServiceUnavailable)
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		http.Error(w, "database error", http.StatusServiceUnavailable)
		return
	}
	sideWork(r.Context(), code)
	markWrote(w)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"code": code})
}

// page is a heavier request than the redirect: the same lookup, then a little rendering work. Real pages do more
// than one query, and a request this cheap to the app keeps the load balancer from being the busiest thing on the
// machine, so Module 3 measures the app copies rather than the proxy. With REDIS_URL set (Module 4) the rendered
// page is cached: see cache.go.
func (s *server) page(w http.ResponseWriter, r *http.Request) {
	html, err := s.cachedPage(r.Context(), r.PathValue("code"))
	if errors.Is(err, pgx.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, "database error", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, html)
}

// renderPage does the expensive part: one database lookup plus the rendering work.
func (s *server) renderPage(ctx context.Context, code string) (string, error) {
	var long string
	stats.dbQueries.Add(1)
	if err := s.db.QueryRow(ctx, "SELECT url FROM links WHERE code = $1", code).Scan(&long); err != nil {
		return "", err
	}
	if s.delay > 0 { // PAGE_DELAY_MS: stands in for a slow query or a slow downstream call (Module 4 stampede)
		time.Sleep(s.delay)
	}
	sum := sha256.Sum256([]byte(long))
	for i := 1; i < s.work; i++ {
		sum = sha256.Sum256(sum[:])
	}
	return fmt.Sprintf("<!doctype html><title>%s</title><p>Goes to <a href=%q>%s</a> (%x)</p>\n", code, long, long, sum[:4]), nil
}

func (s *server) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	if err := s.db.Ping(ctx); err != nil {
		http.Error(w, "database down", http.StatusServiceUnavailable)
		return
	}
	w.Write([]byte("ok\n"))
}

func main() {
	if len(os.Args) > 2 && os.Args[1] == "drill" {
		drill(os.Args[2])
		return
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), poolConfig())
	if err != nil {
		log.Fatal(err)
	}
	work, err := strconv.Atoi(os.Getenv("PAGE_WORK"))
	if err != nil || work < 1 {
		work = 6000
	}
	openReadPool()
	openShards()
	delayMS, _ := strconv.Atoi(os.Getenv("PAGE_DELAY_MS"))
	s := &server{db: pool, work: work, cache: newPageCache(), delay: time.Duration(delayMS) * time.Millisecond}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("POST /api/links", s.create)
	mux.HandleFunc("GET /page/{code}", shed(s.page))
	mux.HandleFunc("GET /api/enrich/{code}", s.enrich)
	mux.HandleFunc("GET /stats", serveStats)
	mux.HandleFunc("GET /stats/shards", serveShardStats)
	mux.HandleFunc("GET /api/limited", newLimiter().serve)
	mux.HandleFunc("GET /api/lookup", s.lookup)
	mux.HandleFunc("GET /api/recent", s.recent)
	mux.HandleFunc("POST /stats/reset", resetStats)
	mux.HandleFunc("GET /{code}", s.redirect)
	addr := ":8080"
	log.Printf("shortener listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
