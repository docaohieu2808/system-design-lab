# Module 11 — overload: shedding and circuit breakers

## Questions
- Pushing the preview page from below to well past its limit, how many answers come back correct within 500 ms
  (goodput), with and without a cap on requests in progress (4 at once, the rest refused with 429)?
- Every page calls a dependency that takes 1.5 s, and the caller gives up after 1 s: what does a circuit breaker change?

## Environment
One app copy (half a core), the preview page, k6 1.8.2, 4-vCPU AMD EPYC-Milan host, 30/10/2026. `make m11`, 3 runs.

## Results (mean of 3 runs, min–max in brackets; `results/results.json`)
### Goodput (good answers per second)
| offered per s | no cap: good | no cap: slow | cap of 4: good | cap of 4: refused |
|---|---|---|---|---|
| 300 | 300 | 0 | 295 | 5 |
| 600 | 600 | 0 | 515 | 85 |
| 900 | 77 (75–81) | 693 | 526 | 374 |
| 1,200 | 45 (39–48) | 751 | 535 | 665 |
| 1,500 | 95 (53–172) | 497 | 519 | 884 |

The cap costs something below the limit: at 600 per second, it refused 85 requests a second the server could have
served. A cap tuned to the server, or one that adapts, would refuse fewer.

### Circuit breaker (every page degraded: served without the dependency's piece)
| | p50 | p99 |
|---|---|---|
| no breaker | 1,002 ms | 1,039 ms |
| breaker | 1.2 ms | 1,016 ms |

With the breaker, the slow end is the occasional test call that is let through to see if the dependency recovered.

## Added 06/11/2026: single-probe breaker, p90 and slow share, goodput variations (`make m11-breaker`, `results-breaker/results.json`)
`tools/run-m11-breaker.sh`: 3 runs, all 10 arms inside every run, interleaved (the order rotates each run), lab rebuilt and
quiet gate 25/2 before every arm (background 6–25% busy, steal 0). The old results above are not re-measured; every
comparison below is between arms of this run. k6 used 0.13–0.16 cores (breaker arms) and 0.29–0.39 (goodput arms), limit 2,
so it had room. One arm, `g500` run 3, was killed by the kernel (k6 out of memory, exit 137: an uncapped server at 1,200
pages/s leaves thousands of requests waiting); I raised k6's memory limit to 3 GB in `compose.overload.yaml` and repeated just
that arm afterwards, so it was not interleaved with its run (`ONLY=g500-3`). The other 9 g500/g2000/cap arms ran under 1 GB
and are unaffected by the limit.
New in the app: `BREAKER=2` (single probe: after the 2 s pause exactly one call goes through, all others are answered without
the dependency until it returns; success closes the breaker, failure reopens it for 2 s) and `GET /stats/dep` (calls that
really reached the dependency). `enrich.js` now reports p90 and the share of pages slower than 500 ms (the bar goodput.js uses).

### Breaker (200 pages/s for 30 s = 6,001 pages; the dependency takes 1.5 s, timeout 1 s)
| | p50 | p90 | p99 | pages slower than 500 ms | calls that reached the dependency |
|---|---|---|---|---|---|
| no breaker | 1,002 ms | 1,008 ms (1,007–1,009) | 1,043 ms (1,039–1,047) | 100% | 6,001 |
| simple breaker (`BREAKER=1`) | 1.4 ms (1.3–1.4) | 1,002 ms (1,002–1,002) | 1,024 ms (1,021–1,027) | 27.3% (27.1–27.3) | 1,635 (1,626–1,640) |
| single probe (`BREAKER=2`) | 1.3 ms (1.3–1.3) | 2.4 ms (2.1–2.9) | 1,003 ms (1,003–1,004) | 3.6% (3.62–3.63) | 217 (217–218) |

Why: the simple breaker lets every call through again once the 2 s pause ends, so for about a second 200 pages a second
wait on the slow dependency before enough failures come back to open it again (a cycle of about 1 s closed and 3 s open:
27% of pages slow, about 1,600 calls). The single probe sends one call per cycle: the only slow pages are the first
second's 200 (3.3% of 6,001) and the probes, so p90 is 2.4 ms. p99 stays near 1 s for every arm because those first 200
pages (3.3%) are more than 1% of 6,001: a 30-second run cannot show a better p99 whatever the breaker does. About 217 calls
= the first second's 200 + about 17 probes over 30 s.

### Dependency at 500 ms (under the 1 s timeout), 200 pages/s for 30 s
| | p50 | p90 | degraded pages | calls to the dependency |
|---|---|---|---|---|
| no breaker | 504.8 ms (504.6–505.1) | 531 ms | 0% | 6,001 |
| simple breaker | 505.7 ms (504.4–507.0) | 535 ms | 0% | 6,001 |

A slow but answering dependency never fails, so the breaker never counts a failure and never opens: it only helps against
failures and timeouts, not against slowness below the timeout.

### Goodput, offered 600 / 900 / 1,200 pages/s (good per second; 15 s per step; refused answers are 429)
| arm | good at 600 | good at 900 | good at 1,200 | refused at 600 | refused at 1,200 |
|---|---|---|---|---|---|
| no cap, good = within 500 ms | 600 | 50.9 (47.5–53.8) | 31.7 (29.0–34.8) | 0 | 0 |
| no cap, good = within 2,000 ms | 600 | 422.4 (406.6–439.2) | 262.2 (251.9–271.1) | 0 | 0 |
| cap of 2 | 463.2 (459.3–465.3) | 468.8 (462.5–480.7) | 472.4 (459.6–479.0) | 136.8 (134.7–140.8) | 727.7 |
| cap of 4 | 474.5 (463.9–480.9) | 483.6 (475.7–490.3) | 498.2 (483.3–505.7) | 125.6 (119.1–136.1) | 701.9 |
| cap of 8 | 478.5 (476.7–481.5) | 504.7 (495.4–511.8) | 512.0 (499.6–534.8) | 121.5 (118.5–123.3) | 688.0 |

Moving the bar from 500 ms to 2 s turns 51 good answers a second into 422 at 900 offered: the pages are not lost, they are
late (a queue of about 700 a second). Goodput under a cap rises slightly with the cap here (463 → 475 → 479 at 600; 472 → 498
→ 512 at 1,200): a bigger cap keeps the half core a little busier, and refuses less below the limit. The no-cap rows have a
wide spread (12–18% of the mean at 900 and 1,200): a collapsing queue is a noisy thing to count, and three runs agree on the shape, not
on the second digit. The old table above has 77 at 900 for the no-cap arm; this session's machine is slower (the lab's reference
numbers moved by 15–20% between sessions), so use the rows of this table together.

## What it does not show
- Cascades across several services, or adaptive concurrency limits.
- Error budgets (lesson 11.5 is a concept lesson, no lab).
