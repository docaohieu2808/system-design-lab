package main

// Module 12: selling the seat under a lock held in Redis (the fourth way), and what a lease that expires mid-work does.
//
//	LOCK=redis   adds the arm "redis_lock" to `drill tickets`: every buyer takes the lock with SET ... NX PX, runs the same
//	             check-then-insert as the broken way, and gives the lock back only if it is still theirs
//	ARMS         comma list of arms to run instead of the default (for example redis_lock_stall,redis_lock_stall_fence)
//	redis_lock_stall        the first STALL_N (default 3) lock holders freeze for STALL_MS (default 5000) after their check
//	                        and before their write, while the lock lasts only LOCK_LEASE_MS (default 1000 here): the lease
//	                        expires mid-work, someone else takes the lock, and the frozen holder then writes with a stale check
//	redis_lock_stall_fence  the same, but every grant carries a number that only goes up (a fencing token) and the database
//	                        refuses a write whose number is lower than one it has already seen

import (
	"context"
	"fmt"
	"math/rand/v2"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

const lockKey, tokenKey = "lock:event:1", "lock:event:1:token"

// release deletes the lock only if it still holds this holder's value: check and delete as one step.
var release = redis.NewScript(`if redis.call("get", KEYS[1]) == ARGV[1] then return redis.call("del", KEYS[1]) else return 0 end`)

// redisLockModes returns the Redis-lock arms. They need a Redis (REDIS_URL) next to the app.
func redisLockModes(ctx context.Context, pool *pgxpool.Pool) (map[string]func(buyer int) error, func()) {
	rdb := redisClient()
	var stalled atomic.Int64
	buyer := func(lease time.Duration, stall, fence bool) func(b int) error {
		return func(b int) error {
			me := fmt.Sprintf("%d-%d", b, rand.Int64())
			wait := time.Now().Add(60 * time.Second)
			for { // take the lock: set the key only if nobody holds it, and let it expire on its own
				ok, _ := rdb.SetNX(ctx, lockKey, me, lease).Result()
				if ok {
					break
				}
				if time.Now().After(wait) {
					return nil
				}
				time.Sleep(time.Duration(20+rand.IntN(20)) * time.Millisecond)
			}
			defer release.Run(ctx, rdb, []string{lockKey}, me)
			token, _ := rdb.Incr(ctx, tokenKey).Result() // a number that only goes up with every grant
			var sold int
			if err := pool.QueryRow(ctx, "SELECT count(*) FROM orders WHERE event_id = 1").Scan(&sold); err != nil || sold >= 100 {
				return err
			}
			if stall && stalled.Add(1) <= int64(envInt("STALL_N", 3)) {
				time.Sleep(time.Duration(envInt("STALL_MS", 5000)) * time.Millisecond) // frozen: the lease runs out meanwhile
			}
			if fence { // the database refuses a write that carries a lower number than one it has already seen
				tx, err := pool.Begin(ctx)
				if err != nil {
					return err
				}
				defer tx.Rollback(ctx)
				tag, err := tx.Exec(ctx, "UPDATE events SET last_token = $1 WHERE id = 1 AND last_token <= $1", token)
				if err != nil || tag.RowsAffected() == 0 {
					return err
				}
				if _, err := tx.Exec(ctx, "INSERT INTO orders (event_id, buyer) VALUES (1, $1)", b); err != nil {
					return err
				}
				return tx.Commit(ctx)
			}
			_, err := pool.Exec(ctx, "INSERT INTO orders (event_id, buyer) VALUES (1, $1)", b)
			return err
		}
	}
	lease := time.Duration(envInt("LOCK_LEASE_MS", 5000)) * time.Millisecond
	stallLease := time.Duration(envInt("STALL_LEASE_MS", 1000)) * time.Millisecond
	reset := func() { rdb.Del(ctx, lockKey, tokenKey); stalled.Store(0) }
	return map[string]func(int) error{
		"redis_lock":             buyer(lease, false, false),
		"redis_lock_stall":       buyer(stallLease, true, false),
		"redis_lock_stall_fence": buyer(stallLease, true, true),
	}, reset
}
