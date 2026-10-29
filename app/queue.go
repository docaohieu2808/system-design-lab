package main

// Module 10: moving slow work off the request, and the things that go wrong once it is a queue.
//
//	POST /api/links   with SIDE_WORK_MS > 0 creating a link also does slow side work (think: fetch the target page's
//	                  title); QUEUE=1 puts that work on a Redis stream instead and answers at once
//	shortener drill worker      consumes the stream: WORKERS goroutines, SIDE_WORK_MS each job, prints its stats on exit
//	shortener drill charges     a payment worker that crashes after charging but before acknowledging, CRASH_PCT of
//	                            the time; the message is redelivered. IDEMPOTENT=1 records each message id once.
//	shortener drill poison      one message that always fails among good ones; DLQ_AFTER=3 parks it after 3 tries,
//	                            DLQ_AFTER=0 retries it forever

import (
	"context"
	"math/rand/v2"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

const stream, group = "previews", "workers"

func envInt(name string, def int) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return n
	}
	return def
}

func redisClient() *redis.Client {
	opt, err := redis.ParseURL(os.Getenv("REDIS_URL"))
	if err != nil {
		panic(err)
	}
	return redis.NewClient(opt)
}

var sideQueue *redis.Client

// sideWork runs after a link is created: inline, or as a job on the stream.
func sideWork(ctx context.Context, code string) {
	ms := envInt("SIDE_WORK_MS", 0)
	if ms <= 0 {
		return
	}
	if os.Getenv("QUEUE") == "1" {
		if sideQueue == nil {
			sideQueue = redisClient()
		}
		sideQueue.XAdd(ctx, &redis.XAddArgs{Stream: stream, Values: map[string]any{"code": code, "at": time.Now().UnixMilli()}})
		return
	}
	time.Sleep(time.Duration(ms) * time.Millisecond)
}

// worker consumes jobs for WORKER_SECONDS and prints how many it did and how late they were picked up.
func worker(ctx context.Context) map[string]any {
	rdb, n, ms := redisClient(), envInt("WORKERS", 1), envInt("SIDE_WORK_MS", 200)
	rdb.XGroupCreateMkStream(ctx, stream, group, "0")
	deadline := time.Now().Add(time.Duration(envInt("WORKER_SECONDS", 60)) * time.Second)
	var done atomic.Int64
	var mu sync.Mutex
	var waits []float64
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for time.Now().Before(deadline) {
				res, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{Group: group, Consumer: "w" + strconv.Itoa(i),
					Streams: []string{stream, ">"}, Count: 1, Block: 500 * time.Millisecond}).Result()
				if err != nil || len(res) == 0 || len(res[0].Messages) == 0 {
					continue
				}
				m := res[0].Messages[0]
				at, _ := strconv.ParseInt(m.Values["at"].(string), 10, 64)
				mu.Lock()
				waits = append(waits, float64(time.Now().UnixMilli()-at))
				mu.Unlock()
				time.Sleep(time.Duration(ms) * time.Millisecond)
				rdb.XAck(ctx, stream, group, m.ID)
				done.Add(1)
			}
		}(i)
	}
	wg.Wait()
	backlog, _ := rdb.XPending(ctx, stream, group).Result()
	lag, _ := rdb.XLen(ctx, stream).Result()
	return map[string]any{"workers": n, "done": done.Load(), "wait_ms": percentiles(waits), "stream_len": lag,
		"pending": backlog.Count}
}

func percentiles(xs []float64) map[string]float64 {
	if len(xs) == 0 {
		return nil
	}
	s := append([]float64(nil), xs...)
	sortFloat(s)
	at := func(p float64) float64 { return s[int(p*float64(len(s)-1))] }
	return map[string]float64{"p50": at(.5), "p99": at(.99), "max": s[len(s)-1]}
}

// charges: 1,000 payment jobs; the worker charges, then crashes CRASH_PCT of the time before acknowledging, so the
// job is handed out again. Counts charges per job.
func charges(ctx context.Context, pool *pgxpool.Pool) map[string]any {
	rdb := redisClient()
	rdb.Del(ctx, "payments")
	rdb.XGroupCreateMkStream(ctx, "payments", group, "0")
	pool.Exec(ctx, `DROP TABLE IF EXISTS charges; CREATE TABLE charges (id bigserial PRIMARY KEY, job text NOT NULL,
		idem text UNIQUE)`)
	for i := 0; i < 1000; i++ {
		rdb.XAdd(ctx, &redis.XAddArgs{Stream: "payments", Values: map[string]any{"job": strconv.Itoa(i)}})
	}
	crash, idem := envInt("CRASH_PCT", 10), os.Getenv("IDEMPOTENT") == "1"
	crashes := 0
	for {
		// first new jobs, then jobs whose worker "crashed" (unacknowledged for more than 50 ms)
		msgs, _, _ := rdb.XAutoClaim(ctx, &redis.XAutoClaimArgs{Stream: "payments", Group: group, Consumer: "w",
			MinIdle: 50 * time.Millisecond, Start: "0", Count: 50}).Result()
		if len(msgs) == 0 {
			res, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{Group: group, Consumer: "w", Streams: []string{"payments", ">"},
				Count: 50, Block: 100 * time.Millisecond}).Result()
			if err != nil || len(res) == 0 {
				if p, _ := rdb.XPending(ctx, "payments", group).Result(); p.Count == 0 {
					break
				}
				time.Sleep(60 * time.Millisecond)
				continue
			}
			msgs = res[0].Messages
		}
		for _, m := range msgs {
			job := m.Values["job"].(string)
			if idem { // the message id is the idempotency key: a second charge for the same job is a no-op
				pool.Exec(ctx, "INSERT INTO charges (job, idem) VALUES ($1, $2) ON CONFLICT (idem) DO NOTHING", job, m.ID)
			} else {
				pool.Exec(ctx, "INSERT INTO charges (job) VALUES ($1)", job)
			}
			if rand.IntN(100) < crash { // charged, then died before saying so
				crashes++
				continue
			}
			rdb.XAck(ctx, "payments", group, m.ID)
		}
	}
	var total, distinct int
	pool.QueryRow(ctx, "SELECT count(*), count(DISTINCT job) FROM charges").Scan(&total, &distinct)
	return map[string]any{"jobs": 1000, "crashes": crashes, "charges": total, "jobs_charged": distinct,
		"double_charges": total - distinct, "idempotent": idem}
}

// poison: 200 good jobs and one that always fails. Counts attempts on the poison job and how many good jobs finished
// within 10 s.
func poison(ctx context.Context) map[string]any {
	rdb, dlqAfter := redisClient(), int64(envInt("DLQ_AFTER", 0))
	rdb.Del(ctx, "jobs", "jobs-dead")
	rdb.XGroupCreateMkStream(ctx, "jobs", group, "0")
	rdb.XAdd(ctx, &redis.XAddArgs{Stream: "jobs", Values: map[string]any{"poison": "1"}})
	for i := 0; i < 200; i++ {
		rdb.XAdd(ctx, &redis.XAddArgs{Stream: "jobs", Values: map[string]any{"poison": "0"}})
	}
	good, poisonTries, parked := 0, 0, 0
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) && good < 200 {
		// one worker, strict order: retry what is pending before taking anything new (an ordered queue)
		msgs, _, _ := rdb.XAutoClaim(ctx, &redis.XAutoClaimArgs{Stream: "jobs", Group: group, Consumer: "w",
			MinIdle: 20 * time.Millisecond, Start: "0", Count: 1}).Result()
		if len(msgs) == 0 {
			if p, _ := rdb.XPending(ctx, "jobs", group).Result(); p.Count > 0 {
				time.Sleep(25 * time.Millisecond) // the failed job is not idle long enough yet: wait for it, keep order
				continue
			}
			res, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{Group: group, Consumer: "w", Streams: []string{"jobs", ">"},
				Count: 1, Block: 50 * time.Millisecond}).Result()
			if err != nil || len(res) == 0 {
				continue
			}
			msgs = res[0].Messages
		}
		m := msgs[0]
		time.Sleep(5 * time.Millisecond) // the work itself
		if m.Values["poison"] == "1" {
			poisonTries++
			if p, _ := rdb.XPendingExt(ctx, &redis.XPendingExtArgs{Stream: "jobs", Group: group, Start: m.ID, End: m.ID, Count: 1}).Result(); dlqAfter > 0 && len(p) == 1 && p[0].RetryCount >= dlqAfter {
				rdb.XAdd(ctx, &redis.XAddArgs{Stream: "jobs-dead", Values: m.Values})
				rdb.XAck(ctx, "jobs", group, m.ID)
				parked++
			}
			continue
		}
		rdb.XAck(ctx, "jobs", group, m.ID)
		good++
	}
	return map[string]any{"dlq_after": dlqAfter, "good_jobs": 200, "good_done_in_10s": good, "poison_attempts": poisonTries,
		"parked_in_dlq": parked}
}
