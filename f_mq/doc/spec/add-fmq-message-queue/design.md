# 设计：f_mq 与 fmq

> 依据：`f_mq/doc/详细设计.md`（下称「f_mq 设计」）、`fmq/doc/详细设计.md`（下称「fmq 设计」）、
> 两份同目录 `开发计划.md`。本文是这两份设计的**实现级收敛**：确认依赖现状、固定关键决策、
> 给出可直接落成任务的模块边界与算法。实现细节冲突时以本文 + 源码实测为准。

## 1. 目标与非目标

### 目标

1. `f_mq` 动态库：客户端 API + 客户端/服务端共用协议层，业务侧 `import fountain::f_mq.*` 即可发布订阅。
2. `fmq` 可执行文件：多节点持久化消息服务，支持主题/订阅组管理、组内不重复消费、
   at-least-once、超时重投、死信、TTL 清理、元数据全量复制、可选备份副本。
3. 全部按 TDD 落地：每个公共声明先有失败用例，再有实现；跨进程行为由端到端脚本验收。

### 非目标（本期不做）

- 主从选举、自动故障转移、备份副本的自动接管。
- manager 与普通客户端的强身份隔离（`REGISTER`/`DEREGISTER` 仅靠能力收敛：客户端 API 不提供入口）。
- 任意自定义对象 BODY 的服务端过滤器求值（受 `f_codec` 未知类型解码限制）。
- 死信消费者的产品化界面（只提供 `iterate` 机制）。
- 通配/前缀订阅、消息优先级、延迟消息、事务消息。

## 2. 已核实的事实（本 worktree）

这些事实决定了任务顺序，实现时不得按旧文档假设行动。

| 事实 | 证据 | 影响 |
| --- | --- | --- |
| `LogPosition.seq/offset` 仍是包内可见 | `f_io/src/SegmentedLog.cj:38-46`（`let seq` / `let offset`） | **必须先做可见性放宽**；开发计划 D0 标注「已完成」与实际不符 |
| `SegmentedLog` 已提供位置读写与段元数据 | `append(): LogPosition`（`:178`）、`openEntryStream(index, offset)`（`:308`）、`logMetas()`（`:241`）、`removeById(index)`（`:257`）、`rotate()`（`:213`） | 不自建索引、不扫目录删段 |
| `SegmentedMeta` 字段公开 | `f_io/src/SegmentedLog.cj:82-90`：`index/size/creationTime/updateTime/last` | 清理器直接按 `updateTime` 挑段 |
| 当前段不可删 | `removeById` 对当前段抛 `IllegalArgumentException`（`:259-261`） | 清理器必须先跳过 `last == true` 的段 |
| `openEntryStream` 返回 `InputStream`，接口无 `close` | f_io API | 关流写 `if (let r: Resource <- stream) { r.close() }` |
| 协议命令号 0–15 已占满 | `f_protocol/src/default/constants.cj:116-129` | 不新增命令；用途靠载荷类型区分 |
| `Message` 提供 `build/publish/register/subscribe/resp/error/decode/encode` | `f_protocol/src/default/Message.cj:190-273` | 协议层只做装配，不碰帧格式 |
| `Client.transfer(message, timeout): ?Message`；`Server.start(executor)` | `f_net/src/client/client.cj:262-270`、`f_net/src/server/server.cj:122` | 客户端超时/重试与 executor 形态已定 |
| `f_mq` / `fmq` 只有占位文件 | `f_mq/src/f_mq.cj:16-19`、`fmq/src/main.cj:24-27` | 全部为新增代码 |
| 两模块 `cjpm.toml` 已就绪 | `f_mq`（dynamic）、`fmq`（executable），依赖均已声明 | 无需先改构建配置 |

## 3. 总体架构

```
业务应用 ──import fountain::f_mq.*──> MQClient
                                        │  f_net Client<DataAny> × N
                                        ▼
fmq manager ──REGISTER/DEREGISTER──> ┌──────────────┐
                                     │  fmq server  │  ← 进程内、多节点
                                     │              │
                                     │ MQCommand    │
                                     │  Executor    │
                                     │   ├ MetaSyncer ──> MetaStore(metas/)
                                     │   ├ QueueManager ─> QueueLog(SegmentedLog)
                                     │   ├ ConsumeService ─> GroupCursor ─> CursorStore
                                     │   ├ DeadLetterQueue / LogCleaner
                                     │   └ BackupReplicator ─> peer
                                     └──────────────┘
```

### 3.1 包与依赖

```
fountain::f_mq            （门面，public import）
 ├── base                 ← f_codec / f_data / f_protocol / f_util / f_log
 ├── client               ← base / exception / f_net / f_config / f_time
 └── exception            ← f_base

fountain::fmq
 ├── config               ← f_config / f_util / f_process
 ├── meta                 ← f_mq.base / f_codec / f_data / f_net / f_log
 ├── queue                ← f_io / f_mq.base / f_codec / f_time / f_concurrent
 ├── cluster              ← meta / f_net / f_mq.base
 ├── server               ← config / meta / queue / cluster / f_net / f_protocol
 └── manager              ← f_mq.base / f_net / f_config / f_util
```

约束：`fmq` 不依赖 `f_mq.client`；`manager` 不依赖 `server/meta/queue`，保证管理端可独立编译测试。

### 3.2 线程模型

| 线程 | 归属 | 职责 |
| --- | --- | --- |
| accept | `f_net.Server` | 接受连接 |
| 每连接读 | `f_net.Server` | 解帧、PING→ACK、投递 executor |
| 执行池（默认 200） | `f_net.Server` | `MQCommandExecutor.execute` |
| 每连接写 | `SocketBuffer` | 顺序写帧 |
| 心跳 | `f_net.Client` | 节点间/管理端探活与重连 |
| 清理定时器 | `fmq` | 段 TTL、订阅断链巡检、游标 sweep |
| 备份定时器 | `fmq` | 批量 flush |

共享状态保护：`MetaStore` 用 `Mutex`；`SegmentedLog.append` 自带锁；`SubscriberRegistry` 用 `Mutex` +
两个索引；每个 `GroupCursor` 一个 `Mutex`（组间不互相阻塞）；`QueueManager` 的本地队列表用并发容器 +
轮转计数 `AtomicInt64`。

## 4. 协议层设计

### 4.1 命令映射

| MQ 操作 | Command | 载荷 |
| --- | --- | --- |
| 注册主题 / 订阅组 | `REGISTER` | `MQTopicMeta` / `MQSubscribeGroupMeta` |
| 内部元数据同步 | `REGISTER` | `MQInternalMessage{kind:"metaSync", payload:...}` |
| 注销 | `DEREGISTER` | `MQDeregisterPayload` |
| 发布 / 备份 | `PUBLISH(_)` | 记录字节块 / `MQInternalMessage{kind:"backup"}` |
| 订阅 | `SUBSCRIBE` | `MQSubscribePayload` |
| 退订 | `UNSUBSCRIBE` | `MQUnsubscribePayload` |
| 取消息 | `CONSUME(_)` | `MQConsumePayload` |
| 确认 | `ACK` | `MQAckPayload` |
| 错误 | `ERROR` | `MQResult{code != 0}` |
| 成功响应 | `RESP(_)` | 按请求而定 |

`CONSUME(_)` / `RESP(_)` 的 tag 位由 `f_protocol` 内部生成，MQ 不解释其含义。

### 4.2 记录

```
record = codec(String topic) ‖ codec(Array<String> tags) ‖ codec(String messageId) ‖ codec(BODY)
```

- 四段独立编码、无额外长度前缀；接收侧顺序 `decode` 即可。
- `BODY` 泛型约束 `T <: ToData`；支持基本类型、`Decimal`/`DateTime`/`Duration`、集合与 `@DataAssist` 类。
- `MESSAGE_ID` 与帧 `Message.id` 取同一个值：`Message.build(Command.PUBLISH(0), id, Some(record))`。
- 解码完整性判定：四段全部成功**且** `ByteBuffer.readOffset == record.size`。
  不得依赖「读不满自动归零」（`ByteBuffer.read` 读不满会 `clear()`，会把截断伪装成恰好用尽）。
- 编解码器要 `release()`（`DefaultCodec` 池项归还）。

### 4.3 帧内承载与 `MQBytes`

`Message` 的 data 区只有一个 `Data`；记录以 `Array<Byte>` 原始字节块承载
（`DefaultCodec` 对 `DataCollection<Array<Byte>, Byte>` 走原始字节分支）。

`MQBytes.fromData(data)` 负责把载荷还原为字节：

| 运行时形态 | 处理 |
| --- | --- |
| 字节块（`DataCollection<Array<Byte>, Byte>`） | 直接返回 |
| 临时文件（`DataInputStream` 包 `File`，记录 > 4096 字节时出现） | 读回全部字节，删除文件与父目录 |
| 其它 | 返回 `None` |

**关键**：禁止 `convert<Array<Byte>>` 静默失败成空数组，否则大消息会被误判成「无消息」。

### 4.4 载荷分派

| 运行时类型 | 分派 |
| --- | --- |
| 字节块 | `Record` |
| `SimpleDataObject`，`typeInfo` 为 MQ 载荷类 | 对应载荷 |
| `SimpleDataObject`，`typeInfo = MQInternalMessage` | `Internal`（再按 kind 解子载荷） |
| `DataNone` | `Empty` |
| 其它 | `Unknown` → `ERROR(INTERNAL)` + WARN |

### 4.5 内部消息

`MQInternalMessage{kind: String, payload: Array<Byte>}`，`kind ∈ {"metaSync","backup"}`。
子载荷一律用同一套 `f_codec` 编码为字节：

- `metaSync`：`MQMetaSyncRequest` / `MQMetaSnapshot` / `MQTopicAssignment` / `MQDeregisterPayload`；
- `backup`：`MQBackupPayload`（含 `records` 与 `states`）。

不新增命令的代价是「一条 `REGISTER` 可能是注册，也可能是同步」；收益是不动 `f_protocol` 的
命令空间与 tag 语义，避免与 `f_rpc` 冲突。

### 4.6 错误码

见 `specs/f-mq/protocol/spec.md` 的码表。错误一律 `Message.error(request.id, MQResult)`，
客户端把 `code != 0` 转成 `MQServiceException(code, message)`。

## 5. `f_mq` 设计

### 5.1 包结构

```
f_mq/src/
├── f_mq.cj                       # 门面：public import base/client/exception
├── exception/
│   └── MQException.cj            # 三个异常类
├── base/
│   ├── MQConstants.cj            # MQErrorCode / MQConfigKey / MQInternalKind
│   ├── MQTopic.cj
│   ├── MQFilter.cj
│   ├── MQMessageRecord.cj        # encode/decode/topic/tags/body/messageId + MQBytes
│   ├── MQProtocol.cj
│   ├── model/
│   │   ├── MQTopicMeta.cj
│   │   ├── MQSubscribeGroupMeta.cj
│   │   ├── MQMessage.cj          # 含 get<T>()
│   │   └── MQMessageContent.cj
│   └── payload/
│       ├── MQResult.cj
│       ├── MQTopicAssignment.cj
│       ├── MQSubscribePayload.cj
│       ├── MQUnsubscribePayload.cj
│       ├── MQConsumePayload.cj
│       ├── MQConsumeResult.cj
│       ├── MQAckPayload.cj
│       ├── MQDeregisterPayload.cj
│       ├── MQInternalMessage.cj
│       ├── MQMetaSyncRequest.cj
│       ├── MQMetaSnapshot.cj
│       ├── MQBackupPayload.cj
│       ├── MQBackupState.cj
│       └── MQDeadLetterMessage.cj
└── client/
    ├── MQClientConfig.cj
    ├── MQNodePool.cj
    ├── MQOwnershipCache.cj
    ├── MQSubscription.cj
    └── MQClient.cj
```

### 5.2 消息模型与过滤器

- `MQMessage.get<T>(): ?T where T <: DataFields<T>` 用 `convert<T>`（不是 `DataObject.populate`，
  后者只支持 `@DataAssist` 类、取不了标量）；类型不匹配返回 `None`，不抛异常。
- `MQFilter` 规则：空串 → 真；否则 `DataPath.cache(path).get(body)` 取首元素：无元素 → 假，
  `DataBool(b)` → `b`，`DataNone` → 假，其它 → 真。表达式非法在 `compile` 抛异常。
  `DataPath.cache` 自带缓存，服务端对每个订阅编译一次即可。

### 5.3 客户端状态

```
MQClient
 ├ hosts: Array<String>               节点表（下标 = 顺序）
 ├ pool: MQNodePool                   懒建 Client<DataAny>，每节点一条
 ├ ownership: MQOwnershipCache        topic → owners（TTL 1 分钟）
 ├ subscriptions: ConcurrentHashMap<String, MQSubscription>
 └ closed 标记 + closeLock
```

`MQSubscription`：`subscribedId/topic/group/tags/filter/autoAck/owners/cursor` +
`deliveries: ConcurrentHashMap<(Int64,Int64), Int64>`（位置 → 投递节点）。

连接参数：`queueSize=1024`、`socketCount=1`、`checkDuration=30s`、`checker={=> Message.ping()}`；
心跳、重连、失败容忍全部复用 `f_net`，MQ 不重复实现。

### 5.4 发布

```
1. 校验 topic（本地）与 tags
2. messageId = MessageID().toString()
3. record = MQMessageRecord.encode(topic, tags, messageId, body)
4. 候选节点 = ownership.ownersOf(topic) 中可用者，否则按序全部节点
5. 对每个候选：
     msg = Message.build(Command.PUBLISH(0), MessageID(), Some(record))
     resp = client.transfer(msg, publishTimeout=5s)
     - RESP + MQResult(0)      → 成功
     - ERROR + NOT_OWNER       → 从候选移除，继续
     - ERROR + TOPIC_NOT_EXIST → MQServiceException(1)
     - 超时/连接异常            → 继续
6. 全部失败 → MQConnectionException
```

### 5.5 订阅

1. `subscribedId = UUID.random().toString()`；
2. 本地编译 filter（失败即抛，不发请求）；
3. 向**所有**节点发 `SUBSCRIBE`，收集 `MQResult(0)` 的节点为 owners；
4. `GROUP_NOT_EXIST` / `TOPIC_NOT_EXIST` → 向已接受节点补发 `UNSUBSCRIBE` 回滚，抛
   `MQServiceException`；
5. owners 为空 → `MQConnectionException`；否则写入订阅表与所有权缓存。

### 5.6 消费与确认

```
consume(id):
  sub = subscriptions[id] ?: throw MQServiceException(SUBSCRIBE_NOT_EXIST)
  loop:
    for owner in rotate(sub.owners, sub.cursor):
      r = transfer(CONSUME(sub.id), 1s)
      if ERROR(SUBSCRIBE_NOT_EXIST) → throw
      if r.record 非空:
         content = MQMessageRecord.decode(r.record) ?: continue
         if !autoAck: deliveries[(r.index, r.offset)] = owner
         return content.toMessage(r.index, r.offset)
    sleep(200ms)     // 阻塞语义
```

`ack`：先在 `deliveries` 里 `remove` 得到投递节点（命中即删，保证同一位置只被一个线程认领）；
未命中则向所有 owners 广播并忽略 `ACK_UNKNOWN`。`autoAck=true` 不写 `deliveries`。

### 5.7 生命周期

`close()` 幂等：置关闭标记 → `pool.close()`（`f_net.Client.close()` 幂等）→ 清空订阅表。
关闭后任何 API 在入口检查并抛 `MQConnectionException`。

## 6. `fmq` 设计

### 6.1 配置

`MQConfig` 为 `protected struct`（兄弟包可见），全部属性为「首次使用时读配置」的静态属性。
`segmentedLogMaxSize` 用 `f_util.computeBytes`，非法格式要显式兜底（该函数抛
`IllegalArgumentException`，不是返回 `None`）。

启动校验（失败打印原因、退出码 2）：
`backup >= 0`、`nodes` 非空、`selfIndex` 可定位且端口唯一、`deadMsgThreshold >= 1`。

### 6.2 目录布局

```
<exeDir>/metas/
├── assign.meta                                  # codec(nextStartNode)
├── topics/<topicEsc>.meta                       # codec(MQTopicAssignment)
├── groups/<topicEsc>/<groupEsc>.meta            # codec(MQSubscribeGroupMeta)
└── offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor

<segmentedLogDir>/<topicEsc>/<queueIndex>/log_<seq>.log
<segmentedLogDir>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/log_<seq>.log
<deadMsgDir>/log_<seq>.log
```

`<topicEsc>` 为百分号编码（保留 `[A-Za-z0-9._-]`，空串 → `%00`）。
所有元数据写入走「`.tmp` + rename」。

### 6.3 分配

```
allocate(topic, queueNum, nodeCount, start):
  owners[i] = (start + i) % nodeCount
  return MQTopicAssignment{topic, queueNum, startNodeIndex: start, owners}
nextStart(start, queueNum, nodeCount) = (start + queueNum) % nodeCount
```

规格例子（3 节点、4 队列、start=0 → `[0,1,2,0]`、next=1；2 队列、start=1 → `[1,2]`）作为首个用例。

### 6.4 元数据存储与同步

`MetaStore`：内存索引（`topics: HashMap<String, MQTopicAssignment>`、`groups: HashMap<String,
Array<MQSubscribeGroupMeta>>`、`nextStart`）+ `Mutex` + 原子落盘。加载时坏文件记 ERROR 并跳过。

`MetaSyncer` 流程：

```
registerTopic(meta):
  if !MQTopic.isValid → ERROR(INVALID_TOPIC)
  if queueNum < 1 → ERROR(INVALID_TOPIC)
  if store.topicOf(topic) != None → ERROR(TOPIC_ALREADY_EXIST)
  assignment = MQAssignment.allocate(topic, queueNum, registry.nodeCount, store.nextStartNode)
  store.applyTopic(assignment)        // 内部把 assign.meta 推进为 MQAssignment.nextStart(...)
  queues.openTopic(assignment, self)
  broadcast(metaSync, codec(assignment))       // 幂等，失败只记 WARN
  return assignment
```

幂等与防环：

- 收到 `metaSync` 且载荷为 `MQTopicAssignment` → `applyRemote`：已存在且 owners/queueNum 完全一致 →
  `duplicated`，**不广播**；不一致 → `conflict` + WARN，保留先到者。
- 广播失败的 peer 在它恢复时由 `syncFromPeers()` 补齐（全量快照合并）。

### 6.5 队列与读取

`QueueLog` 只包一层 `SegmentedLog`：

| 方法 | 实现 |
| --- | --- |
| `append(record)` | `log.append(record)`，直接返回位置 |
| `openFrom(pos)` | `log.openEntryStream(pos.seq, pos.offset)` |
| `readAt(pos)` | 开流 → 解一条 → 关流 |
| `segments()` | `log.logMetas()` |
| `size` | Σ `meta.size` |

`QueueManager` 维护 `topic → Array<QueueLog>`（只含本机 owner 的队列），`pickQueue` 用
`AtomicInt64` 在本地队列上轮转。`closeTopic(topic, deleteFiles)` 先关日志，再按需删目录。

### 6.6 游标算法（核心）

每个 `(topic, queueIndex, group)` 一个 `GroupCursor`：

```
committed    : LogPosition                 已连续确认的前缀位置（落盘）
scanPosition : LogPosition                 已扫描位置（初始 = committed）
entries      : TreeMap<(Int64,Int64), DeliveryRecord>
```

`next(subscription, matcher)`：

1. **重投/已分配**：按位置顺序找第一条：
   - 未确认；
   - `target == None` 或 `target == sub.id`；
   - `delivered == false`（已分配未取走，无需复检 filter）或 `now - lastDeliverTime >= ackTimeout`；
   - 与订阅匹配（tags/filter）；
   → 命中：`deliverCount++`、`lastDeliverTime = now`、`delivered = true`、`target = None`，
     返回记录；若 `deliverCount > deadMsgThreshold` → 写死信、标记已决、继续找下一条。
   → `autoAck` 时不建 `entries` 项，直接视为已确认。
2. **扫描新消息**：从 `scanPosition` 开流逐条解码（读尽后用最新位置重开）：
   - 匹配本订阅 → 建 `DeliveryRecord{target: None, delivered: true, deliverCount: 1}` 并返回；
   - 匹配组内其它活跃订阅 → 建 `{target: 其它, delivered: false, deliverCount: 0}`，继续扫描；
   - 都不匹配 → 记「不适用」（已决），继续扫描；
   - 流尽 → `None`。
3. **推进 committed**：从 `committed` 起吞并连续已决位置，每前进一步写 `CursorStore`。
4. 定时 `sweep`：清理已消失订阅的 `target`（置 `None`）；组内无匹配者时保留未决，
   **阻塞该组推进**（不丢消息）。

`ack(subId, pos)`：`entries` 无该位置 → `false`（`ACK_UNKNOWN`）；该位置已分配给别的订阅且已投递 →
`false`；否则删除项、标记已确认、推进 `committed`。乱序确认只留洞，不做「按最大位置推进」。

重启：`entries`/`scanPosition` 均为内存态，重建后从 `committed` 重扫 ⇒ at-least-once。

位置失效：`committed` 所在段被 TTL 删除后，`openEntryStream` 抛 `IllegalArgumentException`
⇒ 记 WARN，跳到现存最老段继续（等价「保留期短于消费滞后」时丢消息；清理器的「无游标引用才删」
把该窗口降到最小）。

### 6.7 死信与清理

- 死信条目 `MQDeadLetterMessage` 自描述（含原记录与来源上下文），按组隔离。
- `LogCleaner.cleanOnce(now)`：对每个队列/死信队列，挑
  `meta.updateTime + ttl < now && !meta.last && 无游标 references(index)` 的段，`removeById(index)`；
  返回删除段数。定时 5 分钟。当前段双重保护（`!last` + f_io 自身拒绝）。

### 6.8 集群与备份

`NodeRegistry`：节点表、`selfIndex`、懒建 `Client<DataAny>`（自身返回 `None`）、
`successors(count)` 环形后继、`markSeen/isAlive`（由最近一次调用结果与心跳共同判断）。
「由死转活」触发一次 `syncFromPeers()`。

`BackupReplicator`：

```
record(topic, queueIndex, position, bytes) → 入有界队列（8192），满则 WARN 丢弃
flush: 每 100ms 或累积 64 条 → 按 position 分组，发 MQProtocol.publishBackup 给每个后继
```

接收方写入 `backup/<ownerIndex>/...`，只落盘，不投递、不再备份。

### 6.9 服务装配

```
MQConfig 校验 → 建目录 → MetaStore.load()
 → NodeRegistry → MetaSyncer.syncFromPeers()
 → QueueManager.openTopic(每个本机主题)
 → DeadLetterQueue / SubscriberRegistry / MQMatcher / ConsumeService
 → BackupReplicator.start()（backup>0）/ LogCleaner.start()
 → Server<DataAny>(bindAt=port, checkDuration=30s, executors=200, checker=ping)
 → spawn { server.start(executor.execute) }，阻塞等待关闭
关闭：Server.close() → 定时器 close → QueueLog.sync/close → 游标落盘 → NodeRegistry.close()
```

`MQCommandExecutor.execute` 只做「解析 → 校验 → 调服务 → 组装响应」；
任何异常转 `ERROR(INTERNAL)` 并记日志，不向 `f_net` 抛。

### 6.10 管理端

`MQManagerArgs.parse` 支持 `--server` 前置/后置；缺省读 `mqServer_port` 组装
`127.0.0.1:<port>`。六个子命令各自「建连 → 单次请求 → 解析 → 渲染 → 关闭」。
`listTopics` / `listSubscribeGroups` 用 `metaSync` 请求取 `MQMetaSnapshot`，本地过滤与渲染。
连接失败/配置缺失统一打印「无法连接消息队列服务」并返回 1。

## 7. 关键决策

| 编号 | 决策 | 备选与取舍 |
| --- | --- | --- |
| R1 | 先放宽 `LogPosition` 可见性，再写任何 MQ 代码 | 备选「用 `logMetas()` 反推位置」：脆弱、需要扫目录、且拿不到精确 offset；已被 f_io 新 API 取代 |
| R2 | 不新增协议命令，用途靠载荷类型区分 | 备选「扩展 `Command` 枚举」：会改动 `f_protocol` 的编号分配与 tag 语义，影响 `f_rpc` |
| R3 | 记录以原始字节块承载，`MQBytes` 统一还原 | 备选「元素级编码」：会拆解并重组记录，违背「原样落盘」，且大消息易丢 |
| R4 | `consume` 客户端阻塞轮询，服务端单次立即返回 | 备选「服务端长轮询挂起」：占用执行线程、增加超时与取消复杂度 |
| R5 | `subscribedId` 由客户端生成 | 服务端生成需要「先建后告知」，多 owner 场景要多一轮广播 |
| R6 | 游标 `entries` 只在内存，`committed` 落盘 | 备选「在飞状态也落盘」：写放大且无必要；at-least-once 已满足不丢 |
| R7 | 乱序 ack 留洞，只推进连续前缀 | 备选「按最大位置推进」：会产生永久空洞（旧实现的坑） |
| R8 | 元数据冲突「先到者优先 + WARN」 | 强一致需版本号/共识，超出本期；单点运维变更已足够 |
| R9 | TTL 清理「挑段 + `removeById`」，不用批量删 | 批量 `removeUpdatedBefore` 无法排除慢游标引用 |
| R10 | 服务器节点表复用 `mqClient_hosts`，按端口定位自身 | 新增 `mqServer_nodes` 会与规格冲突，且客户端/服务端节点表必须一致 |
| R11 | `syncInterval = 1`（每条 fsync） | 规格无此配置项；消息队列优先不丢已确认数据，需要时再补配置 |
| R12 | 对象 BODY + 非空 filter → `FILTER_UNSUPPORTED_BODY` | 备选「按未知类型直接不投递」：会静默丢消息；备选「扩展 `f_codec`」：本期范围外 |

## 8. 失败与一致性语义

| 场景 | 行为 |
| --- | --- |
| 发布时节点不可达 | 客户端换节点；全失败抛 `MQConnectionException` |
| 发布到非 owner | `NOT_OWNER` + 客户端修正缓存重试 |
| 服务端崩溃（已确认消息） | 已 fsync；重启后仍可读 |
| 服务端崩溃（未确认消息） | 从 `committed` 重扫，重复投递（at-least-once） |
| ack 丢失 | 超时重投，可能重复；`deliverCount` 累加 |
| ack 超阈值 | 进死信，不阻塞其它消息 |
| 元数据广播失败 | 本地已落盘；peer 恢复后启动同步补齐 |
| 元数据冲突 | 保留先到者 + WARN |
| 段被 TTL 删除而游标仍指旧段 | 记 WARN，跳到最老现存段（可能丢该段消息） |
| 备份队列满 | 丢弃副本 + WARN，不阻塞发布 |
| 大消息（>4096B） | `MQBytes` 走临时文件读回并清理 |

## 9. 测试策略

### 层次

1. **纯函数/模型单测**（`f_mq`）：记录编解码、过滤器、主题校验、分配、文件名字、协议工厂。
2. **组件单测**（`fmq`）：`QueueLog`/`QueueManager`/`CursorStore`/`GroupCursor`/`MetaStore` 等
   全部通过构造函数注入依赖，不碰套接字；文件用例统一用 `/tmp/fmq_test_<name>/` 并在用例前后清理。
3. **进程内集成**：`f_mq` 客户端对桩服务端（`f_net.Server<DataAny>` + 预设响应）；
   `fmq` 命令执行器对桩 `SocketBuffer` 或真实 `Server`。
4. **跨进程端到端**：3 个 `fmq server` + `fmq manager` + 客户端程序，脚本判定 `E2E_OK`。

### 约定

- 时间相关（`ackTimeout`、TTL、备份 flush）一律注入时钟，不用 `sleep` 等真实时间。
- 断言位置时统一走辅助函数（`assertPositionReadable`），避免两套写法。
- 大记录用例必须覆盖 16KB（跨过 4096 阈值），防止「临时文件 → 空数组」回归。
- 并发用例固定线程数（如 4×50/4×500），断言总数、无重复位置、`committed` 单调。

## 10. 风险与待定项

| 风险/待定 | 本期处理 |
| --- | --- |
| `fmq` 是 executable，`cjpm test` 支持情况需先验证 | 计划第 0 阶段做 5 分钟可行性验证；不可用则加 `fmq_test` 测试模块或把纯逻辑下沉到子包 |
| `f_io` 可见性改动与主分支不一致（文档称已完成） | 以本 worktree 为准，先改 + 跑 `f_io` 全量回归 |
| `f_protocol` 命令 tag 语义变化 | 设计只用命令主类型，不解释 tag；升级时复核 §4.1 |
| 大消息临时文件目录清理 | `MQBytes` 读回后删除文件与父目录；失败只记 WARN，不 fail 请求 |
| 元数据并发注册 | 先到者优先；文档明确「同一时刻只对一个节点做变更」的运维约定 |
| 位置失效导致丢消息 | 清理器「无游标引用才删」；文档提示 TTL 应大于最慢组滞后 |
| `f_net` 客户端 `transfer` 超时语义 | 统一 `publish=5s`、`consume=1s`，超时按节点失败处理 |

## 11. 交付顺序

```
P0 f_io 可见性 ──> P1 f_mq base/exception ──> P2 f_mq client
                          │
                          ├──> P3 fmq 基础设施（文件名/配置/用法）
                          ├──> P4 fmq 存储
                          ├──> P5 fmq 消费语义
                          ├──> P6 fmq 元数据与集群
                          └──> P7 fmq 服务运行时 ──> P8 fmq 管理端 ──> P9 E2E/文档
```

P2 与 P3–P6 可并行（`fmq` 只依赖 `f_mq.base`）；P7 起需要 `f_mq.client` 做节点互连与端到端。

## 12. 验收

1. 三个模块测试全绿（`f_io`、`f_mq`、`fmq`）。
2. `scripts/mq_e2e.sh` 输出 `E2E_OK`，覆盖 proposal「成功判据」四条。
3. 文档与元数据更新完成：`f_mq`/`fmq` 的中英文 README、根 README 模块表、`CHANGELOG`、
   `.modules`、依赖图重新生成。
4. 所有新增公共 API 有对应用例；`fmq` 的纯逻辑无套接字依赖。

## 13. verify 修复设计（2026-10-18）

> 本节是 `opsx:verify` 发现问题的实现级修订，优先级高于前文对应段落；不改已完成的 70 项任务，
> 新增阶段 10 承载以下修复。详见 `verify-report.md`。

### 13.1 C1：ACK 链路加入队列身份

- `MQConsumeResult` 增加 `queueIndex: Int64`（与 `segmentedIndex`/`segmentedOffset`/`record` 同级）。
- `MQAckPayload` 增加 `queueIndex: Int64`；`MQMessage` 增加 `queueIndex: Int64`，`toMessage` 填入。
- 客户端 `MQSubscription.deliveries` 的键从 `"index:offset"` 改为 `"queueIndex:index:offset"`；
  `ack` 发送 `MQAckPayload(subscribedId, queueIndex, segmentedIndex, segmentedOffset)`。
- `ConsumeService.consume` 返回 `queueIndex`；`ack` 直接按 `(topic, queueIndex, group)` 取游标，
  不再遍历本机队列「命中第一个即返回」。`queueIndex` 不在本机队列集合 → `ACK_UNKNOWN`。
- 协议兼容性：字段是新增的，编解码自描述；服务端与客户端必须同版本部署（本期无旧客户端兼容要求）。

### 13.2 C2：filter 三态与 `FILTER_UNSUPPORTED_BODY`

- `MQMatcher` 返回 `MQMatchResult { Match, NoMatch, Unsupported }`：
  - topic/tags 不匹配 → `NoMatch`；
  - 非空 filter 且 BODY 解码结果为 `None`（未注册对象/损坏）→ `Unsupported`；
  - 其余按现有规则 → `Match`/`NoMatch`。
- `GroupCursor`：`Unsupported` 的记录 MUST NOT 标记 `decided`、MUST NOT 推进 `committed`；返回 `None`
  让调用方稍后重试（组内无人能评估时暂停该组，而不是丢消息）。
- 发布路径（`MQCommandExecutor.onPublish`）：在 `append` 前扫描该主题下所有活跃订阅；若任一订阅的
  filter 非空且该记录的 BODY 无法评估，直接回 `FILTER_UNSUPPORTED_BODY`，不落盘、不入备份队列。
  没有任何活跃订阅或 filter 全空时，照常发布（BODY 不需要服务端解码）。
- 该检查只针对「有非空 filter 的活跃订阅」，避免对普通纯字节消息强制解码 BODY。

### 13.3 C3：游标段失效恢复

- `GroupCursor` 的 `openRecordsFrom` / `readAt` 捕获段失效（`IllegalArgumentException`）：
  1. 关闭当前 reader；
  2. `log.segments()` 取最老现存段（列表第一个；空列表 → 返回 `None`，不报错）；
  3. `committed_ = LogPosition(oldest.index, 0)`，`scanPosition = committed_`，`CursorStore.save`；
  4. 记 WARN（含旧位置、新位置、组/队列），继续本轮扫描。
- `advance()` 与重投路径的 `readAt` 同样走该恢复逻辑；恢复后不得重复推进已越过的新段前缀。

### 13.4 W1：死转活触发重同步

- `NodeRegistry` 增加 `onRevived: ?(() -> Unit)`（构造参数或 setter）；`markSeen(index)` 记录
  `wasAlive`，在 `false → true` 时调用一次回调。
- `MQServer` 装配时把回调接到 `MetaSyncer.syncFromPeers()`；回调内部异常只记 WARN，不影响心跳线程。

### 13.5 W2：节点表端口唯一性

- `MQConfig.validate()` 先遍历 `nodes` 解析所有端口，任意重复即抛 `MQConfigException`
  （不再只检查「重复端口是否等于本机端口」）；随后再做 `selfIndex` 定位。
- `helpText` 不变。

### 13.6 W3：BackupStore 并发安全

- `BackupStore` 用 `Mutex` 保护 `logs` 的 get-or-create；创建 `QueueLog` 的过程在锁内完成，
  避免同一 `(ownerIndex, topic, queueIndex)` 生成两个实例。
- 写入仍按 `QueueLog.append` 自身锁串行；锁外只做已存在实例的 append。

### 13.7 测试与验收增量

- 新增用例：协议四字段往返、两队列同位置 ACK 不串台、客户端 deliveries 键含 queueIndex、
  filter 三态、发布 `FILTER_UNSUPPORTED_BODY`、段删除后恢复、死转活回调、任意端口重复、备份并发。
- 回归：`f_io` / `f_mq` / `fmq` 全量 + `scripts/mq_e2e.sh` 的 `E2E_OK`。
- E2E 增加两队列同位置场景（可在现有 4 队列拓扑上断言 ACK 后无重复投递/无丢失）。
