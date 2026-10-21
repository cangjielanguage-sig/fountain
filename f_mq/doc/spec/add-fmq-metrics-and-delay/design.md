# 设计：fmq 指标统计与延迟消息

> 依据：`fmq/doc/详细设计.md`、`f_mq/doc/详细设计.md` 与本次 proposal。
> 本文固定指标口径、延迟判定算法、协议载荷与测试边界。

## 1. 目标与非目标

### 目标

1. `fmq manager stats [topic]` 返回节点级指标：积压、消费延迟、投递/确认/重投/死信计数。
2. 主题支持 `delaying=<DurationString>`（默认 `0s`），消息到期前不投递、不推进游标。
3. 延迟随元数据落盘/广播/快照复制，跨重启有效。
4. P0/P1 遗留项归档到 `fmq/doc/backlog.md`，不实现。

### 非目标

- 跨节点聚合统计（`stats` 只查单个节点；多节点由运维分别查询或后续聚合）。
- 指标持久化（`delivered` 等计数从进程启动开始；`backlog/lag` 实时扫描）。
- 消息级 TTL、定时重试、死信重放、动态成员、批量/异步 API。
- 修改协议命令号；统计复用 `REGISTER`。

## 2. 指标设计

### 2.1 指标口径

| 指标 | 口径 |
|---|---|
| `delivered` | 游标成功返回给订阅的次数（含重投） |
| `acked` | `ack` 成功推进游标的次数 |
| `redelivered` | 已投递未确认、超时/释放后再次投递的次数 |
| `deadLettered` | 写入死信的条数 |
| `backlog` | 组在该主题本地队列中 `committed` 之后的记录数（含 pending 与未投递） |
| `lagMs` | backlog 中最早一条记录的发布时间到现在的毫秒数；无 backlog/无法解析为 0 |

计数器按 `(topic, group)` 维度，进程内 `ConcurrentHashMap<String, AtomicInt64>`；
`backlog/lag` 在查询时用游标位置扫描，保证与持久化状态一致。

### 2.2 采集点

- `GroupCursor.next`：新投递 `delivered++`；重投 `delivered++` 且 `redelivered++`。
- `GroupCursor.ack` 成功：`acked++`。
- `GroupCursor.writeDeadLetter`：`deadLettered++`。
- `MQMetrics` 由 `MQServer` 创建，注入 `ConsumeService` → `GroupCursor`；测试可注入空实现。

### 2.3 统计查询

- 协议：`REGISTER` + `MQInternalMessage{kind = "stats"}`，子载荷为 topic 字符串。
- 服务端 `MQCommandExecutor.onInternal` 分派到 `ConsumeService.stats(request)`。
- 组装：
  1. 主题列表：`QueueManager.localTopics()`；请求 topic 非空时只取该主题（不存在返回空）。
  2. `queueNum` 与 `delayingMs` 取分配结果。
  3. 组列表：元数据中的已注册组（`MetaStore.groupsOf`），保证从未消费的组也有记录。
  4. 每组：对每个本地队列调用 `cursorOf(...).committed`，`QueueLog.scanAfter(committed)`
     得到 backlog 与该段最早发布时间 → `lagMs = now - publishTime`。
  5. 计数器从 `MQMetrics` 读取。
- 查询开销：`scanAfter` 只扫 backlog 部分；超大积压时 stats 会变慢，属于已知取舍，
  不阻塞发布/消费（各自持有独立锁）。
- 首行 `#` 携带节点下标，避免误读为集群总量。

### 2.4 响应格式

响应为 UTF-8 TSV 文本，避免新增 `@DataAssist` 载荷类（新增对象类型会干扰跨模块类型注册）：

```text
#\t<nodeIndex>\t<generatedAtMs>\n
R\t<topic>\t<group>\t<queueNum>\t<delayingMs>\t<backlog>\t<lagMs>\t
  <delivered>\t<acked>\t<redelivered>\t<deadLettered>\n
```

- 无订阅组的主题输出一行 group 为空的 `R` 记录。
- manager 按 `\t` 解析；topic/group 中不允许制表符与换行（主题已受 `MQTopic` 校验约束）。
- `MQInternalKind.STATS = "stats"`；请求用 `MQProtocol.stats(topic)`，响应用 `respond<String>`。

## 3. 延迟消息设计

### 3.1 主题定义

- `MQTopicMeta` / `MQTopicAssignment` 新增 `delayingMs: Int64`（毫秒）。
- 管理端 `registerTopic <topic> <queueNum> [delaying=1m1s]`；`Duration.tryParse`，负数拒绝。
- 默认 `0`，不影响既有行为。
- 分配结果落盘、广播、快照携带；`listTopics` 显示 `delaying`。

### 3.2 发布时间

- 客户端 `publish` 生成 messageId：`pid_tid_hostId_<23 位 UTC 时间戳>`。
- `MQMessageRecord.publishTime(record)`：取 messageId 最后一个 `_` 后的 23 位，按
  `yyyyMMddHHmmssSSS`（S 解析 9 位纳秒）解析；用 `zoneOffset` 校正为 UTC。
- 解析失败返回 `None`；服务端按「已到期」处理并 WARN（不阻塞非标准生产者）。

### 3.3 投递判定

`GroupCursor` 持有 `delaying: Duration`。扫描新记录时：

```text
if delaying > 0:
    let stamp = MQMessageRecord.publishTime(record)
    if stamp.isSome() && now - stamp.get() < delaying:
        scanPosition = position       // 停在队首
        reader.close(); reader = None
        return None                    // 不建未决项、不推进 committed
```

- 只在「扫描新记录」路径判定；已投递记录的 `redelivery` 不再延迟。
- 未到期时整条队列暂停（队首阻塞），保证 FIFO；同一主题后续消息发布时间更晚，不会被越过。
- `autoAck` 同样受延迟约束。
- 到期后从同一 `scanPosition` 重扫，正常投递。

### 3.4 重启与时钟

- 发布时间在记录内（messageId），重启后仍可判定，无需额外持久化。
- 依赖生产者与消费者时钟基本同步（NTP）；时钟回拨会延长延迟，文档注明。

## 4. 管理端

- `MQManagerArgs`：新增 `stats`，操作数 0 或 1；`registerTopic` 操作数 2 或 3。
- `MQManager`：`stats(topic)` 发送请求并渲染表格；`registerTopic(topic, queueNum, delayingMs)`。
- `MQManagerOutput`：复用表格；空结果输出「（空）」。
- `MQUsage` / `helpText` 同步。

## 5. 测试策略

| 层 | 用例 |
|---|---|
| 协议 | `MQProtocol.stats(topic)` 的 `REGISTER`/`STATS` 与字符串子载荷；`publishTime` 标准/非标准 ID |
| 元数据 | `MQTopicMeta`/`MQTopicAssignment` 带 delaying 往返；MetaStore 重启保持；快照/远端应用 |
| 消费 | 未到期不投递、到期投递、零延迟、队首阻塞、重启后仍延迟、非标准 ID 立即投递 |
| 指标 | 积压/延迟计算、计数器（投递/重投/确认/死信）、查询无副作用、未知主题 |
| 管理端 | `stats` 全部/按主题/未知主题/连接失败；`delaying=` 合法/非法/默认；listTopics 列 |
| 回归 | 三模块全量 + E2E（现有延迟 0，行为不变） |

## 6. 风险

- 元数据字段变更使旧分配文件缺 `delayingMs`：升级需重新注册主题（未发布分支，BREAKING）。
- `stats` 的 backlog 扫描在超大积压时变慢；文档标注，后续可加缓存/计数。
- 延迟依赖 messageId 时间戳；非标准 ID 只能立即投递。
- 计数器重启归零；`backlog/lag` 不受影响。
