# f_mq

消息队列的客户端与客户端/服务端共用 API（动态库，`fountain::f_mq`）。
依赖 `f_codec`、`f_data`、`f_protocol`、`f_net`、`f_util`。

## 快速开始

```cangjie
import fountain::f_mq.*

main() {
    let client = MQClient(["127.0.0.1:2350"])   // 或让 MQClient() 读取 mqClient_hosts
    client.publish("/order", "hello", tags: ["created"])
    let sid = client.subscribe("/order", subscribeGroup: "g1")
    let message = client.consume(sid)
    let body = message.get<String>()
    client.ack(sid, message.queueIndex, message.segmentedIndex, message.segmentedOffset)
    client.unsubscribe(sid)
    client.close()
}
```

## 包结构

| 包 | 作用 |
| --- | --- |
| `fountain::f_mq` | 门面，`public import` 重导出常用声明 |
| `fountain::f_mq.base` | 记录编解码、过滤器、协议工厂、错误码、主题校验 |
| `fountain::f_mq.base.model` | `MQTopicMeta` / `MQSubscribeGroupMeta` / `MQMessage` 等模型 |
| `fountain::f_mq.base.payload` | 协议载荷类（@DataAssist） |
| `fountain::f_mq.client` | `MQClient`、节点池、所有权缓存 |
| `fountain::f_mq.exception` | `MQException` / `MQConnectionException` / `MQServiceException` |

## 语义与限制

- 投递语义为 **at-least-once**：未确认消息在超时或服务重启后会重复投递。
- 一条消息的位置是 `(queueIndex, segmentedIndex, segmentedOffset)` 三元组：每个队列是独立的段日志，
  仅用段号与偏移会在多队列间重复，`ack` 必须原样带回 `queueIndex`。
- 不提供注册/删除主题的客户端 API，运维操作使用 `fmq manager`。
- `consume` 阻塞直到取到消息；服务端单次 `CONSUME` 立即返回「有/无」。
- 过滤器使用 `f_data.path` 表达式。存在非空过滤器的活跃订阅时，若 BODY 无法被服务端评估
  （未注册对象类型），发布返回 `FILTER_UNSUPPORTED_BODY` 且不落盘，不会静默丢消息。
- 协议层不新增命令号，复用 `f_protocol` 的 `REGISTER` / `PUBLISH` / `SUBSCRIBE` 等命令，
  同一命令的不同用途由载荷运行时类型区分。

## 测试

```bash
cd f_mq && cjpm build && cjpm test
```
