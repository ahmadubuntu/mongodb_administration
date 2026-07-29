# MongoDB realtime HA health check

Inventory-driven multi-node health check for MongoDB replica sets (and optional sharded topologies).

See [ARCHITECTURE.md](ARCHITECTURE.md) for topology and check flow.

## Quick start

```bash
cd mongodb_realtime_check
cp config/clusters/devmongo.example.env config/clusters/devmongo.env   # DEV
cp config/clusters/stgmongo.example.env config/clusters/stgmongo.env   # STG
# edit hosts / credentials — never commit *.env (gitignored)

./check_mongo_ha.sh -c config/clusters/devmongo.env -u a.abdolmaleki -y
./check_mongo_ha.sh -c config/clusters/stgmongo.env -u a.abdolmaleki -y --only membership,primary,latency
```

Verified defaults for gen clusters: `SSH_PORT=7412`, `MONGO_PORT=5061`, `REPLICA_SET_NAME=rs0`.
VIP/LB are empty by default (not checked). `hello`/`ping` work without auth; set `MONGO_URI` for `rs.status` / oplog / WiredTiger.

Options: `-v` verbose, `--json`, `-n` no sudo, `-o report.log`,
`--only TASKS`, `--skip TASKS`, `--ask-tasks`, `--list-tasks`.

```bash
./check_mongo_ha.sh -c config/clusters/devmongo.env -u a.abdolmaleki -y --only os
./check_mongo_ha.sh -c config/clusters/devmongo.env -u a.abdolmaleki -y --only membership,primary,lag,latency
./check_mongo_ha.sh -c config/clusters/devmongo.env --ask-tasks
./check_mongo_ha.sh --list-tasks
```

Exit codes: `0` PASS · `1` WARN/SLOW · `2` FAIL.

Reports: `reports/mongoaha-<slug>-<timestamp>.log`.

## What it checks

| Layer | Tasks |
|-------|--------|
| SSH | Parallel sweep, SLOW threshold, ControlMaster + no-mux fallback |
| Ports | local / listen / cross mesh (mongod, mongos, configsvr, LB→backend) |
| Cascade | VIP → LB → mongos → mongod (skipped when VIP/LB empty); auth gaps are WARN |
| RS | membership via `hello` (+ `rs.status` with auth), PRIMARY, lag, oplog |
| Latency | `{ping:1}` RTT from checker vs on PRIMARY |
| Sharded | balancer vs `EXPECT_BALANCER`, shard count vs `SHARD_NAMES` |
| Capacity | LimitNOFILE, connections, WiredTiger dirty % |
| OS | disk/load/NTP/OOM + boot integrity (fstab, logind, ext4 errors, passno) |

## Credentials

- SSH user once (`-u` or prompt); sudo password once if needed (`SUDO_PASSWORD` env or prompt).
- Mongo: prefer `MONGO_URI` in the gitignored `.env`, or `MONGO_USER` / `MONGO_PASSWORD`.
- Missing mongosh on the checker → WARN + SSH fallback to a member; missing auth → WARN.

## Inventory

Committed example: `config/clusters/devmongo.example.env`.  
Copy to `*.env` and fill real hosts/ports. Script probes **only** ports listed there.
