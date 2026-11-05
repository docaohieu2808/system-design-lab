package main

// Module 4: cache-aside for the preview page, in Redis.
//
//	REDIS_URL         unset = no cache (Modules 1-3 behave exactly as before)
//	CACHE_TTL         seconds a cached page lives (default 60)
//	CACHE_JITTER      0..1, each TTL is spread evenly over TTL ± half this fraction (0.5 = 75%..125%), so pages
//	                  cached together do not all expire together, and the average lifetime stays TTL (default 0)
//	CACHE_SINGLEFLIGHT 1 = while one request rebuilds a missing page, others asking for the same page wait for it
//	                  instead of all going to the database (default 0)
//	CACHE_SWR         1 = stale-while-revalidate: a page past its soft lifetime (CACHE_TTL) is still served at once
//	                  while ONE background refresh rebuilds it; Redis keeps it CACHE_TTL longer so there is
//	                  something to serve (default 0). It cannot help after a flush: nothing is left to serve.

import (
	"context"
	"encoding/json"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"strings"
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
	swr    bool
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
		single: os.Getenv("CACHE_SINGLEFLIGHT") == "1", swr: os.Getenv("CACHE_SWR") == "1"}
}

// cachedPage is cache-aside: look in Redis, and on a miss build the page and put it there.
func (s *server) cachedPage(ctx context.Context, code string) (string, error) {
	c := s.cache
	if c == nil {
		return s.renderPage(ctx, code)
	}
	if raw, err := c.rdb.Get(ctx, "page:"+code).Result(); err == nil {
		if !c.swr {
			stats.hits.Add(1)
			return raw, nil
		}
		// stored as "<soft expiry in unix ms>|<page>"; past the soft expiry serve it and refresh in the background
		if i := strings.IndexByte(raw, '|'); i > 0 {
			soft, _ := strconv.ParseInt(raw[:i], 10, 64)
			stats.hits.Add(1)
			if time.Now().UnixMilli() > soft {
				// DoChan runs the rebuild once per page; later callers join it and we ignore the result
				c.group.DoChan("swr:"+code, func() (any, error) {
					bg, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					return s.rebuild(bg, code)
				})
			}
			return raw[i+1:], nil
		}
	}
	stats.misses.Add(1)
	build := func() (any, error) { return s.rebuild(ctx, code) }
	if !c.single {
		html, err := build()
		return html.(string), err
	}
	html, err, _ := c.group.Do(code, build)
	return html.(string), err
}

// rebuild renders the page and stores it. With stale-while-revalidate the soft expiry travels inside the value and
// Redis keeps the page for one more TTL after it.
func (s *server) rebuild(ctx context.Context, code string) (any, error) {
	c := s.cache
	html, err := s.renderPage(ctx, code)
	if err == nil {
		ttl := time.Duration(float64(c.ttl) * (1 + c.jitter*(rand.Float64()-0.5)))
		if c.swr {
			c.rdb.Set(ctx, "page:"+code, strconv.FormatInt(time.Now().Add(ttl).UnixMilli(), 10)+"|"+html, ttl+c.ttl)
		} else {
			c.rdb.Set(ctx, "page:"+code, html, ttl)
		}
	}
	return html, err
}
