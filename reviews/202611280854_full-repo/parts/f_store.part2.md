# f_store 模块审查报告

> **模块第 2/4 部分**（本报告只覆盖 `files/f_store.part2.txt` 列出的 17 个文件：16 个 `.cj` + `doc/架构设计方案.md`。`README.md` / `README_en.md` / `doc/审查报告.md` / `doc/开发计划.md` 与其余 21 个 `.cj` 由第 1、3、4 部分产出；本部分编号独立，合并时以主 Agent 为准。README 仅作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_store`（本部分 16 个 `.cj` + 1 个 `.md`；模块共 37 `.cj` + 5 `.md`）
- **基线**：工作区快照（`HEAD` 为 `4be871f2f` 之后无源码改动，`git status --porcelain f_store` 为空 ⇒ 本部分所有问题记「存量」，无基线可比）
- **审查重点**：存储后端正确性（LSM 层间语义 / tombstone / 过期）、持久化与一致性、资源生命周期、并发安全、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 2/4 部分）

## 发现

### [严重][存量] #1 `LevelManager.get` 把"命中的 tombstone / 过期条目"当成"未找到"，已删除或已过期的 key 会从更低层复活

- **位置**：`f_store/src/LevelManager.cj:80-92`（`get` 只用 `result.isSome()` 判命中）、`95-138`（`getInLevel` 在 `113` / `131` 直接 `return checkExpiry(e, now)`）、`141-153`（`checkExpiry` 对 tombstone / 过期返回 `None`）
- **来源**：存量（`git blame -L 80,153 -- f_store/src/LevelManager.cj` 命中 `4be871f2f 2026-10-02`；快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」「语义与注释不符」；契约源 `f_store/doc/架构设计方案.md:731`「找到 tombstone（`entry.value == None`）立即返回 `None`，**不需要继续查找更底层**」，`:732`「找到过期数据立即返回 `None`」
- **证据**：静态确定 —— `checkExpiry` 返回的 `None` 与"本层没有这个 key"的 `None` 在 `get` 里无法区分：`85-90` 的 `if (result.isSome()) return result` 在拿到 tombstone 时 `result` 是 `None`，循环继续到下一层，下一层的老值被当成答案返回。同一路径对过期条目等价：L0 里 `expireAt <= now` 的版本被吞掉，L1 里没有 TTL 的老版本被返回。
- **描述**：触发路径是 LSM 的常规生命周期，不需要并发、不需要异常：
  1. `add(K, v)` → flush 成 L0 文件 A → compaction 下沉到 L1；
  2. `remove(K)` → memtable tombstone → flush 成 L0 文件 B；
  3. `get(K)`：active / immutable 都没有 → `getInLevel(0)` 命中 B 的 tombstone → `checkExpiry` 返回 `None` → `get` 继续查 L1 → 返回 A 里的老值 → **已删除的 key 复活**。

  L0 内部还有一层放大：`getInLevel` 的 L0 分支一旦在某个文件里命中 tombstone 就直接返回 `None`（`113-115`），既不再看更老的 L0 文件（这是对的），也不再区分"命中即终止"与"没命中"，于是整个 L0 的删除标记对 L1 完全失效。非最底层 compaction 会保留 tombstone（`Compaction_test.cj:188-214` 断言了这一点），所以 tombstone 会长期存在于 L1/L2…，同样会被 L2 的老值穿透。
  同一缺陷还影响 `ttl`：`Store.lookupEntry`（`Store.cj:345`）走同一条 `levelManager.get`，于是对"已删除但下层还有老值"的 key 调 `ttl` 会把老值当成当前值重新写回一个带新 TTL 的版本（`Store.cj:312-320`），把删除操作彻底撤销。
  现有用例没有覆盖：`LevelManager_test.cj` 的 20 个用例都不存在"同 key 跨层 tombstone/过期"，`Compaction_test.cj:539-594` 只覆盖"同一轮 compaction 内 tombstone 覆盖 L1"，覆盖不到"跨层且未合并"的状态。
- **建议**：把"层间终止判定"和"过期/删除判定"拆开。`LevelManager.get` 应返回原始 `EntryValue`（含 tombstone 与已过期条目），只要本层命中就返回 `Some` 并终止；`Store.get` / `contains` / `lookupEntry` 用现有的 `checkExpiryAndGet` / `entryIsAlive` 做最终判定（`Store.cj:349-374` 已经具备，属于重复实现，顺带收口，见 #12）。若不想改返回类型，至少给 `checkExpiry` 增加 `hit: Bool` 出参或返回 `(Bool, ?EntryValue)`。补三条用例：跨层 tombstone、跨层过期、`ttl` 不复活已删除 key。

### [严重][存量] #2 L0 compaction 只下沉"最新 4 个"，留在 L0 的老文件会遮蔽 L1 的新值（读到旧值 / 删除再次失效）

- **位置**：`f_store/src/Compaction.cj:100-107`（`pickCount` 取末尾 4 个）、`176-186`（新表进 L1 → 从 L0 移除所选 → 关闭删除）
- **来源**：存量（`git blame -L 100,107 -- f_store/src/Compaction.cj`：`4be871f2f`；注释 `P2-2 修复` 说明是后来改的选取策略）
- **判据**：review-checklist §11「逻辑错误 / 数据错误」；LSM 层序不变量：L0 的每个文件必须整体比 L1 的任何文件新，否则"先查 L0 再查 L1"的读路径失效
- **证据**：静态确定 —— `levelManager.addSSTable` 只做追加（`LevelManager.cj:156-172`），`getInLevel` 的 L0 分支从末尾往头遍历（`LevelManager.cj:98-118`），即"L0 列表 = 写入顺序，末尾最新"。`compact(0)` 却从**末尾**取 4 个（`104-107`）下沉到 L1，剩下的是**更老**的文件继续留在 L0，而读取时它们仍然先被检查。于是：
  - 老 L0 文件里的 `K=v_old` 遮蔽 L1 里的 `K=v_new` ⇒ 覆盖写回退；
  - 老 L0 文件里的值遮蔽 L1 里的 tombstone ⇒ 删除失效（与 #1 独立的第二条删除失效路径）；
  - 顺序只在 `L0 文件数 == 4` 时恰好正确；`shouldCompact(0)` 的门限是 `count >= 4`（`LevelManager.cj:268-270`），实际写入突发时 `count` 可以到 5、6、10。

  用例 `Compaction_test.cj:599-639`（`compactorL0SelectsAtMostFour`）确实构造了 6 个 L0 文件并断言"剩 2 个"，但 6 个文件的 key 是**互不重叠**的 `0x01..0x06`，所以遮蔽不会发生；测试通过不代表语义正确。
- **描述**：这是 Leveled-LSM 的标准约束——L0 的挑选必须满足"被下沉的文件比留在 L0 的文件更老"，或者一次性把 L0 全部重叠文件一起下沉。当前实现两条都不满足，是稳定性缺陷而不是性能问题：只要热点 key 反复覆盖写、flush 频率高于 compaction 速度，`get` 就会返回历史值，`remove` 之后的老值会重新出现在 `get` / `prefix` 里。
- **建议**：`level == 0` 时改为从**头部**取最早的若干文件（`for (i in 0..pickCount)`），或按 LevelDB 的做法：先选 L0 中与 L1 目标范围重叠的**全部**文件作为一次 compaction 单元，保证"下沉集合"在 L0 里是连续的老段；同时把 `pickCount` 与 `shouldCompact` 的门限提到同一个常量（见 #14 重复字面量）。补用例：6 个 L0 文件、key 全部为 `0x01`、sequence 递增，`compact(0)` 后 `get` 必须返回最高 sequence 的值；再补一条 tombstone 版本。

### [一般][存量] #3 `removeSSTables` 对"不在列表里"的 SSTable 也扣减缓存，`levelSizes` / `totalSSTableCount` 可漂移甚至为负

- **位置**：`f_store/src/LevelManager.cj:193-199`（CAS 成功后 `for (rm in toRemove)` 无条件 `fetchAdd(-fileSize)` / `decrFetch()`），`182-192`（`newList` 只保留匹配不到的项）
- **来源**：存量（`git blame -L 175,202`：`4be871f2f`；用例 `LevelManager_test.cj:163-168` 与实现同源）
- **判据**：review-checklist §11「错误处理 / 计数不对称」、§12.1「并发正确性：复合状态非原子更新」
- **证据**：静态确定 —— 扣减循环遍历的是**入参** `toRemove`，与"实际从 `oldList` 里删掉了几个"无关。两条路径都会走偏：
  1. 入参含不存在的 SSTable：`LevelManager_test.cj:163-168` 就是这么调的（`fakeSst` 从未 `addSSTable`），CAS 成功后会扣掉 `fakeSst` 的 `fileSize` 并 `decrFetch`，计数器立即错误——用例本身只断言"列表长度仍为 2"，没有断言计数器，所以缺陷被放过去了；
  2. 两个线程先后删除同一个 SSTable：A 删成功后 B 的 CAS 因列表已变而重试，重试时 `newList` 与 `oldList` 内容相同但对象不同（`AtomicReference` 按引用比较），CAS 仍然成功，于是同一文件被扣两次。
- **描述**：后果分两级。(a) `levelSizes` 变负或偏小 ⇒ `shouldCompact(level)`（`262-275`）永远返回 `false`，该层再也不会触发 compaction，写放大与 L0 堆积长期恶化；(b) `totalSSTableCount` 偏小到 0 时，`get` 的短路 `if (totalSSTableCount.load() == 0) return None`（`82-84`）会把"层里其实有文件"的查询直接变成 `None`，即**读到不存在的 key**。第二级是否可稳定复现取决于漂移量，但 (a) 已经是确定性缺陷。
- **建议**：扣减只统计"确实被移除的"：在构建 `newList` 时记录 `removed` 列表（`if (shouldKeep) newList.add(sst) else removed.add(sst)`），CAS 成功后只对 `removed` 扣减；或者干脆用 `levels[level]` 的新旧列表差集来更新缓存，保证"列表内容"与"计数器"是同一个原子对象的派生量。补两条断言：`removeSSTables` 传入不存在的文件后 `shouldCompact` 与 `levelSizes` 不变；重复删除同一文件两次后计数只减一次。

### [一般][存量] #4 compaction 后台线程一旦抛异常就永久停摆，且不写日志、不重启、异常被 `stop()` 吞掉

- **位置**：`f_store/src/Compaction.cj:66-85`（`runLoop` 无 `try/catch`）、`42-45`（`spawn` 体只有 `running.store(false)`，无异常记录）、`50-58`（`stop` 里 `catch (_: Exception) {}`）、`186-197`（关闭/删除失败的 `catch (_: Exception) {}`）
- **来源**：存量（`git blame -L 66,85` / `-L 50,58`：`4be871f2f`）
- **判据**：review-checklist §3「静默吞异常」、§11「错误处理缺失」、§12.1「异步语义：Future 异常被吞」
- **证据**：静态确定 —— `compact(level)` 里有若干不落在局部 `try` 内的抛点：`96-99` 的 `getSSTablesForCompaction`、`145-153` 的 `sst.getMetadata()`（`getMetadata` 内部 `guardReadable()` 在已关闭时抛 `StoreClosedException`，见 `SSTable.cj:261-264`、`483-487`）、`159` 的 `getOverlappingSSTables`、`172-175` 的 `writeStreamToSSTables`（I/O 失败抛 `SSTableWritingException`）。`runLoop` 直接调用 `compact`，异常一路冒到 `spawn` 体，线程结束、`running=false`；`stop()` 再把 `f.get()` 的异常吞掉。全过程没有一条 `f_log`。
- **描述**：一次磁盘满、一次权限错误、一次 `SSTable` 已关闭的竞态，都会让该 `Store` 之后的整个生命周期**没有任何 compaction**：L0 文件无限增长（`shouldCompact(0)` 永远为 true 但没人执行）、点查要线性扫全部 L0、`prefix` 打开的文件句柄数随之线性增长。因为不写日志、`isRunning()` 只在测试里用（`Compaction_test.cj:355`），运维侧完全没有信号，属于"静默失效"。
- **建议**：`runLoop` 的循环体内包 `try { compact(level) } catch (e: Exception) { /* f_log + 计数 + 退避 */ }`，异常后置退避（如 1s）继续下一轮而不是退出线程；`stop()` 里保留异常但通过日志/指标暴露（至少 `f_log` warn），不要 `catch {}` 静默；`remove` 失败要有独立的 orphan 文件兜底策略（见 #5）。

### [一般][存量] #5 `MemTableManager` 没有背压也没有"换出失败"的回退：一次 flush 失败会让 immutable 永久占位，active 无界增长

- **位置**：`f_store/src/MemTableManager.cj:41-54`（`immutable.isSome()` 时 `swapActive` 直接 `return None`）、`64-76`（`clearImmutable` 只能被成功 flush 的一方调用）
- **来源**：存量（`git blame -L 41,54`：`4be871f2f`）
- **判据**：review-checklist §5「无界容器」、§11「错误处理缺失」、§3「开关打开后走进空分支」；文档承诺 `f_store/doc/架构设计方案.md:251`「如果 immutable 尚未刷完而 active 又满了，**需阻塞等待（背压）**」
- **证据**：静态确定 —— 唯一能清掉 `immutable` 的路径是 `Store.maybeFlush` / `Store.close` 里"flush 成功 → `clearImmutable()`"（`Store.cj:381-387`、`263-269`）。`flushMemTable` 抛异常时（`store_func.cj:136-165` 会把异常重新抛出），`clearImmutable` 不会执行，`state.immutable` 永久非空；此后**所有** `swapActive()` 返回 `None`：
  - `maybeFlush` 里的 `if (let Some(table) <- swapActive())` 永远不成立 ⇒ 不再 flush；
  - `active` 只增不减（`MemTable.byteCount` 无上限，`MemTable.cj:31-42`）⇒ 堆随写入线性增长，直到 OOM；
  - 每次 `add` 都会走到 `maybeFlush` 的 `approximateSize()` 判断（`Store.cj:377-380`），但没有任何代价触发（判断的是新的空 active）。
  文档写的"阻塞等待背压"在实现里不存在——实现是"丢弃 swap"，靠调用方恰好是另一个正在 flush 的线程来兜底；那个线程失败后就没有兜底了。
- **描述**：这是"单点失败放大成永久退化"的典型：一次 I/O 错误（磁盘满、目录被删）不会只影响那一次 flush，而是让整个 Store 的写入路径失去落盘能力，并且在进程重启前不可恢复；期间 `add()` 仍然成功返回，用户以为写入了，实际只存在于内存。
- **建议**：`swapActive` 增加"失败重试/超时"语义，或在 `MemTablePair` 里加 `flushFailed: Bool`：`maybeFlush` 捕获 flush 异常后置位并允许下一次 `swapActive` 把旧 immutable 合并回 active（双写）；至少要保证"immutable 卡住"时有可观测信号（异常、日志、`isDegraded()`），并在后续 `add` 上做拒绝/阻塞而不是静默继续。若确定不做背压，请改 `架构设计方案.md:251` 的表述，避免读者按"会阻塞"设计上游。

### [一般][存量] #6 compaction 没有 manifest / 原子提交：中途崩溃或删除失败会留下重复且范围重叠的层，重启后可能读到旧值

- **位置**：`f_store/src/Compaction.cj:176-197`（`addSSTable(nextLevel)` → `removeSSTables` → `close()` → `remove(file)` 四步非原子）、`f_store/src/LevelManager.cj:45-71`（`loadExisting` 只按文件名重建，无任何一致性校验）
- **来源**：存量（`git blame -L 176,197`：`4be871f2f`；`loadExisting` 同）
- **判据**：review-checklist §11「资源不对称 / 契约与实现不符」、§5「长期持有」；文档承诺 `架构设计方案.md:863`「新 SSTable 写完后再删除旧的，保证崩溃恢复后数据完整」、`:871`「旧 SSTable 引用计数归零后延迟删除」
- **证据**：静态确定（机制层面），崩溃后果需实测 ——
  1. 四步之间没有 fsync 目录、没有 MANIFEST/marker，重启时 `loadExisting` 把 `sst/` 下所有能打开的文件都装载（`SSTable.loadAll` 静默跳过打不开的，`SSTable.cj:453-458`）。若崩溃发生在"新 L1 已落盘、旧 L0 未删"，重启后 L0（旧值）与 L1（新值 + 旧值）同时存在，L1 出现**范围重叠**，违反 `LevelManager` 注释里"Ln 范围不重叠"的不变量（`LevelManager.cj:120`、`229-259`），读路径按"第一个命中"返回（`129-133`），结果依赖文件顺序（`sort(sstFiles)` 的字典序），可能返回旧值；
  2. `remove(sst.getMetadata().filePath)` 被包在同一个 `try` 里（`186-197`）：`getMetadata()` 在 SSTable 已关闭时抛 `StoreClosedException`（`SSTable.cj:261-264`），文件删除被跳过，留下没有 LevelManager 引用的孤儿 `.sst`，下次启动又被 `loadExisting` 当成活文件装载（重复数据）；
  3. `架构设计` 承诺的"引用计数 / 延迟删除"在代码里不存在（`removeSSTables` 立即把引用摘掉并 `close()`+`remove()`），读方靠"独立 File 句柄 + 吞 `StoreClosedException`"兜底（`SSTableIterator.cj:225-236`、`LevelManager.cj:103-106`），属于另一套机制，文档与实现不同源。
- **描述**：单进程正常运行时这些窗口不可见（测试均在单线程或"close 后不再操作"的前提下跑）。但模块的卖点是"崩溃后可从 WAL 恢复"（`架构设计方案.md:34`），而 SSTable 侧没有任何类似 WAL 的恢复依据：一旦 compaction 的中间态被持久化，恢复逻辑无法判断"哪些文件是新写的、哪些是待删的"。这属于持久化设计层面的缺口，不是实现笔误。
- **建议**：引入最小 manifest（或用一个 `MANIFEST`/`CURRENT` 文件记录每层文件集合，写临时文件 + rename 原子替换）；`loadExisting` 只装载 manifest 里登记的文件，其余 `.sst` 视为垃圾并在启动时清理；`remove()` 与 `getMetadata()` 解耦（先取 path 再删，删除失败只告警并登记待清理）。补一条崩溃注入用例：`compact` 在 `addSSTable` 之后、删除之前中断，重启后 `get` 必须是新值。

### [一般][存量] #7 `Compactor.compactionThread` 是普通可变字段，`start()` / `stop()` 跨线程读写无同步

- **位置**：`f_store/src/Compaction.cj:25`（`private var compactionThread: ?Future<Unit>`）、`46`（`start` 内赋值）、`52-57`（`stop` 内读取并置 `None`）
- **来源**：存量（`git blame -L 25,58`：`4be871f2f`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」、§6.2「锁对象误用」的反面：这里连锁都没有
- **证据**：静态确定（存在数据竞争）—— `running` / `stopSignal` 都是 `AtomicBool`，唯独真正承载"等待句柄"的 `compactionThread` 是普通字段。`Store.close()` 可从任意线程调用（`Store.cj:246`，且 `atExit` 在运行时线程上调用 `close()`，`Concurrency_test.cj:254-328` 也在写线程之外的主线程 close）。两个线程之间没有任何 happens-before：写者 `start()`（`Store.init` 里调用）与读者 `stop()` 可能看到 `None`，从而**跳过 `f.get()`**，不等待 compaction 退出就继续 flush / `wal.close()` / `closeAll()`。
- **描述**：后果限于 close 期间的收尾竞态（因此定为一般）：compaction 线程仍在 `writeStreamToSSTables` 时 `closeAll()` 关闭了它正在读的 SSTable（`getMetadata` / `getDirect` 抛 `StoreClosedException`），新文件可能在建好后被 `addSSTable` 到已关闭的 Store（句柄泄漏），或因 `#4` 让该线程带异常退出。已确认不会造成已 flush 数据的丢失（WAL 在 `wal.sync()+close()` 前已写入，旧文件删除也在 compaction 内完成），所以不按"数据竞争 ⇒ 严重"顶格。
- **建议**：`compactionThread` 改成 `AtomicReference<?Future<Unit>>`（`start` 里 CAS 安装、`stop` 里 `load()` 后置 `None`），或在 `start`/`stop` 上共用一把 `Mutex`；`stop()` 里对 `f.get()` 加超时并记录未退出。更好的做法是把 `start/stop/isRunning` 收进一个小的状态机（`STOPPED → RUNNING → STOPPING`），避免 `start()` 在 `stop()` 未完成时重启线程。

### [一般][存量] #8 `ByteArray` / `EntryValue` 直接持有调用方的 `Array<Byte>`，无所有权约定：调用方原地改数组会破坏跳表有序性与已持久化数据的一致性

- **位置**：`f_store/src/ByteArray.cj:27-30`（`this.bytes = bytes`，只存引用）、`f_store/src/EntryValue.cj:27-31`（`this.value = value`）、`f_store/src/MemTable.cj:31-42`（把该 key/entry 直接插入 `ConcurrentSkipListMap`）
- **来源**：存量（`git blame -L 22,47 -- f_store/src/ByteArray.cj`：`4be871f2f`）
- **判据**：review-checklist §10「仓颉语言特性：值 / 引用语义」、§11「契约与实现不符」；`f_store/README.md:371-377` 只写"可用字节数组构造、用 `bytes` 取回原始字节"，**没有**声明"传入数组此后不得修改"
- **证据**：静态确定 —— `ByteArray` 是 `struct`，但字段是引用类型 `Array<Byte>`，`this.bytes = bytes` 不复制内容；`Store.add` 用 `ByteArray(key)` 包装调用方数组后插入跳表（`Store.cj:101`），跳表的节点比较依赖该数组内容（`ByteArray.compare`，`33-43`）。调用方在 `add` 返回后 `key[0] = ...`：
  - 跳表的**有序性失效**（节点位置是按旧字节算出来的），后续 `get`/`add` 的二分/下沉会走错分支，可能查不到已存在 key、或产生重复 key 节点；
  - `hash` 字段（`25`）不会随之更新，`hashCode()` 与内容不再自洽；
  - `EntryValue.value` 同理：`add(k, v)` 后改 `v`，memtable 里的值与 WAL/ SSTable 里已写的字节不一致，重启前后读到不同的值。
  返回方向也一样：`get` 直接返回内部数组（`Store.cj:373`），调用方原地改返回值就改掉了存储里的值。`PrefixIterator.next` 返回的 key/value 对 SSTable 源是拷贝（`SSTableIterator.cj:205-214`），对 MemTable 源则是内部引用，行为不一致。
- **描述**：这是公开 API 的契约缺口，不是内部实现细节：`public func add(key: Array<Byte>, value: Array<Byte>)` 接受可变引用类型，使用者（`f_store` 之外）完全可能复用缓冲区（例如从 socket 读入的 `buf` 直接传入）——这在 LSM 里会直接破坏内存索引。仓内调用方目前都传 `unsafeBytes()` 新数组，所以问题潜伏；但没有文档约束、没有防御性拷贝、测试也没有覆盖。
- **建议**：三选一并写进 README/接口注释：(a) `add` / `remove` / `get` 入参做 `key.copyTo()` 防御性拷贝（成本需实测，小 key 每次多一次 O(keyLen) 复制）；(b) 明确"传入数组视为只读、调用后不得修改，返回数组同样只读"，并在 `ByteArray` / `EntryValue` 注释里写清（代价是零拷贝，收益保留）；(c) `ByteArray` 改持不可变表示。无论哪种，`MemTable.tailer` 与 `Store.get` 的返回值语义要统一（要么全部拷贝，要么全部只读引用）。

### [一般][存量] #9 `doc/架构设计方案.md` 大面积停留在旧设计：Mutex/背压/引用计数/时间单位/文件名全部与实现不符，示例代码按文档抄会写错

- **位置**：`f_store/doc/架构设计方案.md:232-245`、`:251`、`:486`、`:871`、`:578`、`:614`、`:1004`、`:848`、`:195`、`:400`、`:539-542`、`:1047-1067`
- **来源**：存量（文档 mtime 2026-10-02，与 `4be871f2f` 同批；实现其后有 `P0/P2/P3` 多轮修复，文档未跟）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「示例代码不能用」「文档过期」
- **证据**：静态确定，逐条对照（左=文档，右=实现）：

  | 文档 | 实现 |
  | --- | --- |
  | `:232-245` `MemTableManager` 用 `active`/`immutable` 两个 `AtomicReference` + `flushLock: Mutex` | `MemTableManager.cj:33-77` 单个 `AtomicReference<MemTablePair>`，**无 Mutex** |
  | `:251` "immutable 未刷完而 active 又满了，需阻塞等待（背压）" | `swapActive` 返回 `None` 直接丢弃（`MemTableManager.cj:45-47`），无背压（见 #5） |
  | `:486` `levelLocks: Array<Mutex>` | `LevelManager.cj:27` `Array<AtomicReference<ArrayList<SSTable>>>`，无锁 |
  | `:871` "旧 SSTable 引用计数归零后延迟删除" | `Compaction.cj:184-197` 摘引用后立即 `close()` + `remove()`，无引用计数 |
  | `:578` / `:614` `DateTime.now().toUnixTimestamp() + expire.toNanoseconds()` | `Store.cj:116` / `132` `DateTime.now().toUnixTimeStamp().toNanoseconds() + expire.toNanoseconds()`；按 `std.time` 文档 `toUnixTimeStamp(): Duration`（`libs/std/time/time_package_api/time_package_structs.html`），文档写法的类型与单位都不成立 |
  | `:1004` "`DateTime.now().toUnixTimestamp()` 也为纳秒级 Int64" | 同上，返回 `Duration`，**不是**纳秒 `Int64`，必须显式 `.toNanoseconds()` |
  | `:195` `byteCount.fetchAdd(...)` 不扣旧值 | `MemTable.cj:33-40` 已改为 `newSize - oldSize`，并有用例 `MemTable_test.cj:103-122` 守护；照文档写会重新引入漂移 |
  | `:848` compaction "跳过 tombstone" | `SSTableMerger(isBottomLevel:)` 只在最底层丢 tombstone（`Compaction_test.cj:164-214`）；按文档写会在非底层丢删除标记，等价于复活已删数据 |
  | `:400` `L{level}_{sequence_start}_{sequence_end}.sst`、`:539-542` `0000000000000001.wal` | 实际 `L{level}_{sstIndex}.sst`（`store_func.cj:117`）、`wal_{seq}.wal`（`WAL.cj:80`） |
  | `:1047-1067` 文件清单含不存在的 `src/SSTableState.cj`，把 `ByteArray`/`EntryValue` 归到 `Store.cj`，`WAL.cj` 写成"File 同步 IO" | 实际 `ByteArray.cj` / `EntryValue.cj` 独立、状态用常量而非枚举、WAL 委托 `f_io.SegmentedLog`（`WAL.cj:25-52`） |

- **描述**：文档本身没有"历史 / 已废弃"标注，读者（含下游使用 `f_store` 的模块作者）会把 §4.2 / §6.3 / §9.3 当作当前语义。危害最大的是三类：时间单位（照抄得到"秒+纳秒"混合的 `expireAt`，TTL 直接错到不可用）、"compaction 跳过 tombstone"（复活已删数据）、"有背压/有引用计数"（对故障与并发行为的预期失真）。第 1 部分已覆盖 README；本条只针对 `doc/架构设计方案.md`。
- **建议**：要么把文档降级为"设计归档（v0，不代表当前实现）"并在首行标注，要么按当前代码重写 §4.2 / §4.7 / §6.2 / §6.3 / §9.3 与文件清单，示例统一使用 `toUnixTimeStamp().toNanoseconds()`。建议在 CI 里加一条"文档示例的类型/API 名称能被 grep 到"的轻量检查（至少防止 `toUnixTimestamp` 这类不存在的拼写）。

### [轻微][存量] #10 `PrefixIterator` 的 Resource 生命周期没有对外说明：提前 `break` 不 `close()` 会为每个 SSTable 泄漏一个 `File`，且 `close()` 自身会抛异常

- **位置**：`f_store/src/PrefixIterator.cj:106-128`（`close` 遍历关闭、异常用 `PrefixIteratorException` 汇总）、`42-102`（只有耗尽/越界才自动 `close`）
- **来源**：存量（`git blame -L 106,128`：`4be871f2f`）
- **判据**：review-checklist §11「资源不对称」、§14.2「缺关键段落：限制与注意事项」
- **证据**：静态确定 —— `Store.prefix` 为每个范围命中的 SSTable 建一个 `PeekableIterator(sst.tailer(...))`（`Store.cj:212-215`），`SSTable.tailer` 每次都 `File(path, OpenMode.Read)`（`SSTable.cj:352-355`）。迭代器只在"堆空"（`95-98`）或"key 越出前缀"（`52-55`）时自动 `close`；调用方在循环里 `break`（分页取前 N 条是很自然的用法）后既没有 close，也没有 finalizer，FD 只能等进程退出才回收。已有用例 `Concurrency_test.cj:414-419` 是"整段迭代完"，掩盖了这个面。`README.md:263-276` 的"迭代器生命周期"段落只讲"关闭不影响 Store"，没说"提前退出必须 close"。
  另外 `close()` 在任一底层 `close` 失败时 `throw PrefixIteratorException()`（`125-127`），而它在 `next()` 内部也被调用（`53`、`97`）——用户在 `next()` 上会收到"关闭失败"异常，`finally` 里再调一次 `close()` 又会抛，容易吞掉原始异常。
- **描述**：属于契约与文档缺口而非实现错误（实现已正确实现 `Resource`）。风险在于 FD：一个 `prefix()` 在 L0 有 4 个文件、L1–L6 各命中 1 个时打开 10 个句柄；1000 并发未关闭的迭代器就能打满默认 `RLIMIT_NOFILE`。
- **建议**：README 的 `prefix` 段落补一句"迭代器是 `Resource`，提前退出请 `try (iter = store.prefix(...))` 或显式 `iter.close()`"，示例改成 `try` 块；`close()` 的异常语义二选一并写清（要么永不抛、错误只记日志，要么保留但文档标注"可能抛"）。`next()` 内部触发的 `close()` 建议不再把关闭异常当作迭代异常抛出，避免与 `PrefixIteratorException` 的"读取失败"语义混淆。

### [轻微][存量] #11 `ByteArray.hash` 的预计算在全仓没有任何消费方：每次取键白付一次 `HashBuilder` 分配 + 全量字节遍历，README 的性能结论失去依据

- **位置**：`f_store/src/ByteArray.cj:25`（`let hash: Int64`）、`27-30`（构造即计算）、`45-47`（`hashCode` 只被自己用）
- **来源**：存量（`git blame -L 22,47`：`4be871f2f`；README 性能表 `README.md:480` 同批）
- **判据**：review-checklist §1「读了不用 / 死计算」、§8「减少分配」；`f_store/README.md:480` 声称"CSLM findNode 中 Node key 的 hashCode() 从 O(n) 降为 O(1)｜大 key ~5-10%"
- **证据**：静态确定 —— 全仓搜 `hashCode`：`f_store` 里只有 `ByteArray.cj:45` 的定义处，没有任何调用点；`f_concurrent/src/ConcurrentSkipListMap.cj` 内没有一处 `hash` / `hashCode`（`Node` 只用 `compare`，泛型约束是 `K <: Comparable<K>`，`ConcurrentSkipListMap.cj:24`），CSLM 也不要求 `Hashable`。而 `ByteArray` 在**每一次**读路径上被构造：`Store.get` / `contains` / `remove` / `add` / `ttl` 都 `ByteArray(key)`（`Store.cj:151` 等），每次都执行 `HashBuilder().append<Byte, Array<Byte>>(bytes).build()`（`ByteArray.cj:29`）——一次对象分配 + 一次全量字节遍历。所以 README 里"降为 O(1)"的前提（CSLM 会取 hash）不成立，收益无从谈起，成本则实打实落在每次按键访问上。
- **描述**：`hashCode()` 是 `public`（对外可达，按规则不算死代码），但 `hash` 字段与构造期计算在仓内是纯开销；README 把它列为已生效的性能优化项，会误导后续维护者继续围绕它做优化。是否值得保留取决于是否有外部使用方把 `ByteArray` 当 `HashMap` 键。
- **建议**：若确认无外部依赖，删掉 `Hashable` / `hash` 字段（`ByteArray` 仍是 `Comparable`，CSLM 不需要 hash）；若保留，改成惰性计算（`hash` 用 `var` + 双重检查，或去掉字段直接 `hashCode` 现场算），并把 `README.md:480` 的结论标注为"当前未被 CSLM 消费，待验证"。收益需要实测，见「待验证假设」#2。

### [轻微][存量] #12 过期 / tombstone 判定有三份实现，语义一致但返回形态不同，已经导致 #1 这种"两处口径不一致"的缺陷

- **位置**：`f_store/src/LevelManager.cj:141-153`（`checkExpiry`，返回 `?EntryValue`）、`Store.cj:349-359`（`entryIsAlive`，返回 `Bool`）、`Store.cj:362-374`（`checkExpiryAndGet`，返回 `?Array<Byte>`）
- **来源**：存量（`git blame`：`4be871f2f`）
- **判据**：review-checklist §2「表现形式不同的重复逻辑：换返回值/换控制流」
- **证据**：静态确定 —— 三处都是"`expireAt <= now` 或 `value.isNone()` ⇒ 视为不存在"，判定顺序还不一致（`LevelManager` 先查过期再查 tombstone，`Store.entryIsAlive` 先查 tombstone）；`Store.get` 在拿到 `levelManager.get` 的结果后又做了一次 `checkExpiryAndGet`（`Store.cj:166-168`），即同一判定对同一 entry 执行两遍。差异点只有一个：`LevelManager` 的版本会**终止层间查找**（这正是 #1 的根因），另外两个不会。
- **描述**：三份实现让"过期/删除"的语义分散在两个文件四个位置，本次审查发现的 #1 就是其中一份被误用为"层间终止信号"的直接后果。合并后语义只在一处定义，`Store` 侧的两份可以退化为一份。
- **建议**：在 `f_store` 内收敛为一个 `func isAlive(entry: EntryValue, now: Int64): Bool`（或 `?Array<Byte>` 版本 + `Bool` 版本互为薄封装），`LevelManager` 只负责"命中即返回原始 entry"，`Store` 负责最终判定（与 #1 的修法同源）。

### [轻微][存量] #13 范围重叠判定两处独立实现，比较方向与边界写法不同（`maxKey < minKey` vs `minKey <= max`）

- **位置**：`f_store/src/Compaction.cj:117-131`（`if (!(meta.maxKey < nm.minKey || meta.minKey > nm.maxKey))`）、`f_store/src/LevelManager.cj:248-255`（`withinMax && meta.maxKey >= min`）
- **来源**：存量（`git blame`：`4be871f2f`）
- **判据**：review-checklist §2「字面量 / 判定复制：同一谓词两处实现」
- **证据**：静态确定 —— 两处都在判 `[min,max]` 与 `[minKey,maxKey]` 是否相交，逻辑等价（`!(sst.maxKey < nm.minKey || sst.minKey > nm.maxKey)` ⇔ `nm.minKey <= sst.maxKey && sst.minKey <= nm.maxKey`），但一处用"否定 + 严格不等"，一处用"正向 + 非严格不等"；`Compaction` 那处对 `ns` 没有 `isClosed()` 前置检查（`120-126`），只靠外层 `catch (_: StoreClosedException)` 兜（`129-130`），`LevelManager` 那处则有（`244-247`）。
- **描述**：等价实现分裂的直接成本是"改一处忘另一处"：例如将来要给 L0/Ln 引入"包含端点"的语义变化，两处很容易只改一处；`Compaction.cj:111` 还借用了 `getSSTablesForCompaction(nextLevel)`（语义是"取该层待合并文件"）来当"取该层全部文件"用，命名与用途不一致。
- **建议**：把相交判定抽成 `LevelManager` 的 `func overlaps(a: SSTableMetadata, b: SSTableMetadata): Bool`（或 `overlapsRange(level, min, max)`），`Compaction.cj:113-132` 改为"对该层每个 sst 调一次"，删除 `getSSTablesForCompaction` 的复用；顺带给 `ns` 加 `isClosed()` 前置检查。

### [轻微][存量] #14 `Compaction.cj:138-140` 是恒假分支（`selectedSSTables` 不可能为空），且"最多 4 个"字面量在选取与门限两处各写一遍

- **位置**：`f_store/src/Compaction.cj:138-140`（`if (selectedSSTables.size == 0) return`）、`104`（`pickCount` 的 `4`）与 `LevelManager.cj:269`（`count >= 4`）
- **来源**：存量（`git blame`：`4be871f2f`）
- **判据**：review-checklist §1「恒真恒假分支」、§2「字面量复制」
- **证据**：静态确定 —— `96-99` 已保证 `levelSSTables.size > 0`；L0 分支 `pickCount = min(4, size) >= 1` ⇒ 至少 add 一个（`104-107`）；Ln 分支无论 `nextLevelSSTables` 是否为空，`133-136` 都会补一个尾部文件 ⇒ `selectedSSTables.size >= 1`。因此 `138` 的条件永远为假，是编译期可判的死分支（属防御性代码，但注释缺失，会被误读成"可能为空"）。同时 `4` 这个阈值在 `Compaction.cj:104` 与 `LevelManager.cj:269` 各写一遍，改一处就会出现"该合并却没合并/合并了却不够"的漂移，与 #2 的选取策略强耦合。
- **描述**：不影响运行，但两处字面量耦合是 #2 的诱因之一：门限（>=4）与单次搬运量（最多 4）被当成两个独立常量，正是"超过 4 个时只搬 4 个"这个错误模型的基础。
- **建议**：把 `L0_COMPACTION_TRIGGER` / `L0_COMPACTION_BATCH` 提为 `LevelManager`（或 `const`）里的具名常量并由 `Compactor` 引用；`138-140` 删除或改注释说明"兜底不可达"。

### [轻微][存量] #15 `PrefixIterator` 在 `init` 里冻结 `now`，与 `get` 的实时过期口径不一致；长时间或懒消费的迭代会返回已过期数据

- **位置**：`f_store/src/PrefixIterator.cj:33`（`this.now = DateTime.now()...`）、`88-92`（用 `this.now` 判过期）
- **来源**：存量（`git blame -L 30,40`：`4be871f2f`；用例 `PrefixIterator_test.cj:170-197` 专门断言"冻结 now"）
- **判据**：review-checklist §11「语义与注释不符」、§13「规格与实现漂移」；文档 `架构设计方案.md:972`「`get`/`prefix` 遇到过期数据视为不存在」
- **证据**：静态确定 —— 口径差异只在"迭代器存活时间长于 TTL 剩余时间"或"创建后先放着不消费"时体现：`iter = store.prefix(p)` 之后睡 10 分钟再逐条 `next()`，会返回 `expireAt` 已过（相对当前时间）的条目；同一时刻 `get(k)` 返回 `None`。`PrefixIterator_test.cj:170-197` 把"冻结"当特性断言（P2 优化，避免每条记录调 `DateTime.now()`），说明这是有意为之，但 README / 文档都没写这条语义。
- **描述**：属于"行为可接受但未声明"。冻结 `now` 对一次性遍历是合理优化（快照语义也要求口径稳定）；问题只在于没有任何地方告诉使用者"迭代器看到的是创建时刻的过期视图"，与 `get` 的对比会让人误判为 bug。
- **建议**：保留冻结语义，在 `README.md` 的 `prefix` 段落与 `PrefixIterator` 类注释各加一句"过期判定以迭代器创建时刻为准，与 `get` 的实时判定可能不同"；若要更严格，改为按块刷新 `now`（每 N 条或每次 `loadBlock` 时刷新），代价是每块一次 `DateTime.now()`。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分没有任何 bench / `cjprof` 数据，全部标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] `LevelManager` 每次增删都复制整层列表

- **现状**：`addSSTable`（`LevelManager.cj:160-171`）与 `removeSSTables`（`179-201`）都是"新建 `ArrayList` → 全量 `add(all: oldList)` → CAS"。n = 该层文件数（L1–L6 单层几十到几百），每次 flush 触发 1 次、每轮 compaction 触发 2 次，每次分配 `n+1` 个引用的数组 + 一个 `ArrayList` 对象；旧列表在下一次 CAS 失败时还会再分配一份。
- **方案**：改成不可变链表/持久化列表（每次变更只分配 O(1) 新节点），或把"层列表"换成 `AtomicReference<ImmutableArray<SSTable>>` 的分段结构（按 sstIndex 分桶，桶内追加）；compaction 端只替换受影响的桶。
- **预期**：每轮 compaction 的临时分配从 O(n) 降到 O(1)（n 为该层文件数），GC 压力随之下降。具体字节量需按实际层规模测算，本报告不给百分比。
- **代价**：读路径需要遍历分段结构（`getInLevel` 的 L0 反向遍历会变复杂），`refEq` 删除需要跨桶扫描；并发语义要从"整表 CAS"重新推导（目前只有 flush / compaction 两个写者，可控）。
- **验证**：同一负载下 `getAllocatedHeapSize()` 与 GC 次数对照；`levelSummary()` 的文件数分布作为规模参数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 取键路径上的 `HashBuilder` 预计算（见 #11）

- **现状**：每次 `ByteArray(bytes)` 构造都 `HashBuilder().append(bytes).build()`；`ByteArray` 在 `get` / `contains` / `add` / `remove` / `ttl` 每次调用都构造一次。仓内无 `hashCode()` 消费方（CSLM 只用 `compare`）。
- **方案**：删除 `Hashable` 与 `hash` 字段；若外部确有 `HashMap<ByteArray, _>` 用法，改成惰性（`var hash: ?Int64` + 首次 `hashCode()` 填充）。
- **预期**：每次按键访问省一次对象分配 + 一次 O(keyLen) 遍历；大 key（README 提到 ~5-10%）可能可见，小 key 接近噪声。
- **代价**：`ByteArray` 不再 `Hashable`，是公开 API 的兼容性变更（本项目允许破坏性变更，但需用户拍板）；惰性方案保留 `Hashable`，但要处理 `struct` 内 `var` 的写法与并发可见性（`ByteArray` 会被多线程共享，惰性写需要原子或"只写不读旧值"的宽容语义）。
- **验证**：`cjpm bench -O2` 跑 `Store_bench` 的 `get` 场景，键长 8B / 64B / 1KB 三档，对照中位数与 P95；`cjprof` 看 `HashBuilder` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] Compaction 选择阶段对 metadata 的 O(n×m) 扫描 + 双重查询

- **现状**：`Compaction.cj:111-132` 对 `levelSSTables` × `nextLevelSSTables` 逐个 `getMetadata()` 比较范围，随后 `159` 又调 `getOverlappingSSTables` 再扫一遍；两层都是内存中的 metadata（`SSTableMetadata`），单次比较很便宜，但文件数上去后是纯 O(n×m)。
- **方案**：两层都按 `minKey` 排序（`loadExisting` 时建一次），用双指针求交；`159` 直接复用 `113-132` 已算出的重叠集合与合并后的范围，避免二次查询。
- **预期**：选择阶段从 O(n×m) 降到 O(n+m)；是否值得做取决于选择阶段占 compaction 总耗时的比例（当前无数据）。
- **代价**：需要在 `LevelManager` 维护"按 minKey 有序"的不变量（当前 Ln 只保证不重叠，未保证列表有序）。
- **验证**：`cjprof record` 跑"6 层、每层 100 文件、持续写入"场景，看 `getMetadata` / `compact` 自耗时占比；`cjpm bench` 对照 compaction 吞吐。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能数据支撑，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `LevelManager.get` 的 L0 全文件遍历（每层 `levels[level].load()` 快照 + L0 反向扫全部文件）是点查 P95 的主要来源 | `f_store/src/LevelManager.cj:82-118` | 自耗时占比、L0 文件数分布 | `cjprof record` 跑 8 写线程 + 4 读线程 10 分钟，输出 L0 文件数直方图与 `get` 分段计时 |
| 2 | `MemTable.approximateSize` 只计 key+value+24B，不含跳表节点/多层索引/对象头，8MB 阈值对应真实堆占用约 2–3 倍 | `f_store/src/MemTable.cj:24`、`31-42`、`56-58` | heapUsed / RSS 与 `approximateSize` 的比值 | 写入直到首次 flush，记录 flush 瞬间 `getUsedHeapSize()` / RSS 与 `approximateSize()` |
| 3 | `prefix()` 为每个命中 SSTable 打开一个 `File`，并发未关闭的迭代器会推高 FD 峰值（见 #10） | `f_store/src/PrefixIterator.cj:106-128`、`Store.cj:212-215` | FD 峰值、每迭代器平均句柄数 | 并发 100/1000 个 `prefix` 迭代器各跑 1 分钟，采样 `/proc/<pid>/fd` 数量 |
| 4 | `removeSSTables` 的整表复制 + `refEq` 双层扫描在文件多时进入 compaction 热路径 | `f_store/src/LevelManager.cj:179-201` | 单次 `removeSSTables` 耗时与调用频次 | 在 compaction 前后打点计时，跑"每层 100 文件"场景 100 轮取中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_store/doc/架构设计方案.md` | .md | ✅ | 与实现大面积漂移，见 #9（1067 行全读） |
| 2 | `f_store/src/ByteArray.cj` | .cj | ✅ | `hash` 预计算无消费方 #11；数组别名 #8 |
| 3 | `f_store/src/ByteArrayEntryValue_test.cj` | .cj | ✅ | 10 个用例；只覆盖比较/相等/默认字段，未覆盖"构造后改数组" |
| 4 | `f_store/src/Compaction.cj` | .cj | ✅ | L0 选取方向 #2、线程停摆 #4、字段同步 #7、恒假分支 #14 |
| 5 | `f_store/src/Compaction_test.cj` | .cj | ✅ | 22 个用例；L0 选取用例（`599-639`）用不重叠 key，未覆盖遮蔽 #2 |
| 6 | `f_store/src/Concurrency_test.cj` | .cj | ✅ | 8 个并发用例；`errors`（`157`）声明后从未递增，`169` 的断言恒真（测试代码，不单列） |
| 7 | `f_store/src/EntryValue.cj` | .cj | ✅ | 值数组别名 #8 |
| 8 | `f_store/src/FlushMemTable_test.cj` | .cj | ✅ | 3 个用例；`108-113` 验证 tombstone/过期在**同一层**生效，覆盖不到跨层 |
| 9 | `f_store/src/IndexEntry.cj` | .cj | ✅ | 纯数据载体，无逻辑问题 |
| 10 | `f_store/src/LevelManager.cj` | .cj | ✅ | 跨层 tombstone #1、计数漂移 #3、重叠判定 #13 |
| 11 | `f_store/src/LevelManager_test.cj` | .cj | ✅ | 20 个用例；`163-168` 实际触发 #3 但未断言计数 |
| 12 | `f_store/src/MemTable.cj` | .cj | ✅ | 近似计数（设计如此），热点见待验证假设 #2 |
| 13 | `f_store/src/MemTableManager.cj` | .cj | ✅ | 无背压/失败不可恢复 #5；`53` 的 `None` 为满足编译器的兜底 |
| 14 | `f_store/src/MemTableManager_test.cj` | .cj | ✅ | 6 个用例；未覆盖"flush 失败后 immutable 卡死" |
| 15 | `f_store/src/MemTable_test.cj` | .cj | ✅ | 8 个用例；覆盖 byteCount 漂移与 tailer |
| 16 | `f_store/src/PrefixIterator.cj` | .cj | ✅ | 资源生命周期 #10、冻结 now #15 |
| 17 | `f_store/src/PrefixIterator_test.cj` | .cj | ✅ | 8 个用例；`170-197` 把冻结 now 当特性断言 |

合计：`.cj` 16 个 / `.md` 1 个 / 共 17 个，全部读完（无抽样、无跳过）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 4（#1 #2 #3 #6）、设计 1（#5 失败态不可恢复）、语言特性 1（#8 值/引用语义）；可读性 0（命名与注释整体清晰，`P0/P2/P3` 修复标记可追溯）；安全性 0（本部分无外部输入解析、无凭据、无 SQL/路径拼接，`remove(path)` 的 path 来自自身目录） |
| §1 死代码 | 1 | #14 的恒假分支。另逐项核过：`private`（`ByteArray.hash`→被 `hashCode` 用、`Compaction.compactionThread`→被 start/stop 用、`LevelManager.getInLevel`/`checkExpiry`→被 `get` 用、`MemTableManager.state`→被四个方法用）均有引用；`internal`（`MemTable.iterator/tailer/valueSize`、`Compactor.isRunning`、`LevelManager.levelSummary/getSSTablesInRange/shouldCompact`）除 `isRunning` 仅测试引用外均有生产调用，`isRunning` 属"仅测试使用"，按规则只作可见性建议**不列死代码**；`while(true)` 之后的 `MemTableManager.cj:53` `None` 与 `PrefixIterator.cj:101` `None` 是满足编译器"所有路径有返回值"的兜底，不计死代码；`EntryValue` / `ByteArray` / `PrefixIterator` / `startsWith` / `PrefixIteratorException` 均为对外可达 `public`，按硬原则一不判 |
| §2 重复逻辑 | 2 | #12 过期/删除判定三份（`LevelManager.checkExpiry` / `Store.entryIsAlive` / `Store.checkExpiryAndGet`，另加 `Store.get` 的二次调用）；#13 范围重叠判定两份（`Compaction.cj:122` / `LevelManager.cj:251`）。另逐对比对了本部分 16 个源文件的函数体摘要：`Compaction_test.cj:48-61` 与 `:766-779` 两个 `createSSTable` 逐行相同（包级 + 测试类私有），属测试准备代码，按 §2 误报边界只记于此、不单列；`LevelManager_test.cj` 的同名辅助函数签名不同（单 key），不构成重复 |
| §3 空实现 | 1 | #4（`catch (_: Exception) {}` 静默吞掉 compaction 失败与文件删除失败，共 6 处：`Compaction.cj:55/82/130/190/196/208`）。无空的公开函数、无 `TODO`、无"开关打开走空分支" |
| §4 栈溢出 | 0 | 本部分无递归：compaction / prefix 都是堆 + 循环（`PrefixIterator` 用 `PriorityQueue` 迭代推进，`Compaction` 用 `while` 归并）；无自引用结构的深度遍历 |
| §5 OOM | 1 | #5（flush 失败后 active 无界增长）。另核过 `Compaction` 为流式写入（`writeStreamToSSTables` 满 64MB 即切文件，`store_func.cj:113-167`），`PrefixIterator` 的堆大小 = 源数，均无"全量物化" |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，热点结论不成立；4 条疑似热点已进「待验证假设」，附采集方法 |
| §6.2 大粒度锁 | 0 | `LevelManager` / `MemTableManager` 均为 AtomicReference + CAS，无锁内 I/O；本部分涉及的唯一锁是 `SSTable.getLock`（`SSTable.cj:306`、`467`），而 `SSTable` 属另一部分的文件，本部分不判 |
| §6.3 并发串行 | 0 | compaction 单线程是设计（单写者 + 原子替换），不是"形式并发实际串行"；`spawn` 后立即 `get()` 只出现在测试收尾（`*.get()` 在全部 spawn 之后），不构成热点 |
| §6.4 低效算法 | 1 | compaction 选择阶段的 O(n×m) metadata 扫描（`Compaction.cj:113-132`，优化方案 3）；`removeSSTables` 的 `refEq` 双层扫描（`LevelManager.cj:183-192`）同源，见待验证假设 #4 |
| §7 降堆内存方案 | 1 | `LevelManager` 整层复制（无基线，待验证） |
| §8 降 CPU 方案 | 2 | `ByteArray` 取键路径 HashBuilder（#11）、compaction 选择阶段双重扫描 |
| §9 local mode 可行性 | 0 | 本部分没有"函数内创建、函数内销毁的大临时对象"：compaction 的中间态是迭代器 + 64MB 流式写，`PrefixIterator` 的堆必须跨 `next()` 存活（逃逸），不符合 local mode 前提，收益也无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 15 | 本部分 15 条发现全部为存量（快照模式无基线，`git blame` 均指向 `4be871f2f 2026-10-02` 及更早）；其中 #1 #2 #3 #5 #6 #8 为逻辑/数据类，#4 #7 为并发/故障类，#9–#15 为文档、死代码、重复与语义声明类 |
| §12 并发安全与锁粒度 | 3 | #7（`compactionThread` 普通字段跨线程读写，同步缺失）；#3（列表 CAS 与计数器分别更新，非同一原子不变量）；#6 附带的"读方持有已关闭 SSTable"路径（`getInLevel` 吞 `StoreClosedException` 后落到下一层，已核对该路径在"新表先入 L1 再删旧表"的顺序下不会读错，故未单列为缺陷）。已确认 `MemTableManager` 的 `clearImmutable` 不会误清后装的 immutable（`swapActive` 在 immutable 非空时拒绝交换，形成互斥） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 `public` 符号逐项对照 `README.md`：`ByteArray`(371-373)、`EntryValue`(375-377)、`PrefixIterator`/`prefix`(250-279)、`startsWith`(367-369)、`PrefixIteratorException`(384) 均已文档化，无遗漏；`Compactor` / `LevelManager` / `MemTable` / `MemTableManager` 为模块内部实现，不必进 README。README 的性能表结论问题并入 #11 |
| 文件覆盖（§13 等） | 17/17 | 无缺文件；`doc/架构设计方案.md` 1067 行全读，逐节核对见 #9 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 7 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量 15 条，是否纳入修复待用户决定（本部分无"本次改动"引入的问题，全部为存量）。

## 总评

本部分的代码质量在"数据结构与并发原语"层面是扎实的：`MemTable` 对 `ConcurrentSkipListMap` 的封装、`MemTableManager` 的 `AtomicReference<MemTablePair>` 双缓冲、`LevelManager` 的 copy+CAS 无锁替换、`Compaction` 用 `try/finally` 兜住源迭代器 FD，这些都是有意设计并且注释到位；`Compaction_test.cj` / `LevelManager_test.cj` 的用例密度也明显高于一般模块，`P0/P2/P3` 修复都有对应用例守护。

但"层间语义"这一层存在两个阻塞项，都会表现为**用户可见的数据错误**而非性能问题：

1. **删除/过期标记无法终止层间查找**（#1）——契约在 `架构设计方案.md:731` 写得很清楚，实现在 `LevelManager.get` 把"命中 tombstone"降级成"未找到"，`remove` 之后的 key 会从 L1 复活，`ttl` 还会把删除撤销掉；
2. **L0 compaction 的下沉方向反了**（#2）——只搬最新的 4 个、把更老的文件留在 L0，读路径"先 L0 后 L1"于是读到旧值，覆盖写与删除都会回退。

这两条都只在"未 compaction 完的中间态"出现，所以现有用例（key 不重叠、单轮合并）恰好绕开了；建议优先补两条针对性用例，再动实现。

其余一般项集中在**故障可恢复性**：compaction 线程一次异常即永久停摆且无日志（#4）、flush 一次失败即让 immutable 永久占位并使 active 无界增长（#5）、compaction 缺少 manifest 导致崩溃/删除失败后层状态不自洽（#6）、`compactionThread` 缺同步（#7）。这些在正常路径上不可见，但决定了"磁盘满 / 权限错 / close 竞态"这类真实故障下 Store 是"降级"还是"静默烂掉"。配合 #8（键值数组别名）与 #3（计数器漂移），构成第二优先级。

轻微项里最值得顺手处理的是 #11（`ByteArray.hash` 全仓无消费方，却在每次按键访问上付一次分配 + 全量遍历，且 README 把它当成已生效的优化）与 #9（`doc/架构设计方案.md` 已与实现脱节到"照抄会写错"的程度，尤其时间单位与 tombstone 策略）。这两项不涉及运行语义，但会持续误导后续维护者与下游使用者。

`f_store` 的整体架构（无锁读路径、无 manifest 的简化设计、单 compaction 线程）是自洽的；上述问题不是架构选型的必然结果，而是"层序不变量"没有被单点表达（`LevelManager` 既做查找又做删除/过期判定）与"故障路径没有兜底"这两件事的具体表现。修 #1/#2 时建议同时把 #12 的判定收敛做完，否则同类缺陷还会以第三种形态出现。
