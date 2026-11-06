#!/usr/bin/env python3
"""cpu-sampler.py <out.tsv> [interval_s]: once per interval, write raw CPU counters of every sdlab-* container
(cgroup cpu.stat: usage_usec, throttled_usec) and of the whole machine (/proc/stat jiffies), with a timestamp.
Raw cumulative counters, so any window can be averaged afterwards (tools/aggregate-m03-cause.py).
Lines: <epoch>\t<name>\t<usage_usec>\t<throttled_usec>   and   <epoch>\tHOST\t<busy_jiffies>\t<steal_jiffies>\t<total_jiffies>
Also one OTHER line: cumulative CPU (usage_usec) of all docker containers that are not sdlab-* (summed, no names), to flag a run
that shared the machine with another stack. Only sdlab-* names, HOST and OTHER are written (the lab shares its machine with other things). Stop it with SIGTERM."""
import os
import subprocess
import sys
import time

out, interval = sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
ids = {}
other_prev, other_total = {}, 0


def refresh():
    ids.clear()
    for line in subprocess.run(["docker", "ps", "--no-trunc", "--format", "{{.ID}} {{.Names}}"],
                               capture_output=True, text=True).stdout.splitlines():
        cid, name = line.split()
        if name.startswith("sdlab-"):
            ids[name] = cid


def read_cgroup(cid):
    try:
        d = dict(l.split() for l in open(f"/sys/fs/cgroup/system.slice/docker-{cid}.scope/cpu.stat"))
        return int(d["usage_usec"]), int(d["throttled_usec"])
    except (OSError, KeyError):
        return None


def other_usage():
    """Cumulative CPU of every non-sdlab container: per-container deltas summed (a container appearing starts from zero)."""
    global other_total
    mine = set(ids.values())
    seen = {}
    for d in os.listdir("/sys/fs/cgroup/system.slice"):
        if d.startswith("docker-") and d.endswith(".scope") and d[7:-6] not in mine:
            try:
                seen[d] = int(dict(l.split() for l in open(f"/sys/fs/cgroup/system.slice/{d}/cpu.stat"))["usage_usec"])
            except (OSError, KeyError):
                pass
    for d, u in seen.items():
        if u >= other_prev.get(d, 0):
            other_total += u - other_prev.get(d, u)
    other_prev.clear()
    other_prev.update(seen)
    return other_total


def host():
    v = [int(x) for x in open("/proc/stat").readline().split()[1:9]]  # user nice system idle iowait irq softirq steal
    tot = sum(v)
    return tot - v[3] - v[4] - v[7], v[7], tot


with open(out, "w", buffering=1) as f:
    n = 0
    while True:
        t = time.time()
        if n % 3 == 0:
            refresh()
        b, s, tot = host()
        f.write(f"{t:.2f}\tHOST\t{b}\t{s}\t{tot}\n")
        f.write(f"{t:.2f}\tOTHER\t{other_usage()}\t0\n")
        for name, cid in list(ids.items()):
            r = read_cgroup(cid)
            if r:
                f.write(f"{t:.2f}\t{name}\t{r[0]}\t{r[1]}\n")
        n += 1
        time.sleep(max(0, interval - (time.time() - t)))
