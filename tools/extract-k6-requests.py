#!/usr/bin/env python3
"""extract-k6-requests.py <k6 --out json file> <out.tsv>: one line per request, <epoch seconds>\t<status>\t<phase tag>.
Keeps nothing else (the raw k6 json is large and is deleted afterwards)."""
import json
import sys
from datetime import datetime

n = 0
with open(sys.argv[1]) as f, open(sys.argv[2], "w") as o:
    for line in f:
        if '"http_reqs"' not in line:
            continue
        p = json.loads(line)
        if p.get("type") != "Point" or p["metric"] != "http_reqs":
            continue
        t = p["data"]["time"]
        ts = datetime.fromisoformat(t[:26].rstrip("Z") + "+00:00" if "." in t else t.replace("Z", "+00:00")).timestamp()
        o.write(f"{ts:.4f}\t{p['data']['tags'].get('status', '')}\t{p['data']['tags'].get('phase', '')}\n")
        n += 1
print(n, "requests", file=sys.stderr)
