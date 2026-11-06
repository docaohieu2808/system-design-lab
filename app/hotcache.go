package main

// Module 7.3 fix: a small in-memory cache of HOT codes in front of the shard router.
//
//	HOT_CACHE=1            switch it on (default off: every lookup goes to its shard)
//	HOT_CACHE_THRESHOLD    a code that missed the cache this many times within one second is called hot (default 20)
//	HOT_CACHE_TTL_S        how long a hot code's answer is kept (default 30)
//
// Only codes that prove hot are kept, so cold traffic does not churn the cache; a cached code is answered by the app
// without touching any shard (and without a counter bump in shardFor), so /stats/shards shows what the shards still see.

import (
	"os"
	"sync"
	"sync/atomic"
	"time"
)

type hotEntry struct {
	url     string
	expires time.Time
}

type hotCache struct {
	mu        sync.RWMutex
	entries   map[string]hotEntry
	seen      map[string]int // misses per code in the current one-second window
	windowEnd time.Time
	threshold int
	ttl       time.Duration
	hits      atomic.Int64
}

var hotc *hotCache

func openHotCache() {
	if os.Getenv("HOT_CACHE") != "1" {
		return
	}
	hotc = &hotCache{entries: map[string]hotEntry{}, seen: map[string]int{}, threshold: max(1, envInt("HOT_CACHE_THRESHOLD", 20)),
		ttl: time.Duration(max(1, envInt("HOT_CACHE_TTL_S", 30))) * time.Second}
}

// get returns the cached long URL of a hot code.
func (h *hotCache) get(code string) (string, bool) {
	h.mu.RLock()
	e, ok := h.entries[code]
	h.mu.RUnlock()
	if !ok || time.Now().After(e.expires) {
		return "", false
	}
	h.hits.Add(1)
	return e.url, true
}

// miss is called after a lookup went to the database; a code that keeps missing within one second is cached.
func (h *hotCache) miss(code, url string) {
	now := time.Now()
	h.mu.Lock()
	if now.After(h.windowEnd) {
		h.seen, h.windowEnd = map[string]int{}, now.Add(time.Second)
	}
	h.seen[code]++
	if h.seen[code] >= h.threshold {
		h.entries[code] = hotEntry{url: url, expires: now.Add(h.ttl)}
	}
	h.mu.Unlock()
}
