# fmq 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`fmq`（105 个文件：69 个 .cj + 36 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 7 个分部分报告合并：`parts/fmq.part1..7.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [一般][存量] 备份关闭期失败的批次仍重新入队，与规格「丢弃并记 ERROR」相反

- **位置**：规格 `fmq/doc/spec/fix-fmq-postfix-audit/specs/fmq/metadata-cluster/spec.md:305-308`；实现 `fmq/src/cluster/BackupReplicator.cj:153-156`（`flushOnce` 无条件 `requeue`）、`:238-265`（`requeue` 无 `closed` 判断）、`:297-310`（`close`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」+ §11「契约与实现不符」
- **证据**：静态确定 —— `close()` 先 `closed.compareAndSwap(false, true)`（`:298`），等 `workerRunning` 变假（`:302-305`），再 `flushOnce()`（`:306`）；`flushOnce()` 拿到 `retry` 后无条件 `requeue(retry)`（`:153-156`）；`requeue` 只做 `attempts++` 与「合并回 `pending`」（`:238-260`），**没有 `closed` 分支**（对照 `record()` 在 `:121-124` 有）。工作线程此时已退出 `while (!closed.load())`（`:273`），条目不会再被发送，只剩 `close()` 末尾一条 `closed with N unsent item(s)` 汇总（`:308-309`）
- **描述**：规格原文是「关闭期间失败而需要重新入队的批次 SHALL 被丢弃并记 ERROR，MUST NOT 入队等一个已不存在的工作线程」。当前是「入队 + 轮末计数」：① 缺 topic/queue/位置级 ERROR，运维只能看到总数；② 条目在 `close()` 返回后仍留在 `pending`，与「关闭完成后若仍有未发送条目」的语义混淆（两类来源被合并计数）。数据影响有限（本就是发送失败的副本），但契约不成立
- **建议**：`requeue` 首行加 `if (closed.load()) { 逐条 log.error(含 topic/queue/position); return }`；或 `flushOnce(allowRequeue!: Bool)`，`close()` 传 `false`，把「关闭期丢弃」与「运行期重试」两条路径显式分开；补一条用例：关闭中目标不可达 → 每条有 ERROR，`pendingCount == 0`

### [一般][存量] `fmq/doc/开发计划.md` 与实现大面积漂移：3 个源路径、143/154 个用例名、多个已删成员、配置项与读取方式全部对不上

- **位置**：`fmq/doc/开发计划.md:51`、`:58`、`:60`（源路径）；`:117`（配置项数量）；`:119`（配置读取方式）；`:126`（`rootHelp`）；`:252`、`:281`、`:323`、`:362`（目标成员）；`:10`（前置状态）
- **来源**：存量 —— `git blame -L 51,51` 指向 `76912d0053`（2026-10-18），postfix-audit 的 V40/V60 只改了 4 个用例文件路径与 3 个用例名，其余未动
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「示例不能用」；`specs/docs/spec.md:206-216`（任务台账真实：每条引用须指向实际存在的文件或用例）
- **证据**：静态确定（`test -f` / `grep -rF` 逐项核对）：
  - 源路径 3 个不存在：`:51` `src/server/MQMatcher.cj`（实际 `src/queue/MQMatcher.cj`）、`:58` `src/meta/MetaSyncer.cj`（实际 `src/cluster/MetaSyncer.cj`）、`:60` `src/queue/LogCleaner.cj`（实际 `src/cluster/LogCleaner.cj`）
  - 表格里 154 个用例名中 143 个在 `fmq/src` + `f_mq/src` 零命中（仅 11 个命中）。例：计划 `rotationHappensAtMaxFileSize`，真实为 `rotationResetsOffsetAndIncrementsSequence`（`fmq/src/queue/QueueLog_test.cj:98`）；计划 `appendReturnsMonotonicPosition`，真实为 `appendThenReadAtReturnsSameBytes`（同文件 `:77`）
  - 目标成员含已删除 / 改名符号：`:281` `byGroup`/`removeByBuffer`（现 `byGroupOf`，`SubscriberRegistry.cj:98`）、`:323` `ownersOf`（下沉测试）、`:362` `self`/`nodeAt`/`indexOf`（现 `selfIndex`，`NodeRegistry.cj:82`）、`:252` `references`（现由注入的 `floorOf` 判定段保留，`LogCleaner.cj:34,78`）、`:126` `rootHelp`（现 `MQUsage.root()`，`MQUsage.cj:23`）
  - `:117` 断言 `helpText()`「含全部 10 个配置项」，实际 12 项（11 个 `mqServer_*` + `mqClient_hosts`，`MQConfig.cj:355-371`；`server-runtime/spec.md:212` 也要求 12）
  - `:119` 写 `Config.getValue<UInt16>/getDuration/getString` + `f_util.computeBytes`；实现是 `Config.getString` + `parseByteSize`，且 `MQConfig.cj:185` 明确说明**不用** `computeBytes`
  - `:10` 仍写 `fmq/src/main.cj（占位）`，而 `main.cj:70` 已有完整子命令分发
- **描述**：这是本模块唯一的 TDD 计划书（`详细设计.md` 的「开发顺序」指的就是它）。按它实现会撞上 8 个已删除 / 改名的成员与 3 个错误目录；按用例名回归找不到用例。`tasks.md:350` 却已结项「台账路径全部收敛」
- **建议**：文件头加「历史计划（2026-10）：成员签名与用例名以源码为准」；或最小改动——按当前源码重写各阶段「目标成员」、修正 3 处目录、把 10 改 12、配置读取改成 `getString` + 严格解析、删掉 `rootHelp`/「占位 main」

### [一般][存量] 台账与规格里的事实性断言不成立（W29 / `generations` / 「路径全部收敛」）

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/tasks.md:323`、`:361`、`:350`；`fmq/doc/spec/fix-fmq-postfix-audit/specs/docs/spec.md:96`
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 与事实相反」；`specs/docs/spec.md:233-236` Scenario「历史勾选与事实一致」
- **证据**：静态确定
- **描述**：
  - `tasks.md:323` 写「全仓检索无 `W29`，无需处置」、`:361` 写「W29 不存在」。W29 实际存在：`f_mq/doc/spec/fix-fmq-full-audit/verify-report.md:35`；同一变更的 `proposal.md:250` 也把 W29 列为「勾选不实」待处置项。按 `specs/docs/spec.md:215`，W29 的勾选状态必须逐项核实，这里用一句不成立的检索结论绕过了核对
  - `specs/docs/spec.md:96` 写「`count`/`generations` 已删，文档不列」：`count` 确已删，但 `generations` 仍是 `SubscriberRegistry` 的私有字段并参与代次推进（`fmq/src/server/SubscriberRegistry.cj:33,49,53`）
  - `tasks.md:350` 写「台账路径全部收敛」，与发现 #2 冲突（3 个源路径仍不存在）
- **建议**：`:323/:361` 改为「W29 位于 `f_mq/doc/spec/fix-fmq-full-audit/verify-report.md:35`，属历史台账，保留勾选并注明不处置」；`specs/docs/spec.md:96` 改为「私有字段仍在，文档不列」；`tasks.md:350` 收敛为可复核表述

### [一般][存量] 规格主副本位置与仓库布局不符，`openspec/` 验收路径恒真空转

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/specs/docs/spec.md:38`、`:51-54`；`fmq/doc/spec/fix-fmq-postfix-audit/verify-report.md:14`、`:17`；`fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/queue-storage/spec.md:13`
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」；`specs/docs/spec.md:38`「归档时同步到主规格」
- **证据**：静态确定 —— `openspec/specs/` 只有 5 个与本模块无关的能力（`data-assist-compare`、`data-assist-supertypes`、`jwt-signature`、`orm-result-type-mapping`、`uring-async-io`）；`openspec/changes/` 只有 `add-f-a2a/` 与 `archive/`
- **描述**：规格把「主规格」定在 `openspec/specs/**`（:38），并把「检索『最老段』应为 0」的验收场景也放在该目录（:51-54）。该目录没有 fmq 能力，场景必然 0 命中，验收恒真；`verify-report.md:17` 自称「对照 `openspec/specs/**` 主规格」，实际无对象可对照；`:14` 的 `openspec status --change fix-fmq-postfix-audit` 在本仓库也不可复现（变更实际在 `fmq/doc/spec/`）。followups 的 `queue-storage/spec.md:13` 引 `openspec/changes/fix-fmq-verify-followups/design.md`，同样不存在
- **建议**：把「主规格」指向本仓库实际布局（`fmq/doc/spec/**` 的 capability 目录，或把 fmq 能力登记进 `openspec/specs/fmq-*`），验收串换成能命中的路径；followups 的引用改相对路径

### [轻微][存量] `verify-report.md` 的收尾结论已过期：3 条 WARNING + 4 条 SUGGESTION 实际均已修复

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/verify-report.md:6`、`:32`、`:40-89`
- **来源**：存量
- **判据**：review-checklist §13「文档过期：描述的问题已被修复，报告仍列为未修」
- **证据**：静态确定 —— 逐条对照当前文件：
  - W1（§6.11 缺 5 分钟容差）→ `fmq/doc/详细设计.md:962-963` 已写入
  - W2（`--help`/`case _` 写成不可达）→ `design.md:366-367` 已改「可达 / 保留」
  - W3（丢弃日志限流「毫秒」）→ `specs/fmq/server-runtime/spec.md:288` 已改「同一秒内限流一条」
  - S1（§5.12/§6.10 指向错）→ `详细设计.md:508` 已改 §5.12/§5.14/§6.4
  - S2（`MetaApplyResult` 片段缺 `Conflict`）→ `design.md:120-126` 已列
  - S3（「投入生产」示例仍写 `scanAfter`）→ `design.md:341` 已换 `BackupReplicator.pendingCount`
  - S4（`tasks.md` 375 例）→ `tasks.md:352` 已 376
- **描述**：报告以「剩 3 WARNING + 4 SUGGESTION」收尾，与 `tasks.md` 的 V68 全绿结论口径不一致；按它排查会去改已经正确的文档。另注：其「9 份 delta spec / 59 条需求 / 282 个 Scenario」与两模块合并统计（`f_mq` 2 份 + `fmq` 7 份）完全一致，**不是**统计错误，勿按单一目录复核成 7/45/227
- **建议**：报告末尾加「收尾状态」表，逐条标注修复位置或对应 V6x；文件头注明「第四轮快照，后续见 `tasks.md` V55–V68」

### [轻微][存量] queue-storage 规格对「段缺失恢复」三套措辞并存，且限流阈值相差 100 倍

- **位置**：`.../specs/fmq/queue-storage/spec.md:126-127`（「每秒最多一条」）vs `:164-167`（「不超过约 100 条/秒」）；措辞三处：`:126`「最接近的更大段」、`:250`「最近的后继段」、`:252`「编号更大的最近现存段」
- **来源**：存量
- **判据**：review-checklist §2「同一规则换写法重复表述」+ §13「规格自身矛盾」（该变更 `specs/docs/spec.md:38-47` 自己要求「唯一说法」）
- **证据**：静态确定 —— 实现为一秒窗口限流一条（`fmq/src/queue/WarnLimiter.cj:34` `windowMs = 1000`），不是 100 条/秒
- **描述**：本变更的核心整改对象就是「四种说法收敛为一种」，结果仍是三套措辞；Scenario 的量化值与正文差两个数量级，照 Scenario 写用例会得到与正文冲突的期望
- **建议**：正文只保留一处定义（「跳到编号大于起点段的最近现存段起点 + WARN；同一 `(topic, queue, 位置)` 每秒最多一条」），其余改为引用；Scenario 改为「100 轮不可读 ≤ 1 条日志」

### [轻微][存量] docs 漂移表 §5.10 的目标字段少列 `nextStartNode`

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/specs/docs/spec.md:78`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `MQMetaSnapshot` 有 5 个字段（`f_mq/src/base/payload/MQMetaSnapshot.cj:29-36`：`topics`/`groups`/`nextStartNode`/`tombstones`/`revision`）；`f_mq/doc/详细设计.md:447-457` 已列全 5 个；漂移表却要求「列 `topics`/`groups`/`tombstones`/`revision`」
- **描述**：同文件 `:102-105` 的 Scenario 要求「字段集合完全一致」。按漂移表执行会把已经正确的文档改错（删掉 `nextStartNode`），修复口径反向
- **建议**：`:78` 的目标值补 `nextStartNode`，与 §5.10、源码三方一致

### [轻微][存量] `tasks.md` 27.4 / 28.9 的标题与括号结论相反

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/tasks.md:295-296`（27.4）、`:320-324`（28.9）
- **来源**：存量
- **判据**：review-checklist §13「文档表述与事实相反」+ 可读性 / 可维护性
- **证据**：静态确定 —— 27.4 标题写「删除不可达分支（…`main --help`、`MQManager case _`）」，括号内写「二者语法/实际可达，保留」；28.9 标题写「V9、26.1、W12/W29 取消不实勾选并注明原因」，结论写「均属实，保留勾选」。两处均已 `[x]`。源码中 `--help`、`case _` 均在（`fmq/src/main.cj:70`、`fmq/src/manager/MQManager.cj:98`）
- **描述**：同一行既说删除又说保留，台账被当验收依据时会误判「这两个分支已删」；28.9 的「取消勾选」与「保留勾选」同样互斥
- **建议**：标题改结论式：「27.4 处理 4 处候选分支：删 2 处、保留 2 处（附原因）」；「28.9 复核历史勾选：V9/26.1/V29 属实维持，W29 见 `f_mq` 归档」

### [轻微][存量] 管理端「分配」示例用字母节点号，与真实数字输出不符

- **位置**：`.../specs/fmq/manager-cli/spec.md:24`
- **来源**：存量
- **判据**：review-checklist §13「示例不能用」
- **证据**：静态确定 —— 真实输出为 `分配：${assignments(owners)}`（`fmq/src/manager/MQManagerOutput.cj:47`），节点号是数字；同变更 `specs/docs/spec.md:98` 的样例是 `分配：0→0,1→1`
- **描述**：`0→A,1→B` 会让按它写断言的用例永远失败，或诱导实现改成字母
- **建议**：`:24` 改为 `0→0,1→1`

### [轻微][存量] 同一变更的 proposal/design/tasks/verify-report 在 `f_mq` 与 `fmq` 各存一份完全相同的副本

- **位置**：`f_mq/doc/spec/fix-fmq-postfix-audit/{proposal,design,tasks,verify-report}.md` ↔ `fmq/doc/spec/fix-fmq-postfix-audit/` 同名文件
- **来源**：存量
- **判据**：review-checklist §2「跨文件复制」（文档形态：同一内容两处维护）
- **证据**：静态确定 —— `diff` 四对文件全部无差异
- **描述**：任何修订都要双写；本部分 #3/#5/#8 在两份副本里同时存在，已证明同步成本，勾选状态尤其容易漂移
- **建议**：保留一份为权威副本，另一份改为一行指针（说明「变更跨 f_mq/fmq，权威副本在 X」）

<!-- 第 3 部分 -->

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

<!-- 第 4 部分 -->

### [严重][存量] 远端 REGISTER 的 `queueNum` 无上限，直接决定数组长度与队列目录数，可被单个请求打成 OOM

- **位置**：`fmq/src/meta/MQAssignment.cj:37`（`Array<Int64>(queueNum) ...`）；缺少上限校验的位置：`fmq/src/meta/MetaStore.cj:225-233`、调用链上游 `fmq/src/cluster/MetaSyncer.cj:117-119`、`fmq/src/server/MQCommandExecutor.cj:106-114`
- **来源**：存量（快照基线无 diff）
- **判据**：review-checklist §5（按不可信长度预分配 / 无界容器）、§11（缺少边界校验）
- **证据**：静态确定 —— 全链只有 `queueNum < 1` 的下界判断：
  - `MetaStore.cj:225` `if (meta.queueNum < 1 || nodeCount < 1) { return (Conflict, None) }`
  - `MetaSyncer.cj:117` `if (meta.queueNum < 1) { throw MQServiceException(INVALID_TOPIC, ...) }`
  - `MQCommandExecutor.cj:106-114` 只校验 `MQTopic.isValid(meta.topic)`，随后 `syncer.registerTopic(meta)`（`meta` 直接来自请求载荷）
  - `MQAssignment.cj:30-37` 只校验 `queueNum < 1`，然后 `Array<Int64>(queueNum)`
  - 规范侧也只有下界：`fmq/doc/spec/add-fmq-message-queue/specs/fmq/metadata-cluster/spec.md:28` 只写 `queueNum <= 0` 的拒绝场景
  - 全仓搜索 `maxQueue|queueNumLimit|MAX_QUEUE` 零命中
- **描述**：`fmq` 服务端没有任何鉴权（`fmq/src/server/*.cj` 搜 `auth|token|ACL` 零命中），任何能连上端口的客户端发一条 `REGISTER + MQTopicMeta(queueNum = N)` 即可：① `MQAssignment.allocate` 立刻按 N 分配 `Array<Int64>`（8N 字节，N=2^31 即 16 GB）；② 该分配发生在 `MetaStore.registerTopic` 的 `synchronized(lock)` 临界区内（`MetaStore.cj:228-242`），OOM 会连带打死整条元数据写入路径；③ 若 N 小到能分配成功（例如 1e6），分配结果会落盘并进入 `queues.openTopic(assignment, ...)`，按队列数建段日志/游标目录，磁盘与句柄被按请求放大。分配后 `MQAssignment.validate/validateStructure` 只做 `owners.size == queueNum` 的一致性检查，不设上限，因此磁盘与快照载荷同样能把超大 `queueNum` 带进索引。
- **建议**：在 `MetaStore.registerTopic`（或 `MQAssignment.allocate` 入口）加显式上限常量/配置项（如 `MAX_QUEUES_PER_TOPIC`），超限返回 `MetaApplyResult.Invalid` 并由 `MetaSyncer` 映射为 `INVALID_TOPIC`；同时在 `MQAssignment.validateStructure` 里加上限，挡住来自磁盘与 peer 快照的超大 `queueNum`（否则「能校验通过 = 能落盘 = 能扩散」）。

### [一般][存量] 墓碑键格式在 6 处手写重复，`MQMetaTombstone.key()` 已经存在却未复用

- **位置**：`fmq/src/meta/MetaStore.cj:480`、`fmq/src/meta/MetaStore.cj:616`、`:618`、`:644`、`:646`；`fmq/src/cluster/MetaSyncer.cj:426`、`:437`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 跨文件重复；判据是语义相同而非语法相同）
- **证据**：静态确定 —— 权威实现在 `f_mq/src/base/payload/MQMetaTombstone.cj:61-67`（`"${KIND_TOPIC}\u{0}${topic}"` / `"${KIND_GROUP}\u{0}${topic}\u{0}${subscribeGroup}"`）。`MetaStore.tombstoneOfLocked`（616/618）与 `dropTombstoneLocked`（644/646）各自重新拼一遍同样的 `\0` 分隔格式；`topicTombstone`（480）甚至绕过 `tombstoneOfLocked` 直接拼 key；`MetaSyncer` 在缺失扫描里用同一个格式去和 `tombstone.key()` 生成集合比对（426/437）。
- **描述**：语义完全一致（同一 kind 前缀、同一 `\0` 分隔、同一字段顺序），差异只有「谁拼的」。当前实现一致，但格式分散在 2 个包 6 处、且其中一处与 `key()` 生成集合做字符串匹配：任何一次格式调整（换分隔符、加转义）只要漏改一处，就是**静默的墓碑查不中**——`applyTopic`/`applyGroup` 会认为「无墓碑」而复活已删条目，属于最难排查的一类数据错误。`MetaStore.cj:480` 尤其危险，它连 `tombstoneOfLocked` 都绕开了。
- **建议**：`MetaStore` 内统一走 `tombstoneOfLocked(kind, topic, group)`（480 处改为 `tombstoneOfLocked(MQMetaTombstone.KIND_TOPIC, topic, "")`）；`MetaSyncer.cj:426/437` 改为构造对应用例的 `MQMetaTombstone` 后再调 `key()`，或在 `f_mq` 里补一个 `static func keyOf(kind, topic, group)` 供两处共用一个入口。

### [一般][存量] 元数据「写盘」与「改内存」顺序不一致：写失败后内存已前进，重启后状态回退

- **位置**：`fmq/src/meta/MetaStore.cj:337-356`（`applyGroup` 先改 `list` 再 `writeAtomically`）、`fmq/src/meta/MetaStore.cj:236-241`（`registerTopic` 先 `topicIndex.add` 再写 `assign.meta`）
- **来源**：存量
- **判据**：review-checklist §11（资源/状态不对称、错误路径当成功）、§3（半提交）
- **证据**：静态确定 —— 同一文件中三种写入的顺序互相矛盾：
  - `registerGroup`（260-269）：`writeAtomically` → `list.add`（先盘后内存）
  - `applyTopic`（301-302）：`writeAtomically` → `topicIndex.add`（先盘后内存）
  - `applyGroup`（346-354）：`list[i] = meta` / `list.add(meta)` → `writeAtomically`（**先内存后盘**）
  - `registerTopic`（236-241）：`writeAtomically(topic)` → `topicIndex.add` → `dropTombstoneLocked` → `writeAtomically(assign.meta)`；第二处写盘失败时，内存索引、`nextStart`、已删除的墓碑文件都已生效
- **描述**：磁盘满 / fsync 失败 / 目录不可写时，`applyGroup` 抛异常给 `MetaSyncer`（对端收到 INTERNAL），但本地内存里该订阅组已存在——此进程内 `groupExists` 为真、快照会把这条组下发给 peer；重启后组文件不存在，组凭空消失。`registerTopic` 的第二处写盘（`assign.meta`）失败同理：主题已在内存与磁盘，客户端却收到失败，重试得到 `TOPIC_ALREADY_EXIST`；同时 `nextStart` 只改了内存，重启后轮转起点回退，两个主题可能拿到相同起点（分配不均衡，不破坏正确性）。现有用例 `AtomicFile_test.cj:139-163` 只覆盖了「第一处写盘就失败」，覆盖不到这两种半提交。
- **建议**：统一成「先在锁内算出新状态（不可变值）→ 写盘 → 成功后一次性替换索引」；`applyGroup` 与 `registerTopic` 的索引更新挪到所有 `writeAtomically` 之后。若维持「内存先行」，至少补一条失败回滚（catch 里恢复 `list`/`nextStart`/墓碑文件），并补一个「第二处写盘失败」的用例。

### [轻微][存量] `dispatchWith` 里的 `--help` 分支恒不成立

- **位置**：`fmq/src/main.cj:69-73`（判据来自 `:52-59` 的选取循环）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支 / 不可达语句）
- **证据**：静态确定 —— `commandIndex` 只会在 `!args[i].startsWith("-")` 的位置被赋值，因此 `let command = args[commandIndex]` 必然不以 `-` 开头，`command == "--help" || command == "-h"` 永远为假；真正的 help 判定已由 `commandIndex < 0` 分支里的 `wantsHelp(args)`（`:62`）覆盖
- **描述**：死分支不影响行为，但会误导后来者以为「第一个参数是 `--help`」走这条路径，实际它落在 `:60-68`。同文件 `:74-87` 的 `server`/`manager` 分支里再查 `wantsHelp` 是有效逻辑（`--help` 出现在子命令之后）
- **建议**：删除 `:70-73`，或在 `:60` 分支注释里写明「所有以 `-` 开头的参数都在这里被吸收」

### [轻微][存量] `runServerWith` 两个 `catch` 体完全相同，其中一个不可区分

- **位置**：`fmq/src/main.cj:121-129`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑）/ §1（兼容残留）
- **证据**：静态确定 —— `catch (e: MQConfigException) { eprintln(...); return 2 }` 与 `catch (e: Exception) { eprintln(...); return 2 }` 逐行一致；`MQConfigException <: Exception`（`MQConfig.cj:26`），单靠第一个 catch 无法产生任何不同行为
- **描述**：两段并行 catch 只增加阅读成本；若将来要给配置错误换成专属退出码或前缀，两处必须同步改，容易漂移
- **建议**：保留一个 `catch (e: Exception)`；确需区分时再按类型分支并在文案/退出码上体现差异

### [轻微][存量] `MQAssignment.cj` 导入了未使用的 `HashMap` / `Map`

- **位置**：`fmq/src/meta/MQAssignment.cj:18`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 该文件只用到 `Array`、`MQTopic.isValid`、`MQTopicAssignment`，全文搜 `HashMap`/`Map` 只在第 18 行出现
- **描述**：纯冗余导入，`cjlint` 应能报出
- **建议**：删除该 import

### [轻微][存量] `MetaStore.close()` 只置位不生效，`isClosed()` 无人读取

- **位置**：`fmq/src/meta/MetaStore.cj:84`、`:560-564`、`:566-570`
- **来源**：存量
- **判据**：review-checklist §3（空实现 / 契约与实现不符）
- **证据**：静态确定 —— `closed` 字段全文件只有三处出现（声明 84、`isClosed` 读 562、`close` 写 568），且 `registerTopic`/`applyTopic`/`applyGroup`/`writeAtomically` 等写路径都不检查它；仓内搜 `meta.isClosed` 零命中（`MQServer.cj:229` 只调 `meta.close()`）
- **描述**：作为 `Resource` 实现，`close()` 语义上应让对象不再可用，实际关闭后仍可继续写盘、继续被快照。当前只在进程退出时调用，后果有限，但「关了还能写」与 `Resource` 契约相反，也让「关闭顺序」在代码上无从验证
- **建议**：要么在写路径入口 `if (closed) { throw ... }`（明确关闭语义），要么把 `close()` 注释成「无外部资源需要释放，仅置标记供用例断言」，并删掉未被读取的 `isClosed`（`Resource` 要求实现，则保留但在注释里说明用途）

### [轻微][存量] `readAll` 短读后静默返回零填充缓冲区

- **位置**：`fmq/src/meta/MetaStore.cj:910-929`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 静默）；§5（按文件大小预分配）
- **证据**：静态确定 —— `while (got < size)` 里 `n <= 0` 时直接 `break`，随后 `bytes`（初值全 0）原样返回，`got` 不再参与任何判断；调用方（`loadTopics`/`loadGroups`/`loadTombstones`/`loadRevision`/`loadNextStart`）只按「能否 decode」区分，无法知道读短了
- **描述**：文件在 `file.info.size` 与 `read` 之间被截断（并发写者、半写、外部操作）时，返回的是「真实前缀 + 零填充」，decode 可能成功并产出一个字段被清零的条目（例如 `Int64` 位点读出 0）。正常路径下 rename 是原子的，触发面窄，故按轻微处理；同时 `Array<Byte>(size, repeat: 0)` 完全信任本地文件大小，畸形/超大文件会直接按该尺寸分配
- **建议**：`got != size` 时返回 `None` 或抛异常（调用方已有「skip corrupted」分支），并把 `size` 与一个上限常量比较后再分配

### [轻微][存量] `NodeRegistry.close()` 置位后 `clientOf` 仍会新建连接，慢速关闭会泄漏句柄

- **位置**：`fmq/src/cluster/NodeRegistry.cj:106-128`（`clientOf`）与 `:218-234`（`close`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 生命周期不对称）、§11（资源释放不对称）
- **证据**：静态确定 —— `send()` 在 `:139` 读 `closed`，通过后进入 `clientOf`；`clientOf` 全程不检查 `closed`，在 `lock` 内遇到空槽就 `createClient`。`close()` 先把 `closed` 置真（`:219`），再取 `lock` 逐个关闭并清槽（`:222-233`）；若 `send` 在 `close` 清槽之后才拿到锁，它会为已关闭的注册表新建一个连接，而 `close()` 的幂等短路（`:219-221`）使得这个新连接永远不会被关闭
- **描述**：只在「关闭期间仍有线程在广播」时触发，后果是进程退出前多一个未关闭的 TCP 连接。不影响稳态正确性，但 `isClosed()` 为真而仍持有活连接，属生命周期语义不一致
- **建议**：`clientOf` 在 `lock` 内先判 `closed`（是则返回 `None` 或抛），`send` 据此直接返回 `None`；或把 `createClient` 的建连放到锁外并在建连后复查 `closed`（复查命中则立即关闭新连接）

### [轻微][存量] `markSeen` 的「检查-然后-触发回调」非原子，复活同步可能重复执行

- **位置**：`fmq/src/cluster/NodeRegistry.cj:171-189`（`:173-175` 为判定点）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入）
- **证据**：静态确定 —— `let previous = alive[index].load(); alive[index].store(STATE_ALIVE); if (previous != STATE_ALIVE) { callback() }` 三步之间没有锁也没有 CAS；两个线程同时 `send` 到同一节点且都成功时，都会读到 `previous != ALIVE` 并各自执行一次 `revivedCallback`
- **描述**：`AtomicInt64` 已经提供 `compareAndSwap`（同文件 `close()` 就用了 `AtomicBool` 的 CAS），这里却用 load/store 组合。后果是并发的两次全量反熵同步（`syncFromPeers`），数据有元数据锁保护、不会错乱，但会放大启动/恢复瞬间的同步风暴与日志
- **建议**：改为 `if (alive[index].compareAndSwap(previous, STATE_ALIVE))` 成功者才触发回调（`STATE_UNKNOWN/STATE_DEAD` 都需触发，可用一次 CAS 失败后重读重试）

### [轻微][存量] `MQConfig` 严格解析三份同形状实现，两个字符串项走非严格路径，字节量换算未查溢出

- **位置**：`fmq/src/config/MQConfig.cj:149-158`（`strictPort`）、`:160-169`（`strictInt64`）、`:171-180`（`strictDuration`）；`:92-102`（`segmentedLogDir`/`deadMsgDir`）；`:233`（`n * (1024 ** UInt64(shift))`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复）、§11（缺少边界校验）
- **证据**：静态确定 —— 三个 `strict*` 函数体逐行同构：`Config.getString(key)` → `None` 返回 fallback → `Some(text)` 解析 → `Some` 取值、`None` 抛 `MQConfigException("${key} '${text}' is not X")`，差异只有解析函数与文案；`segmentedLogDir`/`deadMsgDir` 用 `Config.getString(...) ?? DEFAULT`，与文件头注释「显式配置项非法时启动失败（A63）」以及 `validate()`（`:277-352`）的严格姿态不一致，且 `validate()` 不校验这两个目录；`parseByteSize` 的乘法在 Int64 上无溢出检查，`mqServer_segmentedLogMaxSize=9999999999999999999P` 之类会回绕成任意值（`validate` 只挡 `<= 0`，回绕成正数即静默生效）
- **描述**：三份同构函数本身可维护性一般；真正的行为缺口是「空串目录被接受」（`Config.getString` 原样返回值、不做空值归一，见 `f_config/src/Config.cj:186-198`，因此 `--mqServer_segmentedLogDir=` 这类写法会拿到 `Some("")` 而不是 `None`，`??` 不生效，最终得到空路径；空串是否真的被写入参数表取决于 `f_config` 的解析，属 `待确认`）与「字节量回绕」。两者都属启动期配置健壮性，后果是数据写到意外位置或段上限变成非预期值
- **建议**：抽一个 `private static func strict<T>(key: String, fallback: T, parse: (String) -> ?T, kind: String): T`（错误文案按 `kind` 参数化，保留现有三处文案的差异）；目录项改为 `strictString`（空串视为非法）并纳入 `validate()`；`parseByteSize` 用 `Int64` 上界检查或改为 `checked` 乘法后再返回

### [轻微][存量] `MetaStore.registerTopic` 用 `Conflict` 表达「参数非法」，与枚举注释冲突

- **位置**：`fmq/src/meta/MetaStore.cj:225-227`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名/注释不符）
- **证据**：静态确定 —— `Conflict` 的注释是「同 revision 同 origin 但内容不同的冲突」（`:31`、`:290-294` 的真实用法），而 `:225-227` 在 `queueNum < 1 || nodeCount < 1` 时也返回 `Conflict`；`MetaStore` 已有专表「载荷结构非法」的 `Invalid`（`:35`）
- **描述**：调用方 `MetaSyncer.registerTopic`（`:136-137`）对 `_` 统一映射成 `INTERNAL`，因此「`queueNum=0`」这条本应是 `INVALID_TOPIC` 的请求会被报成服务端内部错误。当前上游已在下界处先拦（`MetaSyncer.cj:117`），实际不暴露，但语义分层已经错位
- **建议**：改成 `MetaApplyResult.Invalid`，并在 `MetaSyncer` 的 `Invalid` 分支映射为 `INVALID_TOPIC`

### [轻微][存量] `AtomicFile.isUnsupportedFsync` 靠错误消息子串判定平台能力

- **位置**：`fmq/src/meta/AtomicFile.cj:99-103`（使用点 `:88-95`）
- **来源**：存量
- **判据**：review-checklist §11（错误分类依赖文案）
- **证据**：静态确定 —— 判定逻辑是 `e.message.toAsciiLower()` 是否包含 `not support` / `unsupported` / `operation not permitted` / `invalid argument`；异常类型、errno 均未参与
- **描述**：把 `EPERM`（真实权限问题）归为「平台不支持」会只记 DEBUG 并继续，掩盖权限故障；反之，若某平台/语言环境给出不同措辞（例如 `Is a directory`），目录 fsync 会被当成致命错误，让全部元数据写入失败。当前在已测平台上行为正确（`AtomicFile_test.cj:130-135` 固定了四条文案），跨平台/本地化下属 `待确认`
- **建议**：优先按异常类型或 `errno` 判定；确无结构化错误可用时，把「平台不支持」的判定收窄到 `not support`/`unsupported`，`operation not permitted` 单独按 WARN 记录而不是静默跳过

### [轻微][存量] `send` 把「下标越界」记成「节点不可达」

- **位置**：`fmq/src/cluster/NodeRegistry.cj:142-150`
- **来源**：存量
- **判据**：review-checklist §11（错误信息误导）
- **证据**：静态确定 —— `try` 块内的 `clientOf(index)` 对 `index` 越界抛 `IllegalArgumentException`（`:110-112`），被同一个 `catch (e: Exception)` 捕获后 `markFailed(index)`（内部有边界保护，不会越界）+ `log.warn("send to node ${index} failed")`
- **描述**：调用方传错下标时，日志表现为网络故障，排查方向被带偏；`isKnownDead` 对越界下标返回 `true`（`:206-211`），进一步把编码错误伪装成「节点已死」
- **建议**：把越界检查移到 `try` 之外（或先做 `index` 范围校验再进 `try`），越界直接抛 `IllegalArgumentException` 给调用方

### [轻微][存量] 测试代码的可读性：蛇形命名与拼写错误、`ConfigSandbox` 的未使用命名参数

- **位置**：`fmq/src/cluster/MetaSyncer_test.cj:856`（`syncer_setup`）、`fmq/src/cluster/MetaSyncer_test.cj:504`（`concurrentRegisterThemeThrowsAlreadyExist`）、`fmq/src/config/MQConfig_test.cj:344`（`init(keys!: Array<String> = ALL_KEYS)`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用：命名参数从未被传入）、通用维度「可读性/命名」
- **证据**：静态确定 —— 全仓搜 `syncer_setup` 只有定义与 `:848` 一处调用，是唯一非驼峰的方法名；`Theme` 应为 `Topic`（用例内注册的是 `MQTopicMeta`）；`ConfigSandbox` 的两处构造（`:32`、`:43`）都不传 `keys`，该参数无任何调用方
- **描述**：不影响正确性；`:856` 的辅助函数只是「新建 syncer 并 `syncFromPeers()`」，与其它用例内联写法并存，属可合并的小工具
- **建议**：改名为 `syncOnce`/`runSync` 并改为 `private static`；修正 `Theme → Topic`；删除 `keys!` 参数（或让「只保存部分键」的用例真的用上它）

<!-- 第 5 部分 -->

### [一般][存量] 跳过/扫描路径「每条记录一次位点落盘」，且全程持有游标锁

- **位置**：`fmq/src/queue/GroupCursor.cj:336`（no-match 分支尾部的 `advance()`）、`GroupCursor.cj:209`、`GroupCursor.cj:409`（`ack`）；落盘链 `GroupCursor.cj:482-484` → `fmq/src/queue/CursorCatalog.cj:86-91` → `fmq/src/queue/CursorStore.cj:75-90` → `fmq/src/meta/AtomicFile.cj:38-70`
- **来源**：存量（工作区快照无 diff；blame `4038804a`）
- **判据**：review-checklist §6.2（`synchronized` 内做 I/O）/ §12.2（临界区只应保护不变量）
- **证据**：静态确定 —— `next()` 整体在 `synchronized(lock)` 内（`GroupCursor.cj:120-339`）；扫描循环每遇到一条「组内无人匹配」的记录就 `entries.add(decided: true)` 后调 `advance()`；队首已是 decided 时 `advance()` 立即 `catalog.save()`；`CursorStore.save` → `AtomicFile.write` 每次都是 `exists(parent)` + `File.create(tmp)` + `write` + `fsync(file)` + `rename` + `fsync(parent)`（约 2 次 fsync、6 次系统调用）
- **描述**：一个组的 tag/filter 只命中少数消息时，一次 `next()` 会把积压里所有不匹配记录逐条「越过」，每条都落盘一次位点（2 次 fsync），全部在游标锁内完成。N 条积压 = N 次落盘，同组其它订阅者的 `next`/`ack` 全程阻塞；上层 `ConsumeService.consume` 是同步请求，直接表现为消费请求超时。正常消费路径也不轻：每条 `ack` 同样是一次 create+fsync+rename+dir fsync，且都在锁内
- **建议**：位点改成「内存 dirty + 阈值/定时 flush」（≥N 条或 ≥T ms 一次），`advance()` 只更新内存，提交放到锁外（单写者 + 原子替换引用保序）；`close()`、段切换、`recoverIfSegmentGone` 时强制 flush。崩溃时重投最后一批是可接受代价（at-least-once 已允许重复）

### [一般][存量] `entries` 无上界：一次 `next()` 即可把整段积压物化成未决项

- **位置**：`fmq/src/queue/GroupCursor.cj:57`（`entries` 声明）、`266`/`309`/`313`/`328`（四处 `entries.add`）、`477-481`（只有队首连续 decided 才会被移除）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §5（无界容器、无拒绝路径）
- **证据**：静态确定 —— 扫描循环 `while (true)` 只在「命中本订阅」或 EOF 时退出；命中同组**其它**订阅的记录以 `decided = false` 入列后继续扫描，其后的「无人匹配」记录以 `decided = true` 排在它后面，而 `advance()` 只能从队首吞并，于是整段积压全部驻留
- **描述**：只要队首有一条未决记录（分配给了迟迟不取消息的订阅者，或该记录一直不 ack），另一个订阅者的一次 `next()` 会把 `committed` 之后的全部记录各建一个 `DeliveryRecord`（每条约 60-90 B 对象 + ArrayList 槽位），百万级积压约 100 MB 常驻、千万级到 GB 级，且不会随时间回落（直到队首被确认）。`entries` 既无条数上限也无背压
- **建议**：设未决窗口上界（如 `maxPendingEntries`，达到上限即停止扫描并返回 `None`，由下一次调用续扫）；或把 `entries` 拆成「已决环 + 未决表」，靠 `committed` 边界回收而不是靠队首连续 decided

### [一般][存量] `QueueRecordReader.next` 吞掉全部读异常并标 `corrupted`，使游标的段失效恢复分支不可达、日志误报「队列损坏」

- **位置**：`fmq/src/queue/QueueLog.cj:361-370`（catch-all → `corrupt(0, -1, ...)`）；受影响分支 `fmq/src/queue/GroupCursor.cj:228-237`、误报日志 `GroupCursor.cj:242-245`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §1（不可达分支）/ §11（注释与实现不符、错误分类错误）
- **证据**：静态确定 —— `QueueRecordReader.next` 内部 `catch (e: Exception) { return corrupt(...) }` 永不外抛，`GroupCursor.cj:230-237` 的 `catch` 只能由「构造 reader 失败」（`openRecordsFrom`）触发，读取中途的异常进不来
- **描述**：段在读取中途被 TTL 清理（`LogCleaner` 与消费并发，属正常运维动作）时：①`GroupCursor.cj:230-237` 的恢复分支不可达（死分支，注释「读取中途段失效：与开流路径同样恢复」不成立）；②`GroupCursor.cj:242-245` 打出 `queue ... is corrupted at ...`，把「段被删」误报成「记录损坏」，运维会去修一个没坏的段；③本次调用既不推进也不恢复，要等下一次 `next()` 由 `openReaderAt` 重新归一化才继续。用例 `GroupCursor_test.cj:725-749` 只断言「不抛异常 + 返回 `None`」，覆盖不到分类错误
- **建议**：让 `QueueRecordReader` 区分「I/O/段缺失」与「格式损坏」两类结局（异常透传，或返回三态而非单 `Option`），只对长度头/边界校验失败置 `corrupted`；`GroupCursor` 的恢复分支改成显式返回值驱动

### [一般][存量] 段出现中间空洞时，恢复逻辑把 `committed` 直接前移到后继段并清空未决项——仍可读的未决记录被静默丢弃

- **位置**：`fmq/src/queue/GroupCursor.cj:521-551`（`recoverIfSegmentGone`：`entries.clear()` + `committed_ = LogPosition(index, 0)`）、`GroupCursor.cj:494-511`（`openReaderAt` 同样的 `entries.clear()` + 前移）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11（数据丢失）/ §12.1（状态机不变式）
- **证据**：静态确定 —— `QueueLog.startSegmentAtOrAfter` 返回**第一个 ≥ 空洞段号**的现存段，`recoverIfSegmentGone` 不校验「未决项是否都落在被跳过的区间内」；对比 `openReaderAt` 有 `movedForward` 判断（`499-507`），`recoverIfSegmentGone` 没有
- **描述**：`LogCleaner` 只删前缀段（`meta.index < floor`），正常路径不会产生中间空洞；但运维手删中间段（`GroupCursor_test.cj:752-778` 正是这种场景）时，若 `entries` 里还有落在**仍存在**的早段中的未决记录（例如 `committed = 1:50`、`scanPosition = 5:0`、段 2-4 被删），恢复会把 `committed` 抬到段 7 起点并把 `entries` 清空：段 1 里那条仍可读的记录再也不会被投递，且该段随之变成可回收——静默丢消息
- **建议**：前移前先判断「`entries` 中位置 < 新起点且所在段仍存在」的记录，存在则不清空、不跳段；或直接抛 `QueueCorruptionException` 把「段空洞 + 未决记录」暴露给上层，而不是静默前移

### [一般][存量] `QueueLog.readAt(resume: false)` 只校验段存在，offset 越界时仍返回后继段记录

- **位置**：`fmq/src/queue/QueueLog.cj:97-125`（`resume == false` 只做 `meta.index == position.seq` 的存在性检查）、`QueueLog.cj:170-189`（`startPositionOf` 在 `offset >= meta.size` 时跳到后继段）；调用点 `fmq/src/queue/GroupCursor.cj:142-152`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 注释（`QueueLog.cj:93-95`）承诺 `resume = false` 用于避免「把后继段的另一条记录当成该位置返回」，实现只挡「段不存在」，挡不住「段存在而 `offset ≥ size`」
- **描述**：段被外部截断/改写后，未决项 `offset == size` 时 `openRecordsFrom` 会归一到下一个现存段的 0 偏移，`readAt` 把那条记录的字节返回，`GroupCursor` 按 `entry.position` 投递并允许 ack 该位置：内容是别的记录的、位置被错误标为已决，后续扫描还会再投一次（同一条内容以两个位置出现）。触发需要段被截断，概率低但语义错乱，故定一般
- **建议**：`resume = false` 时把 `offset >= meta.size` 也判成 `SegmentGone`；或在返回 `Record` 前断言实际位置与请求位置一致

### [一般][存量] `DeadLetterReader.next` 把解码异常一律当流结束，损坏被静默吞掉且不关流

- **位置**：`fmq/src/queue/DeadLetterQueue.cj:88-107`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3（`catch` 静默吞异常）/ §11（资源不对称）
- **证据**：静态确定 —— `DefaultCodec.decodeData`（`f_codec/src/default/DefaultCodec.cj:778-789`）在 EOF 处**抛** `CodecException('input closed while decoding data')`，因此「正常读完」与「记录被截断/损坏」走同一个 `catch`；该 `catch` 只置 `finished = true` + 关流，不打日志
- **描述**：死信日志尾部被截断或中间损坏时，`iterate()` 把损坏点之后当成「读完了」，运维看到的死信条数静默偏小；另外 `DeadLetterReader` 不实现 `Resource`、没有 `close()`，调用方中途放弃迭代时读流要等 GC 才释放（同类 `QueueRecordReader` 是有 `close()` 的，两者不对称）
- **建议**：区分「流干净结束」与「解码失败」（先 `stream.read` 1 字节判 EOF，再解码），解码异常记 ERROR 并置 `finished`；给 `DeadLetterReader` 补 `Resource` 实现或 `close()`，`iterate` 注明调用方负责关闭

### [轻微][存量] `QueueLog.scanFrom` 的 catch-all 把未知异常折成「0 条记录」

- **位置**：`fmq/src/queue/QueueLog.cj:275-277`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3（静默吞异常）/ §11（与 `QueueLog.cj:230-235` 注释「已提交边界或目录损坏向上传播，不能解释成没有积压」冲突）
- **证据**：静态确定
- **描述**：`scanAfter` 只被用例与运维观测调用（生产 `stats` 走 `ConsumeService` 的单趟扫描，见 `ConsumeService.cj:178-262`），所以影响面限于观测口径：文件打不开等异常会显示成「没有积压」
- **建议**：只吞可预期的「段缺失」类异常并保留 WARN，其余向上抛

### [轻微][存量] `QueueLog` 两处函数各带两个相邻文档注释块

- **位置**：`fmq/src/queue/QueueLog.cj:142-155`（`resolveStart`）、`fmq/src/queue/QueueLog.cj:223-235`（`scanAfter`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §10（可读性：残留注释、注释与代码脱节）
- **证据**：静态确定 —— 两个 `/** */` 相连，前一块没有宿主
- **描述**：读代码时无法判断哪一份是当前口径；顺带发现 `resolveStart` 的 `strict = false` 分支在本仓没有调用方（唯一调用点 `ConsumeService.cj:208` 恒传 `true`）
- **建议**：合并成一块注释；确认默认 `strict = false` 是否还需要

### [轻微][存量] `CursorStore.readAll` 按文件实际大小一次性预分配，没有上限

- **位置**：`fmq/src/queue/CursorStore.cj:122-141`（126 行 `Array<Byte>(size, repeat: 0u8)`，`size` 取自 `file.info.size`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §5（按不可信长度预分配、缺少拒绝路径）
- **证据**：静态确定 —— 位点文件正常只有 16 B，代码不校验 `size`
- **描述**：位点文件被写坏/放大（磁盘故障、误操作）时按实际大小分配；需要文件已被破坏才触发，影响仅限本机，故计轻微
- **建议**：加常量上界（如 64 B），超出即按损坏返回 `None` 并记 WARN

### [轻微][存量] 父目录创建在两处重复

- **位置**：`fmq/src/queue/CursorStore.cj:77-80` 与 `fmq/src/meta/AtomicFile.cj:39-42`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2（重复逻辑）
- **证据**：静态确定 —— `CursorStore.save` 建完目录立刻调 `AtomicFile().write`，后者再 `exists(parent)` + `Directory.create` 一次
- **描述**：位点每次落盘多两次系统调用（在锁内，放大 §6.2 的问题）
- **建议**：只保留 `AtomicFile` 里那一份

### [轻微][存量] 「谓词筛选后批量删除」三处重复

- **位置**：`fmq/src/metrics/MQMetrics.cj:62-73`（`removeTopic`）、`MQMetrics.cj:76-87`（`removeGroup`）、`fmq/src/queue/CursorCatalog.cj:146-158`（`invalidateWhere`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2（换容器的重复逻辑：都是「遍历取匹配键 → 收集 → 逐个删」）
- **证据**：静态确定 —— 前两者只差 `prefix`（`removeGroup` 的前缀就是 `removeTopic` 前缀 + group + `\0`）；第三者是同一形状套在 `HashMap` + `Mutex` 上
- **描述**：同一套「先收集再删」逻辑散在三处，改动时容易只改一处
- **建议**：`MQMetrics` 内收敛成 `removeWhere(predicate)`（`removeGroup` 传更长前缀调用它）；`CursorCatalog` 保留自己的版本（必须持锁）。合并时必须保留差异点：`MQMetrics` 用 `ConcurrentHashMap` 不持锁，`CursorCatalog` 用 `HashMap` 必须持锁

### [轻微][存量] `GroupCursor.next` 内两段「回退队首」与四处「关流 + 置 None」重复

- **位置**：`fmq/src/queue/GroupCursor.cj:258-264` 与 `303-307`（同构：`!isDue` → `scanPosition = position; close(); reader = None; return None`）；`240-241`、`261-262`、`305-306`、`319-320`（同构的 `close()` + `reader = None`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2（表现形式不同的重复逻辑）/ §10（`next()` 单函数约 220 行、嵌套 5 层）
- **证据**：静态确定
- **描述**：两段回退逻辑必须保持完全一致（一条改了一条没改就是「延迟消息被提前越过」或「段句柄泄漏」），重复让这种漂移无法被编译期发现
- **建议**：抽 `rewindTo(position)` 与 `closeReader()` 两个私有方法（内部判空），把「重投」与「扫描」拆成两个私有方法

### [轻微][存量] 死代码：两个无引用的非 public 符号

- **位置 1**：`fmq/src/queue/MQMatcher.cj:76-78` `static func topicOf`（所属 `protected class MQMatcher`，成员对外不可达）
- **位置 2**：`fmq/src/queue/QueueLog.cj:433-435` `QueueRecordReader.isClosed()`（`protected` 成员 + `protected class`）
- **来源**：存量（快照无 diff；blame `f1238ea6`）
- **判据**：review-checklist §1（`protected` 只有「`public open`/`public abstract` 非 `sealed` 类的成员」才豁免；不属于该类的 `protected` 无引用即死代码）
- **证据**：静态确定 —— 全仓 `*.cj` 搜 `MQMatcher.topicOf` 零命中（含 8 个 `*_test.cj`）；搜 `isClosed()` 的命中全部打在 `QueueLog`/`DeadLetterQueue`/`QueueManager`/`Resource` 适配与其它类型上，没有一处打在 `QueueRecordReader` 实例上。仓库自有审计文档已把 `MQMatcher.topicOf` 记为「无消费者 → 删除」（`fmq/doc/spec/fix-fmq-postfix-audit/design.md:372`）
- **描述**：两个符号不会被任何调用路径触达
- **建议**：删除；`topicOf` 若要保留，改成 `internal` 并接到实际调用点

### [轻微][存量] 死代码：恒假分支 `length < 0`

- **位置**：`fmq/src/queue/QueueLog.cj:403`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `getInt32BE`（`QueueLog.cj:321-324`）用 `Int64(Byte) << 24 | ...` 组装，`Byte` 无符号，结果恒在 `[0, 0xFFFFFFFF]`，不可能为负；同仓审计文档亦记录该分支不可达（`fmq/doc/spec/fix-fmq-postfix-audit/design.md:366`）
- **描述**：`length < 0 || length > MAX_RECORD_SIZE` 的前半永远不成立，容易让读者以为长度可能是负数
- **建议**：删 `length < 0`，保留 `length == 0`（385 行已单独处理）与超限判定

<!-- 第 6 部分 -->

> 编号索引（正文与「覆盖自检」里的 `#N` 指此表；同一根因合并成一条，不按出现次数刷数量）

| # | 级别 | 标题 |
| --- | --- | --- |
| 1 | 严重 | 未校验的主题名参与目录拼接，删除路径可逃出 `logRoot` |
| 2 | 一般 | 备份位点「读-判-写」非原子，位点可回退 |
| 3 | 一般 | `cursorFloor` 把「位点读不出来」当成「组不存在」；异常被吞 |
| 4 | 一般 | `ConsumeService` 全局游标锁内含游标构造（磁盘读）与落位点（磁盘写） |
| 5 | 一般 | `close()` 先置标志再释放，失败后重试空转，剩余句柄不关 |
| 6 | 一般 | 备份 `(owner, topic, queue)` 键不校验、无上限 |
| 7 | 一般 | 备份批次的逐条状态在接收端只比数量、值被丢弃 |
| 8 | 一般 | 删除主题不清理备份副本，无位点备份永不回收 |
| 9 | 轻微 | `localTopics` 与 `close` 内逻辑复制 |
| 10 | 轻微 | `readAll` 在三个包各写一份 |
| 11 | 轻微 | `warnDropped` 重写 `WarnLimiter` 的时间窗限流 |
| 12 | 轻微 | `ConsumeService` 三处「收集 key → remove → close」重复 |
| 13 | 轻微 | 位置先后比较写三遍，边界含义不同 |
| 14 | 轻微 | `openTopic` 并发抢先分支不可达（回滚会误删对方目录） |
| 15 | 轻微 | 只增不减的注册表：`openLocks` / `owners` |
| 16 | 轻微 | `CapturingAppender.clear` / `CapturingStream.clear` 无引用 |
| 17 | 轻微 | `BackupStore.close` 遍历 `ConcurrentHashMap` 时删除 |

### [严重][存量] 未校验的主题名参与目录拼接，删除路径可逃出 `logRoot` 并递归删库

- **位置**：
  - `fmq/src/server/MQCommandExecutor.cj:172`（`onInternal` 的 `MQDeregisterPayload` 分支：只判 `kindOf() != Unknown`，不校验 `topic`/`subscribeGroup`）
  - `fmq/src/server/MQCommandExecutor.cj:177`、`fmq/src/server/MQCommandExecutor.cj:224`（`cleanupAfterDelete` → `queues.closeTopic(payload.topic, deleteFiles: true)`）
  - `fmq/src/queue/QueueManager.cj:134`–`137`（`let dir = "${logRoot}/${MQFileNames.escape(topic)}"` → `remove(dir, recursive: true)`）
  - `fmq/src/meta/MQFileNames.cj:28`（`isPlain` 把 `.` 当保留字符，`escape(".") == "."`、`escape("..") == ".."`）
- **来源**：存量（工作区快照，无 diff 可比）（`git log` 显示该分支来自 `8acb2d2a7 fix(fmq): 墓碑生效后清理对端队列/游标/订阅/计数器`，A25）
- **判据**：checklist §11（与规格/契约冲突：其它入口都校验）、§10 安全性（外部输入未校验、路径穿越）、§5（无界破坏）
- **证据**：静态确定 —— 链路逐行可闭合：`DEREGISTER + internal(META_SYNC, MQDeregisterPayload)`（`MQProtocol.metaSync(payload)`，`f_mq/src/base/MQProtocol.cj:94`）→ `onDeregister` 见 `kindOf == Internal` 直接转 `onInternal`（`MQCommandExecutor.cj:186`）→ `onInternal` 只判 `Unknown` 就 `applyRemoteDelete + cleanupAfterDelete`（`172`–`179`）→ `case Topic: closeTopic(..., deleteFiles: true)`（`226`）→ 字符串拼接 `${logRoot}/${escape(topic)}` 后 `remove(recursive: true)`（`QueueManager.cj:134`–`137`）。`topic == "."` ⇒ 目标路径就是 `logRoot` 本身，`topic == ".."` ⇒ `logRoot` 的父目录。同一 `cleanupAfterDelete` 也被 peer 墓碑回调复用（`MetaSyncer.cj:498`–`513` → `onDeleted` → `MQCommandExecutor.cj:117`），墓碑里的 `topic` 同样不经校验。
- **描述**：直连 `DEREGISTER` 路径对 Topic/Group 都做了 `MQTopic.isValid` / `MQGroup.isValid`（`MQCommandExecutor.cj:193`–`205`），但**广播/内部信封路径完全没有校验**。而 `MQFileNames.escape` 只转义不在 `[A-Za-z0-9._-]` 里的字节，`"."`/`".."` 原样输出，于是主题名成了可穿越的路径分量。fmq 服务端（`MQServer.start` → `Server<DataAny>`，无鉴权）接受任意能连上端口的客户端发来的内部信封，因此一条 `DEREGISTER` 内部消息即可让本机递归删除整个队列根目录（含其它主题段文件与 `backup/` 副本），或删除其父目录。即「元数据校验只做了一半」导致的数据销毁面。
- **建议**：① `MQFileNames.escape` 对 `"."`/`".."` 追加编码（如 `".."` → `%2E%2E`），这是源头修法；② `QueueManager.closeTopic` 删除前校验规范路径仍在 `logRoot` 之下（`Path(dir).normalize` 前缀断言），删错即抛异常而不是静默执行；③ `onInternal` 的每个子载荷分支补 `MQTopic.isValid` / `MQGroup.isValid`，与 `onDeregister` 对齐；④ 补一条用例：`MQDeregisterPayload("topic", ".")` 必须被拒且 `logRoot` 仍存在。

### [一般][存量] 备份位点「读-判-写」非原子，并发/重试下位点可回退

- **位置**：`fmq/src/server/BackupStore.cj:112`–`128`（`saveCursor`：`loadCursor` 判定后再 `writeCursor`，两步之间无锁）
- **来源**：存量（工作区快照，无 diff 可比）（`8acb2d2a7` 引入备份位点）
- **判据**：checklist §12.1（检查-然后-写入，`AtomicFile` 只保证单文件原子，不保证两次调用之间的顺序）、§11（并发正确性）
- **证据**：待确认 —— 需确认「同一 `(owner, topic, queue, group)` 是否可能被两个执行线程同时 `saveCursor`」：`MQServer` 用 200 个 executor（`MQServer.cj:183`），接收侧 `onPublish` 的备份分支逐条 `append` 后逐组 `saveCursor`（`MQCommandExecutor.cj:245`–`257`）；发送侧在 `transport.send` 返回 `None`（超时）后会重新入队重发（`BackupReplicator.cj:153`–`156`、`199`–`208`，`MAX_ATTEMPTS = 3`），超时批次与重发批次可能在接收端重叠执行。若 f_net 对同一连接串行分发则可避免，需确认 `f_net` 分发模型与重发是否可能并行。
- **描述**：`saveCursor` 的「只前进」语义依赖 `loadCursor` 的返回值，但该返回值只是读瞬间的磁盘状态。若 T1 携带 `5:0`、T2 携带 `4:0` 并发执行：两者都看到旧值 `3:0` 而通过判定，T2 后写就把位点从 `5:0` 拉回 `4:0`。后果是备份恢复点倒退（重启后从更老的位置重放，扩大重复投递面），以及 `cursorFloor` 变小导致该删的段保留更久。
- **建议**：把同 key 的「读-判-写」放进 `BackupStore.lock`（或按 key 分片锁 / 单写者队列），并在内存里维护 `key → LogPosition` 便于原子比较；`AtomicFile` 只保留落盘职责。补一条并发用例：两个线程交替写奇偶位点，终态必须是最大值。

### [一般][存量] `cursorFloor` 把「位点读不出来」当成「该组不存在」，可提前回收段；异常被静默吞掉

- **位置**：`fmq/src/server/BackupStore.cj:167`–`186`（遍历 `.cursor` 只统计 `loadCursor` 成功的组）、`fmq/src/server/BackupStore.cj:153`–`155`（`catch (_: Exception) { None }`）
- **来源**：存量（工作区快照，无 diff 可比）（`8acb2d2a7`）
- **判据**：checklist §11（错误处理缺失/静默，与规格口径不一致）、§3（静默吞异常）
- **证据**：静态确定 —— `seen[0]` 只在有可读位点时置真；只要**有一个**组可读，`floor` 就取可读组的最小段号，读不出的那个组不参与计算，且无任何日志。
- **描述**：与同仓 `CursorCatalog.floorOf` 的保守口径相反：后者对「文件在但读不出来」按 `LogPosition(1, 0)` 处理并 `log.error`（`CursorCatalog.cj:106`–`111`），注释明确「按缺失处理但必须留痕」。备份侧遇到同样情况会得出更大的 floor，`LogCleaner` 据此删除段（`LogCleaner.cj:103`），被损坏位点对应的慢组积压就被删掉；且因为异常被 `catch` 吞掉，运维看不到任何线索。
- **建议**：`cursorFloor` 区分「目录/文件不存在」与「文件存在但解析失败」：后者返回 `1` 并 `log.error`（含 owner/topic/queue/group 与文件名），与 `CursorCatalog.floorOf` 对齐；`loadCursor` 的 catch 至少记一次 WARN，不要 `None` 了事。

### [一般][存量] `ConsumeService` 的全局游标锁内含游标构造（磁盘读）与落位点（磁盘写）

- **位置**：`fmq/src/server/ConsumeService.cj:129`–`147`（`cursorOf` 的 `synchronized(lock)` 覆盖 `GroupCursor(...)` 构造）；构造内部 `GroupCursor.cj:84` → `CursorCatalog.positionOf` → 缓存未命中时 `CursorStore.load`（文件读，`CursorCatalog.cj:53`–`63`）；`ConsumeService.cj:383`–`395`、`406`–`418`、`423`–`433`（`removeTopic`/`removeGroup`/`close` 在锁内 `cursor.close()` → `catalog.save` → `AtomicFile.write`）
- **来源**：存量（工作区快照，无 diff 可比）（`12e48efd3 fix(fmq): … 段恢复下沉 …`、`a17935673`）
- **判据**：checklist §6.2（锁内做 I/O）、§12.2（临界区超出「只保护不变量」）
- **证据**：静态确定（结构）—— 临界区语句已列出；对吞吐的影响量级未测，见「待验证假设 H1」
- **描述**：这把锁本该只保护 `cursors` 这个 `HashMap` 的 get-or-create，实际把「可能落一次磁盘读的游标构造」也包了进去；`consume` / `ack` / `releaseSubscription` 每次调用都要过一次（`consume` 还是**每个本地队列一次**，`ConsumeService.cj:84`–`88`）。删除主题/组时则在锁内为每个游标写一次位点文件，删除期间所有消费/确认线程排队等文件 I/O。锁内不含回调，无死锁面；问题是持有时长不可控。
- **建议**：改成 `ConcurrentHashMap<String, GroupCursor>` + `addIfAbsent` 双检（构造放在锁外，失败方丢弃自己的实例），或按 `(topic, queueIndex)` 分片加锁；`removeTopic`/`removeGroup`/`close` 先摘出 victims、释放锁后再逐个 `close()`。改造需附并发压力用例（多线程 consume/ack + 并发删主题，断言终态与无异常）。

### [一般][存量] `close()` 先置关闭标志再释放资源，中途异常后重试直接返回，剩余句柄永不关闭

- **位置**：`fmq/src/queue/QueueManager.cj:218`–`238`；`fmq/src/server/BackupStore.cj:259`–`269`
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：checklist §11（契约与实现不符、资源释放不对称）
- **证据**：静态确定 —— 两处都是 `if (!closed.compareAndSwap(false, true)) { return }` 之后在循环里直接 `log.close()`，无 try/catch；`log.close()` 抛异常即中断循环，而 `closed` 已置真，后续调用第 219/260 行立刻返回。
- **描述**：`MQServer` 的关闭契约是「每步单独 try/catch，失败步骤可在下一次调用重试」（`MQServer.cj:234`–`238`，`closeDone` 记录成功步骤）。`QueueManager.close`/`BackupStore.close` 不满足：第一个 `QueueLog.close()` 失败后，后面所有队列/备份日志的句柄、写缓冲再也不会被关闭，重试是空转，`MQServer` 却把该步骤记为失败后继续重试，永远修不回来。
- **建议**：逐个 `log.close()` 包 try/catch 并累计失败，只在全部成功时才认定「已关闭」（或把 `closed` 拆成 `closing` 与 `closedDone` 两个状态）；`MQServer` 的重试语义才成立。补一条用例：注入一个 `close()` 抛异常的 `QueueLog`，断言其余日志仍被关闭、重试可补齐。

### [一般][存量] 备份存储对 `(owner, topic, queue)` 键既不校验也无上限，远端可驱动无界建目录与开句柄

- **位置**：`fmq/src/server/BackupStore.cj:56`–`79`（`key` 直接由载荷拼出，`logs.add` 无容量上限）；入口 `fmq/src/server/MQCommandExecutor.cj:239`–`258`
- **来源**：存量（工作区快照，无 diff 可比）（`8acb2d2a7`）
- **判据**：checklist §5（无界容器 / 长期持有）、§10（外部输入未校验）
- **证据**：静态确定 —— `logs`/`owners` 只增不减（`close()` 也不清 `owners`），`append` 对每个新 key 都 `QueueLog(dir, ...)` 建目录并持有打开的段文件；`ownerIndex`/`queueIndex` 是 `Int64`，`topic` 只过 `escape` 不做 `MQTopic.isValid`。
- **描述**：`BACKUP` 内部信封由任意可连接客户端发送，键空间完全由载荷决定：`ownerIndex` 取 `0..N`、`topic` 取任意串、`queueIndex` 取任意值，每个新组合都会新建 `<logRoot>/backup/<owner>/<topicEsc>/<queue>/` 并常驻一个 `QueueLog`（打开的文件句柄）。这与「备份目标数 × 主题数 × 队列数」的正常上界无关，属于可被外部放大的资源面（fd 耗尽 / 目录爆炸）。配合 #1 的严重问题（主题名不校验），写入位置也不受约束。
- **建议**：`append` 前校验 `ownerIndex ∈ [0, nodeCount)`、`topic` 合法、`queueIndex ∈ [0, queueNum)`；给 `logs` 设容量上限（超限丢弃并限流告警，与 `BackupReplicator` 的 `capacity` 语义一致），或改为「只接受本节点配置的备份对端」。

### [一般][存量] 备份批次的逐条状态（delivered/acked/deliverCount）在接收端只比数量、值被丢弃

- **位置**：`fmq/src/server/MQCommandExecutor.cj:249`–`257`（仅 `records.size != states.size` 比较后落 `cursors`，`states` 本身不写任何存储）；生产侧 `fmq/src/server/ConsumeService.cj:302`–`315`
- **来源**：存量（工作区快照，无 diff 可比）（`8acb2d2a7`，注释标注 A26）
- **判据**：checklist §14.1（接线缺失：数据造出来没人用）、§11（契约与实现不符）
- **证据**：静态确定 —— 全仓 `grep MQBackupState`：生产侧只在 `ConsumeService.backupStates` 构造、`BackupReplicator.statesOf` 打包；接收侧除 `size` 比较外无任何读取（`f_mq` 只有定义）。
- **描述**：`MQServer` 装配时特意注释「备份要携带真实消费状态与位点（A26）」（`MQServer.cj:111`–`112`），`ConsumeService.backupStates` 也逐条算了 `ackedByAll` 与 `deliverCountOf`；但接收端只把它们当作「批次完整性校验位」用，值不落盘。备份恢复时投递次数从 0 重算、`acked` 标记丢失，死信阈值（`deadMsgThreshold` 是重试次数）需要重新累计——与「备份可重建消费状态」的预期不符。同时这笔计算正是最贵的一段（每位置全表扫游标，见优化方案 O2），算完就丢。
- **建议**：二选一并写进文档：① 接收端把 `states` 落到备份目录（如 `states/<seq>_<offset>.state` 或在恢复工具里读批次文件），由恢复流程消费；② 明确「state 仅供外部工具/诊断」，把它从热路径移出（或改成按位点区间聚合成一条），别再每批逐条算。

### [一般][存量] 删除主题不清理备份副本，且无位点的备份队列永不回收 → 磁盘无界增长

- **位置**：`fmq/src/server/MQCommandExecutor.cj:224`–`235`（Topic 分支只清本地队列/游标/订阅/指标，无备份分支）；`fmq/src/server/BackupStore.cj:158`–`187`（无位点返回 `1`）；`fmq/src/cluster/LogCleaner.cj:96`–`113`（`meta.index < floor`）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：checklist §5（无界增长：磁盘）、§11（资源释放不对称）
- **证据**：静态确定 —— `floor = 1` 时任何段号都 `>= 1`，`cleanOnce` 一条不删；`BackupStore_test.cj:240`–`248` 还把这一行为固化成断言（`noCursor.cleanOnce(...) == 0`）。
- **描述**：备份段只有在「该队列存在至少一个组位点文件」且「段号小于位点段号」时才被 TTL 清理。若主题从未注册组（`cursorsOf` 返回空，见 `ConsumeService.cj:318`–`327`）或位点文件被删，备份目录就永久保留；而 `deleteTopic` 也不删 `<logRoot>/backup/<owner>/<topicEsc>/`，主题删除后副本变成孤儿。两类叠加的后果是备份盘只增不减，只能靠人工清理。
- **建议**：`cleanupAfterDelete` 的 Topic 分支加一步清理该主题的备份目录（`BackupStore` 提供 `removeTopic(topic)`，内部先摘 `logs`/`owners` 再删目录）；对「无位点」的备份队列，用一个显式的保留上限（例如 `backupRetention` / 直接按 TTL 删非当前段）而不是无限保留，或至少在 `LogCleaner` 里对无位点队列记一条 WARN 让运维可见。

### [轻微][存量] `QueueManager.localTopics` 与 `close` 内的同名逻辑复制（含注释）

- **位置**：`fmq/src/queue/QueueManager.cj:162`–`171` 与 `fmq/src/queue/QueueManager.cj:222`–`228`
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：checklist §2（同文件内两两比对：输入/输出/副作用一致）
- **证据**：静态确定 —— 两段都是「遍历 `topics`，`set.items.size > 0` 才收名」，连注释「只列出本节点真正持有队列的主题，避免 stats 全量/按主题口径不一致」都一字不差。
- **建议**：`close()` 直接复用 `localTopics()`；若担心语义分叉，把过滤条件提成 `hasLocalQueues(set)` 供两处调用。

### [轻微][存量] 整文件读取函数 `readAll` 在三个包各写一份（逐字节相同）

- **位置**：`fmq/src/server/BackupStore.cj:213`–`232`、`fmq/src/queue/CursorStore.cj:122`–`141`、`fmq/src/meta/MetaStore.cj:910`–`929`
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：checklist §2（跨文件字面量/结构复制）
- **证据**：静态确定 —— 三处函数体逐行一致（`File(path, OpenMode.Read)` → 按 `info.size` 预分配 → 循环 `read` 到 `got == size` → `finally close`），错误处理也一致（`n <= 0` 时 `break` 返回短缓冲）。
- **建议**：抽到 `fmq` 内的公共位置（如 `fmq/src/meta/FileBytes.cj` 的 `readFully(path)`），三处改为调用；顺带统一「短读返回截断缓冲」的语义（见优化方案 O4「备份位点没有内存缓存」）。

### [轻微][存量] `BackupStore.warnDropped` 重写了 `WarnLimiter` 的时间窗限流

- **位置**：`fmq/src/server/BackupStore.cj:234`–`244`（自带 `warnLock` + `lastDropWarnMs` + 硬编码 `1000`）；对照 `fmq/src/queue/WarnLimiter.cj:41`–`66`
- **来源**：存量（工作区快照，无 diff 可比）（`0437c5882 fix(fmq): BackupStore 关闭后丢弃写入留痕并限流（R4-G3）`）
- **判据**：checklist §2（换算/常量复制：同一时间窗逻辑两处实现）
- **证据**：静态确定 —— 语义相同（`now - last < window` 则抑制），差异只有两点：`WarnLimiter` 按 key 分桶、`BackupStore` 是全局单桶；`WarnLimiter` 时钟可注入、`BackupStore` 直接 `DateTime.now()`。
- **建议**：`BackupStore` 持有一个 `WarnLimiter`，用固定 key（如 `"drop"`）调用 `allow`，全局单桶语义等价，还能顺手拿到「可注入时钟」以便用例固定时间；`WarnLimiter` 已是 `protected` 同模块可用。

### [轻微][存量] `ConsumeService` 三处「收集 key → remove → close」重复

- **位置**：`fmq/src/server/ConsumeService.cj:376`–`396`（`removeTopic`）、`399`–`419`（`removeGroup`）、`421`–`434`（`close`）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：checklist §2（换条件、同控制流）
- **证据**：静态确定 —— 三段结构完全一致，只有筛选谓词不同（`startsWith("${topic}\0")` / 同前缀且 `endsWith("\0${group}")` / 全选），差异是业务要求（作用域不同），但重复的遍历+摘除+关闭可以统一。
- **建议**：抽 `private func removeCursorsWhere(predicate: (String) -> Bool)`，三个调用点只传谓词；`metrics.removeTopic/removeGroup` 留在各自入口。

### [轻微][存量] 位置先后比较写了三遍，边界含义各不相同

- **位置**：`fmq/src/server/ConsumeService.cj:297`–`299`（`before`：严格小于）、`fmq/src/server/ConsumeService.cj:335`–`338`（`ackedByAll`：`<=` 即「必须严格越过」）、`fmq/src/server/BackupStore.cj:119`–`120`（回退判定：`>=` 即「相等也算回退」）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：checklist §2（近似重复 + 边界判断散落，容易漂移）
- **证据**：静态确定 —— `LogPosition` 只有 `seq`/`offset` 两个字段，没有比较运算符（`f_io/src/SegmentedLog.cj:43`–`53`），f_mq/f_io 也没有现成 helper（全仓搜 `func before|isAfter|compare` 只命中 `ConsumeService.before`）。
- **建议**：在 fmq 内加 `LogPositions.isBefore / isAtOrBefore / isAfter`（或让 `LogPosition` 支持 `<`），调用点用带含义的名字替代裸 `||`；`ackedByAll` 的「严格越过」写成 `!position.isAtOrBefore(committed[i])` 之类，避免下次改边界时漏改一处。

### [轻微][存量] `openTopic` 的并发抢先分支不可达；若将来可达，其回滚会删掉对方的目录

- **位置**：`fmq/src/queue/QueueManager.cj:97`–`101`（`topics.addIfAbsent(...).isSome()` 时 `throw`）、`102`–`115`（catch 里 `remove(dir, recursive: true)`）
- **来源**：存量（工作区快照，无 diff 可比）（`efae83e7f fix(fmq): 队列打开原子性与失败回滚（A52）`）
- **判据**：checklist §1（恒假分支/不可达语句）
- **证据**：静态确定 —— `topics` 的唯一写入口就是本函数（`close()`/`closeTopic` 只删），而同一主题的所有 `openTopic` 都经 `openLocks` 里**同一个** `Mutex`（`76`–`79`，`addIfAbsent` 只会把后来者导向既有实例），进入临界区后第 `81` 行已 `contains` 判过；因此第 `97` 行的 `addIfAbsent` 不可能返回 `Some`。
- **描述**：死分支本身无害，但它的 catch 承担了「构造失败回滚」的职责：一旦这个防御分支哪天真的被触发，`createdDirs` 里的目录正是并发赢家正在写的目录，`remove(recursive: true)` 会删掉已有句柄下的数据（而不是只清理自己的半成品）。
- **建议**：把「并发抢先」从异常路径改成返回值/重查（如 `if (topics.get(...).isSome()) { 关闭本次句柄；return }`），并让回滚只删「本次新建且确认无主」的目录；或直接删掉该不可达分支并在注释里写明由 per-topic 锁保证互斥。

### [轻微][存量] 只增不减的两张注册表：`openLocks` 与 `owners`

- **位置**：`fmq/src/queue/QueueManager.cj:57`（`openLocks` 只在 `76`–`79` 添加，`closeTopic`/`close` 都不删）；`fmq/src/server/BackupStore.cj:42`（`owners` 只 `add`，`close()` 只清 `logs`）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：checklist §5（注册表不注销 / 长期持有）、§7（缩短生命周期）
- **证据**：静态确定 —— 全仓搜 `openLocks` / `owners`，无任何 `remove`。
- **描述**：主题被反复创建/删除时，`openLocks` 每个主题留一个 `Mutex`；备份 `owners` 每个曾出现的 `(owner, topic, queue)` 留一个三元组。单个对象很小，但对「主题 churn 大」的部署是无界增长，也让 `allLogs` 之外的遍历（若以后加）拿到过期项。
- **建议**：`closeTopic` 里同步 `openLocks.remove(topic)`（注意先取用再删，避免与进行中的 `openTopic` 抢锁）；`close()` 里 `owners.clear()`。补一条用例：建-删同一主题 100 次后 `openLocks.size == 0`（需要暴露一个仅供测试的计数）。

### [轻微][存量] `CapturingAppender.clear` / `CapturingStream.clear` 全仓无引用（4 份副本同步存在）

- **位置**：`fmq/src/server/LogCapture_test.cj:90`–`92`、`fmq/src/server/LogCapture_test.cj:56`–`61`（同样的文件还存在 `fmq/src/queue/`、`fmq/src/meta/`、`fmq/src/cluster/`）
- **来源**：存量（工作区快照，无 diff 可比）（`72be80245 refactor(fmq): 测试替身退出进程钩子，清理零消费者符号…`）
- **判据**：checklist §1（非 public 符号全仓无调用者 = 死代码；`class CapturingAppender` 与 `class CapturingStream` 都是非 public 顶级声明，其 `static func` 不构成对外契约）
- **证据**：静态确定 —— `grep -rn "CapturingAppender.clear"` 与 `"CapturingStream.clear"` 全仓只在 `LogCapture_test.cj:91`（`CapturingStream.clear` 的定义处内部调用）命中；没有任何测试调用这两个 `clear()`。
- **建议**：四处副本一并删掉 `clear()`；若担心后续用例需要重置，保留但补一条使用点（否则下一轮仍会被判死代码）。

### [轻微][存量] `BackupStore.close` 在遍历 `ConcurrentHashMap` 时删除元素（与同仓写法不一致）

- **位置**：`fmq/src/server/BackupStore.cj:263`–`268`
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：checklist §11（并发正确性 / 迭代与修改并发）
- **证据**：待确认 —— 本地文档快照里没有 `std.collection.concurrent.ConcurrentHashMap` 的迭代语义说明（`docs/` 下搜不到），无法确认「迭代中删除」是弱一致还是抛异常。
- **描述**：同一仓库的其它三处都先收集再删：`QueueManager.close()`（`QueueManager.cj:222`–`237`）、`CursorCatalog.invalidateWhere`（`CursorCatalog.cj:146`–`158`）、`SubscriberRegistry.removeByTopic`（`SubscriberRegistry.cj:137`–`152`）。只有这里边遍历边 `remove`。若底层迭代器是快照/弱一致则无害，否则 `close()` 会在释放中途抛异常，叠加前面「close 不可重试」的问题会留下一批未关闭的段文件。
- **建议**：改成与其它三处一致的「先把 key 收进 `ArrayList`，再逐个 `remove`+`close`」；顺便让 `close()` 的失败可重试（见 `close()` 那条发现）。

<!-- 第 7 部分 -->

### [一般] [存量] `SubscriberRegistry.generations` 只增不减，键是客户端每次新生成的 UUID

- **位置**：`fmq/src/server/SubscriberRegistry.cj:33`（声明）、`:49-54`（每次 `register` 写入）、`:128-133`（`clear()` 不清）；键来源 `f_mq/src/client/MQClient.cj:141`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无界容器」/「缓存键无界：用户 ID / 请求 ID 做 key，没有容量、TTL、淘汰」；§12.1「有界性」
- **证据**：静态确定 —— 全仓只有 `register` 写入 `generations`，`unregister`（`:76-90`）与 `clear()`（`:128-133`）都不删条目，`byId`/`byGroup` 清了它不清；`subscribedId` 由客户端 `UUID.random().toString()` 生成，同一逻辑订阅每次重连都是新键
- **描述**：生产者侧每次 `SUBSCRIBE` 必然产生一个从未被回收的映射项，`unsubscribe`、断链清理、`close()` 都不会移除。长期运行的服务端，条目数 = 进程生命周期内的 SUBSCRIBE 总次数（与当前在线订阅数无关）。按 `HashMap` 节点 + 36 字符 UUID 串估算约 100–150 B/条：100 万次订阅约 100–150 MB 常驻且不回落；客户端可用「反复订阅/退订同一主题」（只需一个已存在的主题与组）稳定推高。`byGroup` 同理：`removeFromGroup`（`:200-209`）把组内列表清空后不删 key，残留空 `ArrayList`，但其数量受 `(topic, group)` 组合数约束，量级远小于 `generations`。本条按单请求增量小、需百万级累计才到 OOM 量级定为「一般」；若从严按 §5 的「无界增长」口径，可直接升为「严重」。
- **建议**：给 `generations` 加 TTL 或按「无活跃订阅」修剪。代次只需要覆盖一次巡检快照的存活期（`MQServer.CLEANUP_INTERVAL = 2s`），因此可在 `unregister` 成功后把该 id 的条目降级为「待修剪」并记录时间戳，定时器里删除「距上次登记 > 若干倍 CLEANUP_INTERVAL 且 `byId` 中已无该 id」的条目；`clear()` 里应一并 `generations.clear()`（关闭语义已由 `closeCompleted` 保证，不需要跨 close 保留代次）。`byGroup` 的空列表在 `removeFromGroup` 内顺手 `byGroup.remove(key)`。

### [一般] [存量] 生命周期状态机不完整：`start()` 不看 `closed`，且 `server`/`cleanupTimer` 与 `close()` 无同步

- **位置**：`fmq/src/server/MQServer.cj:57`（`private var server`）、`:60`（`cleanupTimer`）、`:166-190`（`start()`）、`:187-189`（`spawn`）、`:239-263`（`close()`）、`:206-232`（`closeSteps()` 的 `"server"` 步骤）；调用序 `fmq/src/main.cj:102-111`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「资源不对称 / 语义与注释不符」、§12.1「可见性：用普通字段当跨线程信号」「发布逸出」
- **证据**：静态确定 —— `start()`（`:166`）只做 `started` 的 CAS，没有读 `closed`；`close()`（`:244`）只置 `closed`，两个入口之间没有互斥；`server`/`cleanupTimer` 是普通 `var`，写入在 `start()`、读取在 `closeSteps()`/`cancelCleanupTimer()`，而 `close()` 由 `ExitCallbacks` 的信号回调在另一线程执行（`f_base/src/signal.cj:39-47` 注册 handler，`onExit()` 内直接同步调用回调）
- **描述**：两个可复现的状态机缺口。
  1. `close()` 之后调用 `run()`（`run()` 无条件 `start()`）：`started` 仍为 `true` 时 `start()` 直接返回，`closed` 已为 `true` 使 `run()` 立即返回 0 —— 这没问题；但**从未启动**的实例先 `close()` 再 `run()` 时，`started=false`，`start()` 会重新起 `backup`/`cleaner`/反熵/巡检定时器并 `new Server(bindAt: port)` 绑端口，随后 `run()` 因 `closed` 立刻返回 —— 留下一个已绑定端口、定时器在跑、无人关闭的实例。现有用例 `MQServer_test.cj:489-501` 先在 490 行 `start()` 过，恰好绕开了这个分支。
  2. `SIGTERM` 在 `this.server = Some(srv)`（`:185`）之前到达：`close()` 的 `"server"` 步骤把 `None` 当成功（`:208-213`），写入 `closeDone` 并把 `closeCompleted` 置 `true`；随后 `start()` 继续 `new Server(...)` 并 `spawn`，这个 Server 永远不会被关闭（端口被占、accept 线程常驻），而 `close()` 已宣告完成。窗口窄但确实存在，且注释 `:178`「端口最后绑定：装配失败或定时器启动失败都不会留下已占用端口」只覆盖了抛异常路径，没覆盖 close 并发路径。
- **建议**：把 `start`/`close` 放进同一个 `Mutex`（或让 `close()` 复用 `closeLock` 并在 `start()` 的绑定段内取同一把锁），`start()` 入口先 `if (closed.load()) { return }`；`closed` 置位与 `started` 的检查放在同一临界区，避免「close 先于 bind」。若要保持无锁，至少把 `server` 改成在 `start()` 内先构造、再在锁内发布，且 `closeSteps` 的 `"server"` 步骤在 `None` 时不要计入 `closeDone`。

### [一般] [存量] `MQManager_test` 的端口探测与就绪等待不 `connect()`，用例可能在服务未监听时继续

- **位置**：`fmq/src/server/MQManager_test.cj:49-62`（`freePort`）、`:64-80`（`waitReady`）；正确实现对照 `fmq/src/server/MQServer_test.cj:50-65`（`isListening` 显式 `connect()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「近似重复：两块代码相似度高，但其中一块少了边界判断 —— 这往往同时是缺陷」、§11「边界 / 错误处理缺失」
- **证据**：静态确定 —— 同仓 `MQServer_test.cj:50` 的注释就是作者自己的结论：「该端口是否已有监听者：TCP 构造函数不建连，必须显式 `connect()`」。`MQManager_test` 的两处都只 `TcpSocket(IPSocketAddress(...))` + `close()`，从不 `connect()`
- **描述**：`freePort()`（`:52-56`）永远第一次就返回 `nextPort.fetchAdd(1) % 60000` 的结果，即使该端口已被别的进程/用例监听（构造不连通不报错），因此「找空闲端口」退化为「取下一个自增端口」；`waitReady()`（`:69-71`）更严重 —— `probe.close()` 恒成功，`ready` 第一轮就为 `true`，等于完全不等待，`startServer`（`:93-95`）返回后用例立刻发管理请求，服务端尚未绑定端口时会走到「无法连接」分支，表现为**偶发失败**，或把真实的启动失败掩盖成连接失败。`MQManager_test` 的 18 个 `@TestCase` 里有 14 个经由 `startServer`/`freePort`/`waitReady` 拿端口与就绪信号（其余 4 个不连服务端）。
- **建议**：删除 `MQManager_test` 的私有实现，改为复用 `MQServer_test` 的 `ServerPortAllocator.freePort()`/`waitReady()`（同包，直接把 `ServerPortAllocator` 提成两文件共用的测试 helper，或并入 `TestDirs` 所在包）；至少把探测改成 `connect()` 并 `catch` 判定。

### [一般] [存量] 服务线程异常无处传播：`spawn { srv.start(...) }` 无 catch，`run()` 只轮询 `closed`

- **位置**：`fmq/src/server/MQServer.cj:187-189`（`spawn`）、`:193-199`（`run()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失或静默」、§12.1「异步语义：`Future` 异常被吞」
- **证据**：静态确定（无传播路径）+ 待确认（触发条件落在 `f_net`）—— `MQServer` 侧既没有 `try` 也没有保存 `Future`/状态位，`run()` 的唯一退出条件是 `closed.load()`；而 `f_net` 的 accept 循环里 `params.populate(socket)`（`f_net/src/server/server.cj:136`）与 `SocketBuffer(bufferQueueSize, socket)`（`:137`）在 `try` 之外，任一抛异常都会让 `start()` 直接返回
- **描述**：一旦 accept 循环因非 `SocketException` 的异常退出（socket 选项设置失败、缓冲分配失败、以及 `:138` 的 `buffers.add`），`MQServer` 的 `spawn` 线程结束、服务端不再接受任何连接，但 `isClosed()` 仍为 `false`、`closed` 仍为 `false`，`run()` 继续 200ms–500ms 空转，进程既不退出也不告警 —— 表现为「进程活着、端口不通、日志无线索」。这与「`run()` 阻塞运行（生产入口）」的契约相冲突：调用方没有任何手段分辨「在服务」与「服务线程已死」。
- **建议**：在 `spawn` 内 `try { srv.start(executor.execute) } catch (e: Exception) { log.error(...); closed.store(true) }`，并新增一个「服务线程已退出」的原子状态供 `run()` 判定（退出码非 0）；或把 `srv.start` 的返回/异常通过 `Future`/`AtomicBool` 回传，让 `run()` 在服务线程死亡时返回非 0 而不是继续空转。

### [轻微] [存量] `MQSubscriptionInfo.connectionKey` 是死字段，`buffer` 声明为 `var` 但从不重赋值

- **位置**：`fmq/src/server/MQSubscriptionInfo.cj:35`（字段）、`:52-56`（唯一赋值，每次构造多算一次 `remoteAddress.toString()`）、`:36`（`var buffer`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「无调用者 / 兼容残留」；`fn` 全仓检索范围：整个 `fountain` 工作区
- **证据**：静态确定 —— 全仓 `connectionKey` 仅命中定义处 `:35` 与赋值处 `:52`（`grep -rn connectionKey` 另有文档与历史报告，无读取点）；`buffer` 的写入仅 `:51` 构造赋值，全仓无 `\.buffer\s*=` 的其他命中
- **描述**：`connectionKey` 是 `removeByBuffer` 链（已删除）的残留：构造时对每个 `SUBSCRIBE` 多做一次 `SocketAddress.toString()` 分配，之后没有任何读取者，属于「算了不用」。`buffer` 被声明为 `var` 会让读者以为断链后会被替换为 `EMPTY_SOCKET_BUFFER`，实际从未发生（测试是新建 `MQSubscriptionInfo`），`var` 徒增「可变共享状态」的误解。
- **建议**：删除 `connectionKey` 字段与 `:52-56` 的构造逻辑（顺带去掉一次字符串分配）；`buffer` 改 `let`。若确实需要「连接标识」，应真正接回 `unregister` 的归属判定（当前用 `generation` 承担，二者不要并存）。

### [轻微] [存量] `byGroupOf` 与 `activeIds` 对同一 `(topic, group)` 列表做两遍过滤，调用方连续调用两者

- **位置**：`fmq/src/server/SubscriberRegistry.cj:98-112`（`byGroupOf`）、`:168-187`（`activeIds`）；调用点 `fmq/src/server/ConsumeService.cj:73` 与 `:83`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「表现形式不同的重复逻辑：换控制流 / 只改类型名」，差异点必须点名
- **证据**：静态确定 —— 两个函数的体逐行对齐：都 `synchronized(lock)`、都取 `byGroup.get(groupKey(topic, group))`、都对每个 id 做 `byId.get` 存在性检查、都 `ArrayList → toArray`。差异只有两点：（a）`activeIds` 多一个 `!info.isDisconnected()` 过滤；（b）返回 `Array<String>` 还是 `Array<MQSubscriptionInfo>`
- **描述**：`ConsumeService.consume` 先 `byGroupOf` 拿全部成员并在调用方按 `!isDisconnected()` 过滤出 `members`（`:73-78`），紧接着 `activeIds`（`:83`）把同一个列表再遍历一遍、再判一次 `isDisconnected()`。每次 `CONSUME` 因此多一次全局锁获取、一次 O(组内订阅数) 扫描、一个 `ArrayList` + 一个 `Array` 分配，且两份结果必须保持一致（新增过滤条件时极易只改一处 —— 这正是「重复逻辑导致行为漂移」的典型形态）。
- **建议**：保留一个「按组快照」入口，`activeIds` 由调用方从 `members` 派生（`Array<String>(members.size) {i => members[i].subscribedId}`），或让 `byGroupOf` 增加 `activeOnly!: Bool = false` 参数并在内部一次遍历完成；`ConsumeService` 只调用一次。注意保留语义差异：`byGroupOf` 的其它调用点若需要「含断链订阅」的全量视图，必须显式传 `activeOnly: false`。

### [轻微] [存量] 测试装配与断言 helper 重复（跨文件两套端口/就绪/装配代码 + 两个近乎逐行相同的用例）

- **位置**：`fmq/src/server/MQManager_test.cj:82-96`（`startServer`）vs `fmq/src/server/MQServer_test.cj:76-84`（`options`）；`MQManager_test.cj:98-116`（`manager` / `managerWithOutput`）；`MQManager_test.cj:118-128`（`joined`）；`MQServer_test.cj:525-569` 与 `:596-640`（两个断链释放用例）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「同文件内两两比对函数体」「跨文件搜相同字面量/同一套装配」
- **证据**：静态确定 —— `startServer` 与 `options` 都用同一串 12 个参数（`Duration.second*10, 3, Duration.hour*72, "${root}/logs", "${root}/dead", 1024*1024, Duration.hour*72, 0, "${root}/metas"`）构造 `MQServerOptions`，只有「是否顺带 `start()`+`waitReady`+拼地址」不同；`manager(args)` 与 `managerWithOutput(args)` 的差异只有第二个 sink 参数；`joined` 是 `String.join(lines.toArray(), delimiter: "\n")` 的手写版本；两个 cleanup 用例的步骤完全一致（注册主题/组 → 订阅 → publish "held" → consume 断言 → 造断链订阅 → cleanup → 新订阅取到 "held" → ack），只差「怎么把订阅标成断链」。
- **描述**：测试基建重复本身不是缺陷，但这里的重复已经产生实际后果：同一份「端口探测」在两处实现、其中一处漏了 `connect()`（见上一条「一般」），且两个 cleanup 用例维护成本翻倍（A55/A60/A70 的断言分散在两处，改一处漏一处）。`joined` 手写拼接还多了一层 `StringBuilder` 逻辑，与 `String.join` 的语义需要人工对齐。
- **建议**：把 `MQServerOptions` 的测试构造、`freePort`/`waitReady`、`manager(...)` 收敛成一份（放 `fmq.test` 包的测试 helper，与 `TestDirs` 同级）；`manager`/`managerWithOutput` 合并为带 `sink!: ?(String) -> Unit = None` 的单函数；`joined` 换成 `String.join`；两个 cleanup 用例合并为「注入断链方式」参数化的一个用例。

### [轻微] [存量] `TestDirs` 硬编码 `/tmp`，且 `cleanNamespace` 用空 catch 吞掉清理失败

- **位置**：`fmq/src/test/TestDirs.cj:39`（`"/tmp/fmq_test_..."`）、`:46`（同）、`:48-52`（`catch (_: Exception) {}`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符 / 跨平台」、§3「`catch {}` 静默吞异常（有意 no-op 需注释）」
- **证据**：静态确定 —— 路径字面量写死 `/tmp`，无 `os`/`TMPDIR` 分支；空 catch 体没有任何注释说明「为什么失败可以忽略」；同仓 `f_base/src/signal.cj:70-74` 明确存在 Windows 分支，说明该工程需要跨平台构建
- **描述**：Windows 上 `/tmp` 通常不可写，`Directory.create(dir, recursive: true)`（`:40`）会直接抛错，`fmq` 的全部单测（`TestDirs.of` 被 `MQServer_test`/`MQManager_test`/`ConsumeService_test`/`MQCommandExecutor_test`/`BackupStore_test` 共用）在该平台无法运行；这与 `f_base` 已做的 Windows 兼容形成不一致。空 catch 使得 `@AfterAll` 清理失败完全无声，残留目录会跨轮累积（`/tmp/fmq_test_*` 只在断言失败时被发现）。
- **建议**：路径改为 `Path`/环境变量派生（`TMPDIR` → 平台默认临时目录），与 `MQConfig` 的目录处理保持一致；空 catch 至少加一行 `// 清理失败不影响用例结果，残留目录由下一轮 cleanNamespace 覆盖` 并降级为可选告警。若确定只在 Linux/ohos 跑单测，应在 `TestDirs` 头部写明平台约束，而不是让调用方在 Windows 上碰到一个裸 `Directory.create` 异常。

### [轻微] [存量] 设计文档称 `byGroupOf` 返回「所有活跃订阅」，实现不过滤断链订阅

- **位置**：文档 `fmq/doc/详细设计.md:648-649`；实现 `fmq/src/server/SubscriberRegistry.cj:98-112`（对照 `activeIds` `:168-187` 的过滤与注释 `:176`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 语义与文档不符」，必须给两边位置
- **证据**：静态确定 —— 文档写「该主题该组下的所有活跃订阅（组内选人、匹配判定用）」，实现只做 `byId` 存在性检查并全部返回，断链过滤在 `activeIds`（`:177`）和调用方 `ConsumeService.cj:75`；`activeIds` 的注释「断链订阅不是『活跃』：否则它的记录永远不会退回组内（A55）」正是对「活跃」的定义
- **描述**：按文档字面理解，`byGroupOf` 的返回值可直接用于「组内选人」，实际会包含已断链订阅，调用方必须再过滤一次（`ConsumeService` 确实这么做了）。这正是上一条「重复遍历」的根因：文档把「活跃」的语义给了 `byGroupOf`，实现却把这个语义留给了调用方和 `activeIds`。
- **建议**：二选一并同步文档 ——（a）让 `byGroupOf` 真正过滤 `isDisconnected()`，`ConsumeService` 去掉 `:75` 的重复过滤；（b）文档改成「该组下全部登记中的订阅（含断链），活跃判定见 `activeIds`」。`详细设计.md` 属另一部分的文件，本条的修改落点需与那一部分合并处理。

### [轻微] [存量] `executors: 200` 与 `f_net.Server` 的默认值重复，巡检/检查周期硬编码

- **位置**：`fmq/src/server/MQServer.cj:183-184`（`checkDuration: CHECK_DURATION, executors: 200`）、`:40-41`（`CHECK_DURATION` / `CLEANUP_INTERVAL`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10「可读性 / 可维护性」、§2「字面量复制」
- **证据**：静态确定 —— `f_net/src/server/server.cj:110` 的签名就是 `executors!: Int64 = 200`，此处显式传 200 与库默认值完全相同，却让「线程池大小」看起来是本模块的策略
- **描述**：三个常量（30s 连接检查、2s 订阅巡检、200 线程）都在代码里写死，既没有配置项也不在 `MQConfig` 校验范围内；`executors: 200` 尤其容易误导——它暗示 MQ 侧做过容量决策，实际只是抄了默认值。200 个 executor 线程 + 每 2s 一次全量订阅巡检的线程/CPU 成本没有对应的配置入口，部署侧无法按节点规模调整。
- **建议**：删掉 `executors: 200`（用库默认，需要时再显式配置）；把 `executors` 与 `CLEANUP_INTERVAL` 提为 `MQConfig` 项（默认值保持不变），或在类注释里写明「与 f_net 默认一致，暂无配置入口」的理由。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

本部分 15 个文件全为规格 / 任务 / 验证报告，无可测量的分配与调用路径，也没有 bench / profile 基线；按铁律不产出堆内存 / CPU 方案（0 条）。文档侧改进已并入各条「建议」，不重复计为优化方案。

<!-- 第 3 部分 -->

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

<!-- 第 4 部分 -->

### [CPU] MetaStore 单锁内做 fsync + 目录遍历，写盘时长直接落在临界区里

- **现状**：`MetaStore` 只有一把 `mutex`（`MetaStore.cj:77`），`registerTopic`/`applyTopic`/`applyGroup`/`applyTombstone`/`removeTopic`/`removeGroup`/`gcTombstones`/`advanceNextStart` 全部在 `synchronized(lock)` 内调用 `writeAtomically`（`895-897` → `AtomicFile.write`：写临时文件 + `flush`/fsync + `rename` + 父目录 fsync，`AtomicFile.cj:38-70`）；`removeTopic` 还在锁内做 `remove(groupDir, recursive: true)`（`696-707`），`gcTombstones` 在锁内 `exists`+`remove`（`518-527`）。同一把锁同时服务反熵/管理端的 `snapshot()`（`539-558`）与所有元数据变更。
- **方案**：把「序列化 + 写盘 + rename」移出临界区：锁内只做「判定 + 生成不可变目标状态 + 取版本号」，释放锁后写盘，再进锁做「版本仍是当前值则替换索引，否则丢弃」的比较替换；或按 topic 哈希分片成 N 把锁（`tombstones` 仍用全局锁）。
- **预期**：注册/广播路径的持锁时长从「ms 级 fsync」降到「map 操作」量级；`snapshot()` 不再排在 fsync 后面。
- **代价**：需要引入「版本校验 + 重试」，写盘失败要能回滚（与「写盘/改内存顺序」那条的修法同源）；`AtomicFile` 的「同路径临时文件」需要按写者区分（当前固定 `${path}.tmp`，并发写同一路径会互删临时文件）。
- **验证**：`cjpm bench -O2` 跑「N 个主题并发注册 + 30s 反熵」；同时用 `cjprof` 看 `synchronized` 的等待占比与 `AtomicFile.write` 自耗时；另采线程状态（BLOCKED 时长）——锁等待在 CPU profile 里看不到。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次版本分配都全表扫一遍 `maxRevisionLocked()`，N 个主题注册是 O(N²)

- **现状**：`nextRevisionLocked()`（`MetaStore.cj:779-784`）每次调用都执行 `maxRevisionLocked()`（`757-777`），后者遍历 `topicIndex`、`groups`（双层）、`tombstones` 三张表求最大值；`registerTopic`/`registerGroup`/`newTombstoneLocked` 每次变更都走一次，且都在锁内。
- **方案**：维护 `revision` 单调量即可——`load()` 时算一次初值，之后 `nextRevisionLocked` 直接 `revision + 1`（`applyTopic`/`applyTombstone` 收到远端更高版本时顺手 `revision = max(revision, remote)`）。
- **预期**：注册路径从 O(主题数+组数+墓碑数) 降到 O(1)；N 个主题批量注册的整体从 O(N²) 降到 O(N)。
- **代价**：需要一个「远端版本更高时更新本地位标」的集中点，漏一处会让墓碑 TTL/GC 的版本比较退化。
- **验证**：`cjpm bench -O2`，注册 1k / 10k 主题，比较总耗时中位数与 `maxRevisionLocked` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `MQManagerOutput.table` 每个单元格算两遍显示宽度，且每次 `toRuneArray()`

- **现状**：`table()`（`MQManagerOutput.cj:145-170`）先为每个单元格调 `width()` 求列宽，`renderRow → pad()`（`131-142`）又对同一单元格再调一次 `width()`；`width()`（`119-129`）走 `text.toRuneArray()`，即每格两次 rune 数组分配。
- **方案**：`table()` 在求列宽的那一趟把 `(cell, width)` 缓存（或直接在此处构造已补齐的单元），`renderRow` 只做拼接，不再复算宽度。
- **预期**：渲染阶段 `width()` 调用量减半、rune 数组分配量减半。
- **代价**：多一份 `Array<Int64>` 级缓存，代码路径略增。
- **验证**：`fmq manager stats` 打 1000 主题 × 10 组的服务端输出，`cjprof` 看 `width`/`toRuneArray` 自耗时占比；`cjpm bench` 同输入对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU / 延迟] 复活回调在发送线程内同步跑完整反熵同步

- **现状**：`NodeRegistry.markSeen`（`NodeRegistry.cj:171-189`）在 `send()` 的调用线程里直接执行 `revivedCallback()`；生产装配是 `MQServer.cj:126` 的 `this.registry.onRevived = {=> this.syncer.syncFromPeers()}`，而 `syncFromPeers` 会对每个 peer 发一次带超时的请求（`MetaSyncer` 侧 `transport.send` → `transfer(..., pingTimeout * 5)`，`NodeRegistry.cj:143`）。也就是说一次「节点恢复」会把全量同步的耗时叠加到当前的广播/发布线程上。
- **方案**：回调改为投递到后台任务（专用单线程或多个 `spawn` + 去重标记），`markSeen` 只做状态翻转与置位；或者把 `onRevived` 语义改成「置脏标记，由反熵定时器下一轮消费」。
- **预期**：广播路径 P99 不再被同步等待拖长；重复复活不产生并发的全量同步。
- **代价**：补齐延迟（最长一个反熵周期）；需要去重，避免 flapping 节点刷爆同步。
- **验证**：两节点场景下 kill/restart peer，采 `send()` 的 P50/P99 与同步完成时间；线程状态确认发送线程不处于 WAITING。
- **证据状态**：`无基线（待验证，不进 tasks）`；回调重入导致的递归深度当前只在「同一次同步内失败后又成功」时成立，属 `待确认`，未计入缺陷。

### [堆内存] 全量快照每次都复制三张表

- **现状**：`snapshot()`（`MetaStore.cj:539-558`）在锁内把 `topicIndex`、`groups`（双层）、`tombstones` 全量复制进 3 个 `ArrayList` 再转 `Array`，随后 `MQMetaSnapshot` 持有；`topics()`（164-172）、`allGroups()`（175-185）、`allTombstones()`（463-471）同样全量复制。反熵每 `antiEntropyInterval`（默认 30s）走一次，管理端 `metaSync` 也走一次。
- **方案**：让 `snapshot()` 复用「写时复制」的不可变索引（每次变更生成新数组引用、原子替换），快照直接取当前引用而不复制；或按 revision 做增量快照（只带 `revision > peerRevision` 的条目）。
- **预期**：单次快照的临时对象从 O(条目数) 降到 O(1)（增量路径为 O(变更数)）。
- **代价**：写路径要维护不可变索引，内存占用略升（旧快照存活期间两份索引）；增量快照需要 peer 侧支持 `sinceRevision`，涉及协议变更。
- **验证**：`getAllocatedHeapSize()` + RSS 在 10k 主题稳态下跑 10 分钟，看每次反熵周期的分配尖峰是否消失；同时确认 `snapshot()` 耗时未退化。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 5 部分 -->

### [CPU/IO] 位点落盘批量化（dirty + 阈值/定时 flush）

- **现状**：每次 `advance()` 提交 → `CursorCatalog.save` → `CursorStore.save` → `AtomicFile.write`（`exists` + `create` + `write` + `fsync` + `rename` + `fsync(dir)`，约 2 次 fsync、6 次系统调用），发生在 `GroupCursor.lock` 内。消费路径每条 ack / autoAck 一次；扫描路径每条被越过的记录一次（`GroupCursor.cj:336`）
- **方案**：`GroupCursor` 持 `dirtyPosition`，`advance()` 只更新内存；由「≥N 条 / ≥T ms / close / 段切换 / 恢复」触发批量提交，提交在锁外完成（单写者保序）
- **预期**：消息路径 fsync 次数从「每条 2 次」降到「每 T 毫秒 2 次」；扫描 N 条积压从 2N 次降到常量次
- **代价**：崩溃时最多重投最后一批（at-least-once 允许）；flush 间隔必须远小于段清理周期（当前 5 分钟），否则 `floorOf` 依据的位点滞后会让段保留边界算偏
- **验证**：`cjpm bench -O2` 对照「1 组 1 订阅、10 万条、逐条 ack」与「10 万条全部 tag 不匹配」两场景的中位/P99 延迟与吞吐；用 `strace -c -f` 核 fsync 次数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 未决集合的线性操作（`remove(at: 0)`、`contains`、`deliverCountAt`）

- **现状**：`advance()` 每次 `entries.remove(at: 0)`（O(n) 搬移，`GroupCursor.cj:479`）；`sweep` 每条用 `Array.contains` 判活跃（O(m)，`GroupCursor.cj:447`，且 `ConsumeService.cj:87` 每次 consume 都调一次）；`deliverCountAt` 线性扫 `entries`（`GroupCursor.cj:379-388`），上层 `ConsumeService.cj:311-313` 对备份批次**每个位点**调用一次 → 单批成本 O(B·G·E)
- **方案**：`entries` 改双端队列或「头索引 + 尾部追加」（到达上限时整体压缩一次）；`sweep` 的活跃集合改 `HashSet`；`deliverCountAt` 改按位置建索引（`HashMap<LogPosition, Int>` 或复用扫描位置差）
- **预期**：队首吞并从 O(n²) 摊销到 O(1)；备份路径从 O(B·G·E) 降到 O(B·G)
- **代价**：双端队列与索引表都增加一处状态，必须与 `entries.clear()`（`recoverIfSegmentGone`/`openReaderAt`）同步清理
- **验证**：`cjpm bench -O2` 对照「1 万条未决 + 逐条 ack」与「备份批次 500 位点 × 3 组」；断言最终 `committed` 与逐条 ack 一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU/堆] `QueueRecordReader.readUpTo` 去掉 tmp 缓冲与逐字节拷贝

- **现状**：`readUpTo` 先 `Array<Byte>(size)`，循环里再 `Array<Byte>(size - got)` 作为中转，读到后逐字节 `for (i in 0..n) out[got + i] = tmp[i]`（`QueueLog.cj:452-474`）。每条记录读一次 4 B 头（2 次小分配）+ 一次正文（2 次分配 + 逐字节拷贝），1 万条记录约 4 万次分配、正文长度级字节拷贝
- **方案**：直接 `stream.read(out[got..size])`（本仓多处已用该切片读法，如 `CursorStore.cj:129`、`f_io/src/SegmentedLog.cj:928`），并复用固定 4 B 头缓冲
- **预期**：每条记录少 1 次分配 + 1 次全量拷贝（正文大小），大记录（KB-MB 级）收益最明显
- **代价**：需确认 `InputStream.read` 对切片写入的语义与逐字节版本等价（EOF 返回值一致）；无外部行为变化
- **验证**：`cjpm test` 的 `QueueLog_test.cj` 全部用例 + `cjpm bench -O2` 对照「10 万条 × 4 KB 记录」的吞吐与分配量
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `QueueLog.append` 把整条记录再复制一次

- **现状**：`append` 分配 `PREFIX_SIZE + record.size` 的新数组，写入 4 B 头后 `record.copyTo` 全量复制（`QueueLog.cj:82-85`）；大记录（近 `effectiveMaxRecord`）时峰值多出一份记录大小
- **方案**：若 `SegmentedLog` 提供「两段写 / 前缀 + 载荷」入口则直接拼接写，否则保持现状；至少可以只在 `record.size` 较小（如 < 64 KB）时走复制路径，大记录走两段写
- **预期**：大记录发布路径峰值内存减少约一个记录长度（并发发布 K 条时减少 K × size）
- **代价**：`f_io` 需要新接口（跨模块改动），且 `[长度][记录]` 的落盘格式不能被破坏
- **验证**：`cjpm bench -O2` 发 4 KB / 1 MB 记录各 1 万条，比对 `getAllocatedHeapSize()` 峰值与 RSS
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 指标 key 每条消息重复拼接

- **现状**：`MQMetrics.bump` 每次用 `"${topic}\u{0}${group}\u{0}${name}"` 新建字符串（`MQMetrics.cj:31-33`、`41-52`）；一条消息的投递+确认+重投最多 3 次 `bump`，即 3 次三端插值；`valueOf` 查询同理
- **方案**：`GroupCursor` 初始化时算一次 `"topic\0group\0"` 前缀，`MQMetrics` 提供带前缀的重载（`bumpWithPrefix(prefix, name)`），名称部分再拼；或按 `(topic, group)` 缓存 `AtomicInt64[]` 小数组
- **预期**：每条消息少 2-3 次字符串拼接与哈希（键仍要拼 name，但少两次插值）
- **代价**：指标类新增一个重载，缓存数组需在 `removeTopic`/`removeGroup` 时同步失效
- **验证**：`cjpm bench -O2` 对照「10 万条投递 + ack」的吞吐与 `cjprof` 中 `String`/`HashMap` 相关自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 6 部分 -->

> 全部无改前/改后对照数据，只能作为下一轮补数据的候选，**不进 `tasks.md`**。编号 `O1`–`O5` 供正文与「覆盖自检」引用（标题按主题排序，不按编号顺序）。

### [堆内存] O3 备份接收路径对每条记录多做一次整条复制

- **现状**：`MQCommandExecutor.onPublish` 备份分支逐条 `payload.records[i].copyBytes()`（`MQCommandExecutor.cj:245`–`248`）后才 `backupStore.append`；`QueueLog.append` 内部已经要新建 `Array<Byte>(PREFIX_SIZE + record.size)` 并把正文拷进去（`QueueLog.cj:82`–`85`）。即每条备份记录至少 2 次全量拷贝，单条上限 64 MiB（`QueueLog.MAX_RECORD_SIZE`），批次上限 64 条（`BackupReplicator.BATCH_SIZE`）。
- **方案**：去掉 `copyBytes()`（`append` 不保留入参引用，`SegmentedLog.append` 同步写出），或让 `BackupStore.append` 接受 `Array<Byte>` 并在内部一次性拼好「4B 头 + 正文」交给 `SegmentedLog`，省掉 `QueueLog.append` 的中间数组。
- **预期**：备份接收路径的单条峰值分配从 2×N 降到 ~1×N（N = 记录字节数），批次峰值约减半；GC 压力同比例下降。
- **代价**：需要确认 `MQBackupPayload.records` 的缓冲在 `append` 返回后不会被复用/改写（若 codec 复用了同一块 buffer，就必须保留拷贝）。
- **验证**：`cjpm test -O2` + 固定批次（64 条 × 16 KiB）跑 10 分钟，对照 `getAllocatedHeapSize()` 与 `backupStore` 写入计数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] O1 发布路径每条消息都做一次「全量订阅快照 + 全表扫描」

- **现状**：`MQCommandExecutor.bodyIsEvaluable` 对每条 PUBLISH 调 `subscribers.byTopicOf(topic)`（`MQCommandExecutor.cj:292`），而该函数在**全局锁**内遍历 `byId` 全表、按 `info.topic == topic` 过滤并 `toArray()`（`SubscriberRegistry.cj:115`–`125`）。订阅数 N 与本次发布的主题无关，成本是 O(N) + 一次数组分配，且无主题索引可用。
- **方案**：在 `SubscriberRegistry` 里维护 `topic → ArrayList<subscribedId>` 索引（`byGroup` 已有 `(topic, group)` 维度，可复用/扩展），`byTopicOf` 变为 O(该主题订阅数)；无订阅主题直接命中空表、零分配。
- **预期**：发布路径的订阅扫描从 O(全节点订阅数) 降到 O(同主题订阅数)；每条消息少一次数组分配。
- **代价**：多一份索引要在 `register`/`unregister`/`removeByTopic`/`removeByGroup` 同步维护，一致性风险上升；需补索引与 `byId` 的一致性用例。
- **验证**：`cjpm bench -O2` 固定 1000 订阅 / 10 主题，测 publish p50/p99；`cjprof` 看 `byTopicOf` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] O2 `backupStates` 对每个位置重复全表扫游标（O(位置数 × 游标数)）

- **现状**：`ConsumeService.backupStates` 对批次里每个位置调一次 `deliverCountOf`（`ConsumeService.cj:311`–`314`），后者在 `synchronized(lock)` 内遍历**全部**游标、用 `startsWith("${topic}\0${queueIndex}\0")` 过滤、再逐个取游标自身的锁读 `deliverCountAt`（`ConsumeService.cj:343`–`357`）；`deliverCountAt` 内部又是 O(未决条目) 线性扫（`GroupCursor.cj:379`–`388`）。批次上限 64 条（`BackupReplicator.BATCH_SIZE`），备份 flush 每 100 ms 一次或每 64 条一次（`BackupReplicator.cj:73`–`74`）。
- **方案**：`backupStates` 一次遍历：先按 `(topic, queueIndex)` 取到该队列的游标集合（一次性收集），再对每个游标调用一次「按位置数组返回计数」的新接口（`deliverCountsAt(positions)`，内部一次遍历 `entries` 建立 `位置 → count`），把 O(P×C×E) 降到 O(C×(P+E))；`startsWith` 换成结构化的 `(topic, queueIndex, group)` 三元组键，去掉每次的字符串拼接。
- **预期**：批次为 64、游标 200、未决 1000 时，`backupStates` 的游标扫描次数从 ~64×200 降到 ~200，未决条目扫描从 ~64×200×1000 降到 ~200×1000。
- **代价**：新增一个跨游标批量接口，`GroupCursor` 需要暴露「位置数组 → 计数数组」；返回顺序必须与入参严格对齐（现有 `statesOf` 依赖下标对应）。
- **验证**：`cjpm bench -O2` 固定 64 条批次 / 200 游标 / 1000 未决，对照 `backupStates` 单次耗时中位数；`cjprof` 复核 `deliverCountOf` 自耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU/IO] O4 备份位点没有内存缓存：每次保存 1 读 1 写，每轮清理读一遍全部位点文件

- **现状**：`saveCursor` 每次先 `loadCursor`（`File` 打开 + 读全文件 + `DefaultCodec` 解码，`BackupStore.cj:112`–`128`、`131`–`156`）再 `writeCursor`（编码 + `AtomicFile.write`）；`cursorFloor` 每个清理轮次对每个备份队列遍历 `cursors/` 目录并逐个 `loadCursor`（`158`–`187`），清理器默认 5 分钟一轮（`LogCleaner.cj:48` + `MQServer.cj:120`–`124`）。
- **方案**：`BackupStore` 增加 `HashMap<key, LogPosition>` 作为位点缓存（在 `lock` 内维护，写成功才更新，与 `CursorCatalog` 的「先落盘再更缓存」一致），`saveCursor` 的比较用缓存值，`cursorFloor` 只对缓存未命中的组读盘；启动时不用预热（首次仍走磁盘）。
- **预期**：每个备份批次从「每组 1 读 + 1 写」降到「每组 1 写」；每轮清理的位点读取次数从 Q×G 降到 0（稳态命中）。
- **代价**：多一份内存状态，需与磁盘保持单调一致（写失败时不能只更缓存）；`removeTopic` 类操作要同步失效。
- **验证**：`cjpm bench -O2` + 100 备份队列 × 10 组，统计 `cursorFloor` 单轮耗时与 `saveCursor` p50；配合 `strace`/IO 计数确认读次数下降。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] O5 `consume` 每次调用 4 个临时容器 + 两遍未决集合扫描

- **现状**：`ConsumeService.consume` 每次调用都会 `subscribers.byGroupOf(...)`（新数组）、`ArrayList<MQSubscriptionInfo>`、`Array<MQSubscriptionView>`、`subscribers.activeIds(...)`（新数组）（`ConsumeService.cj:72`–`83`），并对每个本地队列各调一次 `cursor.sweep(active)`；`sweep` 在游标锁内遍历全部未决条目做 `activeSubscriptions.contains(owner)`（`GroupCursor.cj:440`–`455`），随后 `next()` 又遍历一遍未决集合。
- **方案**：把「组内活跃 id 集合」在订阅变更时维护成不可变快照（订阅表已有 `byGroup` 索引），`consume` 只读引用不复制；`sweep` 改成「只在本轮 `active` 快照代次变化时执行」或与 `next` 的第一遍合并（同一次遍历里既判定归属失效又取消息）。
- **预期**：每次交付的消息数不变，`consume` 的临时分配从 4 个容器降到 0–1 个；未决集合从扫 2 遍降到 1 遍。
- **代价**：快照代次需要与订阅表锁配合，`sweep` 延迟一轮会让断链记录多占一轮未决位；需补「断链订阅不影响其它成员取消息」的用例（已有 `disconnectedSubscriptionDoesNotBlockGroup` 可复用）。
- **验证**：`cjpm bench -O2`，单主题 1000 条、10 订阅、未决 100，测 `consume` p50 与分配量（`getAllocatedHeapSize`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 7 部分 -->

> 以下均无改前基线，因此只作方案，不进 `todo.md` / `tasks.md`。

### [CPU] 消费路径合并两次组快照，复用 `views` 数组

- **现状**：每次 `CONSUME` 在 `SubscriberRegistry` 上取两次全局锁、做两次 O(组内订阅数) 遍历（`byGroupOf` `:98-112` + `activeIds` `:168-187`），再在 `ConsumeService.cj:82` 为每个成员生成一个 `MQSubscriptionView` 数组；单次消费至少 3 个短命容器（两个 `ArrayList`、两个 `toArray()` 结果、一个 views 数组）
- **方案**：`byGroupOf` 返回值直接带 `active` 标记或在内部完成 `isDisconnected()` 过滤，`ConsumeService` 用一份快照同时得出 `members` 与 `active` id 集合；`views` 改为 `Array<MQSubscriptionView>(members.size)` 一次填装（当前已是），进一步可把「同组成员」按 `generation` 缓存到订阅登记时
- **预期**：每次消费少一次加锁与一次 O(k) 遍历（k = 组内订阅数）；k=50、QPS=10k 时约省 50 万次/秒的比较与一次锁竞争名额。端到端收益需 profile 确认，按 §6.1 的 Amdahl 口径在未测前不给百分比
- **代价**：`byGroupOf` 语义变化会影响其它调用点（需保留 `activeOnly` 开关）；缓存 `views` 需要在 register/unregister 时失效，复杂度上升
- **验证**：`cjpm bench -O2`，固定 1 组 50 订阅 / 4 队列，测 `consume` p50/p99 与 `byGroupOf`+`activeIds` 的 `cjprof` self time 占比，改前改后各 5 轮取中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 订阅表单锁读写分离

- **现状**：`SubscriberRegistry` 用一把 `Mutex`（`:29`）同时保护 `byId` / `byGroup` / `generations`；`of()`（`:92-96`）在每次 `CONSUME`/`ACK`/`UNSUBSCRIBE` 都被调用（`MQCommandExecutor.cj:341,356,371`），`register`/`unregister` 是写。读多写少，但读也要排同一把锁
- **方案**：`byId` 换成不可变快照 + 原子替换（写时复制，读无锁）；或按 `subscribedId` 哈希分片成 N 把锁。`generations` 与 `byGroup` 的跨字段不变量（register 同时改三张表）仍需在同一临界区内完成，建议保持一把写锁、只把 `of()` 的读路径移出
- **预期**：`of()` 的锁等待消失；高并发 consume/ack 下减少 BLOCKED 线程。收益上限取决于锁等待占比（CPU profile 看不出来）
- **代价**：写时复制的 `HashMap` 每次写 O(n) 拷贝，订阅频繁变更时更慢；分片需要保证 `byGroup` 与 `byId` 的一致性协议
- **验证**：50 线程 × 10k 次 `consume`+`ack` 的压测，采线程状态（BLOCKED/WAITING 时长）与 p99 延迟，改前改后对照；`cjprof` 只作辅助
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 巡检/消费快照去副本

- **现状**：`infos()`（`:190-198`）、`byGroupOf`、`activeIds`、`byTopicOf` 每次调用都 `ArrayList → toArray()`；`MQServer.cleanupSubscribers` 每 2s 对全部订阅做一次 `infos()` 快照（`MQServer.cj:305`）。N 条订阅 ⇒ 每 tick 一个长 N 的数组 + 一个 `ArrayList` 的中间扩容，全部短命
- **方案**：把 `infos()` 的返回改为「直接遍历不可变快照」（维护一个写时复制的数组，register/unregister 时替换），或让 `cleanupSubscribers` 接受回调式遍历（`forEachInfo(f)`），在锁内只做 `isDisconnected()` 与代次判定，把 `releaseSubscription` 移出锁（当前已在锁外）
- **预期**：每 2s 少一次 O(N) 数组分配；N=10k 时约 80 KB/次、43 MB/天 的分配量下降（按 8 B 引用粗算，未计对象头）。是否影响 GC 停顿需实测
- **代价**：回调式遍历会把「锁内执行用户回调」引入 `SubscriberRegistry`，必须保证回调不重入该锁（`releaseSubscription` 取的是 `GroupCursor` 锁，顺序为 registry→cursor，与 `ConsumeService.consume` 一致，需在注释里固定该顺序）
- **验证**：10k 订阅 / 2s tick 跑 30 分钟，采 `getAllocatedHeapSize()` 增速、RSS 稳态、GC 次数，改前改后对照
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `backup = 0` 时每次发布取 `BackupReplicator` 的限流锁，会在高并发发布下形成串行点 | `fmq/src/cluster/BackupReplicator.cj:114-120`、`fmq/src/server/MQCommandExecutor.cj:279-280` | 锁等待占比、发布 QPS 上限 | 单节点 `backup = 0`，4/8/16 生产者线程各发 10 万条；`cjprof` 采线程状态（BLOCKED 时长）与 publish p99，对照短路后的同负载 |
| 2 | `stats` 的实时扫描在超大积压时耗时可观，并可能拉高同队列消费的 P99 | `fmq/src/server/ConsumeService.cj:178-262`、`fmq/README.md:111-112` | 单次扫描耗时与积压条数的关系、对消费延迟的影响 | 造 10 万 / 100 万条积压，`stats` 前后分段计时；同时并发 `CONSUME` 观察 P99（`cjprof` + 分段计时） |
| 3 | 默认配置下每秒一条「dropped backup」WARN 会放大日志写入开销并淹没真实告警 | `fmq/src/cluster/BackupReplicator.cj:114-120` | 日志占发布路径耗时比、日志文件增长速率 | 稳态跑 10 分钟，统计日志行数与 publish CPU 占比；对照关闭该 WARN 的同负载 |
| 4 | 存在「从不消费的组」时备份盘无界增长（#3 的量化） | `fmq/src/cluster/LogCleaner.cj:40-41`、`96-113` | 24h 持续发布下 `backup/` 的段数与字节数 | 单组不消费 + `backup = 1` + 固定速率发布 24h，每小时记 `du -sh segmentedLogDir/backup` 与段数；预期段数单调增、无回收 |
| 5 | 组级 FIFO 在多订阅 + 延迟下不成立：队首未到期记录若只匹配 S1，会被登记为 S1 的未决项，S2 的扫描继续前进并可能先拿到第 2 条 | `fmq/README.md:93` vs `fmq/src/queue/GroupCursor.cj:302-309`（`entries.add` 后不 return，继续 `advance`） | 多订阅场景的实际投递顺序 | 写 `GroupCursor_test`：S1(tag a)/S2(tag b) 在线，R1(tag a, 未到期)、R2(tag b, 已到期)；断言 S2 首次 `consume` 是否返回 R2。若返回 R2，README 的「FIFO」需限定为「同一订阅内 FIFO」 |

<!-- 第 2 部分 -->

> 本部分无性能对象，性能类假设 0 条。唯一的数据缺口是「计划项 → 真实用例」的映射，属一致性核对待办，不是性能结论，也不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 计划中 143 个未命中用例名都能映射到现有用例（仅命名漂移，非功能缺失） | `fmq/doc/开发计划.md` 各用例表 | 计划项 → `@TestCase` 的映射表 | 按表逐个对照同包 `*_test.cj`，标注「已覆盖 / 改名 / 未实现」三态 |

<!-- 第 3 部分 -->

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `MetaSyncer.broadcast` 在注册/注销的请求线程上串行同步发给全部 peer，节点数大或 peer 不可达时注册延迟线性放大（单次 `send` 上限 `pingTimeout*5`，见 `NodeRegistry.cj:143`） | `fmq/src/cluster/MetaSyncer.cj:464-476` | 节点数-延迟曲线、单次 send 的 P95 | 3/5/9 节点各跑 1000 次 `registerTopic`，分段计时（`broadcast` 前后打点）+ `cjprof` 过滤 `NodeRegistry.send` |
| 2 | `LogCleaner.cleanOnce` 在段多、组多时 `floorOf` 成为主要耗时（见上「CPU」方案） | `fmq/src/cluster/LogCleaner.cj:73-94` | 自耗时占比、段数×组数 | `cjprof record` 跑 200 段 × 20 组的一轮清理，统计 `CursorCatalog.floorOf` 自耗时 |
| 3 | `BackupReplicator` 的 10ms 轮询在空闲进程里占比不可忽略（100 次/秒唤醒 + 每次取锁） | `fmq/src/cluster/BackupReplicator.cj:272-294` | 空闲 CPU 时间、唤醒次数 | 空载 60s 采 `ps`/`time` 的 CPU 时间，对比事件驱动实现 |
| 4 | `CapturingStream.lines` 只增不减（`take()` 不清空）会让日志用例的 `find/waitFor` 随用例数变慢（测试栈） | `fmq/src/cluster/LogCapture_test.cj:50-61` | 单次 `find` 耗时 vs 累计行数 | 在 `LogCleaner_test`/`MetaSyncer_test` 全量跑时打点 `lines.size` 与 `find` 耗时 |

<!-- 第 4 部分 -->

> 无性能测试数据支撑，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 元数据单锁 + 锁内 fsync 是注册/同步的吞吐上限 | `fmq/src/meta/MetaStore.cj:228-242`、`895-897` | 单次持锁时长、BLOCKED 线程占比 | 20 线程并发 `registerTopic`，采线程状态 + `cjprof record`，对比 N=1/8/32 |
| 2 | `maxRevisionLocked` 全表扫描在主题数上千时成为注册热点 | `fmq/src/meta/MetaStore.cj:779-784` | 自耗时占比（N=1k/10k） | `cjpm bench -O2` 批量注册，分段计时 + `cjprof report` |
| 3 | `MQManagerOutput.table` 的重复宽度计算占 `stats` 渲染的主要耗时 | `fmq/src/manager/MQManagerOutput.cj:145-186` | 渲染耗时占比 | 1000 主题 × 10 组的 TSV 输入跑 100 次，`cjprof` 看 `width`/`toRuneArray` |
| 4 | 复活回调同步执行把广播 P99 拖长一个同步周期 | `fmq/src/cluster/NodeRegistry.cj:178-184` | `send()` P50/P99 与同步耗时 | 两节点，peer kill/restart 各 20 次，记录 `send` 延迟分布 |
| 5 | 反熵快照的全量副本造成周期性分配尖峰 | `fmq/src/meta/MetaStore.cj:539-558` | 每周期分配量 / GC 次数 | 加 `getAllocatedHeapSize()` 埋点，10k 主题稳态跑 10 分钟 |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 锁内 fsync 是消费延迟主因（单条 ack 中位延迟被 fsync 主导） | `GroupCursor.cj:409`、`482-484`、`CursorStore.cj:89` | 单次 fsync 耗时、锁等待时长、端到端 P99 | `cjprof record` 跑「单队列 10 万条 + 逐条 ack」；同时用线程状态采样看 WAITING/BLOCKED 占比 |
| 2 | 扫描大积压时 `entries` 峰值内存随积压线性增长 | `GroupCursor.cj:57`、`266-336` | 峰值 heapUsed / 对象数 | 埋点 `getAllocatedHeapSize()` + 100 万条、队首故意不 ack，跑一轮后读峰值 |
| 3 | 每记录 2 次小数组分配造成的 GC 压力可观测 | `QueueLog.cj:452-474` | GC 次数、分配速率 | `cjprof heap` 跑 10 万条 4 KB 记录 |
| 4 | `sweep` 每次 consume 全量扫未决项在 E 较大时成为串行段 | `GroupCursor.cj:440-455` + `ConsumeService.cj:87` | E 的实际分布、单次 sweep 耗时 | 加计数埋点统计 `entries.size` 分位与单次 sweep 耗时，跑 10 分钟稳态负载 |

<!-- 第 6 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| H1 | `ConsumeService` 全局游标锁是消费吞吐上限（多队列/多组时排队在 `cursorOf`） | `fmq/src/server/ConsumeService.cj:129` | 锁等待时长、线程状态（BLOCKED 占比）、`consume` 端到端 p99 | 200 executor 压测：10 主题 × 20 队列 × 5 组，`cjprof record` + 线程状态采样，对照把锁换成 `ConcurrentHashMap` 的分支 |
| H2 | 发布路径的 `byTopicOf` 全表扫描/分配是 publish p99 的可见部分 | `fmq/src/server/MQCommandExecutor.cj:292` | `byTopicOf` 自耗时占比、每消息分配字节 | `cjpm bench -O2`，1000 订阅 / 10 主题，`cjprof` 看 `byTopicOf` 与 `toArray` |
| H3 | `stats` 全量扫描 backlog 在大积压下会拖长内部 STATS 调用（无增量、无上限） | `fmq/src/server/ConsumeService.cj:184`–`262` | backlog=10^5/10^6 时单次 `stats` 耗时与 CPU 占比 | 造 backlog 10^6 条后调 `stats("")`，分段计时（扫段/计数/字符串拼接） |
| H4 | `backupStates` 的 O(位置×游标) 在 200 队列/10 组时占备份线程 CPU 明显 | `fmq/src/server/ConsumeService.cj:302`–`357` | 单批耗时、自耗时占比 | 固定 64 条批次，`cjprof` 跑备份 flush 10 分钟 |
| H5 | `cursorFloor` 每轮读全部位点文件在「备份队列多 + 组多」时是清理器的主要 I/O | `fmq/src/server/BackupStore.cj:158`–`187` | 单轮清理 IO 次数与耗时 | 100 备份队列 × 10 组，`cjpm bench` 调 `cleanOnce`，统计读文件次数与耗时 |
| H6 | 本部分涉及的临时结构（`stats` 的 `StringBuilder`/`HashMap`、`loadCursor` 的 codec）适合 local mode | `ConsumeService.cj:179`–`199`、`BackupStore.cj:136`–`152` | 峰值内存前后对照（`getUsedHeapSize` / RSS / `getAllocatedLocalObjectSize`） | 先在 `cjpm.toml` 的 `compile-option` 开 `--experimental --enable-local-mode`，同输入对照峰值内存；无收益则关闭 |

<!-- 第 7 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SubscriberRegistry` 的单锁在消费高峰成为串行段（每次 `CONSUME` 至少 3 次 `of`/`byGroupOf`/`activeIds` 取锁） | `SubscriberRegistry.cj:29,92-96,98-112,168-187` | 锁等待时长、BLOCKED 线程数、p99 | 50 线程压 `consume`+`ack`，采线程状态与 p99；`cjprof` 无法反映锁等待 |
| 2 | 2s 巡检在 timer 线程上串行处理全部断链订阅，订阅数大时单轮超过 2s（`Timer.repeat` 会顺延） | `MQServer.cj:174-177,304-320` | 单轮 `cleanupSubscribers` 耗时 vs 订阅数 | 注入 1k/10k 断链订阅，埋点计时单轮耗时与 `releaseSubscription` 累计耗时 |
| 3 | `close()` 的 `subscribers.clear()` 之后仍可能有在飞请求写入订阅表，使「关闭后订阅表为空」的断言偶发失败 | `MQServer.cj:217-219` 与 `f_net/src/server/server.cj:209-211`（`close` 最多 3 轮关 buffer，不等执行中的 executor） | 是否存在 close 后仍执行 `onSubscribe` 的窗口 | 并发压测：持续 `SUBSCRIBE` 的同时 `close()`，之后断言 `infos().size == 0`，重复 1000 次统计失败率 |
| 4 | `removeFromGroup` 的 `indexOf` + `remove(at:)` 在超大订阅组（>10k）下使注销/重订阅变成可见开销 | `SubscriberRegistry.cj:200-218` | 组规模上界、单次注销耗时 | 1k/10k/50k 同组订阅下测 `unregister` p99；组规模由客户端数决定，需先确认部署上限 |
| 5 | `MQServer` 每个节点固定 `executors: 200` 线程对 RSS 的贡献（线程栈默认大小 × 200） | `MQServer.cj:183` | 进程线程数、线程栈占用、RSS 构成 | `pmap`/`/proc/<pid>/status` 采线程数与栈 RSS，单节点空载与满载对照 |

## 文件覆盖

> 与 `files/fmq.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fmq/README.md` | .md | ✅ | — |
| 2 | `fmq/README_en.md` | .md | ✅ | — |
| 3 | `fmq/doc/backlog.md` | .md | ✅ | — |
| 4 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/consume-semantics/spec.md` | .md | ✅ | — |
| 5 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/manager-cli/spec.md` | .md | ✅ | — |
| 6 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | — |
| 7 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/queue-storage/spec.md` | .md | ✅ | — |
| 8 | `fmq/doc/spec/add-fmq-message-queue/specs/fmq/server-runtime/spec.md` | .md | ✅ | — |
| 9 | `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/consume-semantics/spec.md` | .md | ✅ | — |
| 10 | `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/manager-cli/spec.md` | .md | ✅ | — |
| 11 | `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | — |
| 12 | `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/metrics/spec.md` | .md | ✅ | — |
| 13 | `fmq/doc/spec/fix-fmq-full-audit/specs/docs/spec.md` | .md | ✅ | — |
| 14 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/consume-semantics/spec.md` | .md | ✅ | — |
| 15 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/manager-cli/spec.md` | .md | ✅ | — |
| 16 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | — |
| 17 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/metrics/spec.md` | .md | ✅ | — |
| 18 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/queue-storage/spec.md` | .md | ✅ | — |
| 19 | `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/server-runtime/spec.md` | .md | ✅ | — |
| 20 | `fmq/doc/spec/fix-fmq-postfix-audit/design.md` | .md | ✅ | — |
| 21 | `fmq/doc/spec/fix-fmq-postfix-audit/proposal.md` | .md | ✅ | — |
| 22 | `fmq/doc/spec/fix-fmq-postfix-audit/specs/docs/spec.md` | .md | ✅ | — |
| 23 | `fmq/doc/spec/fix-fmq-postfix-audit/specs/fmq/consume-semantics/spec.md` | .md | ✅ | — |
| 24 | `fmq/doc/spec/fix-fmq-postfix-audit/specs/fmq/manager-cli/spec.md` | .md | ✅ | — |
| 25 | `fmq/doc/spec/fix-fmq-postfix-audit/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | — |
| 26 | `fmq/doc/spec/fix-fmq-postfix-audit/specs/fmq/metrics/spec.md` | .md | ✅ | — |
| 27 | `fmq/doc/spec/fix-fmq-postfix-audit/specs/fmq/queue-storage/spec.md` | .md | ✅ | — |
| 28 | `fmq/doc/spec/fix-fmq-postfix-audit/specs/fmq/server-runtime/spec.md` | .md | ✅ | — |
| 29 | `fmq/doc/spec/fix-fmq-postfix-audit/tasks.md` | .md | ✅ | — |
| 30 | `fmq/doc/spec/fix-fmq-postfix-audit/verify-report.md` | .md | ✅ | — |
| 31 | `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/manager-cli/spec.md` | .md | ✅ | — |
| 32 | `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | — |
| 33 | `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/queue-storage/spec.md` | .md | ✅ | — |
| 34 | `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/server-runtime/spec.md` | .md | ✅ | — |
| 35 | `fmq/doc/开发计划.md` | .md | ✅ | — |
| 36 | `fmq/doc/详细设计.md` | .md | ✅ | — |
| 37 | `fmq/src/FmqTestSetup_test.cj` | .cj | ✅ | — |
| 38 | `fmq/src/MQUsage.cj` | .cj | ✅ | — |
| 39 | `fmq/src/MQUsage_test.cj` | .cj | ✅ | — |
| 40 | `fmq/src/Main_test.cj` | .cj | ✅ | — |
| 41 | `fmq/src/cluster/BackupReplicator.cj` | .cj | ✅ | — |
| 42 | `fmq/src/cluster/BackupReplicator_test.cj` | .cj | ✅ | — |
| 43 | `fmq/src/cluster/FakeTransport_test.cj` | .cj | ✅ | — |
| 44 | `fmq/src/cluster/FmqTestSetup_test.cj` | .cj | ✅ | — |
| 45 | `fmq/src/cluster/LogCapture_test.cj` | .cj | ✅ | — |
| 46 | `fmq/src/cluster/LogCleaner.cj` | .cj | ✅ | — |
| 47 | `fmq/src/cluster/LogCleaner_test.cj` | .cj | ✅ | — |
| 48 | `fmq/src/cluster/MQNodeTransport.cj` | .cj | ✅ | — |
| 49 | `fmq/src/cluster/MetaSyncer.cj` | .cj | ✅ | — |
| 50 | `fmq/src/cluster/MetaSyncer_test.cj` | .cj | ✅ | — |
| 51 | `fmq/src/cluster/NodeRegistry.cj` | .cj | ✅ | — |
| 52 | `fmq/src/cluster/NodeRegistry_test.cj` | .cj | ✅ | — |
| 53 | `fmq/src/config/MQConfig.cj` | .cj | ✅ | — |
| 54 | `fmq/src/config/MQConfig_test.cj` | .cj | ✅ | — |
| 55 | `fmq/src/main.cj` | .cj | ✅ | — |
| 56 | `fmq/src/manager/MQManager.cj` | .cj | ✅ | — |
| 57 | `fmq/src/manager/MQManagerArgs.cj` | .cj | ✅ | — |
| 58 | `fmq/src/manager/MQManagerArgs_test.cj` | .cj | ✅ | — |
| 59 | `fmq/src/manager/MQManagerOutput.cj` | .cj | ✅ | — |
| 60 | `fmq/src/manager/MQManagerOutput_test.cj` | .cj | ✅ | — |
| 61 | `fmq/src/meta/AtomicFile.cj` | .cj | ✅ | — |
| 62 | `fmq/src/meta/AtomicFile_test.cj` | .cj | ✅ | — |
| 63 | `fmq/src/meta/LogCapture_test.cj` | .cj | ✅ | — |
| 64 | `fmq/src/meta/MQAssignment.cj` | .cj | ✅ | — |
| 65 | `fmq/src/meta/MQAssignment_test.cj` | .cj | ✅ | — |
| 66 | `fmq/src/meta/MQFileNames.cj` | .cj | ✅ | — |
| 67 | `fmq/src/meta/MQFileNames_test.cj` | .cj | ✅ | — |
| 68 | `fmq/src/meta/MetaStore.cj` | .cj | ✅ | — |
| 69 | `fmq/src/meta/MetaStore_test.cj` | .cj | ✅ | — |
| 70 | `fmq/src/metrics/MQMetrics.cj` | .cj | ✅ | — |
| 71 | `fmq/src/metrics/MQMetrics_test.cj` | .cj | ✅ | — |
| 72 | `fmq/src/queue/CursorCatalog.cj` | .cj | ✅ | — |
| 73 | `fmq/src/queue/CursorCatalog_test.cj` | .cj | ✅ | — |
| 74 | `fmq/src/queue/CursorStore.cj` | .cj | ✅ | — |
| 75 | `fmq/src/queue/CursorStore_test.cj` | .cj | ✅ | — |
| 76 | `fmq/src/queue/DeadLetterQueue.cj` | .cj | ✅ | — |
| 77 | `fmq/src/queue/DeadLetterQueue_test.cj` | .cj | ✅ | — |
| 78 | `fmq/src/queue/DeliveryRecord.cj` | .cj | ✅ | — |
| 79 | `fmq/src/queue/GroupCursor.cj` | .cj | ✅ | — |
| 80 | `fmq/src/queue/GroupCursor_test.cj` | .cj | ✅ | — |
| 81 | `fmq/src/queue/LogCapture_test.cj` | .cj | ✅ | — |
| 82 | `fmq/src/queue/MQMatcher.cj` | .cj | ✅ | — |
| 83 | `fmq/src/queue/MQMatcher_test.cj` | .cj | ✅ | — |
| 84 | `fmq/src/queue/QueueExceptions.cj` | .cj | ✅ | — |
| 85 | `fmq/src/queue/QueueLog.cj` | .cj | ✅ | — |
| 86 | `fmq/src/queue/QueueLog_test.cj` | .cj | ✅ | — |
| 87 | `fmq/src/queue/QueueManager.cj` | .cj | ✅ | — |
| 88 | `fmq/src/queue/QueueManager_test.cj` | .cj | ✅ | — |
| 89 | `fmq/src/queue/WarnLimiter.cj` | .cj | ✅ | — |
| 90 | `fmq/src/server/BackupStore.cj` | .cj | ✅ | — |
| 91 | `fmq/src/server/BackupStore_test.cj` | .cj | ✅ | — |
| 92 | `fmq/src/server/ConsumeService.cj` | .cj | ✅ | — |
| 93 | `fmq/src/server/ConsumeService_test.cj` | .cj | ✅ | — |
| 94 | `fmq/src/server/FmqTestSetup_test.cj` | .cj | ✅ | — |
| 95 | `fmq/src/server/LogCapture_test.cj` | .cj | ✅ | — |
| 96 | `fmq/src/server/MQCommandExecutor.cj` | .cj | ✅ | — |
| 97 | `fmq/src/server/MQCommandExecutor_test.cj` | .cj | ✅ | — |
| 98 | `fmq/src/server/MQManager_test.cj` | .cj | ✅ | — |
| 99 | `fmq/src/server/MQServer.cj` | .cj | ✅ | — |
| 100 | `fmq/src/server/MQServerOptions.cj` | .cj | ✅ | — |
| 101 | `fmq/src/server/MQServer_test.cj` | .cj | ✅ | — |
| 102 | `fmq/src/server/MQSubscriptionInfo.cj` | .cj | ✅ | — |
| 103 | `fmq/src/server/SubscriberRegistry.cj` | .cj | ✅ | — |
| 104 | `fmq/src/server/SubscriberRegistry_test.cj` | .cj | ✅ | — |
| 105 | `fmq/src/test/TestDirs.cj` | .cj | ✅ | — |

合计：`.cj` 69 个 / `.md` 36 个 / 共 105 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：#1（关闭期丢弃契约未实现）、#2（引用不存在的文件与用例）；设计：#4（规格主副本位置与仓库布局冲突）；可读性：#8（同一勾选项结论互斥）；语言特性、安全性无对象（无 `.cj`，文档无凭据与外部输入） |
| §1 死代码 | 0 | 文档无代码，本维度无对象；机械动作换成「文档引用是否存在」：`开发计划.md` 的 8 个目标成员（`byGroup`/`removeByBuffer`/`ownersOf`/`self`/`nodeAt`/`indexOf`/`references`/`rootHelp`）已不存在、154 个用例名中 143 个零命中 —— 结论并入 #2，不另立死代码条目 |
| §2 重复逻辑 | 2 | #6（「段缺失恢复」三套措辞，语义同、量化值相反）；#10（4 份变更文档在两模块各一份，`diff` 无差异）。delta 链的 MODIFIED 覆盖属正常演进，不计 |
| §3 空实现 | 0 | 15 个文件 grep `TODO|FIXME|待补` 仅命中 `proposal.md:124`「待补偿集」与 `开发计划.md:10`「占位 main」（描述性文字，非待办占位）；规格中「SHALL 有行为」的 9 个出口（死信、跳过计数、`stats` 严格模式、`queues.sync`、备份按 target 重试、`BackupStore` 留痕、清理汇总、`bump` 原子性、`TestDirs` 可见性）8 个有实现，第 9 个（关闭期丢弃）是实现走样而非空，记 #1 |
| §4 栈溢出 | 0 | 文档无递归承诺；规格涉及的遍历（`cleanOnce` 逐段、`stats` 单趟扫描、`startSegmentAtOrAfter` 线性找段）均迭代，无深层递归接口 |
| §5 OOM | 0 | 规格声明的上界都有实现：`min(64MiB, maxFileSize-4)`（`QueueLog.cj:55-71`）、备份队列 `capacity` 有界、读端先校验长度再分配（`QueueLog.cj:396-410`）；本部分不新增无界容器 |
| §6.1 热点瓶颈 | 0 | 无 bench / `cjprof` 数据，本部分也不含可测量代码，不给热点结论 |
| §6.2 大粒度锁 | 0 | 规格未承诺锁结构；抽查 `CursorCatalog.positionOf` 已把磁盘 IO 放锁外（`CursorCatalog.cj:62-78`），`MQMetrics` 无全局锁；缺持有时长数据不报 |
| §6.3 并发串行 | 0 | 规格承诺「发布不阻塞、独立工作线程批量发送」，实现一致（`BackupReplicator.cj:267-286`），未见 `spawn` 后立即 `get` |
| §6.4 低效算法 | 0 | `stats` 为单趟扫描（`ConsumeService.cj:178-261`）；线性找段在段数有限时不构成证据 |
| §7 降堆内存方案 | 0 | 无「持有什么 / 多大 / 活多久」的量化数据；`close()` 残留 `pending` 是缺陷（#1）不是优化项 |
| §8 降 CPU 方案 | 0 | 无改前基线，按铁律不写 |
| §9 local mode 可行性 | 0 | 本部分无函数体，无法做逃逸检查，也无峰值内存对照 |
| §11 现有代码的 BUG（存量） | 1 | #1（`requeue` 未判 `closed`，与规格 SHALL 相反）；其余读到的边界（`resolveStart(strict)`、`ackedByAll` 边界、`stats` 无组行、`readAt` 越界校验、`wall-clock` 限流）核对无缺陷 |
| §12 并发安全与锁粒度 | 1 | 唯一并发面是 `close()` 与工作线程的退出时序（#1），与 §11 同源不重复计数；规格承诺的 `MQMetrics` 删除/自增并发、`BackupStore` 关闭并发在源码侧成立 |
| §13 文档一致性（.md） | 9 | #2–#10；15 个 `.md` 全量比对实现（#1 属规格与实现的行为漂移，归 §11） |
| §14 功能完备性与 README 覆盖 | 2 | #2（「每条勾选项 SHALL 能指向实际用例」不成立）、#4（变更未归档到主规格，验收恒真）；README 覆盖属 part1，不重复计 |
| 文件覆盖（§13 等） | 15/15 | 无缺项；`design.md`、`README.md`、`doc/详细设计.md` 仅作交叉取证读片段，未计入覆盖与统计 |

### 第 3 部分

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

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：`MetaStore` 半提交（一般）、`readAll` 短读零填充、`NodeRegistry` 关闭竞态；设计：`MetaStore.close` 无效果、`send` 失败原因混同；安全性：`queueNum` OOM（严重）。可读性 2 条（双 catch、测试命名）与 §1/§2 行重叠，不在此重复计数；本部分无线程本地/值语义误用 |
| §1 死代码 | 2 | 逐个核对本部分全部非 public 符号并全仓搜引用：`MetaStore` 的 `dropTopicLocally`/`dropGroupLocally`/`allGroups`/`advanceNextStart`（`MetaSyncer.cj:429/440/433/448`）、`topicTombstone`、`gcTombstones`、`nextRevision`、`snapshot`、`allTombstones` 均有调用者；`NodeRegistry` 的 `onRevived`（`MQServer.cj:126`）、`markSeen`（`NodeRegistry.cj:144`）、`markFailed`（`:147`，另测试引用）、`clientOf`（`:143`）均有调用者；`MQConfig` 11 个配置属性全部被子 `MQServerOptions.cj:66-79` 消费，`helpText()` 被 `MQUsage.cj:42` 消费；`MQManager`/`MQManagerOutput`/`MQAssignment`/`MQFileNames`/`AtomicFile` 的每个 `private`/`protected` 成员均有用例或生产调用。命中 2 条：`main.cj:70-73` 恒假分支（`commandIndex` 由 `!startsWith("-")` 选出）、`MQAssignment.cj:18` 未使用的 `HashMap`/`Map` import。`public` 且对外可达的 `MetaApplyResult`、`MQManagerOutput.*`、`MQManagerArgs.*` 按硬原则一不判死代码（仓内均有引用） |
| §2 重复逻辑 | 2 | 函数体两两比对结果：`MQMetaTombstone` 键格式 6 处手写（已列）；`MQConfig` 的 `strictPort`/`strictInt64`/`strictDuration`（149-180）为同形状三份（差异仅在解析函数与错误文案，已合并列出）。另有一处**不判为缺陷**：`MQManager` 的 `registerTopic`(111-122)/`stats`(211-223)/`finish`(258-269)/`requestSnapshot`(277-290) 都做「None→连接失败、ERROR→printError」分类，但载荷类型与返回码路径不同（前两者需要取具体 payload），合并收益低于抽象成本，记为「实现漂移」而非重复。`MQAssignment.validate/validateStructure` 为包含关系，不是重复 |
| §3 空实现 | 1 | `CapturingStream.flush()`（`LogCapture_test.cj:48`）与 `ConfigSandbox.isClosed()` 返回 `false` 属测试替身合理 no-op，不判；命中 `MetaStore.close()`（560-570）：只置 `closed`，而 `closed` 在本文件之外零读取（全仓搜 `meta.isClosed` 零命中），关闭后仍可继续写盘 |
| §4 栈溢出 | 0 | 唯一的递归是 `MetaStore.walkFiles`（899-908），递归深度由 `metas/` 下的目录层数决定，而该布局固定为 `topics/`、`groups/<topicEsc>/`、`tombstones/`（`MQFileNames.cj:93-105`），目录名经百分号转义不含 `/`，故深度为常量 2；其余文件无递归、无自引用结构。`MetaSyncer_test` 的 `listeningSocket` 是 `while(true)` 循环不是递归 |
| §5 OOM | 1 | 命中 `queueNum` 无上限预分配（严重）；另核对：`readAll`（910-929）按 `file.info.size` 预分配本地元数据文件，属本机磁盘输入且无上限常量，仅作 §11 轻微记录；`MQManagerOutput.stats` 对服务端 TSV 全量 `split`，规模受元数据条目数约束，未定性 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof`/`cjpm bench` 数据，未提供任何自耗时占比与输入规模，「锁内 fsync」「全表扫版本号」「表格渲染」全部降级为「优化可行性方案（无基线）」+「待验证假设」 |
| §6.2 大粒度锁 | 0 | 定性证据齐全（临界区含 fsync/目录删除、竞争线程为广播+反熵+管理端），但缺「单次持有时长量级」，按铁律不作缺陷，写入优化方案第 1 条 |
| §6.3 并发串行 | 0 | `MetaStore` 单锁本身使元数据写入全序执行；`NodeRegistry` 每次 `send` 都要取全局 `lock` 做槽位查表（`NodeRegistry.cj:113`，锁外做 `transfer`），属「一把锁保护多个无关资源」形态，但无并行度/等待数据，未定缺陷 |
| §6.4 低效算法 | 0 | 已定位两处复杂度问题：`nextRevisionLocked`→`maxRevisionLocked` 每次 O(主题+组+墓碑)（N 次注册 O(N²)）、`dropGroupLocked` 每次删除重建整个组列表（`MetaStore.cj:709-729`，O(组数)）。无改前基线，未定为缺陷，前者写入优化方案；后者规模为单主题下组数（通常个位数），未单列 |
| §7 降堆内存方案 | 1 | `snapshot()/topics()/allGroups()/allTombstones()` 全量复制（优化方案，无基线），其余对象生命周期均为请求内局部量 |
| §8 降 CPU 方案 | 4 | 锁内 fsync、版本号全表扫、表格宽度重复计算、复活回调同步执行，均已标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内用完的大对象」：`MetaStore` 的临时 `ArrayList` 规模随元数据条目数增长且作为返回值逃逸（`snapshot()`/`topics()`），`MQAssignment.allocate` 的数组写入索引与磁盘，均不满足逃逸约束；无峰值内存对照数据，不提出改造建议 |
| §11 现有代码的 BUG（存量） | 4 | 逐函数核对了边界与空值：`MetaStore.removeTopic/removeGroup` 的「不存在返回空」、`gcTombstones` 的 TTL 边界（`<=` 保留、`>` 才回收）、`applyGroup` 的 `revision` 同值比较、`MQFileNames.unescape` 的 `i + 2 < size` 均正确。命中：半提交（一般）、`registerTopic` 用 `Conflict` 表达非法参数、`send` 把下标越界记成网络失败、`readAll` 短读零填充 |
| §12 并发安全与锁粒度 | 2 | 已列共享点与同步手段：`MetaStore.*` 全部走 `synchronized(lock)`（安全，但锁过大）；`NodeRegistry.alive` 用 `AtomicInt64`、`closed` 用 `AtomicBool`（安全）；`clients` 数组全部在 `lock` 内读写（安全）。命中：`markSeen` 的「检查-然后-回调」非原子（可直接换 `compareAndSwap`）、`close()` 置位后 `clientOf` 仍会新建连接（`NodeRegistry.cj:106-128` 无 `closed` 判断） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`，README 覆盖与文档一致性归入负责 `fmq/README*.md`、`fmq/doc/**` 的部分；本部分未发现「承诺了但没实现」的接线缺失（`MQConfig` 11 个配置项均有消费方，`MQManager` 7 个子命令均已接线） |
| 文件覆盖（§13 等） | 19/19 | 无缺失、无未读；`.md` 数量为 0，§13 在本部分无适用对象 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 3（#3、#4、#5）、设计 1（#1）、可读性 2（#8、#12）、语言特性 1（`Option`/`Result` 用法整体规范，仅 `readAt` 契约一处 #5）；**安全性 0**：本部分无 SQL/HTML/路径拼接，记录长度在分配前有 `MAX_RECORD_SIZE` + 剩余字节双重校验，未发现注入/越权 |
| §1 死代码 | 3 | 已逐个搜 `private`（全仓）、`internal`（本包及子包）、`protected`（本 module）符号：`MQMatcher.topicOf`（零引用）、`QueueRecordReader.isClosed`（零引用）、`QueueLog` `length < 0` 恒假分支；对外可达的 `public`（`QueueCorruptionException` 等）不判。另：`GroupCursor.cj:230-237` 的恢复 `catch` 不可达，已并入「正确性」#3 计一次，不重复计数 |
| §2 重复逻辑 | 3 | 已把 9 个实现文件的函数体压成「输入→输出→副作用」两两比对，并跨文件搜相同错误文案/正则/前缀拼接：命中 #10（父目录创建）、#11（谓词删除三处）、#12（`next()` 回退/关流）；`scanAfter` 与 `ConsumeService.stats` 的单趟扫描形态相近，但前者已注明「仅测试/运维口径」且需要按组分桶，属有意独立，不判重复 |
| §3 空实现 | 2 | #6（死信解码异常吞成流结束）、#7（`scanFrom` catch-all）；`CapturingStream.flush()` 是 `OutputStream` 合理 no-op，`MQMetrics.bump` 的裸 `()` 无副作用语义 |
| §4 栈溢出 | 0 | 已核对全部递归可能：`GroupCursor`/`QueueRecordReader`/`MQMatcher`/`DeadLetterReader` 全部为循环实现，无自调用、无递归遍历（`advance` 同名但分属两个类） |
| §5 OOM | 2 | #2（`entries` 无上界）、#9（`readAll` 按文件大小预分配）；`readUpTo` 已在分配前用 `MAX_RECORD_SIZE` + `remaining` 双校验，未判 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，热点结论不成立；4 条线索已列入「待验证假设」，其中 fsync（#1）最值得先测 |
| §6.2 大粒度锁 | 1 | #1：临界区含 create/fsync/rename/dir-fsync 与读流打开（`GroupCursor.cj:143`、`218`），单次持有时长需实测；已给分片（按 group 天然分片）+ 批量化两条替代方案 |
| §6.3 并发串行 | 0 | 同组订阅者共用一个游标与一把锁导致串行，是「按 (topic,queue,group) 分片」后的设计选择，已并入 #1 的锁粒度结论，不单独计缺陷；未发现 `spawn` 后立即 `get()` |
| §6.4 低效算法 | 2 | `entries.remove(at: 0)`（O(n²) 摊销）与 `deliverCountAt` 每记录线性扫（O(B·G·E)）；两者均作为「优化可行性方案」处理，未按缺陷计 |
| §7 降堆内存方案 | 2 | `QueueLog.append` 全量复制、`entries` 未决窗口上限（与 #2 同根，方案在「优化」段落） |
| §8 降 CPU 方案 | 4 | 位点批量化、未决集合线性操作、`readUpTo` 双缓冲、指标 key 预计算 |
| §9 local mode 可行性 | 0 | 本部分临时数组全部逃逸（记录字节返回给调用方或写入 `f_io`），`CursorStore.save` 的 16 B 编码拷贝太小，收益无法用峰值内存证明 ⇒ 不可行 |
| §11 现有代码的 BUG（存量） | 5 | #2-#6；本轮读到的边界/空值/资源路径另已核对：`GroupCursor` 空 `entries`、`floorOf` 无组（`Int64.Max`）、`readUpTo` EOF、`CursorStore.load` 短文件、`MQMatcher` 空记录均有正确处理 |
| §12 并发安全与锁粒度 | 1 | #1（锁内 I/O）。共享状态已核对：`GroupCursor` 全部可变态在 `Mutex` 内；`CursorCatalog.cache` 持锁、磁盘 IO 在锁外；`MQMetrics` 用 `ConcurrentHashMap` + `AtomicInt64`；`DeadLetterQueue`/`QueueLog` 依赖 `SegmentedLog` 自带的 `appendLock`/`oldFilesLock`（`f_io/src/SegmentedLog.cj:34` 声明线程安全）；锁顺序统一为 `ConsumeService.lock → GroupCursor.lock → CursorCatalog.lock`，无反向持有，未发现死锁 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`，README 覆盖由含 README 的部分判定；实现侧逐项核对：`MQMetrics.removeGroup`/`inc*` 均已接线（`ConsumeService.cj:280-286`、`401`）、`takeUnsupported`/`deliverCountAt` 已接线（`ConsumeService.cj:93`、`349`）、`DeadLetterQueue.cleanExpired` 已接线（`LogCleaner.cj:120`），无「承诺未实现」 |
| 文件覆盖（§13 等） | 17/17 | 清单 17 个文件全部读完；本部分无 `.md`，§13 无对象 |

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 安全性 1（#1 路径穿越）、正确性 6（#2 #3 #5 #6 #7 #8）、设计/可维护性 4（#4 #12 #14 #15）；语言特性方面核对了 `HashMap.add` 的「键存在则覆盖」语义（`docs/dev-guide/source_zh_cn/collections/collection_hashmap.md`，据此排除 `WarnLimiter.allow` / `stats` 里 `backlog.add` 的重复键异常）、`synchronized` 块内 `return` 的提前退出（两种解释对 `openTopic` 等价：都只跳过后续建队列）、`ConcurrentHashMap` 迭代与删除并发（本地文档快照无该节，见 #17 待确认） |
| §1 死代码 | 2 | 已逐个 `private`/`internal`/`protected` 符号全仓搜引用：`QueueManager` 的 `openTopic/closeTopic/queueOf/localQueues/localTopics/delayingOf/queueNumOf/pickQueue/allLogs/sync` 均有调用者；`BackupStore` 的 `append/allLogs/saveCursor/loadCursor/cursorFloor` 有调用者（`instanceCount`、`ConsumeService.statsScans`、`MQCommandExecutor.execute(request)` 仅测试使用，属可见性建议不判死代码）；命中 2 条：#14（恒假分支）、#16（`clear()` 无引用）；`import` 逐文件核对无未使用项 |
| §2 重复逻辑 | 5 | 已把本部分 24 个非测试函数体压成「输入→输出→副作用」两两比对：命中 #9（`localTopics`/`close`）、#10（`readAll`×3）、#11（限流）、#12（游标摘除）、#13（位置比较）；`countOf`/`bodyOf` 这类测试准备代码按误报边界不计；`delayingOf`/`queueNumOf` 只是取不同字段的同形访问器，不构成重复 |
| §3 空实现 | 1 | 无空函数体、无 `TODO`；命中 #3 的 `catch (_: Exception) { None }`（位点解析失败静默降级）；`ConsumeService_test.ConsumeFixture.isClosed` 返回常量属测试替身，不计 |
| §4 栈溢出 | 0 | 本部分无递归函数（`ConsumeService.stats`/`BackupStore.cursorFloor` 都是平级循环 + `Directory.walk` 回调，回调不递归） |
| §5 OOM | 2 | 命中 #6（备份键无界 → 目录/句柄）、#8（备份段永不回收 → 磁盘）；`ConsumeService.stats` 的容器规模由 topics×queues×groups 决定，有界；`BackupStore.readAll` 按真实文件大小分配（位点文件 ~16B） |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile/bench 数据，热点结论不成立；已转「待验证假设」H1–H5 |
| §6.2 大粒度锁 | 1 | 命中 #4（全局游标锁内含磁盘读/写） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` + 立即 `get()`；`consume` 的串行段是 #4 的锁，属并发竞争而非任务串行 |
| §6.4 低效算法 | 0 | `backupStates` 的 O(P×C)、`consume` 的两遍扫未决、`stats` 的全量扫描都缺占比数据，已进优化方案 O2/O5 与 H3/H4，不写成缺陷 |
| §7 降堆内存方案 | 1 | O3（备份记录二次复制）；`clear()` 不还物理内存等假象在本部分不适用（无长生命周期大容器） |
| §8 降 CPU 方案 | 4 | O1（订阅全表）、O2（逐位置扫游标）、O4（位点无缓存）、O5（`consume` 临时容器 + 双扫） |
| §9 local mode 可行性 | 0 | 本部分函数内临时对象都小且逃逸到返回值/成员（`stats` 的 `StringBuilder` 返回、`MQConsumeResult` 返回），`local region` 容量与工具链约束下收益无法用峰值内存证明；仅保留 H6 观察项 |
| §11 现有代码的 BUG（存量） | 8 | #1 #2 #3 #4 #5 #6 #7 #8 全部为存量（快照模式无 diff，`git log` 已核到引入提交）；其余函数（`pick`、`queueOf`、`before`、`ackedByAll`、`writeCursor`、`warnDropped`）的边界与空值逐条核对：`ackedByAll` 空组返回 `false`、`cursorFloor` 空目录返回 `1`、`stats` 空组输出 14 列，均与注释一致 |
| §12 并发安全与锁粒度 | 3 | 共享点：`ConsumeService.cursors`（`Mutex`，见 #4）、`BackupStore.logs/owners`（`Mutex` + `ConcurrentHashMap`）、`QueueManager.topics/openLocks`（`ConcurrentHashMap` + per-topic `Mutex`）、`BackupStore` 位点文件（**无锁**，见 #2）；已核对未见多锁反向获取（`ConsumeService.lock → GroupCursor.lock` 单向，`GroupCursor` 不回调 `ConsumeService`），无死锁面 |
| §14 功能完备性与 README 覆盖 | 1 | 本部分无 `.md`，README 覆盖由其它部分评估；代码侧命中 #7（`MQBackupState` 造而不用 = 接线缺失） |
| 文件覆盖（§13 等） | 12/12 | 清单 12 个文件全部读完，无 `未读`；本部分无 `.md`，故 §13 文档一致性计数为 0 |

### 第 7 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 3（生命周期状态机、服务线程异常、代次表无界）、语言特性 1（`var buffer` 从不重赋值）、可读性 1（硬编码 200/2s/30s 重复库默认值，与「轻微」条目合并计）、设计 1（`close()` 粗锁持锁做 I/O，判定为关闭路径的幂等实现，不另计）。安全性：本部分无外部输入直接拼接 SQL/路径/命令，`subscribedId` 只作 map 键，未见注入面；敏感数据未进日志（记录内容不进日志）。分层：`server` 依赖 `queue`/`meta`/`cluster`，无反向依赖 |
| §1 死代码 | 1 | 已逐个符号机械核对：`MQServer` 的全部 private 成员（`log`/`CHECK_DURATION`/`CLEANUP_INTERVAL`/25 个字段/`reconcileDeletions`/`currentCloseSteps`/`cancelCleanupTimer`/`ensureDir`）全部有读取者或调用者；`MQServerOptions` 的 14 个字段全部被读；`SubscriberRegistry` 的 `groupKey`/`indexOf`/`removeFromGroup` 与 10 个公开方法全部有仓内调用（`clear`/`infos`/`byTopicOf`/`activeIds` 见 `MQCommandExecutor.cj:292,333,341`、`ConsumeService.cj:73,83`、`MQServer.cj:219,305`）；`TestDirs` 三个成员全部被 5 个测试文件使用。`MQServer` 的 10 个 `protected` 成员（`init(options:)`/`port`/`start`/`closeSteps`/`cleanupSubscribers`/`sweepTombstones`/`beforeBind`/`syncQueuesOverride`/`subscriptionRegistry`/`setCloseStepsOverride`）虽只被同模块测试使用，但**有引用**，按 §1「仅测试使用」记为可见性建议而非死代码：`public class MQServer` 未标 `open`，这些 `protected` 对外并无扩展点价值，若下游确实不需要自定义装配，可降为 `internal` 并让测试走 `@Test` 同包可见。唯一死代码是 `connectionKey`（全仓无读取） |
| §2 重复逻辑 | 3 | 已把本部分 11 个非测试函数体压成「输入→输出→副作用」两两比对（`init×2`/`reconcileDeletions`/`start`/`run`/`closeSteps`/`close`/`cleanupSubscribers`/`sweepTombstones`/`ensureDir`/`installExitHooks`），无同语义实现；命中 3：`byGroupOf` vs `activeIds`（同一遍历两种投影）、测试侧 `freePort`/`waitReady`/`startServer`/`options`/`manager`/`managerWithOutput`/`joined`（跨文件两套）、两个 cleanup 用例逐行对齐。另记录一处**同语义不同顺序**（有兜底、不计缺陷）：`MQServer.cleanupSubscribers` 先 `unregister` 再 `releaseSubscription`（`:309-314`），`MQCommandExecutor.onUnsubscribe` 先 `release` 再 `unregister`（`:345-347`）；`releaseSubscription` 抛 `IllegalArgumentException`（`ConsumeService.cj:137`，队列不再本机）时后者会把记录留在已删订阅名下，但 `ConsumeService.consume` 每轮先 `cursor.sweep(active)`（`:87`）会把 owner 不在活跃集合的记录退回组内，故不构成丢消息，仅建议统一顺序并在注释里说明兜底 |
| §3 空实现 | 1 | `TestDirs.cleanNamespace` 的 `catch (_: Exception) {}`（`:48-52`）为唯一空实现/静默吞异常，已按「轻微」计（仅测试收尾、无业务后果，但缺「为什么可以忽略」的注释）。`MQServer` 的四处 catch（`:151-155`、`:313-318`、`:334-336`、`:253-256`）均有 ERROR/WARN 日志，非静默 |
| §4 栈溢出 | 0 | 本部分无递归：`reconcileDeletions`/`close`/`cleanupSubscribers`/`sweepTombstones` 均为单层 for 循环，无自引用结构遍历，无每帧大对象；`MQSubscriptionInfo` 无父子引用 |
| §5 OOM | 2 | 命中 `generations` 只增不减（含 `byGroup` 空列表残留，合并计 1 条）、`closeDone`/`failures` 虽无界但受步骤名与固定 13 步约束（不计）。已量化：约 100–150 B/次订阅、百万级才到百 MB 量级；`TestDirs` 的临时目录只在测试进程内增长（不计） |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 `cjprof`/`cjpm bench` 数据，`of`/`byGroupOf`/`activeIds` 的锁与遍历成本一律进「待验证假设」#1、优化方案，不作缺陷。历史 `parts/fmq.part6.md` 已就 `byTopicOf` 的全表扫描记录过一条同类方案，本部分不重复 |
| §6.2 大粒度锁 | 0 | `close()` 在 `closeLock` 内执行 `server.close()`/`queues.sync()`（fsync）/`meta.close()`（`MQServer.cj:240-262`），属「锁内 I/O」，但只在关闭路径、无请求并发、且粗锁正是「幂等 + 失败步骤可重试」的实现基础（`closeDone`/`closeCompleted` 需与步骤执行原子），判定为可接受；`SubscriberRegistry` 的单锁是否成为热点见 §6.1/§12.2 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get()`；accept 循环每连接 `spawn`（`f_net`），执行器池 200；唯一的串行段是 2s 巡检 timer 线程上的 `cleanupSubscribers`（O(订阅数)），已列「待验证假设」#2 |
| §6.4 低效算法 | 1 | `removeFromGroup` 的 `indexOf`（O(n)）+ `ids.remove(at: index)`（O(n)）每次注销/重订阅扫两遍组内列表（`SubscriberRegistry.cj:200-218`），列「待验证假设」#4（组规模无数据，不作缺陷）；`byTopicOf` 的 O(全表) 已由 part6 记录，不重复 |
| §7 降堆内存方案 | 1 | 巡检/消费快照 `toArray()` 副本（方案已写，无基线）；`clear()` 只清元素不还物理内存的事实已在方案「代价」中提示；`generations` 的修剪归入「一般」#1 的修法，不重复计方案 |
| §8 降 CPU 方案 | 2 | 消费路径两次组快照合并、订阅表读写分离（均无基线） |
| §9 local mode 可行性 | 0 | 本部分函数内无「大对象 + 函数内销毁」形态：`start`/`close` 的临时对象是 13 个闭包 + 小数组（一次性），`cleanupSubscribers`/`byGroupOf` 的临时容器按订阅数增长但单元素是引用（不复制 `MQSubscriptionInfo`）；无峰值内存数据，无法证明 local region 收益，且需 `--experimental --enable-local-mode` 全模块开启、`SocketBuffer`/`MQSubscriptionInfo` 均要 `@ local!` 重建，收益/风险不成立 |
| §11 现有代码的 BUG（存量） | 7 | 本轮读到的存量问题：#1 代次表无界、#2 生命周期状态机（含 close-before-bind 漏关）、#3 测试端口探测不 connect、#4 服务线程异常不可观测、#5 死字段、#6 重复遍历、#7 `/tmp` 硬编码；另逐项核对过的边界：`close()` 空 `failures` 才算完成（`:258`）、`unregister` 代次不符返回 `SUBSCRIBE_NOT_EXIST` 且不删（`:80-83`）、`cleanupSubscribers` 在代次不符时 `continue` 且不释放（`:310-312`）、`freePort` 200 次上限后抛错、`reconcileDeletions` 对「墓碑对应条目已复活」`continue`（`:140-147`）、`sweepTombstones` 单步异常只 WARN（`:334-336`）—— 均与注释/规格一致 |
| §12 并发安全与锁粒度 | 4 | 已列出共享点与同步手段：`SubscriberRegistry` 三张表由 `lock` 保护（读写都在 `synchronized` 内，`removeByTopic` 先收 victims 再删，避免迭代中改容器）；`MQServer` 的 `started`/`closed` 用 `AtomicBool`；`close` 用 `closeLock` 保证幂等；`generation` 在 registry 锁内写、`infos()` 取锁建立 happens-before 后在锁外读（同一对象不再被并发改写，因为 `register` 总是新建 `MQSubscriptionInfo`）—— 判定无数据竞争。命中 4：`server`/`cleanupTimer` 普通字段跨线程读写（#2）、服务线程异常（#4）、代次表无界（#1）、订阅表单锁粒度（优化方案）。`beforeBind`/`syncQueuesOverride`/`closeStepsOverride` 是测试注入点，写入发生在 `start()` 之前，不构成并发缺陷 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分公开面仅 `MQServer`（`init`/`run`/`close`/`isClosed`）与 `installExitHooks`：`README.md:62-63` 描述 SIGTERM 关闭链路、`:185`/`:189` 符号表列出 `installExitHooks` 与 `MQServer.isClosed`，`doc/详细设计.md:607-618` 给出 `run`/`close` 与装配顺序、`:168` 说明 `installExitHooks` 的可注入设计；`MQServerOptions`/`MQSubscriptionInfo`/`SubscriberRegistry` 均为 `protected`，不进 README 属正确。承诺的「close 幂等 + 失败步骤重试」「关闭后端口可再绑定」「断链清理可由测试直接触发」均有实现与用例（`MQServer_test.cj:184-209,440-592`）。`installExitHooks` 只做转发、把 installer 交给调用方，是否为过宽接口属设计口味（文档已声明可注入），不作缺陷 |
| 文件覆盖（§13 等） | 8/8 | 无缺文件；本部分无 `.md`，文档一致性只就 `详细设计.md:648` 的 `byGroupOf` 语义作交叉核对（已计「轻微」一条，`.md` 本身由另一部分覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 32 |
| 轻微 | 58 |
| 其中存量 | 83 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分只有文档，但文档质量整体偏高：`README.md` 的 12 个配置默认值、13 步关闭顺序、13 列 `stats`、备份的 64 条 / 100ms / 3 次重试、存储布局（含墓碑与备份游标文件名）、命名与长度限制，逐条都能在 `src/` 找到对应实现且数值一致；`fmq.sh` 的注释与 README 同步；`doc/spec/**` 的 `MODIFIED` 链条与源码事实基本吻合（墓碑胜负、段末尾归一化、记录上限三层防线、备份重试与位点）。没有「README 承诺的功能整体不存在」这类严重漂移。

主要风险分三类：

1. **运行时观测口径**：#1 `lagMs` 取「首个队列首条」而非「最早一条」，多队列、游标不齐时系统性偏小，积压告警会迟报。这是本部分唯一直接影响运维判断的实现偏差，建议与 `ConsumeService.stats` 的代码修复合并处理。
2. **语义缺口（可能伴随丢消息）**：#2 消费三态写了两态，「匹配订阅者离线、组内仍有人在线」被实现折叠成「无匹配」直接越过；#3 README 的「备份盘不会无界增长」与同文档的保留规则相反。#2 的代码侧定性请交给 `GroupCursor` 所在部分，若确认丢消息应按严重处理。
3. **文档滞后与台账不可信**：#6 `backlog.md` 的 P0 四项已全部落地、行号漂移；#11 `design.md` 处置清单还剩 2 项未落地（恒假分支 + 零引用死方法）；#4 旧 delta 同一节内自相矛盾且无取代标注。这类文件最容易把人带回去重做已完成的工作。

其余为表述与覆盖问题（#5 公开 API 清单、#7 5 分钟容差、#8 死信不可读、#9 默认配置每秒 WARN、#10 `each commit`、#12 `skipped*` 口径、#13 恢复入口、#14 默认值六处复制），一次 PR 可以连同中英两份改完。

无阻塞项：没有一条会导致数据错误或启动失败；#1 / #2 / #3 建议优先排期，其余可进文档整理窗口。第 2–7 部分的代码结论若与本部分冲突，以代码侧取证为准；合并时请把 #2 与 `GroupCursor` 的代码结论、#11 与 `MQMatcher` / `QueueLog` 的死代码结论各并成一条。

**第 2 部分**：本部分不含 `.cj`，但它是 fmq 的契约层：postfix-audit 的 delta 把墓碑判定、段末尾归一化、记录/段上限联动、死信阈值、`stats` 严格模式、关闭 13 步、管理端错误四分类都写成了可验收的 SHALL + Scenario。逐条对照源码后，**规格主体可信**：抽查的 20 余个断言（`effectiveMaxRecord`、零长度判损坏、损坏/段缺失分流、`deliverCount = N+1`、14 列 TSV、`ackedByAll` 边界、13 步关闭顺序、12 个配置项、6 条命令错误分支、`MQMetrics` 原子自增、`TestDirs` 可见性）都能在 `fmq/src` 找到对应实现，未发现「承诺的功能不存在」这类严重漂移。verify-report 的 9 份 / 59 条 / 282 个 Scenario 也与两模块合并统计吻合，不是统计错误。

风险集中在三处，都不在实现主体而在「文档没跟上代码」：

1. **有一条 SHALL 没落地**——备份关闭期失败的批次仍 `requeue` 进 `pending`（#1），与「丢弃并记 ERROR」相反。这是本部分唯一涉及运行期行为的项，影响面限于发送失败的副本与日志粒度，建议与集群/备份部分的修复合并（同一落点 `BackupReplicator.requeue`）。
2. **台账不真实**——`开发计划.md` 的 3 个源路径、143 个用例名、8 个已删成员、配置项数量与读取方式全部停留在设计期（#2），而 `tasks.md`、`docs/spec.md` 又有三条不成立的自检断言（#3）。按计划实现会找不到文件，按台账会以为已核对过。
3. **验收口径空转**——主规格定在 `openspec/specs/**`，该目录没有 fmq 能力，「检索『最老段』为 0」必然通过；verify-report 的「对照主规格」没有对象（#4），且它以「3 WARNING + 4 SUGGESTION 未闭环」收尾，实际 7 条都已修（#5）。

建议排期：#1 与集群/备份代码修复同批；#2、#3、#8 一次通读 `开发计划.md` + `tasks.md` 改完（同一 PR 内可完成）；#4 需先定「fmq 主规格放哪里」；#5、#6、#7、#9、#10 随下一轮文档收敛处理。

**范围外提示**（不计入统计）：`fmq/src/config/MQConfig.cj:312` 用字面量 `64 * 1024 * 1024 + 4` 判断段上限，与 `fmq/src/queue/QueueLog.cj:48` 的 `MAX_RECORD_SIZE` 是同一常量两处定义（§2 字面量复制），改一处漏一处会让「启动期 WARN 阈值」与「写入拒绝阈值」分叉。

**第 3 部分**：本部分的代码形态是「三个集群组件 + 入口帮助文本 + 测试夹具」。分工清晰、注释里带设计编号（A25/A27/A31/A33/A41），`BackupReplicator` 的「发布只入队、worker 批量发送、失败按目标集合重试」与 `LogCleaner` 的「逐段/逐队列隔离异常 + 轮末汇总」都是按可测性设计的，12 个清理用例还断言了「段文件真的少了」而不是只看计数，这是本模块里质量较高的一块。

**唯一的阻塞项是 `MetaSyncer.mergeSnapshot` 的「快照缺失即删」**：它把「某个 peer 没收到某次广播」判定成「本机多了一条」并删除，删除会走到 `closeTopic(deleteFiles: true)`，消息段与游标一起没。触发不需要并发，只需要一次广播失败（设计已把它当常态）+ 该 peer 之后有任何 revision 更高的变更；而 `nextStartNode` 的单调性、`close()` 的收尾语义又分别有各自的竞态窗口。这三条建议一起修：删除路径加墓碑/多 peer/严格版本三重门、单调性下沉到 `MetaStore` 锁内、`closed` 判定移进 `pending` 锁。

备份复制面还有两个可量化的风险：容量只数条数不数字节（理论 512GiB，1MB 记录也有 8GiB），以及 flush 取走整个积压（`BATCH_SIZE` 只触发不封顶）。两者叠加在「副本慢」这个本来就要靠队列扛的场景里，建议按字节预算 + 分批一起做，并配 `cjprof heap` 的前后对照。

轻微项集中在测试资产（`LogCapture_test.cj` 四份、`FmqTestSetup_test.cj` 三份、`CapturingAppender.clear()` 从未被调用）与两处「文档/注释停在旧实现」（待补偿集合、备份 Timer 线程模型）。这些不影响运行，但会让下一次改动误判「已有覆盖/已有兜底」，建议随同上面三条一起收敛。性能类结论（`broadcast` 串行、`floorOf` 每段一次、10ms 轮询）目前只有结构证据，已全部放进「待验证假设」与无基线的优化方案，未计入缺陷。

**第 4 部分**：本部分是 fmq 的「元数据 + 集群节点表 + 配置 + 管理端」底座，工程化程度明显高于平均水平：写入路径统一 `.tmp + fsync + rename`、墓碑用 `(revision, origin)` 做 LWW 且双向收敛、坏文件只记 ERROR 不阻断启动、加载期还有 `convergeTombstonesLocked` 兜住崩溃窗口，`MetaStore`/`MetaSyncer` 两个用例文件合计 50+ 个场景（含并发注册、崩溃残留、乱序快照）。

阻塞项只有一个，但很实际：**`queueNum` 从请求载荷直达数组长度与队列目录数，没有任何上限**（`MQAssignment.cj:37`）。服务端无鉴权，一条 REGISTER 就能把进程打到 OOM，且分配发生在元数据锁内，会连带打死同步路径。建议作为本模块唯一的必修项排期。

其余风险集中在「一致性顺序」而非逻辑错误：`applyGroup` 与 `registerTopic` 的「内存先行」会让写盘失败留下幻影状态（重启后回退），与同文件另外两条「先盘后内存」的路径自相矛盾；墓碑键格式 6 处手写、`MQMetaTombstone.key()` 闲在一旁，是典型的「今天一致、改一次就静默复活已删条目」的隐患。

性能面没有可用的基线，因此 `MetaStore` 的单锁 + 锁内 fsync、`maxRevisionLocked` 的全表扫、复活回调的同步执行都只写成优化方案与待验证假设，未计入缺陷——这几条如果要推进，第一件事是补 `cjprof` + 线程状态数据，而不是先改代码。

轻微项（死分支、未使用 import、双 catch、`close()` 无效果、错误文案分类、测试命名等）可以随下一次顺手清理。存量发现 15 条（1 严重 / 2 一般 / 12 轻微），是否纳入修复待用户决定。

**第 5 部分**：这一部分是 fmq 的「消费位点 + 段读取 + 死信 + 指标」核心，语义严谨度明显高于平均水平：投递/确认状态机（`DeliveryRecord` + `committed` 只增、乱序 ack 留洞、`autoAck` 计入 acked、阈值 N+1 次投递）在 22 个用例下自洽；段缺失/损坏/空洞三种恢复路径都有专门用例；`CursorCatalog` 用「全部已注册组的最小位点」做段保留边界，避开了「按内存游标删段会删掉慢组积压」的经典坑；并发状态全部走单把 `Mutex`，锁顺序单一，未见死锁与可见性缺口。

真正的风险集中在两处，都不是语义错误而是**放大量级**：

1. **位点落盘频率与锁粒度**（#1）。每条 ack、每条被越过的记录都要 `create + fsync + rename + dir fsync`，且都在游标锁内。功能正确，但一旦出现「组内大量不匹配消息」或「慢消费者」，消费请求会以 fsync 为节拍器，P99 直接塌陷；这也是本部分唯一建议优先排期的项（先补 `cjprof`/`strace` 数据再改）。
2. **未决集合无上限**（#2）。队首一旦卡住，后续整段积压会被物化成 `DeliveryRecord` 常驻内存。同样是「正确但无界」，需要先量化再定上限。

其余 4 条一般项都是**异常/运维路径上的一致性缺口**：段读取异常被折成「损坏」（#3）、段空洞恢复丢可读未决项（#4）、`readAt(resume:false)` 契约只实现了一半（#5）、死信读取把损坏当结束（#6）。它们只在段被删/被截断、或死信文件损坏时触发，正常路径不受影响，属于「排期修」而不是「阻塞发布」；但 #3 的误导性 ERROR 日志会直接把排障带偏，建议连同日志文案一起修。

死代码与重复逻辑各 3 条，量级很小（两个无引用符号、一个恒假分支、三处同构代码），说明这个包在被持续清理过（仓库自带的 postfix 审计文档还留了几条未落实的清理项）。总体判断：**无阻塞项；建议按「#1 补数据→批量化、#2 定上限、#3-#6 修正异常分类」三批推进。**

**第 6 部分**：本部分代码整体结构清晰：队列生命周期（`QueueManager`）把「慢操作按主题单锁 + 失败回滚」写对了，`ConsumeService` 的游标懒建、单趟 stats 扫描、异常到 `MQErrorCode` 的映射都有注释与用例兜底，`MQCommandExecutor` 的命令分发把异常收敛在边界内、每条分支都有确定错误码。投递/确认主链路的语义（严格越过才算确认、断链订阅退回组内、autoAck 计入 acked、stats 不伪造 backlog）与用例一致，未发现「静默丢消息」类缺陷。

阻塞项只有一条：**内部删除载荷的主题名不校验 + `escape` 不处理 `.`/`..` + `remove(recursive)` 直接拼路径**，三者叠起来可被一条 `DEREGISTER` 内部消息删掉整个队列根目录甚至其父目录。修法很窄（`escape` 特判 + 删除前路径前缀断言 + `onInternal` 补校验），但必须先修。

其次是备份链路的三个正确性/资源问题（位点读-判-写非原子、`cursorFloor` 把不可读位点当缺失、`close()` 部分失败后不可重试）与两个「造了数据没人用/不回收」的完备性问题（`states` 丢弃；备份副本既不随主题删除、无位点时也永不回收）。这些都不阻塞发布，但会在「备份恢复 + 磁盘容量」两条线上留下长期隐患，建议排进下一轮修复。

性能侧本部分没有 profile/bench 数据，因此没有报成缺陷：发布路径的全量订阅快照、`backupStates` 的逐位置扫游标、`consume` 的临时容器与双扫未决集合，都先作为无基线的优化方案与待验证假设列出，等补完数据再决定是否进 `tasks.md`。

存量问题共 17 条（严重 1 / 一般 7 / 轻微 9），是否纳入修复待用户决定；本轮只报不改。

**第 7 部分**：这一部分是 fmq 的「装配层 + 订阅表 + 测试基建」，主体质量不错：装配顺序与关闭顺序严格按规格的相反序执行，`close()` 的「逐步 try/catch + `closeDone` 记账 + 只重试失败步骤」是全仓少见的完整实现，断链清理用「快照 + 代次」解决了重订阅误删（A60），并有针对性用例；`SubscriberRegistry` 的两个索引在单锁内维护，读路径都有锁，未见数据竞争。

风险集中在两处。**第一是生命周期状态机**：`start()` 不检查 `closed`、`server`/`cleanupTimer` 用普通字段在「启动线程—信号线程」之间传递，导致「close 后再 run 会留下绑了端口的僵尸实例」和「SIGTERM 早于 bind 时漏关 Server 却宣告关闭完成」两个缺口；再叠加 `spawn { srv.start(...) }` 无异常传播，服务线程死亡对 `run()` 不可见。这三条都在生产主路径（SIGTERM 是唯一的正常退出方式），建议优先于其它问题处理，修法不需要改架构，只需一把锁 + 一个失败状态位。**第二是 `generations` 无界**：客户端 UUID 作键、永不回收，长跑节点的内存随历史订阅次数单调增长，属于可预期的慢性 OOM 面。

测试基建的问题值得单独提：`MQManager_test` 的端口探测漏了 `connect()`，使「等待就绪」恒真 —— 这不是风格问题，而是会让 14 个用例在服务未起来时继续执行，把「启动失败」误报成「连接失败」，同时把仓库里已经写对的版本（`MQServer_test.cj:50-65`）复制成了两套。修掉它能显著降低 fmq 单测的偶发失败率。

存量共 10 条（一般 4 / 轻微 6），是否纳入本轮修复待用户决定；其中「一般」#2、#4 建议优先，#3 属于测试可信度问题建议一并处理，#1 可排期。「优化可行性方案」3 条与「待验证假设」5 条均无基线，仅在下一轮补数据后进入修复清单。
