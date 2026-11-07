#!/usr/bin/env bash
# Module 6, the write cost of synchronous replication. Output: modules/m06-replication/results-sync-cost/
#   default   N runs (default 3), arms async and sync (synchronous_commit = remote_apply, standby '*') interleaved (order rotates
#             each run); fresh stack and quiet gate before each arm; 5 s warm-up at the same rate, then RATE creates/s for 30 s.
#   probe     PROBE="100 200 400 ..." runs each rate once per arm (to pick a moderate rate), labelled probe-*.
#   stopped   STOPPED=1: one run, sync configured, the standby (db2) stopped BEFORE the load starts; RATE creates/s for 20 s with a 5 s
#             client timeout. Single run, labelled so.
set -euo pipefail
runs=${1:-3}; out=modules/m06-replication/results-sync-cost; mkdir -p "$out"; rate=${RATE:-200}
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m06-replication/compose.replica.yaml APPLY_DELAY=0 RYW_SECONDS=0
lock="flock -o /tmp/claude-1000/sdlab.lock"
dc() { $lock docker compose "$@"; }
fresh() {  # fresh <tag> <async|sync>
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$1.gate"
  dc up -d --wait >/dev/null; sleep 3
  if [ "$2" = sync ]; then   # after the replica is attached: during init there is no standby to wait for
    dc exec -T db psql -U postgres -qAt -c "ALTER SYSTEM SET synchronous_standby_names = '*'" \
      -c "ALTER SYSTEM SET synchronous_commit = 'remote_apply'" -c "SELECT pg_reload_conf()" >/dev/null
    dc exec -T db psql -U postgres -qAt -c "SHOW synchronous_commit" -c "SELECT sync_state FROM pg_stat_replication" > "$out/$1.mode"
  fi
}
load() {  # load <tag> <rate> <seconds> [extra k6 env...]
  local tag=$1 r=$2 d=$3; shift 3
  python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & local cs=$!
  $lock nice -n 10 docker compose run --rm -e RATE=$r -e DURATION=$d -e RESULT="$out/$tag.json" "$@" k6 run --quiet modules/m06-replication/create-latency.js >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
  kill $cs; wait $cs 2>/dev/null || true
}
dc build app >/dev/null
if [ -n "${STOPPED:-}" ]; then
  tag=stopped-1
  fresh $tag sync
  dc stop db2 >/dev/null
  date +%s.%N > "$out/$tag.standby-stopped-at"
  load $tag "$rate" 20 -e TIMEOUT=5s -e VUS=1500 -e MAXVUS=4000
  # what the primary shows right after the load: rows the clients never got an answer for, and backends waiting for the standby
  { echo "rows_on_primary_from_this_load: $(dc exec -T db psql -U postgres -d shortener -qAt -c "SELECT count(*) FROM links WHERE url LIKE 'https://example.com/c/%'")"
    echo "backends_waiting_for_standby: $(dc exec -T db psql -U postgres -qAt -c "SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'SyncRep'")"
    # one create with a long client timeout: does it ever come back while the standby is down?
    echo "one_create_with_30s_timeout: $(curl -s -o /dev/null -m 30 -w '%{http_code} after %{time_total}s' -X POST -H 'Content-Type: application/json' -d '{"url":"https://example.com/hang-check"}' http://127.0.0.1:8080/api/links || true)"
  } > "$out/$tag.after.txt"
  echo "$tag done"; dc down -v --remove-orphans >/dev/null 2>&1; exit 0
fi
if [ -n "${PROBE:-}" ]; then
  for r in $PROBE; do for arm in async sync; do
    tag="probe-$arm-$r"; fresh $tag $arm
    load warm "$r" 5; load $tag "$r" 20
    echo "$tag done"
  done; done
  dc down -v --remove-orphans >/dev/null 2>&1; exit 0
fi
arms=(async sync)
for k in $(seq 1 "$runs"); do
  for i in 0 1; do
    arm=${arms[$(( (i + k - 1) % 2 ))]}; tag="$arm-$k"
    [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $tag "* ]] && continue
    fresh $tag $arm
    load warm "$rate" 5; load $tag "$rate" 30
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
dc down -v --remove-orphans >/dev/null 2>&1
rm -f "$out/warm.cpu.tsv" "$out/warm.json"
python3 tools/aggregate-m06-synccost.py "$out" "$runs"
