# Module 8 — CAP: cut one node off and watch what it answers

## Questions
- etcd (3 nodes): when one node is cut off from its two peers but can still be reached by the client, does it take
  writes, and what do a normal (linearizable) read and a local (serializable) read return?
- Redis (primary + replica): when the replica is cut off from the primary, what does it answer?

## Environment
etcd v3.6.16, Redis 8.10.2, two Docker networks (`peers` for traffic inside each cluster, `clients` for the probe),
4-vCPU AMD EPYC-Milan host, 30/10/2026. `make m08` (`tools/run-m08.sh 3`), 3 runs. Each run: 30 s, one write and one
read about every 200 ms; the node is disconnected from `peers` from 10 s to 20 s. Phases: before (< 10 s), during
(10.5–19.5 s), after (> 22 s). "Behind" = how many writes the value read trails the newest successful write.

## Results (mean of 3 runs, min–max in brackets; `results/results.json`)
### etcd, e1 cut off
| | before | during | after |
|---|---|---|---|
| write to e2 (majority side) ok | 99% | 100% | 100% |
| write to e1 (cut off) ok | 98% | 0% | 100% |
| normal read from e1 ok | 98% | 0% | 100% |
| local read from e1 ok | 100% | 100% | 100% |
| local read from e1, most writes behind | 0.3 | 5.7 (5–6) | 0 |

The local read returned the value from the moment of the cut for the whole cut, and was current again 3–4 s after the
network healed (stale from ~10.0 s to 23.0–23.8 s in the logs). During the cut each probe loop waits out two 800 ms
timeouts, so fewer writes happen and "behind" stays small; what matters is that the value never moved.

### Redis, replica r2 cut off
| | before | during | after |
|---|---|---|---|
| write to r1 ok | 100% | 100% | 100% |
| read from r2 ok | 100% | 100% | 100% |
| read from r2, most writes behind | 0 | 45 | 64 (while catching up) |

r2 answered every read, all with the value from the moment of the cut (stale from ~10.1 s to 23.3–23.8 s). The
"after" maximum is the first second or so after 22 s, before the replica reconnected and resynced.

## What this does not show
- How Raft elects a leader or how Redis decides to resync (course two).
- A cut that isolates the etcd leader specifically, or a Redis failover with Sentinel.
- Client-side behaviour: a real client would retry against another etcd node.

## Fixes made while building this lab
- etcd never started: in a YAML flow sequence `--initial-cluster=a=...,b=...` was split at the commas. Quoted it.
- The first partition had no effect: nodes resolved each other's names over the `clients` network too. Peers now use
  aliases that exist only on `peers` (`eN-peer`, `r1-peer`). The results above are from the rerun after both fixes.
