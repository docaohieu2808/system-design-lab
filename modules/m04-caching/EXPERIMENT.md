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

Part b is 3 full runs, all arms interleaved inside each run, 25/2 quiet gate; background CPU the gate saw before the
runs: 9–19% busy (flush 9–15%, expiry 10–19%). The runner samples CPU of every `sdlab-*` container: k6 used 0.24–0.25
cores (limit 2) and the app 0.17–0.24 cores, so the load generator had room. Part a: numbers of 30/10/2026, not re-run.

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
| no single-flight | 0 | 184 (151–201) | 503 ms (503–503) | 590 ms (574–614) |
| single-flight | 0 | 0.3 (0–1) | 225 ms (217–230) | 534 ms (521–554) |

Why p99 is 503 ms without single-flight: until the first rebuild lands (500 ms) every request finds the page missing,
queries the database and waits the full build: 400 req/s x 0.5 s is about 200 requests (184 counted), that is about 0.8%
of the 24,000 requests, plus the ones just after, so the 99th percentile sits on the build time. With single-flight those
same requests join the one rebuild and wait only what is left of it (0 to 500 ms, about 250 on average), so p99 lands
lower (225 ms) and the database sees one query. The old table has the same 502 ms p99; what moved is the stampede size
(129 then, 184 now; the ranges 102–159 and 151–201 barely overlap). I did not isolate why it grew: the first run
of the design was on a different day and machine load. The mechanism (all requests of the first 500 ms hit the database)
is the same in both.

Stale-while-revalidate is not an arm of the flush experiment on purpose: a flush deletes the stale copy too, so there is
nothing to serve while the page rebuilds. It helps when entries expire, not when they vanish.

### b2. Synchronised expiry (2,000 pages warmed together, TTL 20 s, building a page takes 100 ms)
| | worst 1 s of database queries | total queries in 60 s | p99 |
|---|---|---|---|
| no fix | 188 (165–202) | 3,811 (3,802–3,817) | 107 ms (106–108) |
| 50% jitter (lifetimes 15–25 s) | 142 (124–162) | 3,802 (3,754–3,832) | 107 ms (106–108) |
| stale-while-revalidate | 183 (167–202) | 3,724 (3,694–3,747) | 18 ms (15–21) |

The worst-second spread (about 20% of the mean) is above the 10% bar and I did not add runs: the worst second is the
maximum of 110 one-second windows of random traffic (random arrivals picking among 2,000 pages) and the refill wave
hits a different phase of the second each run. It is a noisy statistic by nature. The ranges still say two things: jitter
(124–162) is below no fix (165–202) in every run, and SWR (167–202) is not distinguishable from no fix. The total (spread
under 2%) and p99 (spread under 3%, except SWR's 15–21 ms) are stable.

Jitter lowers the worst second by about a quarter while the total stays the same: it moves refills apart, it doesn't
remove them. Stale-while-revalidate does the opposite: the refills are as many and as bunched as with no fix, but no
user waits for them, because every request is answered from the old copy while one background refresh per page rebuilds
it, so p99 falls from about 107 ms (one 100 ms rebuild) to about 18 ms. It protects the user, not the database; jitter
protects the database. The two can be combined (not measured here). SWR's total is slightly lower (about 3%) because a
refreshed page is not asked for again until traffic reaches it. The price is staleness: a page can be older than the nominal
lifetime when asked just before its refresh lands.

At 400 req/s over 2,000 pages each page is asked for about every 5 s, so traffic itself already spreads the refills a
little; the peak is lower than "2,000 at once".

Note: the first version of jitter only shortened lifetimes (TTL minus up to 50%), so pages lived 15 s on average
instead of 20 s and the total rose to 4,975. `app/cache.go` now spreads lifetimes evenly over TTL ± 25%.

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
