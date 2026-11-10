# fountain实现思想与应用第十三弹

##### ——消息队列

项目链接：https://gitcode.com/Cangjie-TPC/fountain

消息队列的 API 通常只有两个：发和收。

```cj
client.publish("/order", "hello")
let message = client.consume(sid)
```

真正难的是这两个动作背后的问题：

- 一条消息如何避免重复处理？重复了怎么办？
- 消费者崩溃重启后，从哪里继续消费？
- 一个主题的队列如何分配到多个节点，客户端如何找到它们？
- 积压量与最早消息的滞留时长如何计算？
- 历史消息如何安全清理？

fountain 的消息队列用两个模块回答这些问题：`f_mq`（客户端 + 客户端/服务端共用 API）和 `fmq`（服务端可执行程序）。

---

## 一、先看模型：队列是并行单位，组游标是进度单位

主题、队列、订阅组与游标的关系：

```
  主题 /order（queueNum = 4）
  ├── queue 0  ──►  分段日志 log_0.log, log_1.log, …
  ├── queue 1  ──►  分段日志 …
  ├── queue 2  ──►  分段日志 …
  └── queue 3  ──►  分段日志 …

  订阅组 grp1 × queue 0  ──►  一个游标 cursor（committed）
  订阅组 grp1 × queue 1  ──►  一个游标
  …
```

- 主题注册时指定 `queueNum`，这些队列**按节点轮转分配**，每个队列是一份**独立的段日志**；
- 订阅组按 `(topic, group)` 注册；
- 每个 `(topic, queueIndex, group)` 维护一个**组游标**，组内所有订阅共享这个游标；
- 并发度 = 队列数，不是订阅者数。想让一个组消费得更快，要么加队列（注册时定死），要么在组内加订阅者分摊队列。

### 为什么一条消息的位置是三元组

```cj
public func ack(subscribedId: String, queueIndex: Int64,
    segmentedIndex: Int64, segmentedOffset: Int64): Unit
```

因为**每个队列都是独立的段日志**。如果位置只有 `(segmentedIndex, segmentedOffset)`，那么「queue 0 的第 1 段偏移 100」和「queue 1 的第 1 段偏移 100」会撞在一起——ack 到错误的队列，游标就乱了。

所以 `queueIndex` 不是冗余信息，它是**命名空间**。客户端要做的只有一件事：**把 `consume` 返回值里的三个字段原样带回来**，不要自己拼。

---

## 二、at-least-once 是怎么「做」出来的

fmq 的投递语义是 **at-least-once**（至少一次）。这不是一句声明，而是四个机制叠加的结果：

```
  ① 投递：服务端把记录位置交给消费者，游标不前进
        │
  ② 确认：ack 到达 → 推进该队列的 committed
        │
  ③ 超时：超过 mqServer_ackTimeout 未确认 → 重投
        │
  ④ 阈值：投递次数 > mqServer_deadMsgThreshold → 进死信，不再投递
```

关键在 ①：**投递不等于确认**。游标只在 `ack` 时前进，所以进程崩溃、网络断开、客户端卡住，都会导致同一条消息被再次投递。这就是「至少一次」的来源，也是它的代价。

```bash
export mqServer_ackTimeout=10s
export mqServer_deadMsgThreshold=3
export mqServer_deadMsgTTL=72h
```

一条消息投递超过 3 次（默认）就进死信，死信段按 72h 保留。**死信不是「丢弃」，是「隔离」**——它还在盘上，只是不再阻塞正常消费。没有死信队列的 MQ，一条毒消息就能让整个组停摆。

### 组游标的三个细节

1. **组内无匹配订阅**：该位置被标记为「不适用」并越过（DEBUG 日志）。因为组游标是共享的，某个订阅只关心部分消息时，不能让它挡住别人。
2. **组内无人在线**：保留未决、不推进。此时游标停在原地，积压就是积压。
3. **`autoAck` 订阅**：服务端在投递时自动推进游标，客户端不用 `ack`。适合「丢了也无所谓」的指标、日志类消息。

### 消费端必须自己保证幂等

at-least-once 意味着**重复是常态，不是异常**。业务侧的写法应该是「按业务主键 upsert」或「先查后写 + 唯一约束」，而不是假设「只会来一次」。

框架不在这里替业务做去重：它选择显式的 at-least-once，而不是静默的 at-most-once。

---

## 三、存储：元数据与消息走两条路

```
<可执行文件目录>/metas/
├── assign.meta                         # 队列 → 节点分配
├── revision.meta                       # Lamport 计数器
├── topics/<topicEsc>.meta
├── groups/<topicEsc>/<groupEsc>.meta
├── tombstones/t_<topicEsc>.meta        # 主题墓碑
├── tombstones/g_<topicEsc>_<groupEsc>.meta
└── offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor

<segmentedLogDir>/<topicEsc>/<queueIndex>/log_<seq>.log
<segmentedLogDir>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/log_<seq>.log
<deadMsgDir>/log_<seq>.log
```

两条路的取舍完全不同：

**消息路径：单机顺序追加 + 段文件。** 没有分布式共识，没有两阶段提交。一条消息写进当前段就返回，落盘由段文件与 `sync()` 负责（关闭时统一 `queues.sync()`）。这是吞吐的来源——**绝大多数 MQ 的写路径都不该有共识算法**。

**元数据路径：文件 + Lamport 计数器 + 墓碑 + 反熵。** 主题、订阅组、队列分配这些数据量极小、变更极少，用最终一致足够：

- 每次变更递增 `revision.meta` 的 Lamport 计数；
- 删除不真删，留**墓碑**（默认 `mqServer_tombstoneTTL=7d`），否则离线的节点重新上线会把已删的元数据「复活」；
- 每 `mqServer_antiEntropyInterval`（默认 30s）做一次反熵同步，把差异补齐。

这个组合的优点是简单、可预期；代价写在「已知限制」里：**节点离线超过墓碑 TTL 就无法靠增量收敛**，必须清空该节点的 `metas/` 重新拉全量快照。这是一个明确的运维动作，而不是一个能被自动修复的故障。

### 写入的原子性

元数据与游标写入用 `.tmp` + `fsync` + rename + 父目录 `fsync`。

父目录也要 fsync：rename 改了目录项，只 fsync 文件不保证目录项落盘——掉电后可能出现「文件存在但目录里看不到」或者空文件。漏掉这一步，掉电后的表现是「元数据莫名丢失」。

---

## 四、备份：先明确它不是什么

```bash
export mqServer_backup=2    # 每条消息异步推送给环形后续的 2 个节点
```

- 副本节点是**环形的后续 N 个**（不含自身，最多 `节点数-1`）；
- 副本**只落盘，不参与投递**；
- 发布路径只入队，独立工作线程按 **64 条或 100ms** 批量发送；
- 失败批次重入队，最多重试 3 次后丢弃并记 ERROR；
- 备份队列满或关闭阶段到达的写入会**丢弃并记 WARN**，发布路径不阻塞。

所以：**这是数据副本，不是高可用。**

它保证的是「主节点盘坏了，数据还在别的机器上」，不保证「主节点挂了，服务自动切过去」。fmq 没有自动故障转移，`mqServer_backup` 也不能当 Raft 用。

这样设计的原因是：自动故障转移需要选主、一致性的队列分配，还要处理脑裂，复杂度是另一个量级。fmq 先保证不丢与可恢复，把自动故障转移留给运维或上层调度。

备份载荷里带着**每组真实位点**（`cursors`），恢复时据此不回放已确认消息；备份段按位点与 `segmentedLogTTL` 一起清理，所以磁盘不会无界增长。这两个细节决定了备份是「可用的副本」而不是「一堆无法判断进度的日志」。

---

## 五、延迟消息：时间戳藏在 messageId 里

```bash
fmq manager --server=127.0.0.1:2350 registerTopic /reminder 2 delaying=1m1s
```

延迟投递的判定基准是**消息的发布时间**，而发布时间来自 `messageId` 末尾的 23 位 UTC 时间戳（`yyyyMMddHHmmss` + 9 位纳秒）。

不用「入队时间」，是因为**跨重启有效**：服务重启后，`messageId` 还在，发布时间就还在；如果记在内存里，重启后所有延迟消息都会提前到期。

两个行为要注意：

1. **未到期消息会阻塞该队列的后续消息**，以保持 FIFO。延迟主题的队列不应混放即时消息，否则一条 1 小时后到期的消息会阻塞它之后的全部消息。
2. 依赖生产者与服务端**时钟基本同步**（NTP）。非标准 `messageId` 无法解析时间戳时，按已到期处理并记 WARN。

---

## 六、过滤：tags 是粗筛，表达式是细筛

```cj
let sid = client.subscribe("/order", subscribeGroup: "g1",
    tags: ["created"], filter: "$.enabled")
```

**tags 是子集匹配**：订阅的每个 tag 都必须出现在消息 tags 中；空数组表示不过滤。

**filter 是 `f_data.path` 表达式**，求值规则很克制：

| 表达式结果 | 是否投递 |
| --- | --- |
| 空串 | 恒真 |
| 无结果 | 假 |
| `DataBool(b)` | 取 `b` |
| `DataNone` | 假 |
| 其它类型（存在即匹配） | 真 |

所以 BODY 是带 `enabled: Bool` 字段的对象时，`filter: "$.enabled"` 只投递 `enabled == true` 的消息。非法表达式在 `subscribe` **本地编译时**抛 `DataException`，不发请求——错误尽早暴露。

有一个设计上很讲究的点：

> 存在非空过滤器的活跃订阅时，若 BODY 无法被服务端评估（未注册对象类型），发布返回 `FILTER_UNSUPPORTED_BODY`**且不落盘**。

它既不把「评估不了」当成通过，也不丢弃消息，而是**返回错误，让生产者知道**。前两种做法都会造成「消息静默丢失或静默误投」，这类问题在生产环境里排查成本高。

代价是：生产者需要处理这个错误码，或者提前把对象类型注册进集群。空过滤器不需要服务端解码 BODY，所以「不过滤」的路径没这个负担。

---

## 七、用起来

### 客户端

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

`MQClient` 的行为要点：

- `MQClient()` 从 `mqClient_hosts`（逗号分隔的 `host:port`）读节点表；缺失、为空或有非法项时**构造期**抛 `MQConnectionException`；
- `publish` 先找主题的 owner 节点，遇到 `NOT_OWNER` 换下一个重试，全不可达抛 `MQConnectionException`；
- `consume` 阻塞直到取到消息：在 owner 节点间轮转，空轮询间隔 200ms；
- `ack` 优先发给投递该位置的节点，未命中时向所有 owner 广播并忽略 `ACK_UNKNOWN`；
- `unsubscribe` 幂等，但客户端只记住**有界**的已退订 id 集合（默认 4096，FIFO 淘汰），被淘汰的 id 再退订会按「从未订阅」处理并抛 `MQServiceException`。

### 服务端与运维

```bash
cjpm install
export mqClient_hosts="127.0.0.1:2350,127.0.0.1:2351,127.0.0.1:2352"
export mqServer_port=2350
fmq server
```

客户端 API **不提供**主题/订阅组注册入口，注册是运维动作：

```bash
fmq manager --server=127.0.0.1:2350 registerTopic /order 4
fmq manager --server=127.0.0.1:2350 registerSubscriber /order grp1
fmq manager --server=127.0.0.1:2350 listTopics
fmq manager --server=127.0.0.1:2350 stats /order
```

`stats` 的输出是排障的主视图：

```
topic / group / queueNum / delaying / backlog / lagMs / delivered / acked
     / redelivered / deadLettered / skippedUnreadable / skippedNoMatch / skippedUnsupported
```

- `backlog`：本地队列中 `committed` 之后的记录数（含已投递未确认与未到期延迟消息）；
- `lagMs`：backlog 中最早一条消息的发布时长（毫秒），无积压为 `0`；
- `delivered` / `acked` / `redelivered` / `deadLettered`：**进程启动以来**的累计值，重启归零；
- 扫描失败（段损坏）返回 `ERROR(INTERNAL)`，**不会伪造 `backlog=0`**。

`backlog=0` 和「读不出来」必须能区分：前者是空队列，后者是故障。

`stats` 只返回**当前节点**的指标，多节点部署要分别查，manager 不自动聚合。

### 一条命令跑通全流程

```bash
bash fmqdemo/run-demo.sh
```

它完成「起 fmq → 注册主题/订阅组 → 发布 → 消费 ack → 校验」，发布端与消费端都是 fboot 加载的动态库，可用作环境自检。

---

## 八、部署与已知限制

**必配**

```bash
export mqClient_hosts="127.0.0.1:2350"      # 必填：既是客户端节点表，也是服务端集群节点表
export mqServer_port=2350
export mqServer_segmentedLogDir=/data/fmq/segmentedLogs
export mqServer_deadMsgDir=/data/fmq/deadMsgs
```

- `mqClient_hosts` 是**同一份表**给两端用：服务端按 `mqServer_port` 在表里匹配本机下标，端口不在表中或重复出现会启动报错；
- 默认日志目录在 `/var/log/fmq` 下，普通用户先改成可写目录；
- `protocol_hostId` **必填且每台机器唯一**（脚本里默认导出 `1`）：它是 `MessageID` 身份的一部分，配 0 直接抛异常；`(pid, tid, 时间戳)` 跨机器会重复，集群维度只能靠它。

**限制（照抄前先看）**

1. **at-least-once**：未确认消息会重复投递，消费端必须幂等。
2. **无自动故障转移**：备份副本只保证落盘，不自动接管。
3. **段保留边界取所有已注册组持久化位点的最小值**：一个**从未消费过**的组会把边界钉在编号最小的现存段，历史段永远不回收。要回收就删掉那个组，或者接受语义变化后下调 `segmentedLogTTL`。
4. **墓碑 TTL 7d**：节点离线超过这个时间无法增量收敛，要清空该节点 `metas/` 后重启拉全量。
5. **大记录（>4096 字节）要求集群内所有节点升级到同一版本**，旧节点收到大记录会降级成空消息——**发布大消息前先完成滚动升级**。
6. **游标指向的段被 TTL 清理后**，会自动跳到编号更大的最近现存段并落盘（记 WARN），全部段不可读时返回空，不永久报错。
7. **manager 与普通客户端共用 TCP 协议**，没有强身份隔离。生产环境要靠网络层隔离，别把管理端口暴露出去。

---

## 一句话收尾

fmq 把「并行」交给队列，把「进度」交给组游标，把「不丢」交给 ack 与重投，把「清理」交给 TTL 与墓碑，把「恢复」交给备份。

**fmq 不做选主与自动故障转移；消息位置、组游标、死信与备份位点都持久化在盘上，可以查询和恢复。**

---

**同系列**

- [编解码器与应用通讯协议](fountain实现思想与应用第10弹——编解码器与应用通讯协议.md)
- [RPC实现](fountain实现思想与应用第11弹——RPC实现.md)
- [数据库中间件](fountain实现思想与应用第12弹——数据库中间件.md)
- [JSONRPC & MCP](fountain实现思想与应用第14弹——JSONRPC&MCP.md)
