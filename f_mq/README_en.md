# f_mq

MQ client and the client/server shared API (dynamic library, `fountain::f_mq`).
Depends on `f_base`, `f_codec`, `f_config`, `f_data`, `f_io`, `f_log`, `f_net`, `f_protocol`,
`f_time`, `f_util`.

## Quick start

```cangjie
import fountain::f_mq.*

main() {
    let client = MQClient(["127.0.0.1:2350"])   // or MQClient() to read mqClient_hosts
    client.publish("/order", "hello", tags: ["created"])
    let sid = client.subscribe("/order", subscribeGroup: "g1", tags: ["created"])
    let message = client.consume(sid)
    let body = message.get<String>() ?? ""
    client.ack(sid, message.queueIndex, message.segmentedIndex, message.segmentedOffset)
    client.unsubscribe(sid)
    client.close()
}
```

`MQClient()` reads the node table from `mqClient_hosts` (comma-separated `host:port`).
A missing/empty value or an invalid entry throws `MQConnectionException` during
construction. Use `MQClient(hosts)` for tests or multiple clusters.

## Client API

```cangjie
public class MQClient <: Resource {
    public init(hosts: Array<String>)
    public init()

    public func publish<T>(topic: String, body: T, tags!: Array<String> = []): Unit where T <: ToData
    public func subscribe(topic: String, subscribeGroup!: String = '', tags!: Array<String> = [],
        filter!: String = '', autoAck!: Bool = false): String
    public func consume(subscribedId: String): MQMessage
    public func ack(subscribedId: String, queueIndex: Int64, segmentedIndex: Int64,
        segmentedOffset: Int64): Unit
    public func unsubscribe(subscribedId: String): Unit
    public func close(): Unit
    public func isClosed(): Bool
}
```

- `subscribe` returns a client-generated `subscribedId`; errors such as an unregistered
  group roll back the nodes that already accepted the subscription and throw
  `MQServiceException`.
- `publish` first picks an owner node of the topic; on `NOT_OWNER` it retries the next
  node, and throws `MQConnectionException` when no node is reachable.
- `consume` blocks until a message is available, rotating over the owner nodes with a
  200 ms idle poll; a single server `CONSUME` returns "has/has not" immediately.
- `ack` must echo the `queueIndex` returned by `consume`. The client first targets the
  node that delivered the position; on a miss it broadcasts to all owners and ignores
  `ACK_UNKNOWN`.
- `unsubscribe` is idempotent: re-unsubscribing a subscription id that was already
  unsubscribed returns successfully without sending a request, while an id that was
  never subscribed throws `MQServiceException` without sending a request. The client
  keeps a bounded set of retired ids (`MQRetiredSubscriptions`, 4096 by default, FIFO
  eviction); an evicted id is treated as "never subscribed".
- With `autoAck: true` the server advances the cursor on delivery, so the caller does not
  need to `ack`.
- `close` is idempotent; after closing, business APIs other than `isClosed()` throw
  `MQConnectionException`.

## Subscriptions and filters

- `tags` use subset matching: every subscription tag must appear in the message tags.
  An empty array means no tag filtering.
- `filter` is an `f_data.path` expression. Evaluation: an empty string always matches;
  no result → false; `DataBool(b)` yields `b`; `DataNone` → false; other types (presence)
  → true. For a BODY object with an `enabled: Bool` field, `filter: "$.enabled"` delivers
  only messages where `enabled` is `true`. Invalid expressions throw `DataException`
  locally during `subscribe`; no request is sent.
- When an active subscription has a non-empty filter and the server cannot evaluate the
  BODY (unregistered object type), publishing fails with `FILTER_UNSUPPORTED_BODY` and
  nothing is persisted, so messages are never silently dropped. Empty filters require no
  BODY decoding on the server.

## Error codes

The numeric `MQErrorCode` values are a public contract:

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `OK` | Success |
| 1 | `TOPIC_NOT_EXIST` | Topic does not exist |
| 2 | `TOPIC_ALREADY_EXIST` | Topic already exists |
| 3 | `GROUP_NOT_EXIST` | Subscribe group does not exist |
| 4 | `GROUP_ALREADY_EXIST` | Subscribe group already exists |
| 5 | `INVALID_TOPIC` | Invalid topic |
| 6 | `INVALID_GROUP` | Invalid subscribe group |
| 7 | `SUBSCRIBE_NOT_EXIST` | Subscription does not exist |
| 8 | `NOT_OWNER` | The node owns no queue of the topic |
| 9 | `ACK_UNKNOWN` | ACK position does not belong to the subscription |
| 10 | `FILTER_UNSUPPORTED_BODY` | The server cannot evaluate the filter on the BODY |
| 11 | `INTERNAL` | Internal error |

Server-side errors are thrown as `MQServiceException(code, message)`.

## Stats and delay helpers

`fountain::f_mq.base.MQProtocol` exposes two shared helpers for `fmq` (no new protocol
commands):

- `MQProtocol.stats(topic)`: builds a `REGISTER` + internal `stats` message; the response
  is TSV text, with the metric semantics and rendering handled by `fmq`.
- `MQMessageRecord.publishTime(record)`: parses the 23-digit UTC timestamp at the end of
  the messageId (`yyyyMMddHHmmss` + 9-digit nanoseconds) for server-side delayed delivery.
  Returns `None` for non-standard IDs.

The client API exposes no topic/group registration or stats entry point; use
`fmq manager` for operations.

## Naming and length limits

| Item | Rule |
| --- | --- |
| Topic | Non-empty, starts with `/`, does not end with `/`, no empty segment (`//`); no control characters or Unicode blanks; other checks fail locally with `INVALID_TOPIC` |
| Group | Empty string is the default group; at most `MQGroup.MAX_LENGTH` (255) bytes; no control characters/Unicode blanks and no `/` `\` `:` `%`; must not start or end with `.` (`INVALID_GROUP`) |
| Tags | At most `MQTags.MAX_COUNT` (64); each 1..`MQTags.MAX_LENGTH` (128) bytes; no control characters/Unicode blanks (`INVALID_TAGS`) |
| Single record | At most `min(QueueLog.MAX_RECORD_SIZE, segment size - 4 bytes)` (i.e. `QueueLog.effectiveMaxRecord`); larger records fail before any segment write |

## Semantics and limits

- Delivery is **at-least-once**: unacknowledged messages may be redelivered after a
  timeout or restart.
- A message position is the triple `(queueIndex, segmentedIndex, segmentedOffset)`.
  Each queue is an independent segmented log, so segment/offset alone collide across
  queues; `ack` must echo `queueIndex`.
- Topic registration accepts `delaying=<DurationString>` (via `fmq manager`). Delay is
  measured from the publish time, and not-yet-due records block later records in the same
  queue.
- No new protocol commands are introduced; MQ reuses `f_protocol` commands
  (`REGISTER` / `PUBLISH` / `SUBSCRIBE` / ...) and distinguishes their purpose by the
  runtime payload type.
- Records larger than 4096 bytes may be spooled to temporary files by the decoder;
  `MQBytes.fromData` restores the bytes either way, so large messages are never mistaken
  for empty ones.
- The set of retired subscription ids is bounded (`MQRetiredSubscriptions`, 4096 by
  default, FIFO eviction); an evicted id is treated as an unknown id and throws
  `MQServiceException`.
- A node offline for longer than the tombstone TTL (7d by default) cannot converge
  incrementally; wipe that node's `metas/` and restart it to pull a full snapshot.
- Full support for large records (>4096 bytes) requires **every node** in the cluster to
  be upgraded to this version.

## Packages

| Package | Purpose |
| --- | --- |
| `fountain::f_mq` | Facade, re-exports common declarations |
| `fountain::f_mq.base` | Record codec (`MQMessageRecord` / `MQBytes`), filters, protocol factories, error codes, topic validation, `MQHost` |
| `fountain::f_mq.base.model` | `MQTopicMeta` / `MQSubscribeGroupMeta` / `MQMessage` models |
| `fountain::f_mq.base.payload` | Protocol payload classes (`@DataAssist`) |
| `fountain::f_mq.client` | `MQClient`, `MQClientConfig`, node pool, ownership cache |
| `fountain::f_mq.exception` | `MQException` / `MQConnectionException` / `MQServiceException` |

## Tests

```bash
cd f_mq && cjpm build && cjpm test
```

End-to-end tests against a real server and network live in
[`fmq`](../fmq) under `scripts/mq_e2e.sh`.
