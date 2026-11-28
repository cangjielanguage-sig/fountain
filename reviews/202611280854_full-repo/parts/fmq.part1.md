# fmq 模块审查报告

> **模块第 1/7 部分**（本部分只覆盖 `files/fmq.part1.txt` 的 20 个文件：`README.md`、`README_en.md`、`doc/backlog.md` 与 `doc/spec/**` 下 17 份变更规格/设计文档。**本部分没有 `.cj` 源文件**，故 §1 / §2 的机械动作改为「文档引用的符号、路径、脚本是否仍存在」「文档承诺的处置项是否落地」，`src/` 侧的逐函数检查留给第 2–7 部分，避免跨分报告重复计数。）

- **审查日期**：2026-11-28
- **模块路径**：`fmq`（本部分 20 个 `.md`，0 个 `.cj`）
- **基线**：工作区快照（`git diff` 为空 ⇒ 全部问题记「存量（无基线可比）」）
- **审查重点**：投递 / 确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑（本部分落在文档侧：语义承诺是否完整、是否与实现相反、规格是否自洽）
- **报告版本**：v1（第 1/7 部分，待主 Agent 与 part2–part7 合并为 `docs/review/2026-11-28/fmq_v2.md`）

## 发现

### [一般][存量] #1 `lagMs` 口径为「backlog 中最早一条」，实现取「首次遇到的队列首条」

- **位置**：`fmq/README.md:105`、`fmq/README_en.md:123`、`fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/metrics/spec.md:12`（`lagMs`：最早一条记录的发布时间）；实现 `fmq/src/server/ConsumeService.cj:240-251`（关键在 `246-251`：`if (oldest.get(group).isNone()) { ... oldest.add(group, published) }`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」+ §11「语义与命名 / 注释不符」
- **证据**：静态确定 —— `oldest` 对每个组只写入一次（`isNone()` 才 `add`），此后不再比较发布时间；`for ((queueIndex, log_) in locals)`（`184`）按 `QueueManager.localQueues` 的返回顺序遍历队列。因此 `lagMs` = 「遍历中第一个有积压、且首条 messageId 可解析的队列，其首条记录的发布时间」，而不是「所有队列里最早的一条」。
- **描述**：多队列主题（`registerTopic /order 4` 即 4 个队列）在「各队列游标推进程度不同」时必然暴露：队列 0 已消费到最新、队列 3 的游标停在一天前，`lagMs` 仍取队列 0 的首条（很新），积压告警会迟报甚至不报。单队列或各队列同步消费时不暴露，所以测试里很难撞见。
- **建议**：把 `oldest.add` 改成「取最小发布时间」（保留 per-group 的 `?DateTime`，`Some(prev)` 时比较后再决定是否覆盖），或在 README 与 metrics 规格里统一改成「取首个非空队列首条」——二选一，但两侧必须同口径。

### [一般][存量] #2 消费语义只写了两态，第三种「匹配者离线、组内仍有人在线」实现按「无匹配」越过

- **位置**：`fmq/README.md:88`（`服务端保证 at-least-once`）、`fmq/README.md:94`（`组内无匹配订阅时…越过；组内无人在线时保留未决`）、`fmq/README_en.md:99`、`fmq/README_en.md:108-110`；规格 `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/consume-semantics/spec.md:64-70`；实现 `fmq/src/server/ConsumeService.cj:72-78`、`fmq/src/queue/GroupCursor.cj:287-335`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14「承诺了但没实现 / 关键限制缺失」、§13「文档与实现不一致」、§11「契约与实现不符」
- **证据**：静态确定 —— `ConsumeService.cj:72-78` 把 `members` 构造为「组内**未断链**的订阅」；`GroupCursor.cj:287-300` 只在这批在线成员里找匹配者，都不匹配且无 `Unsupported` 时走 `326-335` 的 `else` 分支：`decided: true` + `incSkippedNoMatch` + `advance()`。于是「组内唯一匹配该记录的订阅 S1 离线、同组不匹配的 S2 在线」这一态被折叠成「组内无匹配」：记录被永久越过，不进死信、不推进 `committed` 之外的任何观测，只有一条 DEBUG 日志。
- **描述**：README 只定义「组内无匹配」（越过）与「组内无人在线」（保留未决）两种状态，`fix-fmq-full-audit` 的规格还明确要求两态「MUST NOT 混用」，但**两处都没定义第三态**。实现把第三态归入「无匹配」，等价于丢消息，与 README:88 的 at-least-once 承诺不符；读者从任一文档都发现不了。代码侧是否按「严重（数据丢失）」处理，请第 2–7 部分的 `GroupCursor` 审查裁定；本部分只记文档缺口：第三种状态缺定义，也缺「该状态下记录是否会被丢弃」的结论。
- **建议**：三份文档（`README.md`、`README_en.md`、consume-semantics delta）各补一条：匹配者离线且组内仍有在线订阅时，当前实现按「不适用」越过；若确认为缺陷，先改实现（匹配者离线应保留未决）再改文档；若确认为取舍，必须写明「该场景消息会被跳过、仅记 DEBUG」，并同步 `stats` 的 `skippedNoMatch` 口径。

### [一般][存量] #3 README 承诺「备份段…磁盘不会无界增长」，与同文档的保留规则及清理器实现矛盾

- **位置**：`fmq/README.md:59-60`（`备份段按位点与 segmentedLogTTL 一起参与清理，磁盘不会无界增长`）、`fmq/README_en.md:65-67`；对照 `fmq/README.md:160-161`（`从未消费过的组会把边界钉在编号最小的现存段，历史段不会回收`）；实现 `fmq/src/cluster/LogCleaner.cj:40-41`、`96-113`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现相反」、§5「无界增长」（此处是磁盘，不是堆）
- **证据**：静态确定 ——
  1. `LogCleaner.cj:96-113`：备份段只有满足 `meta.updateTime + ttl < now && meta.index < floor` 才删除；
  2. `LogCleaner.cj:40-41`：`backupFloor` 的默认实现是 `{_, _, _ => 1}`，注释写「缺失时返回 1（保留全部）」——**没有任何备份位点文件的组会把 floor 永久钉在 1**；
  3. `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/metadata-cluster/spec.md:177`：`备份段 SHALL 纳入 TTL 清理，保留边界由备份位点决定`。
- **描述**：只要存在一个注册后从不消费的组（或它的备份位点从未写入成功），备份段就永不满足 `index < floor`，`segmentedLogTTL` 对它完全失效；持续发布会让 `segmentedLogDir/backup/**` 单向增长，写满后发布失败。README 的「磁盘不会无界增长」会被当成容量兜底承诺，而正确操作（删除离线组 / 手工清理 `backup/`）只写在同文档另一节。
- **建议**：改成条件式表述并与 `README.md:160-161` 合并：「备份段与消息段共用同一保留规则，位点最小的组决定边界；从未消费的组会让备份段同样不被回收，需删除该组或手工清理 `backup/`」。中英同步。

### [一般][存量] #4 存档 delta「无匹配订阅者时暂停」同一节内 Requirement 正文与 Scenario 结论相反

- **位置**：`fmq/doc/spec/add-fmq-message-queue/specs/fmq/consume-semantics/spec.md:136-149`（正文 `138-139`：`游标 SHALL 保留该位置为未决，不得跳过推进（保证消息不丢）`；场景 `141-144`：`该位置被标记为「不适用」并允许越过`；场景 `146-149`：`committed 不前进`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移 / 文档自相矛盾」，按「当时结论是否自洽」核对
- **证据**：静态确定 —— 同一 Requirement 下，正文要求「不匹配 ⇒ 不越过」，`#### Scenario: 组内无匹配` 要求「不匹配 ⇒ 越过」，二者不可同时满足；第三个场景又要求「无人在线 ⇒ 不推进」。三种表述对应三种不同实现：按正文实现会让一个不匹配的记录永久卡住整组（backlog 单调增长），按场景实现则丢消息。
- **描述**：这是 fmq 消费语义最容易被读错的一处，也是后来 `fix-fmq-full-audit` 重写该 Requirement 的直接原因（`fmq/doc/spec/fix-fmq-full-audit/specs/fmq/consume-semantics/spec.md:64-70` 拆成两态并加 `MUST NOT 混用`）。但旧文件没有「已被后续变更取代」的标注，两份 delta 并列存在于 `doc/spec/` 下。
- **建议**：在 `add-fmq-message-queue` 的三份旧 delta 顶部统一加 `> 部分 Requirement 已被 fix-fmq-full-audit / add-fmq-metrics-and-delay 修改，以较晚变更为准`；至少修掉 `136-149` 这处自相矛盾（正文改为与场景一致）。

### [一般][存量] #5 README「其他公开 API」清单漏 6 个公开符号，且把 `protected` 类型的成员写成模块级 API

- **位置**：`fmq/README.md:185-190`、`fmq/README_en.md:220-225`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.2「公开 API 未文档化」、§13「API 与源码不符」
- **证据**：静态确定 —— 对 `fmq/src` 的顶层 `public` 声明与 `public` 成员逐个比对两份 README：
  1. **漏项**：`MQConfigException`（`fmq/src/config/MQConfig.cj:26`，README/README_en 零命中）、`MQManagerArgs.server`（`fmq/src/manager/MQManagerArgs.cj:26`，清单只写 `command` / `operands`）、`MQManagerOutput.stats`（`fmq/src/manager/MQManagerOutput.cj:68`，同类 `topicList` / `table` 都在清单里）、`NodeRegistry.nodeCount`（`fmq/src/cluster/NodeRegistry.cj:88`，同类 `selfIndex` 在清单里）、`MQServer` 的 `run` / `close`（`fmq/src/server/MQServer.cj:193`、`:239`，清单只列 `isClosed`）。
  2. **混入内部成员**：`execute`（`fmq/src/server/MQCommandExecutor.cj:67`、`:72`，所属 `protected class MQCommandExecutor`，见 `:39`）、`backupStates` / `backupCursors`（`fmq/src/server/ConsumeService.cj:302`、`:318`，所属 `protected class ConsumeService`，见 `:36`）、`pendingCount`（`fmq/src/cluster/BackupReplicator.cj:100`，`protected class` 见 `:71`；另有 `GroupCursor.cj:98` 同名）、`isAlive` / `isKnownDead` / `successors` / `send` / `selfIndex`（`NodeRegistry.cj:197`、`:206`、`:154`、`:138`、`:82`，全部在 `protected class` 内）、`isClosed`（**七个类型同名**：`MetaSyncer.cj:98`、`MetaStore.cj:560`、`DeadLetterQueue.cj:70`、`QueueLog.cj:306`、`QueueManager.cj:214`、`BackupStore.cj:255`、`NodeRegistry.cj:214`）。
- **描述**：清单自称「按模块级 / 类型分组列出」，实际把 7 个同名 `isClosed`、两个 `selfIndex`、两个 `pendingCount`、两个 `execute` 压成裸名字，且把模块内成员抬成对外契约。外部使用者按此查找会找不到符号（类型不可见），也无法判断语义（哪个 `next`、哪个 `isClosed`）。
- **建议**：清单改为「类型 → 成员」两列，并加一列可见性；删掉 `protected` 类型成员，或标 `模块内可见（非对外 API）`；补齐上述 5 项，中英同步。

### [一般][存量] #6 `doc/backlog.md` 的 P0 四项已全部落地却仍写「本轮不实现」，引用行号亦已漂移

- **位置**：`fmq/doc/backlog.md:8-21`（对照 `fmq/README.md:56-59`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期：写着『暂不支持』其实已支持」
- **证据**：静态确定 —— 逐项核对：
  - 第 1 项「备份状态未真正复制、`deliverCount` 固定 0、`acked` 固定 false」：现由 `ConsumeService.backupStates` 逐条计算真实投递次数与「全部组已确认」（`fmq/src/server/ConsumeService.cj:302-315`），接收端还落 `cursors`（`fmq/src/server/MQCommandExecutor.cj:244`）；
  - 第 2 项「发送失败即丢」：`flushOnce` + `requeue` 已实现「失败批次重入队、`MAX_ATTEMPTS = 3` 后丢弃记 ERROR」（`fmq/src/cluster/BackupReplicator.cj:73-76`、`:139-157`），README:57-58 同样这么写；
  - 第 3 项「广播失败不补齐」：已由反熵定时器收敛（`mqServer_antiEntropyInterval`，`MQConfig.cj:52`）；
  - 第 4 项「连接缓存关闭后不重建」：`NodeRegistry.clientOf` 已清槽重建（`fmq/src/cluster/NodeRegistry.cj:113-127`）；
  - **行号漂移**：`backlog.md:10` 指向 `BackupReplicator.cj:110`，该行现在是 `setStateSource` 的赋值（`this.stateSource = source`）；`backlog.md:11` 指向 `MQCommandExecutor.cj:162-168`，该处是 metaSync 的分派分支。
- **描述**：文件标题写「遗留项（归档，暂不实现）」，没有任何「P0 已被后续变更修复」的标注。按它排期会重复处理已修问题，按行号跳转还会读错代码。P1 的 5–10 项经核对仍成立，说明这是「部分过期」而非整体废弃，危害更大。
- **建议**：文件头加「历史快照（2026-10-18）：第 1–4 项已在 fix-fmq-full-audit 中落地，行号不再对应」；删除或改写 P0 段，保留仍成立的 5–10 项并重标当前行号。

### [轻微][存量] #7 README 的延迟投递说明缺「发布时间超前 > 5 分钟视为已到期」容差

- **位置**：`fmq/README.md:114-117`、`fmq/README_en.md:135-140`；实现 `fmq/src/queue/GroupCursor.cj:560-575`；规格出处 `fmq/doc/spec/fix-fmq-postfix-audit/design.md:329`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「关键段落缺失 / 规格与实现漂移」
- **证据**：静态确定 —— `isDue` 对 `published > current + Duration.minute * 5` 直接返回到期并记 WARN（`566-569`），对 `publishTime == None` 也返回到期并记 WARN（`572-574`）。README 只写了后者（`117` 行「非标准 messageId…按已到期处理并记 WARN」），没有前者。
- **描述**：README 把延迟表述为「发布时间 + delaying 之前不投递，未到期消息阻塞后续（FIFO）」。生产者时钟超前 5 分钟以上时消息会**提前**投递且不阻塞队列，运维按 README 判断「延迟 1h 的消息不会早于 1h 出现」会误判，排障时也想不到去看 WARN。
- **建议**：在 `README.md:117` 那段补一句「发布时刻比服务端当前时间超前 5 分钟以上按已到期投递并记 WARN；超前 ≤ 5 分钟仍按正常延迟等待」，中英同步。

### [轻微][存量] #8 「已知限制」缺「死信只有落盘文件，无读取 / 重放入口」

- **位置**：`fmq/README.md:148-167`、`fmq/README_en.md:172-201`；证据 `fmq/src/queue/DeadLetterQueue.cj:31-77`、`fmq/src/MQUsage.cj:49-68`、`fmq/doc/backlog.md:34-36`（P1#8 自述）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.2「缺关键段落：限制与注意事项」
- **证据**：静态确定 —— `DeadLetterQueue` 的读写入口 `append` / `iterate` / `cleanExpired` / `sync` 全是 `protected`（`DeadLetterQueue.cj:38-72`），类型本身也是 `protected class`（`:31`）；manager 的 7 个子命令与 `MQUsage.managerHelp` 无死信相关项；`backlog.md:34-36` 自己也写着「无死信读取/重放接口」。
- **描述**：README:90-91 只写「超过阈值进死信、按 `deadMsgTTL` 保留」，读者会假设「消息还在，可以捞回来重放」，实际只能进服务器文件系统手工解析 `<deadMsgDir>/log_<seq>.log`（每条是 `codec(MQDeadLetterMessage)`）。这是消息被丢后唯一的补救路径，必须先讲清。
- **建议**：已知限制加一条「死信只有落盘文件，客户端与 manager 均无读取/重放接口；需要时按 `MQDeadLetterMessage` 编码手工解析」。

### [轻微][存量] #9 默认配置（`backup = 0`）下每次发布都记一条限流 WARN，README 未记录

- **位置**：`fmq/README.md:58`、`fmq/README_en.md:63-64`；实现 `fmq/src/server/MQCommandExecutor.cj:278-280`、`fmq/src/cluster/BackupReplicator.cj:114-120`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符」+ §11「日志语义」
- **证据**：静态确定 —— `onPublish` 在 `log.append` 之后**无条件**调用 `backup.record`（`MQCommandExecutor.cj:279-280`）；`record` 的第一个分支是 `if (backup <= 0) { warnRateLimited("dropped backup ... replication is disabled"); return }`（`BackupReplicator.cj:114-120`），限流窗口 1s；`mqServer_backup` 默认 0（`MQConfig.cj:62`）。
- **描述**：README 只写「备份队列满或关闭阶段到达的写入会被丢弃并记 WARN」。默认配置（绝大多数单节点部署）下每条消息都会走进该分支，表现为**每秒一条** `dropped backup ... (mqServer_backup=0)`，运维会把这条 WARN 当成真实丢副本告警。该行为在规格里有（`fix-fmq-full-audit` metadata-cluster:176），README 未写。
- **建议**：README 补「`backup = 0` 时发布路径仍调用复制器，写入被丢弃并每秒最多记一条 WARN」；或按优化方案在装配期短路，把提示改成启动期一条 INFO。

### [轻微][存量] #10 `README_en.md` 把「每条消息」写成「each commit」

- **位置**：`fmq/README_en.md:60`（对照 `fmq/README.md:56`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「`README_en.md` 与 `README.md` 不同步：语义不一致」
- **证据**：静态确定 —— 中文「每条消息异步推送」，英文「each commit is replicated」；实现是在发布落盘后按**记录**入队（`MQCommandExecutor.cj:279-280` → `BackupReplicator.record`），与组游标 `committed` 无关。
- **描述**：`commit` 在消息队列语境里通常指「消费位点提交」，读者会以为备份按 committed 游标触发，与同段「副本只落盘、不参与投递」自相矛盾。
- **建议**：改为「each published record is replicated asynchronously」。

### [轻微][存量] #11 `design.md` §4.2 的处置清单还有 2 项未落地（1 处恒假分支、1 处零引用死方法）

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/design.md:366`（「`QueueLog` 的 `length < 0` 分支 → 不可达 → 合并进 `length == 0`/超限判定」）、`:372`（`QueueManager.hasLocalQueues、MQMatcher.topicOf | 无消费者 | 删除`）；实现 `fmq/src/queue/QueueLog.cj:403`、`fmq/src/queue/MQMatcher.cj:76-78`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「恒真恒假分支 / 无调用者」+ §13「处置项与实现不一致」
- **证据**：静态确定 ——
  1. `QueueLog.cj:403`：`if (length < 0 || length > QueueLog.MAX_RECORD_SIZE)`，而 `length` 由 4 字节无符号值拼成 `Int64`（`0..0xFFFFFFFF`），`length < 0` 永假；
  2. `MQMatcher.cj:76-78`：`static func topicOf(record)` 只转发 `MQMessageRecord.topic`；`MQMatcher` 是 `protected class`（`:75`），在 `fmq/src`、`f_mq/src`、`fmqdemo` 全量检索 `MQMatcher.topicOf` 与 `topicOf(` **只有定义处命中**（其余命中均为 `MetaStore.topicOf`，`MetaStore.cj:158`）。
  同批清单已核对确已落地的项：`QueueLog.openFrom`、`hasMessage`、`isOk`、`respondEmpty`、`countAll`、`removeByBuffer`、`pendingPeerCount`、`nodeAt`、`hasLocalQueues`、`ownersOf`、`tombstoneFloor` 在非测试代码中命中数均为 0；`scanAfter` 按清单保留并已在 `QueueLog.cj:230-235` 标注「测试与运维观测 API」。
- **描述**：两处都不影响运行（`length > MAX_RECORD_SIZE` 已覆盖 4 GiB 声明长度；`topicOf` 无人调用），但会让读者以为「这里可能存在负长度」，也让 design.md 的处置清单失去「已清零」的证据力。死代码本身归 `MQMatcher` / `QueueLog` 所在代码部分统计，本部分只记台账不一致。
- **建议**：删掉 `length < 0` 条件（保留 `== 0` 与 `> MAX`）；删除 `MQMatcher.topicOf`。design.md §4.2 增加「状态」列（已删 / 保留 / 待做），避免清单与代码再次分叉。

### [轻微][存量] #12 `stats` 的三个 `skipped*` 列只有列名、没有口径说明

- **位置**：`fmq/README.md:100-102`（列名）、`:104-109`（只解释了 `backlog` / `lagMs` / 四个计数器）、`fmq/README_en.md:117-128`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.2「缺关键段落」、§13「文档与实现一致性」
- **证据**：静态确定 —— 三列语义完全不同：段缺失导致记录不可读（`GroupCursor.cj:160-169`，标记已决 + WARN + 计数）、组内无订阅匹配（`:326-335`，DEBUG + 计数）、BODY 不可评估（`:310-325`，WARN + 计数 + 向消费者报一次 `FILTER_UNSUPPORTED_BODY`）。
- **描述**：`skippedUnreadable` 意味着**数据已经读不到**（运维必须介入），`skippedNoMatch` 是正常过滤行为。只给列名会让值班人员无法区分「消息坏了」和「没人订阅」。
- **建议**：指标段落补三行口径，每行含「含义 / 日志级别 / 是否需要运维动作」。

### [轻微][存量] #13 备份章节描述了「恢复」用途，但仓内没有恢复入口与恢复步骤

- **位置**：`fmq/README.md:59`（`备份载荷携带每组真实位点（cursors），恢复时据此不回放已确认消息`）、`fmq/README_en.md:65-66`；对照 `fmq/README.md:151`（`无自动故障转移：备份副本只保证落盘，不自动接管`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现（缺入口）」
- **证据**：静态确定 —— `fmq/src`、`f_mq/src` 检索 `restore` / `恢复` 只有「游标段缺失后跳到后继段」「节点复活重同步」等不相关命中，没有从 `<segmentedLogDir>/backup/**` 读回记录或位点的生产代码；`BackupStore` 只提供写入、枚举、关闭（`fmq/src/server/BackupStore.cj:206-255`）。规格侧「从备份位点重建游标」只写成用例场景（`fix-fmq-full-audit` metadata-cluster:358-362），`doc/backlog.md:8-11` 也把「备份无法恢复消费进度」列为遗留项——当前补齐的只是位点数据，没有补齐恢复动作。
- **描述**：读者看到「恢复时据此不回放已确认消息」会以为存在 `fmq restore` 之类入口或至少一段手工步骤，实际两者都没有。这句话只能理解为「位点数据本身完整、将来做恢复时可用」。
- **建议**：改成「备份位点已随副本落盘，**当前版本不提供恢复命令**」，并给出手工恢复的目录拷贝与 `metas/` 重建步骤；短期不做就在「已知限制」加一条「无恢复工具」。

### [轻微][存量] #14 配置默认值在 6 处重复维护，无单一来源（当前逐项核对一致）

- **位置**：`fmq/README.md:41-54`、`fmq/README_en.md:45-58`、`fmq/doc/spec/add-fmq-message-queue/specs/fmq/server-runtime/spec.md:9-20`、`fmq/doc/spec/fix-fmq-full-audit/specs/fmq/server-runtime/spec.md:9-22`、`fmq/src/config/MQConfig.cj:54-64` 与 `:355-369`（`helpText`）、`fmq/fmq.sh:20-58`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「字面量复制」（同一张默认值表散落多处）
- **证据**：静态确定 —— 12 个键（`port 2350`、`ackTimeout 10s`、`deadMsgThreshold 3`、`deadMsgTTL 72h`、`segmentedLogDir /var/log/fmq/segmentedLogs`、`deadMsgDir /var/log/fmq/deadMsgs`、`segmentedLogMaxSize 1G`、`segmentedLogTTL 72h`、`backup 0`、`tombstoneTTL 7d`、`antiEntropyInterval 30s`、`mqClient_hosts` 必填）在 6 处**当前完全一致**，未发现行为漂移；`helpText` 与 README 表一一对应。
- **描述**：改一个默认值要同步 6 处（2 份文档、2 份 delta、1 处 `helpText`、1 处 shell 注释）。`README.md:27-28` 与 `fmq.sh:9-11` 已经出现「脚本已 export 全部配置项」与「有默认值的项一律注释掉」的同句矛盾，说明这条复制链已经在漏（该处只是措辞问题，未单列为缺陷）。
- **建议**：加一条 `MQConfig_test` 用例：由 `MQConfig.DEFAULT_*` 生成 `k = v` 行，逐行断言 `README.md` / `README_en.md` / `helpText` 中存在同一行；英文文档只改说明语言、不改键名与默认值。

**范围外提示**（不占本部分统计，留给对应代码部分）：
- `MQUsage.managerHelp`（`fmq/src/MQUsage.cj:49-68`）与 `MQManagerArgs.helpText`（`fmq/src/manager/MQManagerArgs.cj:91-110`）是**逐字相同**的同一段帮助文本，属 §2 字面量复制，改一处漏一处会让 `fmq manager --help` 与解析失败提示分叉。
- `MQMatcher` 的类注释写「BODY 无法解码…由调用方决定『不投递且不越过』」（`fmq/src/queue/MQMatcher.cj:72-73`），而 `GroupCursor.cj:310-325` 的实际处理是「不投递且越过」——注释与实现相反。

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分无堆内存量级证据，故只给 1 条 CPU 方案与 1 条工程化方案；性能结论均无基线。

### [CPU] `mqServer_backup = 0` 时在装配期短路发布路径的备份调用

- **现状**：默认配置 `backup = 0`（`MQConfig.cj:62`），但每条发布都在落盘后进入 `BackupReplicator.record`（`MQCommandExecutor.cj:279-280`）。`record` 的 `backup <= 0` 分支先调 `warnRateLimited`（内部取 `Mutex` + `DateTime.now()`，`BackupReplicator.cj:313-321`）再返回——注意它**没有**进入容量锁 `synchronized(lock)`（该锁在 `:125` 之后）。即每条消息多出 1 次互斥获取 + 1 次时钟读取 + 每 1000ms 一条日志。
- **方案**：`record` 首行 `if (backup <= 0) { return }`，并把「备份关闭」提示改成启动期一条 INFO（`MQServer` 装配时判断 `options.backup <= 0`）；保留 `closed` 分支的限流 WARN（关闭阶段确有在途写入）。
- **预期**：省掉每发布的 1 次 mutex 与 1 次时钟读取，并消除默认部署下每秒一条误导性 WARN（#9）。端到端 p50/p99 改善幅度待测。
- **代价**：失去运行期「备份被丢弃」的周期提示（改为启动期一条）；若运维依赖该 WARN，需同步改 README:58。
- **验证**：`cjpm bench -O2`（或 `cjprof record`），单节点 `backup = 0`、1 生产者 1 队列、5 万条 512B、5 轮取中位数与离散度，对照改前/改后的 publish 延迟与 CPU；另抓 60s 稳态日志，确认 WARN 从 ~60 条/分钟降为 1 条。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [工程化] 配置默认值单一来源 + 文档一致性用例

- **现状**：12 个配置键的默认值在 6 处复制（见 #14），当前一致但已出现过措辞漂移。
- **方案**：`MQConfig.helpText()` 由「键 / 说明 / 默认值」常量表生成；README 表格改为在测试里逐行断言（`k` 与 `v` 必须同时出现在两份 README 的表格行中）。
- **预期**：默认值漂移从「线上发现」降为 `cjpm test` 失败；收益是防未来分叉，不是修当前错误。
- **代价**：`helpText()` 多一层生成逻辑（数十行）；README 表格不能自由排版。
- **验证**：新增 `MQConfig_test` 用例，故意改错 README 某行默认值，断言用例变红；再改回。
- **证据状态**：`无基线（待验证，不进 tasks）`——非性能项，无需基准。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `backup = 0` 时每次发布取 `BackupReplicator` 的限流锁，会在高并发发布下形成串行点 | `fmq/src/cluster/BackupReplicator.cj:114-120`、`fmq/src/server/MQCommandExecutor.cj:279-280` | 锁等待占比、发布 QPS 上限 | 单节点 `backup = 0`，4/8/16 生产者线程各发 10 万条；`cjprof` 采线程状态（BLOCKED 时长）与 publish p99，对照短路后的同负载 |
| 2 | `stats` 的实时扫描在超大积压时耗时可观，并可能拉高同队列消费的 P99 | `fmq/src/server/ConsumeService.cj:178-262`、`fmq/README.md:111-112` | 单次扫描耗时与积压条数的关系、对消费延迟的影响 | 造 10 万 / 100 万条积压，`stats` 前后分段计时；同时并发 `CONSUME` 观察 P99（`cjprof` + 分段计时） |
| 3 | 默认配置下每秒一条「dropped backup」WARN 会放大日志写入开销并淹没真实告警 | `fmq/src/cluster/BackupReplicator.cj:114-120` | 日志占发布路径耗时比、日志文件增长速率 | 稳态跑 10 分钟，统计日志行数与 publish CPU 占比；对照关闭该 WARN 的同负载 |
| 4 | 存在「从不消费的组」时备份盘无界增长（#3 的量化） | `fmq/src/cluster/LogCleaner.cj:40-41`、`96-113` | 24h 持续发布下 `backup/` 的段数与字节数 | 单组不消费 + `backup = 1` + 固定速率发布 24h，每小时记 `du -sh segmentedLogDir/backup` 与段数；预期段数单调增、无回收 |
| 5 | 组级 FIFO 在多订阅 + 延迟下不成立：队首未到期记录若只匹配 S1，会被登记为 S1 的未决项，S2 的扫描继续前进并可能先拿到第 2 条 | `fmq/README.md:93` vs `fmq/src/queue/GroupCursor.cj:302-309`（`entries.add` 后不 return，继续 `advance`） | 多订阅场景的实际投递顺序 | 写 `GroupCursor_test`：S1(tag a)/S2(tag b) 在线，R1(tag a, 未到期)、R2(tag b, 已到期)；断言 S2 首次 `consume` 是否返回 R2。若返回 R2，README 的「FIFO」需限定为「同一订阅内 FIFO」 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/fmq.part1.txt` 一一对应（20 行，全部读完）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fmq/README.md` | .md | ✅ | 配置表 / 关闭顺序 / 存储布局 / 命名限制与源码逐条一致；见 #1 #2 #3 #5 #7 #8 #9 #12 #13 #14 |
| 2 | `fmq/README_en.md` | .md | ✅ | 与中文版逐节对应，无整节缺失；`each commit` 差异见 #10，其余同上 |
| 3 | `fmq/doc/backlog.md` | .md | ✅ | 归档清单，P0 四项已过期且行号漂移，见 #6；P1#8「死信无读取接口」仍成立，见 #8 |
| 4 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/consume-semantics/spec.md` | .md | ✅ | 见 #4（136-149 自相矛盾）；死信阈值「投递 4 次进死信」与 `GroupCursor.cj:184` 的 `deliverCount > threshold` 一致 |
| 5 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/manager-cli/spec.md` | .md | ✅ | 6 子命令与 `MQManagerArgs.parse` 的参数个数校验一致（`registerTopic` 2~3 个操作数）；「配置参数不能前置」已被后续变更放宽 |
| 6 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | 轮转分配 `(start+i)%nodeCount`、目录布局、编码规则与 `MQAssignment` / `MQFileNames` 一致；177 行是 #3 的规格依据 |
| 7 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/queue-storage/spec.md` | .md | ✅ | 段布局与 `effectiveMaxRecord`、游标文件格式一致；「位置失效抛 `IllegalArgumentException`」已被后续改为跳段恢复（演进项，不算缺陷） |
| 8 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/server-runtime/spec.md` | .md | ✅ | 11 个配置默认值与 `MQConfig.cj:54-64` 一致；命令矩阵与 `MQCommandExecutor` 一致 |
| 9 | `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/consume-semantics/spec.md` | .md | ✅ | 延迟语义（23 位时间戳、队首阻塞）与 `publishTime` / `isDue` 一致；缺 5 分钟容差（#7，README 侧也缺） |
| 10 | `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/manager-cli/spec.md` | .md | ✅ | `stats [topic]`、`delaying=` 解析与 `MQManager.run`、`MQManagerArgs.parse` 一致 |
| 11 | `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | `delayingMs` 落盘与复制链路存在（`MQTopicAssignment.delayingMs`） |
| 12 | `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/metrics/spec.md` | .md | ✅ | 10 项指标口径；`lagMs`「最早一条」与实现不符，见 #1 |
| 13 | `fmq/doc/spec/fix-fmq-full-audit/specs/docs/spec.md` | .md | ✅ | 文档一致性验收口径（7 子命令 / 备份语义 / 已知限制两条）；子命令与备份语义满足，已知限制见 #8 |
| 14 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/consume-semantics/spec.md` | .md | ✅ | 64-70 行是 #2 的依据（两态 MUST NOT 混用，但未定义第三态）；确认归属 / 断链立即失效与 `GroupCursor.ack`、`sweep` 一致 |
| 15 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/manager-cli/spec.md` | .md | ✅ | 四类失败文案互斥（`Failure`）与 `MQManager.report` 一致；输出可断言已落地（`sink`） |
| 16 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | 墓碑 / revision / 远端校验与 `MetaStore`、`MetaSyncer` 一致；备份段保留（177）是 #3 依据 |
| 17 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/metrics/spec.md` | .md | ✅ | 11 列 TSV 与「扫描失败返回 INTERNAL」与 `ConsumeService.stats` 一致；列数已被后续变更扩到 14（演进项） |
| 18 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/queue-storage/spec.md` | .md | ✅ | 记录边界（4B 大端 + 64 MiB）、位点 fsync、段 TTL 双源（内存 + 磁盘位点）与 `QueueLog` / `CursorStore` 一致 |
| 19 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/server-runtime/spec.md` | .md | ✅ | 启动校验 7 条与 `MQConfig.validate` 逐条对应；关闭异常隔离与 `closeSteps` / `closeDone` 一致 |
| 20 | `fmq/doc/spec/fix-fmq-postfix-audit/design.md` | .md | ✅ | §4.2 处置清单还有 2 项未落地（#11）；§6「stats 增列」与 `MQManagerOutput.stats` 的 `>= 11` 兼容解析一致 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性（文档语义完整性）#2、#3；设计（规格自洽）#4；可读性 #5。安全性：本部分无凭据、无注入面，README 已如实披露「manager 无强身份隔离、客户端无注册入口」（`MQClient` 仅有 publish / subscribe / consume / ack / unsubscribe / close / isClosed，已核对），未命中。语言特性：文档不涉及语言语义，未命中 |
| §1 死代码 | 1 | 本部分无 `.cj`，机械动作改为「文档引用 / 处置项是否仍存在」：`design.md` §4.2 的 21 项逐项全仓检索——`QueueLog.openFrom`、`hasMessage`、`isOk`、`respondEmpty`、`countAll`、`removeByBuffer`、`pendingPeerCount`、`nodeAt`、`hasLocalQueues`、`ownersOf`、`tombstoneFloor` 非测试命中均为 0（已删）；`scanAfter` 保留且已标注「测试与运维观测 API」；唯 `QueueLog.cj:403` 的 `length < 0` 恒假分支与 `MQMatcher.topicOf`（零引用）仍在 ⇒ #11。README 清单里的每个符号逐个定位到声明处，全部存在（问题在可见性与同名歧义，见 #5） |
| §2 重复逻辑 | 1 | 文档层：12 个配置默认值在 6 处复制（#14，已核对当前一致）；`README.md` ↔ `README_en.md` 为翻译关系（§13 检查，差异见 #10）；三代 delta spec 是 OpenSpec 变更记录（每代只写增量）不判重复；`stats` 口径在 README / 两份 metrics spec / `STATS_HEADER` / `ConsumeService.stats` 五处描述，逐列比对一致，未命中。代码层顺带命中 `MQUsage.managerHelp` 与 `MQManagerArgs.helpText` 逐字重复（见「范围外提示」，不计入本部分） |
| §3 空实现 | 0 | 文档承诺的 6 类能力逐个对照实现入口：7 个 manager 子命令（`MQManager.run` 全分支有实现）、`stats`（`ConsumeService.stats`）、备份（`BackupReplicator`）、退出钩子（`installExitHooks`）、`--server` 缺省值（`MQManagerArgs.cj:83-87`）、`fmq.sh` 三个动作（脚本有实现）。无「文档承诺 + 空实现」配对；死信重放不是空实现而是缺接口（#8） |
| §4 栈溢出 | 0 | 文档未承诺递归结构；实现侧消费 / 统计 / 清理均为循环迭代（`GroupCursor.next`、`ConsumeService.stats`、`LogCleaner.cleanOnce`），无递归解析 |
| §5 OOM | 0 | 堆侧无判据（本部分无代码）；文档声明的有界化均与实现一致：备份队列 `capacity = 8192`（`BackupReplicator.cj:93`）、`retired` 4096 FIFO（`MQRetiredSubscriptions.cj:29`）、段上限与单条记录上限联动、`stats` 单趟扫描不物化。文档里唯一的「无界增长」主张是备份**磁盘**，已按 §13 记入 #3 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；「发布路径取备份限流锁」「stats 扫描耗时」缺自耗时占比与调用路径 ⇒ 待验证假设 1–3，不写成缺陷 |
| §6.2 大粒度锁 | 0 | 唯一线索是发布主路径上的 `BackupReplicator` 限流锁，缺持有时长与竞争线程数，按铁律只能进待验证假设 1 |
| §6.3 并发串行 | 0 | 文档未承诺并行度；备份明确写「独立工作线程、发布只入队」且与 `BackupReplicator.cj:68-78` 一致，不存在「文档说并发、实现串行」的落差 |
| §6.4 低效算法 | 0 | 文档描述的算法均为单趟扫描（`stats` 单读流、`GroupCursor` 顺序读），未发现 O(n²) 承诺；`stats` 的线性扫描成本已列入优化方案（无基线） |
| §7 降堆内存方案 | 0 | 本部分无「持有什么 / 多大 / 活多久」的量化证据（文档只声明上限、无峰值实测），堆方案只能是猜测，故不写 |
| §8 降 CPU 方案 | 1 | 优化方案「`backup = 0` 时装配期短路」（`无基线（待验证，不进 tasks）`）；另有 1 条工程化方案（默认值单一来源），不计入 CPU |
| §9 local mode 可行性 | 0 | 本部分无函数体，无法做逃逸检查，收益也无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 3 | #1（`lagMs` 口径）、#2（匹配者离线被越过）、#9（默认配置每秒 WARN）。其余读到的边界 / 空值路径——`QueueLog.startPositionOf` 归一化、`GroupCursor.ack` 的 `delivered` 门槛、`ConsumeService.ack` 的 `queueIndex` 校验、`BackupStore.saveCursor` 回退保护、`LogCleaner` 逐对象 try/catch——均核对无缺陷 |
| §12 并发安全与锁粒度 | 0 | 文档只在「发布路径不阻塞」处涉及并发；`BackupReplicator.record` 的临界区只含容量检查与入队、`BackupStore.append` 的 get-or-create 有独立锁，未发现「文档承诺线程安全但实现无同步」的项；锁竞争比例见待验证假设 1。代码侧的锁粒度判定留给第 2–7 部分 |
| §13 文档一致性 | 6 | #3、#4、#6、#7、#10、#11；#1 / #2 / #5 与 §11 / §14 同源，不重复计数 |
| §14 功能完备性与 README 覆盖 | 3 | #5（public 清单漏项 + 混入内部成员）、#8（已知限制缺死信不可读）、#12（`skipped*` 无口径）；另 #13 记「恢复」无入口。已按 `src/` 的顶层 public 声明、7 个子命令、12 个配置项逐条对照，无「承诺功能整体缺失」项 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；20 份 `.md` 逐段核对（README 配置表 / 关闭顺序 / 存储布局 / 命名限制 / 已知限制，5 份 delta 的 Requirement 与 Scenario 逐条对照实现） |

## 模块统计

> 仅统计本部分（第 1/7 部分，20 个 `.md`）。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU / 工程化） | 0 / 1 / 1 |

存量 14 条（本部分全部问题均为存量），是否纳入修复待用户决定。

## 总评

本部分只有文档，但文档质量整体偏高：`README.md` 的 12 个配置默认值、13 步关闭顺序、13 列 `stats`、备份的 64 条 / 100ms / 3 次重试、存储布局（含墓碑与备份游标文件名）、命名与长度限制，逐条都能在 `src/` 找到对应实现且数值一致；`fmq.sh` 的注释与 README 同步；`doc/spec/**` 的 `MODIFIED` 链条与源码事实基本吻合（墓碑胜负、段末尾归一化、记录上限三层防线、备份重试与位点）。没有「README 承诺的功能整体不存在」这类严重漂移。

主要风险分三类：

1. **运行时观测口径**：#1 `lagMs` 取「首个队列首条」而非「最早一条」，多队列、游标不齐时系统性偏小，积压告警会迟报。这是本部分唯一直接影响运维判断的实现偏差，建议与 `ConsumeService.stats` 的代码修复合并处理。
2. **语义缺口（可能伴随丢消息）**：#2 消费三态写了两态，「匹配订阅者离线、组内仍有人在线」被实现折叠成「无匹配」直接越过；#3 README 的「备份盘不会无界增长」与同文档的保留规则相反。#2 的代码侧定性请交给 `GroupCursor` 所在部分，若确认丢消息应按严重处理。
3. **文档滞后与台账不可信**：#6 `backlog.md` 的 P0 四项已全部落地、行号漂移；#11 `design.md` 处置清单还剩 2 项未落地（恒假分支 + 零引用死方法）；#4 旧 delta 同一节内自相矛盾且无取代标注。这类文件最容易把人带回去重做已完成的工作。

其余为表述与覆盖问题（#5 公开 API 清单、#7 5 分钟容差、#8 死信不可读、#9 默认配置每秒 WARN、#10 `each commit`、#12 `skipped*` 口径、#13 恢复入口、#14 默认值六处复制），一次 PR 可以连同中英两份改完。

无阻塞项：没有一条会导致数据错误或启动失败；#1 / #2 / #3 建议优先排期，其余可进文档整理窗口。第 2–7 部分的代码结论若与本部分冲突，以代码侧取证为准；合并时请把 #2 与 `GroupCursor` 的代码结论、#11 与 `MQMatcher` / `QueueLog` 的死代码结论各并成一条。
