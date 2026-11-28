# f_dbd 模块审查报告（第 1/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（49 个源文件；本部分 `src/common/` 下 15 个）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，`git status` 仅 `docs/review/` 与 `reviews/` 两个未跟踪目录，源码干净）
- **审查重点**：DB 协议载荷 / 列 / 结果集的正确性与内存边界、错误处理、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（第 1/4 部分，待与 part2–part4 合并为 `docs/review/f_dbd_review_20261128.md`）

> 范围声明：本部分只审上列 15 个文件。文中出现的 `f_dbd/src/driver/*`、`fdbm/src/*`、`f_data/src/*` 仅作为调用方 / 被调用方的取证上下文，未展开审查。

## 发现

### [严重][存量] `decodeStrict` 的"严格 flag"实际恒为 0，与自身注释直接冲突：含整数字段的载荷可能永远解不出

- **位置**：`src/common/types.cj:54`（注释自述在 `types.cj:49-50`）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee` 引入；诱因是 `f_data` 2026-10-15 `f8b45cccd` 把 `DEFAULT_DATA_FLAG` 从 `WRAPPING|SILENCE` 改成纯 `SILENCE`）
- **判据**：review-checklist §11（错误处理静默失效 / 契约与实现不符）、§3（静默吞失败）
- **证据**：静态确定 ——
  1. `f_data/src/base/global_objects.cj:42-51`：`SILENCE = 1|2|4|8 = 15`，`DEFAULT_DATA_FLAG = SILENCE`；
  2. 故 `DEFAULT_DATA_FLAG & !SILENCE == 15 & 0xFFFF_FFFF_FFFF_FFF0 == 0`；
  3. 同函数注释 `types.cj:49-50` 明确写"**为什么不能取 `flag: 0`**：`f_data` 的整数解码要求四个溢出策略位之一被置位…`flag: 0` 时**所有含整数字段的载荷都解不出来**"；
  4. `f_data/src/base/NumberData.cj:244-273`（`Int64.tryFromData`）在 flag 为 0 时：`DataReal` 的四个策略分支与 `ignoreNotConvertable` 分支全不命中，最终落到 `case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException(...)`，即抛异常。
- **描述**：`decodeStrict` 因此等价于"用 flag 0 解码"，凡载荷含 `Int64` 字段（`UpdateResultPayload.rc/liid`、`ColumnInfoImpl.len/scl/ds`、`DbdErrorPayload.code`、`QueryResultColumnPayload.index/bufSize`）都会抛 `DataException` 并被本函数吞成 `None`。影响面（范围外，仅作影响说明）：`DbdStatement.cj:86/108` 会把每条查询 / 更新响应判成 `PROTOCOL`；`DbdTransport.cj:128` 会把每个 `ERROR` 降级成 `PROTOCOL` 并丢掉错误码与 sqlState。
  唯一可能掩盖它的路径是 `f_data/src/base/DataObject.cj:208-213` 的 `populate` 早退：若上游传入的已经是**同型** `DataObject<T>`，则不做字段转换、flag 不生效。线上载荷经 `Client<DataAny>`（`DbdTransport.cj:46`）解码，形态是否为同型 `DataObject<T>` 需一条用例确认 —— 这正是本条从"静态确定"降级为"需确认端到端是否已暴露"的唯一不确定点；但表达式恒 0 与注释自述矛盾这两点是静态确定的，不能视为"设计如此"。
- **建议**：改为显式策略位，例如 `flag: THROWING_ON_INT_OVERFLOW`（保留 IGNORE 位全清零语义，且不依赖 `DEFAULT_DATA_FLAG` 的当前取值）；若想保留"跟随默认 flag 的策略位"，写成 `(DEFAULT_DATA_FLAG & (WRAPPING_ON_INT_OVERFLOW | THROWING_ON_INT_OVERFLOW | SATURATING_ON_INT_OVERFLOW)) | THROWING_ON_INT_OVERFLOW` 之类的显式表达式，并在 `decodeStrict` 上加一条"含 Int64 字段的载荷必须解出"的回归用例（`UpdateResultPayload` + `DbdErrorPayload` 各一条即可覆盖）。

### [一般][存量] `QueryResultImpl.next()` 异常路径不复位行状态，后续 `get()` 可能读到未定义行

- **位置**：`src/common/result.cj:91-112`（关键：`98` 发包、`101` 抛 `PROTOCOL`、`105-110` 才更新状态）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`）
- **判据**：review-checklist §11（错误处理缺失 / 状态机不一致）、§12.1（异步语义：失败后状态未处理）
- **证据**：静态确定 —— 三种失败路径（`send_` 抛超时 / IO、响应不是 `DataBool` 抛 `PROTOCOL`）都在 `rowValid`/`exhausted` 更新之前退出，两个字段保持上一行的值；而 `ensureReadable`（`result.cj:209-212`）只看 `rowValid`，于是失败后 `get()/getOrNull()` 仍认为"当前行可读"。
- **描述**：`NEXT_ROW` 一旦失败，服务端游标可能已推进或连接已断（`DbdTransport.cj:134-146` 明确写了"可能已错位"），客户端却继续用旧 `rowValid=true` 读列 → 返回上一行（或错位行）的单元格。同类缺陷在 fdbm 侧已按 G28 修过（`fdbm/src/execute/cursor.cj:122-129`：推进失败先 `rowValid = false; clearRow()`），客户端这一侧漏了同一处理。
- **建议**：把 `send_` 放进 `try`，任何失败（含非 `DataBool`）先 `rowValid = false; invalidateStreams()` 再重抛；或抽 `private func failRow()` 统一复位。

### [一般][存量] `readData` 的流列分支整块物化且无上限，同时丢失 IO 异常包装

- **位置**：`src/common/types.cj:368`（`readChunk(readStream(result, index), 0).toData()`）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`；2026-10-21 `eda252b8f` D02 明确改成"整读"）
- **判据**：review-checklist §5（一次性物化 / 无拒绝路径）、§11（错误处理不对称）
- **证据**：静态确定（规模可量化）—— `readChunk(..., 0)` 走 `toEnd` 分支（`types.cj:406-420`），把整个 `InputStream` 读进 `ArrayList<Byte>` 再 `toArray()`；峰值 ≈ "值大小 V × 2（ArrayList 扩容 + 终态数组）+ 64 KiB 缓冲"，1 GiB 的 LOB 列即 ≥2 GiB 峰值，且没有大小上限、没有超限抛错路径。
- **描述**：fdbm 的游标路径是分块流式（`fdbm/src/execute/cursor.cj:169-187`，`bufSize` 分块），但 `readData` 这条"一次性"路径（`fdbm/src/execute/executors.cj:404/636/1051` 对 `RETURNING` 类语句使用）对所有 `InputStream` 列都整读。另外 `readChunk` 里的 `stream.read` 异常在这里**未包装**，会以驱动原始异常（如 `IOException`/`SqlException`）穿透到 fdbm 与最终调用方，而同文件 `encodeParameter`（`types.cj:462-468`）对同类异常做了 `DataException` 包装 —— 同一模块内两套错误契约。
- **建议**：给整读加可配置上限（如 `max_lob_bytes`），超限抛 `DbdException(CONVERSION/CONFIG)` 而不是 OOM；至少用 `try/catch` 把非 `DbdException` 异常包成 `DataException`（与 `encodeParameter` 对齐）。若某类语句其实可按块消费，改为返回分块迭代而不是整块。

### [一般][存量] 归一化表缺 `int` 基名：`INT(11)` / `INT(11) UNSIGNED` 被归一成 `String`

- **位置**：`src/common/types.cj:250-256`（`PAREN_BASES` 无 `int`）、`241-248`（`parenBaseOf`）、`214-227`（去括号重试）、`320-345`（`resolveDialect` 只认精确 `int`）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`）
- **判据**：review-checklist §11（语义与命名 / 规格不符）、§2（两张表不一致导致行为漂移）
- **证据**：静态确定 —— 对 `"int(11)"`：`resolveCangjieName` 无匹配 → `resolveDialect('int(11)')` 无匹配（只有精确 `'int'/'integer'`）→ `endsWith(' unsigned')` 不成立 → `parenBaseOf('int(11)')` 在 `PAREN_BASES` 里找不到 `int`（表内有 `integer` 但没有 `int`；`'int(11)'` 不以 `'integer'` 开头）→ 前缀匹配不成立 → 返回 `None` → `canonicalName` 兜底 `'String'` 并打 WARN。`"int(10) unsigned"` 同理落到 `'String'`。
- **描述**：MySQL/MariaDB 最常见的整型拼写带长度后缀（`INT(11)`、`INT(10) UNSIGNED`），归一后列 `typeName` 变成 `String`：`ColumnInfo` 元数据错报（影响 ORM 映射与使用者判断），`readData` 会按 `String` 读列（多一次驱动侧字符串化 + 客户端侧再解析），而 `bigint(20)`/`smallint(6)`/`mediumint(8)`/`tinyint(4)` 都正常 —— 行为不一致且难以发现。现有用例只覆盖 `TINYINT(1)`/`varchar(64)`/`decimal(10,2)`（`sqltypes_test.cj:105-109`），未覆盖 `int(n)`。
- **建议**：在 `PAREN_BASES` 补 `'int'`（放 `'integer'` 之后、并让 `parenBaseOf` 额外校验"基名之后紧跟 `(`"以避免 `int4range`/`interval(x)` 这类前缀误命中），补 `readType('int(11)') → I32`、`readType('int(10) unsigned') → U32` 两条用例。

### [一般][存量] 未知列类型的 WARN 打在逐单元格路径上（日志放大）

- **位置**：`src/common/types.cj:370-372`
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`）
- **判据**：review-checklist §8（降低日志放大，`perf §9.1`）、§6.4（同一输入重复计算）
- **证据**：静态确定 —— `readData` 每读一格调用一次 `readType(typeName)`，`Unknown` 分支里 `logger.warn(...)` 无去重、无节流；列类型是**每列固定**的，同一列 N 行即 N 条同文案 WARN。
- **描述**：`GEOMETRY`/`inet`/`tsvector` 这类列（`sqltypes_test.cj:113-118` 明确承认是 WARN 兜底族）在 10 万行结果集上会产生 10 万条 WARN，日志成本与磁盘占用都按行数放大，而且把真正的告警淹没。列信息归一（`canonicalName`，`types.cj:155-162`）已经在"每列一次"的位置打过同样的 WARN。
- **建议**：`readData` 的 `Unknown` 分支去掉日志（信息已由 `canonicalName` 报过），或按 `typeName` 做一次性去重（`HashSet<String>` + 上限）。

### [一般][存量] `QueryResultImpl` / `DbdInputStream` 未声明线程封闭，可变状态无任何同步

- **位置**：`src/common/result.cj:55-62`（5 个可变字段）、`392-398`（`DbdInputStream` 的 `pending/pos/eof/dead`）、`345-351`（`invalidateStreams`）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性）
- **证据**：待确认 —— 具体共享路径：`QueryResultImpl.next()` 在调用线程写 `dead=true` 并清空 `pending`（`result.cj:346-350` → `440-444`），若另一个线程正在同一个 `DbdInputStream` 上 `read()`（读 `dead`/`pending`/`pos`），构成无同步的数据竞争（可见性 + 撕裂读）；同一结果集上并发 `get()/next()` 还会交错发包打乱服务端单一游标。缺的信息：std.database.sql 是否承诺 `QueryResult` 单线程使用（本仓未在类型上写任何线程约束注释）。
- **描述**：类型对外是 `public class ... <: QueryResult`，无 `@ThreadSafe` 类声明也无"仅限单线程"的文档；一旦被连接池/异步框架跨线程使用，错误是沉默的数据错乱而不是异常。
- **建议**：在 `QueryResultImpl` / `DbdInputStream` 的类注释里写明"单线程使用，禁止跨线程共享"（若契约允许），或对 `closed_/rowValid/exhausted/dead` 使用原子/锁并说明并发语义。**不要**为降锁粒度牺牲正确性。

## 优化可行性方案

### [堆内存] `readChunk` 每调用固定分配 64 KiB 缓冲，且输出经"复制进 ArrayList → `toArray`"两次搬运

- **现状**：`types.cj:409` 每次调用 `Array<Byte>(DEFAULT_STREAM_CHUNK, repeat: 0u8)`（64 KiB，清零）；`418` 的 `out.add(all: buf[0..n])` 复制进 `ArrayList`，`421` 的 `toArray()` 再复制一次。单次块读的实际分配 ≈ 64 KiB（缓冲）+ 块长×2（扩容 + 终态）；fdbm 每个流列块请求都新建一份缓冲（`fdbm/src/execute/cursor.cj:175/187` 调 `readChunk`），缓冲不跨请求复用（新增的 `ReadChunkReuse_test.cj` 只证明"同一调用内跨轮复用"）。
- **方案**：① 让缓冲大小跟随 `want`（`min(size, DEFAULT_STREAM_CHUNK)`）而不是恒定 64 KiB，`size` 很小时不付 64 KiB 代价；② 对"读至 EOF"场景先按已知长度（若调用方给得出）预分配，或直接返回 `ArrayList` 避免 `toArray` 终态复制；③ 若确实需要跨调用复用，用可归还的线程本地缓冲（必须有上限与清理路径）。
- **预期**：小尺寸 `bufSize`（客户端可配 `fetch_rows`/`bufSize`）时单次分配从 64 KiB 降到 `bufSize`；整读 1 MiB 时省掉一次 1 MiB 级别的终态复制（对象数 -1，峰值 -1×V）。
- **代价**：① 只是改分配大小，无语义变化；② 会改变返回类型或要求调用方给长度，需同步改 fdbm 两处调用；③ 池化是最后手段，且必须带上限。
- **验证**：`ReadChunkReuse_test.benchToEnd`（已有 `F_DBD_BENCH=1` 门禁，统计 `alloc`）在改前/改后各跑 5 轮取中位数；配 `getAllocatedHeapSize()` + RSS。
- **证据状态**：`无基线（待验证，不进 tasks）`（仅有 `benchToEnd` 的打印口径，仓库内无已记录数值）

### [CPU] 流列 `DbdInputStream.read` 逐字节拷贝

- **现状**：`result.cj:431-434` 用 `while (i < n) { buffer[i] = pending[pos + i]; i += 1 }` 把待消费块搬进调用方缓冲；BLOB 的每个字节都要经过一次仓颉层循环（数组边界检查 + 逐元素赋值），调用方缓冲通常只有 4~8 KiB，于是同一块会被反复分段搬。
- **方案**：改成整段拷贝，如 `pending[pos..pos + n].copyTo(buffer, 0, 0, n)`（测试里的 `PatternStream.read` 就是这么写的，`ReadChunkReuse_test.cj:39`），并顺手把 `pos`/`n` 的类型判断收敛到一次。
- **预期**：拷贝段从 O(n) 解释执行降为一次 memmove；单次块搬运的 CPU 常数级下降（量级需 profile 确认）。
- **代价**：无（`copyTo` 语义等价，需补一条"跨块 + 小缓冲"的等价性用例，`leftoverIsKeptForNextRead` 已覆盖）。
- **验证**：`cjprof record` 跑"读 1 GiB BLOB"场景，看 `DbdInputStream.read` 自耗时占比；或 `cjpm bench -O2` 前后对照 `read` 的 ns/byte。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每单元格重复归一化 `typeName`（可加类型名→读类型缓存）

- **现状**：`readData`（`types.cj:348-349`）每读一格都调 `readType(typeName)` → `resolve` → `trimAscii()` + `toAsciiLower()`（两次 `String` 分配）+ 最多 8 级判定（`resolveCangjieName`/`resolveDialect`/括号重试/前缀匹配）。`typeName` 是**每列常量**，但调用频次是"行数 × 列数"（`fdbm/src/execute/cursor.cj:192` 每格一次）。
- **方案**：在 `SqlTypes` 内做 `typeName → SqlReadType` 的有界缓存（列名种类有限，容量上限如 256 + 直接淘汰），或把归一化结果前移到 `ColumnInfoImpl`（列信息构建时算一次，`cursor.cj:100` 已经在做 `canonicalName`）。
- **预期**：每格省 2 次 `String` 分配 + 一次多级字符串比较链；100 万格约省 200 万次短生命周期分配（GC 压力下降）。
- **代价**：引入共享缓存 → 需要并发安全（不可变 `HashMap` 快照或每线程缓存），否则反而引入锁竞争；类型名种类可能来自服务端，需带上限。
- **验证**：`cjprof record` 看 `SqlTypes.resolve` / `String.toAsciiLower` 在 `readData` 调用链上的自耗时占比；`cjpm bench -O2` 跑 10 万行 × 10 列读取。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `decodeStrict` 恒 0 flag 是否已在端到端暴露（还是被 `populate` 同型早退掩盖） | `src/common/types.cj:54` | 一条 `UpdateResultPayload`/`DbdErrorPayload` 的 `decodeStrict` 往返用例结果 | 加两条 `@TestCase` 断言 `decodeStrict<UpdateResultPayload>(p.toData()).isSome()` 与 `decodeStrict<DbdErrorPayload>(p.toData()).getOrThrow().errorCode()==code`，跑 `cjpm test` |
| 2 | `SqlTypes.resolve` 是否为 `readData` 主路径的热点 | `src/common/types.cj:171-233`、`348-349` | 自耗时占比 + 分配量 | `cjprof record` 跑 10 万行 × 10 列查询，看 `resolve`/`toAsciiLower` 的 self time；`getAllocatedHeapSize()` 前后差值 |
| 3 | `DbdInputStream.read` 逐字节拷贝的实际占比 | `src/common/result.cj:431-434` | 单次 `read` 的 ns/byte 与整体占比 | `cjpm bench -O2` 读 1 GiB 流（分块 64 KiB、调用方缓冲 8 KiB）改前/改后对照，取 5 轮中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/common/DbdException.cj` | .cj | ✅ | 见轻微 #4（构造器重复 `errorCode()`） |
| 2 | `src/common/DbdException_test.cj` | .cj | ✅ | 7 个用例覆盖继承 / code / sqlState / cause / payload 还原；断言方式正确 |
| 3 | `src/common/ReadChunkReuse_test.cj` | .cj | ✅ | 缓冲复用回归；`benchToEnd` 有 `F_DBD_BENCH` 门禁，做法可作范本 |
| 4 | `src/common/column.cj` | .cj | ✅ | 6 短名数据字段 + 6 个 `@DataExclude[field]` 只读属性，形态与注释一致 |
| 5 | `src/common/column_test.cj` | .cj | ✅ | 钉住线上键集合恰为 6 个短名，覆盖严格解码 |
| 6 | `src/common/dispatch_perf_test.cj` | .cj | ✅ | 见轻微 #6（复制生产分派链、无 bench 门禁） |
| 7 | `src/common/error.cj` | .cj | ✅ | 见轻微 #3（三份 16 分支表） |
| 8 | `src/common/error_test.cj` | .cj | ✅ | 码值表 / toString / 兜底 / 往返，覆盖充分 |
| 9 | `src/common/payload.cj` | .cj | ✅ | 见轻微 #5（`next(values)` 忽略参数） |
| 10 | `src/common/payload_test.cj` | .cj | ✅ | 键集合红线 + 严格解码 + 常量断言，覆盖充分 |
| 11 | `src/common/placeholder.cj` | .cj | ✅ | 见轻微 #2（无任何声明的占位文件） |
| 12 | `src/common/result.cj` | .cj | ✅ | 见严重/一般 #2、#6；优化方案 2 条 |
| 13 | `src/common/result_test.cj` | .cj | ✅ | 状态机 + 流列 + 关闭握手，桩设计良好；`codeOf` 把"没抛"也映射成 `INTERNAL`（轻微 #7） |
| 14 | `src/common/sqltypes_test.cj` | .cj | ✅ | 见轻微 #8（过期注释）；归一化用例缺 `int(n)` |
| 15 | `src/common/types.cj` | .cj | ✅ | 见严重 #1、一般 #3/#4/#5；优化方案 3 条 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完。本部分清单内无 `.md`（`README.md` / `README_en.md` / `doc/**` 属本模块范围但不属第 1 部分，§13 / §14 的文档侧核对留给合并后的模块报告）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 3 条（#1 严格 flag、#2 行状态、#4 类型归一化）；设计 1 条（`readData` 与 `encodeParameter` 两套异常契约）；可读性 1 条（`resolve` 的判定顺序与两张表无交叉引用，读代码要自己推哪个 case 不可达）；安全性：载荷均为服务端/驱动产出，无注入面，未发现敏感信息入日志 |
| §1 死代码 | 2 | 逐个 private / internal 符号在本包及子包内搜引用：`resolve`/`parenBaseOf`/`resolveSqlName`/`resolveCangjieName`/`resolveUnsigned`/`resolveDialect`/`cellOf`/`isIntegerTarget`/`PAREN_BASES` 均有调用者；`requestBlock`/`invalidate`/`columnIndex` 均有调用者；`DbdTypeInfo` 被 `isStreamTarget` 使用。命中：① `resolveDialect` 中 `'bool'`(`322`)/`'decimal'`(`329`)/`'int8'`(`325`)/`'datetime'`(`332`) 四个 case 不可达（更早的 `resolveCangjieName` 已吃掉同名 key）；② `types.cj:200-203` 的 `resolveUnsigned(base)` 分支不可达（6 个基名都先在 `resolveDialect` 的 `* unsigned` 精确 case 命中）。对外可达的 `public`（`SqlTypes` 全部静态方法、`SqlReadType`、payload 类、`SqlTypes.readStream(QueryResult,Int64,Int64)`）一律不判死代码；其中 `readStream(result, index, size)` 全仓（含测试）零引用，仅记信息 |
| §2 重复逻辑 | 4 | ① `resolveUnsigned`（`303-311`）与 `resolveDialect` 的 `* unsigned` case（`339-342`）是同一张映射表的两份；② `DbdErrorCode` 的 `value`/`toString`/`parse`（`error.cj:50-119`）是三份 16 分支同构表，新增一码需改 3 处，`parse` 静默兜 `INTERNAL`；③ `SqlReadType.toString` 与 `of`（`types.cj:76-127`）是同一张映射的正反两份；④ `dispatch_perf_test.cj:405-429` 的 `canonicalB` 与生产 `decodeCellAsAny`（`result.cj:231-251`）逐分支同形，新增类型要改两处，否则性能实验数据会静默漏项。合并建议：②③ 至少加一条"表长 = 枚举数"的用例代替手工对齐；④ 应让 harness 直接调用生产分派或明确标注"仅历史实验" |
| §3 空实现 | 2 | ① `placeholder.cj` 无任何声明（注释却写"共用占位类型（保留以兼容既有 import）"，实际没有类型可 import）；② `QueryResultImpl.next(values)`（`result.cj:114-117`）忽略 `values`，调用方拿到的数组不会被填充。`close()` 吞异常（`185-197`）是设计文档明确要求（§3.10 规则 7），不算空实现 |
| §4 栈溢出 | 0 | 15 个文件内无递归调用；`resolve` 的各级辅助函数是单向调用链（`resolve`→`resolveSqlName`/`resolveCangjieName`/`resolveDialect`/`parenBaseOf`），无环；无按输入深度展开的结构 |
| §5 OOM | 1 | `readData` 的 `Stream` 分支整块物化（一般 #3，已量化：V×2 + 64 KiB，无上限、无拒绝路径）。其余容器（`streams_`/`nullStreams_`/`params`/`cells`）都是"每行/每语句"作用域，行切换即清，无全局无界集合 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 明确"未提供"），`resolve` 与 `DbdInputStream.read` 只能是线索，已列入「待验证假设」#2/#3 与两个 `[CPU]` 方案 |
| §6.2 大粒度锁 | 0 | 本部分 15 个文件无任何锁 / `synchronized` / 原子操作；`SqlTypes.logger` 是只读静态引用 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无线程池 —— 每个请求一次 `send_` 同步调用（这是协议设计，不是并发退化） |
| §6.4 低效算法 | 2 | ① `readChunk` 每调用恒定 64 KiB 分配 + 两次搬运（优化方案 1）；② `resolve` 每格两次字符串分配 + 多级前缀比较（优化方案 3）。`medianOf`（`dispatch_perf_test.cj:202-218`）对 5 元素用冒泡，代价可忽略，不提 |
| §7 降堆内存方案 | 1 | 优化方案 1（`readChunk` 缓冲 / 终态复制）。`QueryResultImpl` 的 `infos_` 逐项转换（`result.cj:71-75`）是泛型不变性所迫，无法省 |
| §8 降 CPU 方案 | 2 | 优化方案 2（逐字节拷贝）、方案 3（类型名缓存）；另一般 #5（WARN 放大）也属 §8 |
| §9 local mode 可行性 | 0 | 候选只有 `resolve` 里的 `trimAscii()`/`toAsciiLower()` 临时串与 `readChunk` 的单块缓冲；前者是 std `String`（无 mode 重载，非 `Copyable`，要重建），后者生命周期跨 `stream.read` 调用、无法整块在函数返回时释放；没有峰值内存对照数据 → 只能作假设，收益无法证明，判不可行（约束 3/5） |
| §11 现有代码的 BUG（存量） | 6 | 见「发现」中带 `[存量]` 的 6 条（1 严重 + 5 一般）；已核对但未列为缺陷的边界：`readChunk` 的 `want>=1`（`size-got>0` 恒成立）、`ensureReadable` 的 `index` 上下界、`DbdInputStream.read` 的 `n=min(buffer, remaining)`、`openStreamAsAny` 的 NULL 探测与空 BLOB 区分（有专门用例） |
| §12 并发安全与锁粒度 | 1 | 一般 #6：`QueryResultImpl`/`DbdInputStream` 可变状态无同步且未声明线程封闭（具体共享路径已给出，证据等级 `待确认`）。锁粒度：本部分无锁，无从细粒度化 |
| §14 功能完备性与 README 覆盖 | 1 | 轻微 #5（`next(values)` 的 std 契约未履行）；本部分不含 `.md`，README/public API 覆盖对照留给模块合并报告 |
| 文件覆盖（§13 等） | 15/15 | 无缺失；§13 文档一致性本轮不适用（本部分无 `.md`） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 8 |

> 轻微清单（正文从略，位置均已核对）：① `SqlReadType.==` 用 `toString()` 比较（`types.cj:100-102`，每次比较 2 次字符串分配，且枚举本身可默认判等）；② `placeholder.cj:18-20` 空占位文件 + 注释与内容不符；③ `DbdErrorCode` 三份同构表（`error.cj:50-119`，与 §2 ② 同源，此处只记可维护性）；④ `DbdException.cj:60-61` 同一 payload 调两次 `errorCode()`；⑤ `result.cj:114-117` `next(values)` 忽略参数；⑥ `dispatch_perf_test.cj` 无 `F_DBD_BENCH` 门禁（`46-51`：19 类型 × 4 组合 × 10⁶ 次 × 5 轮，随 `cjpm test` 默认执行）+ `165` 悬空的"三组对照"注释（下文体只测了 A 的 NULL 短路）；⑦ `result_test.cj:627-636` `codeOf` 把"没有抛异常"也返回 `INTERNAL`，与"确实抛了 INTERNAL"不可区分（对断言 `INTERNAL` 的用例是假阳性风险）；⑧ `sqltypes_test.cj:172-176` 注释仍写"当前实现按 `Int64.Max` 申请，会抛分配失败"，与当前分块实现（`types.cj:405-422`）相反。

> 优化方案：堆内存 1 条 / CPU 2 条（全部 `无基线（待验证）`，不进 `tasks.md`）。

> 存量缺陷共 6 条（1 严重 + 5 一般）+ 轻微 8 项，默认只报不修，是否纳入修复待用户决定。

## 总评

本部分是 f_dbd 的"协议载荷 + 类型映射 + 结果集状态机"，代码组织清晰：载荷类用"短名数据字段 + `@DataExclude[field]` 只读属性"这一形态是被设计文档论证过的唯一可行解，且有钉住线上键集合的回归用例；`QueryResultImpl` 的"无预读 / 无缓存 / 显式状态机"实现与文档一致，`result_test.cj` 用桩发送器把状态机、流句柄复用、关闭握手都覆盖到了，属于本仓测试质量偏上的一层。

主要风险集中在两处：

1. **阻塞项候选**：`decodeStrict` 的严格 flag 在其依赖的 `f_data` 改了 `DEFAULT_DATA_FLAG` 之后退化为 0，而函数自己的注释就写着"flag 0 解不出整数字段"。这条一旦在端到端成立，`update()`/`query()`/`ERROR` 三条主路径会同时失效，属最高优先级，建议先补两条用例确认（成本极低）。
2. **状态机与内存边界**：`next()` 失败后不复位行状态（与 fdbm 侧已修的 G28 同源），以及 `readData` 对流列整块物化且无上限、异常契约与 `encodeParameter` 不一致。

其余为类型归一化表的缺口（`INT(n)` → `String`）、逐单元格 WARN 放大，以及一批"表分散在多处、靠手工对齐"的可维护性隐患（死分支、重复映射表、性能实验代码复制生产分派）。性能方面本轮无任何 profile / bench 数据，三个优化方向都只作为待验证假设，不进修复清单。
