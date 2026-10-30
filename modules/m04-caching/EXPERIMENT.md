# Module 4 — caching: hit ratio, stampede, synchronised expiry

## Questions
- a. With a cache that holds about a tenth of 100,000 pages, how much database work does it remove for skewed (Zipf)
  traffic, and for evenly spread traffic?
- b1. When the cache is wiped while every request asks for one slow page, how many identical database queries follow,
  without and with single-flight?
- b2. When 2,000 pages are cached in one burst with the same 20 s lifetime, how hard does the expiry hit the database,
  without and with 50% TTL jitter?

## Environment
One app copy (half a core), Redis 8.10.2, k6 1.8.2, 4-vCPU AMD EPYC-Milan host, 30/10/2026. 400 page requests/s for
60 s. a: `make m04` (cache capped at 4 MB). b: `tools/run-m04b.sh 3` (cache 64 MB; a sampler reads the app's database
query counter every 0.5 s). 3 runs each.

## Results (mean of 3 runs, min–max in brackets)
### a. Hit ratio (`results/results.json`)
| traffic | hit ratio | database queries/s | p50 | p99 |
|---|---|---|---|---|
| no cache | 0% | 400 | 1.0 ms | 37.7 ms |
| evenly spread | 8.4% | 366 | 1.2 ms | 43.8 ms |
| Zipf | 62.8% | 149 | 0.4 ms | 18.7 ms |

### b1. Stampede after a wipe (`results-b/results.json`; one page, building it takes 500 ms, wipe at 32 s)
| | queries in the 10 s before | queries in the 3 s after | p99 | max |
|---|---|---|---|---|
| no single-flight | 0 | 158 (134–201) | 502 ms | 535 ms |
| single-flight | 0 | 0.7 (0–1) | 220 ms | 519 ms |

### b2. Synchronised expiry (2,000 pages warmed together, TTL 20 s, building a page takes 100 ms)
| | worst 1 s of database queries | total queries in 60 s | p99 |
|---|---|---|---|
| no jitter | 180 (165–207) | 3,812 | 104 ms |
| 50% jitter | 119 (114–123) | 4,975 | 104 ms |

Jitter here shortens each lifetime by a random 0–50%, so pages live 15 s on average instead of 20 s and are refilled
more often: the total goes up while the worst second goes down by a third. A jitter that spreads lifetimes around the
target (for example 20 s ± 25%) keeps the average and only flattens the peak. At 400 req/s over 2,000 pages each page
is asked for about every 5 s, so traffic itself already spreads the refills; the peak is lower than "2,000 at once".

## What this does not show
- How stale data affects a real product.
- A cache spread over several machines, or eviction policy choices.
- Single-flight across several app copies (it is per process here).

## Fixes made while building this lab
- The first two designs of b showed no clear signal: a wipe also emptied every other page, so the hot page's extra
  queries drowned in ordinary misses; and 2,000 pages expiring together were a ripple on top of misses for pages
  nobody had warmed. The third design sends every request to one page (b1) and only asks for the 2,000 warmed pages
  (b2, `KEYS=set` in `traffic.js`). The tables above are from that design.
