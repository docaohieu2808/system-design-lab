# Module 9 — rate limiting

## Questions
With a limit of 10 requests per second per client:
- Three app copies: how much gets through with a bucket in each copy vs one shared bucket in Redis?
- A burst just before and just after a second boundary: fixed window vs token bucket?
- Redis paused for 10 s: what do fail open and fail closed do?
- A client that fakes `X-Forwarded-For` on every request: which address should the limiter trust?

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

## What it does not show
- Sliding-window counters, or limits per API key from a config file (left as the capstone 13.2 exercise).
- A Redis replica or cluster behind the limiter.
