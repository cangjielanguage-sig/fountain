# f_store 模块审查报告（第 1/4 部分：文档）

> 本报告是 f_store 模块**第 1/4 部分**，只覆盖 `files/f_store.part1.txt` 列出的 4 个 `.md`。
> 代码文件（`src/*.cj`）由第 2–4 部分审查，本报告不重复其结论；涉及代码仅作为文档一致性的取证依据。

- **审查日期**：2026-11-28
- **模块路径**：`f_store`（本部分 4 个 `.md`；模块整体 37 个 `.cj` + 5 个 `.md`，分 4 部分）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支）
- **审查重点**：`README.md` / `README_en.md` / `doc/审查报告.md` / `doc/开发计划.md` 与当前实现的契约一致性（§13）、README 覆盖与功能完备性（§14），并交叉验证存储语义、持久化与并发声明
- **报告版本**：v1（分报告）

## 发现

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

## 优化可行性方案

本部分只审查 `.md`，没有代码改动面，不新增堆内存 / CPU 优化方案。README `:440-471` 的基准与 `:475-482` 的优化历程早于 SegmentedLog 迁移，只能作为历史参考，**不能**作为当前版本的收益基线（见上一条与「待验证假设」#2）。代码级优化候选由第 2–4 部分给出。

## 待验证假设

> 没有性能测试数据支撑，只用于下一轮补数据；不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SegmentedLog.appendLock` 与 `SSTable.getLock` 使写/点查吞吐随线程数饱和，README 的"8 路并行验证无锁"结论不成立 | `f_store/src/WAL.cj:62`、`f_io/src/SegmentedLog.cj:272-276`、`f_store/src/SSTable.cj:306` | 1/2/4/8 线程下 add/get 吞吐与 P99、锁等待时长 | 同机同 SDK `-O2` 跑 `cjpm bench -j 1..8`，另采线程状态（BLOCKED/WAITING） |
| 2 | README 表中 `add` 115.3 ms / 1000 ops 等基线已不代表当前版本（WAL I/O 已迁移） | `f_store/README.md:447-471` | 迁移后同机基线（中位数 ± 离散度） | `cjHeapSize=8GB cjpm bench -j 1` 与 `-j 8`，同输入、同并发，记录多轮中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_store/README.md` | .md | ✅ | 512 行全读；与实现存在多处契约不符，见发现 #1–#6、#8、#9 |
| 2 | `f_store/README_en.md` | .md | ✅ | 512 行全读；与中文版章节一一对应，问题同源（#1–#6、#8、#9） |
| 3 | `f_store/doc/审查报告.md` | .md | ✅ | 2217 行全读；历史审查记录，存在相反结论与过期统计（#3、#10） |
| 4 | `f_store/doc/开发计划.md` | .md | ✅ | 963 行全读；旧方案残留、死引用（#4、#7） |

合计：`.cj` 0 个 / `.md` 4 个 / 共 4 个，全部读完（本部分不含 `.cj`，代码部分见 part2–part4）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 10 条（本部分全部为存量，工作区快照无基线），是否纳入修复待用户决定。

## 总评

本部分只覆盖文档，但暴露的是**契约层风险**而不是排版权风险：`README` 把模块最核心的两个承诺写错了——"关键路径完全无锁"（实际 WAL 追加与 SSTable 点查都有 Mutex）和"prefix 迭代是快照且跳过过期数据"（实际弱一致性 + 迭代开始时刻的固化 `now`）。前者会让容量规划与后续优化方向失真，后者会让长前缀遍历返回已过期条目，是用户可感知的语义偏差；两者都建议阻塞到文档修正（后者还需第 2 部分同步修代码）。

其余问题集中在文档维护：依赖树漏了实际承担 WAL I/O 的 `f_io` 与 `PriorityQueue` 来源 `f_collection`，运行阈值（8MB/64MB/7 层）完全没写，测试命令指向不存在的用例，`开发计划.md` 与 `审查报告.md` 未标注为历史记录且残留死引用和过期结论。这些按轻微/一般排期即可，不影响运行时正确性。

建议顺序：先修 `README` 的无锁与 prefix 语义表述（#1–#3，与代码修复联动），再补依赖图与配置限制段（#4、#5），最后统一清理两份 `doc/` 的历史标注与死引用（#7、#10）。
