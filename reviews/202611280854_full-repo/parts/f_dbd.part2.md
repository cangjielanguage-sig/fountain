# f_dbd 模块审查报告

> **模块第 2/5 部分**（本报告只覆盖 `files/f_dbd.part2.txt` 列出的 7 个文件：`doc/开发计划.md`、`doc/详细设计.md` 与 `src/common/` 下的 `DbdException.cj`、`DbdException_test.cj`、`ReadChunkReuse_test.cj`、`column.cj`、`column_test.cj`。`payload.cj` / `types.cj` / `result.cj` / `driver/**` / `multid/**` 与 README 由其余 4 个部分产出，合并时以主 Agent 为准；本报告只对本部分文件下结论，引用其他文件仅作取证上下文。）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（本部分 5 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：数据库驱动协议正确性、类型映射、资源与连接生命周期、死代码、重复逻辑、存量 BUG（本部分实际承载的是「异常类型 + 列信息线上载体 + 其单测」与两份设计/计划文档，协议状态机与连接生命周期在其余部分）
- **报告版本**：v1（第 2/5 部分）

## 发现

### [一般][存量] #1 `DbdException` 的 `cause` 只落在私有字段，没有接入 `Exception.causedBy` —— 根因在框架日志里不可见

- **位置**：`f_dbd/src/common/DbdException.cj:51-56`（`super(message, sqlState, code.value)` + `this.cause_ = cause`）、`f_dbd/src/common/DbdException.cj:59-63`（payload 构造器同形）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失或静默」「语义与注释 / 契约不符」；§10 正确性（诊断面）
- **证据**：静态确定 —— 两个构造器调用父类时只传 3 个参数，`cause` 仅写进 `private let cause_`：
  - std 侧异常链的唯一载体是 `Exception.causedBy`（`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_exceptions.md:223` 构造器 `init(message: String, causedBy: Exception)`、`:238-241` `public mut prop causedBy: ?Exception`），`SqlException` 的 3 参构造器（`database_sql_package_api/database_sql_package_exceptions.md:6-10`）没有 cause 形参 ⇒ 本类实例的 `causedBy` 恒为 `None`；
  - 本仓既有约定是走父类：`f_email/src/model/MailException.cj:35-36`、`f_egraph/src/exception/GraphException.cj:29-31` 都是 `super(message, causedBy)`；按 `causedBy` 链遍历的代码有 `f_base/src/BaseException.cj:75`、`fdbm/src/server/handler.cj:39-48`；
  - 日志打印对非 `BaseException` 只输出顶层：`f_log/src/output/LogWriterImpl.cj:63-71` → `f_base/src/BaseException.cj:21-31`（打印 `exception` 的 `toString` + 自身栈，不跟 `causedBy`）；
  - 生产侧完全没有读 `.cause`：全仓 `grep "\.cause\b"` 在 `f_dbd`/`fdbm` 内只命中 `DbdException_test.cj:58/62/63/98` 四处；而生产写入点有 13 处（`common/result.cj:254,257,334,337,370,373,376` 共 7、`driver/DbdDatasource.cj:64,75` 共 2、`driver/DbdStatement.cj:187`、`multid/Datasource.cj:118,121` 共 2、`multid/Url.cj:98`）。
- **描述**：一次 `DbdException(IO, ..., cause: e)` 之后，调用方/日志只能看到包装消息（`SqlException.message` 还会追加 `, errorCode: N.`），`e` 的 message 与栈全部丢失：该 `DbdException` 的 `causedBy` 恒为 `None`，`f_log.writeException` 也只打顶层。断链、握手失败、单元格转换失败这类最需要原始异常的场景恰好全部依赖这个字段。现有用例（`DbdException_test.cj:53-64,93-99`）只断言"私有字段保真"，因此这个缺口不会被测试发现。
- **建议**：在构造器里把 cause 同步到标准链：`if (let Some(c) <- cause) { this.causedBy = c }`（`causedBy` 在 core 文档中声明为 `public mut prop`，可写性以所用 SDK 实测为准；若不可写，至少让 `cause` 与 `causedBy` 在文档中二选一并统一）。补一条用例断言 `DbdException(PROTOCOL, 'x', cause: root).causedBy.isSome()`，再顺带核对 `f_log` 打印是否带出 `Caused by:`。

### [一般][存量] #2 详细设计把 `readChunk(stream, size)` 的 `size <= 0` 写成「按块大小处理」，与实现的「读至 EOF」相反

- **位置**：`f_dbd/doc/详细设计.md:382`（`size <= 0` → 按 `DEFAULT_STREAM_CHUNK` 处理）；同一表述见 `f_dbd/doc/开发计划.md:115`（Step 1.8 用例 ④）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— 实现 `f_dbd/src/common/types.cj:405-421`：`let toEnd = size <= 0`，随后 `while (toEnd || got < size)` 一直读到 `read` 返回 0，即"读到流结束"；同函数文档注释 `types.cj:400` 写的是"`size <= 0` 表示**读至 EOF**（用于整块物化大对象）"，`f_dbd/doc/spec/reuse-read-buffers/design.md:70` 也写"`readChunk(stream, 0)` 读至 EOF"。文档的"按 `DEFAULT_STREAM_CHUNK` 处理"只能读成"本次只读一块 64 KiB"。
- **描述**：这不是措辞问题，两种语义会产出不同数据。`types.cj:368` 的 `SqlReadType.Stream` 分支正是 `readChunk(readStream(result, index), 0).toData()`（设计 §8「InputStream 列读到 EOF 后整块返回」）——若维护者照 §3.9 的表格"修正"实现，流列会被**静默截断成首块 64 KiB**，线上表现为大字段被截短且无任何错误（fdbm 侧 `readData` 同源）。反向风险同样存在：按文档写 fdbm 侧新代码、传 `0` 期望"取一块"，实际会一次读完整个大对象。
- **建议**：把 §3.9 该格改为"`size <= 0` → 读至 EOF（临时缓冲固定 64 KiB，总内存上界 = 已读字节 + 一块缓冲）"，并同步 `开发计划.md:115` 的用例 ④（现有用例 `ReadChunkReuse_test.cj:77-91` 的 `benchToEnd` 已按读至 EOF 断言，可作参照）。

### [一般][存量] #3 详细设计 §8 的「判定顺序 / 不做方言归一」与 §3.9 及实现相互矛盾，`Unknown → WARN` 的真实触发条件被写错

- **位置**：`f_dbd/doc/详细设计.md:950`（判定顺序：① 精确匹配 ② 去包名前缀 ③ 仍未命中 → `Unknown`；"**不做**去长度后缀 / 前缀匹配 / 方言长名等归一"）、`f_dbd/doc/详细设计.md:949`（把 `SqlVarchar` / `int4` / `BIGINT` / `bytea` / `timestamp with time zone` / `uuid` 列为"正常不该出现在线上、会落到 Unknown → 按 String 读 + WARN"）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」；同文 §3.9 行 378 与本处自相矛盾
- **证据**：静态确定 —— `f_dbd/src/common/types.cj:171-232` 的 `resolve()` 实际顺序是：`Sql*` 抽象名 → `TINYINT(1)` 特例 → 仓颉类型名 → 方言拼写 → `... unsigned` → 去 `(...)` 后缀 → `varchar*/character*` 前缀 → 未命中。`resolveSqlName`（`:259-275`）与 `resolveDialect`（`:320-344`）把 §8 举例的 `SqlVarchar`、`int4`、`BIGINT`、`bytea`、`timestamp with time zone` 全部映射到真实类型；`uuid`/`jsonb` 也在 `:334-338` 归到 `String`，**都不会**经过 `Unknown` 与 WARN。同文 §3.9 行 378 又写 `readType` "识别物理驱动的任意 `typeName` 写法（`Sql*` 抽象名 / 仓颉类型名 / 方言拼写）"，与 §8 的说法直接冲突。
- **描述**：类型映射是本模块协议正确性的核心（`ColumnInfoImpl.tn` 就是 `get<T>` 的 `T`）。按 §8 排查"列类型归一错"的人会去日志里找 WARN 线索，而实际不会产生任何 WARN；反过来，维护者若相信"方言拼写不会命中"，可能把 `resolveSqlName` / `resolveDialect` 当成死代码删掉，直接导致方言驱动的列全部退化成 `String`。`Unknown + WARN` 现在只对真正未收录的私有拼写生效。
- **建议**：§8 改为两句事实陈述：① fdbm 归一后的线上口径只有仓颉类型名；② f_dbd 的 `SqlTypes.resolve` 另有一层方言/抽象名兜底（顺序见 `types.cj:171-232`），只有两层都不命中才 `Unknown → String + WARN`，并把 §8 的举例行改成"这些拼写当前会被兜底识别（列在此处仅作回归用例集）"。

### [轻微][存量] #4 开发计划 Step 1.1 的实现要点仍把 `SqlPayload.params` 写成 `let`，与同一文件的硬约束和实现相反

- **位置**：`f_dbd/doc/开发计划.md:38`（"`params` 为 `let` 空 `ArrayList`"）；对照 `f_dbd/doc/开发计划.md:9`（硬约束："**禁止** `let` 字段……`SqlPayload.params` 曾照草图写成 `let`，已修为 `var`"）与 `f_dbd/src/common/payload.cj:32`（`private var params: ArrayList<DataAny>`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与代码一致性」
- **证据**：静态确定 —— 同一文件第 9 行与第 38 行对同一字段给出相反要求，代码取 `var`。
- **描述**：Step 1.1 的表格是 TDD 的"实现要点"，照它写会精确复现第 9 行点名过的那个 BUG（宏生成只读属性 ⇒ fdbm 解码 `CONSUME` 载荷时静默丢参数、严格解码抛 `DataException`）。因为 `params` 恰好是"往返用例"的回归红线，这处残留最容易误导下一位照表实现的人。
- **建议**：把第 38 行改成 `var`，并在表格里指向 §通用约定（payload 字段规则），避免同一约束写两遍再漂移。

### [轻微][存量] #5 测试辅助 `roundTrip` / 键集合提取跨文件重复，`implementsColumnInfo` 的断言与 `fullConstructor` 完全重复

- **位置**：`f_dbd/src/common/column_test.cj:30-38`（非泛型 `roundTrip`）vs `f_dbd/src/common/payload_test.cj:30-37`（泛型 `roundTrip<T>`）；`column_test.cj:94-98`（`toData()` 后遍历 `DataObject` 收集键名）vs `payload_test.cj:39-46`、`48-55`（`keysOfUpdateResult` / `keysOfServer` 同形循环）；`column_test.cj:115-124`（`implementsColumnInfo` 的 6 条断言）vs `column_test.cj:51-60`（`fullConstructor` 的 6 条断言）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 跨文件复制」
- **证据**：静态确定 —— 逐行比对：两处 `roundTrip` 只有类型参数与失败文案不同（`'decode failed'` vs `'decode<ColumnInfoImpl> failed'`），三处键集合收集的循环体逐字相同；`implementsColumnInfo` 与 `fullConstructor` 用同一组入参、同一组 6 个断言，唯一新增信息是 `let c: ColumnInfo = ...` 这行**编译期**赋值。
- **建议**：把 `roundTrip<T>` 与 `keysOf<T>` 收到一个共享测试工具文件（与本模块 `driver/testkit_test.cj`、`multid/stub_test.cj` 同风格，例如 `src/common/testkit_test.cj`），`column_test` 直接复用；`implementsColumnInfo` 保留类型化调用 + 一条代表字段断言（它的价值在类型化，不在 6 条重复断言）。文案差异若确有意义，用参数化消息保留。

### [轻微][存量] #6 `ColumnInfoImpl` 把 6 个线上键名以 `public mut` 属性对外暴露，`ColumnInfo` 的只读契约被实现类放宽

- **位置**：`f_dbd/src/common/column.cj:34-39`（`private var nm/tn/len/scl/nl/ds`，`@DataAssist[fields props]` 生成同名的 `public mut prop`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10（设计合理性 / 封装，语言特性：值语义与可变性）
- **证据**：静态确定 —— `c.nm = 'uid'` 这类写入在 `column_test.cj:72-77` 里是被显式断言支持的；`ColumnInfo` 接口（std `database_sql_package_interfaces.md:3-13`）只有 6 个非 mut 属性。
- **描述**：形态本身是设计 §3.4 规则 6 的既定取舍（`var` 才可解码），但副作用是：应用拿到 `Array<ColumnInfo>` 后可以 `as ColumnInfoImpl` 改写列名/类型，随后再次 `toData()` 编码就把被改的值发回对端；同时这 6 个短名（协议键）成了公开可写 API，重命名等于协议变更。当前类型注释只说明了"为什么用短名"，没有说明"应用不应写"。
- **建议**：实现保持不变（改成只读需要改 `f_data` 宏，超出本模块），在类型注释与 README 明确"这 6 个属性是线上协议字段，仅供编解码，应用只读"；若后续要收紧，评估给它们配只读别名、把 `mut` 属性降为 `internal`（需宏支持）。

## 优化可行性方案

> 本部分没有 profile / bench 数据可引用（`ReadChunkReuse_test` 的 bench 默认跳过），以下两条均为「无基线（待验证）」，不进 `tasks.md`。

### [堆内存] 每查询重建列信息对象与编码中间态，可按列签名复用只读列信息

- **现状**：每次 `query()` 首包解码都会得到 N 个 `ColumnInfoImpl`（6 字段），编码侧另有每个字段一个 `DataString`/`DataReal` 装箱与 `DataObject` 字段表；生命周期 = 一次结果集（`f_dbd/src/common/column.cj:33-51`）。
- **方案**：在 fdbm 侧（构造 `QueryResultServerPayload` 处）按 `(nm,tn,len,scl,nl,ds)` 六元组做有界缓存（容量 + 淘汰），命中即复用同一批列信息对象；缓存值必须发布为不可变。客户端侧（`QueryResultImpl` 构造）的对象随结果集存活，收益需单独评估，不在本条范围内。
- **预期**：待测。可量化口径 = 每次查询省下的 `ColumnInfoImpl` 个数 + `Data` 装箱个数 + 编码器遍历字段数。
- **代价**：缓存键构造成本；共享对象与 #6 的 `public mut` 属性冲突（必须先只读化，否则跨结果集串改）；列对象同一性变化可能影响下游 `===` 判断；缓存容量需要配置项。
- **验证**：`cjprof heap` + `getAllocatedHeapSize()`/RSS，10k 次 20 列查询、`-O2`，与改前同机对照中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ColumnInfoImpl.toData()` 走宏生成的字段表（按名遍历 6 次）

- **现状**：列信息编码/解码都经 `@DataAssist` 的通用字段表路径（按名查找 `MutableField`），每次首包编解码各一遍；单次成本小，调用频次 = 查询次数 × 列数（`column.cj:32-39`）。
- **方案**：若实测占比可观，为 `ColumnInfoImpl`/`QueryResultServerPayload` 留手写编码/解码快速路径（固定 6 字段顺序），保留宏路径作兼容。
- **预期**：待测（字段表查找次数 6→0，但需 profile 证明其占比）。
- **代价**：两份实现需同步（新增字段容易漏），代码量上升；对正确性无收益。
- **验证**：`cjpm bench -O2` 对 encode/decode 各 10⁶ 次取中位数与离散程度，`cjprof record` 看 `DataObject` 相关帧自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 列信息对象的分配与编码占查询首包开销的比例可能不低（宽表/高频短查询） | `f_dbd/src/common/column.cj:33-51` | 每次查询的分配字节数、`DataObject` 帧自耗时占比 | `cjprof heap` + 10k 次 20 列查询；`cjprof record` 看 `toData/convert` 帧 |
| 2 | 失败风暴下 `DbdException` 构造成本（两次 `payload.errorCode()` match + `SqlException.message` 拼接）可忽略，但未验证 | `f_dbd/src/common/DbdException.cj:59-63` | 每秒异常数上限、CPU 占比 | 注入 10k 次 `ERROR` 响应，`cjprof record` 取 `DbdException` 帧占比 |
| 3 | `readChunk` 单缓冲复用后 1 MiB「读至 EOF」的分配量是否与 `doc/spec/reuse-read-buffers/design.md:90` 的 5,436,040 B 基线一致（代码已演进） | `f_dbd/src/common/ReadChunkReuse_test.cj:77-91`（`F_DBD_BENCH=1` 已打印 alloc） | 5 轮 alloc 中位数与离散程度 | `F_DBD_BENCH=1 cjpm test --filter ReadChunkReuse_test --show-all-output`，同机 `-O2` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_dbd/doc/开发计划.md` | .md | ✅ | 与实现基本对齐；见 §13 问题 #4（`params` 写成 `let`）、#2（`readChunk` 用例 ④） |
| 2 | `f_dbd/doc/详细设计.md` | .md | ✅ | 与实现基本对齐；见 §13 问题 #2（`size<=0` 语义）、#3（§8 归一顺序与 §3.9 矛盾） |
| 3 | `f_dbd/src/common/DbdException.cj` | .cj | ✅ | 见问题 #1（`cause` 未接入 `causedBy`） |
| 4 | `f_dbd/src/common/DbdException_test.cj` | .cj | ✅ | 7 条用例覆盖两构造器/sqlState/cause/未知 code；仅断言私有字段，见 #1 |
| 5 | `f_dbd/src/common/ReadChunkReuse_test.cj` | .cj | ✅ | 覆盖 `readChunk` 跨块/EOF/空流与 `F_DBD_BENCH` 分配打印；无缺陷 |
| 6 | `f_dbd/src/common/column.cj` | .cj | ✅ | 见问题 #6（协议键短名对外可写）；`@DataExclude` 六项完整 |
| 7 | `f_dbd/src/common/column_test.cj` | .cj | ✅ | 覆盖默认值/全参/短名可写/线上键集合/接口实现/往返/严格解码；见 #5 |

合计：`.cj` 5 个 / `.md` 2 个 / 共 7 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | #1（诊断信息丢失，正确性-错误路径）、#3（设计-文档契约矛盾）、#6（设计-封装/可变性）、#5（可读性-测试重复）；本部分无外部输入、无 SQL 拼接、无凭据，安全性 0 条 |
| §1 死代码 | 0 | 已逐个符号搜引用：`DbdException.code_`/`cause_` 均被自身 `prop` 读取；`ColumnInfoImpl` 六个短名属性由宏（编码/解码）与 `column_test.cj:66-77` 使用，类本身被 `payload.cj:91,95`（字段/构造形参类型）与 `result.cj:70-75`（列信息逐项转换）使用；`PatternStream`（4 处）、`roundTrip`、`patterned`、`benchEnabled`、`settle` 均有调用者；无 `return/throw/break/continue` 后同层语句；5 个 `.cj` 的 `import` 全部命中使用点（`DataObject` 属 `f_data.base`，已核对 `f_data/src/base/DataObject.cj:67`）；`public` 声明所属顶层类型均对外可达，按硬原则一不判 |
| §2 重复逻辑 | 1 | #5（`roundTrip` / 键集合循环跨 `column_test`↔`payload_test` 复制、`implementsColumnInfo` 与 `fullConstructor` 断言重复）。另 `DbdException.cj:60-61` 对 `payload.errorCode()` 调了两次（`super` 实参与字段），属构造期微重复，未单列 |
| §3 空实现 | 0 | `ColumnInfoImpl.init() {}` 的 6 个字段都有声明处初值（设计 §3.4 规则 5 要求的解码形态），不是空契约；`benchToEnd` 的跳过分支有显式 `println` 与 `F_DBD_BENCH` 开关；范围内无 `TODO`/`FIXME`/`catch {}` |
| §4 栈溢出 | 0 | 范围内无递归（`PatternStream.read` 为线性；`roundTrip` 不递归）；无自引用结构遍历 |
| §5 OOM | 0 | 范围内无按报文长度预分配、无无界容器；`ReadChunkReuse_test` 的 1 MiB 为测试常量；列信息数组的元素上限校验属 `payload.cj` 部分 |
| §6.1 热点瓶颈 | 0 | 无任何 profile/bench 数据（bench 用例默认跳过），不成立为发现；已转「待验证假设」3 条 |
| §6.2 大粒度锁 | 0 | 范围内无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 范围内无 `spawn`/`Future`/线程池 |
| §6.4 低效算法 | 0 | 范围内循环均为单遍线性（键集合收集 6 项、`patterned` 一次填充）；无 `contains` 热路径、无 `remove(at: 0)` |
| §7 降堆内存方案 | 1 | 列信息对象复用（无基线，待验证） |
| §8 降 CPU 方案 | 1 | 列信息编解码快速路径（无基线，待验证） |
| §9 local mode 可行性 | 0 | 范围内对象全部逃逸：`ColumnInfoImpl` 进结果集/网络载荷、`DbdException` 抛给调用方并可能进日志；无"函数内创建、函数内销毁"的大对象，改造不成立 |
| §11 现有代码的 BUG（存量） | 1 | #1；另核对了 `DbdException` 两构造器（参数顺序、`sqlState`/`code` 传递、未知 code 兜底）与 `ColumnInfoImpl` 六个属性的读写/排除，未发现边界或空值缺陷 |
| §12 并发安全与锁粒度 | 0 | 本部分无共享可变静态状态（`SqlTypes.logger` 在 `types.cj`）；`ColumnInfoImpl` 的 `mut` 属性未承诺线程安全，跨线程共享由调用方负责（std `ColumnInfo` 同样不承诺），故不构成"共享路径无同步" |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 README（由其他部分核对）；`DbdException`、`ColumnInfoImpl` 的公开成员在详细设计 §3.7/§4 都有对应条目，未见"承诺但未实现"；`src/exception/` 重导出不在本部分 |
| 文件覆盖（§13 等） | 7/7 | 7 个文件全部读完，无缺；§13 文档一致性命中 3 条（#2 `readChunk` 语义、#3 类型归一顺序、#4 `params` 写成 `let`） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分的代码本体（异常类型 + 列信息线上载体 + 3 个测试文件）是干净的：无并发、无句柄/连接资源、无不可达语句、无无界容器，`@DataExclude` 与短名键集合的回归用例写得比多数模块扎实。真正的问题集中在两处**跨层契约**：

1. **诊断链断裂**（#1）：`DbdException.cause` 是 13 个生产调用点都在写的字段，却既不进 `Exception.causedBy`，也没有任何生产代码读取，`f_log` 打印时根因直接消失。断链/握手/转换失败恰恰最需要它，属应排期修的一般项（修法很小：构造器里同步 `causedBy`）。
2. **文档与实现相反**（#2、#3）：`readChunk(size<=0)` 的语义写反，若照文档"修正"代码会让流列静默截断；§8 的类型归一判定顺序与 §3.9 和实现三方不一致，会让排障者找不到 WARN 线索、也可能诱使后来者删掉 `resolveSqlName`/`resolveDialect`。两处都应随下一轮文档回填一次改齐。

无阻塞发布项：本部分不含协议状态机与连接生命周期，无法就这两项下总体结论（见其余 4 个部分）。存量缺陷共 6 条（3 一般 + 3 轻微），是否纳入修复待用户决定；两条优化方案均无基线，只作下轮补数据用。
