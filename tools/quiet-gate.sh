#!/usr/bin/env bash
# quiet-gate.sh [max_busy_pct] [max_steal_pct] [timeout_s]
# Waits until the machine is quiet before a measurement: samples /proc/stat over 10 s, and while the busy share
# (everything except idle and iowait) is above max_busy (default 15) or steal is above max_steal (default 2), waits
# 30 s and tries again. Prints "background_busy_pct=<n> steal_pct=<n>" for the run's record. Gives up after timeout
# (default 1800 s) and exits 1, so a run on a noisy machine is never silently recorded.
max_busy=${1:-15}; max_steal=${2:-2}; timeout=${3:-1800}; start=$(date +%s)
while :; do
  a=($(head -1 /proc/stat)); sleep 10; b=($(head -1 /proc/stat))
  tot=0; for i in 1 2 3 4 5 6 7 8; do tot=$(( tot + ${b[$i]} - ${a[$i]} )); done
  idle=$(( ${b[4]} - ${a[4]} + ${b[5]} - ${a[5]} )); steal=$(( ${b[8]} - ${a[8]} ))
  busy=$(( 100 * (tot - idle - steal) / tot )); stealp=$(( 100 * steal / tot ))
  if [ $busy -le $max_busy ] && [ $stealp -le $max_steal ]; then
    echo "background_busy_pct=$busy steal_pct=$stealp"; exit 0
  fi
  echo "machine busy ($busy% busy, $stealp% steal), waiting" >&2
  [ $(( $(date +%s) - start )) -ge $timeout ] && { echo "background_busy_pct=$busy steal_pct=$stealp (gave up)"; exit 1; }
  sleep 30
done
