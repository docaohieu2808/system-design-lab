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

## What it does not show
- Cascades across several services, or adaptive concurrency limits.
- Error budgets (lesson 11.5 is a concept lesson, no lab).
