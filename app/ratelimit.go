package main

// Module 9: rate limiting GET /api/limited (a cheap endpoint, so only the limiter is measured).
//
//	RL_MODE   local        a token bucket in this app copy's memory
//	          redis-bucket one token bucket per client in Redis (a Lua script), shared by every copy
//	          redis-window one counter per client per whole second in Redis (fixed window)
//	RL_RATE   requests per second per client (default 10); the bucket holds RL_RATE tokens
//	RL_FAIL   open | closed: what to do when Redis does not answer (default open)
//	RL_CLIENT xff-left  = the first X-Forwarded-For address (what the client claims; can be faked)
//	          xff-right = the last one (added by our own proxy; what the server actually saw)
//
// Allowed requests answer 200, refused ones 429; a Redis failure answers 200 (open) or 503 (closed).

import (
	"context"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

type limiter struct {
	mode, fail, client string
	rate               float64
	rdb                *redis.Client
	mu                 sync.Mutex
	buckets            map[string]*bucket
}

type bucket struct {
	tokens float64
	last   time.Time
}

// tokenBucketLua refills the client's bucket for the time passed, then takes one token if there is one.
var tokenBucketLua = redis.NewScript(`
local rate, now = tonumber(ARGV[1]), tonumber(ARGV[2])
local b = redis.call('HMGET', KEYS[1], 'tokens', 'last')
local tokens, last = tonumber(b[1]) or rate, tonumber(b[2]) or now
tokens = math.min(rate, tokens + (now - last) / 1000 * rate)
local ok = 0
if tokens >= 1 then tokens = tokens - 1; ok = 1 end
redis.call('HSET', KEYS[1], 'tokens', tokens, 'last', now)
redis.call('PEXPIRE', KEYS[1], 10000)
return ok`)

func newLimiter() *limiter {
	l := &limiter{mode: os.Getenv("RL_MODE"), fail: os.Getenv("RL_FAIL"), client: os.Getenv("RL_CLIENT"), buckets: map[string]*bucket{}}
	if l.mode == "" {
		return nil
	}
	l.rate, _ = strconv.ParseFloat(os.Getenv("RL_RATE"), 64)
	if l.rate <= 0 {
		l.rate = 10
	}
	if strings.HasPrefix(l.mode, "redis") {
		opt, err := redis.ParseURL(os.Getenv("REDIS_URL"))
		if err != nil {
			panic(err)
		}
		opt.ReadTimeout, opt.WriteTimeout, opt.DialTimeout, opt.MaxRetries = 200*time.Millisecond, 200*time.Millisecond, 200*time.Millisecond, -1
		l.rdb = redis.NewClient(opt)
	}
	return l
}

func (l *limiter) clientOf(r *http.Request) string {
	parts := strings.Split(r.Header.Get("X-Forwarded-For"), ",")
	if l.client == "xff-left" && parts[0] != "" {
		return strings.TrimSpace(parts[0])
	}
	if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
		return last
	}
	return r.RemoteAddr
}

// allow says whether this request may go through; err is set when Redis could not be asked.
func (l *limiter) allow(ctx context.Context, client string) (bool, error) {
	now := time.Now()
	switch l.mode {
	case "local":
		l.mu.Lock()
		defer l.mu.Unlock()
		b := l.buckets[client]
		if b == nil {
			b = &bucket{tokens: l.rate, last: now}
			l.buckets[client] = b
		}
		b.tokens = min(l.rate, b.tokens+now.Sub(b.last).Seconds()*l.rate)
		b.last = now
		if b.tokens >= 1 {
			b.tokens--
			return true, nil
		}
		return false, nil
	case "redis-bucket":
		ok, err := tokenBucketLua.Run(ctx, l.rdb, []string{"rl:" + client}, l.rate, now.UnixMilli()).Int()
		return ok == 1, err
	default: // redis-window
		key := "rw:" + client + ":" + strconv.FormatInt(now.Unix(), 10)
		n, err := l.rdb.Incr(ctx, key).Result()
		if err == nil {
			l.rdb.Expire(ctx, key, 2*time.Second)
		}
		return float64(n) <= l.rate, err
	}
}

func (l *limiter) serve(w http.ResponseWriter, r *http.Request) {
	if l == nil {
		w.WriteHeader(http.StatusOK)
		return
	}
	ok, err := l.allow(r.Context(), l.clientOf(r))
	switch {
	case err != nil && l.fail == "closed":
		w.WriteHeader(http.StatusServiceUnavailable)
	case err != nil:
		w.WriteHeader(http.StatusOK)
	case ok:
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusTooManyRequests)
	}
}
