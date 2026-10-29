package main

// Module 7: the app routes each short code to one of several database shards.
//
//	SHARD_URLS  comma-separated database URLs; unset = one database (all earlier modules)
//	            a code goes to shard hash(code) mod N; GET /stats/shards counts the lookups each shard answered

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync/atomic"

	"github.com/jackc/pgx/v5/pgxpool"
)

var shardPools []*pgxpool.Pool
var shardHits []atomic.Int64

func openShards() {
	urls := os.Getenv("SHARD_URLS")
	if urls == "" {
		return
	}
	for _, u := range strings.Split(urls, ",") {
		p, err := pgxpool.New(context.Background(), u)
		if err != nil {
			panic(err)
		}
		shardPools = append(shardPools, p)
	}
	shardHits = make([]atomic.Int64, len(shardPools))
}

// shardFor returns the pool that owns this code, or nil when the app is not sharded.
func shardFor(code string) *pgxpool.Pool {
	if len(shardPools) == 0 {
		return nil
	}
	i := hash64(code) % uint64(len(shardPools))
	shardHits[i].Add(1)
	return shardPools[i]
}

func serveShardStats(w http.ResponseWriter, r *http.Request) {
	out := make([]int64, len(shardHits))
	for i := range shardHits {
		out[i] = shardHits[i].Load()
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"lookups_per_shard": out})
}
