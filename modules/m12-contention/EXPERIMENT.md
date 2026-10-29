# Module 12 — contention: the ticket race

## Question
1,000 buyers try to buy one of 100 seats at the same moment. How many orders does each way of selling produce?

## Environment
Postgres 18.6 (half a core), the app's `drill tickets` with 50 database connections, 4-vCPU AMD EPYC-Milan host,
30/10/2026. `make m12`, 3 runs.

## Results (mean of 3 runs; `results/results.json`)
| way | orders (of 100 seats) | time for 1,000 buyers |
|---|---|---|
| check, then insert | 972 (872 oversold) | 1,502 ms |
| `SELECT ... FOR UPDATE` on the event row | 100 | 1,368 ms |
| advisory lock around check + insert | 100 | 758 ms |
| one conditional `UPDATE ... WHERE sold < capacity` | 100 | 703 ms |

## What it does not show
- Holds that expire, payments failing midway, or seat maps (specific seats).
- A Redis or other distributed lock (deliberately not measured; see lesson 12.2).
- Several app copies or databases.
