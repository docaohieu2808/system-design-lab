package main

// Drills for Modules 7 and 12: run once, print one JSON line.
//
//	shortener drill rehash    1,000,000 keys on 3 shards, then 4: how many keys change shard, modulo vs consistent hashing
//	shortener drill tickets   100 seats, 1,000 buyers at once, four ways to sell them: how many seats are oversold

import (
	"context"
	"fmt"
	"hash/fnv"
	"sort"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func hash64(s string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(s))
	return h.Sum64()
}

// ring is consistent hashing: every shard owns `vnodes` points on a circle; a key belongs to the next point clockwise.
type ring struct {
	points []uint64
	owner  map[uint64]int
}

func newRing(shards, vnodes int) *ring {
	r := &ring{owner: map[uint64]int{}}
	for s := 0; s < shards; s++ {
		for v := 0; v < vnodes; v++ {
			p := hash64(fmt.Sprintf("shard-%d-vnode-%d", s, v))
			r.points = append(r.points, p)
			r.owner[p] = s
		}
	}
	sort.Slice(r.points, func(i, j int) bool { return r.points[i] < r.points[j] })
	return r
}

func (r *ring) shard(key string) int {
	h := hash64(key)
	i := sort.Search(len(r.points), func(i int) bool { return r.points[i] >= h })
	if i == len(r.points) {
		i = 0
	}
	return r.owner[r.points[i]]
}

func rehash() map[string]any {
	const keys = 1_000_000
	r3, r4 := newRing(3, 100), newRing(4, 100)
	movedMod, movedRing := 0, 0
	load4 := make([]int, 4)
	for k := 1; k <= keys; k++ {
		key := base62(int64(k))
		h := hash64(key)
		if h%3 != h%4 {
			movedMod++
		}
		a, b := r3.shard(key), r4.shard(key)
		if a != b {
			movedRing++
		}
		load4[b]++
	}
	return map[string]any{"keys": keys, "from_shards": 3, "to_shards": 4,
		"moved_modulo_pct": 100 * float64(movedMod) / keys, "moved_consistent_pct": 100 * float64(movedRing) / keys,
		"consistent_keys_per_shard_after": load4, "vnodes_per_shard": 100}
}

// tickets: each of 1,000 buyers tries to buy one seat for an event with 100 seats, all at once.
func tickets(ctx context.Context, pool *pgxpool.Pool) map[string]any {
	pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS events (id int PRIMARY KEY, seats int NOT NULL, sold int NOT NULL DEFAULT 0);
		CREATE TABLE IF NOT EXISTS orders (id bigserial PRIMARY KEY, event_id int NOT NULL, buyer int NOT NULL)`)
	modes := map[string]func(buyer int) error{
		// read how many are sold, and if there is room, write an order: two buyers can both see room for the last seat
		"check_then_insert": func(b int) error {
			var sold int
			if err := pool.QueryRow(ctx, "SELECT count(*) FROM orders WHERE event_id = 1").Scan(&sold); err != nil {
				return err
			}
			if sold >= 100 {
				return nil
			}
			_, err := pool.Exec(ctx, "INSERT INTO orders (event_id, buyer) VALUES (1, $1)", b)
			return err
		},
		// the same check, but holding a lock on the event row: buyers queue up on it
		"select_for_update": func(b int) error {
			tx, err := pool.Begin(ctx)
			if err != nil {
				return err
			}
			defer tx.Rollback(ctx)
			var seats, sold int
			if err := tx.QueryRow(ctx, "SELECT seats, sold FROM events WHERE id = 1 FOR UPDATE").Scan(&seats, &sold); err != nil {
				return err
			}
			if sold < seats {
				tx.Exec(ctx, "UPDATE events SET sold = sold + 1 WHERE id = 1")
				tx.Exec(ctx, "INSERT INTO orders (event_id, buyer) VALUES (1, $1)", b)
			}
			return tx.Commit(ctx)
		},
		// a named lock in Postgres around the check-then-insert
		"advisory_lock": func(b int) error {
			tx, err := pool.Begin(ctx)
			if err != nil {
				return err
			}
			defer tx.Rollback(ctx)
			tx.Exec(ctx, "SELECT pg_advisory_xact_lock(1)")
			var sold int
			tx.QueryRow(ctx, "SELECT count(*) FROM orders WHERE event_id = 1").Scan(&sold)
			if sold < 100 {
				tx.Exec(ctx, "INSERT INTO orders (event_id, buyer) VALUES (1, $1)", b)
			}
			return tx.Commit(ctx)
		},
		// one statement that only succeeds while there is room: no separate check at all
		"conditional_update": func(b int) error {
			tag, err := pool.Exec(ctx, "UPDATE events SET sold = sold + 1 WHERE id = 1 AND sold < seats")
			if err != nil || tag.RowsAffected() == 0 {
				return err
			}
			_, err = pool.Exec(ctx, "INSERT INTO orders (event_id, buyer) VALUES (1, $1)", b)
			return err
		},
	}
	out := map[string]any{"seats": 100, "buyers": 1000}
	for _, name := range []string{"check_then_insert", "select_for_update", "advisory_lock", "conditional_update"} {
		pool.Exec(ctx, "TRUNCATE orders; INSERT INTO events (id, seats, sold) VALUES (1, 100, 0) ON CONFLICT (id) DO UPDATE SET sold = 0")
		var wg sync.WaitGroup
		start, gate := time.Now(), make(chan struct{})
		for b := 0; b < 1000; b++ {
			wg.Add(1)
			go func(b int) {
				defer wg.Done()
				<-gate
				modes[name](b)
			}(b)
		}
		close(gate)
		wg.Wait()
		var orders int
		pool.QueryRow(ctx, "SELECT count(*) FROM orders WHERE event_id = 1").Scan(&orders)
		out[name] = map[string]any{"orders": orders, "oversold": max(0, orders-100), "ms": time.Since(start).Milliseconds()}
	}
	return out
}
