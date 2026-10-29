#!/bin/sh
# Runs inside the client containers. Every 200 ms for SECONDS: write a counter to one node and read it from another,
# printing "<ms since start> <op> <node> <ok|fail> <value>". The runner cuts the network halfway through.
now() { awk '{printf "%d", $1 * 1000}' /proc/uptime; }
kind=$1; secs=${2:-30}; start=$(now); i=0
while [ $(( $(now) - start )) -lt $(( secs * 1000 )) ]; do
  i=$((i + 1)); t=$(( $(now) - start ))
  if [ "$kind" = etcd ]; then
    for n in e1 e2; do
      if etcdctl --endpoints=http://$n:2379 --command-timeout=800ms put k-$n $i >/dev/null 2>&1; then echo "$t write $n ok $i"; else echo "$t write $n fail $i"; fi
    done
    v=$(etcdctl --endpoints=http://e1:2379 --command-timeout=800ms get k-e2 --print-value-only 2>/dev/null) && echo "$t read-linear e1 ok $v" || echo "$t read-linear e1 fail -"
    v=$(etcdctl --endpoints=http://e1:2379 --command-timeout=800ms --consistency=s get k-e2 --print-value-only 2>/dev/null) && echo "$t read-local e1 ok $v" || echo "$t read-local e1 fail -"
  else
    redis-cli -h r1 set k $i >/dev/null 2>&1 && echo "$t write r1 ok $i" || echo "$t write r1 fail $i"
    v=$(redis-cli -h r2 get k 2>/dev/null) && echo "$t read r2 ok $v" || echo "$t read r2 fail -"
  fi
  sleep 0.2
done
