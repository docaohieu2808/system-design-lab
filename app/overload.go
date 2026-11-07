package main

// Module 11: staying useful when asked for more than you can do.
//
//	MAX_INFLIGHT  > 0: at most this many preview pages are built at once; one more is refused at once with 503 and
//	              Retry-After: 1 instead of waiting in line (load shedding). 503, not 429: the cap protects the whole
//	              service (temporary unavailability); 429 is the per-client rate limiter of module 9. 0 = everyone waits.
//	GET /api/enrich  builds the page and also asks a dependency (DEP_URL) for extra data, with a DEP_TIMEOUT_MS timeout.
//	              BREAKER=1: after 5 failures in a row, stop calling the dependency for 2 s and answer without it;
//	              when the 2 s end, every call goes through again.
//	              BREAKER=2: the same, but when the 2 s end exactly ONE call (the probe) goes through; all others are
//	              answered without the dependency until it returns. Success closes the breaker, failure reopens it for 2 s.
//	GET /stats/dep   how many calls really reached the dependency (since the app started)

import (
	"encoding/json"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
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
			// a slot frees within milliseconds; 1 s is the smallest wait the header can say
			w.Header().Set("Retry-After", "1")
			http.Error(w, "busy, try again shortly", http.StatusServiceUnavailable)
		}
	}
}

type breaker struct {
	mu        sync.Mutex
	fails     int
	openUntil time.Time
	tripped   bool // BREAKER=2: opened and not yet closed again by a successful probe
	probing   bool // BREAKER=2: the single probe call is in flight
}

var depCalls atomic.Int64

func serveDepStats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"dep_calls": depCalls.Load()})
}

// callOnce asks the dependency and counts the call.
func callOnce() bool {
	depCalls.Add(1)
	depClient.Timeout = time.Duration(envInt("DEP_TIMEOUT_MS", 3000)) * time.Millisecond
	resp, err := depClient.Get(os.Getenv("DEP_URL"))
	ok := err == nil && resp.StatusCode == http.StatusOK
	if resp != nil {
		resp.Body.Close()
	}
	return ok
}

// callSingleProbe is BREAKER=2: closed -> 5 failures -> open 2 s -> half-open (one probe) -> closed or open again.
func callSingleProbe() bool {
	dep.mu.Lock()
	if dep.tripped && (time.Now().Before(dep.openUntil) || dep.probing) {
		dep.mu.Unlock()
		return false
	}
	probe := dep.tripped // the pause is over and nobody is probing: this call is the probe
	if probe {
		dep.probing = true
	}
	dep.mu.Unlock()
	ok := callOnce()
	dep.mu.Lock()
	defer dep.mu.Unlock()
	switch {
	case probe && ok:
		dep.tripped, dep.probing, dep.fails = false, false, 0
	case probe:
		dep.probing, dep.openUntil = false, time.Now().Add(2*time.Second)
	case dep.tripped: // a call started before the breaker opened: its answer no longer matters
	case ok:
		dep.fails = 0
	default:
		if dep.fails++; dep.fails >= 5 {
			dep.tripped, dep.openUntil, dep.fails = true, time.Now().Add(2*time.Second), 0
		}
	}
	return ok
}

var dep = &breaker{}
var depClient = &http.Client{}

// callDependency returns false when the dependency failed, timed out, or the breaker is open.
func callDependency(r *http.Request) bool {
	if os.Getenv("BREAKER") == "2" {
		return callSingleProbe()
	}
	useBreaker := os.Getenv("BREAKER") == "1"
	if useBreaker {
		dep.mu.Lock()
		open := time.Now().Before(dep.openUntil)
		dep.mu.Unlock()
		if open {
			return false
		}
	}
	ok := callOnce()
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
