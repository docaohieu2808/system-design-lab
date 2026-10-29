# Module 13 — capstones: news feed and chat rooms

## Questions
- 13.3 News feed: what does fan-out on write cost compared with fan-out on read, to post (ordinary user, celebrity) and
  to read one feed?
- 13.4 Chat rooms: does every listener get every message, how fast, and how much memory does one open connection cost?

## Environment
Postgres 18.6 (half a core), one app copy (half a core), k6 1.8.2, 4-vCPU AMD EPYC-Milan host, 30/10/2026.
`make m13`, 3 runs. Feed: 10,000 users, 20 earlier posts each; ordinary users have 100 followers, user 1 (the
celebrity) is followed by all 9,999 others. Chat: listeners spread over 20 rooms, one message per room per second for
30 s.

## Results (mean of 3 runs, min–max in brackets; `results/results.json`)
### 13.3 News feed
| | fan-out on write | fan-out on read |
|---|---|---|
| ordinary user posts (100 followers) | 39 ms (19–62) | 0.9 ms |
| celebrity posts (9,999 followers) | 1,013 ms (742–1,172) | 0.6 ms |
| read one feed, p50 of 200 reads | 5.2 ms (first runs, see note) | 0.97 ms |
| rows in the timeline table | 20,208,079 | 0 |

Note on reads: the first runs read the timeline table straight after a 20-million-row bulk load, before any vacuum, so
Postgres could not use an index-only scan and fetched every row from the table itself. A real timeline table is vacuumed
regularly. `app/feed.go` now runs `VACUUM ANALYZE timeline` before measuring; `tools/run-m13-feed.sh` re-measures
the feed alone.

### 13.4 Chat rooms
| listeners | delivered | delivery p50 | delivery p99 | server memory per connection |
|---|---|---|---|---|
| 500 | 100% | 1 ms | 2 ms | 43.9 KB (43.3–44.3) |
| 1,000 | 100% | 1 ms | 3 ms | 43.1 KB (43.0–43.2) |

Memory per connection = growth of the Go runtime's memory from idle to 20 s into the test, divided by open connections.

## What it does not show
- The hybrid feed (copy on write for ordinary users, merge celebrities at read time): left as the exercise.
- Feeds with ranking, or a feed cache in Redis.
- More than one chat gateway, or listeners on slow networks (the slow-listener drop is in the code, not measured).
- Capstones 13.1 and 13.2 reuse numbers from modules 2, 3, 4, 6 and 9; 13.1 has its own checker (`make check-capstone`).
