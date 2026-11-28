# fmq 模块审查报告（模块第 5/7 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fmq`（本部分 17 个源文件：9 个实现文件 + 8 个 `*_test.cj`，无 `.md`）
- **基线**：工作区快照（源码与 `120fd2542` 一致，`git diff` 为空；本报告 HEAD 为 `f309f0b55`，只多了 docs 提交）⇒ 所有问题记「存量」
- **审查重点**：投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `fmq_v2.md`；本文件不写 `docs/review/`）

## 发现

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

## 可见性建议（不算死代码、不计入统计）

以下 `protected` 成员在本仓只被 `*_test.cj` 引用，按硬原则一不属于死代码；若确认无下游依赖，可考虑收窄或下沉为测试辅助：

- `MQMetrics.size`（`MQMetrics.cj:90`，仅 `MQMetrics_test.cj`、`ConsumeService_test.cj:536`）
- `DeadLetterQueue.iterate` / `DeadLetterQueue.sync`（`DeadLetterQueue.cj:47`、`66`，仅 `DeadLetterQueue_test.cj`、`GroupCursor_test.cj`）
- `QueueLog.scanAfter` / `QueueLog.sync` / `QueueLog.size`（`QueueLog.cj:236`、`302`、`292`，仅 `QueueLog_test.cj`、`ConsumeService_test.cj:392`）
- `GroupCursor.committed` / `pendingCount` / `unreadableSkipped` / `noMatchSkipped` / `unsupportedSkipped`（`GroupCursor.cj:92`、`98`、`343`、`352`、`361`，生产代码零引用）

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 锁内 fsync 是消费延迟主因（单条 ack 中位延迟被 fsync 主导） | `GroupCursor.cj:409`、`482-484`、`CursorStore.cj:89` | 单次 fsync 耗时、锁等待时长、端到端 P99 | `cjprof record` 跑「单队列 10 万条 + 逐条 ack」；同时用线程状态采样看 WAITING/BLOCKED 占比 |
| 2 | 扫描大积压时 `entries` 峰值内存随积压线性增长 | `GroupCursor.cj:57`、`266-336` | 峰值 heapUsed / 对象数 | 埋点 `getAllocatedHeapSize()` + 100 万条、队首故意不 ack，跑一轮后读峰值 |
| 3 | 每记录 2 次小数组分配造成的 GC 压力可观测 | `QueueLog.cj:452-474` | GC 次数、分配速率 | `cjprof heap` 跑 10 万条 4 KB 记录 |
| 4 | `sweep` 每次 consume 全量扫未决项在 E 较大时成为串行段 | `GroupCursor.cj:440-455` + `ConsumeService.cj:87` | E 的实际分布、单次 sweep 耗时 | 加计数埋点统计 `entries.size` 分位与单次 sweep 耗时，跑 10 分钟稳态负载 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fmq/src/meta/MetaStore_test.cj` | .cj | ✅ | MetaStore 用例（墓碑/revision/并发注册）；`concurrentRegisterTopicOnlyOneWins` 多线程写 `results[i]` 依赖 `AtomicInt64` 栅栏，未发现用例缺陷 |
| 2 | `fmq/src/metrics/MQMetrics.cj` | .cj | ✅ | 见发现 #11；并发自增/删除设计正确（`entryView` 单键原子） |
| 3 | `fmq/src/metrics/MQMetrics_test.cj` | .cj | ✅ | 覆盖「删主题/组清计数」与并发 bump/remove，与实现一致 |
| 4 | `fmq/src/queue/CursorCatalog.cj` | .cj | ✅ | 缓存只前进、IO 在锁外，正确；`save` 无条件覆盖缓存属预期（见发现 #1 落盘链） |
| 5 | `fmq/src/queue/CursorCatalog_test.cj` | .cj | ✅ | 覆盖离线组位点/最小段号/损坏按缺失 |
| 6 | `fmq/src/queue/CursorStore.cj` | .cj | ✅ | 见发现 #9、#10；`.tmp + rename` 语义与用例一致 |
| 7 | `fmq/src/queue/CursorStore_test.cj` | .cj | ✅ | 1000 次覆盖写无 tmp 残留，等于把「每写一次一个文件」的代价固化进用例 |
| 8 | `fmq/src/queue/DeadLetterQueue.cj` | .cj | ✅ | 见发现 #6；`cleanExpired` 跳过 `last` 段，正确 |
| 9 | `fmq/src/queue/DeadLetterQueue_test.cj` | .cj | ✅ | 覆盖逐条读回、段轮转、TTL、重开；未覆盖「尾部截断」→ 发现 #6 无用例 |
| 10 | `fmq/src/queue/DeliveryRecord.cj` | .cj | ✅ | 纯数据类，字段与 `GroupCursor` 状态机一致 |
| 11 | `fmq/src/queue/GroupCursor.cj` | .cj | ✅ | 见发现 #1-#5、#12；投递/ack/重投/死信语义整体正确 |
| 12 | `fmq/src/queue/GroupCursor_test.cj` | .cj | ✅ | 38 个用例覆盖损坏/乱序 ack/超时/死信/延迟/段空洞；缺「未决窗口内存」与「段空洞 + 未决项」两个场景 |
| 13 | `fmq/src/queue/LogCapture_test.cj` | .cj | ✅ | 测试专用 appender，`flush()` 空实现是 `OutputStream` 合理 no-op |
| 14 | `fmq/src/queue/MQMatcher.cj` | .cj | ✅ | 三态匹配正确（`Unsupported` 不误判为 `NoMatch`）；见发现 #13 |
| 15 | `fmq/src/queue/MQMatcher_test.cj` | .cj | ✅ | 覆盖 topic 精确相等、tags 子集、filter 求值、BODY 不可解 |
| 16 | `fmq/src/queue/QueueExceptions.cj` | .cj | ✅ | `QueueCorruptionException` 对外可达，`Resource` 语义与 stats 映射一致 |
| 17 | `fmq/src/queue/QueueLog.cj` | .cj | ✅ | 见发现 #3、#5、#7、#8、#13、#14 |

合计：`.cj` 17 个 / `.md` 0 个 / 共 17 个，全部读完（本部分清单无 `.md`，README 与 `doc/**` 由含 README 的部分覆盖）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 4 |

存量缺陷：14 条（本部分全部为存量；快照模式无基线）。是否纳入修复待用户决定。

## 总评

这一部分是 fmq 的「消费位点 + 段读取 + 死信 + 指标」核心，语义严谨度明显高于平均水平：投递/确认状态机（`DeliveryRecord` + `committed` 只增、乱序 ack 留洞、`autoAck` 计入 acked、阈值 N+1 次投递）在 22 个用例下自洽；段缺失/损坏/空洞三种恢复路径都有专门用例；`CursorCatalog` 用「全部已注册组的最小位点」做段保留边界，避开了「按内存游标删段会删掉慢组积压」的经典坑；并发状态全部走单把 `Mutex`，锁顺序单一，未见死锁与可见性缺口。

真正的风险集中在两处，都不是语义错误而是**放大量级**：

1. **位点落盘频率与锁粒度**（#1）。每条 ack、每条被越过的记录都要 `create + fsync + rename + dir fsync`，且都在游标锁内。功能正确，但一旦出现「组内大量不匹配消息」或「慢消费者」，消费请求会以 fsync 为节拍器，P99 直接塌陷；这也是本部分唯一建议优先排期的项（先补 `cjprof`/`strace` 数据再改）。
2. **未决集合无上限**（#2）。队首一旦卡住，后续整段积压会被物化成 `DeliveryRecord` 常驻内存。同样是「正确但无界」，需要先量化再定上限。

其余 4 条一般项都是**异常/运维路径上的一致性缺口**：段读取异常被折成「损坏」（#3）、段空洞恢复丢可读未决项（#4）、`readAt(resume:false)` 契约只实现了一半（#5）、死信读取把损坏当结束（#6）。它们只在段被删/被截断、或死信文件损坏时触发，正常路径不受影响，属于「排期修」而不是「阻塞发布」；但 #3 的误导性 ERROR 日志会直接把排障带偏，建议连同日志文案一起修。

死代码与重复逻辑各 3 条，量级很小（两个无引用符号、一个恒假分支、三处同构代码），说明这个包在被持续清理过（仓库自带的 postfix 审计文档还留了几条未落实的清理项）。总体判断：**无阻塞项；建议按「#1 补数据→批量化、#2 定上限、#3-#6 修正异常分类」三批推进。**
