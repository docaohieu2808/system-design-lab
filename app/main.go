// Command shortener is the course's demo app: a tiny URL shortener.
//
//	POST /api/links {"url": "..."}  -> 201 {"code": "..."}
//	GET  /{code}                     -> 302 to the long URL
//	GET  /healthz                    -> 200 when the database answers
//
// It is deliberately plain (one process, one Postgres) so every later module
// can change one thing and measure the difference.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
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

type server struct{ db *pgxpool.Pool }

func (s *server) redirect(w http.ResponseWriter, r *http.Request) {
	var long string
	err := s.db.QueryRow(r.Context(), "SELECT url FROM links WHERE code = $1", r.PathValue("code")).Scan(&long)
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
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"code": code})
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
	pool, err := pgxpool.New(context.Background(), os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	s := &server{db: pool}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("POST /api/links", s.create)
	mux.HandleFunc("GET /{code}", s.redirect)
	addr := ":8080"
	log.Printf("shortener listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
