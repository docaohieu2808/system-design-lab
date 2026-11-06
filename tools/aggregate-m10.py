"""Summarise Module 10 runs into results.json.  python3 tools/aggregate-m10.py modules/m10-async/results 3"""
import json
import re
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}


def load(path):
    """k6 writes pretty-printed JSON; the drills print one JSON line after any log lines."""
    text = path.read_text().strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return json.loads(text.splitlines()[-1])


j = lambda n: [load(out / f"{n}-{k}.json") for k in range(1, runs + 1)]
res = {"runs": runs}
for q in ("0", "1"):
    res[f"inline_queue{q}"] = {f: agg([r[f] for r in j(f"inline-{q}")]) for f in ("create_p50_ms", "create_p99_ms")}
for w in ("1", "16"):
    rows = j(f"lag-{w}")
    res[f"lag_workers{w}"] = {"done": agg([r["done"] for r in rows]), "wait_p50_ms": agg([r["wait_ms"]["p50"] for r in rows]),
                              "wait_p99_ms": agg([r["wait_ms"]["p99"] for r in rows]), "left_in_stream": agg([r["stream_len"] - r["done"] for r in rows])}
for i in ("0", "1"):
    res[f"charges_idem{i}"] = {f: agg([r[f] for r in j(f"charges-{i}")]) for f in ("crashes", "charges", "jobs_charged", "double_charges")}
for d in ("0", "3"):
    res[f"poison_dlq{d}"] = {f: agg([r[f] for r in j(f"poison-{d}")]) for f in ("good_done_in_10s", "poison_attempts", "parked_in_dlq")}
def cores(tag, part):
    """Average CPU cores used by containers whose name contains `part`, over their sampled life (cpu-sampler.py output)."""
    first, last = {}, {}
    for l in (out / f"{tag}.cpu.tsv").read_text().splitlines():
        t, name, u, *_ = l.split("\t")
        if part in name and name not in ("HOST", "OTHER"):
            first.setdefault(name, (float(t), int(u))); last[name] = (float(t), int(u))
    return round(sum((last[n][1] - first[n][1]) / 1e6 / max(last[n][0] - first[n][0], 1) for n in first), 3)


def storm_row(tag):
    r = load(out / f"{tag}.json")
    t0 = r["test_started_ms"] / 1000
    stopped, started = float((out / f"{tag}.stopped").read_text()), float((out / f"{tag}.started").read_text())
    back = int(started - t0) + 1               # first whole test-second after the app was started again
    per = r["per_second_attempts"]
    row = {p: {f: r[p][f] for f in ("attempts", "created", "gave_up", "began", "dropped", "ended_other")} for p in ("before", "during", "after")}
    row["gave_up_total"] = sum(r[p]["gave_up"] for p in ("before", "during", "after"))
    row["peak_attempts_1s_after_return"] = max(per[back:])
    row["peak_attempts_1s_overall"] = max(per)
    row["outage_start_s"] = round(stopped - t0, 1); row["outage_end_s"] = round(started - t0, 1)
    row["create_p99_ms"] = r["create_p99_ms"]
    row["background_busy_pct"] = float(re.search(r"background_busy_pct=(\d+)", (out / f"{tag}.gate").read_text()).group(1))
    row["k6_cores"] = cores(tag, "k6"); row["app_cores"] = cores(tag, "app")
    row["k6_exit"] = int((out / f"{tag}.rc").read_text())
    return row, per


for r_ in ("immediate", "backoff", "backoff-nojitter"):
    rows, pers = zip(*[storm_row(f"storm-{r_}-{k}") for k in range(1, runs + 1)])
    d = {p: {f: agg([r[p][f] for r in rows]) for f in ("attempts", "created", "gave_up", "began", "dropped", "ended_other")} for p in ("before", "during", "after")}
    for f in ("gave_up_total", "peak_attempts_1s_after_return", "peak_attempts_1s_overall", "outage_start_s", "outage_end_s",
              "create_p99_ms", "background_busy_pct", "k6_cores", "app_cores", "k6_exit"):
        d[f] = agg([r[f] for r in rows])
    d["per_second_attempts_mean"] = [round(st.mean(x), 1) for x in zip(*pers)][:40]
    res["storm_" + r_.replace("-", "_")] = d
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
