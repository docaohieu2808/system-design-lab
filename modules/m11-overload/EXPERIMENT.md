# Module 11 — overload: shedding and circuit breakers

## Questions
- Pushing the preview page from below to well past its limit, how many answers come back correct within 500 ms
  (goodput), with and without a cap on requests in progress (4 at once, the rest refused with 503 and Retry-After: 1)?
- Every page calls a dependency that takes 1.5 s, and the caller gives up after 1 s: what does a circuit breaker change?

## Environment
One app copy (half a core), the preview page, k6 1.8.2, 4-vCPU AMD EPYC-Milan host. Goodput table re-measured 07/11/2026 (`PARTS=shed make m11`, 3 runs, quiet gate 25/2) after the cap's refusal changed from 429 to 503 with `Retry-After: 1`; the circuit breaker table below is from 30/10/2026.
The cap answers 503, not 429: it protects the whole service (temporary unavailability), while 429 means "this client sent too many" and belongs to the per-client limiter of module 9 (RFC 9110 section 15.6.4, RFC 6585 section 4). `goodput.js` counts a 503 that carries `Retry-After` as refused; a 503 without it counts as failed.

## Results (mean of 3 runs, min–max in brackets; `results/results.json`, 07/11/2026)
### Goodput (good answers per second)
| offered per s | no cap: good | no cap: slow | cap of 4: good | cap of 4: refused |
|---|---|---|---|---|
| 300 | 300 | 0 | 293 | 7 |
| 600 | 600 | 0 | 462 (451–471) | 138 (129–149) |
| 900 | 56 (52–62) | 677 | 481 (478–483) | 419 (417–422) |
| 1,200 | 42 (41–44) | 765 | 497 (492–506) | 703 (694–708) |
| 1,500 | 36 (33–40) | 706 (562–788) | 488 (483–496) | 1,012 (1,004–1,017) |

At 1,500 offered, one of the three no-cap runs also had 199 requests a second that gave up after the 5 s client timeout (mean 66); the capped runs had none.
The no-cap server finishes about 732 pages a second at 900 offered (good + slow), 800 at 1,200. Same arms on 30/10/2026 (a faster
day): no cap 77 good at 900, cap of 4 526 good and 374 refused at 900, 85 refused at 600. The shape is the same; compare rows of one session only.

The cap costs something below the limit: at 600 per second, it refused 138 requests a second the server could have
served. A cap tuned to the server, or one that adapts, would refuse fewer.

### Circuit breaker (every page degraded: served without the dependency's piece)
| | p50 | p99 |
|---|---|---|
| no breaker | 1,002 ms | 1,039 ms |
| breaker | 1.2 ms | 1,016 ms |

With the breaker, the slow end is the occasional test call that is let through to see if the dependency recovered.

## Added 06/11/2026: single-probe breaker, p90 and slow share, goodput variations (`make m11-breaker`, `results-breaker/results.json`)
The goodput arms (g500, g2000, cap2, cap4, cap8) were repeated on 07/11/2026 for the 503 change (`ONLY="g500-1 ... cap8-3"`, 3 runs, interleaved, quiet gate 25/2, background 6–21% busy, steal 0); the breaker arms are the 06/11 run and were not repeated. The goodput table below is the 07/11 run.
`tools/run-m11-breaker.sh`: 3 runs, all 10 arms inside every run, interleaved (the order rotates each run), lab rebuilt and
quiet gate 25/2 before every arm (background 6–25% busy, steal 0). The breaker rows above are not re-measured; every
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

### Goodput, offered 600 / 900 / 1,200 pages/s (good per second; 15 s per step; refused answers are 503 with Retry-After; 07/11/2026)
| arm | good at 600 | good at 900 | good at 1,200 | refused at 600 | refused at 1,200 |
|---|---|---|---|---|---|
| no cap, good = within 500 ms | 600 | 55.7 (47.1–60.7) | 31.8 (29.7–35.5) | 0 | 0 |
| no cap, good = within 2,000 ms | 600 | 426.9 (401.4–449.0) | 251.2 (233.5–263.8) | 0 | 0 |
| cap of 2 | 463.7 (462.5–466.0) | 458.4 (453.3–461.4) | 472.8 (465.9–480.5) | 136.4 (134.1–137.6) | 727.2 |
| cap of 4 | 467.6 (459.3–473.3) | 485.9 (477.9–496.1) | 498.0 (493.3–504.2) | 132.4 (126.8–140.7) | 702.0 |
| cap of 8 | 484.7 (480.1–490.8) | 493.8 (488.8–501.1) | 503.0 (494.9–508.8) | 115.3 (109.2–119.9) | 697.0 |

Moving the bar from 500 ms to 2 s turns 56 good answers a second into 427 at 900 offered: the pages are not lost, they are
late (a queue of about 700 a second). Goodput under a cap rises slightly with the cap here (464 → 468 → 485 at 600; 473 → 498
→ 503 at 1,200): a bigger cap keeps the half core a little busier, and refuses less below the limit. The no-cap rows have a
wide spread (lowest to highest run: 25% of the mean at 900 for the 500 ms bar): a collapsing queue is a noisy thing to count, and three runs agree on the shape, not
on the second digit. The cap-of-4 arm appears twice on 07/11 (the table at the top, 138 refused at 600; this table, 132): two
separate runs of the same arm, within 5% of each other. The 30/10 numbers differ by 15–35% (faster day): use the rows of one table together.

## What it does not show
- Cascades across several services, or adaptive concurrency limits.
- Error budgets (lesson 11.5 is a concept lesson, no lab).
