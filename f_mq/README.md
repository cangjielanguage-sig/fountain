# f_mq

消息队列的客户端与客户端/服务端共用 API（动态库，`fountain::f_mq`）。
依赖 `f_base`、`f_codec`、`f_config`、`f_data`、`f_io`、`f_log`、`f_net`、`f_protocol`、`f_time`、`f_util`。

## 快速开始

```cangjie
import fountain::f_mq.*

main() {
    let client = MQClient(["127.0.0.1:2350"])   // 或 MQClient() 读取 mqClient_hosts
    client.publish("/order", "hello", tags: ["created"])
    let sid = client.subscribe("/order", subscribeGroup: "g1", tags: ["created"])
    let message = client.consume(sid)
    let body = message.get<String>() ?? ""
    client.ack(sid, message.queueIndex, message.segmentedIndex, message.segmentedOffset)
    client.unsubscribe(sid)
    client.close()
}
```

`MQClient()` 从配置项 `mqClient_hosts`（逗号分隔的 `host:port`）读取节点表；缺失、为空或
存在非法项时在构造期抛 `MQConnectionException`。显式构造 `MQClient(hosts)` 用于测试或多集群。

## 客户端 API

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

- `subscribe` 返回客户端生成的 `subscribedId`；未注册订阅组等错误会回滚已接受的节点并抛
  `MQServiceException`。
- `unsubscribe` 幂等：已成功退订过的 id 再退订返回成功且不发请求；从未订阅的 id 抛
  `MQServiceException` 且不发请求。客户端只记住有界的已退订 id 集合（`MQRetiredSubscriptions`，
  默认 4096，FIFO 淘汰），被淘汰的 id 视同「从未订阅」。
- `publish` 先选主题的 owner 节点；遇到 `NOT_OWNER` 换下一个节点重试，全部节点不可达时抛
  `MQConnectionException`。
- `consume` 阻塞直到取到消息：在 owner 节点间轮转，空轮询间隔 200ms；服务端单次 `CONSUME`
  立即返回「有/无」。
- `ack` 的 `queueIndex` 必须与 `consume` 返回的位置一致；客户端优先发给投递该位置的节点，
  未命中时向所有 owner 广播并忽略 `ACK_UNKNOWN`。
- `autoAck: true` 的订阅由服务端在投递时自动推进游标，业务侧无需 `ack`。
- `close` 幂等；关闭后除 `isClosed()` 外的业务 API 抛 `MQConnectionException`。

## 订阅与过滤

- `tags` 采用子集匹配：订阅的每个 tag 都必须出现在消息 tags 中；空数组表示不过滤。
- `filter` 使用 `f_data.path` 表达式，求值规则：空串恒真；表达式无结果 → 假；
  `DataBool(b)` 取 `b`；`DataNone` → 假；其它类型（存在即匹配）→ 真。
  例如 BODY 是带 `enabled: Bool` 字段的对象时，`filter: "$.enabled"` 只投递 `enabled`
  为 `true` 的消息。非法表达式在 `subscribe` 本地编译时抛 `DataException`，不发请求。
- 存在非空过滤器的活跃订阅时，若 BODY 无法被服务端评估（未注册对象类型），发布返回
  `FILTER_UNSUPPORTED_BODY` 且不落盘，不会静默丢消息；空过滤器不需要服务端解码 BODY。

## 错误码

`MQErrorCode` 的数值是对外契约：

| 码 | 名称 | 含义 |
| --- | --- | --- |
| 0 | `OK` | 成功 |
| 1 | `TOPIC_NOT_EXIST` | 主题不存在 |
| 2 | `TOPIC_ALREADY_EXIST` | 主题已存在 |
| 3 | `GROUP_NOT_EXIST` | 订阅组不存在 |
| 4 | `GROUP_ALREADY_EXIST` | 订阅组已存在 |
| 5 | `INVALID_TOPIC` | 非法主题 |
| 6 | `INVALID_GROUP` | 非法订阅组 |
| 7 | `SUBSCRIBE_NOT_EXIST` | 订阅不存在 |
| 8 | `NOT_OWNER` | 节点不持有该主题的任何队列 |
| 9 | `ACK_UNKNOWN` | ack 位置不属于该订阅 |
| 10 | `FILTER_UNSUPPORTED_BODY` | 服务端无法在 BODY 上求值过滤器 |
| 11 | `INTERNAL` | 内部错误 |

服务端错误以 `MQServiceException(code, message)` 抛出。

## 统计与延迟辅助

`fountain::f_mq.base.MQProtocol` 为 `fmq` 提供两个共用辅助（不新增协议命令）：

- `MQProtocol.stats(topic)`：构造 `REGISTER` + 内部 `stats` 消息，响应为 TSV 文本；
  统计口径与渲染在 `fmq` 侧。
- `MQMessageRecord.publishTime(record)`：解析 messageId 末尾的 23 位 UTC 时间戳
  （`yyyyMMddHHmmss` + 9 位纳秒），用于服务端延迟投递判定；非标准 ID 返回 `None`。

客户端 API 不提供主题/订阅组注册与统计入口；运维操作使用 `fmq manager`。

## 命名与长度限制

| 项目 | 规则 |
| --- | --- |
| 主题 | 非空、以 `/` 开头、不以 `/` 结尾、无空段（`//`）；不含控制字符与 Unicode 空白（`MQChars.isBlankOrControl`）；不是绝对路径时本地直接失败（`INVALID_TOPIC`） |
| 订阅组 | 空串为默认组；≤ `MQGroup.MAX_LENGTH`（255）字节；不含控制字符/Unicode 空白与 `/` `\` `:` `%`；不以 `.` 开头或结尾（`INVALID_GROUP`） |
| tags | 最多 `MQTags.MAX_COUNT`（64）个，每个 1..`MQTags.MAX_LENGTH`（128）字节；不含控制字符/Unicode 空白（`INVALID_TAGS`） |
| 单条记录 | ≤ `min(QueueLog.MAX_RECORD_SIZE, 段上限 - 4 字节)`（即 `QueueLog.effectiveMaxRecord`）；超过时发布本地失败，不会写入段文件 |

## 语义与限制

- 投递语义为 **at-least-once**：未确认消息在超时或服务重启后会重复投递。
- 一条消息的位置是 `(queueIndex, segmentedIndex, segmentedOffset)` 三元组：每个队列是独立的段日志，
  仅用段号与偏移会在多队列间重复，`ack` 必须原样带回 `queueIndex`。
- 主题注册时可用 `delaying=<DurationString>` 设置延迟投递（由 `fmq manager` 操作），延迟按消息
  发布时间计算，未到期消息会阻塞该队列的后续消息。
- 协议层不新增命令号，复用 `f_protocol` 的 `REGISTER` / `PUBLISH` / `SUBSCRIBE` 等命令，
  同一命令的不同用途由载荷运行时类型区分。
- 大于 4096 字节的记录在解码侧可能落临时文件；`MQBytes.fromData` 统一还原为字节数组，
  避免把大消息误判成空消息。
- 已退订 id 集合有界（`MQRetiredSubscriptions`，默认 4096，FIFO 淘汰）；被淘汰的 id 再退订按
  「未知 id」处理并抛 `MQServiceException`。
- 节点离线时间超过墓碑 TTL（默认 7d）后无法靠增量收敛，需要清空该节点 `metas/` 后重启拉全量快照。
- 大记录（>4096 字节）的完整支持要求集群内**所有节点**升级到本版本。

## 包结构

| 包 | 作用 |
| --- | --- |
| `fountain::f_mq` | 门面，`public import` 重导出常用声明 |
| `fountain::f_mq.base` | 记录编解码（`MQMessageRecord` / `MQBytes`）、过滤器、协议工厂、错误码、主题校验、`MQHost` |
| `fountain::f_mq.base.model` | `MQTopicMeta` / `MQSubscribeGroupMeta` / `MQMessage` 等模型 |
| `fountain::f_mq.base.payload` | 协议载荷类（`@DataAssist`） |
| `fountain::f_mq.client` | `MQClient`、`MQClientConfig`、节点池、所有权缓存 |
| `fountain::f_mq.exception` | `MQException` / `MQConnectionException` / `MQServiceException` |

## 测试

```bash
cd f_mq && cjpm build && cjpm test
```

服务端与真实网络链路的端到端测试见 [`fmq`](../fmq) 的 `scripts/mq_e2e.sh`。
