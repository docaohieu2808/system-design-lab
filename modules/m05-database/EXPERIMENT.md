# Module 5 — the database

## Questions
What does one missing index cost? N+1? Too many connections? How often do concurrent writes lose updates or break a rule?

## Environment
Postgres 18.6 (half a core) with a million links (`more.sql`), one app copy (half a core), k6 and pgbench on the same
4-vCPU AMD EPYC-Milan host, 30/10/2026. `make m05` / `tools/run-m05.sh`, 3 runs of everything.

## Method
1. index: `EXPLAIN ANALYZE` of a lookup by long URL, then 5 lookups/s for 30 s; again after `CREATE INDEX`.
2. N+1: `/api/recent` (20 links with counts) at 200 req/s, `NPLUS1=1` vs `0`.
3. connections: pgbench one-row lookups, 8/32/128/512 clients, 20 s each, direct (max_connections 600) vs PgBouncer
   (20 server connections); plus 128 clients direct at the default limit (100).
4. lost update: 5,000 concurrent increments, read-then-write vs `clicks = clicks + 1`.
5. write skew: 1,000 trials of two doctors going off call at once, read committed vs serializable.

## Results (mean of 3 runs; `results/results.json`)
| test | result |
|---|---|
| index, one query | Seq Scan 322 ms → Index Scan 0.12 ms; build 8.2 s |
| index, 5 lookups/s | p50 8,089 ms, 35% failed → p50 0.82 ms, 0 failed |
| N+1 at 200 req/s | 21 queries/request, p99 145 ms → 1 query, p99 2.0 ms |
| direct, tps at 8/32/128/512 clients | 3,135 / 2,971 / 2,330 / 1,203 |
| PgBouncer, tps at 8/32/128/512 clients | 2,960 / 2,918 / 3,019 / 3,068 |
| 128 clients, default limit | refused ("too many clients"), 0 tps |
| lost update (of 5,000) | read-then-write 182 counted; atomic 5,000 |
| write skew (of 1,000) | read committed: nobody on call 990; serializable: 0, with 992 refused commits |

## Added 06/11/2026: variations (`make m05-deepen`, `tools/run-m05-deepen.sh`, `results-deepen/results.json`)
3 runs; the arms of each experiment are interleaved inside every run (the order rotates each run), lab rebuilt and the
quiet gate (25/2) passed before every arm (background it saw: 5–13% busy, steal 0). A CPU sample of every `sdlab-*`
container is kept per arm. The old results above are not re-measured. **These runs were on a slower day than the old
ones** (the same 8-client pgbench read 2,677 tps here against 3,135 on 30/10; no-index at 5/s failed 52% here against
35%), so compare an arm with the reference arm of the same table, not with the table above.
k6 used at most 0.23 cores and pgbench 0.46 (limit 1.5), so neither load generator was the limit; Postgres was at its
half-core cap (0.49 cores) in every saturated arm.

### No index, 30 s of lookups by long URL (`idx`)
| rate | failed | p50 | p99 |
|---|---|---|---|
| 2/s | 0% | 250 ms (230–283) | 382 ms (367–393) |
| 5/s (reference) | 52.0% (48.7–55.6) | 9,995 ms | 10,001 ms |
| 10/s | 88.4% (87.7–88.7) | 10,000 ms | 10,001 ms |

A scan takes about 250–320 ms and Postgres has half a core, so it finishes about 3 a second. At 2/s it keeps up (database
0.34 cores); above that a queue builds and requests time out at 10 s (the 10 s p50 is the timeout). The failed share is
the share of requests that were still waiting at 10 s.

### `/api/recent` at 400 requests/s, 30 s (`nplus1`)
| | failed | dropped by k6 | p50 | p99 | database queries/s |
|---|---|---|---|---|---|
| 21 queries per request (`NPLUS1=1`) | 41.0% (39.9–41.6) | 5,252 (5,218–5,278) | 9,495 ms | 10,001 ms | 4,673 (4,634–4,732), 20.8 per request |
| 1 query per request (`NPLUS1=0`) | 0% | 0 | 0.69 ms | 14.5 ms (8.1–18.4) | 400 |

The N+1 arm asked for 8,400 queries/s and the database answered about 4,670: that is this database's ceiling for these
tiny queries. The p99 of the one-query arm has a wide relative spread (8–18 ms) and is a small number either way.

### pgbench, 512 clients through PgBouncer, `DEFAULT_POOL_SIZE` (`pool`, 20 s)
| pool size | tps | average latency |
|---|---|---|
| 5 | 2,674 (2,645–2,709) | 191.5 ms |
| 20 (reference) | 2,385 (2,289–2,437) | 214.8 ms |
| 80 | 2,025 (1,944–2,103) | 253.1 ms |

A smaller pool was faster at every step: fewer server processes share the half core, so less time goes to switching
between them. (An explanation, not isolated: I did not measure context switches.) This is the opposite of "five performs
about the same".

### Lost update, 50 workers x 100 increments (`drill lost-update`)
| app pool | read-then-write (of 5,000) | atomic `clicks = clicks + 1` | read-then-write with `SELECT ... FOR UPDATE` |
|---|---|---|---|
| 2 connections | 184.7 (182–186) | 5,000 | 5,000 |
| 4 (the default: pgx uses max(4, CPUs)) | 183.7 (183–184) | 5,000 | 5,000 |
| 50 | 152.7 (132–165) | 5,000 | 5,000 |

The default pool is 4 connections (the drill now prints `pool_max`). With 50 workers a pool of 2 loses as many updates as a
pool of 4: the lost updates come from the read and the write being two statements, not from the pool size. A pool of 50
lets more workers read at once and the surviving count dropped to about 153. The spread at 50 (21% of the mean) is the
spread of a race; I did not add runs.

### Write skew, 1,000 trials (`drill write-skew`)
| variant | nobody on call | refused commits |
|---|---|---|
| read committed | 989.7 (986–992) | 0 |
| serializable | 0 | 990.7 (983–996) |
| read committed, check written as `SELECT name FROM doctors WHERE on_call FOR UPDATE` | 0 | 0 |

The locked version makes the second doctor wait at the check and see one doctor left, so the rule holds without a single
refusal and without a retry.

### pgbench, 8 clients straight to Postgres, 20 s (`prep`)
| protocol | tps | average latency |
|---|---|---|
| simple (reference) | 2,677 (2,583–2,772) | 2.99 ms |
| `-M prepared` | 3,723 (3,672–3,759) | 2.15 ms |

Prepared statements gave 39% more lookups per second from the same half core: the ceiling belongs to the query path, not
to the database alone.

## What it does not show
- Index cost on writes, or bigger-than-memory tables.
- PgBouncer in transaction mode with prepared statements or session features.
- Exact numbers on your machine; compare shapes (Module 0, calibration).
