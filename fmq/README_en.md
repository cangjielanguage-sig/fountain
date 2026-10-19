# fmq

MQ server executable: `fmq server` and `fmq manager`.
Depends on `f_mq` (shared API), `f_io` (segmented log), `f_net` / `f_protocol` (inter-node transport).

## Build and run

```bash
cjpm build          # artifact: target/release/bin/main
cjpm install        # installs $HOME/.cjpm/bin/fmq

export mqClient_hosts="127.0.0.1:2350,127.0.0.1:2351,127.0.0.1:2352"
export mqServer_port=2350
fmq server
```

`mqClient_hosts` is both the client node table and the server cluster node table. The
server matches its own index by `mqServer_port`; a port missing from the table or listed
twice fails startup. In a multi-node deployment, also set a unique `protocol_hostId` per
machine, otherwise `MessageID` cannot distinguish nodes.

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

With `mqServer_backup = N`, each commit is replicated asynchronously to the next N nodes in
the ring (excluding itself, at most `nodeCount-1`). Replicas are stored only and never
delivered. Backup writes are dropped with a WARN when the backup queue is full or the store
is shutting down, so the publish path never blocks. `fmq server --help` prints all options.

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
`127.0.0.1:<mqServer_port>`. On connection failure it prints `无法连接消息队列服务` and
exits 1. `listTopics` prints topic, queueNum, delaying and the queue-to-node assignment;
`listSubscribeGroups` prints the groups (an empty name is shown as the default group).

## Consumption semantics

- A topic has `queueNum` queues assigned round-robin across nodes at registration time;
  each queue is an independent segmented log.
- Subscribe groups are registered per `(topic, group)`; one group cursor is kept per
  `(topic, queueIndex, group)` and shared by the subscriptions in the group (in-flight
  entries are owned by a specific subscription), with **at-least-once** delivery.
- `ack` advances the queue's `committed` position; messages not acknowledged within
  `mqServer_ackTimeout` are redelivered.
- A message whose delivery count exceeds `mqServer_deadMsgThreshold` is moved to the dead
  letter queue and no longer delivered; dead-letter segments are retained per
  `mqServer_deadMsgTTL`.
- `autoAck` subscriptions advance the cursor on delivery, so clients need not `ack`.
- Not-yet-due delayed messages are not delivered, do not advance the cursor, and block
  later records in the same queue (FIFO).

## Metrics and delayed delivery

`stats [topic]` reports metrics for the **current node**. Columns:
`topic / group / queueNum / delaying / backlog / lagMs / delivered / acked / redelivered / deadLettered`.

- `backlog`: records after the group's `committed` position in the topic's local queues
  (including delivered-but-unacknowledged and not-yet-due delayed records).
- `lagMs`: age of the oldest backlog record in milliseconds; `0` when there is no backlog.
- `delivered` / `acked` / `redelivered` / `deadLettered`: process-lifetime counters that
  reset on restart.
- A topic with no subscribe group yields one zero row with an empty `group`; `stats`
  without a topic aggregates the topics owned by this node.

Query each node separately; the manager does not aggregate. `backlog` / `lagMs` are
computed by scanning at query time, so a very large backlog costs some time.

`registerTopic` accepts an optional `delaying=<DurationString>` (for example `1m1s`,
default `0s`). A record is delivered only after its publish time plus the delay.
Not-yet-due records are not delivered, do not advance the cursor, and block later records
in the same queue (FIFO). The publish time comes from the UTC timestamp in the messageId,
so the delay survives restarts; producer and server clocks must be synchronized (NTP).
Records with a non-standard messageId are treated as due and logged at WARN.

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

Topic names use percent-encoding (only `[A-Za-z0-9._-]`, empty → `%00`); metadata writes
use `.tmp` + rename.

## Known limits

- At-least-once delivery; unacknowledged messages may be redelivered.
- No automatic failover; backup replicas are stored but not promoted.
- Manager and clients share the same TCP protocol; isolation relies on API capability
  (clients cannot register).
- If an active subscription has a non-empty filter and the BODY is an unregistered object
  type, publishing fails with `FILTER_UNSUPPORTED_BODY` and nothing is persisted; empty
  filters never require the server to decode the BODY.
- ACK targets the cursor by `(topic, queueIndex, group)`; a missing or non-local queue
  index yields `ACK_UNKNOWN`.
- If a cursor's segment was removed by TTL cleanup, it jumps to the oldest surviving
  segment and persists the new position; when no segment is readable it returns empty
  instead of failing forever.
- Backup writes may be dropped during shutdown: writes arriving after `BackupStore` closes
  are silently discarded so the publish path never blocks; writes acknowledged before
  close are persisted.

## Tests

```bash
cd fmq && cjpm build && cjpm test
cd .. && ./scripts/mq_e2e.sh    # 3-node e2e, prints E2E_OK
```
