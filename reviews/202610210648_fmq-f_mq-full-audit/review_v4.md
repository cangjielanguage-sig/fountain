# R4: fmq 队列与消费语义（分段日志 / 游标 / 投递-ack-重投-死信-延迟 / 队列管理）

审查时间：2026-10-21 07:10
审查基线：HEAD `5a133474`（全树审计，非 diff）

### 审查范围

代码（`fmq/src/queue/**`，12 个文件，54 条用例）：

- `fmq/src/queue/QueueLog.cj`、`QueueLog_test.cj`
- `fmq/src/queue/CursorStore.cj`、`CursorStore_test.cj`
- `fmq/src/queue/GroupCursor.cj`、`GroupCursor_test.cj`
- `fmq/src/queue/DeadLetterQueue.cj`、`DeadLetterQueue_test.cj`
- `fmq/src/queue/DeliveryRecord.cj`、`MQMatcher.cj`、`MQMatcher_test.cj`
- `fmq/src/queue/QueueManager.cj`、`QueueManager_test.cj`

依赖参照（只用于确认语义，不计入被审对象）：

- `f_io/src/SegmentedLog.cj`（`append`/`logMetas`/`openEntryStream`/`removeById`/`ChainedSegmentStream`）
- `f_mq/src/base/MQMessageRecord.cj`（`publishTime`）、`f_mq/src/base/payload/**`（`MQDeadLetterMessage`）
- `fmq/src/server/ConsumeService.cj`（游标懒建、`references` 接线、`stats`）、`fmq/src/server/MQServer.cj`（装配/关闭顺序）
- `fmq/src/cluster/LogCleaner.cj`、`LogCleaner_test.cj`（段 TTL 清理链路）
- `fmq/src/config/MQConfig.cj`、`fmq/src/meta/MQFileNames.cj`

文档：

- `fmq/doc/spec/add-fmq-message-queue/specs/fmq/queue-storage/spec.md`
- `fmq/doc/spec/add-fmq-message-queue/specs/fmq/consume-semantics/spec.md`
- `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/consume-semantics/spec.md`（延迟投递 delta）
- `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/metrics/spec.md`（`backlog`/`lagMs` 口径）
- `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/queue-storage/spec.md`（记录边界格式）
- `fmq/doc/详细设计.md` §5.7–5.14、§6.4–6.6、§6.9、§6.11
- `fmq/doc/backlog.md`（已归档遗留项，用于排除重复报告）

### 发现

#### [S1] [严重] 段 TTL 清理只认「内存游标」，持久化位点被忽略，慢组积压会被直接删掉

- **位置**：`fmq/src/server/ConsumeService.cj:202-214`（`references` 只遍历 `cursors` 这个懒建的内存表）、`fmq/src/queue/GroupCursor.cj:351-355`（`references = segmentIndex >= committed_.seq`）、`fmq/src/cluster/LogCleaner.cj:58`（删除条件只用这个回调）、`fmq/src/server/ConsumeService.cj:110-127`（游标只在消费时创建）
- **现象**：`GroupCursor` 采用「懒建」——只有某组真正发起过 `CONSUME`，内存中才会出现该组的游标。服务重启后、或某组长时间没有消费者在线时，磁盘上仍有 `metas/offsets/<topic>/<queue>/<group>.cursor`，但 `ConsumeService.cursors` 里没有对应项，`references()` 对该组一律返回 `false`。`LogCleaner.cleanOnce` 因此在「该组位点仍指向这些段」的情况下照常删除它们（`updateTime + ttl < now` 即删）。`GroupCursor.recoverIfSegmentGone`（`GroupCursor.cj:393-418`）随后会把位点跳到现存最老段，`committed_` 可能**向前跳**，整段未消费消息永久丢失。
- **影响**：直接违反 `queue-storage/spec.md:150-168`「删除『…**且没有任何游标引用该段**』的封口段」与「被游标引用则保留」。触发条件真实存在：`segmentedLogTTL` 默认 72h、清理器每 5 分钟一轮，任何「离线超过 TTL 的订阅组 + 服务重启」都会命中；把 TTL 调小（或像测试那样用负 TTL）则立刻命中。现有用例无法发现：`LogCleaner_test.cj:88` 用 `{_, _, index => index == firstSealed.index}` 这个假回调替代真实 `ConsumeService.references`，从未把「真实 GroupCursor / 真实 cursor 文件」接进清理链路。
- **建议**：`references` 的判定必须覆盖持久化位点——最小改动是清理前对每个 `(topic, queueIndex)` 枚举 `metas/offsets/<topicEsc>/<queueIndex>/*.cursor`，取所有已落盘位点与内存游标的 `min(committed.seq)` 作为保留下界（落在内存表里的组可继续用现有逻辑，落盘的组按文件内容判断）；或改为「启动时按主题×组预建所有 GroupCursor」，但那会放大内存与启动代价，不如前者。补一条集成用例：写消息 → 消费并落盘位点 → 关闭服务（丢弃内存游标）→ 用负 TTL 跑 `cleanOnce` → 断言段仍在、位点未跳。

#### [S2] [严重] 读取端对记录长度头没有任何上界校验，损坏/撕裂的段会触发 GB 级分配并导致进程 OOM

- **位置**：`fmq/src/queue/QueueLog.cj:201-206`（`length = getInt32BE(h, 0)`，只判 `length <= 0`）、`fmq/src/queue/QueueLog.cj:241-262`（`readExact` 第 242 行 `Array<Byte>(size, repeat: 0u8)` 直接按 `length` 分配）
- **现象**：4 字节大端头被解码成 `1 .. 2^32-1` 的任意值。只要头部字节不完整（掉电/撕裂写在段尾留下半条记录，尾部是预分配空洞里的 0 或被覆盖的脏字节），读端就会按该值一次性申请最大 4 GiB 缓冲。写入侧有 `MAX_RECORD_SIZE = 64 MiB` 限制（`QueueLog.cj:33,42-44`），读取侧完全没有对应限制，也没有「不超过本段剩余有效字节」的检查（`QueueRecordReader` 手里就有 `segments` 快照，可用 `segments[i].size` 算出剩余量）。
- **影响**：单条损坏记录足以让 `fmq server` 进程被 OOM killer 杀掉（或 `Array` 分配抛异常打断整轮消费）。这与 `详细设计.md:321-323`「剩余字节不足视为损坏并停止读取」的承诺相反：当前实现是「先按声明长度分配，再发现读不满」。同类问题在 `f_codec` 已有专门防护并归档过缺陷（`DefaultCodec.checkedBuffer`，见 `f_codec/src/default/DefaultCodec.cj:723-738`），这里遗漏了。
- **建议**：`QueueRecordReader.next()` 在 `length <= 0` 之外再判 `length > QueueLog.MAX_RECORD_SIZE` 与 `length > 本段剩余有效字节`，两者任一成立即按损坏处理（记录 WARN 并返回 `None`，或抛 `IllegalArgumentException`，与语义统一）；`readExact` 增加 `size` 上限参数。补用例：手工构造「长度头 = 2 GiB」「长度头只写 2 字节」的段文件，断言不分配、返回 `None`/抛异常。

#### [S3] [严重] 不可评估 BODY（`Unsupported`）会让该组队列永久停摆，且无日志、无指标、无可恢复路径

- **位置**：`fmq/src/queue/GroupCursor.cj:243-246`（本订阅 `Unsupported`）、`:256-258`（组内其它订阅 `Unsupported`）、`:271-276`（`scanPosition` 回退、关流、静默 `return None`）
- **现象**：扫描到「BODY 是未在本进程注册的对象类型 + 订阅 filter 非空」的记录时，游标既不建未决项、也不标记已决、也不推进 `committed`，直接返回 `None`（连 `logger.warn` 都没有，而同类异常在 `:427-429` 的延迟分支里是会告警的）。由于队列是 FIFO 且 `scanPosition` 停在该位置，此后该组对该队列的**每一次** `CONSUME` 都只会重扫这一条并返回空——组内所有后续消息永久不可达。
- **影响**：发布侧的 `bodyIsEvaluable` 只检查「**当下**有非空 filter 的活跃订阅」（`MQCommandExecutor.cj:230-241`），因此「先在没有 filter 订阅时发布，之后才 subscribe 带 filter 的订阅」这条完全正常的时序就会把整组卡死。规格 `consume-semantics/spec.md:9-10,32-35` 要求「该记录 MUST NOT 被投递，并 SHALL 以 `FILTER_UNSUPPORTED_BODY` 语义报错」，实现既没有把错误面暴露给任何一方（消费者只看到「没有消息」），也没有超时/死信等出口，属于「静默且不可恢复」。现有 54 条用例中**没有任何一条**走到这个分支。
- **建议**：①扫描命中 `Unsupported` 时至少 `logger.warn` 并累加一个新的指标（如 `filterUnsupported`），必要时回一个可区分的错误码给消费者，而不是 `None`；②给出出口：超过 `ackTimeout` 或一个独立的 `unsupportedTimeout` 后把该位置转入死信并标记已决，避免整组永久停摆；③在 `consume-semantics` 规格里把「不可评估」在消费侧的行为写清楚（当前只写了发布侧）。补用例：注册过滤器 → 用未注册对象类型的记录（可用截断记录模拟，参考 `MQMatcher_test.cj:97-105`）走完 `GroupCursor.next`，断言行为与日志/指标。

#### [G1] [一般] `scanAfter` 在位点段被删（但非最老段）时静默返回 `(0, None)`，`backlog`/`lagMs` 被报成 0

- **位置**：`fmq/src/queue/QueueLog.cj:98-129`（`101-103` 只处理 `start.seq < 最老段` 的情况；`125-127` 任何异常都 `return (0, None)`）、`fmq/src/server/ConsumeService.cj:161-166`（stats 直接采信）
- **现象**：只有「位点段号小于现存最老段」才会把起点修正到最老段。若位点段号落在「比最老段大、但已被删除」的区间（S1 的后果，或手工删段、或先删后建），`openRecordsFrom` 抛 `IllegalArgumentException`，被 `catch` 吞掉后返回 `(0, None)`——统计口径上表现为「积压 0、延迟 0」，与实际积压相反。
- **影响**：违反 `metrics/spec.md`「`backlog` 必须与查询时刻的持久化状态一致，不得使用可能失真的估算值」；运维会据此误判「没有积压」而放过已经积压的组。与 S1 叠加时问题被完全掩盖。
- **建议**：把起点修正改为「取第一个 `index >= start.seq` 的现存段，段号相同则用 `offset`，段号更大则用 0」；确实无法判定时返回 `None` 让上层输出「不可用」而不是 0。补用例：`committed` 指向已删的中间段，断言 `scanAfter` 从后续现存段开始计数。

#### [G2] [一般] 记录「不可读」时静默标记已决，消息丢失且无任何日志

- **位置**：`fmq/src/queue/GroupCursor.cj:143-147`
- **现象**：重投路径上 `readAt(entry.position)` 返回 `None`（例如段内偏移越界/记录被截断）时，直接把 `entry.decided = true` 并 `continue`，注释写着「记录已不可读（段被清理）：标记已决，避免阻塞」。没有 `WARN`、没有指标、也没有记录位置。
- **影响**：与规格「不得静默丢消息」的总体取向冲突；一旦发生（损坏段、TTL 与位点竞态），该消息对该组永久消失且事后无法定位（不知道丢了哪条、哪一段）。同一函数在 `:407,415` 的段缺失场景是有 `logger.warn` 的，这里不一致。
- **建议**：至少 `logger.warn("unreadable record ...")` 并累加一个 `unreadable` 指标；更稳妥的做法是把它当「损坏」处理（进死信或直接抛错让上游记录），而不是静默丢弃。

#### [G3] [一般] `next` 的读流异常恢复分支自相矛盾：全段缺失时开流返回 `None`、读中却 `throw`

- **位置**：`fmq/src/queue/GroupCursor.cj:188-198`（开流失败：`recoverIfSegmentGone` 为真但 `segmentsOrEmpty().size == 0` → `return None`）对比 `:199-207`（读中失败：同样条件 → `throw e`）
- **现象**：两个分支对「所有段都没了」给出相反结果：一个当作空队列，一个把原始异常抛给调用方（`ConsumeService` → `MQCommandExecutor` → 客户端 `INTERNAL`）。
- **影响**：主题目录被外部清理/磁盘异常时，同一状态在「首次打开」和「读到一半」表现不同，客户端会间歇收到 `INTERNAL`；`allSegmentsMissingReturnsNone`（`GroupCursor_test.cj:445-458`）只覆盖了开流分支，读中分支零覆盖。
- **建议**：统一为「无可读段 → `WARN` + 返回 `None`」；`recoverIfSegmentGone` 返回的三态（已恢复/段仍在/无段可读）显式表达，而不是靠 `|| size()==0` 二次判断。

#### [G4] [一般] `ack` 不校验「是否真的投递过」，可确认一个尚未取走的分配项

- **位置**：`fmq/src/queue/GroupCursor.cj:290-310`（循环里只判断 `decided`、位置相等、`owner` 归属，不判断 `entry.delivered`）
- **现象**：组内 s2 的分配项（`owner = s2, delivered = false`，扫描时为其它订阅创建，见 `:270`）在 s2 从未 `CONSUME` 到它的情况下，只要 s2 发出 `ACK(position)` 就会被接受并推进 `committed`。
- **影响**：与 `详细设计.md:687-691` 的 ack 口径（「已投递给它」才拒绝他人；言下之意未投递的位置不应被确认）和 `consume-semantics/spec.md:116-134` 的「只接受属于本游标且属于该订阅的位置」存在偏差；客户端一旦复用/重放旧 `ACK`，会推进一个尚未投递的位置，导致消息对该组静默消失（at-least-once 退化为 at-most-once）。用例 `ackChecksOwnership`、`recordAssignedToOtherSubscriber` 都只覆盖「他人已取走」的情形。
- **建议**：`ack` 增加 `entry.delivered == true` 判定（或明确规格允许「预确认」并在文档里写清）；补用例：记录被分配给 s2 但 s2 未取走时 `ack` 返回 `false`。

#### [G5] [一般] 游标落盘没有 fsync，「重启后能读回最后一次写入的值」在掉电场景下不成立

- **位置**：`fmq/src/queue/CursorStore.cj:84-93`（`File.create(tmp)` → `write` → 直接 `rename`，无 `flush`/`fsync`，也不 fsync 父目录）
- **现象**：`write` 只到页缓存，`rename` 是原子替换但内容可能尚未落盘；掉电后 `.cursor` 可能是 0 字节/半条记录（`load` 此时返回 `None`，位点回到 `(1,0)`，整主题重投）或回退到上一个值。
- **影响**：`queue-storage/spec.md:93-113` 明确要求「重启后 SHALL 能读回最后一次写入的值」。每次 `advance` 都写盘（`GroupCursor.cj:382-384`）说明设计取向是「消息不丢优先」，但没有 fsync 使这个保证只对进程崩溃成立、对机器掉电不成立；`CursorStore_test` 的 `saveAndLoadRoundtrip`/`overwriteHasNoTmpResidue` 只能验证进程内语义。
- **建议**：`write` 后 `file.flush()`（必要时 `fsync` 文件与父目录）再 `rename`；或在文档中把该条降级为「进程崩溃安全、掉电可能回退一个位点（可重投）」。前者更符合规格原文。

#### [G6] [一般] `QueueManager.openTopic` 是「先查后插」的非原子操作，并发下会泄漏 `QueueLog` 并多开一个段

- **位置**：`fmq/src/queue/QueueManager.cj:65-77`（`if (topics.contains(topic)) return` … `topics.add(...)`）
- **现象**：两个线程同时进入时都可能通过 `contains` 检查，各自为同一批队列构造 `QueueLog`（构造 `SegmentedLog` 会**立即建一个新段文件**，`f_io/src/SegmentedLog.cj:131-152`），随后 `topics.add` 对已存在的 key 失败抛异常，先建的那批 `QueueLog` 既没被登记也没被关闭（mmap 与 fd 泄漏 + 目录里多一个空段）。
- **影响**：`详细设计.md:325-344` 与用例 `QueueManager_test.cj:50-52` 都只描述「重复调用为空操作」，没有覆盖并发；当前注册路径经 `MetaStore.applyTopic` 的互斥大多能挡住重复注册，但这属于「靠上游巧合」，且 `openTopic` 中途抛错（如磁盘错误）时同样会留下未关闭的日志对象。
- **建议**：用 `ConcurrentHashMap.addIfAbsent` 式语义（先构造到局部变量，`add` 成功再登记；失败则关闭新建的 `QueueLog` 并复用已有集合），或加一把主题级互斥；`openTopic` 内部对 `QueueLog` 构造加 try/finally 回滚已建项。

#### [G7] [一般] `详细设计.md` 的队列章节与实现多点不一致，其中「投递后 `target = None`」与 ack 归属校验直接矛盾

- **位置**：`fmq/doc/详细设计.md:664`（`entries: TreeMap<(index,offset), DeliveryRecord>`，实现为 `ArrayList`，`GroupCursor.cj:57`）、`:673`（「命中：`deliverCount++`、`lastDeliverTime = now`、`target = None`、`delivered = true`」，实现保留 `owner = 订阅 id`，`GroupCursor.cj:160-163`）、`:372`（`sweep(now: DateTime, matcher: MQMatcher)`，实现为 `sweep(activeSubscriptions: Array<String>)`，`GroupCursor.cj:333`）、`:366`（`next(subscription, matcher)` 两参，实现三参 `next(subscription, groupMembers, matcher)`，`GroupCursor.cj:110-111`）、`:350-355`（`DeliveryRecord` 缺 `next`/`decided` 两个实际存在的字段）、`:753`（线程模型列出「`GroupCursor.sweep` Timer」，实现**没有任何 sweep 定时器**，`sweep` 只在 `ConsumeService.cj:75` 每次消费前被调用）
- **影响**：`:673` 的 `target = None` 若照做，`ack` 的「owner 是别人则拒绝」（`:690`，`GroupCursor.cj:296-300`）就失去依据，实现与文档必须有一个是错的——当前是实现对、文档错。`:753` 的定时器缺失会让读者以为「断链订阅的分配项有兜底定时清理」，实际只在同组有人消费时才清理（见 G9）。`entries` 结构漂移掩盖了 A1 的性能问题。签名漂移会让按文档写的调用方直接编译失败。
- **建议**：按实现回写 §5.10/§5.11/§6.5/§6.9：`entries` 为按位置有序的 `ArrayList`、投递后保留 `owner`、`sweep(activeSubscriptions)`、`next` 三参、补 `next`/`decided` 字段，并二选一——要么补上 sweep 定时器（`Timer.repeat(min(ackTimeout,1s))`），要么删掉线程模型里那一行并写明「sweep 由消费请求驱动」。

#### [G8] [一般] `ackTimeout` 没有正数校验，配成 0/负数时同一位置会被无限重投并饿死后续消息

- **位置**：`fmq/src/config/MQConfig.cj:68-72`（`getDuration(...) ?? DEFAULT`，`validate()` 只校验 `deadMsgThreshold`，见 `:249-251`）、判定点在 `fmq/src/queue/GroupCursor.cj:130`（`current - entry.lastDeliverTime >= ackTimeout`）
- **现象**：`ackTimeout <= 0` 时，刚投递出的未决项在下一次 `next` 立刻满足「已超时」，队首位置会被连续重投（`deliverCount` 很快越过阈值 → 直接进死信），后续消息长期得不到调度。
- **影响**：配置层没有任何拦截，属于「一个合法写法的配置项把队列打成重复投递风暴」；`MQConfig.validate` 对其它几项（`deadMsgThreshold`、`delayingMs`、`backup`）都有显式校验，此处遗漏。
- **建议**：`validate()` 增加 `ackTimeout > Duration.Zero` 校验并给出可读错误；`GroupCursor` 侧可加一条防御性 `max(ackTimeout, 1ms)`。补一条配置校验用例。

#### [G9] [一般] 传给 `sweep` 的「活跃订阅」包含已断链订阅，断链名下的分配项要等巡检周期才可能被退回

- **位置**：`fmq/src/server/ConsumeService.cj:71-75`（`active = subscribers.activeIds(...)` 后立刻 `cursor.sweep(active)`）、`fmq/src/server/SubscriberRegistry.cj:159-171`（`activeIds` 只返回 `byGroup` 里的 id，**不判断** `isDisconnected()`；对比 `MQServer.cj:157-166` 的巡检会先 `isDisconnected()` 才注销）
- **现象**：连接断开后、`cleanupSubscribers` 巡检（`CLEANUP_INTERVAL`）运行前，`sweep` 认为断链订阅仍然「活跃」，因此不会把它名下的 `owner` 复位。这段时间里同组其它订阅者拿不到这些记录。
- **影响**：`consume-semantics/spec.md:151-164`「连接断开时其名下已分配未确认的记录 SHALL 退回组内」在时间上被延迟到一个巡检周期；叠加「组内只剩断链订阅」时该组会整体空转。`sweepReleasesInactiveOwner`（`GroupCursor_test.cj:343-362`）用手工构造的 id 数组覆盖了 `sweep` 本身，但没有任何用例覆盖「`activeIds` 真实包含断链订阅」这一上游缺陷。
- **建议**：`activeIds` 过滤掉 `isDisconnected()`（或新增 `liveIds` 专供 sweep）；把「断链 → 立即 sweep」接到 `removeByBuffer` 上，而不是只靠定时巡检。

#### [G10] [一般] 规格场景与关键分支缺用例（含「测试无法发现 S1/S2/S3」的证据）

- **位置**：`fmq/src/queue/*_test.cj`（共 54 条，逐条核对 `queue-storage` / `consume-semantics` 的 Scenario 后）
- **现象**：以下场景无对应用例：

  | 缺失场景 | 规格出处 | 现状 |
  |---|---|---|
  | 被真实游标引用则保留段 | `queue-storage/spec.md:160-163` | 仅 `LogCleaner_test.cj:88` 用假回调，S1 因此漏网 |
  | 长度头损坏/越界 | `fix-…/queue-storage/spec.md:21-24`、`详细设计.md:321-323` | 零覆盖，S2 因此漏网 |
  | `Unsupported` BODY 在消费侧的行为 | `consume-semantics/spec.md:32-35` | 零覆盖，S3 因此漏网 |
  | 跨组各自消费（A 组已消费，B 组仍可取） | `consume-semantics/spec.md:47-50` | 零覆盖（`ConsumeService_test` 也没有） |
  | 组内无人在线时 `committed` 不前进 | `consume-semantics/spec.md:146-149` | `GroupCursor.cj:113` 的 `groupMembers.size == 0` 分支无用例 |
  | 从中间记录位置开流 | `queue-storage/spec.md:55-58` | 只测了「从首条」「从段中间字节」两种 |
  | `scanAfter` / `countAll` / `segmentsOrEmpty` | 设计 §6.11 | `QueueLog_test` 零覆盖，G1 因此漏网 |
  | `MAX_RECORD_SIZE` 拒绝 | `详细设计.md:317` | 零覆盖（`QueueLog.cj:42-44` 分支） |
  | 死信损坏尾/`deadMsgTTL` 边界（`== ttl`） | `queue-storage/spec.md:170-173` | 零覆盖；`DeadLetterReader` 的「遇损坏即结束」（`DeadLetterQueue.cj:92-98`）无用例 |
  | `openTopic` 关闭后重新打开保留消息 | `queue-storage/spec.md:35-48` | `QueueManager_test` 零覆盖（只有 `closeTopic` 后目录存在性） |
  | topic/tags 解码失败 → `NoMatch` | `MQMatcher.cj:93-103` | 零覆盖（只测了 BODY 截断） |
  | 并发的 `committed` 单调性 | `consume-semantics/spec.md:186-189` | `concurrentNextAndAckProduceUniquePositions` 只断言 `seen.size == 200`，未断言 `committed` 单调不减、也未断言最终等于日志末尾 |

- **影响**：三个严重问题全部落在「用例盲区」里，说明当前用例是「按实现写」而不是「按规格写」：`GroupCursor_test` 22 条主要覆盖 happy path + 超时/死信/延迟，异常与规格边界几乎全是空白。
- **建议**：按上表逐条补齐，优先补前三条（S1/S2/S3 的回归锚点）与「跨组隔离」「无人在线暂停」两条规格 Scenario。

#### [G11] [一般] `consume-semantics` 规格自相矛盾，「组内无匹配」到底越过还是保留没有唯一解释，用例固化了其中一种

- **位置**：`fmq/doc/spec/add-fmq-message-queue/specs/fmq/consume-semantics/spec.md:136-149`（Requirement 正文：「若某条记录对组内任何活跃订阅都不匹配…游标 SHALL 保留该位置为未决，**不得跳过推进**（保证消息不丢）」；同一 Requirement 的 Scenario「组内无匹配」：「该位置被标记为『不适用』并**允许越过**」）、实现 `fmq/src/queue/GroupCursor.cj:277-280`、用例 `GroupCursor_test.cj:288-303`
- **现象**：正文与 Scenario 给出相反要求；实现按 Scenario 执行（建 `decided = true` 的项并推进 `committed`），用例 `unmatchedRecordIsSkippedAndCommitted` 还把这一行为固定了下来。
- **影响**：文档层面无法拿来判定「消息该不该保留」；如果按正文实现，则「组内订阅 tags 永远不匹配某条消息」会让该组永久停摆（没有出口）；如果按 Scenario，则后加入组的匹配订阅永远看不到此前被越过的消息。两种语义都有代价，必须由规格拍板，否则后续任何改动都会被判「违反规格」。
- **建议**：把 Requirement 正文改成与 Scenario 一致（推荐：明确「不匹配即越过，不进入死信」并说明「新增订阅不回溯历史」），或新增 `unmatchedDeadLetter` 之类的出口；同时补一条「后加入订阅」的用例把语义钉死。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 3 |
| 一般 | 11 |
| 建议 | 11 |

建议级明细（不改变结论，仅列位置与要点）：

1. `GroupCursor.cj:57,119-180,375-385`：`entries` 用 `ArrayList` 做「按位置有序」集合，重投路径对每条 `next` 全表线性扫描，`advance()` 又用 `entries.remove(at: 0)`（O(n) 搬移），在飞窗口大时是 O(n²)；设计 §5.11 原本写的是 `TreeMap`。建议改 `TreeMap<(seq,offset), DeliveryRecord>` 或 `ArrayDeque` + 头部游标。
2. `QueueLog.cj:244-254`：`readExact` 每轮 `read` 都新分配 `tmp` 并逐字节拷贝到 `out`（`for (i in 0..n)`），大记录/N 段时拷贝量可观；可改为 `stream.read(out[got..got + want])`（`Array` 切片是引用，`f_io` 里已有同样写法，见 `SegmentedLog.cj:638`）。
3. `MQMatcher.cj:76-78`：`topicOf(record)` 无任何调用方，是死代码；`matches` 内部直接调 `MQMessageRecord.topic`，建议删除或改为复用。
4. `CursorStore.cj:46-67`：`load` 读到损坏文件（长度不足/解码失败）静默返回 `None`，调用方（`GroupCursor.cj:76-79`）会退回 `(1,0)` 造成整主题重投且无任何日志；建议 `WARN` 并带上文件路径。
5. `QueueLog.cj:202-210,255-258`：`length <= 0`、读到一半截断（记录损坏）都没有日志，线上无法判断「队列空了」还是「段坏了」；建议与 S2 一起补 `WARN`。
6. `QueueLog.cj:41-49`：`append` 不拒绝空记录，写入的 4 字节头为 0，读端 `QueueLog.cj:202-205` 会把它当损坏并在该处**永久停止**，这条记录之后的所有消息都不可读；建议 `if (record.size == 0) throw IllegalArgumentException`（与 `详细设计.md:317`「length 取值 1..64MiB」一致）。
7. `QueueManager.cj:192-207`：`close()` 只收集 `items.size > 0` 的主题来移除，`items` 为空的 `TopicQueueSet` 永远留在 `topics` 里；关闭后 `queueNumOf/delayingOf` 仍能返回值，与 `closeTopic` 的行为不一致。建议关闭时移除全部 key。
8. `LogCleaner.cj:54`：用 `queue.segments()`（目录不可读时抛异常，`QueueLog.cj:79-81`）而不是 `segmentsOrEmpty()`；主题目录被删（`closeTopic(deleteFiles: true)` 与清理器并发，属 backlog P2 已承认的窗口）会让整轮清理中断，后续队列都清理不到。建议改用 `segmentsOrEmpty()` 并跳过空清单。
9. `QueueLog_test.cj:233-247`：用例名 `everyAppendIsImmediatelyReadable`（目录名 `fsync`）暗示验证每写必落盘，实际只验证「写完能读回」，`syncInterval = 1` 的落盘语义没有任何断言（也无法在单进程内断言），建议改名或注明。
10. `QueueLog_test.cj:250-270`：`truncatedEntryIsRejected` 把「返回 `None`」和「抛异常」都算通过，而规格 `fix-…/queue-storage/spec.md:21-24` 与 `详细设计.md:321-323` 对「损坏」只有一种期望；断言过宽，无法保护 S2 的修复。
11. `GroupCursor_test.cj:256-260`：死信断言只查 `segmentedIndex >= 1`、`subscribeGroup`、`deliverCount`，未校验 `record` 原文、`topic`、`queueIndex`、`deadTime`、`segmentedOffset`，与 `consume-semantics/spec.md:102-105`「死信条目内容完整」不匹配；另外 `ConsumeService.cj:72-81` 每次 `consume` 对所有本地队列都先跑一遍 `sweep`（全表扫描 + 可能落盘），在飞量增长后是固定开销，建议只对该组「有 owner 失效嫌疑」时再扫。

附：队列相关的已归档遗留项（`fmq/doc/backlog.md` #8「无死信读取/重放接口」、P2「删除主题与在途消费并发」）本轮不重复计为问题。

### 总评

队列层是本模块的骨架，整体质量在「正常路径」上是扎实的：`QueueLog` 严格把定界职责交给 f_io、只加 4 字节长度前缀，且把「记录不跨段 / 位置单调 / 快照读」三条硬约束都落在实现与用例上；`GroupCursor` 的连续前缀推进、乱序 ack 留洞、按组分配、超时重投、阈值死信、autoAck、延迟队首阻塞这些核心算法与 `详细设计.md` §6.5 的思路一致，22 条用例把主要分支都走了一遍（含 4 线程并发唯一性、段被删后的恢复、延迟跨重启），54 条用例**没有空用例、没有 `@Assert(true)` 占位、没有空函数体**，`CursorStore`/`DeadLetterQueue`/`MQMatcher` 的职责边界也很干净。

问题集中在**「异常/生命周期的边界」与「可观测性」**两条线上，其中三条严重问题都不是「少写一个 if」，而是「测试与规格对不上，导致错误行为被当成正确行为固化」：

- S1（TTL 清理只认内存游标）把「至少一次」在慢组场景下变成「静默丢一批」，而且被清理器、游标恢复、stats 三处叠加掩盖；
- S2（长度头无上界）在损坏段上会直接打崩进程，与文档承诺的「损坏即停止」相反；
- S3（`Unsupported` 永久停摆）会把整组消费卡死且不给任何信号，且发布侧的前置检查只覆盖「发布时刻的订阅」，正常时序就能触发。

一般级问题里，G1/G2/G4 同属「静默降级」——把异常吞成「没有消息」「已决」「已确认」，短期看是「不阻塞」，长期看是把故障变成不可诊断的数据偏差；G5/G6/G8/G9 是持久化与并发的边界缺口；G7/G11 是文档必须先拍板的分歧（尤其文档 §673「投递后 target=None」是明确的错误描述，会误导后续维护者改坏 ack 归属校验）。

建议的修复顺序：S1 → S2 → S3 → G4/G1/G2（正确性与可观测性）→ G5/G6/G8/G9（可靠性边界）→ G10 补用例（前三条严重问题各自带一条回归锚点）→ G7/G11 文档回写 → 建议级。完成 S1–S3 与 G10 前三行后，本层可认为「与规格一致、可上线」。
