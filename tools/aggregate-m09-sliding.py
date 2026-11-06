"""Summarise the Module 9.3 sliding-window runs into results.json.  python3 tools/aggregate-m09-sliding.py <dir> <runs>

steady arms: allowed requests per second (mean of the three 10 s phases), k6 cores, and for the Redis arms the Redis
commands per request (round trips from the app, and all commands including the ones inside the Lua script) and
MEMORY USAGE in bytes of the client's key.   boundary arms: allowed of 40 requests across a second boundary.
"""
import json
import re
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)
SKIP = {"info", "config", "memory", "scan", "type", "object", "ping", "client", "hello", "command", "script", "select", "dbsize"}


def k6_cores(path):
    """Mean k6 cores over its busy stretch (usage_usec of the sdlab-k6 container)."""
    rows = []
    for line in path.read_text().splitlines():
        f = line.split("\t")
        if f[1].startswith("sdlab-k6"):
            rows.append((float(f[0]), int(f[2])))
    return (rows[-1][1] - rows[0][1]) / 1e6 / (rows[-1][0] - rows[0][0]) if len(rows) > 1 else 0


def total_requests(r):
    return sum(r[p]["allowed_per_s"] * 10 + r[p]["refused_429"] + r[p]["errors_503"] + r[p]["other"] for p in ("before", "during", "after"))


res = {"runs": runs, "steady": {}, "boundary": {}}
for arm in ("local1", "local3", "window", "bucket", "sliding"):
    rows = []
    for k in R:
        r = json.loads((out / f"{arm}-{k}.json").read_text())
        row = {"allowed_per_s": st.mean(r[p]["allowed_per_s"] for p in ("before", "during", "after")),
               "k6_cores": k6_cores(out / f"{arm}-{k}.cpu.tsv"),
               "background_busy_pct": float((out / f"{arm}-{k}.gate").read_text().split()[0].split("=")[1])}
        cs = out / f"{arm}-{k}.commandstats.txt"
        if cs.exists():
            calls = {m.group(1): int(m.group(2)) for m in re.finditer(r"cmdstat_(\w+):calls=(\d+)", cs.read_text())}
            n = total_requests(r)
            data = {c: v for c, v in calls.items() if c not in SKIP}
            trips = data.get("evalsha", 0) + data.get("eval", 0) or sum(data.values())
            row.update({"requests": n, "redis_round_trips_per_request": trips / n,
                        "redis_commands_per_request": sum(v for c, v in data.items() if c not in ("evalsha", "eval")) / n,
                        "commands_by_name": data})
            mem = (out / f"{arm}-{k}.memory.tsv").read_text().split("\n")[0].split("\t")
            row["key"], row["key_bytes"], row["key_encoding"] = mem[0].split(":")[0], int(mem[1]), mem[3]
        rows.append(row)
    num = [f for f in rows[0] if isinstance(rows[0][f], (int, float))]
    res["steady"][arm] = {f: agg([r[f] for r in rows]) for f in num}
    if "commands_by_name" in rows[0]:
        res["steady"][arm]["commands_by_name_run1"] = rows[0]["commands_by_name"]
        res["steady"][arm]["key_encoding"] = rows[0]["key_encoding"]
for arm in ("bwindow", "bbucket", "bsliding"):
    rows = [json.loads((out / f"{arm}-{k}.json").read_text()) for k in R]
    res["boundary"][arm[1:]] = {"allowed_of_40": agg([r["allowed_per_burst_pair"] for r in rows]), "refused_total": agg([r["refused"] for r in rows])}
# outage: when does the freeze take hold? Offsets in seconds from the start of the "during" block (first request tagged
# phase=during) and from the pause command. last_429 = the last refusal before Redis stopped answering; first_503 (fail
# closed) = the first request the app failed because Redis did not answer within its 200 ms timeout.
res["outage"] = {}
for arm, name in (("outopen", "open"), ("outclosed", "closed")):
    rows = []
    for k in R:
        ev = [float(x) for x in (out / f"{arm}-{k}.events").read_text().split()]
        reqs = [(float(a), b, c) for a, b, c in (l.split("\t") for l in (out / f"{arm}-{k}.requests.tsv").read_text().splitlines())]
        block = min(t for t, _, ph in reqs if ph == "during")
        last429 = max(t for t, s_, _ in reqs if s_ == "429" and t <= ev[1] + 1.0)
        row = {"pause_command_from_block_start_s": ev[0] - block, "last_429_from_block_start_s": last429 - block,
               "last_429_from_pause_command_s": last429 - ev[0]}
        after = [t for t, s_, _ in reqs if s_ == "503" and t >= ev[0]]
        if arm == "outclosed" and after:
            row["first_503_from_pause_command_s"] = min(after) - ev[0]
            row["first_503_from_block_start_s"] = min(after) - block
            row["last_503_from_unpause_command_s"] = max(t for t, s_, _ in reqs if s_ == "503") - ev[2]
        rows.append(row)
    res["outage"][name] = {f: agg([r[f] for r in rows]) for f in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
