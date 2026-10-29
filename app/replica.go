package main

// Module 6: reads from a replica, and the failover writer drill.
//
//	READ_DATABASE_URL  unset = everything uses DATABASE_URL (Modules 1-5 unchanged); set = redirects read from here
//	RYW_SECONDS        read-your-writes: for this many seconds after a client creates a link, that client's reads
//	                   go to the primary instead (the create response sets a cookie with the time)
//	shortener drill failover-writer   creates links at WRITER_RATE per second for WRITER_SECONDS and prints one JSON
//	                   line per attempt: {"t": seconds since start, "ok": bool, "code": "..."}

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

var readPool *pgxpool.Pool

func openReadPool() {
	url := os.Getenv("READ_DATABASE_URL")
	if url == "" {
		return
	}
	p, err := pgxpool.New(context.Background(), url)
	if err != nil {
		panic(err)
	}
	readPool = p
}

// readDB picks where a read goes: the replica, unless this client wrote within the last RYW_SECONDS.
func (s *server) readDB(r *http.Request) *pgxpool.Pool {
	if readPool == nil {
		return s.db
	}
	if ryw, _ := strconv.Atoi(os.Getenv("RYW_SECONDS")); ryw > 0 {
		if c, err := r.Cookie("wrote"); err == nil {
			if ms, err := strconv.ParseInt(c.Value, 10, 64); err == nil && time.Since(time.UnixMilli(ms)) < time.Duration(ryw)*time.Second {
				return s.db
			}
		}
	}
	return readPool
}

func markWrote(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: "wrote", Value: strconv.FormatInt(time.Now().UnixMilli(), 10), Path: "/"})
}

func failoverWriter(ctx context.Context, pool *pgxpool.Pool) {
	rate, _ := strconv.Atoi(os.Getenv("WRITER_RATE"))
	secs, _ := strconv.Atoi(os.Getenv("WRITER_SECONDS"))
	if rate < 1 {
		rate = 100
	}
	if secs < 1 {
		secs = 60
	}
	enc, start := json.NewEncoder(os.Stdout), time.Now()
	tick := time.NewTicker(time.Second / time.Duration(rate))
	defer tick.Stop()
	for i := 0; time.Since(start) < time.Duration(secs)*time.Second; i++ {
		<-tick.C
		t := time.Since(start).Seconds()
		c, cancel := context.WithTimeout(ctx, 2*time.Second)
		var code string
		err := pool.QueryRow(c, "INSERT INTO links (code, url) VALUES ('fo-' || $1, 'https://example.com/failover/' || $1) RETURNING code", strconv.Itoa(i)).Scan(&code)
		cancel()
		row := map[string]any{"t": t, "ok": err == nil, "code": code}
		if err != nil {
			row["err"] = err.Error()
		}
		enc.Encode(row)
	}
}
