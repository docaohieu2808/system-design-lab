# Module 10 — async work: queues, retries, idempotency

## Questions
- Creating a link also does 200 ms of side work: what does moving it to a queue do to the create time?
- 40 jobs per second for 30 s: how far behind do 1 and 16 workers fall?
- A payment worker that crashes after charging 10% of the time: how many double charges, without and with an
  idempotency key?
- One job that always fails, in front of 200 good ones: retry forever vs a dead-letter queue after 3 tries?
- The app is down for 10 s: what do instant retries and backoff with jitter do to the load?

## Environment
One app copy (half a core), Postgres 18.6, Redis 8.10.2 streams as the queue, k6 1.8.2, 4-vCPU AMD EPYC-Milan host,
30/10/2026. `make m10`, 3 runs.

## Results (mean of 3 runs, min–max in brackets; `results/results.json`)
| experiment | without | with |
|---|---|---|
| create time p50 / p99, side work inline vs queued | 203 / 206 ms | 2 / 6 ms |
| jobs done after 40 s, 1 vs 16 workers (of about 1,200) | 198 | 1,202 (all) |
| job wait p50, 1 vs 16 workers | 17.2 s | 0 ms |
| double charges in 1,000 payments, no key vs idempotency key | 128 (116–137) | 0 |
| good jobs done in 10 s behind a poison job, retry forever vs dead-letter after 3 | 0 (321 tries of the bad job) | 200 (bad job parked after 3) |

### Retry storm (40 creates/s; the app is stopped from 12 s to about 22 s; up to 5 retries)
| | attempts during (10–20 s) | created during | gave up, whole run | attempts after (20–30 s) |
|---|---|---|---|---|
| retry at once | 1,350 (1,344–1,360) | 306 | 33 (32–34) | 498 |
| backoff + jitter (200 ms, 400 ms, ... ×0.5–1.5) | 1,145 (1,141–1,150) | 328 | 0 | 462 |

Normal is 400 attempts per 10 s. Both ways about tripled the load while the app was down; the clear difference is who
gave up: retrying at once used its five tries inside the outage, backing off outlasted it. Attempts during the outage
still took up to the 2 s client timeout (p99 of a create was 11–12 s both ways), so "at once" is not instant here and
the attempt counts are closer than a real fast-failing outage would make them.

Note: the first runs froze the app (`docker compose pause`) and showed no difference at all (immediate 1,151, backoff
1,058 attempts, nobody gave up). `tools/run-m10.sh` now stops the app instead; the table is from
`tools/run-m10-storm.sh 3` after that change.

## What it does not show
- Queues with several partitions, ordering across them, or exactly-once delivery from the broker.
- Crashes in the middle of a charge, rather than between charging and acknowledging.
