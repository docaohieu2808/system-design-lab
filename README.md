# System Design Lab

Labs for the course **System Design in Practice: Build It, Load It, Break It**.
Every system design idea in the course is built here, loaded with [k6](https://grafana.com/docs/k6/), broken on purpose
and measured. Every number shown in the videos comes from running these files.

## What you need
- Docker with Compose v2, 4 CPU cores, 8 GB RAM (the reference machine for all labs)
- `make`, `curl`, Python 3 (only for summarising results)

## Quick start
```bash
make verify     # ~1 minute: the stack starts, answers correctly, and k6 is not the bottleneck
make calibrate  # ~2 minutes: your machine's ceiling vs the course machine, as a ratio
make m00        # Module 0: closed vs open load around a 2-second freeze (3 runs, ~15 minutes)
make help       # every module's experiments, with how long each takes
make m01        # Module 1: find the ceiling of one server (3 runs, ~13 minutes)
make down       # remove everything
```

## How to follow along
Each module folder has a `LAB.md`: the lesson's experiments step by step, with a question to answer **before** each
run. Write your prediction down, then run it; being wrong is where the learning happens.

## How every experiment is recorded
Each module folder has:
- the k6 script(s) — an **open model** (Module 0 also runs a closed one, to show why not) (`constant-arrival-rate`): k6 sends at the asked rate whether or not answers
  come back, so a slow server shows up as latency instead of being hidden;
- `EXPERIMENT.md` — environment, method, what the result proves and what it does **not** prove;
- `results/results.json` — per load step, the mean / min / max over all runs of:
  `sent_rps` (issued), `completed_rps` (answered without error), `succeeded_rps` (the expected answer),
  `dropped` (could not even be sent), and p50 / p95 / p99 latency; plus the peak CPU of every container.

Your numbers will differ from the videos because your machine differs. Compare **ratios** (for example "p99 at 80% of
the ceiling vs at 50%"), not absolute values.

## Modules
| # | Topic | Folder |
|---|---|---|
| 0 | The lab: open vs closed load, calibration | `modules/m00-the-lab` |
| 1 | One server, honestly measured | `modules/m01-one-server` |
| 3 | Load balancing: copies, a crash, a frozen copy, a slow copy | `modules/m03-load-balancing` |
| 4 | Caching: hit ratio, skewed traffic, stampede, single-flight, TTL jitter | `modules/m04-caching` |
| 5 | Database: index, N+1, connection pools, lost updates, write skew | `modules/m05-database` |
| 6 | Replication: replica reads, lag, read-your-writes, failover | `modules/m06-replication` |
| 7 | Partitioning: consistent hashing, hot keys, ID types | `modules/m07-partitioning` |
| 8 | CAP: cut the network (etcd, Redis) | `modules/m08-cap` |
| 9 | Rate limiting: shared buckets, windows, fail open/closed, client identity | `modules/m09-rate-limiting` |
| 10 | Async work: queues, lag, idempotency, poison messages, retry storms | `modules/m10-async` |
| 11 | Overload: goodput, load shedding, circuit breaker | `modules/m11-overload` |
| 12 | Contention: the ticket race | `modules/m12-contention` |
| 13 | Capstones: news feed drill, and `make check-capstone URL=...` for your own shortener | `modules/m13-capstones` |

## License
Code: MIT. Course videos and text are not covered by this license.
