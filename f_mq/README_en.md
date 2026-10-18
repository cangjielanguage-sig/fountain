# f_mq

MQ client and the client/server shared API (dynamic library, `fountain::f_mq`).
Depends on `f_codec`, `f_data`, `f_protocol`, `f_net`, `f_util`.

## Quick start

```cangjie
import fountain::f_mq.*

main() {
    let client = MQClient(["127.0.0.1:2350"])   // or MQClient() to read mqClient_hosts
    client.publish("/order", "hello", tags: ["created"])
    let sid = client.subscribe("/order", subscribeGroup: "g1")
    let message = client.consume(sid)
    let body = message.get<String>()
    client.ack(sid, message.segmentedIndex, message.segmentedOffset)
    client.unsubscribe(sid)
    client.close()
}
```

## Packages

| Package | Purpose |
| --- | --- |
| `fountain::f_mq` | Facade, re-exports common declarations |
| `fountain::f_mq.base` | Record codec, filters, protocol factories, error codes, topic validation |
| `fountain::f_mq.base.model` | `MQTopicMeta` / `MQSubscribeGroupMeta` / `MQMessage` models |
| `fountain::f_mq.base.payload` | Protocol payload classes (`@DataAssist`) |
| `fountain::f_mq.client` | `MQClient`, node pool, ownership cache |
| `fountain::f_mq.exception` | `MQException` / `MQConnectionException` / `MQServiceException` |

## Semantics and limits

- Delivery is **at-least-once**: unacknowledged messages may be redelivered after a timeout or restart.
- Topic/group registration is not exposed to clients; use `fmq manager`.
- `consume` blocks until a message is available; the server returns "has/has not" immediately.
- Filters use `f_data.path` expressions. A record whose BODY is an unknown object type is not delivered
  when the subscription has a non-empty filter.
- No new protocol commands are introduced; MQ reuses existing `f_protocol` commands and distinguishes
  their purpose by the runtime payload type.

## Tests

```bash
cd f_mq && cjpm build && cjpm test
```
