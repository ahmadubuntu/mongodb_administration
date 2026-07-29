# MongoDB HA health-check architecture

## Topology (typical)

```mermaid
flowchart LR
  Client --> VIP["VIP / anycast"]
  VIP --> LB["LB hosts"]
  LB --> MS["mongos\n(optional)"]
  MS --> MD1["mongod A"]
  MS --> MD2["mongod B"]
  MS --> MD3["mongod C"]
  MD1 --- MD2
  MD2 --- MD3
  CS["configsvr RSA\n(sharded only)"] --- MS
```

Pure replica set: leave `VIP_HOST` / `LB_HOSTS` / `MONGOS_HOSTS` empty; clients hit `MONGOD_HOSTS:27017`.

## Check flow

```mermaid
flowchart TD
  A[Load inventory .env] --> B[SSH sweep parallel]
  B --> C[Port matrix local/listen/cross]
  C --> D[Cascade VIP→LB→mongos→mongod]
  D --> E[VIP owner / systemd]
  E --> F[RS membership + PRIMARY]
  F --> G[Replication lag + oplog window]
  G --> H[dbPath disk]
  H --> I[Sharded balancer / shards]
  I --> J[EXPECT_* config drift]
  J --> K[Capacity FD/conn/WT]
  K --> L[OS + boot integrity]
  L --> M[Summary PASS/WARN/SLOW/FAIL]
```

## Severity

| Status | Meaning | Exit contribution |
|--------|---------|-------------------|
| PASS | Healthy / expected | 0 |
| WARN | Degraded or checker gap | 1 |
| SLOW | Worked but slow SSH | 1 |
| FAIL | Availability/correctness broken | 2 |
| INFO | Context | 0 |
| SKIP | Prerequisite missing | 0 |

## Toolkits in this directory

1. **`./run_all.sh`** — orchestrator over suites (`--only ha` today).
2. **`./check_mongo_ha.sh`** — inventory-driven multi-node HA check (skill `ha-cluster-healthcheck`); tasks via `--only` / `--skip`.

Deep single-node admin suites (if added later) belong in `run_admin_suite.sh`, not `run_all.sh`.
