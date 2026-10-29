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

## What it does not show
- Index cost on writes, or bigger-than-memory tables.
- PgBouncer in transaction mode with prepared statements or session features.
- Exact numbers on your machine; compare shapes (Module 0, calibration).
