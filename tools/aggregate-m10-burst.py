"""Summarise tools/run-m10-burst.sh.  python3 tools/aggregate-m10-burst.py <dir> <runs>
Per arm: the busiest 100 ms and the busiest second of attempts, the number of visible waves, created / gave up, and a timeline file
(<dir>/timeline-<arm>.tsv: seconds into the test, mean/min/max attempts per 100 ms over the runs, first 32 s).
The first 0.5 s (the clients' own first try, the burst itself) is left out of the retry numbers: "retry_peak_100ms" is the busiest 100 ms
after it, "retry_waves" the waves after it. A wave = a run of 100 ms buckets with at least a third of the clients' attempts in each; runs closer than 0.5 s count as one."""
import json
import re
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}


def waves(per, n):
    """Start times (s) of the waves: buckets with >= n/3 attempts, merged when less than 5 buckets apart."""
    hot = [i for i, c in enumerate(per) if c >= n / 3]
    groups = []
    for i in hot:
        if groups and i - groups[-1][-1] < 5:
            groups[-1].append(i)
        else:
            groups.append([i])
    return [g[0] / 10 for g in groups]


res = {"runs": runs, "bucket_ms": 100}
for arm in ("nojitter", "jitter"):
    rows, tl, wave_times = [], [], []
    for k in range(1, runs + 1):
        t = f"burst-{arm}-{k}"
        r = json.loads((out / f"{t}.json").read_text())
        assert r["began"] == r["clients"] and r["ended_other"] == 0, f"{t}: began {r['began']} of {r['clients']}, ended_other {r['ended_other']}"
        per = r["attempts_per_bucket"]
        t0 = r["test_started_ms"] / 1000
        early = 5   # buckets (0.5 s) holding the first try of every client
        retry = [0] * early + per[early:]
        w = waves(retry, r["clients"]); wave_times.append(w)
        rows.append({"peak_100ms": max(per), "peak_100ms_pct_of_clients": round(100 * max(per) / r["clients"], 1),
                     "retry_peak_100ms": max(retry), "retry_peak_100ms_pct_of_clients": round(100 * max(retry) / r["clients"], 1),
                     "retry_peak_1s": max(sum(retry[i:i + 10]) for i in range(len(retry) - 9)), "retry_waves": len(w),
                     "attempts": r["attempts"], "created": r["created"], "gave_up": r["gave_up"], "last_done_s": r["last_done_s"],
                     "app_returned_s": round(float((out / f"{t}.started").read_text()) - t0, 1),
                     "background_busy_pct": float(re.search(r"background_busy_pct=(\d+)", (out / f"{t}.gate").read_text()).group(1))})
        tl.append(per[:320])
    res[arm] = {f: agg([x[f] for x in rows]) for f in rows[0]}
    res[arm]["wave_start_seconds_per_run"] = wave_times
    lines = ["seconds\tmean\tmin\tmax"] + [f"{i / 10:.1f}\t{st.mean(c):.1f}\t{min(c)}\t{max(c)}" for i, c in enumerate(zip(*tl))]
    (out / f"timeline-{arm}.tsv").write_text("\n".join(lines) + "\n")
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
