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
make m01        # Module 1: find the ceiling of one server (3 runs, ~13 minutes)
make down       # remove everything
```

## How every experiment is recorded
Each module folder has:
- the k6 script(s) — always an **open model** (`constant-arrival-rate`): k6 sends at the asked rate whether or not answers
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
| 1 | One server, honestly measured | `modules/m01-one-server` |

## License
Code: MIT. Course videos and text are not covered by this license.
