# Module 1, lesson 3 — the same test with the load generator squeezed

**Question:** what does a load test report when the load generator, not the server, is close to full?

## Method
Identical to `../EXPERIMENT.md` (same script, steps, fresh stack, 3 runs, same reference machine) with one change:
k6 is limited to **1 CPU** instead of 2 (`make m01-starved`, `K6_CPUS=1.0`). App and database keep ½ core each.

## Results (mean of 3 runs, range in brackets) next to the valid run (k6 on 2 cores)
| Asked req/s | Succeeded, k6 1 core | Succeeded, k6 2 cores | p50 ms 1 core / 2 cores | p99 ms 1 core / 2 cores | Not sent 1 core / 2 cores |
|---|---|---|---|---|---|
| 1,000 | 1,000 | 1,000 | 0.42 / 0.40 | 7.2 (7.0–7.5) / 3.1 | 0 / 0 |
| 2,000 | 2,000 | 2,000 | 0.45 / 0.44 | 25.3 (21.5–28.9) / 14.7 | 0 / 0 |
| 3,000 | 2,999 | 3,000 | 1.79 / 0.54 | 93.3 (86.8–103.6) / 42.0 | 29 / 0 |
| 4,000 | 3,783 (3,742–3,841) | 3,900 | 54 / 117 | 240 / 238 | 4,346 / 2,002 |
| 5,000 | 3,759 (3,731–3,808) | 4,042 | 275 / 395 | 1,008 / 1,045 | 24,686 / 18,389 |

Median CPU during each step (docker stats, 2 s samples, % of one core; mean of 3 runs):
| Asked req/s | app (limit 50%) | db (limit 50%) | k6, 1-core limit (100%) | k6, 2-core limit (200%) |
|---|---|---|---|---|
| 2,000 | 41 | 27 | 63 | 60 |
| 3,000 | 51 | 37 | 81 | 84 |
| 4,000 | 50 | 46 | 91 | 93 |
| 5,000 | 50 | 45 | 97 | 103 |
Peak sample: k6 103% with a 1-core limit (full), 152% with a 2-core limit (room left).

## What this proves
- With k6 near its limit, the test **reports a slower server than the real one** below the ceiling: at 3,000 req/s
  p99 93 ms instead of 42 ms, p50 1.8 ms instead of 0.5 ms; at 2,000 req/s p99 25 ms instead of 15 ms. The extra time
  is spent inside k6 (scheduling and reading responses late), but it is recorded as server latency.
- It **under-reports the ceiling** by about 3–7% (≈3,760–3,780 instead of 3,900–4,040) and starts failing to send
  requests at 3,000 req/s, where the valid run sent every one.
- Above the ceiling the two runs look alike (p99 ≈ 240 ms and ≈ 1 s): once the server is full, its queue dominates.
  A starved load generator does its damage **before** the ceiling, where you would otherwise conclude "fine".

## What it does not prove
- How badly a starved generator lies on other machines or scripts: heavier scripts (more checks, more tags, bigger
  bodies) cost more CPU per request and lie earlier.
- The very first attempt (before this lab was set up properly) showed k6 at a full core while the app was not at its
  limit; its raw data was not kept, so the course does not quote numbers from it.
