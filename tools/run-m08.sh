#!/usr/bin/env bash
# Module 8, N runs (default 3). About 5 minutes. For each store: 30 s of writes and reads every 200 ms; from 10 s to
# 20 s one node is cut off from its peers (it can still be reached by the client).
#   etcd:  writes to the cut-off node e1 and to e2 in the majority; reads from e1, linearizable vs local (serializable)
#   redis: writes to the primary r1; reads from the cut-off replica r2
set -euo pipefail
runs=${1:-3}; out=modules/m08-cap/results; mkdir -p "$out"
C="docker compose -f modules/m08-cap/compose.cap.yaml -p sdcap"
for k in $(seq 1 "$runs"); do
  $C down -v >/dev/null 2>&1 || true; $C up -d --build >/dev/null; sleep 6
  for kind in etcd redis; do
    svc=client; victim=$([ $kind = etcd ] && echo sdcap-e1-1 || echo sdcap-r2-1)
    ( sleep 10; docker network disconnect sdcap_peers $victim; sleep 10; docker network connect sdcap_peers $victim ) & ev=$!
    $C exec -T $svc sh -s $kind 30 < modules/m08-cap/cap-probe.sh > "$out/$kind-$k.log"
    wait $ev; sleep 5; echo "run $k $kind done"
  done
done
$C down -v >/dev/null 2>&1
python3 tools/aggregate-m08.py "$out" "$runs"
