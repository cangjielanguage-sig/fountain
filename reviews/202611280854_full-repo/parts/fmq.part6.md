# fmq 模块审查报告（第 6/7 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fmq/src/queue`、`fmq/src/server`（本部分清单 12 个文件，全部为 `.cj`）
- **基线**：工作区快照（`git status` 只有未跟踪的 `docs/review/`、`reviews/202611280854_full-repo/`，源码无 diff）⇒ 所有问题来源写「存量」
- **审查重点**：投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑（另按 checklist 全维度扫）
- **报告版本**：v1（模块分部分报告，由主 Agent 合并到 `docs/review/2026-11-28/fmq_v2.md`）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| H1 | `ConsumeService` 全局游标锁是消费吞吐上限（多队列/多组时排队在 `cursorOf`） | `fmq/src/server/ConsumeService.cj:129` | 锁等待时长、线程状态（BLOCKED 占比）、`consume` 端到端 p99 | 200 executor 压测：10 主题 × 20 队列 × 5 组，`cjprof record` + 线程状态采样，对照把锁换成 `ConcurrentHashMap` 的分支 |
| H2 | 发布路径的 `byTopicOf` 全表扫描/分配是 publish p99 的可见部分 | `fmq/src/server/MQCommandExecutor.cj:292` | `byTopicOf` 自耗时占比、每消息分配字节 | `cjpm bench -O2`，1000 订阅 / 10 主题，`cjprof` 看 `byTopicOf` 与 `toArray` |
| H3 | `stats` 全量扫描 backlog 在大积压下会拖长内部 STATS 调用（无增量、无上限） | `fmq/src/server/ConsumeService.cj:184`–`262` | backlog=10^5/10^6 时单次 `stats` 耗时与 CPU 占比 | 造 backlog 10^6 条后调 `stats("")`，分段计时（扫段/计数/字符串拼接） |
| H4 | `backupStates` 的 O(位置×游标) 在 200 队列/10 组时占备份线程 CPU 明显 | `fmq/src/server/ConsumeService.cj:302`–`357` | 单批耗时、自耗时占比 | 固定 64 条批次，`cjprof` 跑备份 flush 10 分钟 |
| H5 | `cursorFloor` 每轮读全部位点文件在「备份队列多 + 组多」时是清理器的主要 I/O | `fmq/src/server/BackupStore.cj:158`–`187` | 单轮清理 IO 次数与耗时 | 100 备份队列 × 10 组，`cjpm bench` 调 `cleanOnce`，统计读文件次数与耗时 |
| H6 | 本部分涉及的临时结构（`stats` 的 `StringBuilder`/`HashMap`、`loadCursor` 的 codec）适合 local mode | `ConsumeService.cj:179`–`199`、`BackupStore.cj:136`–`152` | 峰值内存前后对照（`getUsedHeapSize` / RSS / `getAllocatedLocalObjectSize`） | 先在 `cjpm.toml` 的 `compile-option` 开 `--experimental --enable-local-mode`，同输入对照峰值内存；无收益则关闭 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fmq/src/queue/QueueLog_test.cj` | .cj | ✅ | 测试；`countOf` 与 `ConsumeService_test` 同名同体（测试准备代码，按 §2 误报边界不计重复） |
| 2 | `fmq/src/queue/QueueManager.cj` | .cj | ✅ | 见 #1/#5/#9/#14/#15 发现 |
| 3 | `fmq/src/queue/QueueManager_test.cj` | .cj | ✅ | 覆盖并发打开/回滚/轮转/关闭语义，与实现一致 |
| 4 | `fmq/src/queue/WarnLimiter.cj` | .cj | ✅ | `allow` 用 `HashMap.add`（文档 §collection_hashmap：键存在则覆盖），无「窗口过期后二次 add 抛异常」问题 |
| 5 | `fmq/src/server/BackupStore.cj` | .cj | ✅ | 见 #2/#3/#5/#6/#7/#8/#10/#11/#17 |
| 6 | `fmq/src/server/BackupStore_test.cj` | .cj | ✅ | 用例把「无位点不回收」固化为断言（`240`–`248`），见 #8 |
| 7 | `fmq/src/server/ConsumeService.cj` | .cj | ✅ | 见 #4/#7/#12/#13 与优化方案 O2/O5 |
| 8 | `fmq/src/server/ConsumeService_test.cj` | .cj | ✅ | stats/备份状态/多队列/断链场景齐全；`countOf` 与队列测试重复（测试代码不计） |
| 9 | `fmq/src/server/FmqTestSetup_test.cj` | .cj | ✅ | 全局 `Config.set(protocol_hostId=1)`，与 f_protocol 校验一致 |
| 10 | `fmq/src/server/LogCapture_test.cj` | .cj | ✅ | 见 #16（死代码）；`waitFor` 轮询 10 ms 与 f_log 异步落盘匹配 |
| 11 | `fmq/src/server/MQCommandExecutor.cj` | .cj | ✅ | 见 #1/#6/#7/#8 与优化方案 O1/O3 |
| 12 | `fmq/src/server/MQCommandExecutor_test.cj` | .cj | ✅ | 命令矩阵/墓碑清理/备份位点用例与实现一致 |

合计：`.cj` 12 个 / `.md` 0 个 / 共 12 个，全部读完（本部分清单不含 `.md`，README/`doc` 一致性与 §14 的文档覆盖属其它部分）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 7 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 4 |

## 总评

本部分代码整体结构清晰：队列生命周期（`QueueManager`）把「慢操作按主题单锁 + 失败回滚」写对了，`ConsumeService` 的游标懒建、单趟 stats 扫描、异常到 `MQErrorCode` 的映射都有注释与用例兜底，`MQCommandExecutor` 的命令分发把异常收敛在边界内、每条分支都有确定错误码。投递/确认主链路的语义（严格越过才算确认、断链订阅退回组内、autoAck 计入 acked、stats 不伪造 backlog）与用例一致，未发现「静默丢消息」类缺陷。

阻塞项只有一条：**内部删除载荷的主题名不校验 + `escape` 不处理 `.`/`..` + `remove(recursive)` 直接拼路径**，三者叠起来可被一条 `DEREGISTER` 内部消息删掉整个队列根目录甚至其父目录。修法很窄（`escape` 特判 + 删除前路径前缀断言 + `onInternal` 补校验），但必须先修。

其次是备份链路的三个正确性/资源问题（位点读-判-写非原子、`cursorFloor` 把不可读位点当缺失、`close()` 部分失败后不可重试）与两个「造了数据没人用/不回收」的完备性问题（`states` 丢弃；备份副本既不随主题删除、无位点时也永不回收）。这些都不阻塞发布，但会在「备份恢复 + 磁盘容量」两条线上留下长期隐患，建议排进下一轮修复。

性能侧本部分没有 profile/bench 数据，因此没有报成缺陷：发布路径的全量订阅快照、`backupStates` 的逐位置扫游标、`consume` 的临时容器与双扫未决集合，都先作为无基线的优化方案与待验证假设列出，等补完数据再决定是否进 `tasks.md`。

存量问题共 17 条（严重 1 / 一般 7 / 轻微 9），是否纳入修复待用户决定；本轮只报不改。
