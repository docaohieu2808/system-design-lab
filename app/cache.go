package main

// Module 4: cache-aside for the preview page, in Redis.
//
//	REDIS_URL         unset = no cache (Modules 1-3 behave exactly as before)
//	CACHE_TTL         seconds a cached page lives (default 60)
//	CACHE_JITTER      0..1, each TTL is spread evenly over TTL ± half this fraction (0.5 = 75%..125%), so pages
//	                  cached together do not all expire together, and the average lifetime stays TTL (default 0)
//	CACHE_SINGLEFLIGHT 1 = while one request rebuilds a missing page, others asking for the same page wait for it
//	                  instead of all going to the database (default 0)

import (
	"context"
	"encoding/json"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
	"golang.org/x/sync/singleflight"
)

var stats struct{ dbQueries, hits, misses atomic.Int64 }

func serveStats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]int64{
		"db_queries": stats.dbQueries.Load(), "cache_hits": stats.hits.Load(), "cache_misses": stats.misses.Load()})
}

func resetStats(w http.ResponseWriter, r *http.Request) {
	stats.dbQueries.Store(0)
	stats.hits.Store(0)
	stats.misses.Store(0)
	w.WriteHeader(http.StatusNoContent)
}

type pageCache struct {
	rdb    *redis.Client
	ttl    time.Duration
	jitter float64
	single bool
	group  singleflight.Group
}

func newPageCache() *pageCache {
	url := os.Getenv("REDIS_URL")
	if url == "" {
		return nil
	}
	opt, err := redis.ParseURL(url)
	if err != nil {
		panic(err)
	}
	ttl, err := strconv.Atoi(os.Getenv("CACHE_TTL"))
	if err != nil || ttl < 1 {
		ttl = 60
	}
	jitter, _ := strconv.ParseFloat(os.Getenv("CACHE_JITTER"), 64)
	return &pageCache{rdb: redis.NewClient(opt), ttl: time.Duration(ttl) * time.Second, jitter: jitter,
		single: os.Getenv("CACHE_SINGLEFLIGHT") == "1"}
}

// cachedPage is cache-aside: look in Redis, and on a miss build the page and put it there.
func (s *server) cachedPage(ctx context.Context, code string) (string, error) {
	c := s.cache
	if c == nil {
		return s.renderPage(ctx, code)
	}
	if html, err := c.rdb.Get(ctx, "page:"+code).Result(); err == nil {
		stats.hits.Add(1)
		return html, nil
	}
	stats.misses.Add(1)
	build := func() (any, error) {
		html, err := s.renderPage(ctx, code)
		if err == nil {
			ttl := time.Duration(float64(c.ttl) * (1 + c.jitter*(rand.Float64()-0.5)))
			c.rdb.Set(ctx, "page:"+code, html, ttl)
		}
		return html, err
	}
	if !c.single {
		html, err := build()
		return html.(string), err
	}
	html, err, _ := c.group.Do(code, build)
	return html.(string), err
}
