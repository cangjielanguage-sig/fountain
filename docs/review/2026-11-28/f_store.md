# f_store 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_store`（42 个文件：37 个 .cj + 5 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 4 个分部分报告合并：`parts/f_store.part1..4.md`）

## 发现

<!-- 第 1 部分 -->

### [一般][存量] README 宣称"关键路径完全无锁"，实际追加与点查路径都持有 Mutex

- **位置**：`f_store/README.md:4`、`f_store/README.md:72`、`f_store/README.md:147`、`f_store/README.md:391`、`f_store/README.md:487`（`README_en.md` 同位置 4 / 72 / 147 / 391 / 487）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档承诺与实现相反）；同时命中 §12.1 并发契约、§6.2 锁粒度声明
- **证据**：静态确定 —— `Store.add/remove/ttl` 每次都走 `wal.append()`（`f_store/src/WAL.cj:62`），而 `WAL` 已把 I/O 委托给 `SegmentedLog`，`SegmentedLog.append()` 全程在 `synchronized(appendLock)` 内（`f_io/src/SegmentedLog.cj:198`、`:272-276`）；`Store.get()` 命中 SSTable 时经 `LevelManager` → `SSTable.getDirect()` → `readBlockAndScan()`，Linux 与非 Linux 两条分支都在 `synchronized(getLock)` 内做 pread/seek（`f_store/src/SSTable.cj:306`、`:328`）。README 自己在 `:421` 也写明"`SSTable.get()` 点查询通过 `getLock + pread(fd)` 共享了 fd"，与 `:147` / `:397` 的"无锁点查询"自相矛盾。
- **描述**：`README` 开头、`add`/`get`/`ttl` 各节、并发安全表、稳定性分析共 5 处把"完全无锁"作为模块核心卖点，并把 `-j 8` 基准解释为"验证无锁"。实际语义是：MemTable 与 LevelManager 无锁，但**所有写追加串行在一把 `appendLock` 上**，**同层 SSTable 点查串行在各自 `getLock` 上**。这会让使用者按"写吞吐随核数线性增长"做容量规划，也会误导后续优化方向（真正需要优化的是这两段串行临界区）。
- **建议**：把 `README.md` / `README_en.md` 的表述改为"MemTable 与 LevelManager 无锁；WAL 追加由 `SegmentedLog.appendLock` 串行、SSTable 点查由 `getLock` 串行"，并同步修正 `:487` 的稳定性结论为"未观察到锁竞争"而非"消除了锁竞争"；若要用无锁口径，需先在 `WAL`/`SSTable` 层去掉 Mutex（属第 2–3 部分的改造议题）。

### [一般][存量] README 承诺 `prefix` 迭代器是创建时快照，实际是弱一致性迭代

- **位置**：`f_store/README.md:267`（`README_en.md:267`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（API 语义与实现不符）
- **证据**：静态确定 —— `Store.prefix()` 把 active/immutable MemTable 的 `tailer()` 直接作为数据源（`f_store/src/Store.cj:206`、`:209`），而 `ConcurrentSkipListMap.tailer()` 返回的 `TailEntryIterator` 每步读取 `node.next[0].load()` 与 `node.value.load()`（`f_concurrent/src/ConcurrentSkipListMap.cj:904-919`），是跟随链表的实时读，不复制节点、不冻结版本。
- **描述**：README 写"迭代器在创建时从 MemTable 和 SSTable 获取快照，不受后续写入影响"。SSTable 部分（只读文件）近似成立，但 MemTable 部分不成立：迭代开始后插入到当前位置之后的 key 会被遍历到，已有 key 的值更新也会被读到。按文档写"边遍历边统计"的调用方会得到随写入变化的集合，结果不可复现。
- **建议**：把该条改为"MemTable 源为弱一致性迭代（并发写入可能被看到），SSTable 源为文件快照；需要稳定视图时请在业务层自行物化"，`README_en.md` 同步。

### [一般][存量] `prefix` 的过期过滤用迭代器创建时刻的 `now`，与"过期数据被跳过"承诺冲突，且审查报告前后结论相反

- **位置**：`f_store/README.md:126`、`f_store/README.md:253`（`README_en.md:126`、`:253`）；实现 `f_store/src/PrefixIterator.cj:33`、`:89`；文档冲突 `f_store/doc/审查报告.md:741-775` 与 `:1874-1882`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义与注释/契约不符）、§13（同一文档结论相反）
- **证据**：静态确定 —— `PrefixIterator.init()` 捕获 `this.now = DateTime.now()...`（`:33`），`next()` 用 `expireAt <= this.now` 判断（`:89`）。而 `doc/审查报告.md:741-775` 明确论证"缓存 `now` 会返回已过期的 key，违反正确性，故不优化"，`:1874-1882` 又记为 P2 修复"在 `init()` 中捕获 `this.now`"——同一份文档给出互斥结论，代码采纳了被自己论证为错误的一侧。
- **描述**：README 承诺"过期数据和 tombstone 被跳过"、"过期检查是惰性的（仅在 get/prefix 时检查）"。实际是"按迭代开始时刻判断"：遍历持续期间到期的条目仍会作为有效值返回。`prefix` 是外部驱动的长遍历，TTL 常见于会话/令牌类数据，这条会直接返回已失效的凭证。该行为同时是代码缺陷，代码侧定级与修复归第 2 部分（`PrefixIterator.cj` 属 part2）；本报告按"文档契约与实现冲突"记一般。
- **建议**：恢复 `next()` 内实时取 `now`（或每 N 条刷新一次并写清语义），并删除 `审查报告.md:1874-1882` 的"已修复"记录；若坚持快照语义，则 README 必须改成"以迭代开始时刻为准，可能返回遍历期间到期的条目"。

### [一般][存量] README 模块依赖图缺 `f_io` / `f_collection`，且与开发计划"不依赖 f_io"直接矛盾

- **位置**：`f_store/README.md:6-14`（`README_en.md:6-14`）；`f_store/doc/开发计划.md:47-53`；实际依赖 `f_store/cjpm.toml:25-30`、`f_store/src/imports.cj:35`、`:37`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档过期）、§14.2（关键段落缺失/错误）
- **证据**：静态确定 —— `cjpm.toml` 声明 6 个模块依赖，README 依赖树只列 4 个，缺 `fountain::f_collection`（`PriorityQueue`，`imports.cj:35`）与 `fountain::f_io`（`SegmentedLog`/`LogConfig`，`imports.cj:37`、`WAL.cj:43-51`）。`开发计划.md:47-53` 仍写"不再使用 IOUringStream，f_store 不依赖 fountain::f_io"。此外 README `:10` 把 `mcopy` 列为 f_store 对 f_base 的用途，但生产代码全仓搜不到 `mcopy`（只在 `f_io` 内使用）。
- **描述**：按 README 的依赖图无法解释构建依赖，也无法理解 WAL 的 I/O 实际由谁承担；开发计划的表述则与当前架构相反。新维护者容易误判"WAL 是自研 mmap"或"改 WAL 不涉及 f_io"。
- **建议**：依赖树补上 `f_collection (PriorityQueue)` 与 `f_io (SegmentedLog/LogConfig，承担 WAL mmap+轮转+fsync)`，删掉 `mcopy`；`开发计划.md` 的 Step 2 与"与原方案的主要差异"表同步改为"WAL I/O 委托 `f_io.SegmentedLog`"。

### [一般][存量] README 没有配置/限制段落：刷盘阈值、SSTable 上限、层数、WAL 分段大小全部未文档化

- **位置**：`f_store/README.md`（全文无相关段落，检索 `8MB`/`64MB`/`memFlushThreshold`/`MAX_SSTABLE_SIZE` 均无命中）；实现 `f_store/src/Store.cj:47`、`f_store/src/SSTable.cj:84`、`f_store/src/imports.cj:40`、`f_store/src/WAL.cj:36`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §14.2（缺关键段落：配置项表、限制与注意事项）
- **证据**：静态确定 —— 关键运行参数硬编码：MemTable 刷盘阈值 8MB（`Store.cj:47`）、SSTable 单文件上限 64MB（`SSTable.cj:84`）、层数 `MAX_LEVEL = 7`（`imports.cj:40`）、WAL 分段 64MB（`WAL.cj:36`）。README 只在 `:287` 提到"每 100 次 append fsync"，其余参数均未出现。
- **描述**：使用者无法从文档得知何时触发 flush/compaction、单文件上限、总层数与写放大预期，也无法判断内存峰值与磁盘占用；出现"写入抖动/磁盘暴涨"时缺少对照依据。这些参数还都是编译期常量，README 未说明"不可配置、需改代码重建"。
- **建议**：新增"配置与限制"小节，列出四项参数的当前值、影响面与是否可配；若后续改为可配置，在此表登记键名与默认值。

### [一般][存量] README 的指定测试用例命令不存在，照文档执行会 0 匹配

- **位置**：`f_store/README.md:511`（`README_en.md:511`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（示例跑不通）
- **证据**：静态确定 —— 文档命令为 `cjpm test --filter StoreIntegrationTest.testAddGetBasic`。`StoreIntegrationTest` 存在（`f_store/src/Store_itergration_test.cj:24`），但其首个用例是 `testAddGetRoundTrip`（`:29`），文件内搜不到 `testAddGetBasic`；`testAddGetBasic` 实际属于 `StoreTest`（`f_store/src/Store_test.cj:25`）。
- **描述**：按 README 复制命令会得到"没有匹配用例"，使用者会误以为集成测试缺失或过滤语法失效；这也是文档长期未随测试改名同步的信号。
- **建议**：改为 `cjpm test --filter StoreIntegrationTest.testAddGetRoundTrip`，或 `cjpm test --filter StoreTest.testAddGetBasic`；中英同步。

### [轻微][存量] `doc/开发计划.md` 整体已与实现脱节：死引用 + 旧 I/O 架构 + 全部步骤仍标 ✅

- **位置**：`f_store/doc/开发计划.md:6`（引用不存在的 `./f_store/doc/store.md`）、`:59`、`:89`、`:449`、`:495`、`:779`（引用不存在的 `src/LSM.cj`）、`:171-232`（IOUringStream 版 WAL 设计）、`:951-962`（"与原方案的主要差异"表）；`f_store/doc/审查报告.md:3-4` 同样引用 `store.md`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（链接/路径失效、文档过期）
- **证据**：静态确定 —— `f_store/doc/` 下只有 `审查报告.md`、`开发计划.md`、`架构设计方案.md`，无 `store.md`；`f_store/src/` 无 `LSM.cj`（MemTable/LevelManager 已拆分独立文件）；`WAL.cj:21-23` 明确"基于 `f_io.SegmentedLog`，I/O 全部委托"，与计划中 IOUringStream/`createStoreStream` 方案及 `:951-962` 的差异表相反。
- **描述**：18 个 Step 全部标 ✅，但文件路径、I/O 方案、模块边界都是旧版；新维护者按计划找文件会扑空，按差异表会得出"f_store 自管 std.fs.File 同步 IO"的错误结论。
- **建议**：在文件头标注"历史计划，已归档，以 `架构设计方案.md` 与源码为准"，修正或删除死引用；至少把 Step 2/6 与差异表替换为 SegmentedLog 方案。

### [轻微][存量] README 性能章节的 mmap 优化条目与基准数据早于 SegmentedLog 迁移

- **位置**：`f_store/README.md:440-441`（2026-05-02 基线）、`f_store/README.md:475-482`（优化历程 #6 "WAL mmap 写"，文件列 `WAL.cj`、`store_func.cj`）；`README_en.md` 同位置
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档过期）、§8（性能结论需当前基线）
- **证据**：静态确定 —— `WAL.cj:21-23`、`:62` 已把写入交给 `SegmentedLog`；`store_func.cj` 只剩 `pread` 绑定（`:79-95`），全文无 `mmap`/`munmap`/`memcpy`/`fallocate`。即 #6 条目描述的实现已不在所列文件中（mmap 现在 `f_io/SegmentedLog.cj`），而基准数据采集于迁移前。
- **描述**：性能表被当作当前版本的能力承诺，但被测实现已被替换（WAL I/O、崩溃恢复路径都变了）；#6 的文件归属也会把读者引到错误文件。按审查铁律，这不能作为当前性能结论，只能作为历史数据。
- **建议**：在性能章节标注"数据对应迁移前版本/commit"，迁移后重跑 bench 再更新；#6 的文件列改为 `f_io/SegmentedLog.cj`（或标注"已下沉到 f_io"）。

### [轻微][存量] README 的 init/close 流程与代码细节不符，`Store(Path)` 重载未文档化

- **位置**：`f_store/README.md:48-54`（初始化流程）对照 `f_store/src/Store.cj:69-93`；`f_store/README.md:304-309`（关闭流程）对照 `Store.cj:250-283`；`f_store/README.md:32` 对照 `Store.cj:38`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档与实现不一致）、§14.2（公开 API 未文档化）
- **证据**：静态确定 —— README 初始化步骤 5 写"创建新 WAL 文件，启动后台 Compaction 线程"、步骤 6 写"注册 atExit"，实际顺序是 WAL → Compactor 构造 → `atExit`（`Store.cj:86`）→ `compactor.start()`（`:93`）。关闭流程只列一次 `swapActive`，实际有第二次 swap 用于捕获 flush 期间的并发写（`Store.cj:270-278`）。`public init(path: Path)`（`Store.cj:38`）在 README 中完全没有出现。
- **描述**：流程顺序与二次 swap 是持久化语义的一部分（关闭期并发写的落点），省略会让读者误判"close 只保证一次切换"；Path 重载虽是小 API，但属于对外契约遗漏。
- **建议**：按当前代码重画两张流程图（补二次 swap 与 start 的顺序），在 `init` 小节补一句"也支持 `Store(Path)`"。

### [轻微][存量] `doc/审查报告.md` 统计口径自相矛盾且未标注为历史记录

- **位置**：`f_store/doc/审查报告.md:8`（"共 ~82 个测试用例，全部 122 通过"）、`:1976`（`Store.cj | 401`，当前 403 行）、`:2202-2216`（Round 18/19 "无 P0/P1/P2/P3" 的收尾结论）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档一致性、统计与实现漂移）
- **证据**：静态确定 —— 同一句里给出两个互斥的用例数（~82 与 122）；文件行数与当前 `Store.cj` 不一致；Round 18 声称"未发现任何新的 P0-P4 问题"，紧接着 Round 19 又列出 3 个问题，文档未回填修订。
- **描述**：该文件是 19 轮审查的累积记录，但没有"历史/以当前代码为准"的标注，最后落点又是"代码质量优秀、零缺陷"。读者会把它当作当前状态的结论，而本轮在文档层已发现多处契约不符（见上）。
- **建议**：文件头加"历史审查记录，结论以最新代码与模块报告为准"；修正用例数与行号；把 Round 18/19 的收尾结论改为"截至该轮"，避免被当成永久结论。

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

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

<!-- 第 4 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分只审查 `.md`，没有代码改动面，不新增堆内存 / CPU 优化方案。README `:440-471` 的基准与 `:475-482` 的优化历程早于 SegmentedLog 迁移，只能作为历史参考，**不能**作为当前版本的收益基线（见上一条与「待验证假设」#2）。代码级优化候选由第 2–4 部分给出。

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

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

<!-- 第 4 部分 -->

> 本部分无任何 bench / profile 基线（`scope.md` 的「已有性能资料」是 local mode 文档，不含本模块数据），因此不提优化方案，性能线索全部下沉到「待验证假设」。统计为 0 / 0。

## 待验证假设

<!-- 第 1 部分 -->

> 没有性能测试数据支撑，只用于下一轮补数据；不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SegmentedLog.appendLock` 与 `SSTable.getLock` 使写/点查吞吐随线程数饱和，README 的"8 路并行验证无锁"结论不成立 | `f_store/src/WAL.cj:62`、`f_io/src/SegmentedLog.cj:272-276`、`f_store/src/SSTable.cj:306` | 1/2/4/8 线程下 add/get 吞吐与 P99、锁等待时长 | 同机同 SDK `-O2` 跑 `cjpm bench -j 1..8`，另采线程状态（BLOCKED/WAITING） |
| 2 | README 表中 `add` 115.3 ms / 1000 ops 等基线已不代表当前版本（WAL I/O 已迁移） | `f_store/README.md:447-471` | 迁移后同机基线（中位数 ± 离散度） | `cjHeapSize=8GB cjpm bench -j 1` 与 `-j 8`，同输入、同并发，记录多轮中位数 |

<!-- 第 2 部分 -->

> 没有性能数据支撑，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `LevelManager.get` 的 L0 全文件遍历（每层 `levels[level].load()` 快照 + L0 反向扫全部文件）是点查 P95 的主要来源 | `f_store/src/LevelManager.cj:82-118` | 自耗时占比、L0 文件数分布 | `cjprof record` 跑 8 写线程 + 4 读线程 10 分钟，输出 L0 文件数直方图与 `get` 分段计时 |
| 2 | `MemTable.approximateSize` 只计 key+value+24B，不含跳表节点/多层索引/对象头，8MB 阈值对应真实堆占用约 2–3 倍 | `f_store/src/MemTable.cj:24`、`31-42`、`56-58` | heapUsed / RSS 与 `approximateSize` 的比值 | 写入直到首次 flush，记录 flush 瞬间 `getUsedHeapSize()` / RSS 与 `approximateSize()` |
| 3 | `prefix()` 为每个命中 SSTable 打开一个 `File`，并发未关闭的迭代器会推高 FD 峰值（见 #10） | `f_store/src/PrefixIterator.cj:106-128`、`Store.cj:212-215` | FD 峰值、每迭代器平均句柄数 | 并发 100/1000 个 `prefix` 迭代器各跑 1 分钟，采样 `/proc/<pid>/fd` 数量 |
| 4 | `removeSSTables` 的整表复制 + `refEq` 双层扫描在文件多时进入 compaction 热路径 | `f_store/src/LevelManager.cj:179-201` | 单次 `removeSSTables` 耗时与调用频次 | 在 compaction 前后打点计时，跑"每层 100 文件"场景 100 轮取中位数 |

<!-- 第 3 部分 -->

> 本部分未提供 profile / bench 数据，以下均为待补数据的假设，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次 `get` 的 4KB 块缓冲分配是 GC 压力与 p99 抖动的主要来源 | `f_store/src/SSTable.cj:308,330` | 分配速率、GC 次数、自耗时占比 | `cjprof record` 跑 10 万次混合点查（命中率 50%），看 `Array` 分配与 GC 线程时间；同时记 `getAllocatedHeapSize()` |
| 2 | 同一 SSTable 的并发点查在 `getLock` 上排队，吞吐不随线程数增长 | `f_store/src/SSTable.cj:306-326` | 锁等待时长、BLOCKED 占比 | 1/4/8/16 线程各跑 60s 同 key 集合点查，采集吞吐与线程状态（CPU profile 看不到锁竞争） |
| 3 | 刷盘期间 active MemTable 缺少背压，可涨到远高于 8MB 阈值 | `f_store/src/Store.cj:377-390` | 刷盘时长、并发写速率、active 峰值 | 大 value（64KB）持续写 + 慢盘（或人为 delay flush），每 100ms 采样 `getActive().approximateSize()` |
| 4 | 归并路径每 key 的 `HashBuilder` 计算占压缩 CPU 的可见比例 | `f_store/src/SSTableIterator.cj:205-219` | `HashBuilder.append` 自耗时占比 | `cjprof record` 跑"10 万 key 触发 compaction"，看归并栈内 hash 计算占比 |
| 5 | WAL 恢复期的 CRC 重建是启动耗时的主要部分 | `f_store/src/WALReader.cj:52-75`、`WALRecordCodec.cj:26-39` | 64MB WAL 的启动分解耗时 | 预置 64MB WAL，分段计时（读文件 / CRC / MemTable 写入），各 5 轮取中位数 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | flush/compaction 写入路径「每条记录一次 `writer.write` + 一次 `Array<Byte>` 分配」是刷盘 CPU 与 syscall 的主要开销，用户态批量缓冲可摊薄 | `store_func.cj:120-122` → `SSTable.cj:150-200`（每记录 `file.write(buf)`） | 该函数自耗时占比、`write` syscall 次数/秒、单条 50B 与 1KB 记录的差异 | `cjprof record` 跑一次 1GB memtable flush（记录 ~50B，并发 1），对比「每 64KB 聚合一次 `file.write`」的改后版本；同时给 `-O2` 中位数与离散程度 |
| 2 | 启动期对 `walDir` / `sstDir` 做全目录 `walk`（`cleanupOldWALFiles`、`recoverAll`、`loadAll` 各一次），加上每文件两次 `split` + `Int64.parse`，在文件数上万时拉长 `Store.init` | `store_func.cj:220-228`、`:182-199` | 文件数与 `Store.init` 耗时曲线 | 造 1k / 10k / 100k 个空 `.sst` 与 `.wal`，计时 `Store.init`（分段：recover / loadExisting / cleanup） |

## 文件覆盖

> 与 `files/f_store.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_store/README.md` | .md | ✅ | — |
| 2 | `f_store/README_en.md` | .md | ✅ | — |
| 3 | `f_store/doc/审查报告.md` | .md | ✅ | — |
| 4 | `f_store/doc/开发计划.md` | .md | ✅ | — |
| 5 | `f_store/doc/架构设计方案.md` | .md | ✅ | — |
| 6 | `f_store/src/ByteArray.cj` | .cj | ✅ | — |
| 7 | `f_store/src/ByteArrayEntryValue_test.cj` | .cj | ✅ | — |
| 8 | `f_store/src/Compaction.cj` | .cj | ✅ | — |
| 9 | `f_store/src/Compaction_test.cj` | .cj | ✅ | — |
| 10 | `f_store/src/Concurrency_test.cj` | .cj | ✅ | — |
| 11 | `f_store/src/EntryValue.cj` | .cj | ✅ | — |
| 12 | `f_store/src/FlushMemTable_test.cj` | .cj | ✅ | — |
| 13 | `f_store/src/IndexEntry.cj` | .cj | ✅ | — |
| 14 | `f_store/src/LevelManager.cj` | .cj | ✅ | — |
| 15 | `f_store/src/LevelManager_test.cj` | .cj | ✅ | — |
| 16 | `f_store/src/MemTable.cj` | .cj | ✅ | — |
| 17 | `f_store/src/MemTableManager.cj` | .cj | ✅ | — |
| 18 | `f_store/src/MemTableManager_test.cj` | .cj | ✅ | — |
| 19 | `f_store/src/MemTable_test.cj` | .cj | ✅ | — |
| 20 | `f_store/src/PrefixIterator.cj` | .cj | ✅ | — |
| 21 | `f_store/src/PrefixIterator_test.cj` | .cj | ✅ | — |
| 22 | `f_store/src/SSTable.cj` | .cj | ✅ | — |
| 23 | `f_store/src/SSTableIterator.cj` | .cj | ✅ | — |
| 24 | `f_store/src/SSTableMerger.cj` | .cj | ✅ | — |
| 25 | `f_store/src/SSTableMetadata.cj` | .cj | ✅ | — |
| 26 | `f_store/src/SSTable_test.cj` | .cj | ✅ | — |
| 27 | `f_store/src/Store.cj` | .cj | ✅ | — |
| 28 | `f_store/src/StoreClosedException.cj` | .cj | ✅ | — |
| 29 | `f_store/src/StoreStream_test.cj` | .cj | ✅ | — |
| 30 | `f_store/src/Store_bench.cj` | .cj | ✅ | — |
| 31 | `f_store/src/Store_itergration_test.cj` | .cj | ✅ | — |
| 32 | `f_store/src/Store_test.cj` | .cj | ✅ | — |
| 33 | `f_store/src/TestTmpDirs_test.cj` | .cj | ✅ | — |
| 34 | `f_store/src/WAL.cj` | .cj | ✅ | — |
| 35 | `f_store/src/WALReader.cj` | .cj | ✅ | — |
| 36 | `f_store/src/WALReader_test.cj` | .cj | ✅ | — |
| 37 | `f_store/src/WALRecord.cj` | .cj | ✅ | — |
| 38 | `f_store/src/WALRecordCodec.cj` | .cj | ✅ | — |
| 39 | `f_store/src/WALRecord_test.cj` | .cj | ✅ | — |
| 40 | `f_store/src/WAL_test.cj` | .cj | ✅ | — |
| 41 | `f_store/src/imports.cj` | .cj | ✅ | — |
| 42 | `f_store/src/store_func.cj` | .cj | ✅ | — |

合计：`.cj` 37 个 / `.md` 5 个 / 共 42 个，全部读完。

## 覆盖自检

### 第 1 部分

> 命中数按维度计，同一条发现可落入多个维度；发现总数以「模块统计」为准（10 条）。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 命中 #2（快照语义）、#3（过期过滤）；本部分无代码，语言特性/安全性无独立结论 |
| §1 死代码 | 0 | 本部分无 `.cj`，无符号可判；文档中被引用但仓内不存在的文件（`doc/store.md`、`src/LSM.cj`）按 §13 记为文档失效（#7），不计死代码 |
| §2 重复逻辑 | 0 | 已比对 4 份文档：`README.md` 与 `README_en.md` 为翻译副本，不判重复；`审查报告.md` 对同一问题的两处相反结论属冲突而非重复，记 #3 |
| §3 空实现 | 0 | 本部分无函数实现 |
| §4 栈溢出 | 0 | 本部分无递归代码 |
| §5 OOM | 0 | 本部分无容器/分配代码；容量阈值缺文档记 #5 |
| §6.1 热点瓶颈 | 0 | 无 profile / 当前版本 bench 数据，热点不成立；已列入待验证假设 #1、#2 |
| §6.2 大粒度锁 | 1 | #1：README 的"无锁"表述掩盖 `appendLock` / `getLock` 串行临界区 |
| §6.3 并发串行 | 0 | 无并行度实测数据，串行段归入 #1 与待验证假设 #1 |
| §6.4 低效算法 | 0 | 本部分无算法实现 |
| §7 降堆内存方案 | 0 | 本部分无代码改动面，不产出方案 |
| §8 降 CPU 方案 | 0 | 同上；README 性能数据过期记 #8 |
| §9 local mode 可行性 | 0 | 未提供峰值内存/分配量数据，不成立 |
| §11 现有代码的 BUG（存量） | 1 | #3：`PrefixIterator` 用固化 `now` 过滤，长遍历会返回迭代期间到期的条目（代码归属 part2） |
| §12 并发安全与锁粒度 | 1 | #1：文档承诺"完全无锁"，实际两条 Mutex 路径；未发现文档层面的数据竞争描述缺失 |
| §14 功能完备性与 README 覆盖 | 3 | #4（依赖树缺失）、#5（容量/限制段落缺失）、#9（`Store(Path)` 未文档化） |
| 文件覆盖（§13 等） | 4/4 | 4 个 `.md` 全部逐行读完，无缺漏 |

### 第 2 部分

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

### 第 3 部分

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

### 第 4 部分

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
| 严重 | 8 |
| 一般 | 30 |
| 轻微 | 24 |
| 其中存量 | 62 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分只覆盖文档，但暴露的是**契约层风险**而不是排版权风险：`README` 把模块最核心的两个承诺写错了——"关键路径完全无锁"（实际 WAL 追加与 SSTable 点查都有 Mutex）和"prefix 迭代是快照且跳过过期数据"（实际弱一致性 + 迭代开始时刻的固化 `now`）。前者会让容量规划与后续优化方向失真，后者会让长前缀遍历返回已过期条目，是用户可感知的语义偏差；两者都建议阻塞到文档修正（后者还需第 2 部分同步修代码）。

其余问题集中在文档维护：依赖树漏了实际承担 WAL I/O 的 `f_io` 与 `PriorityQueue` 来源 `f_collection`，运行阈值（8MB/64MB/7 层）完全没写，测试命令指向不存在的用例，`开发计划.md` 与 `审查报告.md` 未标注为历史记录且残留死引用和过期结论。这些按轻微/一般排期即可，不影响运行时正确性。

建议顺序：先修 `README` 的无锁与 prefix 语义表述（#1–#3，与代码修复联动），再补依赖图与配置限制段（#4、#5），最后统一清理两份 `doc/` 的历史标注与死引用（#7、#10）。

**第 2 部分**：本部分的代码质量在"数据结构与并发原语"层面是扎实的：`MemTable` 对 `ConcurrentSkipListMap` 的封装、`MemTableManager` 的 `AtomicReference<MemTablePair>` 双缓冲、`LevelManager` 的 copy+CAS 无锁替换、`Compaction` 用 `try/finally` 兜住源迭代器 FD，这些都是有意设计并且注释到位；`Compaction_test.cj` / `LevelManager_test.cj` 的用例密度也明显高于一般模块，`P0/P2/P3` 修复都有对应用例守护。

但"层间语义"这一层存在两个阻塞项，都会表现为**用户可见的数据错误**而非性能问题：

1. **删除/过期标记无法终止层间查找**（#1）——契约在 `架构设计方案.md:731` 写得很清楚，实现在 `LevelManager.get` 把"命中 tombstone"降级成"未找到"，`remove` 之后的 key 会从 L1 复活，`ttl` 还会把删除撤销掉；
2. **L0 compaction 的下沉方向反了**（#2）——只搬最新的 4 个、把更老的文件留在 L0，读路径"先 L0 后 L1"于是读到旧值，覆盖写与删除都会回退。

这两条都只在"未 compaction 完的中间态"出现，所以现有用例（key 不重叠、单轮合并）恰好绕开了；建议优先补两条针对性用例，再动实现。

其余一般项集中在**故障可恢复性**：compaction 线程一次异常即永久停摆且无日志（#4）、flush 一次失败即让 immutable 永久占位并使 active 无界增长（#5）、compaction 缺少 manifest 导致崩溃/删除失败后层状态不自洽（#6）、`compactionThread` 缺同步（#7）。这些在正常路径上不可见，但决定了"磁盘满 / 权限错 / close 竞态"这类真实故障下 Store 是"降级"还是"静默烂掉"。配合 #8（键值数组别名）与 #3（计数器漂移），构成第二优先级。

轻微项里最值得顺手处理的是 #11（`ByteArray.hash` 全仓无消费方，却在每次按键访问上付一次分配 + 全量遍历，且 README 把它当成已生效的优化）与 #9（`doc/架构设计方案.md` 已与实现脱节到"照抄会写错"的程度，尤其时间单位与 tombstone 策略）。这两项不涉及运行语义，但会持续误导后续维护者与下游使用者。

`f_store` 的整体架构（无锁读路径、无 manifest 的简化设计、单 compaction 线程）是自洽的；上述问题不是架构选型的必然结果，而是"层序不变量"没有被单点表达（`LevelManager` 既做查找又做删除/过期判定）与"故障路径没有兜底"这两件事的具体表现。修 #1/#2 时建议同时把 #12 的判定收敛做完，否则同类缺陷还会以第三种形态出现。

**第 3 部分**：这部分的代码密度和工程质量明显高于仓库平均水平：SSTable 有完整的帧校验与篡改用例、WAL 用 `SegmentedLog` 把 mmap/轮转/fsync 收干净、`Store` 的"无锁关键路径"（CSLM + AtomicReference 双缓冲）思路正确，测试也覆盖了崩溃残留、CRC 损坏、并发 get+close 这些难写的场景。真正的风险集中在**跨进程重启这条链**上，而且四条严重问题都在同一处汇聚：

1. 重开文件时 `maxKey` 取错（#1）⇒ 重启后 L1+ 的键查不到；
2. 序列号不从 SSTable 恢复（#2）⇒ 重启后新写入在 compaction 里输给旧值；
3. 恢复完立刻删 WAL（#3）⇒ 重启后到首次刷盘之间崩溃即丢数据；
4. 文件名序号不补零 + 字符串排序（#4）⇒ 重启后 L0 优先序与 WAL 重放顺序都反了。

这四条的共同点是"重启后语义与运行期不一致"，且现有用例恰好都绕过了它们（`testCloseReopen` 只测 active，`testFlushToSSTableAndReopen` 只测单文件单值）。它们必须一起修，否则修好其中一条，另外三条仍会让"重启后数据不对"。第 5 条严重问题 `ttl` 的读改写（#5）是独立的并发缺陷，但同样属于"静默丢写"，建议与 #15 一起用一次原子更新原语解决。

一般级里，#6/#7/#8/#9 是"损坏输入与句柄生命周期"的健壮性缺口（都在已有防护风格的反面，补起来很快）；#10/#18/#26 是同一根因（该复用 `lookupEntry` 却各写一套）造成的契约漂移；#12/#13/#14/#16 是四个句柄/注册表泄漏点；#19 说明测试里存在"假装在测崩溃恢复"的用例，会掩盖上面四条重启类缺陷。

优化方案全部是"待验证假设"：没有 profile/bench 数据，报告里不给任何百分比承诺。可先做的是 #6（校验前移，零成本）与 #9（损坏文件留痕），其余按排期在补齐基线后再决定。

本部分存量缺陷 29 条（严重 5 / 一般 14 / 轻微 10），是否纳入修复待用户决定。

**第 4 部分**：`store_func.cj` 是整个存储栈最底层的「字节编解码 + 刷盘 + 文件名约定 + WAL 清理」工具集，代码量不大（229 行），但承担了两类难以观测的风险：**文件名序号**与**启动期清理**。编码助手（`write*LE`/`read*LE`）实现正确，`@OverflowWrapping` 的用法经语言文档核对无误；异常清理路径（136-165 行）已经有 close/remove/`addSuppressed` 的完整三步处理，历史审查的 FD 泄漏问题确实已修。

真正的问题集中在生命周期边界：①序号是全局状态而命名空间是目录，`loadExisting` 又用非原子的「取当前最大值再 store」，在多实例或崩溃残留场景下会复用文件名，而 `OpenMode.ReadWrite` 不截断把「复用」变成静默损坏——这是本部分唯一的阻塞项；②0 条数据的 flush 会留 0 字节 `.sst`，既污染目录又给①提供输入，修法极简（close 后 remove）；③清理旧 WAL 的 `catch {}` 把删除失败完全吞掉，配合「memtable 优先、不比 sequence」的读路径，会把旧值复活，建议至少补日志并让恢复集与清理集同源。另有一条路径解析的跨平台隐患（`split("/")`）需要在非 Linux 上实测确认后再定级。剩余三条是重复实现与错误处理粒度问题，可以排期处理，不阻塞发布。

**范围外提示**（不计入本部分统计，提请覆盖对应文件的子轮核查）：
1. `f_store/src/Store.cj:58-73`：`Store.sequence` 只从 WAL 记录推导，未取 `SSTableMetadata.sequenceEnd`；而 `SSTableMerger.cj:78-90` 同 key 取最高 sequence——重启后新写入的 sequence 会小于盘上旧记录的 sequence，下一次 compaction 会把旧值「合并」成最新值（延迟性数据回退）。
2. `f_store/src/Compaction.cj:66-88`：`runLoop` 无 `catch`，任何 flush/compaction 异常都会让后台线程静默退出且 `running` 标志不复位（`stop()` 里 `f.get()` 的异常被 `catch (_: Exception) {}` 吞掉），此后 compaction 永久停摆。
3. `f_store/README.md:482`：性能表把 WAL mmap 写入归到 `WAL.cj`, `store_func.cj`，但本文件只有字节编解码与刷盘编排，不含 mmap 写路径，文献引用疑似过期（由 README 所在子轮判定）。
