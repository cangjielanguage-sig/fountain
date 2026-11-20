# R2: 复审 fmq 元数据与集群

审查时间：2026-10-21 19:40

### 审查范围

代码（HEAD `22c13ec4`，只读）：

- `fmq/src/meta/AtomicFile.cj`、`MQAssignment.cj`、`MQFileNames.cj`、`MetaStore.cj` 及其 4 个 `*_test.cj`
- `fmq/src/cluster/BackupReplicator.cj`、`FakeTransport_test.cj`、`LogCleaner.cj`、`MQNodeTransport.cj`、`MetaSyncer.cj`、`NodeRegistry.cj` 及其测试（共 102 个 `@TestCase`）
- 交叉参照（判定行为/覆盖用）：`fmq/src/server/MQServer.cj`、`MQCommandExecutor.cj`、`ConsumeService.cj`、`BackupStore.cj`、`fmq/src/queue/QueueManager.cj`

文档/规格：

- `fmq/doc/详细设计.md`（§3、§4.3/§4.5、§5.3–§5.6、§5.14–§5.16、§6.2/§6.3/§6.8/§6.9）
- `openspec/specs/fmq/metadata-cluster/spec.md`（8 个 Requirement）
- `openspec/changes/archive/2026-10-21-fix-fmq-full-audit/specs/fmq/metadata-cluster/spec.md` + `tasks.md`/`verify-report.md`

> 注：范围文件给出的 `fmq/doc/spec/fix-fmq-full-audit/**` 在本 worktree 不存在，实际内容位于 `openspec/changes/archive/2026-10-21-fix-fmq-full-audit/`，已按该路径审查。

### 结论摘要（对应四项必答）

1. **文档-实现一致性**：核心布局、路径、默认值、`revision/origin`、墓碑 TTL、反熵周期、备份批处理阈值均一致；**不一致 4 处**：`MetaStore.init` 缺 `nodeCount`、`removeTopic` 返回类型、`NodeRegistry` 公开面（`self` vs `selfIndex`、缺 `isKnownDead`/`onRevived`）、`LogCleaner` 失败日志级别（规格要求 ERROR，实现 WARN）。另 `MQNodeTransport` 注释称广播会跳过已知死亡节点，实现明确不跳过（自相矛盾）。
2. **Requirement/Scenario 覆盖**：8 个 Requirement、约 60 个 Scenario 中 49 个有直接用例，5 个只有等价/部分用例，6 个无用例（详见矩阵）。「勾选但无用例」2 处：`tasks.md:26.1`（某段删除失败 + 死信仍清理）、`tasks.md:W12/W29`（`states` 数量校验，被错误归到 `backupCursorRebuildsConsumerCursor`）。弱断言 3 处（见 G8）。
3. **空测试/空函数**：本范围 **未发现** 空 `@TestCase`、`@Assert(true)`、`@Ignore`/禁用用例、`NotImplemented` 桩、空函数体。`FakeTransport_test.cj` 无 `@TestCase`，但它是测试替身文件，不属缺陷。
4. **死代码**：1 个不可达分支、7 个仅测试使用/无生产消费者的符号、1 个无调用方的参数、1 个无消费者的协议字段（见 G7）。

### 发现

#### [严重] 墓碑不参与接受判断，已删除的主题/组可被迟到的低版本变更复活

- **位置**：`fmq/src/meta/MetaStore.cj:224-248`（`applyTopic`）、`fmq/src/meta/MetaStore.cj:250-286`（`applyGroup`）、`fmq/src/cluster/MetaSyncer.cj:382-413`（`mergeSnapshot` 先应用墓碑、再应用条目）
- **现象**：`applyTopic` 在 `topicIndex` 无该主题时直接 `writeAtomically` + `topicIndex.add`，全程不查 `tombstones`；`applyGroup` 同理。`mergeSnapshot` 即便刚从快照/本地应用了 revision 更高的墓碑，随后也会把快照里残留的旧条目写回。已删除组被迟到广播（如 rev 2 < 墓碑 rev 7）命中时会重新落盘；已删除主题被旧 peer 快照（快照含该主题、本地墓碑 rev 9 更高）命中时会重新落盘并触发 `notifyTopicApplied` → `QueueManager.openTopic` 与 `MQCommandExecutor` 的 `queues.openTopic`，随后该主题重新接受发布。
  仓库内唯一的防复活判断在 `MetaSyncer.applyRemoteGroup:285`，且只在 `TopicMissing` 分支才查 `topicTombstone`，对「主题已复活」与「主题条目迟到」都不生效。
- **影响**：违反 `metadata-cluster` 规格「删除 MUST 以墓碑传播」「旧节点删除不复活」「MUST NOT 继续为该主题打开队列」。墓碑机制对**乱序广播**和**旧 peer 快照**两条主路径失效，会产生删不掉的主题、已删主题重新积压消息、以及节点间的长期不一致（本地再次持有主题但所有 peer 认为已删除）。现有 102 个用例无一覆盖「墓碑之后到达低版本条目」。
- **建议**：`applyTopic`/`applyGroup` 在写入前查同 key 墓碑，`tombstone.revision >= meta.revision`（同 revision 再用 origin 比较）时返回 `Duplicated`（或新增 `Tombstoned`）且不落盘；`mergeSnapshot` 在应用条目后对每个 key 复用同一判定；补用例：先 `removeTopic`/`removeGroup`，再投递低 revision 条目与包含该条目的旧快照，断言 `topicOf`/`groupExists` 仍为空且未打开队列。

#### [严重] `applyTombstone` 版本比较失败时仍删除本地条目，导致数据被「输掉的墓碑」清掉

- **位置**：`fmq/src/meta/MetaStore.cj:340-368`
- **现象**：`applied` 由 `isNewer(tombstone.revision, tombstone.origin, existing.revision, existing.origin)` 决定，但随后删除条件只比较 revision：`if (local.revision <= tombstone.revision) { dropTopicLocked(...) }`。当墓碑与本地条目 **revision 相同、origin 更小**（版本比较判负、`applied=false`、墓碑不落盘）时，`local.revision <= tombstone.revision` 成立，条目仍被删除。组墓碑同理（`:359-366`）。经 `MetaSyncer.applyRemoteTombstone:362-368` → `notifyDeletedIfGone` → `cleanupAfterDelete`，还会连带删除队列目录、游标、订阅与指标。
- **影响**：并发「注册」与「删除」在同一 revision 上竞争时，持有较新 origin 的节点会把活着的主题/组删掉，且本地不保留任何墓碑记录（无法自愈，只能等下一次同步），属数据丢失与一致性破坏。规格与代码注释（`:331-335`「按 revision 只进不退」）都要求墓碑输掉比较时不做任何变更。现有用例 `tombstoneRemovesLocalEntryOnlyWhenOlder` 只覆盖 3 vs 4、3 vs 9，未覆盖同 revision 不同 origin。
- **建议**：删除条件改为 `applied && local is not newer than tombstone`（或直接复用 `!isNewer(local.revision, local.origin, tombstone.revision, tombstone.origin)`）；补用例「本地 rev5/origin2 条目 + 墓碑 rev5/origin0 → 条目保留、墓碑不入库」。

#### [一般] 快照合并把「畸形条目」当成「对端已删除」，误删本地元数据并清理队列

- **位置**：`fmq/src/cluster/MetaSyncer.cj:383-386`、`:399-402`、`:420-439`
- **现象**：畸形主题/组在校验失败时 `continue`，没有加入 `topicNames` / `groupKeys`；随后的缺失扫描以 `!topicNames.contains(...) && revision <= snapshot.revision` 判定为「对端已删除」，调用 `dropTopicLocally`/`dropGroupLocally` 并 `notifyDeleted`。
- **影响**：一个发送畸形载荷（或版本较旧、数据残缺）的 peer 就能让本节点删除合法主题，并触发 `cleanupAfterDelete` 删除队列段目录与游标——把「拒绝畸形数据」的保护变成了「畸形数据触发删除」。用例 `malformedSnapshotEntriesAreSkipped` 只断言畸形条目未被加入，未构造「本地已有同 key 条目」的前置状态，因此该路径无用例。
- **建议**：畸形条目在缺失扫描中按「存在但不可用」处理（记录到一个 `unusable` 集合并从删除候选中排除），或缺失扫描只对「快照中出现过的合法 key 全集」取补。

#### [一般] `MetaStore.load()` 不按已落盘墓碑收敛，崩溃窗口后已删条目会复活

- **位置**：`fmq/src/meta/MetaStore.cj:91-105`（加载顺序）、`:647-660`（`loadTombstones` 只填 map）
- **现象**：`removeTopic`/`applyTombstone` 的顺序是「先写墓碑 → 再删文件」。若在两步之间崩溃（或删除抛错，如 `dropTopicLocked:546-557` 中 `remove` 失败），重启后 `loadTopics` 会把条目重新载入，`loadTombstones` 只把墓碑放进 map，二者不做收敛。
- **影响**：墓碑持久化原本用于「重启后删除仍生效」，此窗口下删除丢失：主题重新可发布，墓碑却仍留在快照里，节点间出现「条目与墓碑共存」的非法状态（直到下一次同步）。规格 Scenario「墓碑往返」只覆盖无崩溃的正常路径。
- **建议**：`load()` 末尾统一收敛一遍：对每个墓碑，若同 key 条目 revision 不高于墓碑则删除条目（复用与 `applyTombstone` 相同的判定），并补「墓碑文件 + 主题文件同时存在」的加载用例。

#### [一般] `LogCleaner` 的失败日志级别与粒度不符合规格（WARN 汇总、无逐对象 ERROR）

- **位置**：`fmq/src/cluster/LogCleaner.cj:114-119`（`log.warn("cleanup skipped N object(s): ...")`）
- **现象**：规格要求「单个失败 SHALL 记 ERROR（含主题/队列/段）」「一轮结束 SHALL 汇总删除数 / 失败数」（spec `:430-432`、Scenario `:434-437`）；实现把全部失败合并成一条 WARN，删除数与失败数分别打印（`log.info("removed N expired segments")` / `log.warn`），没有 ERROR，也没有段级定位（只有 `topic/queue#index(message)` 拼在 WARN 文本里，级别不符）。文档 `fmq/doc/详细设计.md:490-500` 未提 ERROR 要求，§5.14 与规格本身也不一致。
- **影响**：按告警级别做运维筛选时清理失败会漏报；与规格、`tasks.md:26.3`「实现逐对象 try/catch + 汇总日志」的承诺不完全一致。
- **建议**：每个失败对象记 ERROR（含 topic/queue/segment 与异常消息），轮末用一条 INFO 汇总「removed=X failed=Y」；同步修订 §5.14。

#### [一般] 规格「单段删除失败」「死信清理继续」两个 Scenario 无用例，`tasks.md:26.1` 属勾选但未落实

- **位置**：`fmq/src/cluster/LogCleaner_test.cj:254-292`（`oneQueueFailureDoesNotStopOthers`）
- **现象**：该用例注入的是 `floorOf` 抛异常（整队列被跳过），不是「某段 `removeById` 抛异常、同队列其它段仍被删」；也没有任何用例让 `deadLetter.cleanExpired` 抛异常来验证「普通队列失败时死信仍清理」（现用例 `deadLetterUsesItsOwnTtl` 不含失败注入）。`tasks.md:26.1` 声称「某段删除抛错时其它段与死信仍被清理，日志含失败段」，实际无对应用例，日志亦未被断言。
- **影响**：`cleanOnce` 内层的段级 try/catch（`LogCleaner.cj:75-80`、`:97-102`）与死信 try/catch（`:109-113`）从未被失败的用例触发，回归时这两层隔离可能被静默破坏。
- **建议**：用「段号 = 当前段」触发 `removeById` 抛 `IllegalArgumentException`（f_io 对当前段拒绝删除），断言同队列其它段被删且 `removed >= 1`；再注入 `DeadLetterQueue` 失败（可通过注入抛错的 collector 或删除死信目录制造失败）断言普通队列仍完成清理。

#### [一般] 备份接收端「`states` 与记录数不一致」的分支完全无用例，且台账记录与事实不符

- **位置**：`fmq/src/server/MQCommandExecutor.cj:249-257`；测试 `fmq/src/server/MQCommandExecutor_test.cj:403-415`
- **现象**：规格新增 Scenario「记录与状态数量不一致 → 记 WARN，仍落盘记录，但不更新位点」（spec `:423-426`）。唯一相关用例 `backupPayloadOnlyWritesCopy` 的 records/states 数量是相等的；`verify-report.md` 的 W12/W29 把该场景归到 `backupCursorRebuildsConsumerCursor`，而该用例验证的是「备份位点重建游标」，与数量校验无关。
- **影响**：这条 ADDED Requirement 的核心防御（数量不一致时不得写位点）没有任何用例；一旦实现退化为「始终写位点」，现有测试全绿。
- **建议**：补用例：`records.size=2, states.size=1, cursors=[{g,2,0}]`，断言 `backupStore.loadCursor(...)` 仍为空、副本记录已追加、日志含不匹配提示。

#### [一般] 「备份真实状态」只用桩验证，真实 `acked` 推导（`ConsumeService.backupStates`）无用例

- **位置**：`fmq/src/cluster/BackupReplicator_test.cj:168-185`（`StubStateSource`，`:347-358`）；实现 `fmq/src/server/ConsumeService.cj:269-308`
- **现象**：规格要求「`acked` SHALL 由『记录位置早于该组 committed』推导，不得硬编码为 false」，并由生产端在 flush 时读取真实游标。现有用例注入固定返回的桩，只证明「载荷透传」；`backupStates`/`backupCursors`/`ackedByAll`（含「无组时视为未确认」「多组取最小 committed」）没有任何直接用例。
- **影响**：规格最核心的「备份不带假状态」缺少对真实实现的回归锚点；`ackedByAll` 在多组场景下的边界（`<=` 与 `<` 的选择）无法被验证。
- **建议**：在 `ConsumeService_test` 里直接构造两个组（一个已 ack 到位置 P、一个未 ack），断言同一位置得到的 `acked=false`；单组 ack 后为 `true`；无组时为 `false`；并断言 `backupCursors` 每组一条且位点等于 `positionOf`。

#### [一般] 组载荷校验失败不记 WARN，与「校验失败 SHALL 记 WARN（含主题与失败字段）」不符

- **位置**：`fmq/src/cluster/MetaSyncer.cj:281-292`（`applyRemoteGroup` 对 `Invalid` 无日志）、`:264-268`（主题 WARN 不含失败字段）
- **现象**：规格 `:373-375` 要求任何远端载荷校验失败「返回 `Invalid`，记 WARN（含主题与失败字段）」。实现中组名非法时 `store.applyGroup` 返回 `Invalid` 后直接返回，无任何日志；主题的 WARN 只有 `topic` 与 `origin`，没有指出哪个字段越界。
- **影响**：线上出现畸形广播时无迹可查；与 `tasks.md:16.2`「记 WARN（含主题与失败字段）」的验收口径不一致。
- **建议**：`applyRemoteGroup` 在 `Invalid` 分支记 WARN（topic/group）；`MQAssignment.validate` 改为返回失败原因（或提供 `validateReason`），由 `applyRemote` 打印具体字段。

#### [一般] 备份部分目标失败不重试，副本在失败节点上永久缺失（且备份无反熵补偿）

- **位置**：`fmq/src/cluster/BackupReplicator.cj:169-180`
- **现象**：一批数据对多个 target 逐个 `send`，只要 `delivered > 0` 就不进入 `retry`；失败 target 的记录被丢弃。规格「发送失败 SHALL 把批次重新入队并按上限重试」、文档 §6.8:830「失败批次 attempts++ 后放回队首」都按「批次」描述，未说明这种部分成功语义。
- **影响**：`backup=2` 且其中一个后继短暂不可达时，该节点永久缺失这批副本，而备份链路没有类似元数据的反熵补偿；恢复时若恰好切换到该节点会丢这段数据。
- **建议**：按 target 维护重试（记录 target→已发送位置），或对失败 target 单独重发同一 payload，并在文档中明确「部分成功不重发」的取舍。

#### [一般] 备份 `close()` 只等 500ms，慢后继时在途批次回队后无人 drain，与文档「等当前批次」不符

- **位置**：`fmq/src/cluster/BackupReplicator.cj:268-279`；文档 `fmq/doc/详细设计.md:534`
- **现象**：`close()` 轮询 `workerRunning`，最多 50×10ms；而单次发送超时上限是 `pingTimeout*5`（`NodeRegistry.send:150`，默认 5s）。若工作线程仍在 `sendBatch`，`close()` 会继续执行 `flushOnce()`，随后在途批次失败被 `requeue` 到 `pending`，此时已无任何线程会再 flush。文档声明「停止定时器 → 唤醒工作线程 → 等当前批次 → 最后 drain 一次」。
- **影响**：关闭时最后一批可能悄无声息地留在内存（`pendingCount>0` 但无人检查），与「关闭前做最后一次 flush，记录全部发出」的规格承诺不符。
- **建议**：`close()` 改为等待工作线程真正退出（或用可中断信号 + join 语义），并在 drain 后断言 `pending` 为空；若允许丢弃，至少记 ERROR 带上条数。

#### [一般] 主题重新注册不清理墓碑：墓碑永久保留、持续随快照扩散；对应 Scenario 无用例

- **位置**：`fmq/src/meta/MetaStore.cj:173-191`（`registerTopic` 不触碰 `tombstones`）、`:406-427`（GC 的 `resurrected` 分支会永久保留被更高 revision 覆盖的墓碑）
- **现象**：规格 Scenario「新注册覆盖墓碑」允许「墓碑被移除或标记为已复活」，实现两者都没做：墓碑留在 map 与磁盘、进入每份快照、`tombstoneFloor` 被压低，且 GC 因 `local.revision > tombstone.revision` 永不回收。`applyRemoteGroup` 的 `topicTombstone` 检查也仍会命中该主题。
- **影响**：墓碑数量随「删除-重建」次数单调增长，快照体积与同步成本上涨；`topicTombstone(topic)` 对已重建主题返回 `Some`，语义上「主题已删」的判断不再可靠。规格 Scenario 目前只有组维度的等价用例（`deletedGroupCanBeRecreatedWithHigherRevision`），主题维度无用例。
- **建议**：`registerTopic` 在新分配 revision 高于主题墓碑时删除该墓碑（含文件）；补「删除主题 → 更高 revision 重新注册 → `allTombstones`/`snapshot().tombstones` 不含它」的用例。

#### [一般] 死代码：不可达分支 + 7 处仅测试使用/无消费者的符号 + 1 个空转参数 + 1 个无消费者的协议字段

- **位置与现象**：
  1. 不可达分支：`fmq/src/cluster/MetaSyncer.cj:408-410` 的 `case MetaApplyResult.Conflict`——`MetaStore.applyGroup`（`:250-286`）只会返回 `Applied/Duplicated/TopicMissing/Invalid`，该分支永不执行。
  2. 仅测试使用：`MQAssignment.ownersOf`（`fmq/src/meta/MQAssignment.cj:99`，生产无调用方）、`NodeRegistry.nodeAt`（`:104`）与 `indexOf`（`:177`）、`MetaSyncer.pendingPeerCount`（`:101`）、`BackupReplicator.pendingCount`（`:80`）与 `flush`（`:119-121`，生产仅经 `flushOnce`）。
  3. 无消费者状态：`MetaSyncer.pendingPeers`（`:46`、`:474-484`）只累加/清空，从未参与选点、指标或日志，唯一读数是 `pendingPeerCount` 的用例断言。
  4. 无调用方赋值：`LogCleaner.start(now!: () -> DateTime)`（`fmq/src/cluster/LogCleaner.cj:123`）的生产与测试调用都不传 `now`。
  5. 无消费者字段：`MQMetaSnapshot.tombstoneFloor`（`f_mq/src/base/payload/MQMetaSnapshot.cj:34`）由 `MetaStore.snapshot:471` 计算、序列化，但任何合并/清理逻辑都未读取（仅 `f_mq` 往返用例与本包一条断言）。
- **影响**：`ownersOf`、`nodeAt`、`indexOf` 会被误认为生产 API（文档 §5.4 还把 `ownersOf` 列进签名清单）；`pendingPeers` 与 `tombstoneFloor` 增加了维护与序列化成本却不产生行为；不可达分支掩盖了「组冲突本该被处理」的设计缺口（组根本没有 `Conflict` 语义）。
- **建议**：删除或改用（`ownersOf`/`nodeAt`/`indexOf` 若无计划就删；`pendingPeers` 接入指标或删除；`tombstoneFloor` 要么用于「快照缺失兜底」的判定，要么从协议中移除）；`applyGroup` 若确需 `Conflict` 就在 `sameGroup` 比较处返回它，否则删除该分支并同步文档。

#### [建议] 文档签名与实现不符（4 处）

- **位置**：`fmq/doc/详细设计.md:205`、`:221-222`、`:506-518`、`:490-500`；`fmq/src/cluster/MQNodeTransport.cj:33-38`
- **现象**：
  1. `MetaStore.init(metaDir, origin!)` 缺少实现中的 `nodeCount!: Int64 = 0`（`MetaStore.cj:82`）。
  2. `removeTopic(topic): ?MQMetaTombstone` 与实现 `Array<MQMetaTombstone>`（`MetaStore.cj:294`）不符；`removeGroup` 的返回值正确。
  3. `NodeRegistry` 文档写 `prop self`，实现是 `selfIndex`（`NodeRegistry.cj:82`）；文档缺 `isKnownDead`、`markFailed`、`onRevived` 与 `clientBuilder!` 参数；`init` 的 `checkDuration/pingTimeout` 实际带默认值。
  4. `MQNodeTransport` 注释「广播据此跳过已被判定不可达的节点（A40）」，而 `MetaSyncer.broadcast:465-467` 明确「不按已知死亡跳过」；用例 `knownDeadPeerIsSkippedAndCompensatedByAntiEntropy:639` 断言的正是「不跳过」（`attemptCount()==2`），用例名与断言相反。
- **影响**：按文档调用 `removeTopic` 会编译失败；读者会误判广播的容错策略（这是 A40 的核心取舍）。
- **建议**：逐条对齐文档与注释；把用例改名为 `knownDeadPeerIsStillTriedAndCompensatedByAntiEntropy`。

#### [建议] 用例弱断言 3 处

- **位置**：`fmq/src/meta/AtomicFile_test.cj:81-103`、`fmq/src/cluster/BackupReplicator_test.cj:150-165`、`fmq/src/cluster/MetaSyncer_test.cj:758-770`
- **现象**：
  1. `fsyncFailurePropagates` 通过 `trace` 回调在 `fsync(file)` 步骤抛异常，异常发生在 `file.flush()` **之前**（`AtomicFile.cj:53-55`），验证的是「写入路径异常不 rename」，不是「fsync 失败向上抛」。
  2. `slowReplicasDoNotBlockPublish` 以「200 条总计 < 1000ms」断言，规格是「每次 publish 在 50ms 内返回」，阈值宽 4 倍×条数，阻塞 4ms/条也能通过。
  3. 规格「重复应用幂等且不转发」只断言了 `Duplicated`，没有断言 `transport.sentCount()` 未增长。
- **影响**：三条失败路径的回归保护弱于其命名/规格承诺。
- **建议**：fsync 用「只读目录/关闭 FD」等真实失败注入，或至少断言 `.tmp` 残留与正式文件缺失；慢后继改为逐条计时取最大值；补 `sentCount` 断言。

#### [建议] 反熵选点实现与规格措辞不一致（随机 vs 确定性分层）

- **位置**：`openspec/specs/fmq/metadata-cluster/spec.md:176`；`fmq/src/cluster/MetaSyncer.cj:219-235`
- **现象**：规格写「向随机 peer 做一次反熵同步」，实现是确定性三趟（未知→存活→已知死亡）顺序遍历，取第一个可用快照即返回。行为上收敛性更好且可测（`antiEntropyPrefersUnknownThenAliveThenDead`），但与规格字面不符。
- **影响**：文档-实现一致性判定不通过；不影响正确性。
- **建议**：修订规格为「按『未知→存活→已知死亡』优先级选择 peer」，或说明随机化是可选项。

#### [建议] 其他可维护性问题

- **位置与现象**：
  1. `fmq/src/cluster/MetaSyncer.cj:220-255`：三趟循环内层缩进错位（`for (offset ...)` 体未缩进），可读性差，易在后续修改中引入括号错误。
  2. `fmq/src/cluster/MetaSyncer.cj:165-173`：`match (store.groupsOf(...)) { case list => ... }` 用不可证伪的单分支 `match` 代替 `for`，属无意义构造。
  3. `fmq/src/cluster/NodeRegistry.cj:186-204`：`markSeen` 在**发送线程**内同步调用 `revivedCallback`（装配为 `syncer.syncFromPeers`），会在广播路径中嵌套触发一次全量同步（每次新节点首次成功一次），放大首连延迟；建议改为入队/异步触发。
  4. `fmq/src/cluster/NodeRegistry.cj:120-135`：`clientOf` 在持 `lock` 的情况下执行 `buildClientFn`（可能建连），会阻塞其它节点的发送。
  5. `fmq/src/meta/MetaStore.cj:629-634`：`nextRevisionLocked` 每次写变更都做一次 `maxRevisionLocked()` 全量扫描（`:607-627`）并对 `revision.meta` 做一次 fsync；`removeTopic` 级联 G 个组墓碑就是 1+G 次 O(n) 扫描 + fsync（`:294-316`）。建议维护内存 `maxRevision` 增量值。
  6. `fmq/src/meta/MetaStore.cj:581-584`：墓碑 `deletedAtMs` 取本机墙钟并随广播/快照传播，对端按自己的 `nowMs` 计算年龄；节点时钟超前后会让远端墓碑被提前回收（再次引入复活风险）。建议以 `revision` 或对端时钟校正兜底。
  7. `fmq/src/cluster/BackupReplicator.cj:238-241`：`start()` 非幂等，重复调用会起两个工作线程（`MetaSyncer.startAntiEntropy` 有幂等保护，二者不一致）。
  8. `fmq/src/meta/MetaStore_test.cj:452-484`：`concurrentDifferentTopicsGetDifferentStarts` 的 `finally` 为空，既未 `store.close()` 也未 `clean(dir)`，与前 20 余个用例的约定不一致（临时目录残留、句柄泄漏）。

### Requirement → 用例矩阵

| Requirement | Scenario | 判定 | 证据/缺口 |
|---|---|---|---|
| 队列轮转分配 | 规格示例逐字复现 | 有 | `MQAssignment_test.specExampleIsReproduced` |
| | 单节点 / 单队列环绕 | 有 | `singleNodeGetsEverything` / `singleQueueWrapsAround` |
| | 非法队列数 → 注册回 ERROR | **缺** | `invalidQueueCountThrows` 只测纯函数；`MetaSyncer` 的 `queueNum<1 → INVALID_TOPIC` 无注册路径用例 |
| | 远端节点推进指针 | 有 | `remoteApplyAdvancesRoundRobinPointer` |
| 元数据目录与原子写 | 路径布局 / 编码无碰撞 | 有 | `pathLayoutMatchesSpec` / `encodingHasNoCollision`（+可逆） |
| | 原子写（`.tmp` 残留） | 有 | `atomicWriteSurvivesStaleTmp`、`repeatedWritesLeaveNoTmpFiles` |
| | 掉电后不为空文件 | 部分 | `writesInFsyncOrder` + 重载用例；无真实掉电/失败 fsync 注入（见弱断言） |
| 元数据持久化与内存索引 | 重建后一致 / 重复注册 / 默认组 / 级联删除 / 孤儿组 / 快照完整 / 损坏跳过 | 有 | `persistenceReloadsEverything`、`duplicateAndConflictHandling`、`deleteTopicCascadesGroups`、`orphanGroupsAreDroppedOnLoad`、`snapshotContainsAllEntries`、`corruptedFilesAreSkipped` |
| | 并发注册同一/不同主题 | 有 | `concurrentRegisterTopicOnlyOneWins`、`concurrentDifferentTopicsGetDifferentStarts` |
| 元数据全量复制 | 注册后各节点一致 | 有 | `registerTopicAllocatesAndBroadcasts` |
| | 重复应用幂等且**不转发** | 部分 | 幂等有断言，「不转发」未断言 |
| | 冲突保留先到者 | 有（弱） | `sameRevisionKeepsFirstAndWarns`、`snapshotConflictKeepsLocal`；WARN 未断言 |
| | 注销复制 | 有（弱） | `deregisterTopicAndGroup` 只数消息条数，未解码墓碑内容 |
| | 离线节点重启后删除仍生效 | 有 | `snapshotMergeDropsTopicDeletedWhileOffline` + `topicTombstoneFromPeerClearsLocalState` |
| | 乱序广播 | 有 | `outOfOrderRemoteDoesNotRewindNextStart` |
| 启动期与恢复期同步 | 补齐缺失 / 全部不可达 / 复活后打开队列 | 有 | `startupSyncMergesSnapshot`、`startupSyncWithAllPeersDownKeepsLocal`、`appliedTopicFromSnapshotOpensLocalQueue` |
| | 反熵补删除 | **缺** | 无「删除广播失败 → 反熵后对端删除」用例；`knownDeadPeerIsSkipped...` 只补新增 |
| | 告警文案准确 | 弱 | `errorResponseDoesNotAbortSync` 只断言最终落地，未断言「不可达 vs 响应不可用」文案 |
| 节点表与身份 | 环形后继 / 不与自身建连 / 从未连上的 peer | 有 | `successorsWrapAround`、`selfNodeHasNoClient`、`revivalTriggersResyncOnlyOnce` |
| | 对端重启后重连（发送成功 + isAlive 翻转 + 重同步） | 部分 | `clientOfRebuildsClosedConnection` 只测重建，未测「send 成功→isAlive true→重同步」链路 |
| | 按端口定位自身 / 自身不在表 / 端口重复 | 不在本范围 | 属 `MQConfig`（R4） |
| 备份副本复制 | 环形后继 / backup=0 / 64 条 / 100ms / 队列满 / 关闭排空 / 单节点故障 / 副本不参与消费 | 有 | `sendsToRingSuccessors`、`backupZeroSendsNothing`、`workerFlushesFullBatch`、`timerFlushesBeforeBatchIsFull`、`fullQueueDropsWithoutBlocking`、`closeFlushesPending`、`onePeerFailureDoesNotBlockOthers`、`backupPayloadOnlyWritesCopy` |
| | 慢后继不阻塞发布 | 弱 | 阈值 1000ms/200 条，非规格的 50ms/次 |
| | 发送失败重试 / 关闭后写入有痕迹 | 部分 | 重试有；「记 WARN（限流，含原因）」未断言日志 |
| | 备份段纳入 TTL | 有 | `BackupStore_test.cleanerReclaimsBackupSegmentsByCursor`（跨文件） |
| 延迟元数据 | 重启保持 / 快照携带 / 远端应用 | 有 | `persistenceReloadsEverything`、`snapshotContainsAllEntries`、`registerTopicKeepsDelayingInAssignmentAndBroadcast`、`remoteApplyIsIdempotentAndKeepsFirst` |
| 元数据版本与墓碑 | 墓碑往返 / 旧节点删除不复活 / 未过期不回收 / 过期回收 | 有 | `deleteWritesTombstoneThatSurvivesReload`、`tombstoneRemovesLocalEntryOnlyWhenOlder`、`tombstoneGcRespectsTtl` |
| | 新注册覆盖墓碑（主题） | **缺** | 只有组维度（`deletedGroupCanBeRecreatedWithHigherRevision`）；实现也不移除墓碑（见一般项） |
| | 墓碑 GC「记 INFO」 | 弱 | 日志在 `MQServer.sweepTombstones:313`，无用例断言 |
| 远端元数据结构校验 | owners 数量不符 / owner 越界 / 组先于主题 / 主题已删后组到达 | 有 | `malformedRemoteAssignmentIsRejected`、`groupArrivingBeforeTopicIsAppliedLater`、`groupIsRejectedWhenTopicIsDeleted` |
| | 失败记 WARN（含失败字段） | 不符 | 组 `Invalid` 无日志；主题 WARN 无字段（见一般项） |
| | owner 为负数 | **缺** | `validateStructure` 有实现，仅加载路径间接覆盖 |
| 备份副本的消费位点 | 状态随备份落地 / 可重建游标 / 位点不回退 | 部分 | 前两项中「状态」仅用桩（见一般项）；`cursorsOnlyMoveForward`、`backupCursorRebuildsConsumerCursor` 有 |
| | 记录与状态数量不一致 | **缺** | 实现 `MQCommandExecutor.cj:249-257`，无用例 |
| 清理器异常隔离 | 单段删除失败 / 死信清理继续 | **缺** | 现用例注入的是 `floorOf` 失败（整队列跳过） |
| | 定时器不中断 | 有 | `timerKeepsRunningAfterFailure` |

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 2 |
| 一般 | 11 |
| 建议 | 4 |

### 总评

元数据与集群这一层的**结构与文档骨架质量较高**：目录布局、百分号编码、原子写顺序、Lamport 版本、墓碑级联、反熵分层、备份批处理与清理器隔离都有清晰的设计依据，102 个用例覆盖了绝大多数正常路径与主要失败路径，未发现空用例、禁用用例、注释代码或未使用 import。

但**墓碑的「一票否决」语义没有落到所有写入路径**：墓碑只在 `applyTombstone` 的当下生效，`applyTopic`/`applyGroup`/`mergeSnapshot`/`load` 都可以绕过它，加上 `applyTombstone` 自身在同 revision 下用 revision 而非 `(revision, origin)` 判定删除，构成两个可能造成「已删主题复活」「活主题被输掉的墓碑删除」的严重缺陷——恰好是本轮规格新增（A25/A35）要解决的问题。这两处都无用例，说明现有覆盖是「按实现写用例」而非「按规格反证」。

次要问题集中在三处：一是快照合并把畸形条目当作删除依据（会把防御逻辑变成删除触发器）；二是日志类承诺（ERROR 级别、WARN 文案、INFO 汇总）在实现与用例两侧都没有落地，导致多条 Scenario 事实上不可验证；三是死代码与文档签名漂移（`removeTopic` 返回类型、`NodeRegistry` 公开面、`MQNodeTransport` 与广播行为的自相矛盾），会让后续维护者按错误契约编码。建议优先修两个严重项并补「墓碑后到达低版本条目」的失败用例，其余按 `todo.md` 排序处理。
