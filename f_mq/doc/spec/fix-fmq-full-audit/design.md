# 设计：fmq / f_mq 全量审查修复

> 依据：`reviews/202610210648_fmq-f_mq-full-audit/todo.md`（R1–R6，75 项，11 严重）。
> 本文固定每个严重问题的落点、算法、兼容边界与用例断言；一般问题按 capability 归并。
> 实现细节与源码冲突时以源码实测为准，但**不得改变**本文规定的对外语义与兼容约束。

## 1. 目标与非目标

### 目标

1. 大记录（>4096 字节）在消费响应、内部信封、备份、死信中都能无损往返，且临时文件必被清理。
2. 记录时间戳只有一个时区语义：UTC；跨时区部署的延迟与滞后统计不再漂移。
3. 客户端连接可自愈；连接失败、服务错误、空响应三者可区分；失败不再静默。
4. 元数据删除可传播、可收敛；同一节点内的注册是原子的；远端畸形数据不落盘。
5. 备份携带真实消费状态、发送不阻塞发布、失败可重试、接收端落位点、存储可清理。
6. 段 TTL 以持久化游标为保留边界；损坏记录不会触发 GB 级分配。
7. 不可评估 BODY 有有界出口，不再让整组永久停摆。
8. 生产入口有退出钩子，关闭全链路可达、可容错、可重试。
9. 规格、设计文档、README、任务台账与实现一致，并有可 grep 的验收点。

### 非目标

- 不引入新的 `f_protocol` 命令号；不改段文件、`.meta`、`.cursor` 的二进制格式。
- 不做跨节点事务、自动故障转移、备份自动接管、跨机房复制。
- 不重构 `f_io.SegmentedLog` 与 `f_codec.DefaultCodec` 的存储/编码实现。
- 不把备份恢复做成 CLI 子命令（本变更只保证「数据足以恢复」）。

## 2. 基线事实（读源码确认）

| 事实 | 位置 | 影响 |
|---|---|---|
| `DefaultCodec` 对 `INPUTSTREAM` 且 `size > fileThreshold(4096)` 返回 `DataInputStream(File)` | `f_codec/src/default/DefaultCodec.cj:950-1030` | 大字节字段走文件形态 |
| 对象字段由 `MutableField` 的 setter 用 `convert<F>(data, SILENCE)` 转换 | `f_data/src/base/MutableField.cj:54-71` | 转换失败静默保留默认值 |
| `Array<T>.tryFromData` 对 `DataInputStream` 落到 `case _`，返回空数组 | `f_data/src/base/CollectionData.cj:79-97` | 大 `record`/`payload` 变 `[]` |
| 对象类型特征只取 `typeInfo.qualifiedName` | `f_codec/src/default/DefaultCodec.cj:78,921-938` | 字段类型变化不改变线格式 |
| `MessageID.toString()` 用 `time.format(...)` | `f_protocol/src/default/MessageID.cj:39-41` | 时区随 `DateTime` 实例 |
| `MQClient.publish` 显式用 `DateTime.nowUTC()` 构造 id | `f_mq/src/client/MQClient.cj:73-75` | 主路径正确，其它构造点仍可产生本地时间 id |
| `MetaStore` 无版本/墓碑，`mergeSnapshot` 只补缺 | `fmq/src/meta/MetaStore.cj:135-240`、`MetaSyncer.cj:145-159` | 删除不传播 |
| `BackupReplicator.record` 在临界区外同步 `flush()` | `fmq/src/cluster/BackupReplicator.cj:65-125` | 发布被 RPC 阻塞 |
| `ConsumeService.references` 只遍历内存游标 | `fmq/src/server/ConsumeService.cj:201-214` | 离线组位点被忽略 |
| 读端只判 `length <= 0`，随后按长度分配 | `fmq/src/queue/QueueLog.cj:201-206,241-262` | 损坏头触发大分配 |
| `GroupCursor` 对 `Unsupported` 直接 `return None` 且不推进 | `fmq/src/queue/GroupCursor.cj:243-276` | 组永久停摆 |
| 生产入口无 `ExitCallbacks`，`run()` 只轮询 `closed` | `fmq/src/main.cj:71-83`、`MQServer.cj:121-127` | `close()` 不可达 |

## 3. 严重问题技术方案

### 3.1 A01：大载荷字节字段（>4096 字节）

**根因**：大字节字段在 `DefaultCodec` 解码阶段变成 `DataInputStream(File)`；对象字段的 setter 用
`convert<Array<Byte>>(SILENCE)`，`Array<T>.tryFromData` 对 `DataInputStream` 进入 `case _`，
返回空数组。对象已经构造完成，之后再调用 `MQProtocol.asPayload` 已无法找回原始流。

**方案**：在 `f_mq.base` 新增 `MQBlob`（`DataFields<MQBlob>`），替换承载记录的字节字段类型：

```
public class MQBlob {
    private var bytes: Array<Byte>
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any
    public static func fromData(data: Data): ?Array<Byte>   // 与 MQBytes.fromData 合并为同一实现
    public func toData(): Data            // DataCollection<Array<Byte>, Byte>
    public func size(): Int64
    public func isEmpty(): Bool
    public func copyBytes(): Array<Byte>
}
```

`tryFromData` 的支持矩阵：

| 输入 | 结果 |
|---|---|
| `DataAny` | 解包后重试 |
| `DataCollection<Array<Byte>, Byte>` | 直接取字节 |
| `DataInputStream(File)` | `seek(0)` → 读满 `info.size` → `close` → 删除文件与父目录 → 字节 |
| `DataInputStream(非 File)` | `None<MQBlob>`（不可静默降级） |
| `DataNone` | 空 `MQBlob` |
| 其它 | `None<MQBlob>` |

替换范围：`MQConsumeResult.record`、`MQInternalMessage.payload`、`MQBackupPayload.records`、
`MQDeadLetterMessage.record`。构造签名保留 `Array<Byte>` 重载，读取处改用 `.copyBytes()` / `.size()`。

**线格式兼容性**：`MQBlob.toData()` 返回与 `Array<Byte>.toData()` 完全相同的
`DataCollection<Array<Byte>, Byte>`；对象类型特征只由类全名决定，字段类型不参与。因此：

- 新编码 → 旧解码：旧类字段仍为 `Array<Byte>`，收到 `DataCollection` 正常还原（≤4096 时）；
- 旧编码 → 新解码：`MQBlob` 收到 `DataCollection` 或 `DataInputStream` 都能还原；
- 需要**全量升级**才能解决「旧节点收到 >4096」的场景（旧节点的缺陷仍在）。

**解码失败语义**：`MQProtocol.decodePayload` / `asPayload` 改用严格转换（见 §4.1）；`MQBlob` 无法
还原时返回 `None`，严格转换抛 `DataException`，上层返回协议错误。`asConsumeResult` 仅在
「载荷类型正确且 `record.isEmpty()`」时表示「无消息」，MUST NOT 把解码失败折叠为空消息。

**临时文件清理**：读取成功后先 `close` 再删文件、再删父目录；任一步失败只记 WARN，不影响返回值。
删除是幂等的；同一 `DataInputStream(File)` 被重复读取时第二次读不到内容（不保证可重放），
MQ 协议不会对同一帧解码两次。

**边界**：`size == 4096` 走内存形态；`4097` 走文件；`64 MiB` 为上限（写入侧既有约束）；
`size == 0` 返回空 `MQBlob`；文件被外部删除时 `tryFromData` 返回 `None`。

**用例**：4096/4097/16KB/1MB 四档；三种载荷（消费、内部备份、死信）往返；解码后
`/tmp/tmpFile*` 不残留；旧字节 → 新类型、新字节 → 旧类型的双向 golden 用例；失败不产生空消息。

### 3.2 A02：发布时间统一 UTC

**根因**：`MessageID.toString()` 直接格式化 `time`；`DateTime.now()` 是本地时区实例。
`publishTime` 按「数字是 UTC」解析，二者只在 UTC 时区一致。

**方案**：

1. `MessageID.toString()` 改为：
   `DateTime.fromUnixTimeStamp(time.toUnixTimeStamp()).format("yyyyMMddHHmmssSSS")`。
   `fromUnixTimeStamp` 返回 UTC 实例，格式化结果与进程时区无关。
2. `MQMessageRecord.publishTime` 的解析公式保留（数字按 UTC 解释），补文档与用例。
3. 容错：`publishTime` 结果晚于 `now + 5min` 时，延迟判定按「已到期」处理并记 WARN；
   `lagMs` 计算为负时取 0。用于吸收滚动升级前由本地时区生成的旧 id。
4. 不在协议里加时区字段：id 是 23 位定长数字，加后缀会破坏既有解析与长度校验。

**兼容性**：新 id 在所有时区一致。旧 id 若由 `+08:00` 生产，会被解释为「未来 8 小时」→ 容错规则使
其立即投递（延迟消息提前，最多一个偏移）；若由负偏移生产，会被解释为过去 → 最多晚一个偏移。
影响范围仅限升级前已落盘的消息，默认 72h TTL 会自然淘汰。文档在已知限制中说明。

**用例**：固定 UTC 时刻构造 id，断言 23 位等于 UTC 墙钟；在 `Asia/Shanghai` 下用本地 `DateTime.parse`
构造同一绝对时刻，断言输出与 UTC 一致；`publishTime` 未来 8 小时 → 记 WARN、`isDue == true`、
`lagMs == 0`；`mid-1` 仍返回 `None`。

### 3.3 A11：客户端连接自愈与建连隔离

**根因**：`MQNodePool.clients[i]` 只在首次创建时写入；命中 `isClosed()` 直接抛错且不清空；
建连在池级 `Mutex` 内同步完成。

**方案**：

- 数据结构改为每节点一个槽位 + 每节点一把锁：
  `slots: Array<?Client<DataAny>>`、`nodeLocks: Array<Mutex>`、`retryAt: Array<Int64>`、
  `failures: Array<Int64>`。
- `clientOf(i)`：
  1. 池已关闭 → 抛 `MQConnectionException`；
  2. 取 `nodeLocks[i]`；
  3. 槽位存在且 `!isClosed()` → 返回；
  4. 槽位存在但已关闭 → `close()` 容错、置 `None`；
  5. 若 `now < retryAt[i]` → 立即抛错（快速失败）；
  6. 在**仅持有节点锁**的情况下 `build()`；成功则写槽位、清零失败计数；
  7. 失败则 `failures++`，`retryAt = now + min(5s, 200ms * 2^(failures-1))`，抛错。
- `aliveNodes()` 返回所有下标（池未关闭时），让发布/消费在节点恢复后能再次尝试；
  `close()` 逐节点取锁后关闭并清槽，避免与建连竞态。
- 测试注入 `clientBuilder`（包内构造参数，默认真实 `Client.builder`），用「已关闭的假 Client」
  驱动重建，不依赖真实网络与端口。

**边界**：并发首次建连只建一条；一个节点建连超时不持有全局锁；关闭后不重建；退避上限 5s。

### 3.4 A25：元数据版本、墓碑与删除收敛

**数据模型**：

- `MQTopicAssignment` / `MQSubscribeGroupMeta` 新增 `revision: Int64 = 0`、`origin: Int64 = 0`。
- 新增 `MQMetaTombstone{kind: "topic"|"group", topic, subscribeGroup, revision, origin, deletedAtMs}`。
- `MQMetaSnapshot` 新增 `tombstones: Array<MQMetaTombstone>`、`revision: Int64`（快照生成时的最大
  revision）、`tombstoneFloor: Int64`（仍保留的最小墓碑 revision）。
- `MetaStore` 新增 `metas/revision.meta`（本节点已发出的最大 revision）与
  `metas/tombstones/*.meta`。

**revision 生成**：持久化 Lamport 计数器。`nextRevision() = max(revision.meta, 所有已加载条目的
最大 revision, 所有墓碑的最大 revision) + 1`，写回 `revision.meta`。不使用墙钟，避免时钟回拨。

**比较规则**：

```
remote > local  ⇔ remote.revision > local.revision
               ∨ (remote.revision == local.revision ∧ remote.origin > local.origin)
```

同 revision 同 origin 且内容不同：保留本地，记 WARN（不应发生，用于暴露实现缺陷）。

**删除**：

1. `nextRevision()`；
2. 原子写主题墓碑（组删除写组墓碑）；
3. 写盘删除主题文件 / 组文件（顺序见 §4.4）；
4. 广播墓碑；
5. 返回成功。

**合并**（广播、启动快照、反熵共用）：

- 先按 revision 应用快照中的主题、组、墓碑；
- 对本地存在、快照中不存在、且 `local.revision <= snapshot.revision` 的条目，视为已删除并移除
  （墓碑被 GC 后的兜底）；
- `nextStartNode = max(local, snapshot.nextStartNode)`，永不回退；
- 任一应用落地 `Applied` 后触发 `onTopicApplied(topic)`，由 `MQServer` 打开本机队列。

**墓碑 GC**：`mqServer_tombstoneTTL`（默认 7d）。仅当 `now - deletedAtMs > ttl` 才删除；
若同 key 已有更高 revision 的活跃元数据，可提前删除（已被复活覆盖）。

**升级**：旧数据无 revision → 加载为 `0/0`；首次本地变更从 `revision.meta` 起步（不存在时取
全体最大 +1）。旧节点不认识墓碑字段，滚动升级窗口内的删除由升级后的反熵补齐（墓碑仍在 TTL 内）。

**边界**：删除与重新注册竞争（高 revision 胜）；节点离线超过 TTL（文档要求全量重建）；
墓碑与活跃条目同 key（活跃优先）；单节点（墓碑无 peer，仍写盘以便未来扩容）。

### 3.5 A26 / A27 / A30 / A38 / A66：备份异步、真实状态与可清理

**载荷**：

- `MQBackupState{segmentedIndex, segmentedOffset, deliverCount, acked}`（沿用现有字段，语义修正）。
- `MQBackupPayload` 新增 `cursors: Array<MQBackupCursor{group, segmentedIndex, segmentedOffset}>`。
- 生产端在 **flush 时**读取每个组的 `committed`（来自 `ConsumeService`/`MetaStore`），
  `acked = position < committed`；`deliverCount` 取游标中该位置的投递次数（无则 0）。

**异步发送**：

- `record()` 只做「容量检查 + 入队 + 记录入队时间」，**不调用 `flush()`**。
- 独立工作线程循环：等待 `pending.size >= 64` 或最早入队时间超过 100ms（10ms 轮询 + 条件判断），
  在锁内取走整批，锁外发送。
- 发送按 `(topic, queueIndex)` 分组，单线程串行，保证同队列顺序。
- 失败批次：记录 `attempts`，重新放回队首；`attempts > 3` 或队列满时丢弃并记 ERROR（含数量与目标）。
- 关闭：置 `closed` → 停止定时器 → 唤醒工作线程 → 等待当前批次结束 → 最后 `drain()` 一次。
  关闭阶段的 `record()` 丢弃并记 WARN（每秒最多一条）。

**接收端**：

- 先 `backupStore.append(...)` 记录；再 `backupStore.saveCursor(owner, topic, queue, group, pos)`。
- 位点只允许前进（比较 `(seq, offset)`）；回退请求记 WARN 并忽略。
- 记录数与 `states` 数不一致时记 WARN，仍落记录但不落位点。

**清理**：`BackupStore.allLogs()` 暴露 `(owner, topic, queueIndex, QueueLog)`；`LogCleaner` 增加
备份扫描，保留边界 = 该队列各组位点的最小值（无位点则保留全部），并叠加 `segmentedLogTTL`。

**恢复语义**：恢复流程（本期不做 CLI）只需按 `backup/<owner>/<topic>/<queue>` 打开日志、按
`cursors/<group>.cursor` 重建 `committed`，即可避免重放已确认消息。

**边界**：单节点 `targets.size == 0` 时不入队（不产生「批次凭空消失」）；批次跨主题不合并；
关闭与发送并发；重复批次幂等；备份位点与主队列位点独立。

### 3.6 A44：段 TTL 以持久化游标为保留边界

**根因**：`ConsumeService.references` 只遍历懒建的内存游标；离线组只有磁盘位点。

**方案**：

- 新增 `CursorCatalog`（`fmq.queue`）：
  - 启动时按 `MetaStore.groupsOf(topic)` 与本地队列，按需 `CursorStore.load`；
  - 内存缓存 `key = topic\0queue\0group → LogPosition`；
  - `save` 成功后更新缓存；`removeGroup/removeAllOf` 后失效；
  - `floorOf(topic, queue) -> Int64`：对所有已注册组取 `position.seq`，缺失位点视为 `1`，
    返回最小值；无组时返回 `1`。
- `GroupCursor` 仍维护内存 `committed`，保存时同步写缓存。
- `LogCleaner` 的引用回调改为 `floorOf`：`segment.index < floor` 才可删除（配合 TTL）。
  即「段号小于所有组位点的最小段号」才是无人需要的段。
- 性能：`floorOf` 走内存缓存；缓存未命中时按组加载一次，不为每个段重复 IO。

**语义**：已注册但从未消费的组把 floor 钉在 1 → 历史段全部保留。这是 at-least-once 的必然代价，
在 README 的已知限制中说明：需要回收历史请删除该组或降低 TTL 并接受语义变化。

**边界**：组删除后 floor 立即抬升；位点文件损坏按「缺失」处理（floor=1，记 ERROR）；
备份队列走相同规则；当前写入段永不删除。

### 3.7 A45：读取端记录长度上界

**段内记录格式**：每条记录以 `[4 字节大端无符号长度][记录字节]` 存放，长度只表示后面的记录字节数，
不包含 4 字节头；记录本身不跨段（容纳不下时先轮转，再整条写入新段）。

| 字段 | 宽度 | 说明 |
| --- | --- | --- |
| 长度 | 4 字节 | 大端无符号整数，值为后续记录字节数（不含头） |
| 记录 | `length` 字节 | `MQMessageRecord` 编码后的完整字节 |

上界为 `QueueLog.MAX_RECORD_SIZE = 64 MiB`，写入侧拒绝超限记录，读取侧据此判定损坏。
**兼容约束**：升级时不得改变前缀宽度或字节序，否则旧段无法按边界读取（历史段会出现错位解析）。

**方案**（`QueueRecordReader.next`）：

1. 读 4 字节头；不足 4 字节 → 损坏（截断的尾部不是合法结束标记）。
2. `length = getInt32BE`；`length == 0` → 立即停止（修正现有「零长度继续解析」的控制流）。
3. `length < 0`（不可能，但保留）或 `length > QueueLog.MAX_RECORD_SIZE (64 MiB)` → 损坏。
4. `remaining = segmentMeta.size - (offset + 4)`；`length > remaining` → 损坏。
5. 只有通过 2–4 才 `Array<Byte>(length)` 分配（MUST NOT 按声明长度直接分配）。
6. 损坏时：记 ERROR（主题、队列、段号、偏移、声明长度、剩余），`close()`，返回 `None`；
   同时把 `QueueLog` 标记为「已损坏」，后续 `scanAfter` 抛出 `QueueCorruptionException`。

**统计与消费的处理**：

- `ConsumeService.stats` 捕获 `QueueCorruptionException` → 整个查询返回 `ERROR(INTERNAL)`（A62）。
- `GroupCursor.next` 捕获后记 ERROR、返回空（不崩溃），并把该位置记为不可读（A48）。

**边界**：`MAX_RECORD_SIZE` 与写入侧常量同源；`remaining` 取创建流时的段快照；不跨段；
截断的尾部不零填充。

### 3.8 A46：不可评估 BODY 的有界出口

**方案**：

- `GroupCursor.next` 返回类型改为 `CursorOutcome`：
  `Record(bytes, position)` / `Empty` / `Unsupported(position)` / `Corrupt(position)`。
- 扫描遇到 `Unsupported`（本订阅或组内任一活跃订阅）：
  1. 为该组写入 `DeliveryRecord(position, after, owner=None, decided=true)`；
  2. `scanPosition = after`，`advance()`（推进 `committed` 并落盘）；
  3. 记 WARN（topic/queue/position/group）；
  4. 返回 `Unsupported(position)`。
- `ConsumeService.consume` 将 `Unsupported` 转为
  `MQProtocol.fail(request, FILTER_UNSUPPORTED_BODY, "position seq:offset")`。
- 由于位置已越过，下一次 `CONSUME` 不会重复命中；同一位置只报一次。
- 发布侧 `bodyIsEvaluable` 保留：存在活跃非空 filter 时拒绝发布（快速失败）。
- 客户端 `consume` 对 `code == 10` 抛 `MQServiceException`（A16 的「不静默」一并生效）。

**语义取舍**：选择「跳过 + 报错」而不是「永久保留」。理由：保留会使组无出口（原文 Severe）；
跳过会丢失该条对该组的投递，但通过错误让调用方可见，且其它组不受影响。规格正文同步修改。

**边界**：组内无匹配（非 Unsupported）仍按 §4.7 处理；autoAck 组同样跳过并记 WARN；
不可评估记录不进入死信（它不是投递失败）。

### 3.9 A58 / A59：退出钩子与关闭容错

**入口**（`fmq/src/main.cj`）：

```
private func runServer(): Int64 {
    let server = ... // 构造失败仍返回 2
    ExitCallbacks.toExitGracefully()
    ExitCallbacks.atExit(0, {=> server.close()})
    server.run()
}
```

- 只在 `server` 分支安装；`manager`/`--help` 不安装。
- `toExitGracefully()` 将 `SIGTERM`/`SIGINT` 重置为「执行全部 atExit 回调后 `exit(0)`」。
- 钩子内 `close()` 必须幂等；重复信号由运行时处理。

**`close()` 结构**：

```
close() {
  synchronized(closeLock) {
    if (closeCompleted) return
    closed.store(true)                 // 让 run() 退出
    for ((name, step) in closeSteps()) {
      try { step() } catch (e) { failures.add(name, e); log.error(...) }
    }
    closeCompleted = failures.isEmpty()
    if (!closeCompleted) log.error("close incomplete: ...")  // 允许再次调用重试
  }
}
```

- `closeSteps()` 顺序：`server.close` → 巡检定时器 → `backup.close` → `cleaner.close` →
  `consume.close` → `backupStore.close` → `queues.sync/close` → `deadLetter.close` → `meta.close` →
  `registry.close`。
- 每个被关闭对象自身幂等；重试只对失败步骤有实际动作。
- 测试通过子类覆写 `closeSteps()` 注入抛错步骤（`protected open`），断言后续步骤仍执行、
  第二次调用只重试失败项。

**边界**：信号处理期间执行阻塞 IO 属于库的既有设计（`fdbm` 同款），文档注明；
`run()` 在 `closed` 后 500ms 内返回；退出码 0。

### 3.10 A28：注册的检查-执行原子化

**根因**：`MetaSyncer.registerTopic` 在锁外 `topicOf` 预检查、读 `nextStart`、`applyTopic` 丢弃
返回值，然后无条件广播。

**方案**：把整个决策下沉到 `MetaStore` 的单一临界区：

```
func registerTopic(meta: MQTopicMeta, nodeCount: Int64) -> (MetaApplyResult, ?MQTopicAssignment)
func registerGroup(meta: MQSubscribeGroupMeta) -> MetaApplyResult
```

- `registerTopic`：锁内检查存在性 → `start = nextStart % nodeCount` → `allocate` → 写
  `topics/*.meta` → 写 `assign.meta` → 返回 `Applied + assignment`；已存在返回 `Duplicated + None`。
- `registerGroup`：锁内检查主题存在 → 检查组存在 → 写盘 → 返回结果。
- `MetaSyncer`：`Applied` 才广播并返回**落盘的那个** `assignment`；`Duplicated` 抛
  `TOPIC_ALREADY_EXIST`/`GROUP_ALREADY_EXIST`；`Invalid` 抛 `INVALID_*`。
- 广播在锁外执行（网络不持锁），但广播内容只来自落盘结果。

**并发结果**：8 线程注册同一主题 → 1 个成功、7 个「已存在」，无重复分配、无分歧广播。
不同主题并发 → `nextStart` 在锁内串行推进，不会取到同一起点。

**边界**：`nodeCount` 由调用方传入（transport 的节点数），锁内只做取模；
`queueNum < 1` 在进入锁前拒绝；广播失败不影响本地成功（由反熵补偿）。

### 3.11 A33 / A34 / A36：远端应用的结构与顺序

虽然严重度为一般，但与 A25 共用应用路径，方案一并固定：

- `validateAssignment(assignment, nodeCount)`：主题合法、`queueNum >= 1`、`owners.size == queueNum`、
  owner/`startNodeIndex`/`origin` 范围、`delayingMs >= 0`、`revision >= 0`。失败返回 `Invalid`。
- `applyTopic` 仅接受通过校验的分配；`Conflict` 仅在「同 revision 不同内容」时返回。
- `applyGroup` 要求主题存在；不存在时返回 `TopicMissing`，`MetaSyncer` 放入
  `pendingGroups`（有界，TTL 5min），在主题 `Applied` 或下一次同步后重试。
- `nextStart` 只增不减：`applyRemote` 计算后与本地取 `max`。
- 畸形载荷：记 WARN 并忽略，不写盘、不广播、不影响本地状态。

## 4. 一般问题的落点

### 4.1 协议严格解码（A03、A04）

- `MQProtocol.asPayload<T>` / `decodePayload<T>` 的转换从 `SILENCE` 改为 `DEFAULT_DATA_FLAG`：
  转换不成功时抛 `DataException`，由调用方 catch 返回 `None`。
- 保留「运行时类型必须等于 `T`」的前置检查；`T` 为标量/字符串时，`Data` 子类型必须精确对应。
- `MQMessage.get<T>`：`body == None`、`DataNone`、空 `MQBlob` → `None`；对象 BODY 的
  `typeInfo.qualifiedName != TypeInfo.of<T>()` → `None`；其余严格转换，异常 → `None`。

### 4.2 组名与 kind 校验（A05、A10、A19）

- 新增 `MQGroup.isValid`（规则见 protocol delta）。
- `MQDeregisterPayload.kindOf(): DeregisterKind`，`isTopic()` 只对 `Topic` 为真；
  `Unknown` 由 `MQCommandExecutor` 回 `ERROR(INTERNAL)` 且不删除。
- 新增 `MQTags.isValid`：最多 64 个、每个 1..128 字符、不含空白/控制字符；
  `publish` 与 `subscribe` 本地校验，manager 不涉及 tags。

### 4.3 客户端错误可见性（A12–A18、A20、A71）

- `transferOf` 改为返回 `TransferOutcome{Response(msg), Timeout, Rejected(e)}`，调用方区分。
- `consume`：一轮内全部 `Rejected/Timeout` → `MQConnectionException`；`ERROR` 非
  `SUBSCRIBE_NOT_EXIST` → `MQServiceException`；解码失败 → ERROR 日志 + `MQServiceException`。
- `ack`：发送成功后才删映射；失败恢复映射并抛错；`ACK_UNKNOWN` 忽略。
- `unsubscribe`：全部成功后再删本地；失败保留并抛错。
- `subscribe` 回滚：收集失败节点写入异常文案与 ERROR 日志。
- 认领：`deliveries` 改为 `ConcurrentHashMap<String, Int64>`，用 `putIfAbsent` 原子占位；
  已存在则继续向下一 owner（服务端重投窗口内的重复位置只被一个线程取走）。
- `close()`：先置 `closed`，再关闭连接池，最后清空订阅；`subscriptionOf` 与 `deliveries.add`
  在 `closed` 检查后执行，允许竞态下抛 `MQConnectionException`，不得访问空引用。

### 4.4 元数据写入与删除顺序（A35、A37、A51）

- `writeAtomically`：`create(tmp)` → `write` → `flush` → `fsync(file)` → `close` → `rename` →
  `fsync(parent)`；失败向上抛，调用方回滚内存变更。
- `removeTopic` 顺序：写墓碑 → 删除全部组文件与目录 → 删除主题文件 → 删除队列目录/游标。
  任一步失败可重试；加载时丢弃孤儿组（见 metadata delta）。
- 对端收到墓碑（广播或快照）后同样要清队列目录/游标/订阅/计数器：`MetaSyncer` 提供
  `onDeleted: (MQDeregisterPayload) -> Unit` 回调，`MQServer` 注入与直连删除相同的清理函数；
  仅当墓碑 Applied 且本地条目确实消失时触发（重新注册覆盖墓碑时不清理）。
- `CursorStore.save` 同样 fsync 文件与父目录。

### 4.5 恢复期装配与反熵（A29、A31、A32、A43）

- `MetaSyncer` 增加 `onTopicApplied: (String) -> Unit` 回调；`MQServer` 注入
  `{topic => queues.openTopic(...)}`；本地注册、远端广播、快照合并、复活同步统一走它。
- `broadcast` 失败加入 `pendingPeers` 集合；反熵定时器每 `antiEntropyInterval` 调用
  `syncFromPeers()`（可选 peer 轮转），成功后清空。
- `syncFromPeers` 区分：无 peer / 连接失败 / 返回错误 / 解码失败，分别记 WARN，文案含原因。
- `snapshotFor(requesterIndex)` 暂不使用入参：删除参数或保留 `_` 并注释「预留按节点裁剪」，
  二选一必须在文档中一致（设计选择：删除参数，减少误导）。

### 4.6 队列读取与打开（A47、A48、A49、A52）

- `scanAfter`：起点段缺失时找最近的更大段；不存在则返回 `(0, None)` 并记 WARN；
  异常不再吞成 `(0, None)`，改为抛 `QueueCorruptionException`/`SegmentMissingException`，
  由 `stats` 转错误、`consume` 转空 + WARN。
- 不可读记录：WARN + `skippedUnreadable` 计数，`decided=true`；同一位置限流。
- `next` 开流与读中统一：无任何段 → `Empty`；有段但读失败 → `Corrupt`；不再一分支返回空、
  一分支抛原始异常。
- `openTopic`：`perTopicLocks` + 先构建后发布；用 `ConcurrentHashMap.putIfAbsent` 判定归属；
  失败时关闭本次创建的 `QueueLog` 并删除本次新建的空段目录。

### 4.7 消费语义（A50、A55、A57）

- `ack` 增加 `entry.delivered` 判定。
- `SubscriberRegistry.activeIds` 过滤 `isDisconnected()`；`sweep` 因此立即释放断链 owner。
- 「组内无匹配」定为**越过**：写 `decided=true`、`advance()`、DEBUG 日志 + 计数；
  正文与场景统一（protocol/consume delta 已改写）。

### 4.8 服务端与配置（A54、A60、A63、A64、A68）

- 配置：`MQConfig` 全量校验（见 server-runtime delta），显式非法值抛 `MQConfigException`；
  `parsePort` 删除，全部改用 `MQHost.parseHost`。
- `ackTimeout <= 0` 在启动期拒绝；运行期 `GroupCursor` 仍做防御性断言。
- 断链清理：`SubscriberRegistry` 的登记项增加 `generation`（每次 `SUBSCRIBE` 自增）；
  `infos()` 返回快照含 generation；`unregister(id, generation)` 只删匹配项。
- 可注入：`dispatchWith(serverFactory, managerFactory, args)`；生产 `dispatch` 调用它。

### 4.9 管理器与指标（A61、A62、A65、A69）

- `MQManager.requestSnapshot`：先判 `Command.ERROR` → `asResult` 打印错误码文案；
  `RESP` 但载荷非快照 → 协议错误；只有发送失败/超时才打印「无法连接」。
- 输出渲染抽成纯函数（`MQManagerOutput`），用例直接断言字符串。
- `MQMetrics.removeTopic/removeGroup`；`GroupCursor` autoAck 分支调用 `incAcked`。
- `stats`：单趟扫描 + 失败传播；`lagMs` 负值取 0。

### 4.10 文档与台账（A09、A22、A23、A53、A73、A74、A75）

- 以「源码为准」重写两份详细设计的相关表与签名；每条给出可 grep 的关键串。
- `fmq/README.md` / `README_en.md`：命令行参数位置、7 个子命令、备份语义、TTL/离线组、
  已知限制。
- `tasks.md`：勾选 11.1–11.6；新增本次变更章节（任务完成后勾选），不得引用不存在的文件。

## 5. 兼容性、迁移与边界

### 5.1 线格式

| 变更 | 兼容性 |
|---|---|
| `Array<Byte>` 字段 → `MQBlob` | 编码字节不变；对象特征按类名，不含字段类型；双向可解 |
| 新增 `revision/origin/deletedAtMs` | 带默认值；旧解码忽略未知字段 |
| `MQMetaSnapshot.tombstones` | 旧节点忽略；新节点对旧快照按空数组处理 |
| `MQBackupPayload.cursors` | 旧接收端忽略；新接收端对缺失字段不回退位点 |
| `MessageID` UTC | 只影响新生成的 id 文本；旧 id 由容错规则兜底 |

**升级顺序**：先全部 `fmq` 服务端，再 `f_mq` 客户端。混合版本期间：
- 旧服务端收到 >4096 的消费响应仍会降级 → 发布大消息前必须完成服务端升级；
- 旧服务端不认墓碑 → 删除在升级后由反熵补齐（墓碑 TTL 内）；
- 新服务端向旧节点发备份时，旧节点忽略 `cursors`，记录仍落盘。

### 5.2 存储

- 新增目录：`metas/tombstones/`、`metas/revision.meta`、`backup/<owner>/<topic>/<queue>/cursors/`。
- 旧数据加载：无 revision 视为 0；无 `revision.meta` 时取全体最大 +1。
- 不迁移、不重写既有文件；段与位点格式不变。
- 回滚：旧版本可读新写的 `.meta`（忽略新字段），但会忽略墓碑；回滚后不得有删除操作，
  否则需再次升级收敛。

### 5.3 行为与 API

| 变更 | 影响 | 处理 |
|---|---|---|
| `consume` 对非空但不可解码记录抛错 | 调用方可能首次见到异常 | 文档 + 用例；错误含位置 |
| 全部 `NOT_OWNER` → `MQServiceException(8)` | 调用方按连接异常重试的逻辑需调整 | 文档；E2E 覆盖 |
| `ack` / `unsubscribe` 失败抛错 | 之前静默 | 文档；调用方需捕获 |
| autoAck 计入 `acked` | 指标数值变化 | 文档；列不变 |
| `stats` 失败返回 ERROR | 脚本可能从「0」变为非 0 退出 | 文档；manager 打印原因 |
| 非法显式配置启动失败 | 之前静默回落 | 文档；`--help` 标注 |

### 5.4 边界清单（必须有用例）

1. `record.size == 4096` 与 `4097`；`record.size == 0` 仍表示「无消息」。
2. 临时文件已被外部删除；父目录删除失败；`DataInputStream` 非文件。
3. `MessageID` 在 UTC / `Asia/Shanghai` / `America/New_York` 三种时区下一致；
   未来时间戳与负 `lagMs`。
4. 单节点集群（`nodeCount == 1`）：注册、删除、备份 0、反熵空转。
5. `backup > nodeCount - 1`、`backup == 0`、后继全不可达。
6. `ackTimeout` 为 0/负数；TTL 为 0；`maxSize` 为 0/负数；非法 `host:port`。
7. 墓碑未过期 / 过期 / 与重新注册竞争；离线节点跨 TTL 返回。
8. 段长头为 `0`、`0xFFFFFFFF`、`> remaining`、恰好等于 `remaining`；段被并发删除。
9. 组从未消费、组离线、组删除后 floor 抬升；备份位点缺失。
10. `close()` 在信号路径、并发调用、单步失败、重复调用下的终态。
11. 断链与重订阅使用同一 `subscribedId` 的竞态。
12. `stats` 与段清理并发；计数器清理与查询并发。

## 6. 测试策略（TDD）

- **红**：每个任务先写失败用例，断言本文规定的行为（而非现有行为）。用例必须能在当前实现上
  失败，失败原因写入任务记录。
- **绿**：最小实现通过；随后补边界与并发用例。
- **隔离**：所有临时目录用 `UUID` 唯一化，不再固定 `/tmp/fmq_test_*`；`Config` 修改必须
  try/finally 还原；网络用例使用包内注入的假 `Client`/`Transport`。
- **时间**：统一注入 `now: () -> DateTime`；延迟、TTL、超时用例不使用真实 `sleep` 断言。
- **层次**：
  - `f_mq`：协议/载荷/客户端（假连接）；
  - `fmq`：MetaStore/MetaSyncer/Backup/Queue/Cursor/Server（包内替身）；
  - 三个模块全量 + `scripts/mq_e2e.sh`。
- **E2E 增量**：`kill -TERM` 验证优雅退出；`stats` 校验；备份目录落盘与清理；
  `deleteTopic` / `deleteSubscribeGroup`；大消息（1MB）发布消费。
- **文档验收**：`grep` 关键串 + 文档与源码签名对照（人工复核 + 任务勾选）。

## 7. 风险与开放问题

| 风险 | 缓解 |
|---|---|
| `MQBlob` 与旧节点的线格式假设有误 | 先写双向 golden 用例（旧 `Array<Byte>` 编码 ↔ 新 `MQBlob` 编码字节相等）再改字段 |
| 改 `MessageID` 影响 `f_protocol` 其它使用者 | 全仓跑测试；只改 `toString`，`==`/`hashCode` 不变；用例覆盖日志/ID 文本 |
| 信号处理中执行阻塞关闭 | 沿用 `fdbm` 模式；关闭步骤有超时/容错；E2E 实测 SIGTERM |
| 墓碑 TTL 与离线时长的权衡 | 默认 7d，可配置；文档明确超期节点的重建流程 |
| 备份位点语义与「副本只落记录」的既有契约 | 位点是**附加**文件，旧节点忽略；不改记录格式 |
| 严格客户端错误破坏现有调用方 | 变更说明 + 全仓调用点更新；错误类型与码稳定 |
| `consume` 对不可评估记录报错可能导致业务中断 | 一次性报错且已越过；组不会停摆；文档给出处理建议 |
| 段保留被「从未消费的组」钉住 | 文档说明；运维可删除组；后续可加「组级保留策略」 |
