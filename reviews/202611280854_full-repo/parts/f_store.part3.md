# f_store 模块审查报告

> **模块第 3/4 部分**（分报告）。本部分覆盖 `SSTable*` / `Store*` / `WAL*` / `imports.cj` 共 20 个 `.cj`；
> 同模块其余文件（`ByteArray` / `Compaction` / `LevelManager` / `MemTable*` / `PrefixIterator` / `README*.md` / `doc/**` 等）见 `parts/f_store.part{1,2,4}.md`，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_store`（本部分 20 个源文件；全模块 37 个 `.cj` + 5 个 `.md`）
- **基线**：工作区快照（`git status` 仅 `docs/review/`、`reviews/` 未跟踪，源码无改动，无 diff 可比）⇒ **本部分所有发现来源均为「存量」**
- **审查重点**：存储后端正确性、持久化与一致性、资源生命周期、并发安全、死代码、重复逻辑、存量 BUG
- **报告版本**：v1

## 发现

### [严重][存量] 重开文件后 `SSTableMetadata.maxKey` 取成「最后一个 Data Block 的首 key」，点查会被范围裁剪漏掉

- **位置**：`f_store/src/SSTable.cj:429-435`（`lastIdx` / `lastKey` / `SSTableMetadata(...)`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「边界差一 / 契约与实现不符」；`SSTableMetadata.maxKey` 的语义是"文件内最大 key"
- **证据**：静态确定 —— Footer 只存 `index_offset/index_size/bloom_offset/bloom_size/entry_count/magic/sequence_start/sequence_end`（`SSTable.cj:607-625`），**不存 min/max key**；重开时 `firstKey` 取 `indexEntries[0].firstKey`（正确），`lastKey` 却取 `indexEntries[lastIdx].firstKey`——即最后一块的**首** key，严格小于真实最大 key
- **描述**：写路径 `finishWrite` 用真实 `maxKey`（`SSTable.cj:232-237`），所以刚落盘的文件正确；进程重启后 `loadAll → open → openFromFile` 重建的 metadata 里 `maxKey` 偏小。消费方按它裁剪：`LevelManager.getInLevel` 对 Ln(n≥1) 判 `if (key < meta.minKey || key > meta.maxKey) continue`（`LevelManager.cj:126-131`）、`getOverlappingSSTables` 判 `meta.maxKey >= min`（`LevelManager.cj:250-254`）、`Compactor.compact` 用 `meta.maxKey` 算合并区间（`Compaction.cj:143-159`）。结果是：**重启后，最后一个 Data Block 里首 key 之后的键在 L1+ 全部查不到**（`get` 返回 `None`，或穿透到更深层返回旧值），`contains`、`prefix` 同步出错。已有用例（`SSTable_test.cj:1211-1235`）只断言 `sequenceStart/End`，没有覆盖 `maxKey` 往返
- **建议**：①打开时真实 max 需要落盘或重算——最小改动是 Footer 扩容或复用 `sequence_start/end` 之外的槽位存 `max_key_len + max_key`；②过渡期可在 `openFromFile` 里对最后一块做一次顺序扫描求真实 max（块 ≤4KB，代价可接受）；③补一条「跨重启后查最后一个块内非首键」的用例

### [严重][存量] 重启时序列号只从 WAL 恢复，忽略已有 SSTable 的 `sequenceEnd` ⇒ 新写入序列号回退，compaction 归并时旧值胜出

- **位置**：`f_store/src/Store.cj:58-80`（`startSeq` 仅由 `WALReader.recoverAll` 结果累加；`:80` 用它作 `startSequence`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「契约与实现不符 / 数据错误」、§12.1「共享可变状态无保护（跨重启的不变量）」
- **证据**：静态确定 —— `levelManager.loadExisting()`（`:71`）只加载文件，不回填序列号；`SSTableMetadata.sequenceEnd` 在全仓只被 `SSTable.cj:133-134`、`SSTable_test.cj` 读取，启动路径零引用；WAL 文件名与内容会随 `cleanupOldWALFiles`（`:77`）整体删除，因此「WAL 一条记录都没有」的启动是可达的（轮转后当前段为空、或刷盘后旧段被清）——此时 `startSeq = 0`，新写入序号从 1 开始
- **描述**：`SSTableMerger` 在同 key 多源时取 `sequence` 最大者（`SSTableMerger.cj:76-95`）。序列号回退后，老 SSTable 里 `sequence=10^5` 的旧值永远赢过新写入的 `sequence=1`：compaction 会把**旧值/旧 tombstone 状态写回新文件**，表现为「刚写入的值在 compaction 后变回旧值」或「已删除的键复活」。`get` 走层序（L0→Ln）不比较 sequence，所以问题只在 compaction 之后暴露，排查成本高
- **建议**：初始化时把 `max(startSeq, max(levelManager 各层 metadata.sequenceEnd))` 作为 `sequence` 初值与 WAL `startSequence`；`LevelManager.loadExisting` 顺带维护一个 `maxSequenceEnd`（`AtomicInt64`）。补一条「刷盘 → 重启 → 再写 → 触发 compaction → 读回新值」的回归用例

### [严重][存量] 恢复完立即删除旧 WAL：数据此时只在内存，重启后未刷盘前崩溃即永久丢失

- **位置**：`f_store/src/Store.cj:76-80`（注释「数据已在 MemTable 中」）；删除实现 `f_store/src/store_func.cj:216-229`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「资源不对称 / 数据丢失」、§5「长期持有与持久化边界」
- **证据**：静态确定 —— 恢复把记录灌进 `memTableManager.getActive()`（`:62-67`），随后 `cleanupOldWALFiles(walDir)` 删除目录下**全部** `.wal`；新 WAL（`:80`）只记录**后续**写入，恢复出来的数据不再有任何日志副本，直到下一次 `maybeFlush()` 落成 SSTable（阈值 8MB，可能很久）
- **描述**：崩溃一致性从「WAL 里至少有一份」退化为「内存里只有一份」。进程在完成首次刷盘前崩溃/被 kill，已确认恢复成功的全部数据不可再恢复（WAL 已被删、SSTable 里没有）。这与注释「数据已在 MemTable 中」的隐含假设（内存等价于持久）相冲突
- **建议**：恢复后**不要**删旧 WAL，改为把恢复出的记录重新 append 到新 WAL（或直接复用同名 WAL 续写），并在 `flushMemTable` 成功、`addSSTable` 完成后再按 seq 清理对应段；`cleanupOldWALFiles` 至少改成"仅删除 seq ≤ 已落盘最大 seq 的段"

### [严重][存量] 文件名序号未补零 + 字符串排序 ⇒ 重启后 L0 文件优先序与 WAL 重放顺序错乱

- **位置**：`f_store/src/SSTable.cj:446-453`（收集后 `sort(sstFiles)`）；`f_store/src/WALReader.cj:107`（`sort(walFiles)` 后顺序重放）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「边界差一 / 顺序假设不成立」
- **证据**：静态确定 —— 生成侧文件名是 `L${level}_${sstIndex}.sst`（`store_func.cj:117,126`）与 `${prefix}_${seq}${ext}`（`f_io/src/SegmentedLog.cj:215`），序号**未零填充**；`sort(String)` 是字典序 ⇒ `"L0_10.sst" < "L0_2.sst"`。而 `LevelManager.getInLevel` 对 L0 **从列表末尾反向遍历**并注释「最新文件最后添加，优先命中」（`LevelManager.cj:97-101`），依赖的正是"添加顺序 = 新旧顺序"
- **描述**：重启后 L0 列表按字典序装载，反向遍历取到的不再是最新文件。同一个 key 若在多次 flush 中都被写过（`L0_9` 与 `L0_10` 同时含该 key），`get` 可能返回**旧值**——静默的数据错误，且只在跨 9→10、99→100 这类进位后重启才出现。`WALReader.recoverAll` 同一根因：`wal_10.wal` 排在 `wal_2.wal` 之前被重放，而 `MemTable.add` 是无条件覆盖（`MemTable.cj:31-42` 不比较 sequence），后重放的老记录会覆盖新记录
- **建议**：文件名序号零填充到固定宽度（如 `L0_%08d.sst`、`wal_%08d.wal`）并按解析出的数值排序；或 `sort` 改成按 `parseSSTIndexFromPath`/`parseSegmentIndex` 的数值比较。同时给 `MemTable.add` 加"仅当新 sequence 更大才覆盖"的保护，作为二道防线

### [严重][存量] `Store.ttl` 是「读—改—写」三步非原子：并发 `add`/`remove` 会被旧值覆盖、删除被复活

- **位置**：`f_store/src/Store.cj:304-321`（`lookupEntry` → `wal.append` → `memTable.add`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1「检查-然后-写入」，严重度表「数据竞争 / 数据错误」
- **证据**：静态确定 —— `lookupEntry`（`:331-346`）先读 active/immutable/LevelManager，再在 `:317-319` 用**读到的旧 value** 重新 append 并写回 active；两步之间没有任何 CAS、版本或锁。`ConcurrentSkipListMap` 提供 `addIfPresent`（`f_concurrent/src/ConcurrentSkipListMap.cj:457`），此处未用
- **描述**：两个并发访问者：线程 A `ttl(key)`、线程 B `add(key, newValue)`。A 读到 `oldValue` 后 B 完成写入（seq 更大），A 随后 append（seq 更大）并把 `oldValue` 写回 ⇒ **B 的新值被静默丢弃，且 A 拿到了最高 seq，重启也恢复不回来**。若 B 是 `remove`，A 会用旧值把 tombstone 覆盖掉，删除失效。这是 Store 公共 API 上的丢失更新，不是理论竞态
- **建议**：把 `ttl` 改成一条原子更新：在 `MemTable`/CSLM 上提供 `updateIfPresent(key, f: (EntryValue) -> EntryValue)`（或 `compareAndSwap(key, expected, updated)`），在同一临界区内完成"读当前值 + 分配 seq + 写回"。WAL 记录必须在原子写成功之后再落（或接受 WAL 里多余一条记录）；补并发用例（1 线程 `ttl` 循环 + 1 线程 `add` 循环，断言终值等于最后一次 `add`）

> 范围外提示（1 条，属第 1/2 部分文件，不计入本部分统计）：`LevelManager.cj:113-115` 命中 tombstone 时 `return checkExpiry(...)` 得到 `None`，`get()` 在 `:85-90` 继续查下一层 ⇒ **删除标记不会截断下探，已删除的 key 会从更深层返回旧值**。位置在 `LevelManager.cj`，但症状由 `Store.get`/`contains` 直接暴露，请合并时与第 2 部分对齐。

### [一般][存量] `SSTable.write` 的有序性校验放在落盘之后：越序记录已写入并计入 index/count 才抛异常

- **位置**：`f_store/src/SSTable.cj:178-196`（`file.write(buf)` 在 `:179`，`if (key < lastKey) throw` 在 `:192-196`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「错误处理缺失 / 状态不一致」、§3「半成品校验」
- **证据**：静态确定 —— 抛异常前已完成 `file.write`、`indexEntries.add`、`bloomFilter.add`、`entryCount++`、`currentOffset/fileSize/dataBlockSize` 累加；异常后对象仍处 Writing 状态，统计量已污染
- **描述**：校验本应在写入前做（`maxKey` 在 `:192` 之前已是上一个 key）。当前形态下，越序时磁盘上已留下一条破坏有序性的记录；若调用方捕获异常后继续 `finishWrite`，产出的 SSTable 索引与数据顺序不一致，`binarySearchIndex` 会漏块。`writeStreamToSSTables` 会删文件兜底（`store_func.cj:136-165`），但 `SSTable` 也是可直接使用的内部 API（测试即如此）
- **建议**：把顺序校验上移到 `:151` 之后、任何写入之前，并保持"校验失败不改任何状态"；同时给 `write` 留一条「越序不抛、由调用方保证」的注释或参数，避免校验语义含糊

### [一般][存量] `openFromFile` 不校验 Footer 里的 `index_offset`/`index_size`，损坏文件可触发巨额预分配

- **位置**：`f_store/src/SSTable.cj:381-395`（`idxOff`/`idxSz` 直接用于 `Array<Byte>(idxSz)` 与 `seek`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §5「按不可信长度预分配」、§11「缺少边界校验」
- **证据**：静态确定 —— 同一函数对 `bloomSz` 有 `0 <= bloomSz <= MAX_SSTABLE_SIZE` 校验（`:414-416`），对 `idxSz`/`idxOff` 完全没有；`file.read(indexBuf)` 的返回值也被忽略（`:395`），短读后剩余字节保持 0，`readInt64LE(indexBuf, 0)` 会得到 count=0 或垃圾
- **描述**：`idxSz` 为负 → 构造抛非预期异常；为正的巨值（例如 2^40）→ `Array<Byte>` 直接申请，进程 OOM；`idxOff` 越界 → `seek` 抛异常或读到非索引区域。崩溃遗留的半截文件、被外部截断的文件都会走到这里。SST 文件是本地数据，但"损坏文件不应把进程打挂"是本模块自己已有的目标（`:405-407` 有 keyLen 校验、`scanBuffer` 有帧校验）
- **建议**：与 `bloomSz` 对齐：`if (idxSz < 8 || idxSz > MAX_SSTABLE_SIZE || idxOff < 0 || idxOff + idxSz > fileLen) throw`；并检查 `file.read` 返回值，短读按损坏处理

### [一般][存量] `SSTableIterator.close()` 不置 `done`，关闭后 `next()` 仍用旧 `fd` 读——`fd` 被复用时读到别的文件数据

- **位置**：`f_store/src/SSTableIterator.cj:160-165`（`next` 只判 `done`）、`:278-282`（`close` 只关 File）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「资源不对称 / 契约与实现不符」、§12.1「跨线程资源」
- **证据**：静态确定 —— `fd` 在 `init`（`:72-73`）由 `file.fileDescriptor.fileHandle` 取出并长期持有；`loadBlock`（`:251-259`）直接 `positionedRead(fd, ...)`，**不检查** `file.isClosed()`；注释（`:225-235`）明确写「不需要显式的 isClosed() 检查」，但该结论只对"文件被 unlink"成立，对"迭代器自己被 close、fd 被进程复用"不成立
- **描述**：调用方按 `Resource` 语义 `close()` 之后若仍调到 `next()`（try-with-resource 提前退出、上层循环未及时 break 都会发生），`pread` 落在已关闭/已复用的 fd 上：轻则 `readOk=false` 静默结束，重则读到**另一个文件的同偏移数据**并把它当记录解析——`scanBuffer` 级的帧校验只能降低概率，不能保证不返回脏数据
- **建议**：`close()` 里同时 `done.store(true)`（或加独立 `closed` 原子位），`next()`/`skipBefore()`/`loadBlock()` 进入时先判；Linux 路径在 `positionedRead` 前再确认 `!file.isClosed()`

### [一般][存量] `SSTable.loadAll` 静默跳过损坏/命名不符的文件：整份 SSTable 的数据无声消失

- **位置**：`f_store/src/SSTable.cj:453-459`（`catch (_: Exception) { }`，只有注释）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §3「`catch {}` 静默吞掉异常」、§11「失败路径当成功」
- **证据**：静态确定 —— 循环内 `try { result.add(open(path)) } catch (_: Exception) {}`，无日志、无计数、无返回值区分
- **描述**：magic 不符、文件过短、索引损坏的 SSTable 会被整体丢弃，启动照常成功。上层 `LevelManager.loadExisting` 无从得知少了文件，`totalSSTableCount`、`levelSizes` 也按"少一个文件"计算 ⇒ 该文件内的键在重启后全部查不到，且没有任何可观测信号。这与"损坏数据应被检测"的设计意图（`:405-407`、`scanBuffer` 帧校验）相反
- **建议**：至少记录 `f_log` 错误并统计跳过数量；更稳妥的是把损坏文件重命名成 `.sst.corrupt` 保留现场后再跳过，或在 `LevelManager.loadExisting` 汇总后返回给调用方决定是否拒绝启动

### [一般][存量] `add`/`remove` 的返回值只查 active MemTable：已刷盘/在 immutable 的旧值不返回，与注释契约不符

- **位置**：`f_store/src/Store.cj:101-106`、`:140-145`（注释 `:135` 写「删除键，返回旧值」）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复导致行为漂移」（已有 `lookupEntry` 可用却未复用）
- **证据**：静态确定 —— 两个方法都只取 `memTableManager.getActive().add(...)` 的返回值；`lookupEntry`（`:331-346`）已经实现了完整三层查找，但只被 `ttl` 使用。`testAddOverwrite`/`testRemove` 都只覆盖"值还在 active"的场景
- **描述**：刷盘（8MB 阈值）之后对同一 key `add` 新值，返回 `None` 而非旧值；`remove` 同理返回 `None`。调用方按注释理解会认为"键原本不存在"，据此做业务判断（例如计数、幂等）就会出错。同一模块内 `ttl` 用了完整查找，两条路径语义漂移
- **建议**：返回值改为先 `lookupEntry`（或写入后由 `MemTable.add` 返回 + 未命中时回查 immutable/LevelManager），并在注释里写清"返回最后一个可见的旧值（含已过期/tombstone 时为 `None`）"

### [一般][存量] 入参与返回值都不做防御性拷贝，而 `ByteArray` 的 hash 在构造时预计算：外部复用/改写 buffer 会破坏索引

- **位置**：`f_store/src/Store.cj:97-107`、`:149-170`；`f_store/src/ByteArray.cj:22-30`（`hash` 预计算）；`f_store/src/MemTable.cj:31-42`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §10「仓颉语言特性：值 / 引用语义」、§11「契约与实现不符」
- **证据**：静态确定 —— `ByteArray(key)`（`Store.cj:101`）只包装调用方的 `Array<Byte>` 引用，`hash` 在 `ByteArray.init` 里一次性算出（`ByteArray.cj:29`）；`EntryValue(value, seq)`（`:100`）同样持有调用方数组；`get` 返回的也是内部数组引用（`ByteArray` 值本身是 struct，但 `bytes` 指向同一数组）
- **描述**：调用方复用缓冲区（`bytes.clear(); bytes.append(...)`）后 key 的字节内容变了但 `hashCode()` 不变，CSLM 按 hash 定位、按 `compare` 比较，两者不一致 ⇒ 该节点永久失联（查不到、也无法删除）。返回值侧同理：命中 MemTable 时 `get` 返回的就是内部数组引用（`checkExpiryAndGet` 直接返回 `entry.value`，`:373`），调用方原地改写会改掉内存中的值，并且与已落盘副本不一致
- **建议**：API 注释明确"`key`/`value` 由库接管、调用方不得再修改"，或入口处 `ByteArray(key.bytes.clone())`/`value.clone()`；返回值统一 `clone()`（代价是每次 get 一次拷贝，需与性能取舍一起定，见"待验证假设"）

### [一般][存量] `Store.close()` 无 try/finally：任一步抛异常后 `closed` 已置真，重试直接返回 ⇒ WAL/SSTable 句柄永久泄漏

- **位置**：`f_store/src/Store.cj:246-284`（`:247-249` CAS 后立即返回；`:253-283` 多次可能抛异常的 I/O）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「资源不对称：异常跳过释放」、§3「错误处理缺失」
- **证据**：静态确定 —— `closed.compareAndSwap(false, true)` 在最前；`flushMemTable`（写盘、可能磁盘满）、`wal.sync()`、`levelManager.closeAll()` 都在其后且无 `try/finally`；再次 `close()` 时 CAS 失败直接 `return`（`testCloseIdempotent` 正是这个语义）
- **描述**：磁盘满/权限变化导致 flush 抛异常时：immutable 未清、`wal.sync/close` 未执行、各层 SSTable 未关闭。进程仍在跑就泄漏 fd 与 mmap；此后再也无法通过 `close()` 释放（唯一入口被判为"已关闭"）。`atExit` 里的 `close()` 同样无效
- **建议**：`close()` 用 `try/finally` 保证 `wal.close()` + `levelManager.closeAll()` 一定执行；flush 失败只记录并继续（或把异常收集成 `addSuppressed` 在最后抛出），保持"关闭"本身幂等且尽力而为

### [一般][存量] 每个 `Store` 实例都注册一条 `atExit` 闭包且无法注销：Store 及其 MemTable/SSTable 被钉到进程退出

- **位置**：`f_store/src/Store.cj:86-90`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §5「长期持有：注册表不注销」，mem §6.2；`std.env.atExit` 只有注册没有反注册（`std/env/env_package_api/env_package_funcs.md` §`func atExit(() -> Unit)`）
- **证据**：静态确定 —— 闭包捕获 `this`（调用 `isClosed()`/`close()`），注册后全仓无任何移除路径（该 API 本身不提供）
- **描述**：按目录反复 `Store(dir)` 的场景（测试、多租户切库、重连）每建一个实例就永久多一条回调 + 一个不可回收的 Store（含 active/immutable MemTable 与全部 SSTable 句柄）。`Store_itergration_test.cj` 里大量 `Store(dir)` 正是这种形态，进程内累积
- **建议**：改为进程级只注册一次（`static` 惰性初始化的注册表，`atExit` 遍历仍存活的 Store），或提供 `close()` 时从注册表移除 + 只注册一次回调；最简做法是保留 `atExit` 但只捕获 `WeakRef<Store>`

### [一般][存量] `Store.prefix` 构造中途异常时，已打开的 SSTable 迭代器不会关闭

- **位置**：`f_store/src/Store.cj:199-218`（`:213-215` 循环 `sources.add(PeekableIterator(sst.tailer(prefixBytes)))`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「资源不对称」、§12.1「跨线程资源（文件句柄）」
- **证据**：静态确定 —— `sst.tailer()` 会 `File(path, OpenMode.Read)`（`SSTable.cj:352-355`），随后还要 `guardReadable`（`SSTable.cj:345`）；循环内任一次抛异常（文件被 compaction 关掉、fd 用尽、`guardReadable` 抛 `StoreClosedException`）时，前面已加入 `sources` 的迭代器既没 close 也没交给任何 `Resource`
- **描述**：`PrefixIterator` 只在"耗尽/显式 close"时关源（`PrefixIterator.cj:106-128`）；构造阶段失败时这些 `File` 句柄无人负责，只能等 GC（Cangjie 不保证 finalizer 立即释放 OS 句柄）⇒ fd 泄漏，高并发 prefix 扫描下会碰 `EMFILE`
- **建议**：`prefix()` 用 `try { ... } catch (e) { for (src in sources) { try { src.close() } catch (_) {} }; throw e }` 兜底（与 `Compactor.compact` 的 `finally` 同型），并在 `PrefixIterator` 上加一个"构造失败即关闭"的工厂方法

### [一般][存量] 并发同 key 写入时，WAL 序号顺序与 MemTable 落地顺序不一致 ⇒ 内存终值与重启恢复值不同

- **位置**：`f_store/src/Store.cj:99-101`（`wal.append` 取号 → `memTable.add` 落地，两步之间无同步）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1「检查-然后-写入 / 可见性」、§11「并发正确性」
- **证据**：静态确定 —— 序号由 `WAL.append` 内部的 `sequence.incrFetch()` 决定（`WAL.cj:58`），落地顺序由 CSLM `add` 的调度决定；`MemTable.add` 无条件覆盖，不比较 sequence（`MemTable.cj:31-42`）
- **描述**：线程 A 先取号 1、线程 B 取号 2，B 先落地、A 后落地 ⇒ 内存里留下 seq=1 的 A 值，而 WAL 里 B 是更新的。重启重放后 B 值胜出 ⇒ **同一序列的写入，重启前后读到不同的值**。对"最后一次写生效"的 KV 语义是隐性违约，也让故障排查极难复现
- **建议**：`MemTable.add` 改为"仅当 `entry.sequence >= old.sequence` 才替换"（CSLM 需提供 `compute`/`compareAndSwap`），或在 `Store.add` 里用同一把按 key 分片的锁包住"取号 + 落地"

### [一般][存量] `close()` 与在途 `maybeFlush()` 竞态：`closeAll()` 之后仍可能 `addSSTable`，留下未关闭的句柄与孤儿文件

- **位置**：`f_store/src/Store.cj:263-284`（close 的 swap/flush）与 `:377-390`（`maybeFlush`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §12.1「异步语义 / 取消后仍改状态」、§11「资源生命周期」
- **证据**：待确认 —— 代码路径确定：`add()` 在 `guardOpen()`（`:98`）之后才进入 `wal.append`/`maybeFlush`，`close()` 在 `:247` 就把 `closed` 置真；因此已通过 `guardOpen` 的 `add` 可以在 `close()` 执行 `levelManager.closeAll()`（`:283`）之后完成 `addSSTable`（`:384`）。缺的是实际时序复现与概率
- **描述**：竞争窗口内新增的 SSTable 不会被 `closeAll()` 关闭（它不在 close 的快照里），文件也不会被删；进程继续运行时这些 fd 常驻。极端情况下 `addSSTable` 与 `closeAll` 交错还会让 `totalSSTableCount` 与真实文件不一致
- **建议**：`close()` 末尾在 `closeAll()` 之后再做一次"排空"（`swapActive` + flush + `closeAll` 循环到无可刷），或让 `maybeFlush` 检查 `closed` 并在关闭后改为"只写 WAL 不刷盘"（数据由下次启动的 WAL 恢复保证）

### [一般][存量] `WALReader.readAll` 不对 `valueLen` 设上界：损坏/半截 WAL 头部可触发巨额预分配

- **位置**：`f_store/src/WALReader.cj:44-58`（`valueLen` 只用于算 `totalDataLen`，随后 `Array<Byte>(totalDataLen, ...)`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §5「按不可信长度预分配」、§11「缺少边界校验」
- **证据**：静态确定 —— 同文件对 `keyLen` 有 `0..1MB` 校验（`:46-48`），`valueLen` 只做 `>= 0` 的方向判断（`:49`）；`WALRecord.decode` 反而有完整长度校验（`WALRecord.cj:95-106`），两条解析路径的防护不对等
- **描述**：mmap 写入被撕裂、文件被截断或外部篡改时，`valueLen` 可能是几 GB → `Array<Byte>(huge)` 直接 OOM/抛异常，启动失败且无降级路径（`readAll` 的 `finally` 只关文件）。这与"截断记录应被忽略"（`:38-40`、`:55-57`）的既定策略相矛盾
- **建议**：`if (valueLen < -1 || valueLen > MAX_VALUE_LEN) break`（上界与 SSTable/WAL 的 1MB key 一致，或按段大小限制），并复用 `WALRecord.decode` 的边界逻辑，避免两条路径继续漂移

### [一般][存量] `Store.ttl` 对已过期键会把值"复活"

- **位置**：`f_store/src/Store.cj:304-321`（`lookupEntry` 注释明确"不做过期检查"，`:313-319` 直接重写）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「语义与命名 / 注释不符」；对照 `get`/`contains` 把过期视为不存在（`:349-374`）
- **证据**：静态确定 —— `lookupEntry` 返回 `EntryValue`（含 `expireAt <= now` 的条目），`ttlInternal` 只用 `e.value.isNone()` 过滤 tombstone，没有过期判断
- **描述**：`get(key)` 对已过期的键返回 `None`（逻辑上不存在），但 `ttl(key, 10s)` 会把老值重新写回并延长生命 ⇒ 过期数据被外部一次 `ttl` 调用复活。`testTTLNonExistentKey` 已确立"不存在的键 ttl 是 no-op"的语义，过期键应与之同构
- **建议**：`ttlInternal` 复用 `entryIsAlive(e, now)`，过期即返回；或显式在注释里声明"允许复活过期键"，并让 `get`/`ttl` 语义一致（二者只能选一个）

### [一般][存量] `testWALRecovery` 同时打开同一目录的两个 Store 且不关闭第一个，断言靠偶然成立

- **位置**：`f_store/src/Store_itergration_test.cj:312-329`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「用例与实现契约不符」、§12.1「跨线程资源」
- **证据**：静态确定 —— `store1` 只 `syncWAL()`（`:319`）后就被丢弃（未 `close()`）；`Store(dir)`（`:322`）在 init 里执行 `cleanupOldWALFiles`（`Store.cj:77`）把 `store1` 正在写的 `wal_0.wal` 删掉（fd 已打开，Linux 下写入落到 unlinked inode），随后 `store2` 从自己恢复的数据里读到该 key
- **描述**：这条用例实际上验证的是"同进程双开 + 删别人的 WAL"这种不受支持的场景；`store1` 的 WAL fd 泄漏到测试进程结束，且 `store1` 后续被 `atExit` 关闭时会再写一次已删除文件。真正的断点恢复（单实例、进程被杀）没有被覆盖，测试给出的绿色信号不可信
- **建议**：改为"`store1` 写入 → `syncWAL` → **不 close**，直接放弃对象并在同一进程里用一个新的 `Store` 打开"是不可能的语义；应改为子进程/`fork` 模拟崩溃，或至少 `store1.close()` 后再验证（那就变成 `testCloseReopen`）。若保留双开，必须在用例注释里写清"仅为模拟崩溃、不支持生产双开"，并显式关闭 `store1` 之前的所有句柄

### [轻微][存量] `Store.path` 与 `Store.sequence` 两个字段只写不读

- **位置**：`f_store/src/Store.cj:26,32`（声明）、`:44,73`（赋值）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1「读了不用 / 死配置字段」
- **证据**：静态确定 —— 全仓搜 `this.path` / `this.sequence` 在 `Store.cj` 内各只有 1 处（赋值），无任何读取；`Store.cj` 里出现的 `entry.sequence` 是 `EntryValue` 的字段，不是 `Store.sequence`
- **描述**：`sequence` 字段看起来是"打算在 Store 层维护全局序号"，实际序号完全由 `WAL.sequence` 决定（见 #2 的根因之一）；留着会误导后续维护者以为 Store 层有序号状态
- **建议**：删除两个字段；若确实需要 `path`，改用 `private` 且被 `toString`/日志使用，否则一并删掉

### [轻微][存量] `SSTableIterator.startKey` 字段只赋值不读

- **位置**：`f_store/src/SSTableIterator.cj:32,38`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1「读了不用」
- **证据**：静态确定 —— `init` 的形参 `startKey` 在 `:39`、`:77` 被直接使用，字段 `this.startKey` 全仓零读取
- **描述**：字段无任何消费者，属于把构造参数顺手存下来的残留；每实例多 8~16 字节，且让"迭代器持有起始键"的语义看起来有意义
- **建议**：删字段，或把它用于 `toString`/调试输出

### [轻微][存量] `imports.cj` 的 `internal import std.binary.*` 无任何使用

- **位置**：`f_store/src/imports.cj:19`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 全模块搜 `LittleEndian|BigEndian|std.binary` 只有该 import 行命中；字节序读写已全部手写在 `store_func.cj:20-74`
- **描述**：无用 import 会掩盖"其实没用标准库二进制接口"的事实，也让包级 import 清单失真
- **建议**：删除该行

### [轻微][存量] 两处不可达的防御分支

- **位置**：`f_store/src/SSTable.cj:261-264`（`metadata ?? SSTableMetadata(...)`）、`:539-542`（`if (headerEnd > blockSize) break`）；同型 `f_store/src/SSTableIterator.cj:104-106`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1「恒真恒假分支 / Option 上已被上游保证 Some 的 None 分支」
- **证据**：静态确定 —— `metadata` 只在 `finishWrite`（`:238`）与读取构造（`:135`）被赋值，而 `guardReadable()` 只在 `STATE_READABLE` 放行，该状态只由这两个路径设置 ⇒ `??` 右支永不执行；`offset + 32 <= blockSize` 已由循环条件（`:523`）保证，`headerEnd > blockSize` 恒假（`SSTableIterator.cj:86` 的 `offsetInBlock + 32 > blockData.size` 同理）
- **描述**：不可达分支不是错误，但会让人误以为存在"metadata 缺失"与"头部越界"两条真实路径，降低帧校验代码的可读性
- **建议**：删掉或改成 `assert`/注释说明"上游已保证"

### [轻微][存量] `SSTableMerger` 与 `PrefixIterator` 是同一套多路归并骨架的两份实现

- **位置**：`f_store/src/SSTableMerger.cj:62-118` / `f_store/src/PrefixIterator.cj:42-102`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2「换控制流 / 近似重复」
- **证据**：静态确定 —— 两处逐段对齐：①从堆弹最小 key；②取该源当前条目并 `peek` 重入堆；③`while peek == currentKey` 收集同 key 源取最大 sequence；④过期过滤；⑤tombstone 处理。差异只有三点：`PrefixIterator` 多一个 `startsWith` 终止条件、tombstone 一律跳过（`SSTableMerger` 看 `isBottomLevel`）、用 `drained: Bool` 而非 `AtomicBool`
- **描述**：差异都是业务要求（不是重复误报），但骨架复制意味着"同 key 取最大 sequence"这条关键规则要改两遍；`SSTableMerger` 里 `sources[idx].next()` 返回 `None` 时直接 `continue` 丢掉该 key 的兜底，`PrefixIterator` 则没有这个分支——已经是漂移
- **建议**：抽一个 `mergeByKey(sources, predicate: (ByteArray) -> Bool, skipTombstone: Bool)` 内部实现（或用 `SSTableMerger` + 前缀过滤装饰器），把"同 key 取最大 seq"收敛到一处；差异用参数显式表达

### [轻微][存量] WAL 记录布局在四处各写一遍，校验强度不一致

- **位置**：`f_store/src/WAL.cj:91-132`（`encodeDirect`）、`f_store/src/WALRecord.cj:49-76`（`encode`）、`:79-125`（`decode`）、`f_store/src/WALReader.cj:36-75`（`readAll` 手工解析）、`f_store/src/WALRecordCodec.cj:21-40`（`computeChecksum` 再拼一遍 payload）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2「字面量复制 / 近似重复 + 一处少边界判断」
- **证据**：静态确定 —— `36`/`32` 头长、`checksum(4)+sequence(8)+key_len(8)+value_len(8)+expire_at(8)` 的字段序在 5 个函数里各写一次；`WALRecord.decode` 校验 `keyLen<=1MB && valueLen>=-1`，`WALReader.readAll` 只校验 `keyLen`（见 #17），`encodeDirect`/`encode` 完全不校验
- **描述**：任何一处格式调整（例如新增 `flags` 字段）需要同步改 5 个位置，漏改即产生"写进去读不出来"的静默损坏；`decode` 与 `readAll` 的校验差异已经是真实缺陷
- **建议**：把"写头/读头/算 CRC/校验字段"收敛到 `WALRecordCodec` 的 4 个函数（`headerSize`、`encodeHeader`、`decodeHeader`、`validate`），`readAll` 改为"读头 → `validate` → 读 payload → `WALRecord.decode` 校验 CRC"

### [轻微][存量] `Store.get` / `contains` / `lookupEntry` 是同一套三层查找的三份拷贝

- **位置**：`f_store/src/Store.cj:149-170`、`:173-194`、`:331-346`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §2「只改类型名 / 换控制流」
- **证据**：静态确定 —— 三者都是 active → immutable → LevelManager 的顺序查找，差异只在命中后处理：`get` 走 `checkExpiryAndGet`、`contains` 走 `entryIsAlive`、`lookupEntry` 原样返回；`checkExpiryAndGet`（`:362-374`）与 `entryIsAlive`（`:349-359`）又是同一判定逻辑的两种输出形态
- **描述**：新增一层存储（例如 block cache）时必须改三处；#10（add/remove 只查 active）与 #18（ttl 复活过期键）都是"该复用未复用"造成的语义漂移
- **建议**：收敛成 `lookupVisible(key, now): ?EntryValue`（统一做过期/tombstone 判定）+ `lookupRaw(key)`，`get`/`contains`/`ttl` 都基于这两个；返回值语义差异用参数或薄包装表达

### [轻微][存量] `WALRecord_test` 的两条边界用例字节偏移算错，没有真正覆盖 1MB 边界

- **位置**：`f_store/src/WALRecord_test.cj:152-161`（`walRecordDecodeOversizedKeyLen`）、`:163-174`（`walRecordDecodeMaxKeyLenOK`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11「用例与注释不符」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `key_len` 从 offset 12 开始小端存放，`bytes[15]` 是**第 4 字节（bit 24-31）**：写 `0x10` 得到的是 `0x1000_0000 = 256MB`，不是注释说的 `0x0010_0000 = 1MB+1`；`walRecordDecodeMaxKeyLenOK` 里 `total = 36 + 1MB` 而 keyLen=256MB ⇒ 走的是"长度不足"分支直接 `return None`，注释"length validation should pass"与实际分支相反
- **描述**：两条用例都返回 `None`，断言成立但**理由错了**：真正要覆盖的"keyLen 恰好 1MB 应通过长度校验、仅 CRC 失败"完全没被执行；将来把 `keyLen > 1MB` 的上限改错也不会被这两条用例发现
- **建议**：修正偏移（1MB+1 = `0x0010_0001`，低字节写 `0x01`、第 3 字节写 `0x10`），并断言"未被长度校验拒绝"的独立信号（例如单独暴露 `validateLengths` 或对比 `decode` 在 CRC 正确时的成功路径）

### [轻微][存量] `Store_bench` 的 `@Bench` 体内含 1000 条预热写入，测的是"建库 + 操作"；`benchMixed` 还有未使用变量

- **位置**：`f_store/src/Store_bench.cj:40-109`（`benchGet`/`benchRemove`/`benchTTL` 等）、`:162-163`（`running`/`N`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §1「未使用局部变量」、§6.1「微基准代表生产 / 基准方法学」
- **证据**：静态确定 —— 每个 `@Bench` 方法体都包含 `for (i in 0..1000) { store.add(...) }` 的装载阶段，`@Bench` 度量的整段（含 `Store` 构造、WAL 建段、目录删除）；`benchMixed` 里 `let N = 4` 声明后再无使用（后续 5 个 `spawn` 直接 `futures.add`）
- **描述**：这些数字不能用来推断单次 `get`/`ttl` 的耗时（被装载阶段淹没），也不能作为"优化前后对比"的基线；`N` 与实际并发度（5）不一致，读者会误判压测并发
- **建议**：装载移到 `@Bench` 之外的 setup（或用 `@Bench[start in ...]` 包裹被测操作），删除 `N` 或改成真正控制 spawn 数量；基线结论必须 `-O2` 采集

### [轻微][存量] `cleanupRotatedWALFiles` 静默吞掉删除失败：旧 WAL 会无限累积

- **位置**：`f_store/src/Store.cj:393-402`
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §3「`catch {}` 静默吞异常」、§5「磁盘/句柄无界增长」
- **证据**：静态确定 —— `takeOldFiles()` 已把路径从内部列表取走（`WAL.cj:71-73`），删除失败后该文件既不在待删列表里也不会被重试，且无日志
- **描述**：权限/占用导致 `remove` 失败时，旧段永久留在 `wal/` 且不再有任何清理机会（列表已清空）⇒ 磁盘随轮转线性增长，重启时 `recoverAll` 还会把这些老段全部重放（叠加 #4 的顺序问题）
- **建议**：失败的文件重新放回待删列表（`WAL` 提供 `requeue`），或直接在 `Store` 侧保留 `pendingDelete` 集合并每次 `maybeFlush` 重试；失败至少记一条 `f_log` warn

## 优化可行性方案

### [堆内存] Data Block 读取缓冲按调用/按块重分配

- **现状**：`SSTable.get` 每次调用 `Array<Byte>(blockSize)`（`SSTable.cj:308`、`:330`，blockSize ≤4KB），一次 get 一个临时数组；`SSTableIterator.loadBlock` 每块再分配一次（`SSTableIterator.cj:249`）。全量遍历一个 64MB SSTable ≈ 1.6 万次 4KB 分配，全部立即死亡
- **方案**：把块缓冲改成 `ThreadLocal<Array<Byte>>` 按需扩容复用（或 `SSTable` 实例上持有单块 scratch，Linux 路径下 pread 到 scratch 后立即扫描）；`get` 的返回值仍需拷贝（调用方持有），只复用中间缓冲
- **预期**：get/遍历路径的临时分配从"每块 1 次 4KB"降到"每线程 1 次稳态"，GC 次数与峰值随之下降；具体字节量与 GC 占比需实测
- **代价**：scratch 常驻内存 = 线程数 × 4KB；`get` 的临界区仍要独占 scratch ⇒ 同实例并发 get 不能共享同一块（可每实例每线程一份，或维持现有 `getLock` 串行语义）
- **验证**：`cjpm bench -O2`（get 混合负载、全量迭代）前后对照 + `getAllocatedHeapSize()` 差值、GC 次数、p99 延迟；同机同输入取中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 归并/遍历路径为每个 key 计算一次 `HashBuilder`，而该 hash 在归并中从未使用

- **现状**：`SSTableIterator.next` 用 `ByteArray(kBuf)` 构造键（`SSTableIterator.cj:205-219`），`ByteArray.init` 会 `HashBuilder().append(bytes).build()` 全量遍历字节（`ByteArray.cj:27-30`）；`SSTableMerger`/`PrefixIterator` 只做 `key <`、`key !=` 比较（`SSTableMerger.cj:32-34,80`），从不调用 `hashCode()`。压缩/前缀扫描要过的 key 数是全量数据量级
- **方案**：为迭代器输出引入"无 hash 的键视图"（例如 `ByteArray` 增加 `init(bytes, computeHash!: Bool = true)`，迭代器路径传 `false`，只有真正进 map 时才补算），或让归并内部用 `Array<Byte>` 直接比较
- **预期**：每个 key 省一次 O(len) 遍历；压缩期 CPU 与分配（8 字节 hash 字段随之可省）下降，幅度需 profile 证明
- **代价**：新增构造重载，`ByteArray` 的 struct 不变量从"hash 一定有效"变为"可能未算"，需要 `hashCode()` 里惰性补算或断言，容易踩坑
- **验证**：`cjprof record` 跑"10 万 key 全量压缩"场景，对比 `HashBuilder.append` 自耗时占比；`cjpm bench -O2` 前后对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] WAL 恢复期逐条重建 payload 计算 CRC，且 key/value 各复制两次

- **现状**：`WALReader.readAll` 先 `Array<Byte>(totalDataLen)` 读入，再复制到 `keyBytes`、`valueBytes`（`WALReader.cj:52-67`），随后 `WALRecordCodec.computeChecksum` 又拼一份 `32+key+value` 的临时数组算 CRC（`WALRecordCodec.cj:26-39`）⇒ 每条记录 3 次分配 + 2 次全量拷贝（外加 `WALRecord` 构造里再算一次 CRC，`WALRecord.cj:37` 其实被 `:120` 的显式校验覆盖）
- **方案**：CRC 直接对"已读入的 `data` 缓冲"（或对 header + 分段 `crc32` 增量）计算，去掉 payload 重建；key/value 用切片视图传给 `MemTable`（`ByteArray` 已是引用包装），或至少合并成一次分配
- **预期**：恢复期分配次数与拷贝字节数约降 2/3；启动耗时的改善量取决于 WAL 大小（64MB 段 ≈ 170 万条小记录）
- **代价**：CRC 覆盖范围必须与写路径严格一致（写路径覆盖 `sequence+key_len+value_len+expire_at+key+value`，不含 checksum），改实现要配等价性用例
- **验证**：造 64MB WAL，测量 `Store(dir)` 构造耗时与 `getAllocatedHeapSize()` 峰值，改前改后各 5 轮取中位数；`cjprof` 看 `computeChecksum` 占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [锁粒度] `SSTable.getLock` 把所有并发点查串行化，而 `pread` 本身无共享偏移

- **现状**：`readBlockAndScan` 在 `synchronized(getLock)` 内做 `positionedRead`（I/O）+ `scanBuffer`（O(block) 扫描）（`SSTable.cj:305-337`）。锁的唯一目的是防 `close()` 释放 fd 后被复用（`:78` 注释）；但 `getLock` 是**实例级单锁**，同层多个 key 的并发读在同一文件上完全串行，热 SSTable 成为并行度上限（`LevelManager.getInLevel` L0 从最新文件开始反查，热点集中）
- **方案**：把"fd 生命周期"与"读"解耦：①引用计数 —— `close()` 等待在途读归零再关文件（`AtomicInt64` + 条件等待），读路径无锁；②或改为不共享 fd：每次 `get` 自己 `open`/`pread`/`close`（多一次 syscall，换掉锁）；③或沿用 `getLock` 但按 block 分片（多把锁），因为不同 block 的 pread 互不干扰
- **预期**：并发点查吞吐随线程数提升（上限由 I/O 与 CPU 决定），p99 不再被锁队列拉长；具体倍数必须实测
- **代价**：①引入引用计数后 `close()` 可能阻塞，需处理"读到一半被关"的语义；②每次 open 的成本在 page-cache 命中场景约 1~2µs 级，可能抵消收益；③分片锁要保证 `close` 时能拿到全部锁
- **验证**：8/16 线程对同一 SSTable 做混合点查（命中/未命中各半），记录吞吐、p50/p99、线程 BLOCKED 占比；`cjpm bench -O2` 同机对照
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 本部分未提供 profile / bench 数据，以下均为待补数据的假设，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次 `get` 的 4KB 块缓冲分配是 GC 压力与 p99 抖动的主要来源 | `f_store/src/SSTable.cj:308,330` | 分配速率、GC 次数、自耗时占比 | `cjprof record` 跑 10 万次混合点查（命中率 50%），看 `Array` 分配与 GC 线程时间；同时记 `getAllocatedHeapSize()` |
| 2 | 同一 SSTable 的并发点查在 `getLock` 上排队，吞吐不随线程数增长 | `f_store/src/SSTable.cj:306-326` | 锁等待时长、BLOCKED 占比 | 1/4/8/16 线程各跑 60s 同 key 集合点查，采集吞吐与线程状态（CPU profile 看不到锁竞争） |
| 3 | 刷盘期间 active MemTable 缺少背压，可涨到远高于 8MB 阈值 | `f_store/src/Store.cj:377-390` | 刷盘时长、并发写速率、active 峰值 | 大 value（64KB）持续写 + 慢盘（或人为 delay flush），每 100ms 采样 `getActive().approximateSize()` |
| 4 | 归并路径每 key 的 `HashBuilder` 计算占压缩 CPU 的可见比例 | `f_store/src/SSTableIterator.cj:205-219` | `HashBuilder.append` 自耗时占比 | `cjprof record` 跑"10 万 key 触发 compaction"，看归并栈内 hash 计算占比 |
| 5 | WAL 恢复期的 CRC 重建是启动耗时的主要部分 | `f_store/src/WALReader.cj:52-75`、`WALRecordCodec.cj:26-39` | 64MB WAL 的启动分解耗时 | 预置 64MB WAL，分段计时（读文件 / CRC / MemTable 写入），各 5 轮取中位数 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_store.part3.txt` 一一对应（本部分清单共 20 个文件，均为 `.cj`，无 `.md`）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_store/src/SSTable.cj` | .cj | ✅ | #1 maxKey、#6 校验时序、#7 footer 未校验、#9 loadAll 静默跳过、#4 字典序排序、#23 不可达分支 |
| 2 | `f_store/src/SSTableIterator.cj` | .cj | ✅ | #8 close 后仍用旧 fd、#21 死字段、#24 与 PrefixIterator 重复、#23 不可达分支 |
| 3 | `f_store/src/SSTableMerger.cj` | .cj | ✅ | #24 归并骨架重复；同 key 取最大 seq 的关键规则（#2 的消费方） |
| 4 | `f_store/src/SSTableMetadata.cj` | .cj | ✅ | 纯数据类，8 个字段均有消费方（`maxKey` 的错误来源见 #1） |
| 5 | `f_store/src/SSTable_test.cj` | .cj | ✅ | 覆盖写入/重启/bloom/篡改/并发 get+close；缺"重开后 maxKey 往返"与"最后一块非首键"用例（#1） |
| 6 | `f_store/src/Store.cj` | .cj | ✅ | #2 序号恢复、#3 启动删 WAL、#5 ttl 读改写、#10 返回值契约、#11 不拷贝、#12 close 异常路径、#13 atExit、#14 prefix 泄漏、#15 并发定序、#16 close/maybeFlush 竞态、#18 ttl 复活、#20 死字段、#26 三层查找重复、#29 静默失败 |
| 7 | `f_store/src/StoreClosedException.cj` | .cj | ✅ | 无问题；`public` 对外可达，构造只设消息 |
| 8 | `f_store/src/StoreStream_test.cj` | .cj | ✅ | 只测 `File` 读写，未触及 Store 流式能力（文件名与内容不符），无缺陷 |
| 9 | `f_store/src/Store_bench.cj` | .cj | ✅ | #28 bench 体内含装载、`N` 未使用、并发度 5 与命名不符 |
| 10 | `f_store/src/Store_itergration_test.cj` | .cj | ✅ | #19 双开同目录 Store；TTL/前缀/并发用例断言偏弱（只断言不崩） |
| 11 | `f_store/src/Store_test.cj` | .cj | ✅ | 基本 CRUD/TTL/close 幂等用例正常；未覆盖刷盘后 add/remove 返回值（#10） |
| 12 | `f_store/src/TestTmpDirs_test.cj` | .cj | ✅ | `/tmp/f_store*` 全局清理与 `atExit` 组合合理；并发跑多份测试时会互删目录（轻微，未单列） |
| 13 | `f_store/src/WAL.cj` | .cj | ✅ | #25 布局重复；`encodeDirect` 用线程局部 4KB scratch，`Array` 切片是视图（`std/core/core_package_structs.md` §`func slice`），写入由 `SegmentedLog.append` 同步 `mcopy`，无别名风险 |
| 14 | `f_store/src/WALReader.cj` | .cj | ✅ | #17 valueLen 无上界、#4 文件名字典序重放、#25 手工解析与 `decode` 漂移 |
| 15 | `f_store/src/WALReader_test.cj` | .cj | ✅ | 截断/CRC 损坏/混合恢复用例扎实；未覆盖多段 WAL 的序号顺序（#4） |
| 16 | `f_store/src/WALRecord.cj` | .cj | ✅ | `decode` 边界校验完整（keyLen 上界、溢出、CRC），是本模块校验最严的路径 |
| 17 | `f_store/src/WALRecordCodec.cj` | .cj | ✅ | #25 CRC 覆盖字段重复拼装；校验范围与 `encode` 一致 |
| 18 | `f_store/src/WALRecord_test.cj` | .cj | ✅ | #27 两条 1MB 边界用例字节偏移算错 |
| 19 | `f_store/src/WAL_test.cj` | .cj | ✅ | 轮转/并发/close 竞态用例较完整；`readRecords` 有界读取是有意为之（注释说明），不算重复 |
| 20 | `f_store/src/imports.cj` | .cj | ✅ | #22 `std.binary.*` 未使用；其余 import 均有消费方 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本模块 5 个 `.md` 与其余 17 个 `.cj` 见第 1/2/4 部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：`add`/`remove` 返回值契约（#10）；语言特性：入参/返回值不拷贝 + 预计算 hash（#11）；语义一致性：`ttl` 复活过期键（#18）。设计上分层清晰（WAL / MemTable / LevelManager / SSTable 职责分明），无越权依赖；安全性：无外部输入拼 SQL/命令，SSTable/WAL 解析是本部分唯一的"不可信输入面"，已单列 #7/#17 |
| §1 死代码 | 5 | 机械过完：`Store.path`、`Store.sequence`（#20，全仓 `this.*` 仅赋值）、`SSTableIterator.startKey`（#21）、`imports.cj:19`（#22）、`Store_bench` 的 `N`（#28）；`SSTable`/`WAL`/`WALReader` 的 private 函数（`readBlockAndScan`/`guardWriting`/`binarySearchIndex`/`scanBuffer`/`writeIndexBlock`/`writeBloomFilterBlock`/`writeFooter`/`encodeDirect`/`skipBefore`/`loadBlock`/`setDone`/`computePrefixEnd`/`ttlInternal`…）逐个搜到调用方；`SSTable`/`SSTableIterator`/`WAL` 的 `public close/isClosed` 是 `Resource` 实现，豁免；`StoreClosedException` 是顶层 public（对外契约），不判 |
| §2 重复逻辑 | 3 | 两两比对后确认：`SSTableMerger` vs `PrefixIterator`（#24）、WAL 布局 5 处（#25）、`get`/`contains`/`lookupEntry`（#26）；另核对 `checkExpiryAndGet` vs `entryIsAlive`（折叠进 #26）与 `WAL_test.readRecords` vs `WALReader.readAll`（测试有帮助里有界读取的理由，属误报边界，不报）；`SSTable.scanBuffer` 与 `SSTableIterator.next` 的帧解析是"近似重复 + 一处少判断"，已并入 #25 的结论面 |
| §3 空实现 | 2 | #9（`loadAll` 空 `catch` 吞掉损坏文件）、#29（`cleanupRotatedWALFiles` 空 `catch`）；无 `TODO`/`FIXME`/`throw Unsupported`；`Store` 无空方法 |
| §4 栈溢出 | 0 | 本部分无递归：`scanBuffer`/`skipBefore`/`next`/`Merger.next` 全是显式循环；`computePrefixEnd` 是 O(len) 循环。`ByteArray.compare`、`startsWith` 均为单层循环 |
| §5 OOM | 3 | #7（`idxSz` 巨额预分配）、#17（`valueLen` 无上界）、#13（`atExit` 长期持有 Store 及其全部 SSTable）。`SSTable.get` 的 `blockSize` 有 `<= MAX_SSTABLE_SIZE` 上界，未列入；active MemTable 刷盘期膨胀无数据，列待验证假设 #3 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，任何"这里是热点"的结论都不成立；锁内 I/O、每 get 分配、每 key hash 计算三条线索已进优化方案与待验证假设 |
| §6.2 大粒度锁 | 1 | `SSTable.getLock` 临界区内含 `positionedRead`（I/O）+ `scanBuffer`，见优化方案 [锁粒度]；该锁是 `close` 竞态的必需手段，判"可否缩小/去掉"而非"该不该有" |
| §6.3 并发串行 | 1 | 同一 SSTable 的所有并发点查被实例级单锁串行，并行度上限 = 1/SSTable；`Store.add` 的刷盘在写线程内同步执行（`maybeFlush`）也会把单写线程阻塞一个刷盘周期，属设计取舍，未单列 |
| §6.4 低效算法 | 0 | 遍历/归并都是单层 + 堆，`binarySearchIndex` 是 O(log n)；`skipBefore` 只在定位块内线性跳过；未发现双层循环、`contains` 热路径、队头删除等形态 |
| §7 降堆内存方案 | 1 | Data Block 缓冲复用（见优化方案 [堆内存]）；`get` 返回值拷贝的必要性（#11 的安全修法会新增拷贝）与本法收益方向相反，需一起权衡，故未单列第二条 |
| §8 降 CPU 方案 | 2 | 归并路径的无用 hash（优化方案 2）、WAL 恢复期 CRC 重建与双拷贝（优化方案 3） |
| §9 local mode 可行性 | 0 | 本部分所有产物都逃逸：`scanBuffer` 的 value 要返回给调用方、`SSTable.write` 的 buf 要写盘、WAL scratch 是线程局部长期对象；`--enable-local-mode` 还要求全依赖同版本 SDK 编译，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 19 | 5 条严重 + 14 条一般，全部为存量（工作区无 diff）。重点核对过：SSTable 写入/重开的边界（空表、越序、篡改、footer 缺失）、`Store` 的 CRUD 边界（空 key/value、过期键、tombstone）、WAL 的截断与 CRC、close/重启路径的句柄释放；每条均给了函数级位置与触发条件 |
| §12 并发安全与锁粒度 | 3 | #5（ttl 读改写丢失更新）、#15（`add` 的取号与落地非原子）、#16（close 与 maybeFlush 竞态）；共享路径已指明：`Store` 是 public 单实例、`add/get/ttl/prefix` 被任意线程调用，`MemTable`/`LevelManager` 内部无锁但依赖 CSLM/AtomicReference。锁粒度另见 §6.2 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`，README 一致性由第 1/4 部分负责；代码侧未见"承诺未实现"——`Store` 的 public 方法均有实现，无 `TODO` 占位、无未接线的配置项（`memFlushThreshold` 为硬编码常量，属可配置性建议，未单列） |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个 `.cj` 全部读完；`.md` 5 个属第 1/4 部分，不在本部分统计 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 14 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 1 / 2（另 1 条锁粒度） |

## 总评

这部分的代码密度和工程质量明显高于仓库平均水平：SSTable 有完整的帧校验与篡改用例、WAL 用 `SegmentedLog` 把 mmap/轮转/fsync 收干净、`Store` 的"无锁关键路径"（CSLM + AtomicReference 双缓冲）思路正确，测试也覆盖了崩溃残留、CRC 损坏、并发 get+close 这些难写的场景。真正的风险集中在**跨进程重启这条链**上，而且四条严重问题都在同一处汇聚：

1. 重开文件时 `maxKey` 取错（#1）⇒ 重启后 L1+ 的键查不到；
2. 序列号不从 SSTable 恢复（#2）⇒ 重启后新写入在 compaction 里输给旧值；
3. 恢复完立刻删 WAL（#3）⇒ 重启后到首次刷盘之间崩溃即丢数据；
4. 文件名序号不补零 + 字符串排序（#4）⇒ 重启后 L0 优先序与 WAL 重放顺序都反了。

这四条的共同点是"重启后语义与运行期不一致"，且现有用例恰好都绕过了它们（`testCloseReopen` 只测 active，`testFlushToSSTableAndReopen` 只测单文件单值）。它们必须一起修，否则修好其中一条，另外三条仍会让"重启后数据不对"。第 5 条严重问题 `ttl` 的读改写（#5）是独立的并发缺陷，但同样属于"静默丢写"，建议与 #15 一起用一次原子更新原语解决。

一般级里，#6/#7/#8/#9 是"损坏输入与句柄生命周期"的健壮性缺口（都在已有防护风格的反面，补起来很快）；#10/#18/#26 是同一根因（该复用 `lookupEntry` 却各写一套）造成的契约漂移；#12/#13/#14/#16 是四个句柄/注册表泄漏点；#19 说明测试里存在"假装在测崩溃恢复"的用例，会掩盖上面四条重启类缺陷。

优化方案全部是"待验证假设"：没有 profile/bench 数据，报告里不给任何百分比承诺。可先做的是 #6（校验前移，零成本）与 #9（损坏文件留痕），其余按排期在补齐基线后再决定。

本部分存量缺陷 29 条（严重 5 / 一般 14 / 轻微 10），是否纳入修复待用户决定。
