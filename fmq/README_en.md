# fmq

MQ server executable: `fmq server` and `fmq manager`.
Depends on `f_mq` (shared API), `f_io` (segmented log), `f_net` / `f_protocol` (inter-node transport).

## Run

```bash
export mqClient_hosts="127.0.0.1:2350,127.0.0.1:2351,127.0.0.1:2352"
export mqServer_port=2350
fmq server
```

Configuration (environment variables or command-line options):

| Key | Default |
| --- | --- |
| `mqServer_port` | 2350 |
| `mqServer_ackTimeout` | 10s |
| `mqServer_deadMsgThreshold` | 3 |
| `mqServer_deadMsgTTL` | 72h |
| `mqServer_segmentedLogDir` | `/var/log/fmq/segmentedLogs` |
| `mqServer_deadMsgDir` | `/var/log/fmq/deadMsgs` |
| `mqServer_segmentedLogMaxSize` | 1G |
| `mqServer_segmentedLogTTL` | 72h |
| `mqServer_backup` | 0 (disabled) |
| `mqClient_hosts` | required node table |

With `mqServer_backup = N`, each commit is replicated asynchronously to the next N nodes in the ring;
replicas are stored only and never delivered. `fmq server --help` prints all options.

## Manager

```bash
fmq manager --server=127.0.0.1:2350 registerTopic /order 4
fmq manager --server=127.0.0.1:2350 registerTopic /reminder 2 delaying=1m1s
fmq manager --server=127.0.0.1:2350 registerSubscriber /order grp1
fmq manager --server=127.0.0.1:2350 listTopics
fmq manager --server=127.0.0.1:2350 listSubscribeGroups /order
fmq manager --server=127.0.0.1:2350 deleteSubscribeGroup /order grp1
fmq manager --server=127.0.0.1:2350 deleteTopic /order
fmq manager --server=127.0.0.1:2350 stats /order
fmq manager --server=127.0.0.1:2350 stats
```

`--server` may appear before or after the subcommand. Without it, the manager connects to
`127.0.0.1:<mqServer_port>`. On connection failure it prints `无法连接消息队列服务` and exits 1.

## Metrics and delayed delivery

`stats [topic]` reports metrics for the **current node**: `backlog` (records after each group's
`committed` position), `lagMs` (age of the oldest backlog record), and process-lifetime counters
`delivered` / `acked` / `redelivered` / `deadLettered`, plus topic totals `messages` / `bytes`.
Query each node separately; the manager does not aggregate.

`registerTopic` accepts an optional `delaying=<DurationString>` (for example `1m1s`, default `0s`).
A record is delivered only after its publish time plus the delay. Not-yet-due records are not
delivered, do not advance the cursor, and block later records in the same queue (FIFO). The publish
time comes from the UTC timestamp in the messageId, so the delay survives restarts; producer and
server clocks must be synchronized. Records with a non-standard messageId are treated as due.

## Storage layout

```
<exe dir>/metas/
├── assign.meta
├── topics/<topicEsc>.meta
├── groups/<topicEsc>/<groupEsc>.meta
└── offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor
<segmentedLogDir>/<topicEsc>/<queueIndex>/log_<seq>.log
<segmentedLogDir>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/log_<seq>.log
<deadMsgDir>/log_<seq>.log
```

Topic names use percent-encoding (only `[A-Za-z0-9._-]`, empty → `%00`); metadata writes use `.tmp` + rename.

## Known limits

- At-least-once delivery; unacknowledged messages may be redelivered.
- No automatic failover; backup replicas are stored but not promoted.
- Manager and clients share the same TCP protocol; isolation relies on API capability (clients cannot register).
- If an active subscription has a non-empty filter and the BODY is an unregistered object type,
  publishing fails with `FILTER_UNSUPPORTED_BODY` and nothing is persisted; empty filters never
  require the server to decode the BODY.
- ACK targets the cursor by `(topic, queueIndex, group)`; a missing or non-local queue index yields
  `ACK_UNKNOWN`.
- If a cursor's segment was removed by TTL cleanup, it jumps to the oldest surviving segment and
  persists the new position; when no segment is readable it returns empty instead of failing forever.
- Backup writes may be dropped during shutdown: writes arriving after `BackupStore` closes are
  silently discarded so the publish path never blocks; writes acknowledged before close are persisted.

## Tests

```bash
cd fmq && cjpm build && cjpm test
cd .. && ./scripts/mq_e2e.sh    # 3-node e2e, prints E2E_OK
```
