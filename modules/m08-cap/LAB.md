# Module 8 — CAP: hands-on

Do this alongside lessons 8.1–8.4. **Predict first, write it down, then run.** Whole module: `make m08` (about 5 min).
This module runs as its own small project (`sdcap`) with two networks: `peers` inside each cluster, `clients` for you.

```bash
C="docker compose -f modules/m08-cap/compose.cap.yaml -p sdcap"
$C up -d --build
```

## 1. etcd: refuse (lesson 8.2)
```bash
$C exec client etcdctl --endpoints=http://e1:2379 put k 1
docker network disconnect sdcap_peers sdcap-e1-1           # cut e1 off from e2 and e3; you can still reach it
$C exec client etcdctl --endpoints=http://e1:2379 --command-timeout=2s put k 2
$C exec client etcdctl --endpoints=http://e2:2379 put k 3
$C exec client etcdctl --endpoints=http://e1:2379 --command-timeout=2s get k
$C exec client etcdctl --endpoints=http://e1:2379 --consistency=s get k
docker network connect sdcap_peers sdcap-e1-1
```
**Predict, before each line:** does it succeed? What value does each read return?

## 2. Redis replica: answer anyway (lesson 8.3)
```bash
$C exec client redis-cli -h r1 set k 1
docker network disconnect sdcap_peers sdcap-r2-1
$C exec client redis-cli -h r1 set k 2
$C exec client redis-cli -h r2 get k
docker network connect sdcap_peers sdcap-r2-1
```
**Predict:** what does the replica answer while it's cut off?

## 3. The measured version
`make m08` writes and reads every 200 ms for 30 s and cuts the network for the middle 10 s; see
`modules/m08-cap/results/results.json`.

Clean up: `$C down -v`.
