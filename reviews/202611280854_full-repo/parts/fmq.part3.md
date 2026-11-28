# fmq 模块审查报告

> **模块第 3/7 部分**：只覆盖 `files/fmq.part3.txt` 列出的 14 个文件（`doc/详细设计.md`、入口 `MQUsage` 与其用例、`src/Main_test.cj`、`src/cluster/{BackupReplicator,MetaSyncer,LogCleaner,MQNodeTransport}.cj` 及 cluster 包的测试与测试夹具）。队列/游标/服务端装配（`MQServer`、`MQCommandExecutor`、`GroupCursor` 等）由其它部分产出，本报告只在判定本部分语义时引用它们作为上下文。

- **审查日期**：2026-11-28
- **模块路径**：`fmq`（本部分 13 个 `.cj` + 1 个 `.md`）
- **基线**：工作区快照（HEAD `f309f0b55`，无 diff 可比 ⇒ 全部记「存量」；blame：`BackupReplicator.cj` 主体 `f1238ea6c6`/`bcd6b73ee9`/`64a25ed2a1`(2026-10-18～10-21)，`MetaSyncer.cj:422-432` 缺失扫描 `fee913b690`/`149b65a8bd`(2026-10-21)）
- **审查重点**：投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑
- **报告版本**：v1（第 3/7 部分；与同模块其它部分合并为 `docs/review/2026-11-28/fmq.md`，本报告不写该文件）

## 发现

### [严重][存量] 反熵「快照缺失即删」把「漏收一次广播」变成删除：对端快照里没有、而本地 revision 不高于快照 revision 的主题/组会被删掉，并连带删掉消息文件

- **位置**：`fmq/src/cluster/MetaSyncer.cj:422-445`（缺失扫描 `store.dropTopicLocally` / `dropGroupLocally` + `notifyDeleted`）、`fmq/src/cluster/MetaSyncer.cj:239`（`mergeSnapshot(snapshot)` 不记录来源 peer）、守卫条件在 `:427` / `:438`（`assignment.revision <= snapshot.revision`）；`snapshot.revision` 的来源见 `fmq/src/meta/MetaStore.cj:555-556`（`revision: maxRevisionLocked()`）
- **来源**：存量（快照模式，无基线可比；`git blame` 显示缺失扫描来自 `fee913b690`/`149b65a8bd`，2026-10-21）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「检查-然后-写入 / 可见性」；违背 `fmq/src/cluster/MetaSyncer.cj:367` 注释与 `fmq/doc/详细设计.md:304` 的设计意图（「缺失扫描是墓碑被 GC 后的兜底」）
- **证据**：静态确定 —— 三条事实叠加即可推出：
  1. `snapshot.revision` 是该 peer 的**全集群 Lamport 最大值**（`MetaStore.cj:757-777` 取 `revision` 计数器 / 各条目 / 各墓碑的最大值），不是「该 peer 对某个 key 的已知版本」；
  2. 守卫只用 `本地条目 revision <= 快照 revision`，与「该 peer 是否真的应用过这条变更」无关，且合并过程**不知道快照来自谁**（`mergeSnapshot` 无 peer 参数）；
  3. 广播失败是设计里预期的常态（`MetaSyncer.cj:464-476` 失败只 WARN，靠反熵补齐），而反熵的入口 `syncFromPeers → mergeSnapshot` 正好跑在同一个缺失判定上。
- **描述**：举例（无需任何并发）：三节点 A/B/C，A 注册 `/t`（revision 5）并广播，B 收到、C 因重启丢失该帧；随后 B 自己注册一个订阅组（revision 6）。A 的反熵（默认 30s）或 `onRevived` 从 B 拉快照：B 的快照含 revision 6 但没有 `/t` ⇒ `5 <= 6` 成立、无墓碑、B 没把 `/t` 标为畸形 ⇒ A 判定 `/t` **在本机缺失**并删除自己的主题。删除不是只改内存：`notifyDeleted` → `MQCommandExecutor.cleanupAfterDelete`（`fmq/src/server/MQCommandExecutor.cj:224-229`）→ `queues.closeTopic(payload.topic, deleteFiles: true)`，本机队列目录与消息段被物理删除，组游标、订阅、计数器一并清掉。同一条路径对订阅组同样成立（`dropGroupLocally` + 删游标）。也就是说：**「补齐丢失的广播」这一步反而把发起方的变更删掉了**。这次删除不写墓碑（`dropTopicLocally` 只删索引与文件，见 `MetaStore.cj:579-583`），因此既不可追溯、也无法靠重启从盘上恢复；若之后从仍持有该主题的 peer 同步回来，`openTopic` 会重建空队列 ⇒ 留下「元数据在、消息没了」的不一致态。文档把这条兜底描述成「墓碑被 GC 之后的保险」，但墓碑 TTL 默认 7d、段 TTL 72h，正常运维下兜底没有必要，收益远小于误删风险。
- **建议**：把「缺失」与「已删除」解耦——(a) 最小改动：删掉 `:422-445` 的兜底删除，只保留墓碑路径（反熵把「本地有、快照无」记 WARN + 计数，供运维核对）；(b) 若必须保留兜底，则要求「连续 N 轮、来自**不同** peer 的快照都缺失该 key」且「本地条目 revision 严格小于这些快照的 revision」，删除前**先写墓碑**（这样重启与其它节点都能收敛，且可被未来仲裁），并给 `mergeSnapshot` 增加 `fromPeer: Int64` 参数以排除「来源 peer 自己漏收」的情况；(c) 无论哪种，`syncFromPeers` 与本地 `registerTopic/registerGroup`（`MetaSyncer.cj:113-166`）之间需要一把「元数据变更互斥」，否则同一条路径还会与并发注册形成第二个窗口。

### [一般][存量] `BackupReplicator.close()` 与 `record()` 是「锁外检查 + 锁内入队」：关闭窗口内入队的备份永远不会被发送，也没有计入 close 的残留告警

- **位置**：`fmq/src/cluster/BackupReplicator.cj:121-135`（`closed.load()` 在 `synchronized(lock)` **之外**）、`fmq/src/cluster/BackupReplicator.cj:297-311`（`close()` 置位 → 等 worker → `flushOnce()` → 统计 `left`）
- **来源**：存量（`f1238ea6c6` / `bcd6b73ee9` / `64a25ed2a1`，2026-10-18～10-21）
- **判据**：review-checklist §12.1「检查-然后-写入」、§11「资源不对称 / 错误处理缺失」
- **证据**：静态确定 —— `record` 的时序是 `closed.load()==false` →（被抢占）→ `synchronized(lock){ pending.add(...) }`；`close` 的时序是 `closed=true` → 等 worker 退出 → `flushOnce()` 取走当时 `pending` → 读 `left`。若 `record` 在 `close` 的 `flushOnce` 之后才拿到 `lock`，该条目就停在 `pending` 里：既不发送、也不再被任何路径取出，且 `left` 已经读过，`log.error("closed with N unsent")` 不会包含它。测试 `closeWhileFlushingIsSafe`（`BackupReplicator_test.cj:292-329`）在收尾时又调了一次 `flushOnce`，所以覆盖不到这个窗口。
- **描述**：关停期（`MQServer.closeSteps` 先关 `server`、后关 `backup`，仍在执行的 executor 线程可以继续 `publish → record`）最后若干条消息的副本会静默缺失；主节点本地日志仍有记录，因此单故障不丢，但「主节点随后损坏 + 副本接管」时这批消息无副本可用。属于 at-least-once 备份面被降级为「可能少一条」，且日志无痕迹（排障时看不到）。
- **建议**：把 `closed` 判定移进 `synchronized(lock)`，并让 `close()` 在同一把锁内置位；`record` 在锁内看到 `closed` 时直接丢弃并走 `warnRateLimited`（这样已进入临界区的条目一定在 `flushOnce` 之前入队）。若希望「关闭后仍收尾」，可在 `flushOnce` 后二次检查 `pendingCount > 0` 再 drain 一轮，超时再记 ERROR。

### [一般][存量] 备份队列只按「条数」限容、flush 又取走整个积压：按字节无上限，堆峰值 ≈ 积压条数 × 单条上限

- **位置**：`fmq/src/cluster/BackupReplicator.cj:126-130`（`pending.size >= capacity` 才丢弃）、`fmq/src/cluster/BackupReplicator.cj:144-152`（`batch = pending`，一次取走全部，`BATCH_SIZE` 只用于**触发**）、`fmq/src/cluster/BackupReplicator.cj:188`（为整批建 `Array<Array<Byte>>`）；单条上限见 `fmq/doc/详细设计.md:343`（`MAX_RECORD_SIZE = 64 * 1024 * 1024`）
- **来源**：存量（`64a25ed2a1`，2026-10-21）
- **判据**：review-checklist §5「OOM 风险：按不可信长度 / 无界容器 / 一次性物化」
- **证据**：静态确定（上界算术；是否真的触顶取决于副本延迟与记录大小，属运行时条件）
- **描述**：容量只数条目（默认 8192），`BackupItem.record` 持有整条记录的 `Array<Byte>`，单条上限 64MB（`QueueLog.effectiveMaxRecord = min(64MB, maxFileSize-4)`）⇒ 理论峰值 8192 × 64MB ≈ 512GiB；即使记录只有 1MB，也有 8GiB。触发条件是本设计明确要应对的场景：副本慢/不可达时 `flushOnce` 阻塞在 `transport.send`，`pending` 持续堆积；而 `shouldFlush` 一旦成立就把**全部积压**塞进一个 `MQBackupPayload`（文档 §6.8 写的是「64 条或 100ms 时取走整批」，代码里 64 只是触发阈值，不是批次上限），编码时再复制一份整批字节，峰值接近 2×。没有任何按字节的拒绝路径，只有条数。
- **建议**：给 `BackupReplicator` 增加字节预算（`pendingBytes`，`record` 在锁内累加 `record.size`，超过 `capacityBytes` 同样丢弃并留痕），`flushOnce` 取批时按 `min(BATCH_SIZE, 预算内条数)` 截断（剩余留在 `pending` 下一轮发），并按字节而不是条数做告警阈值；`MQBackupPayload` 的构造保持在截断之后。

### [一般][存量] 轮转指针「只增不减」是「锁外读-算-写」：并发注册/反熵会让 `nextStartNode` 回退

- **位置**：`fmq/src/cluster/MetaSyncer.cj:259-263`（`let current = store.nextStartNode` → 比较 → `store.applyTopic(..., nextStart: persisted)`）、`fmq/src/cluster/MetaSyncer.cj:447-449`（`if (snapshot.nextStartNode > store.nextStartNode) store.advanceNextStart(...)`）；被写端 `fmq/src/meta/MetaStore.cj:305-308`（`applyTopic` 内 `this.nextStart = value`）与 `fmq/src/meta/MetaStore.cj:532-537`（`advanceNextStart` 无条件覆盖）
- **来源**：存量（`MetaSyncer.cj:259-263` 来自 `fee913b690` 一系；`MetaStore.advanceNextStart` 为既有实现）
- **判据**：review-checklist §12.1「检查-然后-写入」；违背 `详细设计.md:306`「`nextStartNode` 只增不减」与代码注释 `MetaSyncer.cj:260`（A33）
- **证据**：静态确定 —— `nextStartNode` 的 getter 单独取锁（`MetaStore.cj:211-217`），max 计算在 `MetaSyncer` 里完成，随后 `applyTopic`/`advanceNextStart` 在**新的**临界区里直接赋值，没有 `max(现值, 入参)`。两个写者（本地 `registerTopic` → `MetaStore.cj:232-241` 在自身锁内推进；远端 `applyRemote`/`mergeSnapshot`）并发时，后进入锁的一方会用自己早先读到的旧值覆盖新值。
- **描述**：后果是轮转起点回退，新主题的 `startNodeIndex` 可能与旧主题重复，队列分布不再均匀（`MQAssignment.allocate` 的结果仍自洽，`owners` 长度与范围校验都通过，因此不会立刻报错，只是分配倾斜、且要再等指针重新推进才能纠正）。数据不丢，但 A33 的单调性承诺不成立；在「manager 连续注册 + 反熵/复活同步同时进行」时是可复现的（只是难以用现有用例稳定命中）。
- **建议**：把单调性下沉到 `MetaStore`：`applyTopic` 的 `nextStart` 参数与 `advanceNextStart` 都改成 `this.nextStart = max(this.nextStart, value)`（在锁内比较），`MetaSyncer` 侧不再自行读 `nextStartNode` 做比较；`mergeSnapshot` 直接调用 `advanceNextStart(snapshot.nextStartNode)` 即可。

### [轻微][存量] §1 死代码：`CapturingAppender.clear()` 全仓无引用；`LogCleaner_test.cj` 的 `QueueLog` import 未使用

- **位置**：`fmq/src/cluster/LogCapture_test.cj:90-92`（`static func clear()`）、`fmq/src/cluster/LogCleaner_test.cj:29`（`import fountain::fmq.queue.{..., QueueLog, ...}`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1「无调用者 / 未使用的 import」
- **证据**：静态确定 —— `grep -rn "CapturingAppender\." fmq` 只命中 `install()` / `find()` / `waitFor()`（4 个包的 `LogCapture_test.cj` 各自的 `clear()` 都没有调用点，`CapturingStream.clear()` 只被本文件的 `CapturingAppender.clear()` 调用 ⇒ 整条链无外部引用）；`grep -n "QueueLog" fmq/src/cluster/LogCleaner_test.cj` 只命中第 29 行的 import，文件内 `removeSegment` lambda 的参数类型是推断出来的，未用到该类型名。
- **描述**：两处都是无害残留，但 `CapturingAppender.clear()` 是**唯一**清理日志缓冲的入口，沉睡意味着用例之间共享静态 `lines`（`LogCapture_test.cj:31`）只增不减，`find()` 每次都全量扫描；后续若有人以为「已清理」而补断言，会读到历史行。
- **建议**：删除未使用的 import；`CapturingAppender.clear()` 要么在需要隔离的用例里真正使用（`@BeforeEach`），要么删除。`LogCapture_test.cj` 的四份副本见下一条，收敛后只需改一处。

### [轻微][存量] §2 重复逻辑：`fmq manager --help` 的帮助正文两份逐字节相同，且两份用例各钉同一段文本

- **位置**：`fmq/src/MQUsage.cj:49-68`（`managerHelp()`）与 `fmq/src/manager/MQManagerArgs.cj:91-110`（`helpText()`）——取两条原始字符串内部（`sed -n 51,67p` / `93,109p`）后 `diff` 输出为空；用例 `fmq/src/MQUsage_test.cj:46-68` 与 `fmq/src/manager/MQManagerArgs_test.cj:66-80,97-104` 重复断言同一批子命令名与计数
- **来源**：存量（快照模式）
- **判据**：review-checklist §2「字面量复制 / 跨层复制」，差异点核对：两份文本**无任何**语义差异（不含变量、错误文案、级别差异）
- **证据**：静态确定（逐字节 diff）
- **描述**：两个入口分别在 `main.cj:83`（`fmq manager --help`）和 `main.cj:96`（`MQManagerArgs.parse` 失败时打印帮助）被使用，文本却维护两份；新增/改名子命令时只改一处，就会出现「`--help` 与实际解析不一致」，而且两份用例都只数 `counted == 7`，改一处仍会双双通过（文本内容不同但计数相同）。
- **建议**：`MQUsage.managerHelp()` 直接 `MQManagerArgs.helpText()`（`MQUsage` 已依赖 `manager` 包），用例只保留一份内容断言（另一份改为断言两个入口返回同一字符串）。

### [轻微][存量] §2 重复逻辑：`LogCapture_test.cj` 四份、`FmqTestSetup_test.cj` 三份逐字节相同（只差 `package` 行）

- **位置**：`fmq/src/cluster/LogCapture_test.cj`（本部分）与 `fmq/src/meta/LogCapture_test.cj`、`fmq/src/queue/LogCapture_test.cj`、`fmq/src/server/LogCapture_test.cj`（`diff` 仅第 16 行 `package` 不同）；`fmq/src/cluster/FmqTestSetup_test.cj`（本部分）与 `fmq/src/FmqTestSetup_test.cj`、`fmq/src/server/FmqTestSetup_test.cj`（三份 22 行完全相同）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2「只改类型名 / 跨层复制」；误报边界核对：这是**测试辅助代码**，但四份 100+ 行的同一实现不属于「可读性刻意展开」，且模块已有共享测试包
- **证据**：静态确定（`diff` 逐行）
- **描述**：`fmq/src/test/TestDirs.cj` 已经是跨包共享的测试基础设施（`LogCleaner_test.cj:30` 直接 `import fountain::fmq.test.TestDirs`），说明「共享测试辅助放 `fmq.test`」这条路径是通的；`CapturingStream`/`CapturingAppender` 被 4 个包各抄一份后，任何一处修复（例如上面那条 `clear()` 的用法）都要改 4 处，且 `CapturingAppender.install()` 的 `installed` 是**每包一份**的静态标志（`LogCapture_test.cj:70`），同时安装 4 个同名 appender 的交互无人验证。
- **建议**：把 `CapturingStream`/`CapturingAppender` 移到 `fmq/src/test/`（`fountain::fmq.test` 包，`public`），四个包 `import` 使用；`FmqTestSetup_test.cj` 的 `protocol_hostId` 初值也放到同一处（或在 `TestDirs` 旁提供 `ensureProtocolHostId()`），各包只在 `@BeforeAll` 调用一次。

### [轻微][存量] §2 重复逻辑：`applyTombstone(...) == Applied → notifyDeletedIfGone(...)` 两处同构

- **位置**：`fmq/src/cluster/MetaSyncer.cj:356-362`（`applyRemoteTombstone`）与 `fmq/src/cluster/MetaSyncer.cj:370-374`（`mergeSnapshot` 的墓碑循环）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2「同一套过滤/副作用换控制流」
- **证据**：静态确定 —— 两处的输入（`MQMetaTombstone`）、判定（`== MetaApplyResult.Applied`）、副作用（`notifyDeletedIfGone`）完全一致，返回值处理不同（一处 `return result`，一处忽略）
- **描述**：合并快照与接收墓碑广播是两条入口，语义要求相同（「墓碑生效且条目确实消失 → 清理」），复制后任何一侧加守卫（例如「墓碑 revision 更旧时不清理」）都会漏掉另一侧。
- **建议**：抽 `private func applyTombstoneAndNotify(tombstone: MQMetaTombstone): MetaApplyResult`，两处都调用；`mergeSnapshot` 的循环体改成一行调用。

### [轻微][存量] `LogCleaner.start()` / `BackupReplicator.start()` 非幂等，与 `MetaSyncer.startAntiEntropy()` 的守卫不一致

- **位置**：`fmq/src/cluster/LogCleaner.cj:135-146`（直接 `timer = Some(Timer.repeat(...))`，不取消旧 `Timer`、不检查 `closed`）、`fmq/src/cluster/BackupReplicator.cj:267-285`（`workerRunning.store(true)` 只写不读，重复 `start` 会起两个 worker）；对照 `fmq/src/cluster/MetaSyncer.cj:81-86`（`if (antiEntropyTimer.isSome()) { return }`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「重复初始化」
- **证据**：静态确定 —— 生产唯一调用点 `MQServer.start()` 由 `started.compareAndSwap(false, true)` 保护（`fmq/src/server/MQServer.cj:166-183`），因此当前不可达；但三个组件的启动契约不一致，`LogCleaner.start()` 第二次调用会让旧 `Timer` 失去引用却继续 `cleanOnce`（两轮并行删段，`removeById` 对同一段第二次抛错 → 每轮都刷 ERROR）。
- **描述**：属「只靠调用方保证」的隐含前置条件，测试与未来重连/重启路径都容易踩。
- **建议**：三个 `start()` 统一成「已启动则直接返回」的守卫（`LogCleaner` 用 `timer.isSome()` 或 `AtomicBool`，`BackupReplicator` 用 `workerRunning.compareAndSwap(false, true)`），并在 `close()` 后禁止再次 `start()`。

### [轻微][存量] 注释与实现不符：`MetaSyncer` 声称「广播失败进入待补偿集合」，实现只有 WARN；设计文档已改成「不再维护 pendingPeers」

- **位置**：`fmq/src/cluster/MetaSyncer.cj:32`（类注释）、`fmq/src/cluster/MetaSyncer.cj:470-475`（`broadcast` 的失败分支只有 `log.warn`）
- **来源**：存量（`fee913b690` 一系）
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§13「文档与实现漂移」
- **证据**：静态确定 —— 类内没有待补偿集合字段（成员只有 `pendingGroups`/`pendingLock`/`antiEntropyTimer`/`closed`/两个回调），`fmq/doc/详细设计.md:307-308` 明确写「失败的 peer 只记 WARN（不再维护 `pendingPeers` 补发队列）」
- **描述**：代码注释停留在旧实现，读者会以为存在 guaranteed 补发；实际补偿完全依赖下一轮反熵（默认 30s），而反熵正是上一条严重问题的触发路径。
- **建议**：注释改成「失败只记 WARN，由反熵下一轮补齐（无补发队列）」，并把上面那条严重问题的取舍写进同一段。

### [轻微][存量] `registerGroup` 用单分支 `match` 重新查一遍列表取回落盘对象；查不到时静默不广播

- **位置**：`fmq/src/cluster/MetaSyncer.cj:155-166`
- **来源**：存量（快照模式）
- **判据**：review-checklist §11「恒真分支 / 静默跳过」、可读性
- **证据**：静态确定 —— `match (store.groupsOf(meta.topic)) { case list => ... }` 只有一个不可反驳的 case，等价于 `let list = ...`；循环里 `if (group.subscribeGroup == meta.subscribeGroup) { broadcastGroup(group); break }` 没有 `else`，若列表里找不到（`store.registerGroup` 已返回 `Applied` 且 `groupsOf` 在同一主题上，理论上不会发生）就既不广播也不留日志，调用方仍拿到 `MQResult(0, "ok")`。
- **描述**：读起来像错误处理，实际是恒真包装；一旦 `groupsOf` 语义变化（例如按 revision 过滤、或主题被并发删除），广播会静默消失，靠反熵兜底。
- **建议**：改成 `let list = store.groupsOf(meta.topic)`；找不到时 `log.warn("group ... applied but missing from index, broadcast skipped")`，或让 `store.registerGroup` 返回落盘后的 `MQSubscribeGroupMeta` 直接用（`MetaStore.cj:258-259` 已经构造了 `versioned`，只是没返回）。

### [轻微][存量] 用例名/注释与断言相反：单节点无副本时批次被静默丢弃（无任何日志），用例却断言 `pendingCount == 0`

- **位置**：`fmq/src/cluster/BackupReplicator.cj:164-167`（`targets.size == 0` 时直接 `return retry`，批次不从 `pending` 恢复也不记日志）、`fmq/src/cluster/BackupReplicator_test.cj:278-288`（用例名 `singleNodeKeepsBatchWithoutTargets`，注释「批次不会被『凭空丢弃』」，断言 `pendingCount == 0`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §11「语义与注释不符」、§3「静默失败」（丢弃路径无留痕）
- **证据**：静态确定 —— `flushOnce` 先把 `pending` 整体换出（`:144-152`），`sendBatch` 在无目标时返回空 `retry`，`requeue` 不被调用 ⇒ 条目消失；用例断言 `pendingCount == 0` 恰好证明「丢弃」，与用例名相反。
- **描述**：生产可达性低（`backup > 0` 时配置校验要求 `backup <= nodes.size-1`，`successors` 在 `nodeCount<=1` 才返回空，`BackupReplicator.start/record` 在 `backup<=0` 时提前返回），但这意味着真出现「拓扑暂时为 1」时既丢批次又无日志。
- **建议**：`targets.size == 0` 时按「无可发目标」处理：`log.warn` 记一条（限流）并保留条目（重新 `requeue` 且不计 attempts），或明确丢弃并记 ERROR 数量；用例名/注释与断言对齐。

### [轻微][存量] `详细设计.md` 与实现/自身漂移 5 处（包归属、成员清单、线程模型、丢弃日志内容、port 校验措辞）

- **位置与证据**（均为静态确定，文档行号 + 代码行号）：
  1. `fmq/doc/详细设计.md:25-26` 的包级设计表把 `MetaSyncer` 归到 `fountain::fmq.meta`、`LogCleaner` 归到 `fountain::fmq.queue`，实际两者都在 `fmq/src/cluster/`（`cluster/MetaSyncer.cj:16`、`cluster/LogCleaner.cj:16`），且同文档 `:123`（LogCleaner 备注「实现位于 cluster/」）与 `:131`（§4.5 把 MetaSyncer 列在 cluster）自相矛盾；
  2. `fmq/doc/详细设计.md:129` 的 `MQNodeTransport` 成员清单漏了 `isAlive`（`fmq/src/cluster/MQNodeTransport.cj:47`，且 `MetaSyncer.cj:216` 以它做反熵分层）；
  3. `fmq/doc/详细设计.md:932` 线程模型把备份 flush 记为 `BackupReplicator Timer`，实现是 `spawn` + 10ms 轮询（`BackupReplicator.cj:272-284`，无 `Timer`），与同文档 `:596`（`close(): 停止定时器`）也不一致；
  4. `fmq/doc/详细设计.md:915` 写「丢弃并记 ERROR（含数量与目标）」，实际日志只有 topic/queue/attempts（`BackupReplicator.cj:245`），没有目标与数量；
  5. `fmq/doc/详细设计.md:76` 把启动校验第 1 条写成 `` `port == 0` ``，而该列表的语义是「任一不满足即报错」，代码检查的是 **port 不得为 0**（`fmq/src/config/MQConfig.cj:290-292`），照文档读会得出相反结论。
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「API/配置与源码不符」「文档过期」
- **描述**：五处都不影响按文档运行的 API 形状，但第 1、5 条会误导读者对包边界与启动校验的理解，第 3、4 条会让排障时按「Timer / 含目标」去查日志而查不到。
- **建议**：按上列逐条改文档（包表合并成「cluster：NodeRegistry / MQNodeTransport / MetaSyncer / BackupReplicator / LogCleaner / LogCapture*」；§4.5 补 `isAlive`；§6.9 改「BackupReplicator 工作线程」；§6.8 按实际日志文案改；§3 第 1 条改「`port` 为 0 → 报错」）。

## 优化可行性方案

> 不是缺陷，是"还能更好"。每条都必须可执行、可验证。

### [CPU] `LogCleaner.cleanOnce` 把 `floorOf` 提到段循环外（现在每个过期段都查一次「全部组的位点最小段号」）

- **现状**：`fmq/src/cluster/LogCleaner.cj:78` 在 `for (meta in queue.segments())` 内联调用 `floorOf(topic, queueIndex)`，而 `floorOf` 是 `ConsumeService.floorOf → CursorCatalog.floorOf`（`fmq/src/server/ConsumeService.cj:364-366`、`fmq/src/queue/CursorCatalog.cj:98-122`），每次要遍历该主题的全部订阅组并逐个查位点（缓存未命中还要读盘）。同一函数里备份队列的分支（`:96-103`）已经把 `backupFloor(...)` 提到循环外，两处风格不一致。
- **方案**：普通队列循环也先 `let floor = floorOf(topic, queueIndex)` 再进段循环；`meta.index < floor` 用局部变量。
- **预期**：每轮从「过期段数 × 组数 × 位点查询」降到「1 × 组数 × 位点查询」；段数多（大段上限+小 maxFileSize 的部署）与组数多时收益成倍，绝对收益取决于段数与组数，不写成百分比。
- **代价**：语义完全不变（同一时刻的 floor 值），唯一差别是同一轮里 floor 不随段删除而变化——现有用例 `removingGroupLetsSegmentsBeReclaimed` 只在两轮之间改组，不受影响。
- **验证**：`cjprof record` 跑「1 队列 200 段 × 20 组」的 `cleanOnce`，对比改前/改后 `floorOf` 自耗时与整轮耗时（同 SDK、`-O2`、取中位数）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `BackupReplicator` 用 10ms 轮询线程替代事件等待；`backup <= 0` 时每发布一条仍做一次 `nowMs()` + 锁

- **现状**：`fmq/src/cluster/BackupReplicator.cj:272-284` 的 worker 每 10ms `sleep` 后调 `shouldFlush()`（持 `lock` 读 `pending`），空闲时也是 100 次/秒唤醒；`record` 在 `backup <= 0` 时（默认配置）先 `warnRateLimited` → `nowMs()`（`DateTime.now()`）+ `synchronized(lock)`，即使一分钟只允许打一条日志。
- **方案**：worker 改成 `Monitor`/条件变量（`std.sync.Monitor` + `notify`）或「有界队列阻塞取」，由 `record` 在入队时唤醒，空闲不再周期唤醒；`record` 在 `backup <= 0` 分支改为进程内只打一次（`AtomicBool` 首次告警），避免每条消息进锁。
- **预期**：默认配置（`backup=0`）下发布热路径少一次取时钟与一次互斥；空闲 CPU 从每进程 100 次/秒唤醒降到 0。绝对收益取决于发布 TPS 与核数，不给百分比。
- **代价**：`shouldFlush` 的「最早一条等 100ms」需要额外的超时唤醒（`Monitor.wait(timeout)`），实现复杂度上升；关停语义需与 `close()` 的 drain 一并重验（`closeWaitsForInFlightBatch` 等 5 个用例可复用）。
- **验证**：`cjpm bench` 做「backup=0，64 并发发布 10 万条」改前/改后对照（吞吐、P99 延迟、进程 `getUsedHeapSize()`），外加空闲 60s 的 CPU 时间对比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 备份批次按字节预算截断并复用容器，避免「整批积压一次性物化 + 编码再复制一份」

- **现状**：`flushOnce` 把 `pending` 整体换出（`BackupReplicator.cj:144-152`），`sendBatch` 为每个分组新建 `Array<Array<Byte>>`（`:188`），`MQBackupPayload` 再包一层 `MQBlob`，编码时又生成整帧字节；峰值 ≈ 2～3 × 单批字节，而单批上限只有 `capacity`（8192 条），没有字节上限。
- **方案**：给 `pending` 增加 `pendingBytes` 计数，取批时按「`min(BATCH_SIZE, 字节预算)`」截断，未取的留在 `pending`；`records` 直接按键值分组后原地使用（不再先建 `ArrayList<BackupItem>` 再转数组）；`reuse` 一个 `ArrayList` 作为批容器（每轮 `clear()` 后复用，注意 `clear()` 不归还物理容量，需配合上限才有效）。
- **预期**：单轮峰值从「积压全部 + 编码副本」降到「≤ 预算 + 编码副本」，最坏堆占用与发布记录大小解耦（配合上面那条 OOM 缺陷的建议一起做）。收益取决于积压规模，不给百分比。
- **代价**：截断会改变「一次 flush 把积压清空」的现状，`BackupReplicator_test` 里依赖「一次 `flushOnce` 就全部发出」的用例（`recordOnlyEnqueuesAndFlushSendsOneBatch`、`workerFlushesFullBatch`）需要按 64/预算分批调整；`oldestEnqueuedMs` 的语义要重算（剩余条目仍以最早入队时间计时）。
- **验证**：`cjprof heap` + `getAllocatedHeapSize()` 在「副本延迟 300ms、持续发布 5 万条 1KB 记录」场景下对比峰值与稳态（`mem §1.2` 的口径）；同时断言最终 `pendingCount == 0` 且目标节点收到的记录集合与发布集合一致（顺序、重复次数）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `MetaSyncer.broadcast` 在注册/注销的请求线程上串行同步发给全部 peer，节点数大或 peer 不可达时注册延迟线性放大（单次 `send` 上限 `pingTimeout*5`，见 `NodeRegistry.cj:143`） | `fmq/src/cluster/MetaSyncer.cj:464-476` | 节点数-延迟曲线、单次 send 的 P95 | 3/5/9 节点各跑 1000 次 `registerTopic`，分段计时（`broadcast` 前后打点）+ `cjprof` 过滤 `NodeRegistry.send` |
| 2 | `LogCleaner.cleanOnce` 在段多、组多时 `floorOf` 成为主要耗时（见上「CPU」方案） | `fmq/src/cluster/LogCleaner.cj:73-94` | 自耗时占比、段数×组数 | `cjprof record` 跑 200 段 × 20 组的一轮清理，统计 `CursorCatalog.floorOf` 自耗时 |
| 3 | `BackupReplicator` 的 10ms 轮询在空闲进程里占比不可忽略（100 次/秒唤醒 + 每次取锁） | `fmq/src/cluster/BackupReplicator.cj:272-294` | 空闲 CPU 时间、唤醒次数 | 空载 60s 采 `ps`/`time` 的 CPU 时间，对比事件驱动实现 |
| 4 | `CapturingStream.lines` 只增不减（`take()` 不清空）会让日志用例的 `find/waitFor` 随用例数变慢（测试栈） | `fmq/src/cluster/LogCapture_test.cj:50-61` | 单次 `find` 耗时 vs 累计行数 | 在 `LogCleaner_test`/`MetaSyncer_test` 全量跑时打点 `lines.size` 与 `find` 耗时 |

## 文件覆盖

> 与 `{workdir}/files/fmq.part3.txt` 一一对应（14 行，顺序一致）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fmq/doc/详细设计.md` | .md | ✅ | 1047 行全读；§2/§3/§4.5/§5.6/§5.14/§5.16/§6.8/§6.9/§6.12 与实现逐条对照，见「轻微 文档漂移 5 处」；§5.16/§5.14 的签名与实现一致 |
| 2 | `fmq/src/FmqTestSetup_test.cj` | .cj | ✅ | 与 `cluster/`、`server/` 两份逐字节相同，见「轻微 §2 重复」；`protocol_hostId` 侧效应初始化，保留在包级是必要的 |
| 3 | `fmq/src/MQUsage.cj` | .cj | ✅ | `root/serverHelp` 与 `main.cj:49-84` 一致；`managerHelp` 与 `MQManagerArgs.helpText` 重复，见「轻微 §2」 |
| 4 | `fmq/src/MQUsage_test.cj` | .cj | ✅ | 7 个子命令计数断言有效（能发现漏列/重复）；第 56-67 行的计数逻辑与 `MQManagerArgs_test.cj:68-80` 同构，并入重复逻辑条 |
| 5 | `fmq/src/Main_test.cj` | .cj | ✅ | 覆盖 `--help`/无参/未知命令/配置前置/装配失败/manager 不装钩子/启动顺序；`ConfigSandbox` 保存-恢复对称，无残留；无缺陷 |
| 6 | `fmq/src/cluster/BackupReplicator.cj` | .cj | ✅ | 见「一般 close/record 竞态」「一般 字节无界 + 批次不封顶」「轻微 start 非幂等」「轻微 静默丢弃」「轻微 注释/用例相反」；`sendBatch` 重试与分组逻辑逐行核对，`requeue` 保序正确 |
| 7 | `fmq/src/cluster/BackupReplicator_test.cj` | .cj | ✅ | 18 个用例覆盖入队/批量/容量/部分目标失败/重试上限/关闭等待/并发关闭；`singleNodeKeepsBatchWithoutTargets` 名实不符（见「轻微」）；`slowReplicasDoNotBlockPublish` 用 1000ms 墙钟上限，慢机上可能抖动（不单列） |
| 8 | `fmq/src/cluster/FakeTransport_test.cj` | .cj | ✅ | `send` 先计数再判可用，`available/knownDead/alive` 三个开关都被用例使用；`clear()`/`attemptCount()` 有调用者，无死代码 |
| 9 | `fmq/src/cluster/FmqTestSetup_test.cj` | .cj | ✅ | 三份相同，见「轻微 §2 重复」 |
| 10 | `fmq/src/cluster/LogCapture_test.cj` | .cj | ✅ | 四份相同（见「轻微 §2」）；`CapturingAppender.clear()` 无引用（见「轻微 §1」）；`write` 按 `\0` 分行有锁保护，无竞争 |
| 11 | `fmq/src/cluster/LogCleaner.cj` | .cj | ✅ | 见「轻微 start 非幂等」；逐对象 try/catch 与汇总日志符合 A41；`meta.last` 与 `index < floor` 双重保护正确；`floorOf` 位置见「CPU 优化」 |
| 12 | `fmq/src/cluster/LogCleaner_test.cj` | .cj | ✅ | 12 个用例覆盖 TTL/引用保护/当前段/死信独立 TTL/离线组/移除组/队列与段级隔离/重开/定时器续跑；第 29 行未使用的 `QueueLog` import（见「轻微 §1」）；断言均为「段文件真的少了」而非只看计数，质量较好 |
| 13 | `fmq/src/cluster/MQNodeTransport.cj` | .cj | ✅ | 接口 6 个成员（`nodeCount`/`selfIndex`/`send`/`isKnownDead`/`isAlive`/`successors`）全部有使用方（`BackupReplicator`/`MetaSyncer`/`NodeRegistry`）；文档 §4.5 漏 `isAlive`（见「轻微 文档漂移」） |
| 14 | `fmq/src/cluster/MetaSyncer.cj` | .cj | ✅ | 见「严重 缺失扫描误删」「一般 nextStart 回退竞态」「轻微 注释不符」「轻微 registerGroup 单分支 match」；`pendingGroups` 有界 1024 + 5min TTL，`flushPendingGroups` 先锁内取快照再锁外应用，无死锁 |

合计：`.cj` 13 个 / `.md` 1 个 / 共 14 个，全部读完。

## 覆盖自检

> 全部维度都必须出现，命中 0 条也要写理由。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 4（缺失扫描误删、close/record 竞态、nextStart 回退、静默丢弃）；设计 2（备份容量按条不按字节、start 契约不一致）；可读性 3（注释与实现不符、单分支 `match`、用例名与断言相反）；语言特性 1（`synchronized` 内的 `return` 已按语言规范核对为「从外层函数返回」——`cangjie-doc/md/doc/cjapi/sync.md:17`「关键字自动加锁/解锁，正确处理 break/continue/return/throw」；`Mutex` 按 std 文档**可重入** —— `doc/libs/std/sync/sync_package_api/sync_package_classes.md:8919-8930`「可重入是指线程获取该锁后可再次获得该锁」，故 `record` 在锁内调 `warnRateLimited` 不判死锁）；安全性 0（本部分无外部输入拼接、无凭据；`MQNodeTransport.send` 的失败路径不抛异常，`NodeRegistry` 已内部 catch） |
| §1 死代码 | 2 | 逐个 `private`/`internal`/`protected` 符号搜引用：`BackupItem`/`BackupGroup`/`PendingGroup`/`StubStateSource`/`ConfigSandbox` 均有使用；`BackupReplicator`、`MetaSyncer`、`LogCleaner`、`FakeTransport` 的全部字段与方法（含 `sendBatch`/`statesOf`/`cursorsOf`/`requeue`/`shouldFlush`/`warnRateLimited`/`joinNodes`/`nowMs`/`describeQueueNum`/`notifyDeleted*`/`flushPendingGroups`/`addPendingGroup`）都有调用方（`flushOnce`/`pendingCount`/`setStateSource` 仅测试使用，属「可见性建议」不判死代码）；`MetaSyncer.isClosed` 是 `Resource` 接口实现，豁免。命中 2 条：`CapturingAppender.clear()` 全仓无引用、`LogCleaner_test.cj:29` 未使用的 import。`MQNodeTransport`/`BackupStateSource` 是接口，成员按实现/调用计 |
| §2 重复逻辑 | 3 | 同文件与跨文件两两比对函数体「输入→输出→副作用」+ 搜重复字面量/文案：命中 manager 帮助正文两份（逐字节 diff 为空）、`LogCapture_test.cj` ×4 与 `FmqTestSetup_test.cj` ×3、`applyTombstone+notifyDeletedIfGone` 两处同构。判为非重复：`broadcastTopic/Group/Tombstone` 三个一行包装（类型不同、可读性收益）、`statesOf` vs `cursorsOf`（数组 vs 单值语义不同）、`requeue` 的「前插重建」vs `flushOnce` 的「整表换出」（保序目标不同）、`LogCleaner` 普通队列与备份两段循环（floor 来源与日志前缀不同，属显式参数化后的差异） |
| §3 空实现 | 1 | 无 `TODO`/`FIXME`/`UnsupportedException`/`catch {}`；`CapturingStream.flush()` 空体是 `OutputStream` 接口实现（有注释说明是内存实现），不算空实现。命中 1 条：`sendBatch` 在 `targets.size == 0` 时静默丢弃批次且不记日志（并入「轻微 静默丢弃」） |
| §4 栈溢出 | 0 | 本部分无递归：`mergeSnapshot`/`flushPendingGroups`/`cleanOnce`/`sendBatch` 全是单层循环；`BackupReplicator` 的重试是 `requeue` 队列，不是递归；`MetaSyncer` 的 `snapshot` 合并对集合做一遍线性扫描，深度为常数 |
| §5 OOM | 1 | 命中备份队列按条数限容、按字节无上限且整批物化（已量化：8192 × 64MB ≈ 512GiB 理论 / 8192 × 1MB ≈ 8GiB）。其余：`pendingGroups` 有 1024 + 5min TTL 双上限；`failures`/`expired`/`candidates` 三个临时列表的长度上界是段数/组数；`LogCapture` 的静态 `lines` 只增长但属测试栈，已进待验证假设 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据；3 条候选（broadcast 串行、floorOf 每段查一次、10ms 轮询空闲）全部进「待验证假设」，未作为发现 |
| §6.2 大粒度锁 | 0 | 逐处核对临界区：`lock` 只保护 `pending`/`oldestEnqueuedMs`/`lastDropWarnMs`，网络发送在 `lock` 外（`flushLock` 只串行化 flush，且仅 1 个 worker + close）；`pendingLock` 只保护 `pendingGroups`；`MetaStore` 的锁被 `store` 内部持有，`MetaSyncer` 不在其临界区内做 I/O。唯一「锁内日志」是 `record` 满队列分支（`BackupReplicator.cj:126-129`），有 1s 限流，量级不足，不计 |
| §6.3 并发串行 | 1 | 命中 `MetaSyncer.broadcast`：注册/注销请求线程上对全部 peer **串行同步**发送（`MetaSyncer.cj:464-476`），并行度上限 = 1，且失败要等单次 send 超时；该条缺延迟数据，只作为结构事实记入「CPU 优化/待验证假设」，不按缺陷计 |
| §6.4 低效算法 | 1 | 命中 `cleanOnce` 段循环内每次调用 `floorOf`（O(段 × 组)，且可能读盘）；`BackupReplicator` 每条记录重算分组 key（字符串拼接 + `joinNodes`）属同类但缺占比数据，未作为发现。其余：`Array`/`ArrayList` 无 `contains`、无 `remove(at: 0)` 当队列（`requeue` 是重建列表后整表替换） |
| §7 降堆内存方案 | 1 | 备份批次按字节预算 + 截断 + 复用容器（无基线，标注待验证） |
| §8 降 CPU 方案 | 2 | `floorOf` 提出段循环；10ms 轮询改事件等待 + `backup<=0` 免锁告警（均无基线） |
| §9 local mode 可行性 | 0 | 不适用：`sendBatch` 的 `records`、`states` 都要作为消息载荷逃逸到编码/网络层，`mergeSnapshot` 的 `HashSet` 要跨多次 `applyTopic` 使用，均不满足「函数内创建、函数内释放」；`BackupItem` 生命周期跨线程且长度不可预知，local region 的 `cjLocalRegionMaxSize` 会成为新的 OOM 面，收益只能用峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 6 | 本轮读到的 14 个文件的边界/空值/错误处理/资源/并发/契约均过了一遍，命中：缺失扫描误删（严重）、close/record 竞态、字节无界（含静默丢弃）、nextStart 回退、`start()` 非幂等、注释/用例与实现相反。核对后判为非缺陷：`sendBatch` 的 `items[0]`（group 至少一条）、`joinNodes` 空数组、`statesOf` 返回长度不符时的 WARN 回退、`requeue` 超过 `MAX_ATTEMPTS` 的丢弃（有 ERROR 日志）、`LogCleaner` 当前段跳过、`close()` 等待上限与 `flushLock` 的交互（有界于 transport 超时）、`MetaSyncer.pendingGroups` 的 TTL 淘汰。`Mutex` 可重入已核对 std 文档，未按「锁重入死锁」报 |
| §12 并发安全与锁粒度 | 4 | 已列共享点与同步手段：`pending`/`oldestEnqueuedMs`/`lastDropWarnMs`（`Mutex`，读-改-写在锁内）、`closed`/`workerRunning`（`AtomicBool`，但 `closed` 的检查在锁外 ⇒ 命中）、`pendingGroups`（`Mutex`）、`timer`/`antiEntropyTimer`（`start`/`close` 同线程或 CAS）。命中 4 条：close/record 竞态、nextStart 读-算-写、`start()` 重复初始化、`broadcast` 串行（性能面）。`MetaSyncer.closed` 是普通 `Bool` 且仅 `close`/`isClosed` 使用（`isClosed` 无调用方，`Resource` 实现），无实际竞争路径，不单列 |
| §13 文档一致性 | 1 | 命中「轻微 文档漂移 5 处」（包归属、`isAlive` 漏列、Timer 线程模型、丢弃日志内容、port 校验措辞）。其余核对一致：§5.6 MetaSyncer 方法清单、§5.14 LogCleaner 签名与删除条件、§5.16 BackupReplicator 签名与 `capacity=8192`、§6.8 接收端「记录数与 states 数不一致只落记录 + WARN」（`MQCommandExecutor.cj:249-251`）、§6.12 关闭顺序（`MQServer.cj:206-224`）、§7 manager 参数位置与 `--server` 默认 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `README.md`/`README_en.md`（属其它部分），不判 README 覆盖。以 `详细设计.md` 为承诺源逐条对照本部分实现：`BackupReplicator.record/setStateSource/start/close`、`MetaSyncer` 全部方法、`LogCleaner.cleanOnce/start/close`、`MQNodeTransport.successors/isKnownDead/isAlive` 均已接线（`MQServer.cj:96-125`、`MQServer.cj:166-180`、`MQCommandExecutor.cj:152-181`）；无「承诺但未实现」项，唯一偏差是 §6.8 日志内容与 §6.9 线程模型（已并入 §13） |
| 文件覆盖（§13 等） | 14/14 | 本部分 14 个文件全部读完，无缺文件、无「未读」 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 3 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷合计 13 条（严重 1 / 一般 3 / 轻微 9），是否纳入修复待用户决定。

## 总评

本部分的代码形态是「三个集群组件 + 入口帮助文本 + 测试夹具」。分工清晰、注释里带设计编号（A25/A27/A31/A33/A41），`BackupReplicator` 的「发布只入队、worker 批量发送、失败按目标集合重试」与 `LogCleaner` 的「逐段/逐队列隔离异常 + 轮末汇总」都是按可测性设计的，12 个清理用例还断言了「段文件真的少了」而不是只看计数，这是本模块里质量较高的一块。

**唯一的阻塞项是 `MetaSyncer.mergeSnapshot` 的「快照缺失即删」**：它把「某个 peer 没收到某次广播」判定成「本机多了一条」并删除，删除会走到 `closeTopic(deleteFiles: true)`，消息段与游标一起没。触发不需要并发，只需要一次广播失败（设计已把它当常态）+ 该 peer 之后有任何 revision 更高的变更；而 `nextStartNode` 的单调性、`close()` 的收尾语义又分别有各自的竞态窗口。这三条建议一起修：删除路径加墓碑/多 peer/严格版本三重门、单调性下沉到 `MetaStore` 锁内、`closed` 判定移进 `pending` 锁。

备份复制面还有两个可量化的风险：容量只数条数不数字节（理论 512GiB，1MB 记录也有 8GiB），以及 flush 取走整个积压（`BATCH_SIZE` 只触发不封顶）。两者叠加在「副本慢」这个本来就要靠队列扛的场景里，建议按字节预算 + 分批一起做，并配 `cjprof heap` 的前后对照。

轻微项集中在测试资产（`LogCapture_test.cj` 四份、`FmqTestSetup_test.cj` 三份、`CapturingAppender.clear()` 从未被调用）与两处「文档/注释停在旧实现」（待补偿集合、备份 Timer 线程模型）。这些不影响运行，但会让下一次改动误判「已有覆盖/已有兜底」，建议随同上面三条一起收敛。性能类结论（`broadcast` 串行、`floorOf` 每段一次、10ms 轮询）目前只有结构证据，已全部放进「待验证假设」与无基线的优化方案，未计入缺陷。
