# 设计：fmq postfix 复审修复

> 依据：`reviews/202610211902_fmq-postfix-audit/todo.md`（R1–R5，77 项，6 严重）。
> 本文固定 6 个严重问题的根因、落点、算法与用例断言，并给出一般问题的统一裁决与死代码处置策略。
> 实现细节与源码冲突时以实测为准，但**不得改变**本文规定的对外语义。

## 1. 目标与非目标

### 目标

1. 公开读取 API 对合法输入返回正确答案：标量/字符串可读、类型不符返回 `None`、字段漂移不产半成品。
2. 删除真正"删得掉"：墓碑参与接受判定与版本竞争，迟到条目与旧快照都不能复活已删主题/组。
3. 排空到段末尾是常态而不是损坏：位点归一化后游标继续前进，`stats` 不误报。
4. 记录上限与段上限联动，任何配置下都不越界写。
5. 管理端错误分类可回归：服务端错误、格式不符、连不上三类文案互斥，且用例断言输出。
6. 死代码有明确去向（删除/下沉/使用/标注），测试替身退出生产源集。
7. 规格、详细设计、README、台账与实现一致，并消除四处规格自相矛盾。

### 非目标

- 不改段文件、`.meta`、`.cursor` 的二进制格式；不新增命令号。
- 不做备份反熵、自动故障转移、跨节点事务。
- 不为 `MQMetaSnapshot` 删除 `tombstoneFloor` 提供滚动升级兼容层（同版本部署）。
- 不重构 `f_io.SegmentedLog` 的存储模型，只补越界防御。

## 2. 基线事实（读源码确认）

| 事实 | 位置 | 影响 |
|---|---|---|
| `asPayload` 只接受 `SimpleDataObject`，其余直接 `None` | `f_mq/src/base/MQProtocol.cj:154-169` | 标量/字符串恒错答 |
| `asPayload` 用 `convert(..., SILENCE)`，`decodePayload` 用 `DEFAULT_DATA_FLAG` | 同上 `:165`；`:246-252` | 两 API 语义不对称，字段漂移产默认对象 |
| `applyTopic/applyGroup` 只查 `topicIndex`/`groups`，从不查 `tombstones` | `fmq/src/meta/MetaStore.cj:224-248,250-286` | 已删条目可复活 |
| `applyTombstone` 删除条件只看 `local.revision <= tombstone.revision` | `MetaStore.cj:340-368` | 输掉的墓碑仍删数据 |
| `mergeSnapshot` 先应用墓碑，再逐条 apply，畸形条目 `continue` 后不算已验证 key | `MetaSyncer.cj:382-413` | 畸形条目触发误删 |
| `load()` 顺序为 topics→groups→tombstones，但不收敛 | `MetaStore.cj:91-105,647-660` | 崩溃窗口后复活 |
| `startPositionOf` 段存在即原样返回位置，不归一化 `offset == size` | `QueueLog.cj:106-121` | 剩余 −4，判损坏 |
| `QueueRecordReader.next` 用 `meta.size - offset - 4` 做剩余校验 | `QueueLog.cj:303-311` | 负剩余进入 `corrupt` |
| `append` 只校验 `record.size > 64 MiB` | `QueueLog.cj:58-61` | 段上限更小时越界 `mcopy` |
| `SegmentedLog.append` 轮转后不检查 `data.size > maxFileSize` | `f_io/src/SegmentedLog.cj:189-196` | mmap 越界写 |
| `withClient` 的 `catch (_: Exception)` 统一报连接失败 | `MQManager.cj:214` | 格式异常被误分类 |
| 管理端测试只断言 `run() == 1` | `fmq/src/server/MQManager_test.cj:104-142` | A65 回归不可见 |
| `LogCleaner` 把失败合并为一条 WARN | `LogCleaner.cj:114-119` | 无逐对象 ERROR |
| `BackupReplicator` 在 `delivered == 0` 时才回队 | `BackupReplicator.cj:169-180` | 部分成功丢副本 |
| `MQMetrics.bump` 为 `addIfAbsent` + `get` 两步 | `MQMetrics.cj:35-39` | 并发删除抛异常 |
| `MQStubServer.cj`、`TestDirs.cj` 不以 `_test.cj` 结尾 | 两模块 | 进入生产产物 |

## 3. 严重问题技术方案

> 3.2 与 3.3 是「墓碑参与接受与胜负判断」的两个面（接受侧 / 删除侧），必须成对落地；
> 死代码清理与打包边界不属于单个缺陷，统一放在 §4。

### 3.1 R1-S1：`asPayload<T>` 的类型闸门与严格转换

**根因**：类型闸门按「是不是 `SimpleDataObject`」分支，把标量/字符串直接判死；通过后使用
`SILENCE`，与 `decodePayload` 的 `DEFAULT_DATA_FLAG` 相反；而 `f_data` 中 `DEFAULT_DATA_FLAG == SILENCE`，
所以「严格」必须由对象目标的字面量 `0` 表达。

**方案**：把 `decodePayload` 的类型判断抽成唯一实现，`asPayload` 只负责从 `Message` 取 `data`：

```cangjie
private static func readPayload<T>(data: Data): ?T where T <: DataFields<T> {
    let objectTarget = !T.isSimple()
    match (data) {
        case o: SimpleDataObject =>
            if (o.typeInfo.qualifiedName != TypeInfo.of<T>().qualifiedName) {
                return None<T>
            }
        case _ =>
            // 目标是对象、数据是标量：拒绝；目标是标量时由 tryFromData 做精确类型匹配
            if (objectTarget) {
                return None<T>
            }
    }
    // 对象：严格标志（0）；标量：DEFAULT_DATA_FLAG
    let flag: DataConversionFlag = if (objectTarget) { 0 } else { DEFAULT_DATA_FLAG }
    try {
        match (T.tryFromData(data, flag)) {
            case x: ?T => x
            case x: T => Some(x)
            case _ => None<T>
        }
    } catch (_: Exception) {
        None<T>
    }
}

public static func asPayload<T>(message: Message): ?T where T <: DataFields<T> {
    readPayload<T>(message.data)
}
```

`decodePayload` 解码出 `data` 后同样调用 `readPayload`，保证「同一段字节两个 API 同结论」。
`asInternal`/`asResult`/`asConsumeResult` 不改，自动受益；`asResult` 的 `DataNone → MQResult(0,"ok")`
短路保留。

**边界**：

- `T` 为标量时不做跨类型兜底：`DataInt` 不能读成 `String`（`tryFromData` 若宽松，需要先比
  `data.typeInfo` 与 `T` 的全名；以实测为准，用例必须能挡住）。
- `DataNone` 读取对象 → `None`；读取 `Unit`/可选类型不在本 API 的契约内。
- 异常一律吞成 `None`，不改变「读取不抛」的契约。

**用例（Red → Green）**：

1. `String`/`Int64`/`Bool` 三个标量命中（当前必红）；
2. 标量读对象、对象读标量均为 `None`；
3. 构造少字段的旧对象 → `None`（`SILENCE` 下会返回默认对象，必红）；
4. `asPayload` 与 `decodePayload` 对同一字节结论一致；
5. `MQPayload_test` 现有用例全绿（回归）。

### 3.2 R2-S1：墓碑参与接受判定

**根因**：接受判定只看内存索引；墓碑是旁路状态，只在删除路径写、在快照里传，从不参与 apply。

**方案**：把「墓碑也是一次带版本的变更」作为唯一判定入口。

新增结果分支：

```cangjie
enum MetaApplyResult {
    | Applied
    | Duplicated
    | Conflict      // 主题路径：同 revision 不同内容时保留本地并 WARN
    | TopicMissing
    | Invalid
    | Tombstoned    // 新增：被同 key 墓碑挡住
}
```

新增判定（调用方必须持有 `lock`）：

```cangjie
private func tombstoneOfLocked(kind: Int64, topic: String, group: String): ?MQMetaTombstone
private func acceptOverTombstoneLocked(kind, topic, group, revision, origin): Bool {
    match (tombstoneOfLocked(kind, topic, group)) {
        case Some(t) => isNewer(revision, origin, t.revision, t.origin)
        case None => true
    }
}
```

落点：

| 入口 | 改动 |
|---|---|
| `applyTopic` | 先 `acceptOverTombstoneLocked(TOPIC, topic, "", rev, origin)`；否 → WARN + `Tombstoned`；是 → 写入后 `dropTombstoneLocked(key)` |
| `applyGroup` | 先按组 key 判定；再判主题存在；接受后删除组墓碑 |
| `registerTopic` | 新 revision 由 Lamport 计数器分配（`maxRevisionLocked` 必须把墓碑计入）；写入后删除主题墓碑 |
| `registerGroup` | 同上，删除组墓碑 |
| `mergeSnapshot` | 条目走同一 `applyTopic/applyGroup`；`Tombstoned` 的 key 加入 `blockedKeys`，缺失扫描排除 |
| `load` | 收敛阶段用同一 `isNewer` 判定（见 3.3/§4） |

`dropTombstoneLocked`：从 `tombstones` 移除 + 删除墓碑文件；删除失败记 ERROR 但保留内存移除结果，
下次加载按「条目更新 → 删墓碑」再次收敛。

**为什么注册要删除墓碑而不是「标记复活」**：墓碑永久保留会随每份快照扩散、压低
`tombstoneFloor`、让 `topicTombstone(topic)` 对活主题返回 `Some`。删除是唯一能让
「主题已删」判断可靠的方案；`revision` 已足以阻止更旧的条目。

**快照合并的删除兜底**（原 `mergeSnapshot` 的三处漏洞）：

```cangjie
let verifiedTopics = HashSet<String>()   // 通过校验并 apply 的 key（含 Tombstoned）
let skippedTopics  = HashSet<String>()   // 畸形、继续跳过
...
if (snapshot.revision > 0) {
    for (a in store.topics()) {
        if (!verifiedTopics.contains(a.topic) &&
            !skippedTopics.contains(a.topic) &&
            !tombstoneKeys.contains(topicKey(a.topic)) &&
            a.revision <= snapshot.revision) { ... drop ... }
    }
}
```

- 畸形条目进 `skippedTopics`，不参与删除；
- 被墓碑挡下的条目进 `verifiedTopics`（它被"处理过"，不是缺失）；
- 本地有墓碑的 key 永远不因快照缺失而删（墓碑已经表达了删除）。

**用例**：

1. 墓碑 rev 7 + 迟到条目 rev 2（广播/快照两条路径）→ `Tombstoned`，无落盘、无 `openTopic`；
2. 同 rev 不同 origin → origin 大者胜，墓碑被移除；
3. 重新注册后 `topicTombstone == None`，快照不含该墓碑；
4. 畸形条目 + 本地合法同 key → 本地保留、无删除回调；
5. `MetaStore` 重开后墓碑与条目不再共存。

### 3.3 R2-S2：墓碑删除判定改用胜者语义

**根因**：`applied` 用 `isNewer` 算，删除却用 `local.revision <= tombstone.revision`；两者在
「同 revision、不同 origin」时结论相反。

**方案**：

```cangjie
let wins = isNewer(t.revision, t.origin, local.revision, local.origin)
if (!wins) {
    return MetaApplyResult.Duplicated   // 不写墓碑、不删条目、不触发回调
}
writeTombstoneLocked(t); tombstones.add(key, t)
dropEntryLocked(...)                    // 同临界区
MetaApplyResult.Applied
```

三条不变量：

1. **输掉的墓碑零副作用**：不落盘、不删条目、不 `notifyDeletedIfGone`（否则会级联删队列目录、
   游标、订阅与指标）。
2. **墓碑也不能"存储一个输给活条目的版本"**：若 `t` 输给本地条目，则既不写墓碑也不删条目；
   否则后续一个 rev 介于两者之间的条目会被这个墓碑误挡。
3. **删除与写墓碑同临界区**：任一步失败都保持「条目或墓碑至少一个可解释」，由加载收敛修复。

主题墓碑胜出时：删除主题 + 该主题下 revision ≤ 墓碑的组；对 revision 更高的组记 WARN 并一并删除
（主题已不存在，孤儿组无意义，且后续条目会被主题墓碑挡住）。

**用例**：`(rev 5, origin 9)` vs `(rev 5, origin 2)` → `Duplicated` 且组仍在；
`(rev 4)` vs `(rev 5)` → 删除并回调；同墓碑重复到达 → `Duplicated`。

### 3.4 R3-C1：段末尾位点归一化

**根因**：`startPositionOf` 找到段就原样返回 `(seg, offset)`；`offset == meta.size` 时
`ChainedSegmentStream` 会跳到下一段字节，而 `QueueRecordReader.seq` 仍是旧段号，剩余字节为负。

**方案**：在唯一的起点解析函数里归一化。所有开流路径（`openRecordsFrom` 与 `stats` 的起点解析）
都经过它，因此只改一处。

```cangjie
private func startPositionOf(segments, position): ?LogPosition {
    match (findSegment(segments, position.seq)) {
        case Some(meta) =>
            if (position.offset < meta.size) {
                return Some(position)                    // 正常段内
            }
            // 段已读完：落到下一个现存段；offset > size 记 WARN（游标异常）
            return startAfter(segments, position.seq, tail: true)
        case None =>
            return startAfter(segments, position.seq, tail: false)
    }
}

private func startAfter(segments, seq, tail): ?LogPosition {
    match (startSegmentAtOrAfter(segments, seq + 1)) {
        case Some(index) =>
            if (tail) { log.debug(...) } else { warnRateLimited(...) }
            Some(LogPosition(index, 0))
        case None =>
            if (!tail) { warnRateLimited("no segment ...") }
            None<LogPosition>
    }
}
```

配套：

- `QueueRecordReader.next` 的 `remaining < 0` 改为「不变量被破坏」的明确损坏信息（防御性，正常
  路径不再触发）；
- `GroupCursor.openReaderAt` 已在 `actual != position` 时把 `committed` 前移并落盘；归一化后
  `actual = (seg+1, 0)` 属于前移，行为正确，无需改；
- `stats` 使用同一解析结果计算起点，因此 `backlog` 从新段开始（正确），不再抛 `INTERNAL`。

**为什么不在 `append` 或游标侧修**：位点是外部持久化值（可能来自旧版本/备份），只有读取入口
能保证所有消费者一致。

**用例（精确复现）**：`maxFileSize = 64`（2×(4+28)），追加 2 条 28B → ack 两条 →
`committed = (1, 64)` → 追加第 3 条触发轮转 → `next()` 返回第 3 条；`stats` 同时可用。

### 3.5 R3-C2：记录与段上限联动

**根因**：`QueueLog` 与 `MQConfig` 各自只校验一个常量；`SegmentedLog.append` 轮转后无条件
`mcopy` 整条数据。

**方案**（三层防线）：

1. **队列层**：`QueueLog` 计算 `effectiveMaxRecord = min(MAX_RECORD_SIZE, maxFileSize - PREFIX_SIZE)`；
   构造时 `maxFileSize <= PREFIX_SIZE` 抛 `IllegalArgumentException`；`append` 在写入前拒绝
   `size == 0` 与 `size > effectiveMaxRecord`。
2. **存储层**：`SegmentedLog.append` 在 `rotate()` 前后都检查 `data.size > maxFileSize`，抛
   `LogRecordTooLargeException`。这是防御性修复：当前行为是越过 mmap 长度的 `mcopy`（内存破坏）。
3. **配置层**：`MQConfig.validate` 保持 `> 0`，并在 `segmentedLogMaxSize <= MAX_RECORD_SIZE + 4`
   时启动期 WARN，明确「单条记录上限被压低到 maxFileSize - 4」。

**取舍**：不把「段上限必须 ≥ 64 MiB」设为硬性启动错误，否则测试与小段部署（64B 段）无法使用；
`effectiveMaxRecord` 让任意配置都安全，WARN 负责让运维知道真实上限。

**用例**：1 MiB−4 成功且独占段；2 MiB 抛异常且文件长度不变；`append([])` 抛异常；
`maxFileSize = 4` 构造失败；直接调 `SegmentedLog.append` 超大抛 `LogRecordTooLargeException`。

### 3.6 R4-S1：管理端输出回归

**根因**：渲染直接 `println`，测试无法捕获；`withClient` 的兜底 `catch` 把任何非
`MQServiceFailure` 异常归为连接失败；两个 Scenario 用例只断言退出码。

**方案**：

1. **输出注入**：`MQManager` 构造参数增加 `sink: (String) -> Unit = {line => println(line)}`，
   所有输出走 `sink`；测试传入收集器，断言完整文本。
2. **失败分类显式化**：

```cangjie
private enum Failure {
    | Unreachable
    | Server(MQResult)
    | Protocol(String)   // 载荷类型不符或渲染解析失败
    | Local(String)      // 参数/配置非法
}
```

   `requestSnapshot`/`finish` 返回 `Failure` 或成功值，统一由 `report(failure)` 渲染；
   `catch` 顺序：`MQServiceFailure` → `Protocol`，其它 → `Unreachable`。
3. **渲染解析失败归类**：`MQManagerOutput.stats` 在列数不足或 `Int64.parse` 失败时抛
   `MQServiceFailure("stats 响应格式不正确: ...")`，由上层转 `Protocol`。
4. **用例**：捕获 sink，断言「服务端错误」含 `boom from server` 且不含「无法连接」；
   非快照含「响应不是 MQMetaSnapshot」；`stats` 非法数字含「响应格式不正确」；真正不可达含
   「无法连接」。删掉分类逻辑时至少三条用例变红。

**影响面**：`MQManager_test` 的 12 个用例全部改为「退出码 + 输出」双断言；`MQServer_test`
中管理端用例同步。

### 3.7 一般问题的统一裁决

| 议题 | 唯一裁决 | 影响文档/代码 |
|---|---|---|
| 位点段被删 | 跳到**编号更大的最近现存段**起点 + WARN，游标前移落盘；修复前 `stats` 报 `INTERNAL` | `consume-semantics`、`queue-storage`、README、详细设计、`GroupCursor_test` |
| 零长度头 | **损坏**：`corrupted = true` + ERROR，停止读取 | `QueueLog`、`queue-storage` 场景、`zeroLengthHeaderEndsTheStream` 改名并改断言 |
| 损坏 vs 段缺失 | 损坏：不推进、不标记已决、ERROR；段缺失：恢复并 WARN | `QueueLog.readAt` 返回判别结果、`GroupCursor` |
| 死信阈值 | `deadMsgThreshold` = 重试次数；总投递 `N+1` 次，第 `N+2` 次扫描入死信，`deliverCount = N+1` | `GroupCursor`、`consume-semantics` |
| 退订幂等 | 已退订 id → 成功空操作；未知 id → `MQServiceException`；`retired` 有界 4096 FIFO | `MQClient`、client spec、用例 |
| `stats` 段缺失 | committed 段缺失 → `INTERNAL`；段末尾归一化 → 正常 | `ConsumeService.stats` |
| 未来时间 | 超前 > 5 分钟按已到期 + WARN；写入规格与详细设计 | `GroupCursor.isDue`、`consume-semantics` |
| 内部 kind | 只有三种；删除旧场景 | protocol spec、历史 tasks V9 |
| 延迟示例 | 具名参数 `delayingMs:` | protocol spec、详细设计 |
| BackupStore 关闭写 | 留痕丢弃：DEBUG/WARN（1s 限流），`append` 仍返回成功 | `BackupStore`、server-runtime、README |

## 4. 死代码处置策略

### 4.1 四类处置

| 处置 | 判定标准 | 要求 |
|---|---|---|
| **删除** | 无生产调用、无语义价值，或可用更少代码表达 | 同步删测试断言；不得留下 `// removed` 注释 |
| **下沉测试** | 只被 `_test.cj` 用来构造/断言 | 移到 `fmq/src/test/` 或测试文件内的私有辅助；生产 API 面收窄 |
| **投入生产** | 实现本身正确，只是没接线 | 接入后必须有生产调用点 + 用例（如 `BackupReplicator.pendingCount`） |
| **标注保留** | 明确的测试观测/生命周期钩子 | 命名或注释标注「测试观测 API」，并在文档说明 |

原则：**不允许「留着但没人用」**。每个符号必须落入上表之一，并在任务 27 的清单里勾销。

### 4.2 逐项处置

| 符号/位置 | 类别 | 处置 |
|---|---|---|
| `MQDeregisterPayload.isGroup` | 完全死代码 | 删除；调用方改 `kind == ...GROUP` |
| `SegmentMissingException` | 完全死代码 | 删除；读取端用损坏结局/空流 |
| `QueueLog.openFrom` | 完全死代码 | 删除（生产走 `openRecordsFrom`） |
| `MQSubscriptionInfo.isConnected` | 完全死代码 | 删除 |
| `TestDirs.unique`、`cleanNamespace` | 完全死代码 | 删除；需要时并入 `of` |
| `hasMessage`、`isOk`、`respondEmpty` | 仅测试使用 | 下沉到测试辅助 |
| `scanAfter` | 仅测试使用 | 标注为「测试观测 API」（`stats` 走 `resolveStart` + `openRecordsFrom` 单趟扫描，不复用它） |
| `countAll` | 仅测试使用 | 下沉测试辅助（`QueueLog_test`/`ConsumeService_test` 各自实现） |
| `DeadLetterQueue.iterate` | 仅测试使用 | 标注保留（读 API），补一条生产语义说明 |
| `removeByBuffer` | 仅测试使用 | 下沉测试；文档改 `cleanupSubscribers` |
| `NodeRegistry.nodeAt`、`indexOf` | 仅测试使用 | 删除；测试改用 `addressOf`/`hosts` 等既有访问器 |
| `MetaSyncer.pendingPeerCount` + `pendingPeers` | 无消费者状态 | 两者一起删除；反熵遍历全部可达 peer |
| `BackupReplicator.pendingCount` | 仅测试使用 | **投入生产**：`close()` 日志输出剩余条数 |
| `BackupReplicator.flush()` | 重复入口 | 删除，只保留 `flushOnce` |
| `MetaSyncer` 组 `Conflict` 分支 | 不可达分支 | 删除；组冲突语义若需要另开变更 |
| `QueueLog` 的 `length < 0` 分支 | 不可达（`Int32` 读值 + 前面已判 `> MAX`） | 合并进 `length == 0`/超限判定 |
| `main.cj --help` 分支 | **可达**（`--help` 是用户入口） | 保留，`dispatch` 统一处理 |
| `MQManager` 的 `case _` | **可达**（未知子命令兜底） | 保留，打印帮助并返回 2 |
| `LogCleaner.start(now!)` | 空转参数 | 删除参数；需要注入时钟时改为构造参数并接入生产 |
| `MQMetaSnapshot.tombstoneFloor` | 无消费者协议字段 | 删除字段、计算、序列化与断言；快照线格式变更 |
| `MQSubscription` 的 `tags`/`filter` | 只写字段 | `tags` 校验后丢弃；`filter` 不保存；`id/topic/group` 用于日志 |
| `QueueManager.hasLocalQueues`、`MQMatcher.topicOf` | 无消费者 | 删除 |
| `MQAssignment.ownersOf` | 仅测试使用 | 下沉 `MQAssignment_test.cj` 私有辅助；详细设计删该条目 |
| 未使用 import（`SeekPosition`、`std.fs.*`、`f_data.*`） | 编译噪声 | 删除 |
| `setCloseStepsOverride` | 合法测试钩子 | 标注保留 |

### 4.3 打包边界

- `f_mq/src/client/test/MQStubServer.cj` → `MQStubServer_test.cj`（`cjpm` 只把 `*_test.cj` 编入测试目标）。
- `fmq/src/test/TestDirs.cj` **保留原名**：它被 `fmq` 多个兄弟包（`queue`/`server`/`cluster`/`manager`）
  共用，改成 `_test.cj` 后无法跨包导入。改为 `protected`（模块内可见），并**移除** `atExit` 进程钩子，
  由各测试类在 `@AfterAll` 调 `cleanNamespace` 回收。
- `MQStubServer` 由 `public` 改为包内可见；`TestDirs` 不设 `public`。
- 生产代码 MUST NOT 引用 `TestDirs`；验收：`fmq` 主程序构建产物 `nm`/字符串检索无 `MQStubServer`、
  `TestDirs` 符号（E2E 已有三条打包断言）。

## 5. 验证矩阵（TDD 顺序）

| 严重项 | Red（先写，当前必红） | Green（最小改动） | 回归 |
|---|---|---|---|
| R1-S1 | 标量命中、字段漂移返回 `None` | `readPayload` 统一闸门 | `MQPayload_test`/`MQProtocol_test` 全绿 |
| R2-S1 | 墓碑 rev 7 + 条目 rev 2 → 不复活 | `Tombstoned` + 快照 key 集合 | 102 个元数据用例全绿 |
| R2-S2 | `(5,9)` vs `(5,2)` → 组仍在 | 删除条件改 `isNewer` | 墓碑往返/回收用例 |
| R3-C1 | `maxFileSize=64` 复现负剩余 | `startPositionOf` 归一化 | 83 个队列用例全绿 |
| R3-C2 | 2 MiB 记录 + 1 MiB 段 → 越界 | 三层上限 | 记录边界用例 |
| R4-S1 | 断言输出（当前只断退出码） | sink + `Failure` 分类 | 管理端 12 个用例 |

**命令**：

```bash
cd f_mq && cjpm test
cd fmq  && cjpm test --no-progress
```

P0 未全绿不得进入 P1；每完成一个任务独立提交（`AGENTS.md` 分支流程）。

## 6. 兼容性与风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| `MQMetaSnapshot` 删字段 | 新旧节点快照线格式不同 | 同版本部署；README 已知限制注明 |
| `f_io.SegmentedLog.append` 抛异常 | 其他调用方可能依赖「静默截断」 | 检索全部调用方；超大记录本就是 bug |
| `stats` TSV 增列 | 旧 manager 解析 11 列仍可用（忽略尾部） | manager 按 `>= 11` 解析，新增列缺省显示为 `0` |
| 启动延迟绑定 | 依赖「构造后端口已开」的测试会失败 | 改用 `start()` 后探测端口；补启动顺序用例 |
| 墓碑删除 | 重新注册后墓碑消失，旧节点迟到墓碑仍可能到达 | `isNewer` 挡住旧墓碑；旧墓碑输给活条目时不落盘 |
| `retired` 集合有界 | 淘汰后旧 id 再退订会抛未知 id | 文档写明；容量 4096 足够覆盖重试窗口 |
| `scanAfter` 保留为测试观测 | 详细设计标注用途，避免被当成生产 API | 文档标注 + 现有用例 |
| 损坏段永久停摆 | 损坏不推进游标，组停在同一位置 | ERROR 可定位；运维删除损坏段后由段缺失恢复接管 |
