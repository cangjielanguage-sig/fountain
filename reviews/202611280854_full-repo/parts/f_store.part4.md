# f_store 模块审查报告（模块第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_store`（本部分 1 个 `.cj` + 0 个 `.md`；模块合计 37 个 `.cj` + 5 个 `.md`，其余文件由第 1~3 部分覆盖）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线）。`git blame` 本文件全部落在 2026-10-02 `4be871f2fd`「统一换行符为 LF（CRLF→LF，1293 个文件）」这一格式提交上，无法再向上归因，故本部分所有问题一律记为「存量」
- **审查重点**：存储后端正确性、持久化与一致性、资源生命周期、并发安全、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（分部报告，供主 Agent 与第 1~3 部分合并为 `docs/review/2026-11-28/f_store.md`）

## 发现

### [严重][存量] 全局 SSTable 序号不按目录隔离、恢复时只认可解析文件，可覆盖已存在的 `.sst`（`ReadWrite` 不截断）

- **位置**：`f_store/src/store_func.cj:107`（`let sstableFileSeq = AtomicInt64(0)`，进程级全局）、`:116`（取号）、`:117`（`"${sstDir}/L${level}_${sstIndex}.sst"`）；关联 `f_store/src/LevelManager.cj:45-70`（`loadExisting` 只遍历 `SSTable.loadAll()` 的结果算 `maxSstIndex`，59 行 `parseSSTIndexFromPath`，69 行 `sstableFileSeq.store(maxSstIndex)`）
- **来源**：存量（快照模式无基线；blame `4be871f2fd`）
- **判据**：review-checklist §11「契约与实现不符 / 数据错误」、§12.1「共享可变状态」；文件语义依据 std 文档 `fs/fs_package_api/fs_package_enums.md:43-47`（`OpenMode.ReadWrite` 不存在则创建、**不会截断为零字节**）
- **证据**：静态确定 —— 序号是进程级单例但命名空间是「目录级」；`SSTable.loadAll`（`SSTable.cj:440-461`，454-458 的 `catch (_: Exception)`）对打不开的文件直接跳过，因此损坏/残留文件既不进 `files` 也不进 `maxSstIndex`；新文件用 `File(path, OpenMode.ReadWrite)`（`SSTable.cj:99`）打开，同路径已存在时从偏移 0 覆写且不截断，`openFromFile` 又用真实文件长度定位 footer（`SSTable.cj:372-379`）
- **描述**：两条触发路径，后果都是静默数据损坏：
  1. **同进程多实例**：进程 A 打开 `dir1`（已有 `L0_1..L0_100`，`loadExisting` 把计数器置 100）；同一进程再打开 `dir2`（文件至 `L0_3`）→ `sstableFileSeq.store(3)` 把**全局**计数器改小；A 下一次 flush 取到 4，写 `dir1/L0_4.sst`——该文件已存在，于是从 0 覆写旧文件：新表比旧表短时尾部残留旧数据，`LevelManager` 里旧 `SSTable` 对象的 index/footer 也随之失真，读请求返回错误数据。仓内已有同进程多实例用法（`f_hydra/src/FStoreVectorStore_test.cj:111,117` 对同一路径建两个实例），`f_hydra` / `fdbm` / `f_llm` 都是本模块下游。
  2. **崩溃残留**：flush/compaction 被 kill 后留下半截 `.sst`（其序号是当时最大），重启时它打不开 → 不计入 `maxSstIndex` → 下一个 flush 复用同一序号 → 覆写后尾部残留旧字节 → 新表 footer 读错 → 该表下次启动被跳过；而它的 WAL 轮转文件在 flush 后已被 `cleanupRotatedWALFiles` 删除（`Store.cj:389-403`），数据永久丢失
- **建议**：三处任选其一并配套加断言：①序号改为「目录局部」状态（放进 `LevelManager`，随目录生命周期），`loadExisting` 用 CAS 取大（`fetchMax` 语义）而不是无条件 `store`；②`maxSstIndex` 改为扫描**全部** `L*_*.sst` 文件名的最大值（不依赖能否解析）；③写新表前若路径已存在则先 `remove`/用 `OpenMode.Write`（截断）打开，把「复用序号」从静默损坏降级为可检测的覆盖。补一条「目录里预置半截 `.sst` 后 flush」的用例

### [一般][存量] 空 flush / 满块边界留下 0 字节 `.sst` 孤儿文件，永不回收

- **位置**：`f_store/src/store_func.cj:130-135`（`if (writer.getEntryCount() > 0) {...} else { writer.close() }`）；成因 `f_store/src/SSTable.cj:93-99`（构造即 `File(path, OpenMode.ReadWrite)`，文件当场创建）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「资源不对称」、§3「空分支把错误吃掉」
- **证据**：静态确定 —— `SSTable` 构造即建文件，`close()`（`SSTable.cj:464-472`）只关 fd 不写 footer、不删文件；因此「迭代器 0 条数据」分支必然在磁盘上留一个 0 字节 `L{level}_{seq}.sst`
- **描述**：两条高频路径：①`Store.close()` 的 `swapActive()` 不判空（`MemTableManager.cj:41-56`），关闭前若无新写入，就会把空表交给 `flushMemTable` → 每次正常关停都可能生成一个 0 字节 `.sst`；②满 64MB 恰好切块后循环结束，末尾那个刚 new 出来的 writer 同样是 0 条 → 每个满载表多一个孤儿。0 字节文件在下次启动被 `SSTable.loadAll` 的 `catch` 吞掉（`SSTable.cj:454-458`），所以不是致命错误，但会永久累积、每次启动都白抛一次异常，并为上一条的「序号复用」提供不可解析文件
- **建议**：`else` 分支改为 `writer.close()` 后 `remove(writerPath)`（与 136-165 行清理逻辑一致，失败走 `addSuppressed`）；或把 `SSTable` 改成懒创建（首次 `write` 时再开文件），从根上去掉「空 writer 也落盘」

### [一般][存量] `cleanupOldWALFiles` 静默吞掉删除失败：旧 WAL 残留，下次启动重放旧记录覆盖较新 SSTable

- **位置**：`f_store/src/store_func.cj:216-228`（`223-226` 的 `try { remove(...) } catch (_: Exception) {}`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §3「`catch (_: Exception) {}` 静默吞掉异常」、§11「错误处理缺失 / 数据错误」
- **证据**：静态确定（后果链可完整推导）——`Store.init` 先 `WALReader.recoverAll` 再删旧 WAL 再建新 WAL（`Store.cj:58-80`）；`Store.get` 的读取顺序是 active MemTable → immutable → LevelManager（`Store.cj:149-175`），**不与 SSTable 比较 sequence**
- **描述**：删除失败（权限、只读挂载、Windows 上句柄未释放等）时无日志、无告警，旧 `.wal` 留在目录里。本次会话把内存表刷成 SSTable 并在关停时持久化后，这些旧文件记录的仍是**更旧**的值；下次启动 `recoverAll` 把它们重放进 active MemTable，而读取路径 memtable 优先、`LevelManager.get` 也不比 sequence，于是已删/已改的 key 被**复活成旧值**，且没有任何错误迹象。同时 `Store.sequence` 只由 WAL 的最大 sequence 推导（`Store.cj:58-73`），残留旧 WAL 还会把序号基准压低（见文末范围外提示）
- **建议**：至少 `f_log` 打 error 并带路径；更稳的做法是「删不掉就不建新 WAL / 把该文件改名为 `.wal.stale` 移出扫描范围」，让恢复集与清理集保持同一集合；`cleanupOldWALFiles` 返回失败计数供 `Store.init` 决定是否降级

### [一般][存量] `parseSSTablePathPart` 硬编码 `"/"` 切分路径，非 Linux 分隔符下 level/index 全解析成 0

- **位置**：`f_store/src/store_func.cj:182-199`（`183` 行 `path.split("/")`），调用点 `:202-209`；受影响消费方 `SSTable.cj:432`（level）、`LevelManager.cj:59`（index 恢复）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「边界 / 契约与实现不符」；支持面依据 `f_store/README.md:428`（明列「非 Linux 平台：seek+read 需独占 File 对象」，即非 Linux 是声明支持的平台）、`store_func.cj:91-95`（为此还实现了 `@When[os != "Linux"]` 的 `positionedRead`）
- **证据**：待确认 —— 缺「非 Linux 下 `FileInfo.path.toString()` 使用哪种分隔符」的实测；若为 `\`，`split("/")` 只得到 1 段，`fileName` 是整条路径，`startsWith("L")` 为假，两个解析函数恒返回 0
- **描述**：一旦成立，重启后所有 SSTable 的 level 都是 0（分层失效，L0 反向遍历顺序取代层级顺序，可能读到旧值），且 `parseSSTIndexFromPath` 全为 0 → `sstableFileSeq` 不恢复 → 直接触发上面第 1 条的覆盖路径。仓库其余位置（`WAL`、`sstDir` 拼接）都用 `/` 拼路径，Windows 可接受；唯独这里做的是**解析**，必须认实际分隔符
- **建议**：改用 `Path(path).fileName` 取文件名，或 `lastIndexOf("/")` 与 `lastIndexOf("\\")` 取较大者；加一条「`C:\\tmp\\L3_7.sst` 解析出 level=3 / index=7」的跨平台用例

### [轻微][存量] 文件名解析失败静默返回 0，与合法序号 0 不可区分

- **位置**：`f_store/src/store_func.cj:190-198`（`195` 行 `catch (_: Exception) { return 0 }`；`192` 行 `size >= 2` 不满足时静默落 `0`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §3「`case None => ()` 式兜底把错误吃掉」、§11「错误处理缺失」
- **证据**：静态确定 —— 函数返回 `Int64` 而非 `?Int64`，调用方无法区分「解析出 0」与「解析失败」，也没有任何日志
- **描述**：`Int64.parse` 抛出（如 `L0_abc.sst`）、缺下划线、文件名不以 `L` 开头，全部落到 0。对 `parseLevelFromSSTablePath` 而言意味着「归档到 L0」，对 `parseSSTIndexFromPath` 意味着「不参与 max 计算」，后者正是第 1 条覆盖问题的输入
- **建议**：返回 `?Int64`，`parseLevelFromSSTablePath` 对 `None` 记 warn 并保留文件不动；测试里已有 `parseSSTablePathHelpers`（`SSTable_test.cj:1013-1027`），补一条非法名断言

### [轻微][存量] 小端读写助手有逐行重复的实现（仅类型名不同）

- **位置**：`f_store/src/store_func.cj:28-53`（`writeInt64LE` / `readInt64LE`）与 `:57-74`（`writeUInt64LE` / `readUInt64LE`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §2「只改类型名：两个函数体逐行对齐」
- **证据**：静态确定 —— `writeInt64LE` 除首行 `let uv = value.toUInt()` 与 8 条 `UInt8((uv >> n) & 0xFFu64)` 之外，与 `writeUInt64LE` 完全一致；`readInt64LE` 是 `readUInt64LE` 的逐位或表达式再加 `.toInt()`
- **描述**：两套字节拼装逻辑各自演进（例如将来改边界检查或加 offset 校验），漂移后 32/64 位与有/无符号路径会出现不一致；`writeUInt64LE`（57 行）上的 `@OverflowWrapping` 也没有必要——该函数只做位移与掩码（移位按语言规范「高位丢弃」，见 `cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/basic_operators.md`「位运算操作符」节），真正需要包装的窄化转换在 `:30` 的 `value.toUInt()` 与 `:52` 的 `v.toInt()`
- **建议**：`writeInt64LE` 转调 `writeUInt64LE(buf, offset, value.toUInt())`、`readInt64LE` 转调 `readUInt64LE(buf, offset).toInt()`，包装注解只留在有窄化转换的两个入口上；32 位与 64 位之间保持独立（宽度不同，属正当差异）

### [轻微][存量] 「遍历目录 + 按扩展名过滤」三处复制，过滤规则会漂移

- **位置**：`f_store/src/store_func.cj:220-228`（`cleanupOldWALFiles` 的 `Directory.walk` + `extensionName == "wal"`）、`f_store/src/WALReader.cj:93-101`（`recoverAll` 同一谓词）、`f_store/src/SSTable.cj:446-451`（`loadAll` 的 `extensionName == "sst"`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §2「字面量复制：同一组过滤条件散落多处」
- **证据**：静态确定 —— 三处结构逐行相同，只有扩展名与后续动作不同；`cleanupOldWALFiles` 与 `WALReader.recoverAll` 必须看到**同一个文件集合**才正确（前者删、后者读）
- **描述**：任何一侧改动（例如排除临时后缀 `.wal.tmp`、跳过子目录、把 `isDirectory()` 判断改成 `isRegular()`）都会让「恢复集 ≠ 清理集」：清理多删会丢未恢复数据，恢复多读会重放本不该读的文件
- **建议**：在 `store_func.cj` 抽 `internal func walkByExtension(dir: String, ext: String): ArrayList<String>`，三处共用；`cleanupOldWALFiles` 与 `recoverAll` 至少共用同一个谓词函数

### [轻微][存量] `positionedRead` 单次 `read` 不处理短读/中断，失败只回 `false`

- **位置**：`f_store/src/store_func.cj:79-95`（Linux 分支 `87-88`：`let n = unsafe { pread(...) }; n == bufSize`；非 Linux 分支 `93-94`：`seek` + `read(buf) == buf.size`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「边界 / 错误处理缺失」
- **证据**：待确认 —— 需确认 cjc 运行时安装的信号处理器是否带 `SA_RESTART`，以及在本地文件上 `pread` 是否可能出现短读；短读时 `n < bufSize` 会被当作失败
- **描述**：调用方把 `false` 直接翻译成异常（`SSTable.cj:322` `throw Exception("SSTable I/O error: positionedRead failed")`、`SSTableIterator.cj:262-267` 直接 `setDone()` 结束迭代），于是一次可重试的短读会变成「读失败」或「迭代提前结束」——后者更危险，`prefix` 遍历会静默少返回数据。另外 `false` 不含 errno，排障只能看字符串
- **建议**：循环 `pread` 直到读满 `bufSize` 或 `n <= 0`（`n == 0` 才是 EOF，`n < 0` 才是错误，`EINTR` 重试）；返回值改为「已读字节数 + 错误」或抛出携带 errno 的明确异常，调用方据此区分「短读」「EOF」「IO 错误」

## 优化可行性方案

> 本部分无任何 bench / profile 基线（`scope.md` 的「已有性能资料」是 local mode 文档，不含本模块数据），因此不提优化方案，性能线索全部下沉到「待验证假设」。统计为 0 / 0。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | flush/compaction 写入路径「每条记录一次 `writer.write` + 一次 `Array<Byte>` 分配」是刷盘 CPU 与 syscall 的主要开销，用户态批量缓冲可摊薄 | `store_func.cj:120-122` → `SSTable.cj:150-200`（每记录 `file.write(buf)`） | 该函数自耗时占比、`write` syscall 次数/秒、单条 50B 与 1KB 记录的差异 | `cjprof record` 跑一次 1GB memtable flush（记录 ~50B，并发 1），对比「每 64KB 聚合一次 `file.write`」的改后版本；同时给 `-O2` 中位数与离散程度 |
| 2 | 启动期对 `walDir` / `sstDir` 做全目录 `walk`（`cleanupOldWALFiles`、`recoverAll`、`loadAll` 各一次），加上每文件两次 `split` + `Int64.parse`，在文件数上万时拉长 `Store.init` | `store_func.cj:220-228`、`:182-199` | 文件数与 `Store.init` 耗时曲线 | 造 1k / 10k / 100k 个空 `.sst` 与 `.wal`，计时 `Store.init`（分段：recover / loadExisting / cleanup） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_store/src/store_func.cj` | .cj | ✅ | 229 行，逐函数读完；发现 1~8 全在本文件，另追了 `SSTable.cj` / `LevelManager.cj` / `Store.cj` / `WALReader.cj` / `Compaction.cj` / `MemTable.cj` / `SSTableMerger.cj` 作为调用链与语义证据（不计入本部分覆盖） |

合计：`.cj` 1 个 / `.md` 0 个 / 共 1 个，全部读完（本部分清单仅此一个文件）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：#1（序号覆盖）、#3（旧 WAL 重放致读错）、#4（路径解析）；安全性无外部输入拼接、无凭据；语言特性：`@OverflowWrapping` 依据语言文档核对（移位不检查溢出，转换检查），未发现误用 |
| §1 死代码 | 0 | 机械过了一遍：`private parseSSTablePathPart` 两处内部调用；`writeUInt32LE/readUInt32LE`（`WAL.cj:128`、`WALReader.cj:41`）、`write/readInt64LE`（`SSTable`/`WAL`/`WALRecord`/`WALReader` 多处）、`write/readUInt64LE`（`SSTable.cj:619/386`）、`positionedRead` 两个平台版本（`SSTable.cj:311`、`SSTableIterator.cj:255`）、`flushMemTable`（`Store.cj:254,264,273,382` + 测试）、`writeStreamToSSTables`（`Compaction.cj:175` + 测试）、`parseLevelFromSSTablePath` / `parseSSTIndexFromPath`（`SSTable.cj:432` / `LevelManager.cj:59`）、`cleanupOldWALFiles`（`Store.cj:77`）、`sstableFileSeq`（`LevelManager.cj:59-69`）均有引用；`public class SSTableWritingException` 顶层 public 对外可达且被 throw，不判死代码；`@When` 两个 `positionedRead` 是平台分支，非死代码。无 `return` 后同层语句、无未用局部变量 |
| §2 重复逻辑 | 2 | #6（`writeInt64LE`/`writeUInt64LE`、`readInt64LE`/`readUInt64LE` 逐行同构）、#7（三处目录遍历+扩展名过滤）；同文件内 15 个函数体两两比对，其余差异均为宽度/符号数不同（正当差异） |
| §3 空实现 | 2 | #3（`catch (_: Exception) {}` 吞删除失败）、#5（`catch (_: Exception) { return 0 }` 吞解析失败）；函数体本身无空实现、无 TODO/FIXME |
| §4 栈溢出 | 0 | 本文件无递归、无自引用结构遍历；`writeStreamToSSTables` 是单层 `while` |
| §5 OOM | 0 | `writeStreamToSSTables` 逐条流式写入，`result` 只装 SSTable 句柄（每 64MB 一个），无按报文长度预分配、无全量物化；`parseSSTablePathPart` 只在启动期按文件数分配小数组 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点不成立，线索已写入「待验证假设」#1 |
| §6.2 大粒度锁 | 0 | 本文件无锁；唯一的共享状态是 `AtomicInt64` 计数器（单值原子，不构成临界区） |
| §6.3 并发串行 | 0 | 本文件无 `spawn` / `Future.get`；调用方（flush 在业务线程、compaction 在后台线程）并发进入时不共享可变局部状态 |
| §6.4 低效算法 | 0 | 均为 O(1) 编码、O(1) 取号、O(文件数) 扫描；无嵌套循环、无 `contains` 热路径、无 `remove(at: 0)` |
| §7 降堆内存方案 | 0 | 本文件只持有 SSTable 句柄列表与逐条记录缓冲；无长生命周期大对象、无副本可去（记录缓冲属 `SSTable.write`，不在本部分） |
| §8 降 CPU 方案 | 0 | 无基线数据；候选（每记录一次 syscall）已列「待验证假设」#1，按规则不进方案 |
| §9 local mode 可行性 | 0 | 本文件无函数内大临时对象：`result` 与 `writer` 都逃逸（返回/交给 LevelManager），`parseSSTablePathPart` 的临时 `split` 数组极小，峰值内存收益无法成立 |
| §11 现有代码的 BUG（存量） | 8 | 本部分 8 条发现全部为存量：#1~#8 已逐条核对边界（空目录、0 条数据、路径分隔符、解析失败、短读、删除失败）与错误处理路径；`MemTableManager.swapActive` 不判空、`Store.sequence` 只从 WAL 恢复等跨文件问题见范围外提示 |
| §12 并发安全与锁粒度 | 1 | #1 的「同进程多 Store 共享全局序号」是共享可变状态问题（原子操作保证单次自增安全，但语义上不该跨目录共享；`LevelManager.cj:69` 的无条件 `store` 是跨线程可见性之外的逻辑竞态）。`writeStreamToSSTables` 本身线程封闭，`cleanupOldWALFiles` 只在 `init` 单线程调用；无锁粒度问题 |
| §14 功能完备性与 README 覆盖 | 0 | 本文件唯一 `public` 声明 `SSTableWritingException` 已在 `README.md:385` / `README_en.md:385` 列表中出现；其余均为 internal/private 实现细节，按 §14 不要求写进 README；无承诺未实现、无接线缺失 |
| 文件覆盖（§13 等） | 1/1 | 本部分清单仅 `f_store/src/store_func.cj`，已全读；本部分无 `.md`，§13 文档一致性不适用（README / `doc/**` 由第 1~3 部分覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 3 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 8 条（本部分全部为存量），是否纳入修复待用户决定；P0 候选为第 1 条（序号覆盖可致静默数据损坏）与第 3 条（旧 WAL 重放致旧值复活）。

## 总评

`store_func.cj` 是整个存储栈最底层的「字节编解码 + 刷盘 + 文件名约定 + WAL 清理」工具集，代码量不大（229 行），但承担了两类难以观测的风险：**文件名序号**与**启动期清理**。编码助手（`write*LE`/`read*LE`）实现正确，`@OverflowWrapping` 的用法经语言文档核对无误；异常清理路径（136-165 行）已经有 close/remove/`addSuppressed` 的完整三步处理，历史审查的 FD 泄漏问题确实已修。

真正的问题集中在生命周期边界：①序号是全局状态而命名空间是目录，`loadExisting` 又用非原子的「取当前最大值再 store」，在多实例或崩溃残留场景下会复用文件名，而 `OpenMode.ReadWrite` 不截断把「复用」变成静默损坏——这是本部分唯一的阻塞项；②0 条数据的 flush 会留 0 字节 `.sst`，既污染目录又给①提供输入，修法极简（close 后 remove）；③清理旧 WAL 的 `catch {}` 把删除失败完全吞掉，配合「memtable 优先、不比 sequence」的读路径，会把旧值复活，建议至少补日志并让恢复集与清理集同源。另有一条路径解析的跨平台隐患（`split("/")`）需要在非 Linux 上实测确认后再定级。剩余三条是重复实现与错误处理粒度问题，可以排期处理，不阻塞发布。

**范围外提示**（不计入本部分统计，提请覆盖对应文件的子轮核查）：
1. `f_store/src/Store.cj:58-73`：`Store.sequence` 只从 WAL 记录推导，未取 `SSTableMetadata.sequenceEnd`；而 `SSTableMerger.cj:78-90` 同 key 取最高 sequence——重启后新写入的 sequence 会小于盘上旧记录的 sequence，下一次 compaction 会把旧值「合并」成最新值（延迟性数据回退）。
2. `f_store/src/Compaction.cj:66-88`：`runLoop` 无 `catch`，任何 flush/compaction 异常都会让后台线程静默退出且 `running` 标志不复位（`stop()` 里 `f.get()` 的异常被 `catch (_: Exception) {}` 吞掉），此后 compaction 永久停摆。
3. `f_store/README.md:482`：性能表把 WAL mmap 写入归到 `WAL.cj`, `store_func.cj`，但本文件只有字节编解码与刷盘编排，不含 mmap 写路径，文献引用疑似过期（由 README 所在子轮判定）。
