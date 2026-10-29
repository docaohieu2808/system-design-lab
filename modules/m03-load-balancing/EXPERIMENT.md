# Module 3 — load balancing

## Questions
Do N app copies behind a load balancer carry N times the traffic? What happens when a copy is killed, frozen, or slow?

## Environment
Module 1's stack plus Traefik v3.7.16 (1 core) in front of N app copies (a quarter of a core each), Postgres half a
core, k6 2 cores. 4-vCPU AMD EPYC-Milan host, 29–30/10/2026. Every request asks for the preview page (`/page/{code}`):
the same lookup as the redirect plus about 0.8 ms of CPU (`PAGE_WORK=6000`), because with the bare redirect the
proxy itself used about as much CPU as the app copies and the 4-core host filled up (first try, see lesson 3.1;
the formal measurement of that is `results-proxy/`).

## Method (`make m03`, `tools/run-m03.sh`, 3 runs of everything)
1. scale: 1–4 copies, step test 150 → 1,350 pages/s, 15 s per step. Ceiling = most pages/s that succeeded.
2. kill: 600 pages/s for 60 s; at 30 s `docker kill` one copy. 3 copies vs 4.
3. pause: 400 pages/s; at 30 s `docker pause` one of 3 copies. Without vs with a Traefik health check (1 s / 500 ms).
4. slow: 400 pages/s over 3 copies, one limited to 0.08 core. Traefik `wrr` (take turns) vs `p2c` (less busy of two).

## Results (mean of 3 runs; `results/results.json`)
| copies | ceiling pages/s (min–max) | peak CPU: Traefik / db (limit 50%) / host |
|---|---|---|
| 1 | 321 (309–342) | 89% / 54% / 99% |
| 2 | 685 (677–693) | 84% / 53% / 96% |
| 3 | 1,063 (1,059–1,070) | 48% / 26% / 69% |
| 4 | 1,270 (1,264–1,278) | 49% / 51% / 79% |

| test | p99 before → after | failed after (of ~12,000–18,000) |
|---|---|---|
| kill, 3 copies | 84 → 518 ms | 106 |
| kill, 4 copies | 74 → 86 ms | 89 |
| freeze, no health check | 66 → 3,001 ms | 3,861 |
| freeze, health check | 68 → 3,000 ms | 191 |
| slow copy, wrr | 3,001 ms (both halves) | 3,085 / 3,500 per half |
| slow copy, p2c | 86 → 87 ms | 0 |

## What it shows
- Copies add capacity nearly in proportion while only the app is full; the 4th copy adds less because the database
  reaches its half core (51%).
- A killed copy loses the requests it held (~100 here) whatever the setup; with no spare the remaining copies run near
  their ceiling and p99 rises about 6×; with a spare p99 barely moves.
- A frozen copy keeps receiving a third of the traffic until something checks it; a 1 s health check cuts failures
  about 20×. p99 stays at the 3 s timeout because ~1.6% of requests still time out before the check acts.
- With one slow copy, taking turns fails about a quarter of requests; picking the less busy of two fails none.

## What it does not show
- Past each ceiling the steps overload k6 and the host (host CPU up to 99% with 1–2 copies); only the rising part of
  each step test is used for the ceiling, and the peak CPU columns include those overloaded steps.
- Several machines, real network latency between them, or Traefik's own failover (one Traefik here).
- Exact numbers for your machine; compare the shape (see Module 0, calibration).
