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

### IDs (1,000,000 inserts)
| key type | insert time | primary key index |
|---|---|---|
| bigint counter | 20.0 s (19.8–20.2) | 42.2 MB |
| UUIDv4 (random) | 53.3 s (52.9–54.2) | 49.8 MB |
| UUIDv7 (time-ordered) | 33.6 s (32.8–34.9) | 49.8 MB |

## What it does not show
- Moving live data between shards while it is being used.
- Queries across shards, or rebalancing a hot key with copies.
- ID costs on tables much larger than memory, where random inserts hurt more.
