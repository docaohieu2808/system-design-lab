# Module 7 — partitioning: shards, consistent hashing, hot keys, IDs

## Questions
- How evenly do three shards share lookups, and what happens when half of all traffic asks for one code?
- Going from three shards to four, how many keys change shard with remainder (modulo) hashing vs consistent hashing?
- What does the ID type (bigint counter, UUIDv4, UUIDv7) cost to insert, and in index size?

## Environment
Three Postgres 18.6 shards (0.15 core each, each holds a copy of the same links), one app copy routing each code to
one shard, k6 1.8.2, 4-vCPU AMD EPYC-Milan host, 30/10/2026. `make m07`, 3 runs. What is measured is where requests
land, not live data moving between shards.

## Results (mean of 3 runs, min–max in brackets; `results/results.json`)
### Hot key (about 1,800 lookups/s over 100,000 codes)
| | lookups per shard (run 1) | p50 (other codes) | p99, all requests |
|---|---|---|---|
| even traffic | 33% / 33% / 34% | 0.58 ms | 184 ms (177–189) |
| half of requests for one code | 67% / 17% / 16% | 1.23 ms | 1,596 ms (1,406–1,711) |

The hot shard's slow end spreads to every code: p99 for the other codes alone was 1,561 ms.

### Adding a fourth shard (1,000,000 codes)
| rule | codes that change shard |
|---|---|
| remainder, `hash mod N` | 75.0% |
| consistent hashing, 100 points per shard | 27.8% (new shard holds 27.8%; others 22.4–26.9%) |

Note: the first runs gave 5.6%, with the new shard taking only 5.6% of the keys instead of about a quarter. Raw
FNV-1a on short, similar strings (vnode names, short codes) clusters on the ring. `app/drills.go` now mixes the hash
(`ringHash`) before placing points and keys; a Python replay of the same logic on 200,000 codes moved 27.9%. The table is from the rerun after that change (3 runs, identical: the drill is deterministic).

### IDs (1,000,000 inserts) — rerun 06/11/2026 (`make m07-ids`, 3 runs, quiet gate 25/2: background 9–22% busy)
Postgres with half a core (`compose.yaml` alone). The first version of this table (30/10) had two faults: the "index"
column was the table size (`pg_relation_size` of the table, not of its index), and the database ran with the shard
overlay's 0.15 core, which made every insert time about 3.5 times longer (20.0 / 53.3 / 33.6 s). The ratios did not
change (UUIDv4 2.7 times the bigint, UUIDv7 1.7 times, then and now).
| key type | insert time | table | primary key index (real) |
|---|---|---|---|
| bigint counter | 5.7 s (5.3–6.0) | 42.2 MB | 21.4 MB |
| UUIDv4 (random) | 15.2 s (14.7–15.9) | 49.8 MB | 37.8 MB (37.5–38.2) |
| UUIDv7 (time-ordered) | 9.7 s (9.5–9.9) | 49.8 MB | 30.1 MB |

The table is about a fifth bigger for either UUID (a 16-byte key against 8) and the index is 41% (UUIDv7) to 77% (UUIDv4)
bigger than the bigint's. Random UUIDs also make a bigger index than time-ordered ones: inserting in random order splits
pages that sequential inserts fill completely (the usual explanation; page splits were not counted here).

Making the IDs alone (`gen.sql`, a `SELECT count(...)` over `generate_series` of a million, no table and no index; 3 runs):
| | time |
|---|---|
| `count(*)` only (the series itself) | 372 ms (333–412) |
| `count(gen_random_uuid())` | 3,339 ms (3,310–3,374) |
| `count(uuidv7())` | 3,263 ms (3,216–3,300) |

So making a UUID costs about 3 s per million either way (about 3 microseconds each), and it is the same for the random and
the time-ordered one. Subtracting it from the insert times as a rough guide (the pieces are not strictly additive):
bigint 5.7 s, UUIDv7 about 6.4 s, UUIDv4 about 11.8 s. Most of UUIDv7's extra cost over the bigint is the cost of making the ID; for
UUIDv4 the extra is mostly the random placement in the index.

### Hot-key fix and variations — 06/11/2026 (`make m07-hotfix`, `tools/run-m07-extras.sh`; `results-hotfix/`, `results-extras/`)
Same stack and load as the hot-key table above (about 1,800 lookups/s for 30 s, three shards at 0.15 core). 6 runs of each
arm (3, then 3 more because the p99 spread was over 10%), all arms of an experiment inside every run, interleaved, the
order rotating each run; quiet gate 25/2 before every arm (background 6–25% busy, steal 0). The old table above is not
re-measured. **This session's machine is slower than on 30/10** (even traffic p99 310 ms here against 184 ms; hot 4,150
against 1,596), so read the new rows against each other, not against the old table.
The fix (`app/hotcache.go`, `HOT_CACHE=1`): the app keeps a small in-memory cache of hot codes in front of the router. A code
that misses 20 times within one second (`HOT_CACHE_THRESHOLD`) is cached for 30 s, so cold traffic does not churn the cache;
a cached code is answered by the app without asking any shard. The hot code is the one most asked for; nothing is invalidated
(the lab never changes a link).
| arm | shard's share of lookups the shards answered | hot shard's share of ALL requests | p99, all requests | p99, the hot code | p99, other codes | dropped by k6 |
|---|---|---|---|---|---|---|
| even traffic | 33.5% | 33.5% | 310 ms (271–370) | – | 310 ms | 256 (164–453) |
| half the requests ask for one code | 66.7% (66.2–67.0) | 66.7% | 4,150 ms (3,483–4,865) | 4,284 ms | 3,761 ms | 9,089 (8,541–9,637) |
| the same, with the hot-code cache | 33.7% (33.3–34.3) | 17.0% (16.8–17.2) | 138 ms (85–182) | 34 ms (19–56) | 172 ms | 129 (87–185) |
The cache served 26,778 requests (50%); the hot shard's CPU went from 0.15 cores (its cap) to 0.08; failed requests: 0.13% in
the hot arm (0–0.75%), 0 in the other two. With the cache, the shards see half the traffic of the even arm, so the p99 is
lower than in the even arm; the cache did not make the shards more even, it removed the work that was uneven.
| arm | lookups/s | shard share | p99, all requests | dropped |
|---|---|---|---|---|
| even traffic at 600 lookups/s | 600 | 33.5% | 97 ms (79–173) | 0 |
| 20% of requests ask for one code, 1,800/s | 1,786 | 46.7% (46.6–46.9) | 466 ms (255–690) | 419 (127–695) |
| (even traffic at 1,800/s, same run) | 1,786 | 33.5% | 347 ms (252–521) | 412 (171–1,071) |
The 20% case gives the hot shard 46.7% of the lookups (the calculation 0.2 + 0.8/3 = 46.7%), and its p99 (mean 466 ms) is above
even traffic's on average (347 ms) and far below the 50% arm's (4,150 ms), but in 2 of the 6 runs it was below the even arm's of the same run. The spread of the p99s in the 1,800/s arms stays above 10% after 6 runs (even 252–521 ms, hot20
255–690 ms): each shard runs at 80% (even) to 100% (hot) of its 0.15-core cap, where a queue's tail is very sensitive to
small differences, so more runs would not shrink it. The order cache < even < hot (50%) held in all 6 runs; hot20 against even did not (see above). k6 used 0.58–0.73 cores (limit 2, so
it had room), but it dropped 0.8% of arrivals in the even arm (VU start-up lag when latency rises), so the offered load was not perfectly steady.

### Adding a fourth shard with 10 points per shard (`rehash` with `VNODES=10`, deterministic, 1 run)
Consistent hashing: 26.2% of the keys move (100 points per shard: 27.8%), and the new shard holds 26.2% but the shares
after the change spread 18.3% to 30.2% (100 points: 22.4–26.9%): fewer points per shard, a lumpier ring.

## What it does not show
- Moving live data between shards while it is being used.
- Queries across shards, or rebalancing a hot key with copies. The cache has no invalidation and no limit on its size
  (stale answers and a stampede on its first fill are not tested).
- ID costs on tables much larger than memory, where random inserts hurt more. WAL bytes per ID type (not measured).
