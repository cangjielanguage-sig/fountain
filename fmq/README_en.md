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

### Start/stop script (recommended)

`fmq.sh` keeps process management and all configuration in one place:

```bash
bash fmq.sh start     # starts in background; pid in fmq.pid, output appended to fmq.log
bash fmq.sh stop      # SIGTERM; graceful shutdown via the f_base exit hook
bash fmq.sh restart   # stop, then start
```

The script exports every configuration key: `mqClient_hosts` is required and left uncommented,
while keys with defaults are commented out — uncomment to override; each key has a comment above it.
The executable is resolved as `$FMQ_BIN` → `fmq` on `PATH` → this repository's
`target/release/bin/main`; `metas/` still follows the executable directory.
The default `mqServer_segmentedLogDir` / `mqServer_deadMsgDir` live under `/var/log/fmq`, so a
non-root user should point them to a writable directory first.

`mqClient_hosts` is both the client node table and the server cluster node table. The
server matches its own index by `mqServer_port`; a port missing from the table or listed
twice fails startup.

`protocol_hostId` (an f_protocol setting, exported as `1` by the script) is **mandatory and
must be unique per machine**: it is part of `MessageID` equality/hash, and leaving it unset
(or `0`) makes `MessageID` throw `IllegalArgumentException` — `(pid, tid, timestamp)` repeats
across hosts, so `hostId` is the only cluster-wide discriminator.

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
| `mqServer_tombstoneTTL` | 7d (delete-tombstone retention) |
| `mqServer_antiEntropyInterval` | 30s (anti-entropy sync interval) |
| `mqClient_hosts` | required node table |

With `mqServer_backup = N`, each commit is replicated asynchronously to the next N nodes in
the ring (excluding itself, at most `nodeCount-1`). Replicas are stored only and never
delivered. The publish path only enqueues; a dedicated worker sends batches of 64 records or
every 100ms, re-queues failed batches, and drops them after 3 attempts with an ERROR. Backup
writes are dropped with a WARN when the queue is full or the store is shutting down, so the
publish path never blocks. Backup payloads carry real per-group cursors, so a restore never
replays acknowledged messages; backup segments are reclaimed by those cursors and
`segmentedLogTTL`. `fmq server --help` prints all options.

`SIGTERM`/`SIGINT` triggers graceful shutdown: the exit hook calls `MQServer.close()`, which
releases server → timers → anti-entropy → backup → cleaner → consume → subscribers → backup store → queues.sync → queues
→ dead letters → metadata → node connections. A failing step does not block the others, and
calling `close()` again retries only the failed steps.

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
- A record that matches no subscription in the group is marked "not applicable" and skipped
  (DEBUG log); when no subscription is online the position stays pending and the cursor does
  not advance.
- An unevaluable BODY (unregistered object type plus a non-empty filter) is skipped and the
  consumer that triggered the scan receives one `FILTER_UNSUPPORTED_BODY`; the same position
  is never reported twice and the group never stalls.

## Metrics and delayed delivery

`stats [topic]` reports metrics for the **current node**. Columns:
`topic / group / queueNum / delaying / backlog / lagMs / delivered / acked / redelivered / deadLettered /
skippedUnreadable / skippedNoMatch / skippedUnsupported`.

- `backlog`: records after the group's `committed` position in the topic's local queues
  (including delivered-but-unacknowledged and not-yet-due delayed records).
- `lagMs`: age of the oldest backlog record in milliseconds; `0` when there is no backlog.
- `delivered` / `acked` / `redelivered` / `deadLettered`: process-lifetime counters that
  reset on restart; `autoAck` deliveries also count as `acked`, and deleting a topic/group
  clears its counters.
- If scanning fails (corrupted segment) `stats` returns `ERROR(INTERNAL)` instead of faking
  `backlog=0`; `lagMs` is clamped to `0`.
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
├── revision.meta                       # Lamport counter
├── topics/<topicEsc>.meta
├── groups/<topicEsc>/<groupEsc>.meta
├── tombstones/t_<topicEsc>.meta         # topic tombstone
├── tombstones/g_<topicEsc>_<groupEsc>.meta
└── offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor
<segmentedLogDir>/<topicEsc>/<queueIndex>/log_<seq>.log
<segmentedLogDir>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/log_<seq>.log
<segmentedLogDir>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/cursors/<groupEsc>.cursor
<deadMsgDir>/log_<seq>.log
```

Topic names use percent-encoding (only `[A-Za-z0-9._-]`, empty → `%00`); metadata and cursor
writes use `.tmp` + `fsync` + rename + parent-directory `fsync`, so a power loss never leaves
an empty file.

## Naming and length limits

| Item | Rule |
| --- | --- |
| Topic | Non-empty, starts with `/`, does not end with `/`, no empty segment (`//`); no control characters or Unicode blanks (`INVALID_TOPIC`) |
| Group | Empty string is the default group; at most `MQGroup.MAX_LENGTH` (255) bytes; no control characters/Unicode blanks and no `/` `\` `:` `%`; must not start or end with `.` (`INVALID_GROUP`) |
| Tags | At most `MQTags.MAX_COUNT` (64); each 1..`MQTags.MAX_LENGTH` (128) bytes; no control characters/Unicode blanks (`INVALID_TAGS`) |
| Single record | At most `min(QueueLog.MAX_RECORD_SIZE, segmentedLogMaxSize - 4)` (i.e. `QueueLog.effectiveMaxRecord`); rejected before write |

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
- If a cursor's segment was removed by TTL cleanup, it jumps forward to the start of the
  next existing segment with a larger index and persists the new position (WARN, rate
  limited per position); when no segment is readable it returns empty instead of failing
  forever.
- Backup writes may be dropped during shutdown: writes arriving after `BackupStore` closes
  are discarded with a WARN trace (rate limited to one per second) so the publish path never
  blocks; writes acknowledged before close are persisted.
- Segment retention is bounded by the minimum persisted cursor of every registered group: a
  group that never consumed pins the floor at the oldest segment. Delete the group (or lower
  `segmentedLogTTL` and accept the semantic change) to reclaim history.
- Tombstones are kept for 7 days by default. A node offline longer than
  `mqServer_tombstoneTTL` cannot converge incrementally and needs a metadata rebuild (clear
  its `metas/` and restart to pull a snapshot).
- Full support for large records (>4096 bytes) requires every node to be upgraded: an old
  node still degrades them to empty, so finish the rolling upgrade before publishing large
  messages.
- The set of retired subscription ids is bounded (4096 by default, FIFO eviction); an
  evicted id is treated as an unknown id and throws `MQServiceException`, without touching
  server state.

## Tests

```bash
cd fmq && cjpm build && cjpm test
cd .. && ./scripts/mq_e2e.sh    # 3-node e2e, prints E2E_OK
```

For a minimal single-node walkthrough see [`fmqdemo`](../fmqdemo): both the publisher and the
consumer are fboot-loaded dynamic libraries, and `bash fmqdemo/run-demo.sh` runs the whole
"start fmq → register topic/group → publish → consume & ack → verify" flow in one command.
