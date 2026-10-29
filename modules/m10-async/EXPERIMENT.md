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

### Retry storm
Re-measuring. The first runs froze the app (`docker compose pause`), so every attempt hung until the client's 2 s
timeout and "retry at once" behaved like a slow retry: during the outage both ways made about 2.8 times the normal
number of attempts (immediate 1,151, backoff 1,058). `tools/run-m10.sh` now stops the app instead, so requests fail
at once; `tools/run-m10-storm.sh` re-runs only this experiment.

## What it does not show
- Queues with several partitions, ordering across them, or exactly-once delivery from the broker.
- Crashes in the middle of a charge, rather than between charging and acknowledging.
