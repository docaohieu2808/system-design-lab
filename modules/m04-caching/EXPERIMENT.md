# Module 4 — caching: hit ratio, stampede, synchronised expiry

## Questions
- a. With a cache that holds about a tenth of 100,000 pages, how much database work does it remove for skewed (Zipf)
  traffic, and for evenly spread traffic?
- b1. When the cache is wiped while every request asks for one slow page, how many identical database queries follow,
  without and with single-flight?
- b2. When 2,000 pages are cached in one burst with the same 20 s lifetime, how hard does the expiry hit the database,
  and how long do users wait, with no fix, with 50% TTL jitter, and with stale-while-revalidate?

## Environment
One app copy (half a core), Redis 8.10.2, k6 1.8.2, 4-vCPU AMD EPYC-Milan host, 30/10/2026. 400 page requests/s for
60 s. `make m04` runs both parts. a: `tools/run-m04.sh` (cache capped at 4 MB). b: `tools/run-m04b.sh` (cache 64 MB;
a sampler reads the app's database query counter every 0.5 s). Quiet-machine gate before every run; the background CPU
it saw is saved in each run's `.gate` file and in `results*.json` (`background_busy_pct`). k6 had room (the app, at half
a core, is the limit, not the load generator).

**Status of the numbers: b below is a smoke run (1 run, background 9-15%), replaced by the session run (3 runs).** The
3-run numbers for a, for b1 and for the first two b2 arms are from 30/10/2026 (git history of `results-b/`).

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
| no single-flight | 0 | 129 (102–159) | 502 ms | 538 ms |
| single-flight | 0 | 1 (1–1) | 216 ms | 512 ms |

Smoke run (1 run) of b1: no single-flight 202 queries in the 3 s after (p99 502 ms); single-flight 1 (p99 213 ms).
Stale-while-revalidate is not an arm here on purpose: a flush deletes the stale copy too, so there is nothing to serve
while rebuilding. It only helps when entries expire, not when they vanish.

### b2. Synchronised expiry (2,000 pages warmed together, TTL 20 s, building a page takes 100 ms)
3-run numbers (30/10/2026) for the first two rows; the swr row exists only as a smoke run so far.
| | worst 1 s of database queries | total queries in 60 s | p99 |
|---|---|---|---|
| no fix | 183 (174–193) | 3,805 | 104 ms |
| 50% jitter (lifetimes 15–25 s) | 119 (112–123) | 3,804 | 104 ms |
| stale-while-revalidate (smoke, 1 run) | 175 | 3,740 | 16 ms |

Smoke run, all three arms, same session: no fix 175 / 3,834 / 109 ms; jitter 131 / 3,785 / 106 ms; swr 175 / 3,740 /
16 ms.

The worst second drops by about a third with jitter while the total stays the same: jitter moves refills apart, it
doesn't remove them. Stale-while-revalidate does the opposite: the refills are as many and as bunched as with no fix
(peak 175, same as no fix), but no user waits for them, because every request is answered from the old copy while one
background refresh per page rebuilds it, so p99 falls from about 105 ms (one 100 ms rebuild) to about 16 ms. It protects
the user, not the database; jitter protects the database. They can be combined (not measured here). The price is that
a page can be up to one TTL older than the nominal lifetime when asked just before its refresh lands. At 400 req/s over 2,000 pages each page is asked for about every 5 s, so traffic itself already spreads the
refills a little; the peak is lower than "2,000 at once".

Note: the first version of jitter only shortened lifetimes (TTL minus up to 50%), so pages lived 15 s on average
instead of 20 s and the total rose to 4,975. `app/cache.go` now spreads lifetimes evenly over TTL ± 25%; the tables
are from the rerun after that change (b1 was re-measured in the same run; it does not use jitter).

## What this does not show
- How stale data affects a real product.
- A cache spread over several machines, or eviction policy choices.
- Single-flight across several app copies (it is per process here); the same holds for the one background refresh.
- How many pages go stale at once in real traffic, or the stale-while-revalidate and jitter combination.

## Fixes made while building this lab
- The first two designs of b showed no clear signal: a wipe also emptied every other page, so the hot page's extra
  queries drowned in ordinary misses; and 2,000 pages expiring together were a ripple on top of misses for pages
  nobody had warmed. The third design sends every request to one page (b1) and only asks for the 2,000 warmed pages
  (b2, `KEYS=set` in `traffic.js`). The tables above are from that design.
