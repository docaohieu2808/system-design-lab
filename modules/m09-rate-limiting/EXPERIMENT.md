# Module 9 — rate limiting

## Questions
With a limit of 10 requests per second per client:
- Three app copies: how much gets through with a bucket in each copy vs one shared bucket in Redis?
- A burst just before and just after a second boundary: fixed window vs token bucket?
- Redis paused for 10 s: what do fail open and fail closed do?
- A client that fakes `X-Forwarded-For` on every request: which address should the limiter trust?
- Added 06/11/2026: a sliding-window log next to the fixed window and the token bucket (steady rate, the boundary
  burst, Redis work per request, bytes per client); one app copy as the baseline; and when exactly the freeze takes
  hold in the Redis outage test.

## Environment
Three app copies behind Traefik v3.7.16, Redis 8.10.2, k6 1.8.2, 4-vCPU AMD EPYC-Milan host, 30/10/2026.
`make m09`, 3 runs.

## Results (mean of 3 runs, min–max in brackets; `results/results.json`)
| experiment | allowed |
|---|---|
| bucket in each of 3 copies | 30.9 per s (30.87–30.9) |
| one shared bucket in Redis | 10.3 per s (10.30–10.33) |
| fixed window, burst across a second boundary | 20 in 200 ms |
| token bucket, same burst | 11 in 200 ms |
| spoofed header, limit by first address | 50.1 per s (every request) |
| spoofed header, limit by last address (added by our proxy) | 10.3 per s |
| spoofed header, proxy default (client's header replaced) | 10.3 per s |

### Redis paused for 10 s (counts within each phase)
| | phase | allowed per s | refused (429) | errors (503) |
|---|---|---|---|---|
| fail open | before | 10.9 | 392 | 0 |
| | during | 44.0 | 61 | 0 |
| | after | 16.8 | 333 | 0 |
| fail closed | before | 10.9 | 392 | 0 |
| | during | 1.5 | 58 | 428 |
| | after | 9.5 | 335 | 71 |

Not yet checked against per-request timestamps: the refusals counted "during" are likely from just before the pause
took hold, and the 503s "after" from requests that were waiting on the paused Redis when it came back.

## Added 06/11/2026: sliding window, one-copy baseline, outage timing (`make m09-sliding`, `results-sliding/results.json`)
`tools/run-m09-sliding.sh`: 3 runs, all 10 arms inside every run, interleaved (the order rotates each run), quiet gate
25/2 before every arm (background it saw: 9–25% busy, steal 0). Same limit (10 per second per client), same client
(50 per second). The old numbers above are not re-measured; the new arms are compared with each other, and the
fixed-window and bucket rows below come from this run.
New limiter mode `RL_MODE=redis-sliding` (`app/ratelimit.go`): a Redis sorted set per client holding the times of the
last second's allowed requests; one Lua script per request removes entries older than a second, counts, and adds the
new one if fewer than 10 are left. Refused requests are not logged.
Load generator: k6 used about 0.05 cores (limit 2) in the steady arms, so it had plenty of room.

### Steady rate (50 requests per second offered, limit 10; mean of the three 10-second phases)
| arm | allowed per second |
|---|---|
| one app copy, bucket in memory | 10.3 (10.3–10.3) |
| three copies, a bucket in each | 30.89 (30.87–30.9) |
| fixed window in Redis | 10.26 (10.13–10.33) |
| token bucket in Redis | 10.3 (10.3–10.3) |
| sliding-window log in Redis | 10.0 (10.0–10.0) |

The bucket lets 10.3 through because it starts full (10 tokens) and then refills at 10 per second: 10 + 30 s × 10 over
30 s is 10.33. The sliding log never exceeds 10 in any one-second span, so it lands on 10.0. The three-copy row is the
one-copy row times 3 (30.89 against 3 × 10.3 = 30.9): separate buckets add up.

### The edge of the window (5 pairs of 20 + 20 requests across a second boundary, 40 per pair)
| arm | allowed of 40 | refused (5 pairs) |
|---|---|---|
| fixed window | 20 (20–20) | 100 |
| token bucket | 11 (11–11) | 145 |
| sliding-window log | 10 (10–10) | 150 |

### Redis work per request (steady arms, `INFO commandstats` after `CONFIG RESETSTAT`, about 1,500 requests per arm)
| arm | round trips from the app | commands Redis executes | bytes of one client's key (`MEMORY USAGE`, 15 s in) |
|---|---|---|---|
| fixed window | 2.0 (INCR, EXPIRE) | 2.0 | 51 per key; a client has up to 3 keys alive (2 s lifetime), so about 150 |
| token bucket | 1.0 (one script call) | 3.0 (HMGET, HSET, PEXPIRE) | 91–92 (a hash, listpack) |
| sliding-window log | 1.0 (one script call) | 3.2 (ZREMRANGEBYSCORE, ZCARD, PEXPIRE, and ZADD for the 1 in 5 that is allowed) | 397 (a sorted set of 10 entries, listpack) |

The sliding log's key is about 4 times the bucket's at a limit of 10; it grows with the limit (one entry per allowed
request in the last second), the bucket does not.

### Redis paused for 10 s: when does the freeze take hold? (token bucket, 3 copies; 3 runs per arm, every request's finish time kept)
The runner pauses Redis about 12 s after it starts k6, which is 1.1 s (1.03–1.2) after the "during" block began; that
offset is the runner's timing, not a property of the limiter. Offsets below are from the pause command.
| | last refusal (429) | first 503 (fail closed) |
|---|---|---|
| from the pause command | 0.19 s open (0.16–0.21), 0.18 s closed (0.15–0.19) | 0.40 s (0.37–0.41) |
| from the start of the "during" block | 1.31 s open (1.30–1.34), 1.27 s closed (1.18–1.38) | 1.49 s (1.40–1.60) |

So from the pause command, refusals stop within about 0.2 s (the pause call itself takes part of that), and a request
waits out the 200 ms Redis timeout before it fails, so the first 503 arrives about 0.4 s after the command. Measured from
the block start in this runner, the freeze has taken hold by about 1.3 s and the first failure shows at about 1.5 s. After
the unpause, the last 503 comes 0.20 s (0.17–0.23) after the command (requests that were still waiting on the paused
Redis). The old per-phase table above counts these seconds inside "during" and "after".

## What it does not show
- A sliding-window counter (two fixed windows weighted by overlap): only the log is built. Limits per API key from a
  config file (left as the capstone 13.2 exercise).
- The sliding log at a large limit (memory and CPU grow with it); 10 per second only.
- The outage offsets depend on when the runner pauses Redis; they show the lag after the pause, not a fixed "1.5 s".
- A Redis replica or cluster behind the limiter.
