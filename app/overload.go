package main

// Module 11: staying useful when asked for more than you can do.
//
//	MAX_INFLIGHT  > 0: at most this many preview pages are built at once; one more is refused at once with 429
//	              instead of waiting in line (load shedding). 0 = everyone waits.
//	GET /api/enrich  builds the page and also asks a dependency (DEP_URL) for extra data, with a DEP_TIMEOUT_MS timeout.
//	              BREAKER=1: after 5 failures in a row, stop calling the dependency for 2 s and answer without it.

import (
	"net/http"
	"os"
	"sync"
	"time"
)

var inflight chan struct{}

func shed(next http.HandlerFunc) http.HandlerFunc {
	if n := envInt("MAX_INFLIGHT", 0); n > 0 {
		inflight = make(chan struct{}, n)
	}
	return func(w http.ResponseWriter, r *http.Request) {
		if inflight == nil {
			next(w, r)
			return
		}
		select {
		case inflight <- struct{}{}:
			defer func() { <-inflight }()
			next(w, r)
		default:
			http.Error(w, "busy, try again shortly", http.StatusTooManyRequests)
		}
	}
}

type breaker struct {
	mu        sync.Mutex
	fails     int
	openUntil time.Time
}

var dep = &breaker{}
var depClient = &http.Client{}

// callDependency returns false when the dependency failed, timed out, or the breaker is open.
func callDependency(r *http.Request) bool {
	useBreaker := os.Getenv("BREAKER") == "1"
	if useBreaker {
		dep.mu.Lock()
		open := time.Now().Before(dep.openUntil)
		dep.mu.Unlock()
		if open {
			return false
		}
	}
	depClient.Timeout = time.Duration(envInt("DEP_TIMEOUT_MS", 3000)) * time.Millisecond
	resp, err := depClient.Get(os.Getenv("DEP_URL"))
	ok := err == nil && resp.StatusCode == http.StatusOK
	if resp != nil {
		resp.Body.Close()
	}
	if useBreaker {
		dep.mu.Lock()
		if ok {
			dep.fails = 0
		} else if dep.fails++; dep.fails >= 5 {
			dep.openUntil, dep.fails = time.Now().Add(2*time.Second), 0
		}
		dep.mu.Unlock()
	}
	return ok
}

func (s *server) enrich(w http.ResponseWriter, r *http.Request) {
	html, err := s.cachedPage(r.Context(), r.PathValue("code"))
	if err != nil {
		http.Error(w, "database error", http.StatusServiceUnavailable)
		return
	}
	if !callDependency(r) {
		w.Header().Set("X-Degraded", "1") // the page, without the extra data
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(html))
}
