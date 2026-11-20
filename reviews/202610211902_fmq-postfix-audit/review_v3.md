# R3: 复审 fmq 队列与消费语义（queue-storage / consume-semantics）

审查时间：2026-10-21 19:25
审查对象：HEAD `22c13ec4`（全树复审，非 diff）

### 审查范围

代码：

- `fmq/src/queue/QueueLog.cj`
- `fmq/src/queue/QueueManager.cj`
- `fmq/src/queue/GroupCursor.cj`
- `fmq/src/queue/DeliveryRecord.cj`
- `fmq/src/queue/CursorStore.cj`
- `fmq/src/queue/CursorCatalog.cj`
- `fmq/src/queue/DeadLetterQueue.cj`
- `fmq/src/queue/MQMatcher.cj`
- `fmq/src/queue/QueueExceptions.cj`
- 测试：`QueueLog_test.cj`、`QueueManager_test.cj`、`GroupCursor_test.cj`、`CursorStore_test.cj`、`CursorCatalog_test.cj`、`DeadLetterQueue_test.cj`、`MQMatcher_test.cj`
- 交叉参照（只用于判定调用/覆盖，不在本轮改动范围）：`fmq/src/server/ConsumeService.cj`、`fmq/src/server/ConsumeService_test.cj`、`fmq/src/cluster/LogCleaner.cj`、`fmq/src/config/MQConfig.cj`、`f_io/src/SegmentedLog.cj`

文档/规格：

- `fmq/doc/详细设计.md` §4.4、§5.7–§5.13、§6.4–§6.6、§6.11、§9
- `openspec/specs/fmq/queue-storage/spec.md`
- `openspec/specs/fmq/consume-semantics/spec.md`
- `openspec/changes/archive/2026-10-21-fix-fmq-full-audit/specs/fmq/{queue-storage,consume-semantics}/spec.md`
  （说明：任务书给出的 `fmq/doc/spec/fix-fmq-full-audit/specs/...` 在仓库中不存在，实际文件位于上述归档目录，见 S7）

结论摘要：段格式、长度头、游标格式、死信存储、ack 归属、延迟语义基本落地且用例较扎实；
但存在 **2 项严重缺陷**（段末尾位置导致消费永久停摆；段上限与记录上限无关联校验可导致越界写），
以及 **12 项一般问题**（多为边界语义、文档与实现漂移、观测出口缺失、关键场景无用例）。

---

## 一、文档/规格 ↔ 实现逐项核对

| # | 检查项 | 规格/文档承诺 | 实现 | 结论 |
|---|---|---|---|---|
| 1 | 段格式 `[4B 大端长度][记录字节]`，长度不含头 | `详细设计.md:355-368`；`queue-storage/spec.md:223-232` | `QueueLog.cj:58-66`（写）、`:279-319`（读） | 一致 |
| 2 | 长度上界 64 MiB，分配前校验 | `queue-storage/spec.md:226-229`；`详细设计.md:727-728` | `QueueLog.cj:48`、`:305-311` | 边界一致；`length < 0` 为不可达分支（S2） |
| 3 | 0 长度头处理 | 规格标题「零长度视为损坏」（`queue-storage/spec.md:244-247`）；`详细设计.md:366`「`length <= 0` …视为损坏」 | `QueueLog.cj:290-294` 当作干净结束（不置 `corrupted`、不记 ERROR） | **不一致**（M1，已知 S7 未闭环） |
| 4 | 写入侧长度下界 1 | `详细设计.md:362`「取值 1..64MiB」 | `QueueLog.cj:59-61` 只校验上界，`append([])` 可写 0 长度 | **不一致**（M6） |
| 5 | TTL 段保留边界 = 全部已注册组位点最小值 | `queue-storage/spec.md:179-186` | `CursorCatalog.cj:98-122` | 一致；无组时返回 `Int64.Max`（`spec` 未定义，属实现选择） |
| 6 | 游标文件 `metas/offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor` | `queue-storage/spec.md:108-113`；`详细设计.md:446-455` | `MQFileNames.cursorFile` + `CursorStore.cj:36-38` | 一致；`详细设计.md:448` 参数名 `offsetRoot` 与实现 `metaRoot` 不符（M7） |
| 7 | 游标 `committed` = 连续已确认前缀之后的位置 | `consume-semantics/spec.md:56-59`；`详细设计.md:743` | `GroupCursor.cj:457-467` | 一致 |
| 8 | 位点所在段被删除后的恢复 | `queue-storage/spec.md:57-58`「从最接近的更大段继续 + WARN」；`consume-semantics/spec.md:294`「记 ERROR 后从现存最老段恢复」 | `QueueLog.cj:106-121` / `GroupCursor.cj:503-533`：从 `>= seq` 的最小段继续，记 WARN | **规格自相矛盾，实现取前者**（M3） |
| 9 | `openFrom` / `openRecordsFrom` 语义 | `详细设计.md:336-337`、`:760` 称游标用 `openFrom` | 游标实际用 `openRecordsFrom`（`GroupCursor.cj:477`）；`openFrom` 零调用 | **文档与实现不符**（M7） |
| 10 | 打开的原子性（占位+发布、失败回滚） | `queue-storage/spec.md:264-285` | `QueueManager.cj:72-118` | 一致；失败时的磁盘回滚无用例断言（M10） |
| 11 | ack 归属校验（他人 / 未投递 / 已越过 / 重复） | `consume-semantics/spec.md:120-144` | `GroupCursor.cj:375-399` | 一致 |
| 12 | 超过 `deadMsgThreshold` 进死信 | `consume-semantics/spec.md:91-104`「投递 4 次仍未确认」 | `GroupCursor.cj:172-180`：先 `deliverCount++` 再判 `> threshold`，第 4 次不投递直接入死信 | **实际只投递 3 次**（M5） |
| 13 | 延迟：`published + delaying <= now`，队首阻塞 | `consume-semantics/spec.md:215-254` | `GroupCursor.cj:246-252`、`:541-557` | 一致；额外的「未来 >5min 视为到期」未写入设计（M12） |
| 14 | Unsupported BODY：跳过 + 推进 + WARN + 计数 + 一次性报错 | `consume-semantics/spec.md:256-288` | `GroupCursor.cj:298-310`、`:352-358`；`ConsumeService.cj:93-98` | 一致；计数无生产出口（M8） |
| 15 | BODY 仅在需要 filter 时解码 | `consume-semantics/spec.md:10-14` | `MQMatcher.cj:107-118` | 一致 |
| 16 | 死信独立 SegmentedLog + 自描述 + 按位置读取 | `queue-storage/spec.md:158-177` | `DeadLetterQueue.cj:31-104` | 一致；`iterate` 无生产消费者（S6） |
| 17 | 损坏必须可识别、不得伪装成「段被删除」 | `queue-storage/spec.md:298-301`、`:319-322` | `readAt` 对两者都返回 `None`；`GroupCursor.cj:152-158` 标 `decided` 并越过 | **不一致**（M2） |
| 18 | 损坏时 `stats` 返回错误而非 0 | `queue-storage/spec.md:301`；`consume-semantics/spec.md:309` | `ConsumeService.cj:229-232` 只处理「扫描到损坏」；`segments==0` 处理 `:183-188`；**部分段缺失静默少算** | 部分不一致（M4） |
| 19 | `backlog/lagMs` 由 `QueueLog.scanAfter` 计算 | `详细设计.md:864` | `ConsumeService.cj:176-236` 自行单趟扫描；`scanAfter` 仅测试调用 | **文档与实现不符**（M7） |
| 20 | 损坏「抛 `QueueCorruptionException`」 | `详细设计.md:727-728` | 仅 `scanAfter` 抛；游标读路径返回 `None`+ERROR 日志 | 文档不准确（M7） |
| 21 | `next()` 命中后 `owner` 赋值 | `详细设计.md:758` 写 `owner = None` | `GroupCursor.cj:174` `owner = Some(subscription.subscribedId)` | 文档与实现不符（M7） |
| 22 | 读流恢复「开流/读中一致」 | `queue-storage/spec.md:303-317` | `QueueLog.cj:82-98` + `GroupCursor.cj:204-225` | 一致（用例 `allSegmentsMissingMidStreamReturnsNone`） |

---

## 二、Requirement / Scenario → 用例矩阵

记号：✔ 有直接用例；△ 有等价用例但断言偏弱或夹具与场景不符；✗ 无用例。

### 2.1 `queue-storage`

| Requirement / Scenario | 用例 | 判定 |
|---|---|---|
| 只建本机队列 | `QueueManagerTest.onlyLocalQueuesAreCreated`（`QueueManager_test.cj:39`） | ✔ |
| 无本机队列 → `pickQueue=None` | `topicWithoutLocalQueueHasNoPick`（`:132`） | ✔（`NOT_OWNER` 属服务端，未在本层断言） |
| 段内/跨段位置单调 | `rotationResetsOffsetAndIncrementsSequence`（`QueueLog_test.cj:66`） | ✔ |
| 每条记录可立即读回（含重启） | `everyAppendIsImmediatelyReadable`（`:251`）、`restartOpensNewSegmentAndKeepsOldBytes`（`:201`） | ✔ |
| 重启后开新段 | `restartOpensNewSegmentAndKeepsOldBytes` | ✔（未逐字节比较旧段文件，仅比 `size` 与读回） |
| 重启后有效长度不变 | 同上 `:219-220` | ✔ |
| 从中间位置读 | `openFromMiddleRecordReturnsRemaining`（`:486`） | ✔（用例名声称 `openFrom`，实际调 `openRecordsFrom`，S5） |
| 不读预分配区 | `readerSkipsPreallocationAndStopsAtEnd`（`:87`） | △（只写 48B，未真正逼近 `maxFileSize` 空洞边界） |
| 快照语义 | `streamIsSnapshotOfCreationTime`（`:152`） | ✔ |
| 位置已失效（从后继段继续） | `unknownSegmentResumesAtNextSegment`（`:117`） | ✔（WARN 内容未断言） |
| 起始段落在空洞 | `scanAfterSkipsGapToNextSegment`（`:460`）、`GroupCursorTest.startingSegmentHoleResumesAtNextSegment`（`GroupCursor_test.cj:502`） | ✔（走的是 `scanAfter`/游标，`openRecordsFrom` 本身无空洞直测） |
| 全部段被删除 → 空流 + WARN；统计不得报 backlog=0 | `unknownSegmentResumesAtNextSegment` 下半段、`GroupCursorTest.allSegmentsMissingReturnsNone`、`ConsumeServiceTest.statsFailsWhenSegmentsAreGone` | ✔（WARN 未断言） |
| 有效长度取 `logMetas().size` | `sizeUsesSegmentMetadata`（`:180`） | ✔ |
| 本机队列轮转均分 | `pickQueueRotatesEvenly`（`QueueManager_test.cj:148`） | ✔ |
| 位点往返 / 覆盖无残留 / 默认组 | `saveAndLoadRoundtrip`、`overwriteHasNoTmpResidue`、`defaultGroupUsesEncodedName`（`CursorStore_test.cj:53/69/87`） | ✔ |
| 落盘后可持久（fsync/掉电） | — | ✗（M10） |
| 删除主题后目录消失 + 位点清理 | `QueueManagerTest.closeTopicKeepsOrDeletesFiles`（`:167`）、`ConsumeServiceTest.removingTopicAndGroupClearsCounters` | △（队列目录有断言；位点清理只在服务端用例间接覆盖） |
| 删除组后位点消失、其他组不受影响 | `CursorStoreTest.removeGroupKeepsOtherGroups`（`:124`） | ✔ |
| 删除中途崩溃后收敛 | — | ✗（M10） |
| 死信写入后顺序读取 / 中间位置 / 重启保持 | `appendAndIterateFromFirst`、`iterateFromMiddlePosition`、`reopenKeepsAllEntries`（`DeadLetterQueue_test.cj:57/81/100`） | ✔ |
| 段 TTL：超期且无引用才删 / 引用则留 | `LogCleanerTest`（R2 范围）、`CursorCatalogTest.floorTakesMinimumAcrossGroups` | ✔（跨轮次） |
| 离线组持久位点保留段 | `floorUsesDurablePositionOfOfflineGroup`（`CursorCatalog_test.cj:68`） | ✔ |
| 从未消费的组保留段 1 | `floorIsOneWhenGroupNeverConsumed`（`:48`） | ✔ |
| 当前段永不删除 / 死信独立 TTL | `cleanExpiredLeavesOnlyCurrentSegment`、`cleanExpiredRemovesOnlySealedSegments` | ✔ |
| 记录格式写入 design.md 与模块文档 | — | △（`详细设计.md` 满足；归档 `design.md` §3.7 缺格式与兼容约束，见 verify W2） |
| 长度不含头部（10B → 占 14B） | `sizeUsesSegmentMetadata`（`QueueLog_test.cj:193`） | ✔ |
| 零长度视为损坏 | `zeroLengthHeaderEndsTheStream`（`:396`） | ✗ **实现按干净结束，未记 ERROR**（M1） |
| 超大声明长度 0xFFFFFFFF | `hugeDeclaredLengthIsRejectedWithoutAllocation`（`:323`） | △（未证明「未分配 4GiB」，只证明不崩溃） |
| 超过段剩余 | `declaredLengthBeyondRemainingIsRejected`（`:343`） | ✔ |
| 跨段不拼接 | `corruptionDoesNotReadIntoNextSegment`（`:410`） | △（该用例是损坏场景；正常「轮转后整条写入」无专门断言） |
| 并发打开同一主题 | `concurrentOpenCreatesSingleSet`（`QueueManager_test.cj:63`） | ✔ |
| 重复调用是空操作 | `onlyLocalQueuesAreCreated:52-54` | ✔ |
| 中途失败回滚（含磁盘无残留段） | `failedOpenRollsBackAndLeavesNoTopic`（`:104`） | △（只断言内存状态，未断言磁盘无残留，与场景后半句不符） |
| 段被清理导致不可读 → WARN + 计数 | `GroupCursorTest.unreadableRecordIsCounted`（`GroupCursor_test.cj:742`） | △（夹具是把长度头改成 0，不是删段；复用了 M1 的错误语义） |
| 损坏段停止读取 + stats 报错 | `corruptionDoesNotReadIntoNextSegment`、`ConsumeServiceTest.statsPropagatesScanFailure` | ✔ |
| 同一位置重复不可读限流 | — | ✗（实现无限流，M9） |
| 开流/读中全段缺失一致 | `allSegmentsMissingReturnsNone`（`:457`）、`allSegmentsMissingMidStreamReturnsNone`（`:474`） | ✔ |
| 段仍在但记录损坏不得伪装成段删除 | — | ✗（M2/M10；`GroupCursor` 读流中途损坏无用例） |

### 2.2 `consume-semantics`

| Requirement / Scenario | 用例 | 判定 |
|---|---|---|
| 主题完全相等 / tags 子集 / 空 tags / filter 决定投递 | `MQMatcherTest.topicMustMatchExactly`、`tagsAreSubsetAndOrderIndependent`、`filterDecidesDelivery`（`MQMatcher_test.cj:48/55/76`） | ✔ |
| 无法评估的对象 BODY | `undecodableBodyIsUnsupportedOnlyWithFilter`（`:97`）、`ConsumeServiceTest.unsupportedBodyIsReportedOnceAndSkipped` | ✔ |
| 两个订阅同组总数守恒（100 条并发） | `ConsumeServiceTest.sameGroupDoesNotDuplicate` | △（只 2 条、串行；未做 100 条并发守恒） |
| 跨组各自消费 | `differentGroupsConsumeIndependently`（`ConsumeService_test.cj:690`） | ✔ |
| 顺序确认 / 乱序留洞 | `sequentialDeliveryAdvancesCommitted`（`:160`）、`outOfOrderAckKeepsHole`（`:187`） | ✔ |
| 空洞可重投 | `timeoutAllowsRedelivery`（`:231`） | ✔ |
| 超时后重复投递 / 未超时不重投 | 同上 + `metricsCountDeliveryAckAndRedelivery` | ✔ |
| 超阈值进死信 | `deliveryOverThresholdGoesToDeadLetter`（`:256`） | △（阈值 1 → 实际只投递 1 次，固化 M5 的 off-by-one） |
| 组间死信隔离 | — | ✗（`DeadLetterQueueTest.entriesFromDifferentGroupsStayIsolated` 只验证条目字段隔离，未验证 A 组进死信后 B 组仍可消费） |
| 死信条目内容完整 | `deliveryOverThresholdGoesToDeadLetter:267-271` | △（只断言 `segmentedIndex>=1`、`subscribeGroup`、`deliverCount`；未断言原始字节、topic、queueIndex、原 offset、deadTime） |
| 自动确认 | `autoAckAdvancesWithoutExplicitAck`（`:279`）、`ConsumeServiceTest.autoAckSubscriptionNeedsNoAck` | ✔ |
| 他人消息不可确认 | `ackChecksOwnership`（`:214`）、`ackChecksSubscriptionOwnership` | ✔ |
| 尚未投递不可确认 | `ackRequiresDeliveredPosition`（`:777`） | ✔ |
| 已越过的位置（committed 之前 / 已进死信） | — | ✗（只有「重复确认」用例） |
| 重复确认 | `outOfOrderAckKeepsHole:206` | ✔ |
| 组内无匹配 → 越过 | `unmatchedRecordIsSkippedAndCommitted`（`:299`） | ✔ |
| 组内无人在线 → 不推进 | `ConsumeServiceTest.groupWithoutOnlineSubscriberKeepsPosition` | ✔ |
| 后加入的匹配订阅看不到已越过消息 | — | ✗（M10） |
| 注销后可被他人取走 | `releaseReturnsRecordToGroup`（`:339`） | △（由同一订阅重新取走，未验证「他人」） |
| 连接断开清理 / 断链立即不活跃 | `sweepReleasesInactiveOwner`（`:357`）、`ConsumeServiceTest.disconnectedSubscriptionDoesNotBlockGroup` | ✔ |
| 重启重投未确认 | `restartRedeliversOnlyUnacked`（`:378`） | ✔ |
| 位点恢复 | 同上（`close()` 落盘后重建游标） | ✔ |
| 并发取与确认（4 线程 1000 次、committed 单调不减） | `concurrentNextAndAckProduceUniquePositions`（`:549`） | △（4×50 次；只断言 `committed > 起点`，未断言单调不减） |
| 未到期 / 到期 / 队首阻塞 / 重启后仍延迟 / 非标准 id | `delayedRecordWaitsUntilDue`、`delayedTopicBlocksHeadOfLine`、`delayedRecordSurvivesCursorReopen`、`nonStandardMessageIdDeliversImmediately` | ✔ |
| 零延迟 | — | △（隐含于所有非延迟用例，无显式场景） |
| 先发布后加过滤器 / 不重复报错 | `unsupportedBodySkipIsCounted`（`:531`）、`ConsumeServiceTest.unsupportedBodyIsReportedOnceAndSkipped` | ✔ |
| 不影响其它组（unsupported） | — | ✗（M10） |
| 发布侧拒绝 | R1 范围 | — |
| 离线超过 TTL / 重启后恢复 | `floorUsesDurablePositionOfOfflineGroup`、`LogCleanerTest` | ✔ |
| 位点段被删 → ERROR + 最老段 + stats 报错 | `removedCommittedSegmentRecoversToOldestSurvivor`（`:428`）、`startingSegmentHoleResumesAtNextSegment` | ✗ **用例断言的是「下一个段」+ WARN，与规格文字相反**（M3） |

### 2.3 关键覆盖缺口汇总（尤其任务书点名的场景）

- **1 MiB 记录**：队列层 0 个用例。全部 `QueueLog` 用例的记录体 ≤ 96 B（`QueueLog_test.cj:50-92`），
  长度头的多字节大端路径（>255、>65535）只在「伪造损坏段」里以 0xFF 出现，从未做 1 MiB / 16 MiB 的写入-读回往返，
  也未验证跨段轮转时大记录的完整性（M10）。
- **空洞/缺段**：有；但 `openRecordsFrom` 的空洞直测缺失，且「位点恰在段末尾」（C1）完全无覆盖。
- **并发**：`openTopic` 与游标 next/ack 有；消费组守恒、并发 de-dup 的规模与断言偏弱（M11）。
- **重启恢复**：`QueueLog`、`GroupCursor`、死信均有；缺「段末尾 + 轮转」与「读流中途损坏」两类恢复（C1、M10）。

---

## 三、空测试 / 空函数 / 禁用用例

- 7 个测试文件共 83 个 `@TestCase`，**未发现** `@Disabled`/`@Ignore`/`@Skip`、`@Assert(true)`、仅打印、被注释的用例。
- 未发现 `throw NotImplemented`、仅 `return` 的占位函数。
- 空函数体只有两处，均属正常：`MQMatcher_test.cj:29`（`@DataAssist` 要求的无参构造）、`QueueManager.cj:106/:113`（回滚清理的空 `catch`）。
- 但存在**「形式上有用例、实质未验证目标语义」**的用例，按严重度计入 M1/M11：
  - `QueueLogTest.zeroLengthHeaderEndsTheStream`（`QueueLog_test.cj:396`）：断言的是「按干净结束」，与规格场景「零长度视为损坏」相反。
  - `GroupCursorTest.unreadableRecordIsCounted`（`GroupCursor_test.cj:742`）：用「把长度头改成 0」模拟「段被清理」，走的是 M1 的错误语义，未真正覆盖 `readAt` 因段缺失返回 `None` 的路径。
  - `QueueManagerTest.failedOpenRollsBackAndLeavesNoTopic`（`QueueManager_test.cj:104`）：场景要求「磁盘上不保留本次新建的段文件」，用例只断言内存状态。

---

## 四、死代码

### 4.1 无调用方 / 仅测试使用

| 符号 | 位置 | 证据 | 分类 |
|---|---|---|---|
| `SegmentMissingException` | `QueueExceptions.cj:41-53` | 全仓 0 处 `throw`/`catch`；任务 18.4 声称已实现但恢复路径改用 `SegmentRecovery` | 完全死代码 |
| `QueueLog.openFrom` | `QueueLog.cj:82-89` | 全仓 0 调用（测试函数名 `openFromMiddleRecordReturnsRemaining` 实际调 `openRecordsFrom`） | 完全死代码 |
| `QueueLog.scanAfter` | `QueueLog.cj:148-156` | 仅 `QueueLog_test.cj:331-477` 调用；生产 `stats` 自写扫描 | 仅测试使用 |
| `QueueLog.countAll` | `QueueLog.cj:194-200` | 仅 `QueueLog_test.cj` 与 `ConsumeService_test.cj:613` 调用 | 仅测试使用 |
| `QueueLog.size` | `QueueLog.cj:213-221` | 仅 `QueueLog_test.cj:185-240`；文档 `详细设计.md:340` 称用于生产「快速判断」 | 仅测试使用 |
| `QueueManager.hasLocalQueues` | `QueueManager.cj:208-217` | 0 调用 | 完全死代码 |
| `MQMatcher.topicOf` | `MQMatcher.cj:76-78` | 0 调用 | 完全死代码 |
| `GroupCursor.pendingCount` / `unreadableSkipped` / `noMatchSkipped` / `unsupportedSkipped` | `GroupCursor.cj:98-110`、`:325-349` | 仅测试读取；未进入 `stats`/`metrics`/日志 | 仅测试使用的观测面（M8） |
| `DeadLetterQueue.iterate` | `DeadLetterQueue.cj:43-45` | 生产 0 调用（仅两个测试夹具） | 机制存在但无生产入口（Q3 已文档化） |
| `MQMatcher.matchesTags` | `MQMatcher.cj:80-90` | 生产内部调用 + 测试直调 | 合理 |

### 4.2 不可达分支 / 未使用 import / 测试内死代码

- `QueueLog.cj:305` `length < 0`：`getInt32BE` 把 4 字节按 `Int64` 无符号拼装，返回值恒在 `0..0xFFFFFFFF`，该条件不可达（S2）。
- `ConsumeService.cj:203` `catch (e: QueueCorruptionException)`：`openRecordsFrom` 不抛该异常（`QueueCorruptionException` 仅在 `QueueLog.cj:179` 由 `scanAfter` 抛出），该捕获分支不可达（交叉参照，R4）。
- `MQMatcher.cj:18` `import fountain::f_data.DataAny`：文件中无显式使用（`filter.matches(body.data)` 由类型推断），未使用 import（S2）。
- `CursorCatalog_test.cj:35` `private let root = TestDirs.of(...)`：全文件未使用（仅 `freshDir` 生效），测试内死字段（S2）。
- 未发现被注释掉的代码块；未发现 `@Deprecated`。

---

## 五、发现

### [严重] C1 位置恰为段末尾时，下一次读取把后继段的记录头当成本段剩余字节，判为损坏且游标永久停摆

- **位置**：
  - `fmq/src/queue/QueueLog.cj:106-121`（`startPositionOf` 对 `position.seq` 存在时原样返回，不归一化 `offset == meta.size`）
  - `fmq/src/queue/QueueLog.cj:303-311`（`remaining = meta.size - offset - PREFIX_SIZE` 为负 → `corrupt`）
  - `fmq/src/queue/GroupCursor.cj:402-418`（`advance()` 在快照末尾把游标停在 `(seq, meta.size)`）
  - `fmq/src/queue/GroupCursor.cj:226-237`（损坏时仅记 ERROR、返回 `None`，不触发 `recoverIfSegmentGone`）
  - `f_io/src/SegmentedLog.cj:666-671`（`available <= 0` 时跳过该段，直接读下一段）
- **现象**：消费到段末尾并全部确认后，`committed` 正常落在 `(seg, meta.size)`（这是「排空到段尾」的常态，不是异常态）。
  随后该段被封口（下一条不适合放入而轮转），或重启后新段已有数据时：
  `openRecordsFrom((seg, size))` → `startPositionOf` 认为段仍在 → `openEntryStream(seg, size)` →
  `ChainedSegmentStream` 跳过零可用字节的旧段、返回下一段字节 → `QueueRecordReader.seq` 仍是旧段号 →
  `remaining = size - size - 4 = -4` → `corrupt("declared length N exceeds remaining -4")`。
  `GroupCursor` 每轮都用同一位置重开，于是每轮 ERROR + `None`，**该队列对该组永久不可消费**；
  `stats` 以相同位置开流（`ConsumeService.cj:201-205`）同样抛 `INTERNAL`。
- **复现路径（可用小段稳定复现）**：`maxFileSize = 2*(4+28)=64`，追加 2 条 28B 记录 → 确认 2 条
  （`committed=(1,64)`）→ 再追加 1 条触发轮转到段 2 → 下一次 `next()` 即命中。
- **影响**：已确认位点落在段边界的组在段轮转/重启后消费停摆，属于数据不可用；现有 83 个用例无一覆盖
  （`catalogFloorTracksCommittedSegments` 已构造出 `committed=(2,size2)` 的状态，只差再追加一条）。
- **建议**：在 `startPositionOf`/`openRecordsFrom` 中把 `offset >= meta.size` 归一化为
  「首个 `index > seq` 的段起点」（无后继段则返回空流）；或在 `QueueRecordReader` 首次 `next` 前
  用 `segments` 校正 `seq/offset`。补用例：排空 → 强制轮转 → 继续消费；以及排空 → 重启 → 继续消费。

### [严重] C2 `segmentedLogMaxSize` 与 `MAX_RECORD_SIZE` 无关联校验，记录大于段上限时越界写

- **位置**：
  - `fmq/src/queue/QueueLog.cj:58-61`（只校验 64 MiB 上界，不结合段上限）
  - `fmq/src/config/MQConfig.cj:306-308`（只校验 `segmentedLogMaxSize > 0`）
  - `f_io/src/SegmentedLog.cj:189-196`（超限先 `rotate()`，随后按 `currentSize=0` 写入）
  - `f_io/src/SegmentedLog.cj:579-585`（`mcopy(mmapPtr + pos, ..., data.size)` 无剩余空间检查）
- **现象**：运维把 `mqServer_segmentedLogMaxSize` 配成小于单条消息（如 1 MiB）时，`append` 轮转后
  把整条记录 memcpy 进按 `maxFileSize` 映射的区域，越过映射长度。
- **影响**：越界写（进程崩溃或相邻映射被破坏），与规格「记录 SHALL NOT 跨段」（`queue-storage/spec.md:226`）
  和「先轮转，再在新段完整写入」（`:259-262`）的承诺相悖；且没有任何用例覆盖「记录接近段上限」。
- **建议**：启动校验 `segmentedLogMaxSize > MAX_RECORD_SIZE`（或 `append` 时按 `maxFileSize - PREFIX_SIZE`
  拒绝并给出明确错误码）；补 1 MiB 记录 + 小段配置的负向用例。

### [一般] M1 零长度头的语义与规格/设计文档相反

- **位置**：`fmq/src/queue/QueueLog.cj:290-294`；文档 `fmq/doc/详细设计.md:366`
- **现象**：实现把长度 0 当作「干净结束」（关闭流、`corrupted=false`、不记 ERROR）；
  规格场景标题为「零长度视为损坏」（`queue-storage/spec.md:244-247`），设计要求 `length <= 0` 视为损坏。
- **影响**：损坏段（被清零的头部）会被静默当作「已读完」，`stats` 输出 `backlog=0` 而不报错；
  `GroupCursor` 的「不可读」路径也因此复用了错误语义（见 M11）。
- **建议**：二者取一并同步文档与用例：改为 `corrupt(...)` 并记 ERROR（推荐，符合「不得伪装成正常结束」），
  或把规格场景改为「零长度 = 流结束」。verify-report S7 已记录但未闭环。

### [一般] M2 损坏记录被当成「段被删除」越过，违反「不得伪装成段被删除」

- **位置**：`fmq/src/queue/QueueLog.cj:68-79`（`readAt` 对损坏与缺段都返回 `None`）；`fmq/src/queue/GroupCursor.cj:152-158`
- **现象**：重投路径 `readAt` 返回 `None` 时统一 `entry.decided = true` + 计数 + WARN，随后 `advance()` 推进 `committed`；
  段仍在但记录头损坏的情况无法与段被清理区分，且 `isCorrupted()` 信息在此路径被丢弃。
- **影响**：损坏记录被静默确认（消息丢失），与 `queue-storage/spec.md:319-322`「段存在但记录损坏 … 不得伪装成
  『段被删除』」相反；同一队列的 `stats` 会因损坏报 INTERNAL，而消费侧却继续前进，两侧行为不一致。
- **建议**：让 `readAt` 返回可区分的结果（如 `Option` + 损坏标记或抛 `QueueCorruptionException`），
  损坏时按规格停止本轮并上报，不要推进 `committed`。

### [一般] M3 「位点段被删」在三处有四种说法，实现与 `consume-semantics` 冲突

- **位置**：`openspec/specs/fmq/queue-storage/spec.md:57-58`、`:75-83`；
  `openspec/specs/fmq/consume-semantics/spec.md:290-310`；`fmq/doc/详细设计.md:789-791`；
  实现 `fmq/src/queue/QueueLog.cj:106-121`、`GroupCursor.cj:503-533`
- **现象**：queue-storage 要求「从最接近的更大段继续 + WARN」；consume-semantics 要求「记 ERROR 后从现存最老段恢复」；
  详细设计写「跳到现存最老的段继续」；实现是「从 `>= seq` 的最小段继续 + WARN」。
  用例 `startingSegmentHoleResumesAtNextSegment`（`GroupCursor_test.cj:502`）断言跳到段 7（前进），
  明确否定了 consume-semantics 的「最老段」。
- **影响**：验收/排障时无法判定哪种行为正确；若按 consume-semantics 实现会重投已确认消息（回退），
  按实现则可能跳过未被确认的旧段（漏消费）。日志级别（WARN/ERROR）也不一致。
- **建议**：以实现的「前进到最近后继段」为准，修订 `consume-semantics/spec.md:294` 与 `详细设计.md:790`，
  并把日志级别统一为 WARN（或 ERROR 并补 ERROR 断言）。

### [一般] M4 `stats` 在「部分段缺失」时静默少算 backlog，不报错

- **位置**：`fmq/src/server/ConsumeService.cj:183-205`、`:209-228`
- **现象**：只在 `segmentsOrEmpty().size == 0` 时抛 INTERNAL；若 `committed` 所在段被删但仍存在后继段，
  `openRecordsFrom` 内部跳段并只记 WARN，`starts` 仍用旧位点比较，最终返回一个偏小的 `backlog`。
- **影响**：违反 `consume-semantics/spec.md:309`「stats 对该组返回错误而非伪造 backlog」与
  `queue-storage/spec.md:58`「MUST NOT 把段缺失解释为积压为 0 而不留痕」的观测要求。
- **建议**：`openRecordsFrom` 返回实际起点后，若 `actual != 请求位置` 则让 `stats` 抛 INTERNAL（或按组标记异常）；
  并补「只删 committed 段、保留后继段」的 `stats` 用例。

### [一般] M5 死信阈值 off-by-one：实际投递次数比规格少一次

- **位置**：`fmq/src/queue/GroupCursor.cj:172-180`
- **现象**：先 `deliverCount++`，再判 `deliverCount > deadMsgThreshold` 就直接入死信并 `continue`，
  本次不再返回给消费者。`threshold=3` 时实际只投递 3 次；规格场景写「被投递 4 次仍未确认 → 进死信」
  （`consume-semantics/spec.md:96-99`），且死信条目的 `deliverCount=4` 与「实际投递次数」不符。
- **影响**：重试次数与规格/用户预期差 1；死信条目的计数失真；`metrics.delivered` 也不含最后一次。
- **建议**：判 `deliverCount >= threshold` 时入死信（保持 3 次实际投递并在第 4 次转死信前上报），
  或把规格改为「超过阈值的那次不投递」；补阈值 3 的精确次数用例（当前只有阈值 1）。

### [一般] M6 `append` 接受 0 长度记录，会把同段后续记录变成不可见

- **位置**：`fmq/src/queue/QueueLog.cj:58-66`（无下界校验）与 `:290-294`（0 头 = 流结束）
- **现象**：`append([])` 写入 4 字节零头；读取端在该位置直接结束，同段其后已写入的记录全部不可见。
- **影响**：一旦内部调用方传入空记录，等价于段内数据截断（`stats` 少算、消费丢失），且无任何日志。
- **建议**：`append` 拒绝 `record.size == 0`（与 `详细设计.md:362`「取值 1..64MiB」对齐），补边界用例。

### [一般] M7 详细设计 §5.8/§5.11/§5.12/§6.4/§6.5/§6.11 与实现漂移

- **位置与现象**：
  - `详细设计.md:337` 与 `:760` 把 `openFrom` 写成游标读流；实现用 `openRecordsFrom`（`GroupCursor.cj:477`），
    `openFrom` 零调用。§5.8 签名块（`:329-344`）缺 `openRecordsFrom`/`segmentsOrEmpty`/`removeById`/`scanAfter`/`countAll`。
  - `详细设计.md:758` 写「`owner = None`」，实现 `GroupCursor.cj:174` 写 `owner = Some(subscription.subscribedId)`。
  - `详细设计.md:864` 称 `backlog/lagMs` 由 `QueueLog.scanAfter(committed)` 计算，实际由 `ConsumeService.stats` 自写扫描；
    `scanAfter` 仅测试调用。
  - `详细设计.md:727-728` 称读取端「抛 `QueueCorruptionException`」，游标路径实际返回 `None` 并记 ERROR（仅 `scanAfter` 抛）。
  - `详细设计.md:448` `CursorStore.init(offsetRoot: String)` 与实现 `metaRoot` 参数名不符；`:446-452` 未列 `removeGroup`/`hasCursor`；
    `CursorCatalog`（`详细设计.md:120` 表内声明）没有 §5.x 详细小节。
  - `详细设计.md:407-433` 未列 `unsupportedSkipped`（实现 `GroupCursor.cj:343-349`）。
  - `详细设计.md:790` 「跳到现存最老的段」与实现/用例相反（M3）。
- **影响**：按文档写调用方会使用不存在的语义；符号清单无法作为「文档-实现一致」的验收基线（任务 29.4 声称逐节核对过）。
- **建议**：以源码为准修订上述 7 处；§5.8/§5.12 的签名块补齐/删除死成员；新增 `CursorCatalog` 小节。

### [一般] M8 规格要求的「跳过计数」只存在于测试，生产不可见

- **位置**：`fmq/src/queue/GroupCursor.cj:325-349`（三个 prop 无生产读取方）；
  `consume-semantics/spec.md:146-152`（无匹配 SHALL 累加计数）、`:256-264`（unsupported 计数）
- **现象**：`unreadableSkipped`/`noMatchSkipped`/`unsupportedSkipped` 只被 `GroupCursor_test` 断言，
  `stats` TSV、`MQMetrics`、日志汇总都不输出。
- **影响**：线上「消息被越过」无法观测，规格的可观测意图未落地；只能靠 DEBUG/WARN 文本 grep。
- **建议**：把三个计数并入 `stats` 行（或 metrics），至少每分钟汇总一条 WARN/INFO；补 `stats` 断言。

### [一般] M9 段缺失 WARN 未限流，全段删除时每次 CONSUME 刷两条 WARN

- **位置**：`fmq/src/queue/QueueLog.cj:112-119`
- **现象**：`startPositionOf` 在段不存在时无条件 WARN；`GroupCursor` 每轮 `next()` 都重新开流，
  因此「位点段被删/目录被删」状态下每次消费产生 1–2 行 WARN。
- **影响**：规格要求「同一位置的重复不可读 SHALL 限流记录，避免刷屏」（`queue-storage/spec.md:287-291`）；
  高频轮询会淹没日志、抬高 I/O。
- **建议**：按 `(topic, queue, seq)` 做一次性/时间窗限流（可复用 `BackupReplicator.warnRateLimited`）。

### [一般] M10 关键场景缺口（Requirement 有、用例无）

- **位置/缺口**：
  1. 1 MiB / 多字节长度头往返：无（`QueueLog_test.cj` 记录 ≤ 96B；`MAX_RECORD_SIZE` 边界仅测 64MiB+1 拒绝）。
  2. 「落盘后可持久」（`queue-storage/spec.md:131-134`）：无 fsync/掉电模拟用例。
  3. 「删除中途崩溃」（`:153-156`）：无。
  4. 死信「组间隔离」（`consume-semantics/spec.md:101-104`）：GroupCursor 无 A 组进死信、B 组仍消费的用例。
  5. 「后加入的匹配订阅」（`:164-167`）：无。
  6. 「已越过的位置 ACK」（`:136-139`）：无（committed 之前、已进死信两种）。
  7. 「段仍在但记录损坏」（`queue-storage/spec.md:319-322`）：无 GroupCursor 层用例。
  8. 「中途失败回滚」的磁盘断言（`:282-285`）：无。
  9. 「跨段不拼接」的正常路径（`:259-262`）：无「记录刚好放不下 → 整条写入新段」断言。
- **影响**：以上多为数据正确性/恢复路径，缺失意味着回归不可见。
- **建议**：按缺口逐条补用例（优先 1、4、6、7、8）。

### [一般] M11 弱断言清单

- **位置/现象**：
  - `GroupCursor_test.cj:267-271` 死信条目只断言 3 个字段；规格要求「原始记录字节、topic、queueIndex、组名、原位置、投递次数、入死信时间」（`consume-semantics/spec.md:106-109`），仅 `DeadLetterQueue_test` 验证了字段往返，未验证真实入死信条目。
  - `GroupCursor_test.cj:578-580` 并发用例只断言 `committed.seq > 1 || offset > 0`，规格要求「`committed` 单调不减」（`consume-semantics/spec.md:213`）。
  - `GroupCursor_test.cj:742-773` 用零长度头模拟「段被清理」，夹具与场景不符（M1）。
  - `QueueManager_test.cj:121-124` 回滚用例未断言磁盘（M10-8）。
  - `DeadLetterQueue_test.cj:133-137` 只断言 `removed >= 1`，未断言具体段号/剩余段数。
  - `QueueLog_test.cj:323-340` 无法证明「未分配 4 GiB」，只能证明不崩溃（可接受，但应注明）。
- **影响**：用例通过不等于规格满足，尤其死信内容与并发单调性。
- **建议**：补齐字段级断言与精确段号断言；并发用例改为在生成线程中记录 `committed` 序列后断言非降。

### [一般] M12 延迟的「未来时间 > 5 分钟视为到期」未写入规格与设计

- **位置**：`fmq/src/queue/GroupCursor.cj:541-557`
- **现象**：`published > current + 5min` 时直接投递并 WARN。规格只说「无法解析发布时间 → 视为到期」
  （`consume-semantics/spec.md:223`），设计 §6.11（`详细设计.md:870-874`）也未提该容差。
- **影响**：真实未来时间的消息（时钟漂移 > 5min）会提前投递，违反「发布时间 + delaying ≤ 当前时间才可投递」；
  行为不可预期且无文档依据。
- **建议**：把容差写入规格与设计（说明仅用于兼容旧版本地时区 id），或改为按 id 版本识别，避免误放行。

### [建议] S1 死代码清理（完整清单见第四节）

- **位置**：`QueueExceptions.cj:41`、`QueueLog.cj:82/148/194/213`、`QueueManager.cj:208`、`MQMatcher.cj:76`
- **说明**：其中 `openFrom` 与 `size` 仍被 `详细设计.md:337/340` 当作生产 API 描述，属「整块死代码仍被当作入口」的文档侧风险。
- **建议**：删除或标注 `@Deprecated` 并给出替代（`openRecordsFrom` / `segmentsOrEmpty`），同步 §4.4/§5.8；
  若 `scanAfter`/`countAll` 仅测试用，改为测试内辅助函数或给 `stats` 复用（后者更符合 doc §6.11）。

### [建议] S2 不可达分支、未使用 import、测试死字段

- **位置**：`QueueLog.cj:305`（`length < 0`）；`MQMatcher.cj:18`；`CursorCatalog_test.cj:35`
- **建议**：删除 `length < 0`（保留上界与剩余校验）；删除未使用 import；删除测试字段。
  另 `ConsumeService.cj:203` 的 `catch (QueueCorruptionException)` 不可达（交叉 R4），建议改为捕获
  `openRecordsFrom` 实际可能抛的异常。

### [建议] S3 `advance()` 的 `remove(at: 0)` 与逐条落盘带来的二次方/IO 放大

- **位置**：`fmq/src/queue/GroupCursor.cj:457-467`、`:313-318`
- **现象**：`entries` 用 `ArrayList` 头删，确认/跳过 N 条是 O(N²) 搬移；扫描阶段每越过一条「不匹配」记录
  都会 `advance()` → `catalog.save()` → 原子写 + fsync。
- **影响**：大积压（百万级）下单次 `CONSUME` 长时间持锁并产生海量小写入，阻塞同组其它消费者。
- **建议**：改用索引游标（`headIndex`）代替头删；`advance()` 仅在 `next()`/`ack()` 返回前落盘一次，
  或在跳过路径批量合并保存。

### [建议] S4 `readUpTo` 分块重复分配 + O(n²) 拷贝

- **位置**：`fmq/src/queue/QueueLog.cj:354-376`
- **现象**：每次循环分配 `size - got` 的临时数组再逐字节拷贝；读取 1 MiB 记录且流返回小块时是 O(n²)。
- **建议**：直接 `stream.read(out[got..size])` 读到目标切片，避免临时数组与逐字节拷贝。

### [建议] S5 两处测试命名与行为不符

- **位置**：`QueueLog_test.cj:486` `openFromMiddleRecordReturnsRemaining`（实际调 `openRecordsFrom`）；
  `GroupCursor_test.cj:428` `removedCommittedSegmentRecoversToOldestSurvivor`（实际是「下一个现存段」，与 M3 语义冲突）
- **建议**：改名或在用例中同时覆盖 `openFrom`/「最老段」（二选一，与 M3 的裁决保持一致）。

### [建议] S6 `DeadLetterReader` 结束语义与资源释放

- **位置**：`fmq/src/queue/DeadLetterQueue.cj:84-103`
- **现象**：EOF 与「解码损坏」走同一 `catch`，都静默 `finished = true`，无法区分「读完了」与「死信段损坏」；
  调用方提前停止迭代时不关闭底层流（`iterate` 返回裸 `Iterator`，无 `close`）。
- **建议**：EOF 单独判断并正常结束；提供可关闭的迭代器或在 `DeadLetterQueue` 内缓存读流；
  补「末尾损坏」用例。

### [建议] S7 文档/任务书引用的规格路径已不存在

- **位置**：任务书 `fmq/doc/spec/fix-fmq-full-audit/specs/...`；规格内 `queue-storage/spec.md:236`
  引用 `openspec/changes/fix-fmq-full-audit/design.md`
- **现象**：变更已归档到 `openspec/changes/archive/2026-10-21-fix-fmq-full-audit/`，
  任务书给出的 `fmq/doc/spec/fix-fmq-full-audit` 目录不存在。
- **影响**：后续复审/验收按文档路径找不到依据；场景「格式写入设计文档」的可检索性下降。
- **建议**：统一引用归档路径，或在 `fmq/doc/spec/` 保留指向归档的索引。

---

### 本轮统计

| 严重程度 | 数量 |
|---|---|
| 严重 | 2 |
| 一般 | 12 |
| 建议 | 7 |

（另：83 个 `@TestCase`，无禁用/空用例；死代码符号 8 个，其中 2 个仍被设计文档描述为生产 API。）

### 总评

队列存储与消费语义的主体实现质量较好：段格式与长度头上界的校验顺序正确（先校验后分配）、
游标「连续前缀推进 + 乱序留洞」实现干净、延迟投递与 Unsupported BODY 的出口符合规格、
死信自描述与独立 TTL 落地、`openTopic` 的并发与回滚逻辑完整，配套用例覆盖面在 fmq 各子系统中属于较好水平。

但本轮发现两个必须修复的缺陷：

1. **C1** 是真正的正确性缺陷：`committed` 落在段末尾是排空队列的常态，随后段轮转即触发「永久损坏」，
   而现有用例刚好停在触发点之前（`catalogFloorTracksCommittedSegments` 已构造出该状态）。
2. **C2** 是配置与实现之间的空白：`segmentedLogMaxSize` 小于单条记录时会越界写，且没有任何用例覆盖
   「记录接近/超过段上限」。

此外，文档漂移集中在 `详细设计.md` 的 §5.8/§5.11/§6.5/§6.11（`openFrom`、`owner`、`scanAfter`、
「抛损坏异常」四处），以及两份规格对「位点段被删」的互相矛盾描述（M3）——这会让后续维护者按错误前提改代码。
建议优先修 C1/C2，其次统一 M1/M2/M3 的语义与文档，再补 M10 列出的 9 个场景用例；
其余为可读性、性能与文档索引改进。
