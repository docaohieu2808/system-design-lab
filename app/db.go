package main

// Module 5: database behaviour under load.
//
//	GET /api/lookup?url=...   the short code for a long URL ("has this been shortened already?"): a query on a column
//	                          with no index until the lab adds one
//	GET /api/recent           the 20 newest links with their click counts; NPLUS1=1 asks for each count separately
//	POOL_MAX                  connections this app copy may open to the database (default: pgx's own default)
//	shortener drill lost-update | write-skew   the two correctness drills, run once and print a JSON line

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func poolConfig() *pgxpool.Config {
	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		panic(err)
	}
	if n, err := strconv.Atoi(os.Getenv("POOL_MAX")); err == nil && n > 0 {
		cfg.MaxConns = int32(n)
	}
	return cfg
}

func (s *server) lookup(w http.ResponseWriter, r *http.Request) {
	var code string
	stats.dbQueries.Add(1)
	err := s.db.QueryRow(r.Context(), "SELECT code FROM links WHERE url = $1 LIMIT 1", r.URL.Query().Get("url")).Scan(&code)
	if err == pgx.ErrNoRows {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, "database error", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"code":%q}`, code)
}

type recentLink struct {
	Code   string `json:"code"`
	Clicks int64  `json:"clicks"`
}

func (s *server) recent(w http.ResponseWriter, r *http.Request) {
	ctx, out := r.Context(), make([]recentLink, 0, 20)
	if os.Getenv("NPLUS1") == "1" { // one query for the list, then one more per row: 21 round trips
		stats.dbQueries.Add(1)
		rows, err := s.db.Query(ctx, "SELECT code FROM links ORDER BY id DESC LIMIT 20")
		if err != nil {
			http.Error(w, "database error", http.StatusServiceUnavailable)
			return
		}
		codes, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			http.Error(w, "database error", http.StatusServiceUnavailable)
			return
		}
		for _, c := range codes {
			var n int64
			stats.dbQueries.Add(1)
			if err := s.db.QueryRow(ctx, "SELECT clicks FROM link_stats WHERE code = $1", c).Scan(&n); err != nil && err != pgx.ErrNoRows {
				http.Error(w, "database error", http.StatusServiceUnavailable)
				return
			}
			out = append(out, recentLink{c, n})
		}
	} else { // the same answer in one round trip
		stats.dbQueries.Add(1)
		rows, err := s.db.Query(ctx, `SELECT l.code, coalesce(s.clicks, 0) FROM (SELECT code FROM links ORDER BY id DESC LIMIT 20) l
			LEFT JOIN link_stats s ON s.code = l.code`)
		if err != nil {
			http.Error(w, "database error", http.StatusServiceUnavailable)
			return
		}
		if out, err = pgx.CollectRows(rows, pgx.RowToStructByPos[recentLink]); err != nil {
			http.Error(w, "database error", http.StatusServiceUnavailable)
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// drill runs one correctness drill against the database and prints its result as JSON.
func drill(name string) {
	ctx := context.Background()
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig())
	if err != nil {
		panic(err)
	}
	var res any
	switch name {
	case "lost-update":
		res = lostUpdate(ctx, pool)
	case "write-skew":
		res = writeSkew(ctx, pool)
	case "failover-writer":
		failoverWriter(ctx, pool)
		return
	default:
		panic("unknown drill " + name)
	}
	json.NewEncoder(os.Stdout).Encode(res)
}

// lostUpdate: 50 workers each add one click 100 times to the same link. Read-then-write loses clicks; letting the
// database do the addition does not.
func lostUpdate(ctx context.Context, pool *pgxpool.Pool) map[string]int64 {
	res := map[string]int64{"expected": 5000}
	for _, mode := range []string{"read_then_write", "atomic_update"} {
		pool.Exec(ctx, "INSERT INTO link_stats (code, clicks) VALUES ('drill', 0) ON CONFLICT (code) DO UPDATE SET clicks = 0")
		var wg sync.WaitGroup
		for w := 0; w < 50; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for i := 0; i < 100; i++ {
					if mode == "atomic_update" {
						pool.Exec(ctx, "UPDATE link_stats SET clicks = clicks + 1 WHERE code = 'drill'")
						continue
					}
					var n int64
					pool.QueryRow(ctx, "SELECT clicks FROM link_stats WHERE code = 'drill'").Scan(&n)
					pool.Exec(ctx, "UPDATE link_stats SET clicks = $1 WHERE code = 'drill'", n+1)
				}
			}()
		}
		wg.Wait()
		var got int64
		pool.QueryRow(ctx, "SELECT clicks FROM link_stats WHERE code = 'drill'").Scan(&got)
		res[mode] = got
	}
	return res
}

// writeSkew: two doctors are on call; the rule is that at least one must stay on call. Both ask to go off at the same
// moment, each checking the rule first. 1,000 trials per isolation level; count how often nobody is left on call and
// how many transactions the database refused.
func writeSkew(ctx context.Context, pool *pgxpool.Pool) map[string]map[string]int {
	res := map[string]map[string]int{}
	for _, level := range []pgx.TxIsoLevel{pgx.ReadCommitted, pgx.Serializable} {
		broken, refused := 0, 0
		for trial := 0; trial < 1000; trial++ {
			pool.Exec(ctx, "UPDATE doctors SET on_call = true")
			var wg sync.WaitGroup
			var mu sync.Mutex
			start := make(chan struct{})
			for _, name := range []string{"alice", "bob"} {
				wg.Add(1)
				go func(name string) {
					defer wg.Done()
					<-start
					tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: level})
					if err != nil {
						return
					}
					defer tx.Rollback(ctx)
					var n int
					tx.QueryRow(ctx, "SELECT count(*) FROM doctors WHERE on_call").Scan(&n)
					if n >= 2 {
						tx.Exec(ctx, "UPDATE doctors SET on_call = false WHERE name = $1", name)
					}
					if err := tx.Commit(ctx); err != nil {
						mu.Lock()
						refused++
						mu.Unlock()
					}
				}(name)
			}
			close(start)
			wg.Wait()
			var left int
			pool.QueryRow(ctx, "SELECT count(*) FROM doctors WHERE on_call").Scan(&left)
			if left == 0 {
				broken++
			}
		}
		res[string(level)] = map[string]int{"trials": 1000, "nobody_on_call": broken, "refused_commits": refused}
	}
	return res
}
