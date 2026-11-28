# f_dbd 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（69 个文件：49 个 .cj + 20 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 5 个分部分报告合并：`parts/f_dbd.part1..5.md`）

## 发现

<!-- 第 1 部分 -->

### [一般] README 的连接选项键名写成 camelCase，实现只认 `SqlOption` 的 snake_case，四项设置按文档写会静默失效

- **位置**：`f_dbd/README.md:81-83`（`connectionTimeout` / `queryTimeout` / `updateTimeout` / `fetchRows`）、`f_dbd/README_en.md:88-90`；实现 `f_dbd/src/driver/DbdOptions.cj:47-71`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§14.2「关键配置项写错导致按文档用不起来」
- **证据**：静态确定 —— `DbdOptions.apply` 用 `SqlOption.ConnectionTimeout` / `QueryTimeout` / `UpdateTimeout` / `FetchRows` 做字符串精确比较；std 文档 `cangjie-doc/.../std/database_sql/database_sql_package_api/database_sql_package_classes.md:4589-4592` 明确这四个常量为 `connection_timeout` / `update_timeout` / `query_timeout` / `fetch_rows`
- **描述**：照 README 传 `opts = [("queryTimeout", "30000")]` 会落进 `else` 分支，只打一条 DEBUG（`DbdOptions.cj:72-74`）就被丢弃：查询超时退化为 6 小时上限（`DbdTransport.cj:32`），`fetch_rows` 退化为 64 KiB，且**没有 WARN**，用户无法从日志发现配置没生效。`username` / `password` 是单词、无下划线，恰好不受影响，因此问题只暴露在超时与分块上。同一模块的变更文档用的是正确拼写（`doc/spec/harden-fdbm-stack-defects/spec.md:272-273` 写的是 `query_timeout`），只有 README 两份是 camelCase
- **建议**：README 两处表格改为 `connection_timeout` / `query_timeout` / `update_timeout` / `fetch_rows`；若希望保留 camelCase，则须在 `DbdOptions.apply` 里同时识别两种拼写，不能只改文档一半。`README_en.md` 同步

### [一般] README「其他公开 API」把 `protected struct MultiDConfig` 的 14 个静态方法当成模块级公开 API（外部不可达），同时漏列 4 个 public 常量与 3 个 public 成员

- **位置**：`f_dbd/README.md:165`（`getCheckInterval` … `getWeights` 被列在「模块级」）、`f_dbd/README_en.md:184`；实现 `f_dbd/src/multid/Config.cj:29`、`f_dbd/src/dbd.cj:25-27`
- **来源**：存量
- **判据**：review-checklist §14.2「公开 API 未文档化 / 索引失准」、§1 硬原则二（非公共顶级声明里的 `public` 成员对外不可达）；语言可见性依据 `cangjie-doc/md/doc/cj_syntax.md:66`「`protected` — 当前模块及当前类的子类可见」
- **证据**：静态确定 —— `MultiDConfig` 是顶层 `protected struct`，`struct` 无子类，故这 14 个 `public static func` 只在 `f_dbd` 模块内可见；根包 `dbd.cj:25-27` 只重导出 `common.*`、`driver.{DbdDriver,DbdUrl,dbdDriver}`、`multid.{MultiD,MultiDUrl,MultiDatasource}`，没有也不该有 `MultiDConfig`。反向核对公开声明全集（`grep '^public '`）：`NEXT_ROW`、`DEFAULT_PORT`、`DEFAULT_STREAM_CHUNK`、`CELL_READ_FLAG` 四个 public 常量、`DbdStatement.setOption`、`DbdDriver.init(name:)`、`DbdErrorCode.parse` 在 README 中均检索不到
- **描述**：下游照 README 调 `getCheckInterval()` 会直接解析不到符号（README 却把它标成「模块级」，与 `fdBDVersion` 同级）；反过来，真正对外可达的四个协议常量（`NEXT_ROW = -1` 等，`types.cj:28-40`）没有任何文档，使用者若自己拼 `QueryResultColumnPayload` 只能读源码。这份清单是按「`public` 修饰符」机械导出的，没有按「对外可达性」过滤
- **建议**：14 个 `get*` 从「模块级」移出，改为一句「内部配置读取（`protected struct MultiDConfig`，不对外）」；补齐 4 个 public 常量（至少要说明 `NEXT_ROW` 与 `bufSize` 的保留值语义）与 `DbdStatement.setOption`、`DbdDriver.init(name:)`、`DbdErrorCode.parse`。若这 14 个方法本就不打算对外，也可顺手把 `MultiDConfig` 收成 `internal`，让清单导出规则不再误伤

### [一般] README 未记载两项用户可见的硬限制：连接级结果集独占（`CURSOR_STATE`）与事务三属性「只记录、不下发」

- **位置**：`f_dbd/README.md` 全文（缺「限制与注意事项」段落；`CURSOR_STATE` 只在 `:143` 的错误码枚举里出现，`:163-182`「其他公开 API」只列方法名）、`f_dbd/README_en.md:159-201`；承诺源 `doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-dbd/spec.md:257-261`（MUST）；实现 `src/driver/DbdConnection.cj:124-135`、`src/driver/DbdStatement.cj:150-155`、`src/driver/DbdTransaction.cj:24-29,44-69`
- **来源**：存量
- **判据**：review-checklist §14.2「缺关键段落：限制与注意事项」、§13「文档承诺与实现口径」
- **证据**：静态确定 —— 全仓检索 README 无「独占」（`grep -n "独占" README.md` 无命中）；`DbdConnection.ensureNoOpenResult` 在结果集未 `close()`（含已 `next()==false` 但未关）时对任何新 SQL 抛 `CURSOR_STATE` 且不发包；`DbdTransaction` 的 `accessMode` / `deferrableMode` / `isoLevel` 只写成员字段，`begin`/`commit` 透传固定文本 `'begin'` / `'commit'`（`:76,82`），属性值不进任何报文
- **描述**：两种最常见的误用都会在无提示的情况下失败或失效：① 遍历结果集时顺手复用同一 `Connection` 执行另一条 SQL → 直接 `CURSOR_STATE`，README 只把该码列进枚举，用户无从知道要先 `close()`；② `tx.isoLevel = Serializable` 之后以为隔离级别已生效，实际报文只有 `begin`，服务端按默认隔离级别跑。README 是唯一面向接入方的入口文档，这两条目前只写在 `详细设计.md` / 变更 spec 里
- **建议**：README 增「限制与注意事项」小节，至少三条：① 一条连接同一时刻只允许一个未 `close()` 的结果集，否则 `CURSOR_STATE`（含「已耗尽未关闭」）；② 事务三属性只记录不下发，需要方言级隔离级别请直接写 SQL；③ savepoint 名必须匹配 `[A-Za-z_][A-Za-z0-9_]*`，否则 `PROTOCOL`。`README_en.md` 同步

### [轻微] README 的 `DbdDatasource` 构造签名写成 `url: String`，实现是 `url: DbdUrl`

- **位置**：`f_dbd/README.md:25`、`f_dbd/README_en.md:26`；实现 `f_dbd/src/driver/DbdDatasource.cj:34`
- **来源**：存量
- **判据**：review-checklist §13「API 签名与源码不符」
- **证据**：静态确定 —— `public init(url: DbdUrl, opts!: Array<(String, String)> = [])`；与同表下一行 `MultiDatasource(url: String, …)`（`src/multid/Datasource.cj:44`）对照可知是把两者抄混了
- **描述**：照 README 写 `DbdDatasource("fdbm://…")` 编译失败；且 `DbdUrl` 的构造器是 `init`（包内），外部只能经 `DbdUrl.parse` / `Driver.open` 拿到，README 没有交代这条路径
- **建议**：改为 `DbdDatasource(url: DbdUrl, opts!…)`，并补一句「常规用法是 `dbdDriver().open(url, opts)` 或 `DbdUrl.parse` 后构造」

### [轻微] harden 变更文档的 P1 条数自相矛盾：29 / 33 两种口径并存，`29 + 8 + 9 = 46 ≠ 51`

- **位置**：`f_dbd/doc/spec/harden-fdbm-stack-defects/proposal.md:6`、`design.md:41`、`tasks.md:13`（均写「29 个 P1」）；`design.md:227-232`、`design.md:438`（写 33）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移 / 前后不自洽」
- **证据**：静态确定 —— `design.md:41`「51 条 → P1 29 项 + 并入 P0 8 条 + P2 9 条（无遗漏、无重复）」三项相加为 46；同文 §5 表给出「修复 33 / 并入 8 / 补测试 9 / 记录不修 1」= 51，附录 A 统计也写「P1 族 33 条次」
- **描述**：这条变更的全部价值在于「51 条逐条可追溯」，而 29/33 的差异正好落在 4 条一般项上，会让人怀疑附录 A 有遗漏或重复；`tasks.md:13` 的「12 P0 + 29 P1 + 12 P2」同样沿用了错值
- **建议**：统一为 33（P1 修复族）+ 8（并入 P0）+ 9（P2）+ 1（记录不修，G25）= 51，并回改 `proposal.md:6`、`design.md:41`、`tasks.md:13`

### [轻微] `harden-fdbm-stack-defects` 的 `spec.md` 与 `specs/f-dbd/spec.md` 完全相同，同一规格存在两份副本

- **位置**：`f_dbd/doc/spec/harden-fdbm-stack-defects/spec.md` 与 `f_dbd/doc/spec/harden-fdbm-stack-defects/specs/f-dbd/spec.md`
- **来源**：存量
- **判据**：review-checklist §2「重复内容」、§13「规格可追溯性」
- **证据**：静态确定 —— `diff -q` 无差异，两份均为 12,611 字节（280 行）
- **描述**：OpenSpec 变更目录的规范位置是 `specs/<capability>/spec.md`，顶层 `spec.md` 是拆分前的旧形态残留。两份内容一致时无害，但只要后续只改一份（下次 MODIFIED 极易发生），就会出现「以哪份为准」的歧义，而这两份又正好是 `f_dbd` 协议口径（流列、B 口径、URL）的规范来源
- **建议**：保留 `specs/f-dbd/spec.md` 作为唯一规格，删除顶层 `spec.md`；或把顶层文件改成一行「见 `specs/f-dbd/spec.md`」的指针

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

### [一般][存量] #1 类型归一表缺 `int(…)` 与 `real`：MySQL / PG 的常见数值列被降级成 `String`

- **位置**：`f_dbd/src/common/types.cj:250-256`（`PAREN_BASES` 里只有 `integer`、没有 `int`）、`f_dbd/src/common/types.cj:320-345`（`resolveDialect` 有 `float4`/`float`、没有 `real`）、`f_dbd/src/common/types.cj:213-227`（去括号后缀的重试分支）
- **来源**：存量（`git blame`：`ef7b9b06ee 2026-10-18`，`af3ca77d8` 只改了 `readChunk`，未动归一表）
- **判据**：review-checklist §11「契约与实现不符 / 语义与命名不符」、§10 正确性（类型映射）；fountain-baseline §2「驱动上报的就是仓颉类型名」
- **证据**：静态确定 —— 按 `resolve()`（`types.cj:171-233`）的判定顺序逐条走一遍：
  1. `'int(11)'`：`resolveCangjieName('int(11)')` 无命中 → `resolveDialect('int(11)')` 无命中 → `key.contains('(')` 分支调 `parenBaseOf('int(11)')`，`PAREN_BASES` 里 `'integer'`、`'mediumint'`、`'bigint'`、`'tinyint'`、`'smallint'` 都不是 `'int(11)'` 的前缀，`'int'` 根本不在表里 ⇒ 返回 `None`；
  2. `'int(11) unsigned'`：`resolveUnsigned('int(11)')` 无命中 → `parenBaseOf('int(11)')` 同上无命中 → 仍 `None`；
  3. `'real'`：`resolveCangjieName` / `resolveDialect` 都没有该拼写（表里只有 `'float4' | 'float'`）⇒ `None`。
  三条都落到 `SqlTypes.readType` 的 `Unknown`，`canonicalName` 则命中 `types.cj:158-161` 的兜底 `'String'` 并打一条 WARN。
- **描述**：MySQL 8.0.19 之前与 MariaDB 的列定义常带显示宽度（`int(11)`），驱动把 `ColumnInfo.typeName` 报成该拼写时即命中本条（具体驱动是否保留宽度需按驱动版本实测；但无论宽度是多少，归一表缺 `int` 都落到同一结果）；PostgreSQL 的 `real` 是核心类型，属表项缺漏。这两类列现在会被上报成 `String`：`fdbm` 的 `QueryCursor` 把它当文本格读（`SqlTypes.readData` 的 `Unknown` 分支 → `cellOf<String>`，`types.cj:370-372`），`ColumnInfo.typeName` 传给客户端也是 `'String'`。数据本身还能靠 `DataString → Int64` 的宽松转换读出来（`CELL_READ_FLAG` 含 `THROWING_ON_INT_OVERFLOW`），所以**不会报错、只会类型漂移**：`f_orm` / 业务侧按 `String` 拿到的数值列会走字符串比较与字符串排序（`'10' < '9'`），且每次读格都多打一条 WARN。仓内测试只覆盖了 `varchar(64)` / `decimal(10,2)` / `TINYINT(1)`（`sqltypes_test.cj:105-109`），`int(11)` 与 `real` 没有任何用例。
- **建议**：`PAREN_BASES` 在 `'integer'` 之后补 `'int'`（顺序不能放在 `'integer'` 之前，否则 `integer(11)` 会先命中 `'int'` 而少一次精确匹配；两者都映射 `Int32`，放后面最安全），`resolveDialect` 在 `'float4' | 'float'` 一行补 `'real'`；再在 `sqltypes_test` 加 `readType('int(11)') == I32`、`canonicalName('real') == 'Float32'`、`canonicalName('int(11) unsigned') == 'UInt32'` 三条回归。

### [一般][存量] #2 `decodeStrict` 的 flag 恒为 `0`，与紧邻注释的结论正好相反；"严格解码"对同型载荷不做任何字段级校验

- **位置**：`f_dbd/src/common/types.cj:52-58`（`convert<T>(data, flag: DEFAULT_DATA_FLAG & !SILENCE)`）与 `types.cj:43-51` 的注释；对照 `f_data/src/base/global_objects.cj:51`（`DEFAULT_DATA_FLAG = SILENCE`）
- **来源**：存量（`git blame`：`ef7b9b06ee 2026-10-18`；`f_data` 侧把 `DEFAULT_DATA_FLAG` 从 `WRAPPING_ON_INT_OVERFLOW | SILENCE` 改成 `SILENCE` 是 `f8b45cccde 2026-10-15`，本行写于其后）
- **判据**：review-checklist §11「语义与注释不符 / 错误处理缺失」、§3「静默吞异常」、§10 正确性
- **证据**：静态确定（flag 取值）+ 待确认（真实影响面）——
  - `DEFAULT_DATA_FLAG` 的值就是 `SILENCE`（`f_data/src/base/global_objects.cj:42-51`），而 `!` 在整数上是**按位求反**（`cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/basic_operators.md:265`、`Appendix/operator.md:14`），所以 `SILENCE & !SILENCE == 0`；注释 `types.cj:49-50` 自己写着"**为什么不能取 `flag: 0`**：…`flag: 0` 时所有含整数字段的载荷都解不出来"，代码算出来的正是这个被禁止的值。
  - 现状没有炸，靠的是 `f_data` 的**类型快路径**：`DataObject<T>.populate(src, flag)` 在 `src` 运行时类型恰好是 `DataObject<T>` 时直接 `return d.data`（`f_data/src/base/DataObject.cj:208-213`），字段级转换整段被跳过。于是 `decodeStrict` 对"类型恰好对得上"的载荷（`types_test.cj:28-38`、`DbdTransport_test.cj:58` 全部属于这一类：服务端编过该类型 ⇒ 本进程 `typeMurmurCreators` 里登记的就是 `DataObject<T>` 的 creator，见 `f_codec/src/default/DefaultCodec.cj:88-95`、`963-985`）等于**原样返回，没有做任何"字段缺失 / 类型不匹配 / 无法转换"的校验**——注释承诺的严格性并不存在。
  - 反过来，一旦输入不是 `DataObject<T>`（`DataAny` 之外的包装、自定义 `SimpleDataObject` 实现、`DataCollection` 里的同形元素等），`populate` 会走逐字段 `set(..., flag: 0)`；而此时 `Int64.tryFromData(DataReal, 0)` 落到 `f_data/src/base/NumberData.cj:252-253` 的 `case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException(...)` ⇒ **任何含整数字段的载荷必然解不出**，被 `decodeStrict` 吞成 `None`。调用方拿到 `None` 后走的是 `PROTOCOL` / `CONVERSION` 分支（`DbdTransport.cj:126-131`、`DbdStatement.cj:86-90`），错误码与 `sqlState` 全部丢失。
- **描述**：这条是"注释写的与代码算的不一致"，属于潜伏型：今天能跑是因为快路径遮住了，任何一次把载荷改成非 `DataObject<T>` 形态（例如统一包一层 `DataAny`、或换用自定义 `SimpleDataObject` 实现）都会让所有带 `Int64` 字段的载荷（`QueryResultColumnPayload.index/bufSize`、`UpdateResultPayload.rc/liid`、`DbdErrorPayload.code`）一次性变成解不出。
- **建议**：把 flag 显式写成策略位，例如 `convert<T>(data, flag: THROWING_ON_INT_OVERFLOW)`（`types.cj:40` 的 `CELL_READ_FLAG` 已示范该位；严格语义要求**不带**任何 `IGNORE_*`，所以不能直接复用 `CELL_READ_FLAG`）。同时在 `types_test` 补一条"字段缺失 / 类型不符的非同型对象 → `None`、字段齐全的同型对象 → `Some`"的用例，把两条路径都钉死；并把注释改成"flag 必须显式带一个溢出策略位"。

### [一般][存量] #3 `DbdConnection.close()` 与 `registerResult()` 缺状态互斥：并发下新游标会脱离登记、永不关闭

- **位置**：`f_dbd/src/driver/DbdConnection.cj:97-113`（`close()`）、`DbdConnection.cj:137-142`（`registerResult()`）、`DbdConnection.cj:124-135`（`ensureNoOpenResult()` 不检查 `closed`）
- **来源**：存量（`git blame`：`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入 / 跨线程资源」、§11「资源不对称」；`fountain-baseline` 无相反约定
- **证据**：静态确定（代码路径确定）／触发需并发（需实测）——`activeResult` 只在 `Mutex` 内读写，但 `close()` 把"置 `closed`、取 `activeResult`"和"把 `activeResult` 清空"拆成了两个临界区（`98-101` 与 `109-111`），中间夹着 `r.close()` 的阻塞 I/O。于是存在这条交错：线程 A 进入 `close()`，锁内置 `closed = true` 并取走 `pending`，随后在锁外等 `UNSUBSCRIBE` 的 ACK；线程 B 的 `DbdStatement.query()` 此时没有被拦住（`ensureNoOpenResult` 只判 `activeResult`，不判 `closed`），发完 SQL、拿到首包后调 `registerResult`（`DbdStatement.cj:96`）把新结果集写进 `activeResult`；A 回来后执行 `activeResult = None`（`110`）——新结果集既不在连接上登记，也不会再被任何 `close()` 关闭：服务端游标（`qid`）与本地 `streams_` 句柄一直留到 `DbdConnection` 被 GC，而 `transport.close()` 已在其后执行，该结果集后续 `next/get` 只会拿到 `IO`。
- **描述**：`DbdConnection` 自带 `Mutex`（`40`），说明作者按"会被多线程调用"设计（`f_dbpool` 池化后连接会在不同请求线程间传递），因此这条交错不是纯理论。同类次级问题：`ensureNoOpenResult` 与 `prepareStatement` / `createTransaction` 在 `closed == true` 之后仍放行，调用方看到的是 `IO`（transport 已关）而不是明确的"连接已关闭"状态错误。
- **建议**：把 `closed` 纳入两处闸门——`registerResult` 在锁内 `if (closed) throw DbdException(CURSOR_STATE, ...)`，`ensureNoOpenResult`（及 `prepareStatement`）同样先判 `closed`；`close()` 改成"锁内取走 `pending` 并把 `activeResult` 立刻置 `None`"，`r.close()` 仍在锁外做，避免第二次临界区覆盖新登记。补一条并发用例：一个线程反复 `close()`、另一个线程反复 `prepareStatement(...).query()`，断言"凡是 `query()` 返回的结果集，最终都 `isClosed()`"。

### [一般][存量] #4 `SqlTypes.readData` 的流列分支整块物化 LOB，没有长度上限

- **位置**：`f_dbd/src/common/types.cj:368`（`case SqlReadType.Stream => readChunk(readStream(result, index), 0).toData()`）、`types.cj:405-422`（`readChunk` 的 `size <= 0` 语义 = 读至 EOF）
- **来源**：存量（`git blame`：`eda252b8f 2026-10-16` 引入"流列整读"，`af3ca77d8` 改成复用缓冲）
- **判据**：review-checklist §5「一次性物化 / 无拒绝路径」、§11「资源与边界」
- **证据**：静态确定（无任何上限判断）+ 需实测（真实 LOB 长度分布）——`readChunk(..., 0)` 的循环条件是 `while (toEnd || got < size)`，`toEnd` 恒真时只有"流返回 0"才退出，途中 `out.add(all: buf[0..n])` 把每一块追加进 `ArrayList<Byte>`，直到 `toArray()` 再整体复制一次。
- **描述**：`fdbm` 的正常游标路径已按块读流（`fdbm/src/execute/cursor.cj:169-187`），所以这条分支只在"把流列直接交给 `readData`"的调用点生效：`fdbm/src/execute/executors.cj:404` / `636` / `1051` 都传 `query.columnInfos[0].typeName` 或 `typeName`，命中 `std.io.InputStream` 列时会先读至 EOF 再 `toData()`。峰值内存 ≈ `n（LOB 字节数） + 64 KiB`，`ArrayList` 扩容期间另有 1.5–2× 的旧数组暂存，最坏到 2–3 n；没有 size 上限、没有拒绝路径、也没有可配置的阈值。一个 1 GiB 的 `bytea` 列（或攻击者可控的大对象）会直接把进程堆顶到 2–3 GiB。
- **建议**：`readData` 的 `Stream` 分支加一个显式上限（常量或配置，例如 `maxLobBytes`），超限抛 `DbdException(CONVERSION, 'LOB of column ... exceeds ...')`——比 OOM 崩溃可诊断得多；需要全量内容的场景由调用方改用 `readStream(result, index)` 自己分块。同时在 `SqlTypes` 的文档注释里写清"该分支会整块物化"，避免下一个调用方误以为它是流式。

### [轻微][存量] #5 流列字节解码的两段 `try/catch` 重复，差异只有错误文案前缀

- **位置**：`f_dbd/src/common/result.cj:326-338`（`openStreamAsAny` 的探测解码）、`result.cj:362-377`（`requestBlock` 的块解码）
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2「只改字面量 / 同输入-输出-副作用」
- **证据**：静态确定 —— 两段结构逐行对齐：`try { match (SqlTypes.decode<Array<Byte>>(x)) { case Some(b) => b; case None => throw DbdException(CONVERSION, '<前缀> is not a byte array') } }` + `catch (DataException)` / `catch (OverflowException)` / `catch (Exception)` 三个包装分支，异常码统一 `CONVERSION`；唯一差异是 `'stream probe of column'` 与 `'stream block of column'` 两个前缀，以及 `requestBlock` 多一个 `DataNone → 空数组` 的前置判断。
- **描述**：两处的 `DataException` / `OverflowException` / `Exception` 分支文案也不同（一处合并写、一处分开写），后续想统一错误格式时容易只改一处，形成行为漂移。
- **建议**：抽成 `private static func bytesOf(data: Data, what: String, index: Int64): Array<Byte>`（内部统一三个 catch），两处只传 `what`；`DataNone` 的短路留在 `requestBlock` 里。

### [轻微][存量] #6 自己抛出的 `DbdException` 被同层 `catch (e: Exception)` 再包一层，消息重复

- **位置**：`f_dbd/src/common/result.cj:329-331` → `335-338`；`result.cj:365-367` → `374-377`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §11「错误处理」、§10 正确性（异常链）
- **证据**：静态确定 —— `case None => throw DbdException(CONVERSION, '... is not a byte array')` 写在 `try` 块内，同一 `try` 的 `catch (e: Exception)` 会接住它并重新抛 `DbdException(CONVERSION, '... is not a byte array: ${e.message}', cause: e)`。
- **描述**：最终错误文案变成 `... is not a byte array: DbdException: ... is not a byte array`，`cause` 指向自己刚造的那个异常；排查时容易误以为有两层失败。严重度低（码值仍是 `CONVERSION`），但异常链是给使用者看的对外契约。
- **建议**：在 `catch (e: Exception)` 之前加 `catch (e: DbdException) { throw e }`，或把 `None` 分支移到 `try` 外先判掉。

### [轻微][存量] #7 `DbdOptions.apply` 三个超时 key 的分支逐行重复

- **位置**：`f_dbd/src/driver/DbdOptions.cj:57-71`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2「只改字段名」
- **证据**：静态确定 —— `ConnectionTimeout` / `QueryTimeout` / `UpdateTimeout` 三块各 5 行，`timeoutOf` 调用与 `case None => ()` 的注释（只有第一块写了注释）完全同构，只有赋值目标字段不同。
- **描述**：加第四个超时（例如 `transaction_timeout`）必须再抄一遍；`None => ()` 的"保留原值"注释只在第一块出现，另两块靠读者推断。
- **建议**：`match (key)` 先选出一个 setter 闭包（或返回 `?DbdOptions -> ?Duration` 的写入口），再统一 `match (timeoutOf(key, value))`，注释只写一次。

### [轻微][存量] #8 `dispatch_perf_test` 默认就跑约 4.8×10^8 次分派，没有像同包基准那样做开关门控

- **位置**：`f_dbd/src/common/dispatch_perf_test.cj:47-51`（`WARMUP = 10_000` / `LOOPS = 1_000_000` / `ROUNDS = 5`）、`dispatch_perf_test.cj:60-116`（19 个类型 × 4 组合 + 5 个未命中探针 × 4 组合）
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §10 可维护性（测试成本）、§14.1「半成品/接线」的邻居约定
- **证据**：静态确定 —— 计算量 = (19 + 5) × 4 × (10^4 + 5 × 10^6) ≈ 4.8×10^8 次分派调用，全部走 `println` 输出；而同包 `ReadChunkReuse_test.cj:76-91` 的 `benchToEnd` 用 `F_DBD_BENCH == 1` 门控（`benchEnabled()`，`101-106`），只有显式打开才跑。
- **描述**：`cjpm test` 默认会执行本类，把一次普通回归变成数秒到数十秒的基准跑，且输出大量表格；CI 上它与功能用例混在一起，失败时难以区分"用例错"与"机器噪声"。
- **建议**：沿用 `F_DBD_BENCH` 门控（或 `@Configure` + `@Skip`）：未开启时只跑 `semanticDifferenceOnInterfaceImplementor` 与 `nullShortCircuit` 这两个语义断言，性能矩阵在开启时才跑。

### [轻微][存量] #9 测试里存在完全同体的用例与同体的桩助手

- **位置**：`f_dbd/src/common/result_test.cj:441-450` 与 `result_test.cj:454-463`（`emptyBlobIsSomeEmptyStream` / `probeIsBackwardCompatibleWithOldServer`）；`f_dbd/src/common/types_matrix_test.cj:198-209`（`matrixResult`）与 `f_dbd/src/common/sqltypes_test.cj:332-343`（`mockResult`）
- **来源**：存量（`ef7b9b06ee` / `eda252b8f`）
- **判据**：review-checklist §2「同输入-输出-副作用」
- **证据**：静态确定 —— 两个用例的准备、断言、顺序完全一致（`addBlock([])` → `getOrNull<InputStream>` → `isSome` → `read` 为 0）；两个助手函数体逐行一致（`MOCKDB.clear()` / `MOCKDB.execution = {...}` / `toThrowOnExecuting = false` / `prepareStatement` / `query` / `next`），只有函数名不同，且同属 `fountain::f_dbd.common` 包。
- **描述**：`probeIsBackwardCompatibleWithOldServer` 的注释声称验证"旧服务端把 -1 当 <=0 返回首块"，但桩 `StubSender.send`（`result_test.cj:591-600`）对 `bufSize < 0` 只在 `nullProbe` 为真时回 `DataNone`，否则一律按块游标返回 —— 用例并没有构造出与 `emptyBlobIsSomeEmptyStream` 不同的输入，所谓"向后兼容"实际没被覆盖。
- **建议**：两个用例合并成一个（或真的给 `StubSender` 加"旧服务端语义"开关再保留两条）；`mockResult` / `matrixResult` 保留一个，另一个删掉或改名转调。

### [轻微][存量] #10 `sqltypes_test.cj:172-174` 的注释与当前实现相反

- **位置**：`f_dbd/src/common/sqltypes_test.cj:172-175`
- **来源**：存量（`eda252b8f 2026-10-16` 之后未同步）
- **判据**：review-checklist §11「语义与注释不符」、§13 同类（文档/注释与实现一致性）
- **证据**：静态确定 —— 注释写"当前实现按 `Int64.Max` 申请，会抛分配失败"，而 `types.cj:405-422` 已改成固定 64 KiB 缓冲分块读（`Array<Byte>(DEFAULT_STREAM_CHUNK, repeat: 0u8)`）；`f_dbd/src` 里 `Int64.Max` 只出现在这条注释本身与 `types_test.cj:70/73`（`UpdateResultPayload.rc` 的越界用例），`readChunk` / `encodeParameter` 中没有任何按剩余长度整块申请的分支。
- **描述**：这条注释是用来解释"为什么必须有 `encodeParameterStreamReadsToEnd` 这个用例"的，留着会误导后来人以为代码里还有一处待修的大分配。
- **建议**：改成描述历史（"旧实现按剩余长度整块申请"）或直接删掉后半句。

### [轻微][存量] #11 类型归一对 `sql` 前缀短路返回，未命中的 `Sql*` / `sql_…` 拼写不再走后面的方言表

- **位置**：`f_dbd/src/common/types.cj:181-184`（`if (key.startsWith('sql')) { return resolveSqlName(...) }`）
- **来源**：存量（`ef7b9b06ee`）
- **判据**：review-checklist §11「分支只做了一半」、§10 正确性（类型映射）
- **证据**：静态确定（控制流）+ 待确认（是否有驱动真的上报这类名字）—— `resolveSqlName`（`259-275`）只覆盖 21 个 `Sql*` 抽象名；`return` 之后 `TINYINT(1)`、`resolveCangjieName`、`resolveDialect`、`unsigned`、去括号、前缀匹配六条后续规则全部跳过。例如 `sql_variant`（MSSQL）或 `sqlbit` 会直接落 `None`，而同样的拼写不带 `sql` 前缀时 `bit` 是能映射到 `Array<Byte>` 的。
- **描述**：前缀判断假设"以 `sql` 开头的只可能是 `Sql*` 抽象名"，但方言里确实存在 `sql_` 开头的类型名；命中不了也不会报错，只是静默降级成 `String` + WARN（与本报告 #1 同一个后果面）。
- **建议**：改成"命中则返回，未命中继续往下走"（`match (resolveSqlName(...)) { case Some(n) => return Some(n); case _ => () }`），与 `types.cj:189-196` 的写法保持一致。

<!-- 第 4 部分 -->

### [一般][存量] #1 参数 index 没有上界，`sqlPayloadOf` 按最大 index 全量物化 —— 一个错误下标就挂死 + 吃光内存

- **位置**：`f_dbd/src/driver/DbdStatement.cj:64-73`（`set` / `setNull` 只调 `checkIndex`）、`DbdStatement.cj:168-172`（`checkIndex` 只挡 `index < 0`）、`DbdStatement.cj:249-265`（`sqlPayloadOf` 的 `while (i <= max)`）
- **来源**：存量（`git blame`：`29f2d7e88e 2026-11-22`，`DbdStatement.cj:249` 起整段）
- **判据**：review-checklist §5「按不可信长度预分配 / 一次性物化」、§6.4「已知规模却全量扫描」、§11「边界校验缺失」
- **证据**：静态确定 —— `checkIndex` 只判负数；`sqlPayloadOf` 先遍历参数表求 `max`，再 `while (i <= max) { parameters.get(i) ?? addNull() }`，循环次数与 payload 参数个数都等于 `max + 1`。`set(1_000_000_000, x)` 一次就会追加 10^9 个 `DataNone`，`set(Int64.MaxValue, x)` 则直接跑不完。
- **描述**：`set` 的 index 是调用方给的普通 `Int64`（f_orm 位置绑定、或业务代码里 `statement.set(i, v)` 的 `i` 累加）。把「行号 / 计数」错当参数下标（例如循环里忘了重置 `i`）不会报错，而是在执行时先卡在 `while` 里，再随 `SqlPayload.params` 的增长吃满堆；整条路径没有上限校验、没有拒绝分支、也没有日志。参数表本身也随 `max` 无界增长（`HashMap` 每条 entry 一个装箱 `Int64` 键 + 一个 `Data` 引用）。
- **建议**：在 `set` / `setNull` 里加显式上限（例如 `MAX_PARAMETERS = 65535`，与常见物理库的参数上限同量级），超限抛 `DbdException(DbdErrorCode.CONVERSION, 'parameter index ${index} exceeds ...')`；`sqlPayloadOf` 组装前再用同一上限兜一次（防止绕过 `set` 的路径）。用例补 `set(MAX_PARAMETERS + 1, x)` → `CONVERSION` 且不发包。

### [一般][存量] #2 `MultiDatasource.init` 逐个建池没有失败回滚：任一节点建池失败，先前池（连接 + 后台检查线程）没有关闭入口

- **位置**：`f_dbd/src/multid/Datasource.cj:74-90`（`for (datasource in datasources) { builtPools.add(DatabasePool(...)) }`），对照 `Datasource.cj:54-73` 的"先校验权重与算法再建池"注释
- **来源**：存量（`git blame`：`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「资源不对称：异常跳过释放」、§5「无界容器 / 长期持有」；fountain-baseline §5（资源生命周期）
- **证据**：待确认 —— 代码结构上确定：建池循环没有 `try/catch`，也没有"失败时把已建池 `close()`"的分支；`this.pools` 只在循环结束后才赋值（`:90`），因此中途抛异常时，已建池对象连一个可达引用都不会留下。缺的信息：`DatabasePool`（→ `f_pool.Pool` → `KeyPool`，`initSize` 默认 1）构造时是否同步建连、`creator`（`DbdDatasource.connect`）失败是抛出还是被后台线程吞掉。
- **描述**：第 2 个节点建池失败时，第 1 个池已经带着自己的 `PooledConnection`（每条一个 `f_net.Client`：1 条 TCP + 读写线程 + 30s 心跳）与池的检查线程存活，而 `MultiDatasource` 实例不会被返回给调用方 —— 这些连接与线程没有任何关闭入口。若构造阶段同步建连，则 `MultiDriver.open()` 会因单个节点不可达而整体失败（与 `DbdDatasource`「`open()` 不产生 IO、`connect()` 才建链」的口径也不一致）。
- **建议**：`let built = ArrayList<DatabasePool>(); try { ... } catch (e) { for (p in built) { try { p.close() } catch (_: Exception) { () } }; throw e }`；或把建池整体延后到首次 `connect()`（懒建池），让 `open()` 保持纯配置解析。

### [一般][存量] #3 连接级"结果集独占"闸门是检查-后-写入：两次 `query()` 可在同一临界区之间交叉，两个游标只登记一个

- **位置**：`f_dbd/src/driver/DbdStatement.cj:83-98`（`ensureExecutable()` 在 `:154` 过闸 → `connection.request(...)`（一次 TCP 往返）→ `openResult = result` → `connection.registerResult(result)`）；对照 `f_dbd/src/driver/DbdConnection.cj:124-135`（闸门）与 `DbdConnection.cj:137-142`（登记）
- **来源**：存量（`git blame`：`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §12.1「检查-然后-写入 / 并发正确性」、§6.2「用并发容器就当复合操作原子」的同类形态、§11「并发正确性」
- **证据**：静态确定（竞态窗口存在）+ 待确认（是否有多线程共用同一 `DbdConnection` 的调用方）—— `ensureNoOpenResult` 在 `Mutex` 内看不到 `activeResult` 就返回，锁随即释放；发包与写回登记发生在锁外。两个线程可以都通过闸门：服务端对每条 `CONSUME(SqlPayload)` 都会装一个新游标（`fdbm/src/server/handler.cj:104-107`），而客户端 `activeResult` 只留后者。
- **描述**：`DbdConnection.cj:28-35` 自己写明"`QueryResultColumnPayload` 不带结果标识，放任并发会让旧结果集的 `next/get` 静默作用到新游标上"，闸门就是为这条不变量设的；但闸门的判定与登记不在同一临界区，"至多一个未关闭结果集"这条不变量实际上没有被原子地维持。后果是两个结果集都拿到"可用"句柄，先建的那个后续 `next()/get()` 读到的是后建游标的数据（静默错行），且前者的 `close()` 会带自己的 `qid`，服务端按 `qid` 不匹配直接幂等 ACK（`handler.cj:154-155`），前一个游标既不关闭也不报错。与第 3 部分 #3（`close()` 与 `registerResult()` 的交错）根因相邻但交错不同：那条是"关闭期间被登记"，这条是"两次查询同时过闸"。
- **建议**：闸门改成"占位式"——`ensureNoOpenResult` 在同一临界区内写入一个 `pending` 标志（或直接把 `activeResult` 置成占位），`query()` 在 `finally` 里清占位/换真实结果；`update()`/事务 SQL 同样在 `finally` 清占位，保证异常路径不把连接永久锁死。用例：一个线程反复 `next()`、另一个线程反复 `prepareStatement().query()`，断言任一时刻只有一个结果集能 `get`，且两者最终都 `isClosed()`。

### [一般][存量] #4 `DbdTransaction` 的隔离级别 / 访问模式 / 可延迟性只记录不下发，设置后静默无效

- **位置**：`f_dbd/src/driver/DbdTransaction.cj:34-69`（三个 `private var` + 三个 `mut prop`）、`DbdTransaction.cj:72-78`（`begin()` 只发 `'begin'`）
- **来源**：存量（`git blame`：`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「契约与实现不符」、§3「接口承诺有行为、实现无下行效果」；std `Transaction.isoLevel` 的语义
- **证据**：静态确定 —— `accessModeValue` / `deferrableModeValue` / `isoLevelValue` 只在各自的 get/set 中出现（全文件搜索），`execute('begin')` 的 SQL 文本是常量 `'begin'`；`DbdTransaction_test.cj:29-51` 的用例名就叫 `propertiesAreRecordedNotTranslated`，正好把这个行为钉成了"预期"。
- **描述**：调用方写 `tx.isoLevel = Serializable` 再 `begin()`，实际下发的是不带任何级别修饰的 `'begin'`，物理库按默认级别开启事务；可重复读/串行化的假设全部落空，且没有任何 WARN 或异常。类注释与设计 §9 把它登记为"偏离"，但对只依赖 std API 的使用者仍是静默无效——事务语义错配是"数据看起来对、并发下不对"的典型来源。
- **建议**：至少在 `set` 到非 `Unspecified` 时打一条 WARN（"isolation level is not translated; put it in the SQL text"）；或在 fdbm 侧支持后按方言拼 `begin isolation level ...` / `set transaction ...`。README 的"事务三属性只记录不下发"一条已由第 1 部分报过（文档面），这里补的是代码面的建议。

### [轻微][存量] #5 未使用的 import（3 处）

- **位置**：`f_dbd/src/driver/DbdStatement.cj:23`（`DataAny`）、`DbdStatement.cj:25`（`QueryResultClosePayload`）、`f_dbd/src/driver/PayloadWrapping_test.cj:21`（`getGCCount`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 三个符号在全文件内只出现在 import 行（grep 逐符号确认）。`DataAny` / `QueryResultClosePayload` 是 payload 包装改造前的残留（旧写法是 `payload.add<DataAny>(DataAny(data))`，见 `PayloadWrapping_test.cj:30-47` 的 legacy 实现）；`getGCCount` 在 bench 辅助里没被调用。
- **描述**：残留 import 会让人误以为语句层仍在用 `DataAny` 包装参数，读代码时要多追一层。
- **建议**：删掉这三个被导入项。

### [轻微][存量] #6 测试桩里两个成员没有任何调用者（`StubFdbm.consumes()` / `StubFdbm.clear()`）

- **位置**：`f_dbd/src/driver/stub_fdbm_test.cj:80-88`（`consumes()`）、`stub_fdbm_test.cj:91-94`（`clear()`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §1「非 public 类型里的成员，全项目无使用即死代码」
- **证据**：静态确定 —— `StubFdbm` 是非 public `class`，两个成员默认 internal（包内可见）；在 `f_dbd` / `fdbm` / `fdbmdemo` 全仓 grep `consumes` / `.clear()`，`consumes()` 只有定义处一行，`clear()` 在 `f_dbd` 内无任何调用（命中的 `.clear()` 都在 `f_dbd/src/common/*` 与 `fdbm` 的其它类型上）。用例靠"每个用例新建一个 `StubFdbm`"实现隔离，没有走 `clear()`。
- **描述**：`consumes()` 的注释写着"Node站位用得到"，但没有任何用例用它；`clear()`（清空记录队列）也没被用上。两者都是"写了备用、最后没用"的残留。
- **建议**：删除；若想保留 `clear()`，就补一个"同一连接上分两阶段断言请求序列"的用例真正用它（比新建桩更贴近真实复用场景）。

### [轻微][存量] #7 重复逻辑：超时取值 / `codeOf` / 空闲端口探测 / URL 重建

- **位置**：
  - `f_dbd/src/driver/DbdStatement.cj:161-166`（`timeoutOf(configured: ?Duration)`）与 `f_dbd/src/driver/DbdTransaction.cj:113-116`（内联 `match (options.queryTimeout)`）——同一语义"未配置 → `NO_TIMEOUT`"两处实现；
  - `f_dbd/src/driver/testkit_test.cj:27-36` 与 `f_dbd/src/multid/MultiD_test.cj:209-218` —— `codeOf` 逐行同构（只差所在包）；
  - `f_dbd/src/driver/stub_fdbm_test.cj:102-112`（`freePort`）与 `f_dbd/src/multid/stub_test.cj:67-77`（`freePortOf`）——"bind 0 → 取端口 → close"，只差变量名；
  - `f_dbd/src/driver/DbdUrl.cj:124-131`（`toUrl`）与 `DbdUrl.cj:143-150`（`toUrlMasked`）——同一段拼串，只差密码那一段。
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §2（换控制流 / 只改名字 / 字面量复制）
- **证据**：静态确定（四组都逐行比对过）。差异点：`codeOf` 与端口探测分属两个包（`driver` / `multid`），跨包不能直接共享；`toUrl` 与 `toUrlMasked` 的输出差异是业务要求（脱敏）；超时取值两处差异仅在"是否包一层函数"。
- **描述**：`timeoutOf` 这类"未配置→6 小时哨兵"的换算散在两类调用点，将来改 `NO_TIMEOUT` 语义（例如改成 `Duration.Max`）很容易漏一处；`codeOf` / `freePort` 两份实现已经各自演进（`MultiD_test` 那份没有 `message` 版本），改一处不会同步另一处。
- **建议**：`?Duration → Duration` 提到 driver 包一个顶层 `func timeoutOrForever(?Duration): Duration`，两处共用；`codeOf` / 端口探测若要合并，需要建一个 internal 的 test-util 包（否则保留两份并在注释里互相指向）；`toUrl` / `toUrlMasked` 收成一个 `private func render(password: String): String`，两个 public 方法各传实参。

### [轻微][存量] #8 `driver/placeholder.cj` 是空文件残留（只有版权头 + 一句"阶段 0 仅建骨架"）

- **位置**：`f_dbd/src/driver/placeholder.cj:1-20`
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §1「兼容残留 / 无任何声明」
- **证据**：静态确定 —— 文件只有版权注释、`package fountain::f_dbd.driver` 与一段文档注释，零声明。
- **描述**：骨架阶段的占位文件，`driver` 包现在有 8 个实现文件，这个占位已无意义；它唯一的作用是让"包内文件清单"多一项，容易被误认为还有未实现的骨架。
- **建议**：删除（`f_dbd/src/multid/placeholder.cj` 同类，属第 5 部分）。

### [轻微][存量] #9 `MultiDConfig` 权重解析静默"纠正"配置：非数字段/空段被丢弃，权重悄悄漂移

- **位置**：`f_dbd/src/multid/Config.cj:70-83`（`getWeights` 的 `case None => ()`）、`Config.cj:168-177`（`segmentsOf` 丢掉空段）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「错误处理缺失 / 静默」、§14.1「配置项写错不报」
- **证据**：静态确定 —— `multidbm_loadbalance=roundrobin,1,,3`（多打一个逗号）经 `segmentsOf` 得到 `['roundrobin','1','3']`；`roundrobin,1,x,3` 得到 `[1,3]`。两者在 2 节点时正好通过 `effectiveWeights`（`Datasource.cj:173-176`）的"个数相符"校验，路由权重与配置意图不符且无 WARN。只有"个数不符"与"全为 0"会报 `CONFIG`。
- **描述**：权重是影响流量分布的配置，写错时应该启动失败（与 fountain-baseline §4「同名注册启动直接失败，不做隐式优先级」同一取向），而不是按"能解析几段算几段"。
- **建议**：除首段（算法名）外，出现空段或非数字段即记 WARN 并抛 `DbdException(CONFIG)`；`segmentsOf` 保留空段交给 `getWeights` 判定，或让 `getWeights` 按原始 `split(',')` 校验。

### [轻微][存量] #10 `ping()` 把 ERROR 响应归为 `PROTOCOL`，服务端错误码与消息被丢掉

- **位置**：`f_dbd/src/driver/DbdTransport.cj:86-96`（`case Command.ACK => ()` / `case other => PROTOCOL`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「错误映射不一致」、§10 错误处理
- **证据**：静态确定 —— 同文件 `request`（`:118-124`）与 `unsubscribe`（`:74-80`）都是 `case Command.ERROR => throw errorOf(resp)`，只有 `ping` 把 `ERROR` 归进 `other`。`DbdDatasource.connect`（`DbdDatasource.cj:66-76`）再把这条异常原样抛出，调用方拿到的是 `PROTOCOL 'unexpected command ERROR in response to PING'`。
- **描述**：服务端若对 PING 回 ERROR（会话被摘除、服务端升级中的拒绝等），排查时会指向"协议不符"，而真正的 `DbdErrorCode` / `sqlState` / message 在构造 `DbdException(PROTOCOL, ...)` 时已经丢掉。
- **建议**：`ping` 的三分支补齐 `case Command.ERROR => throw errorOf(resp)`，与另两条路径一致。

### [轻微][存量] #11 IPv6 分支忽略 `]` 之后的非 `:` 残留，拼错的 URL 被当成合法

- **位置**：`f_dbd/src/driver/DbdUrl.cj:89-99`（`tail.startsWith(':')` 为假时既不报错也不使用 `tail`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「边界校验缺失」
- **证据**：静态确定 —— `fdbm://[::1]junk:9000/db` 会被解析成 `host = '[::1]'`、`port = DEFAULT_PORT(8112)`，`:9000` 与 `junk` 全部静默丢弃；用例只覆盖了合法形态 `[::1]:9000`（`DbdUrl_test.cj:63-67`）。
- **描述**：URL 拼错（少一个冒号、多一段路径）不会在解析期暴露，错误延后到建链阶段，并且连到的是默认端口——排查成本比直接报 `CONFIG` 高得多。
- **建议**：`tail` 非空且不以 `:` 开头 → `DbdException(CONFIG, 'illegal fdbm url ...: unexpected \'...\' after IPv6 host')`；用例补 `[::1]junk:9000`、`[::1]:` 两条。

### [轻微][存量] #12 deprecated `query(params)` / `update(params)` 只覆盖 0..n-1，不重置既有参数表

- **位置**：`f_dbd/src/driver/DbdStatement.cj:139-148`（两个 deprecated 重载）、`DbdStatement.cj:174-180`（`bind`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复但少一处边界处理」的同类
- **证据**：静态确定（`bind` 只写 `0..n-1`，没有 `parameters.clear()`）+ 待确认（std 未写明 deprecated 重载是否覆盖旧绑定）—— `statement.set(5, x)` 之后调 `update([a])`，`sqlPayloadOf` 会按 `max = 5` 发出 6 个参数（1 个实参 + 5 个空洞）。
- **描述**：数组形式看起来"参数完全由这个数组决定"，实际会带上上一次 `set` 留下的高位参数；参数个数与 `?` 数量不符时由服务端报 SQL 错误，调用方看到的是 SQL 报错而不是"残留参数"，排查方向被带偏。若 std 语义是"参数在语句生命周期内持久"，那无参 `query()/update()` 的当前行为是对的，唯独数组重载需要显式重绑。
- **建议**：`bind` 开头 `parameters.clear()`（数组形式按数组重绑；无参版本保持持久语义），并补一条"先 `set(1,...)` 再 `update([a])` 只发 1 个参数"的用例。

### [轻微][存量] #13 用例写进程级全局配置且不还原，用例之间隐式耦合

- **位置**：`f_dbd/src/multid/MultiD_test.cj:33-47`（`MultiDConfigTest.readsExplicitValues`）、`:195-199`（`MultiDTest.openAcceptsBothSchemes` 设 `InitSize=0/MaxSize=1`）、`f_dbd/src/multid/MultiDTestSetup_test.cj:22` / `f_dbd/src/driver/DbdTestSetup_test.cj:22`（包级 `let` 写 `protocol_hostId`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「测试间隐式耦合 → flaky」、§10 可测试性
- **证据**：待确认 —— `Config.set` 是进程级全局写，本文件三个 `@Test` 类写的是同一组 `multidbm_databasePool*` 键且都不还原；缺的信息是 `cjpm test` 默认是否并行执行测试类（若串行，影响只是执行顺序敏感）。
- **描述**：并行执行时，`MultiDTest` 设的 `InitSize=0/MaxSize=1` 会漏进 `MultiDConfigTest`（反之亦然），表现为随机的池参数断言失败或池行为异常；第 5 部分的 `MultiDatasource_test` 用的是同一批键，跨文件也会受影响。包级 `let` 写 `protocol_hostId` 是刻意的一次性 setup（有注释），不在此列。
- **建议**：每个写配置的用例 `finally { Config.set(原值) }`，或集中到一个 setup 里给全量键赋值并让用例只读；至少让 `MultiDTest` 只改自己需要的两个键并在 `finally` 复原。

<!-- 第 5 部分 -->

### [一般][存量] #1 `MultiDUrl` 自造一套 `firstSegment`，与 `DbdUrl` 的 database 口径漂移（不解码、不切 query）

- **位置**：`f_dbd/src/multid/Url.cj:58`（`let database = firstSegment(rest[slash + 1..rest.size])`）、`Url.cj:113-119`（`firstSegment`）；对照 `f_dbd/src/driver/DbdUrl.cj:67`（`percentDecode(firstSegmentOf(...))`）、`DbdUrl.cj:165-177`（按 `?` 与 `/` 切）
- **来源**：存量（`git blame`：`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2（近似重复：复制了切分逻辑但少两步处理，属"近似重复 + 行为漂移"）、§11（契约与注释不符）
- **证据**：静态确定 —— `firstSegment` 只找 `/`，`DbdUrl.firstSegmentOf` 同时找 `?` 与 `/` 之后才 `percentDecode`；两条路径逐行比对过。
- **描述**：同一个 URL 会在两个 public 类型上得到两个不同的 `database`：
  - `multidbm://h1:1/db?x=1` → `MultiDUrl.database == 'db?x=1'`，`nodes[0].database == 'db'`；
  - `multidbm://h1:1/db%40x` → `MultiDUrl.database == 'db%40x'`，`nodes[0].database == 'db@x'`。

  `Url.cj:113` 的注释明确写"与 `DbdUrl` 的 database 口径一致：忽略后续 `/` 之后的部分"，`Url.cj:37` 写"逻辑库名（第一个路径段）"——实现两条都不满足（query 没切、也没解码）。仓内生产代码只用 `parsed.nodes`（`src/multid/Datasource.cj:45-52`，`database` 仅被 `MultiD_test.cj:132/155` 的用例断言读取），所以当前无连接层影响；但 `MultiDUrl.database` 是公开字段（`README.md:28` 明确列为对外能力），下游拿它做租户 / 路由判定会得到未解码且夹带 query 的值。附带一个错误归因问题：`multidbm://h/db%zz` 会报 `bad node 'h'`（`Url.cj:97-99`），真正非法的是库名，排查方向被带偏。
- **建议**：不要复制切分逻辑——把 `DbdUrl` 的 `firstSegmentOf` + `percentDecode` 提成 driver 包的内部工具（或给 `DbdUrl` 加一个 `fromParts` / `parseDatabase(text, url)` 入口）供 `multid` 复用；`'fdbm://'` 字面量（`Url.cj:95`）也一并收敛到 `DbdUrl` 的 scheme 常量/工厂，避免 scheme 改名时两处不同步。用例补 `db?x=1` 与 `db%40x`，断言 `url.database == nodes[0].database`。

### [一般][存量] #2 `MultiStub` 每个桩构造 200 个工作线程的 `Server`，`close()` 一个都不回收

- **位置**：`f_dbd/src/multid/stub_test.cj:38`（`Server<DataAny>(bindAt: p, checkDuration: Duration.second * 30, checker: {=> Message.ping()})`，未传 `executors`）
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §11「资源不对称：构造申请、关闭不释放」、§5「长期持有」、§12.1「跨线程资源」
- **证据**：静态确定（机制链路完整）+ 需实测（线程数 / RSS / 用例耗时的影响量级）——
  - `f_net` 的 `Server` 默认 `executors!: Int64 = 200`（`f_net/src/server/server.cj:46`、`:110-118`）→ `Executors` 构造 `Array<Executor<T>>(200){_ => Executor<T>(q)}`（`f_concurrent/src/Executor.cj:26`），每个 `Executor` 的私有构造直接 `spawn { while (running.load()) { q.remove()() } }`（`Executor.cj:56-62`），即**构造即起 200 条线程**；
  - `Server.close()` → `doClose` 只做 `server.close()` + `checkTimer.cancel()` + 排空 `buffers`（`server.cj:191-211`），全仓搜 `executors.shutdown` 无 `f_net` 调用点；即使调用，`Executor.shutdown()` 也只置 `running` 标志，阻塞在 `q.remove()` 的线程仍不退出（`f_concurrent` 部分已单列此缺陷）。
- **描述**：桩只需要串行处理（`Server` 分发只走 `executors[0]`，`server.cj:169`），却继承了"生产 200 并发 handler"的默认值。本文件 6 个用例共建 10 个桩（`MultiDatasource_test.cj:33-34/51-52/69-70/86-87/106/131`）⇒ 单测试进程 2,000 条常驻线程；`src/driver/stub_fdbm_test.cj:46` 同形未传 `executors`，整个 `f_dbd` 测试进程会更大。这些线程不随 `close()` 退出，线程栈地址空间与调度器元数据随桩数线性增长；CI 线程上限低时可能在 `pthread_create` 上失败，或表现为进程 RSS 与调度开销抬升（具体量级见「待验证假设」1）。
- **建议**：桩构造改为 `Server<DataAny>(bindAt: p, checkDuration: ..., executors: 1, checker: ...)`（`executors` 是公开命名参数，一行改完）；`Server.close()` 里补 `executors.shutdown()` 属 `f_net` 范围，只记依赖不在此处展开。

### [轻微][存量] #3 `MultiDUrl.tryParse` 捕获 `Exception`，与 `DbdUrl.tryParse` 口径不一致

- **位置**：`f_dbd/src/multid/Url.cj:81-87`；对照 `src/driver/DbdUrl.cj:115-121`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2（同语义两实现只改一个细节）、§11（错误处理：静默吞掉）
- **证据**：静态确定 —— `MultiDUrl.tryParse` 是 `catch (_: Exception) { None }`；`DbdUrl.tryParse` 是 `catch (_: DbdException) { None }`。
- **描述**：两个 `tryParse` 是同一套 API 形状（非法 URL → `None`），但一个只吞契约异常、一个吞掉全部 `Exception`（含切片越界之类解析器自身缺陷）。`MultiDUrl.parse` 内部还会调 `DbdUrl.parse`（`Url.cj:93-100`），后者已经保证非法输入只抛 `DbdException`，所以宽捕获没有收益，只会把"解析器写错了"伪装成"输入非法"。
- **建议**：改为 `catch (_: DbdException)`，与 `DbdUrl` 对齐；若确要兜底，至少 `logger.warn` 记一条再返回 `None`。

### [轻微][存量] #4 `MultiDUrl.parse` 的 `nodes.isEmpty()` 分支不可达

- **位置**：`f_dbd/src/multid/Url.cj:74-76`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §1（不可达语句）
- **证据**：静态确定 —— 走到 `:74` 时 `nodesPart` 已非空（`:62-64` 抛过）；std 文档 `core_package_structs.md` §`func split(String, Bool)` 写明"原字符串为空时返回长度 0；分隔符未出现（原串非空）时返回长度 1"，故 `split` 至少产出一段；空段在 `:67-71` 已抛 `CONFIG`，因此循环体至少 `nodes.add(...)` 一次。
- **描述**：死分支，且错误文案与 `:62-64` 的 "node list is empty" 重复；读代码时要多推一遍"节点数 0"到底由谁负责。
- **建议**：删除该 `if`，节点数为 0 由 `nodesPart.isEmpty()` 一条判定承担。

### [轻微][存量] #5 `freePortOf` 的"探测-关闭-再绑定"窗口，以及非 IP 地址时静默返回 0

- **位置**：`f_dbd/src/multid/stub_test.cj:67-77`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §11（边界 / 资源）、§2（与 `src/driver/stub_fdbm_test.cj:102-112` 的 `freePort` 逐行同构；该重复已在第 4 部分 #7 记录，合并时保留一条，本部分补位置与差异）
- **证据**：静态确定（窗口存在、`case _ => port = 0` 的兜底路径存在）+ 待确认（并行测试下的实际冲突率）
- **描述**：`bind(0)` → 读端口 → `close()`，之后 `Server` 才 bind 同一端口，中间任何进程（包括并行的另一个测试类）都能占走它，`Server` 构造直接抛 `SocketException`，用例报"连接失败"而不是"端口冲突"。`match (probe.localAddress)` 的 `case _ => port = 0` 会把不可用地址静默变成端口 0，URL 成 `127.0.0.1:0`，错误再延后到 `connect()`，排查更远。
- **建议**：非 `IPSocketAddress` 直接 `throw`（或 `@Fail`），不要回 0；消除窗口的办法是让 `Server` 接受 `bindAt: 0` 并对外暴露实际监听端口，或在 `MultiStub` 构造失败时重试 1–2 次。两份 `freePort` 若要合并，需要先有 `driver` / `multid` 共用的 internal test-util（跨包不能直接复用 `private`）。

### [轻微][存量] #6 `useConfig` 只覆盖 9 个 `multidbm_*` 键，且与 `MultiD_test.cj` 各写一份字面量

- **位置**：`f_dbd/src/multid/MultiDatasource_test.cj:149-161`；对照 `src/multid/MultiD_test.cj:33-47`、`src/multid/Config.cj:30-42`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2（字面量复制：同一批配置键散落两处）、§11（注释与实现不符）
- **证据**：静态确定 —— `useConfig` 写 9 个键（loadbalance / InitSize / MinSize / MaxSize / 三个 CheckOn* / ConnectTimeout / MaxWaiting），`MultiDConfig` 共 13 个键，漏 `IdleTimeout` / `ConnectionLife` / `CheckInterval` / `CheckSql`；`MultiDConfigTest.readsExplicitValues` 恰好把这四个写成 5s / 3600s / 120s / `select 2`。
- **描述**：注释写"写一组确定的池/负载均衡配置（避免用例间顺序影响）"，实际只确定 9 个：本文件用例随后建池时会继承前一个测试类留下的 4 个键（与第 4 部分 #13「全局配置不回滚」同根因，这里补"集合不全"这一面）。其中 `IdleTimeout=5s` 会直接影响"归还后连接是否被后台清理"，属于会改变被测行为、却不被本文件声明的输入。另一个后果是 13 个键名在两份测试里各写一遍，改键名时必漏一处。
- **建议**：把 13 个键收成一份测试常量表 / 一个 `multidConfigOf(loadBalance, maxWaiting)` 构造器，两个测试文件共用并全量赋值；键集合与 `MultiDConfig` 的常量同名引用（`MultiDConfig` 的常量是 `static const`，测试侧需要时提成可读的 public 常量）。

### [轻微][存量] #7 `MultiDatasourceTest` 未按 Step 4.4 用例矩阵覆盖，`setOption` 失效时表现为挂起而非断言失败

- **位置**：`f_dbd/src/multid/MultiDatasource_test.cj:127-145`（`setOptionReachesNodeDatasources`，单节点）、`:102-125`（`poolExhaustionAndClose`）、`:29-63`（分布用例）
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §14（承诺源 + 缺失证据）、§11（测试有效性：用例不能在功能失效时给出失败信号）
- **证据**：静态确定 —— 承诺源 `doc/开发计划.md:295-299`（Step 4.4 用例矩阵）与实际用例逐条对照：
  - "两节点 → 两个 `DatabasePool`（`initSize=1` 时桩收到 2 条连接）"：无用例（所有用例 `InitSize=0`）；
  - "重复归还抛 `ConnectionException`"：无用例；
  - "`setOption` 转发到每节点（桩断言两次到达）"与"池建立后再调用不生效"：用例只有单节点（`:132` 的 URL 只有 `stub.port`），既证明不了"每节点"，也没有"建池后不生效"的对照；
  - 失败模式：若 `setOption` 不再转发，`query_timeout` 保持 `None` → `DbdStatement.cj:161-166` 取 `NO_TIMEOUT`（`DbdTransport.cj:32` = 6 小时），桩静默 → 用例卡 6 小时等框架超时，而不是给出断言失败（框架是否给单用例超时：待确认）。
- **描述**：该文件是 `MultiDatasource` 唯一的用例来源，缺口直接等于"多节点路由 / 池生命周期"没有回归网。另外 `@Assert(counts[0], 67)` 把"步长 1、累计权重桶 [1,3]"的实现细节钉成契约，而计划只要求"分布比例接近 2:1（统计断言，容差）"——把 `RoundRobin` 的 `min=1` 桶语义（`Datasource.cj:196-199`）一改，等价实现也会红。
- **建议**：给 `MultiStub` 暴露"每个节点收到的选项"（或对两个桩分别做"有超时/无超时"对照）补两节点 `setOption` 用例；补 `initSize=1` 的双连接计数、重复归还抛 `ConnectionException`、建池后 `setOption` 不生效三条；分布断言放宽成区间（例如 60–75 / 25–40）并保留"总数 = 100"，把"桶语义"钉点改成单独一条针对 `RoundRobin` 的用例。

### [轻微][存量] #8 `multid/placeholder.cj` 是空文件残留（只有版权头 + 一句"阶段 0 仅建骨架"）

- **位置**：`f_dbd/src/multid/placeholder.cj:1-20`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §1（零声明 / 兼容残留）
- **证据**：静态确定 —— 文件只有版权注释、`package fountain::f_dbd.multid` 与一段文档注释，零声明（与 `src/common/placeholder.cj`、`src/driver/placeholder.cj` 同形；后者已在第 4 部分 #8 记录）。
- **描述**：阶段 0 骨架占位，`multid` 包现在有 `Config` / `Datasource` / `MultiD` / `Url` 四个实现文件，占位已无意义；它唯一的作用是让包内文件清单多一项，容易被误认为"多节点还有未实现骨架"。
- **建议**：删除（三个 `placeholder.cj` 一起删，合并时与第 4 部分 #8 合并为一条）。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分为纯 `.md`，未提出新方案。文档内既有的两条分配优化（`sqlPayload` 单层包装、`readChunk` 复用读缓冲）已落地且实现与设计一致，但测量口径为探针 / `-O0`，复核要求见「待验证假设」1–2；在补齐 `-O2` 对照前不作为收益结论。

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

### [堆内存] `readChunk` 固定 64 KiB 缓冲 + 双重拷贝 + 未按已知 `size` 预分配

- **现状**：`f_dbd/src/common/types.cj:405-422` 每次调用都无条件 `Array<Byte>(DEFAULT_STREAM_CHUNK, repeat: 0u8)`（64 KiB），再按轮 `stream.read(buf[0..want])`（切片复制）→ `out.add(all: buf[0..n])`（第二次复制）。`fdbm/src/execute/cursor.cj:186-187` 把客户端请求里的 `bufSize` 原样作为 `size` 传进来，所以"客户端要 1 字节读一块"时，为读 1 字节会分配并清零 64 KiB（放大约 65536×），`out` 也从容量 0 开始按倍增扩容。
- **方案**：`size > 0` 时用 `let cap = min(size - got, DEFAULT_STREAM_CHUNK)` 决定缓冲大小（一次分配、逐轮复用），并用 `ArrayList<Byte>(size)` 预分配容量；`size <= 0` 的整读路径保持不变。
- **预期**：小 `bufSize` 的分块读每次分配量从 64 KiB 降到 `min(size, 64 KiB)`；整读路径少掉 `ArrayList` 的数次扩容复制（n=1 MiB 时约 2 MiB 的额外复制量）。均为静态推算，未测。
- **代价**：每次调用多一次 `min` 判断；`size` 极大时缓冲仍不超 64 KiB，语义不变（短块不是 EOF，见 `types.cj:397-404` 的约定）。
- **验证**：`F_DBD_BENCH=1 cjpm test`（`ReadChunkReuse_test.benchToEnd` 已有 `getAllocatedHeapSize` 口径）在 `bufSize = 1 / 64 / 1024` 三档下对比 `alloc`；再用 `getUsedHeapSize()` / RSS 看稳态。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `DbdInputStream.read` 用逐字节循环搬运

- **现状**：`f_dbd/src/common/result.cj:429-435` 每次 `read` 最多执行 `chunkSize` 次单字节赋值（`while (i < n) { buffer[i] = pending[pos + i]; i += 1 }`），而 `n` 已算好、`pending` 是连续数组；这是流列读格的唯一搬运路径（每块 64 KiB 默认）。对比同仓 `f_multi`/测试里已用的 `copyTo` 写法（`ReadChunkReuse_test.cj:39`）。
- **方案**：`pending[pos..pos + n].copyTo(buffer, 0, 0, n)`（或先 `buffer[0..n]` 切片再拷）替换循环。
- **预期**：单块搬运由 O(n) 次带边界检查的赋值变成一次批量拷贝；能省多少取决于编译器是否已把循环向量化，未测。
- **代价**：多一次切片分配（若编译器不消除），需实测确认净收益为正；语义等价（`n` 已由 `min(buffer.size, pending.size - pos)` 限定）。
- **验证**：`cjprof record` 读 200 MiB LOB（`fetch_rows=65536`）对比 `read` 自耗时占比；或 `cjpm bench -O2` 对 1 MiB `DbdInputStream` 做吞吐对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 4 部分 -->

### [堆内存] `DbdStatement` 参数表从 `HashMap<Int64, Data>` 换成稠密数组

- **现状**：每条 `Statement` 一个 `HashMap<Int64, Data>`（`DbdStatement.cj:41`）：每个参数一个装箱 `Int64` 键 + 一个 `Data` 引用 + 桶数组开销；每次执行 `sqlPayloadOf`（`:249-265`）先整表遍历求 `max`（O(k) 哈希迭代），再 `0..max` 逐位 `get`（每次一次哈希 + 键比较），最后往 `SqlPayload` 追加。参数表活到 `close()`，payload 活到请求发完。
- **方案**：改成 `ArrayList<?Data>`（或 `Array<?Data>` + `maxUsed`）：`set(index)` 时按 index 扩容（同时落地 #1 的上限），`sqlPayloadOf` 直接按下标顺序 append、缺失位 `addNull()`；`sqlPayloadOf` 的入参类型同步从 `Map<Int64, Data>` 换成 `Array<?Data>`。
- **预期**：每次执行省掉一次全表遍历与 k 次哈希查找；参数表从"HashMap 桶数组 + k 个 entry"压成一个指针数组。具体字节数与耗时收益需实测（本部分无基线）。
- **代价**：`set` 大 index 时按 index 扩容（必须有上限，与 #1 合并处理）；`PayloadWrapping_test` 的三条字节等价用例与 bench 的输入类型要改（可用一个 `Map → Array` 的测试内辅助保持对照）。
- **验证**：`F_DBD_BENCH=1` 跑 `PayloadWrapping_test.testBenchPayloadAllocation`（现有隔离探针值 1,744 B/次可作"改前"参考，见 `doc/spec/optimize-f-dbd-payload-wrapping/design.md`），再对 8 / 32 参数两种规模各跑改前改后的 `getAllocatedHeapSize()` 差值与 `cjpm bench -O2` 吞吐。
- **证据状态**：无基线（待验证，不进 tasks）—— 只有"改前"参考值，没有本方案的改后对照。

<!-- 第 5 部分 -->

> 本部分没有改前/改后数据（`scope.md` 的「已有性能资料」是 `docs/LocalMode*.md`，与本部分的 URL 解析、测试桩无关），按铁律不出带收益数字的方案。唯一可执行的资源类改进已并入 #2（`executors: 1`），不单列。

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 8 参数 payload 由 `add<DataAny>(DataAny(x))` 改 `add<Data>(x)` 省 577 B/次（-25%）在 `-O2` 下依然成立 | `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/design.md:13`、`src/driver/DbdStatement.cj:257-263` | `-O2` 下的分配量与耗时中位数 | 同机 `cjpm bench -O2`，8 参数 payload × 2000 次 × 5 轮，`getAllocatedHeapSize()` 前后差 + 中位数/离散度 |
| 2 | `readChunk` 复用一块 64 KiB 缓冲后，1 MiB「读至 EOF」的总分配 5,436,040 B 仍主要由输出数组主导 | `f_dbd/doc/spec/reuse-read-buffers/design.md:86-90`、`src/common/types.cj:405-422` | 该函数在流参数编码路径的分配占比与自耗时 | `cjprof record` 跑 1 MiB `InputStream` 参数 `set` + `update`，采样分配与自耗时，对照 `ArrayList` 增长次数 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 列信息对象的分配与编码占查询首包开销的比例可能不低（宽表/高频短查询） | `f_dbd/src/common/column.cj:33-51` | 每次查询的分配字节数、`DataObject` 帧自耗时占比 | `cjprof heap` + 10k 次 20 列查询；`cjprof record` 看 `toData/convert` 帧 |
| 2 | 失败风暴下 `DbdException` 构造成本（两次 `payload.errorCode()` match + `SqlException.message` 拼接）可忽略，但未验证 | `f_dbd/src/common/DbdException.cj:59-63` | 每秒异常数上限、CPU 占比 | 注入 10k 次 `ERROR` 响应，`cjprof record` 取 `DbdException` 帧占比 |
| 3 | `readChunk` 单缓冲复用后 1 MiB「读至 EOF」的分配量是否与 `doc/spec/reuse-read-buffers/design.md:90` 的 5,436,040 B 基线一致（代码已演进） | `f_dbd/src/common/ReadChunkReuse_test.cj:77-91`（`F_DBD_BENCH=1` 已打印 alloc） | 5 轮 alloc 中位数与离散程度 | `F_DBD_BENCH=1 cjpm test --filter ReadChunkReuse_test --show-all-output`，同机 `-O2` |

<!-- 第 3 部分 -->

> 本部分没有提供任何 profile / bench 数据（`scope.md` 只给了 `docs/LocalMode*.md`，与本部分无关），下面四条都只是线索，不能作为缺陷或收益结论。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 小 `bufSize` 分块读时 `readChunk` 的 64 KiB 分配被放大 | `f_dbd/src/common/types.cj:409` | 每次调用的分配量与请求分布 | `F_DBD_BENCH=1` + `getAllocatedHeapSize()`，按 `bufSize = 1 / 64 / 1024` 各跑 10k 格 |
| 2 | `DbdInputStream.read` 的逐字节搬运在流列读中占比可观 | `f_dbd/src/common/result.cj:429-435` | 自耗时占比 | `cjprof record` 跑 200 MiB LOB 读，`fetch_rows=65536` |
| 3 | 未知 `typeName` 的逐格 WARN（`readData` 的 `Unknown` 分支）会放大日志与耗时 | `f_dbd/src/common/types.cj:370-372` | 日志行数、单格耗时 | 造 1 万格 `weird_type` 列跑一轮，统计日志行数与端到端耗时 |
| 4 | `dispatch_perf_test` 里测出的 A/B 分派耗时是否仍代表当前 `decodeCellAsAny`（实现已改成 `match case _: ?X` + 子类型兜底） | `f_dbd/src/common/dispatch_perf_test.cj:60-116` | 与真实 `get<T>` 的同环境对照 | 同 SDK、`-O2`，对同 19 个类型各跑 10^6 次真实 `QueryResultImpl.get` 与用例中的 `Dispatch.canonicalB` |

<!-- 第 4 部分 -->

> 本部分没有提供 `cjprof` / `cjpm bench` 数据（`scope.md` 的「已有性能资料」是 `docs/LocalMode*.md`，与本部分无关）。下面四条只是线索，不构成热点或收益结论。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sqlPayloadOf` 的"遍历求 max + 逐位 `get`"占单条语句执行耗时的比例 | `f_dbd/src/driver/DbdStatement.cj:249-265` | 自耗时占比（含 8 / 32 参数两档） | `cjprof record` 跑 10 万次 `update`（参数 8 与 32 各一轮），看 `sqlPayloadOf` self time 与调用路径 |
| 2 | 每次 `query()` 新建两个闭包（`ColumnRequestSender` / `ResultCloser`）+ `QueryResultImpl` 的列信息数组拷贝，对短查询的分配占比 | `f_dbd/src/driver/DbdStatement.cj:91-94`；`f_dbd/src/common/result.cj:68-75` | 每次查询的分配字节数 | 前后 `getAllocatedHeapSize()` 差 / 1 万次短查询；同环境 `-O2` |
| 3 | 多节点下每次借连接都走 `RoundRobin.next()`（内部 `Mutex`）+ `TreeMap.forward`，高并发借用是否形成锁竞争 | `f_dbd/src/multid/Datasource.cj:92-99`、`:114`；`f_concurrent/src/LoadBalance.cj:32-49` | 锁等待时长、BLOCKED 线程数 | 200 并发借还压测 + 线程状态采样（CPU profile 看不到锁竞争）；同时记录借用 QPS |
| 4 | 默认 `initSize=1 / maxSize=1`（`Config.cj:85-95`）下每节点并发上限 = 1，是否成为吞吐上限 | `f_dbd/src/multid/Datasource.cj:62-64`、`:76-88` | 池等待时间 P95/P99 | 按 1/4/16 节点各压一轮，采池诊断计数与借用等待分布 |

<!-- 第 5 部分 -->

> 没有 `cjprof` / `cjpm bench` 数据；下面两条只是线索，不构成热点或收益结论，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每个桩 200 条常驻线程会抬升 `f_dbd` 测试进程的线程数与 RSS，并放大用例总耗时 | `f_dbd/src/multid/stub_test.cj:38`（`executors` 未传）；同类 `src/driver/stub_fdbm_test.cj:46` | 进程线程数峰值、RSS 峰值、`cjpm test` 总耗时 | 同机 `-O2` 下跑 `cjpm test`，改前记录 `/proc/self/status` 的 `Threads` / `VmRSS` 与总耗时；把两个桩改成 `executors: 1` 后同条件复跑，取 3 轮中位数 |
| 2 | 桩的每报文分发（`executors[0].call` + `ExecutorFuture` 的 `Mutex`/`Condition` 唤醒）在 100 次借还的分布用例里占比不可忽略 | `f_dbd/src/multid/MultiDatasource_test.cj:169-185`；`f_concurrent/src/Executor.cj:66-72` | 单条 `update` 的分段耗时（客户端发送 / 服务端 handler / 等待唤醒） | 在 `MultiStub` handler 与 `borrowAndCount` 两侧加计时埋点，跑 1 万次 update，输出 P50/P95；或 `cjprof record` 观察 `ExecutorFuture.complete` / 条件变量等待的占比 |

## 文件覆盖

> 与 `files/f_dbd.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_dbd/README.md` | .md | ✅ | — |
| 2 | `f_dbd/README_en.md` | .md | ✅ | — |
| 3 | `f_dbd/doc/spec/harden-fdbm-stack-defects/design.md` | .md | ✅ | — |
| 4 | `f_dbd/doc/spec/harden-fdbm-stack-defects/proposal.md` | .md | ✅ | — |
| 5 | `f_dbd/doc/spec/harden-fdbm-stack-defects/spec.md` | .md | ✅ | — |
| 6 | `f_dbd/doc/spec/harden-fdbm-stack-defects/specs/f-dbd/spec.md` | .md | ✅ | — |
| 7 | `f_dbd/doc/spec/harden-fdbm-stack-defects/tasks.md` | .md | ✅ | — |
| 8 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/design.md` | .md | ✅ | — |
| 9 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/proposal.md` | .md | ✅ | — |
| 10 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-dbd/spec.md` | .md | ✅ | — |
| 11 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-protocol/spec.md` | .md | ✅ | — |
| 12 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/tasks.md` | .md | ✅ | — |
| 13 | `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/design.md` | .md | ✅ | — |
| 14 | `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/proposal.md` | .md | ✅ | — |
| 15 | `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/tasks.md` | .md | ✅ | — |
| 16 | `f_dbd/doc/spec/reuse-read-buffers/design.md` | .md | ✅ | — |
| 17 | `f_dbd/doc/spec/reuse-read-buffers/proposal.md` | .md | ✅ | — |
| 18 | `f_dbd/doc/spec/reuse-read-buffers/tasks.md` | .md | ✅ | — |
| 19 | `f_dbd/doc/开发计划.md` | .md | ✅ | — |
| 20 | `f_dbd/doc/详细设计.md` | .md | ✅ | — |
| 21 | `f_dbd/src/common/DbdException.cj` | .cj | ✅ | — |
| 22 | `f_dbd/src/common/DbdException_test.cj` | .cj | ✅ | — |
| 23 | `f_dbd/src/common/ReadChunkReuse_test.cj` | .cj | ✅ | — |
| 24 | `f_dbd/src/common/column.cj` | .cj | ✅ | — |
| 25 | `f_dbd/src/common/column_test.cj` | .cj | ✅ | — |
| 26 | `f_dbd/src/common/dispatch_perf_test.cj` | .cj | ✅ | — |
| 27 | `f_dbd/src/common/error.cj` | .cj | ✅ | — |
| 28 | `f_dbd/src/common/error_test.cj` | .cj | ✅ | — |
| 29 | `f_dbd/src/common/payload.cj` | .cj | ✅ | — |
| 30 | `f_dbd/src/common/payload_test.cj` | .cj | ✅ | — |
| 31 | `f_dbd/src/common/placeholder.cj` | .cj | ✅ | — |
| 32 | `f_dbd/src/common/result.cj` | .cj | ✅ | — |
| 33 | `f_dbd/src/common/result_test.cj` | .cj | ✅ | — |
| 34 | `f_dbd/src/common/sqltypes_test.cj` | .cj | ✅ | — |
| 35 | `f_dbd/src/common/types.cj` | .cj | ✅ | — |
| 36 | `f_dbd/src/common/types_matrix_test.cj` | .cj | ✅ | — |
| 37 | `f_dbd/src/common/types_test.cj` | .cj | ✅ | — |
| 38 | `f_dbd/src/dbd.cj` | .cj | ✅ | — |
| 39 | `f_dbd/src/dbd_test.cj` | .cj | ✅ | — |
| 40 | `f_dbd/src/driver/DbdConnection.cj` | .cj | ✅ | — |
| 41 | `f_dbd/src/driver/DbdConnection_test.cj` | .cj | ✅ | — |
| 42 | `f_dbd/src/driver/DbdDatasource.cj` | .cj | ✅ | — |
| 43 | `f_dbd/src/driver/DbdDriver.cj` | .cj | ✅ | — |
| 44 | `f_dbd/src/driver/DbdDriver_test.cj` | .cj | ✅ | — |
| 45 | `f_dbd/src/driver/DbdOptions.cj` | .cj | ✅ | — |
| 46 | `f_dbd/src/driver/DbdStatement.cj` | .cj | ✅ | — |
| 47 | `f_dbd/src/driver/DbdStatement_test.cj` | .cj | ✅ | — |
| 48 | `f_dbd/src/driver/DbdTestSetup_test.cj` | .cj | ✅ | — |
| 49 | `f_dbd/src/driver/DbdTransaction.cj` | .cj | ✅ | — |
| 50 | `f_dbd/src/driver/DbdTransaction_test.cj` | .cj | ✅ | — |
| 51 | `f_dbd/src/driver/DbdTransport.cj` | .cj | ✅ | — |
| 52 | `f_dbd/src/driver/DbdTransport_test.cj` | .cj | ✅ | — |
| 53 | `f_dbd/src/driver/DbdUrl.cj` | .cj | ✅ | — |
| 54 | `f_dbd/src/driver/DbdUrl_test.cj` | .cj | ✅ | — |
| 55 | `f_dbd/src/driver/PayloadWrapping_test.cj` | .cj | ✅ | — |
| 56 | `f_dbd/src/driver/placeholder.cj` | .cj | ✅ | — |
| 57 | `f_dbd/src/driver/stub_fdbm_test.cj` | .cj | ✅ | — |
| 58 | `f_dbd/src/driver/testkit_test.cj` | .cj | ✅ | — |
| 59 | `f_dbd/src/exception/DbdException.cj` | .cj | ✅ | — |
| 60 | `f_dbd/src/exception/Reexport_test.cj` | .cj | ✅ | — |
| 61 | `f_dbd/src/multid/Config.cj` | .cj | ✅ | — |
| 62 | `f_dbd/src/multid/Datasource.cj` | .cj | ✅ | — |
| 63 | `f_dbd/src/multid/MultiD.cj` | .cj | ✅ | — |
| 64 | `f_dbd/src/multid/MultiDTestSetup_test.cj` | .cj | ✅ | — |
| 65 | `f_dbd/src/multid/MultiD_test.cj` | .cj | ✅ | — |
| 66 | `f_dbd/src/multid/MultiDatasource_test.cj` | .cj | ✅ | — |
| 67 | `f_dbd/src/multid/Url.cj` | .cj | ✅ | — |
| 68 | `f_dbd/src/multid/placeholder.cj` | .cj | ✅ | — |
| 69 | `f_dbd/src/multid/stub_test.cj` | .cj | ✅ | — |

合计：`.cj` 49 个 / `.md` 20 个 / 共 69 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无源码，无逻辑/并发/注入可判；文档层面的「口径不一致」按 §13/§14 归类，未在此重复计数 |
| §1 死代码 | 0 | `.md` 无声明可判。做了等价机械检查：文档引用的每个符号与路径都做了存在性核对（`fdBDVersion`/`DbdUrl.tryParse`/`dispatch_perf_test.cj`/`reviews/202610210649_fdbm_stack_review`/`docs/LocalMode.md`/`fdbm/test/e2e/README.md` 均存在）；唯一「声明了但外部不可达」的是 README 列的 14 个 `MultiDConfig` getter，按文档缺陷记入 #2，不按死代码计（它们在 `multid/Datasource.cj:60-73` 与 `:167` 有调用） |
| §2 重复逻辑 | 1 | 文档级：`harden.../spec.md` 与 `specs/f-dbd/spec.md` 同内容双份（#6）。跨文档的「同义要求」属 OpenSpec ADDED→MODIFIED 演进，不判重复 |
| §3 空实现 | 0 | 文档中无「承诺了但留空」的条目：`tasks.md` 全部勾选且 4.6/17.7 有验收记录；唯一「记录不修」的 G25 有明确理由与用例，不算空实现 |
| §4 栈溢出 | 0 | 本部分无递归相关文档段落 |
| §5 OOM | 0 | 文档中的内存上界表述（`readChunk` 单块 64 KiB）与实现一致，无「按报文长度预分配」承诺 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；文档内的两条分配结论只能进「待验证假设」1–2 |
| §6.2 大粒度锁 | 0 | 本部分无锁相关文档；`DbdTransport`/`DbdConnection` 的锁粒度留第 2–5 部分 |
| §6.3 并发串行 | 0 | 同上；README「每次 get 都发请求」是显式设计（1+N 往返）而非隐藏串行，已有 Non-Goal 记录 |
| §6.4 低效算法 | 0 | 文档未承诺任何算法实现；`readChunk` 的 O(n) 行为在 `types.cj` 已近线性，未发现文档与实现冲突 |
| §7 降堆内存方案 | 0 | 无改前/改后峰值数据，未写成方案；仅保留待验证假设 |
| §8 降 CPU 方案 | 0 | 同上；文档中的分配收益未在 `-O2` 复核，不进方案 |
| §9 local mode 可行性 | 0 | `optimize-f-dbd-payload-wrapping` 已论证 `DataAny` 是 struct、与 local region 无关；`reuse-read-buffers` 已论证作为 `read` 实参的缓冲无法 local 化，两处结论与 `-O0` 记录一致，无需重开 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无运行时代码。读文档时撞见的两处代码疑点（`MultiDUrl.database` 未解码、结果集闸门三段分离）见「范围外提示」，不占本部分统计 |
| §12 并发安全与锁粒度 | 0 | 本部分无并发实现；README 亦未声明线程安全，按「未声明即不承诺」处理，具体共享点留给代码部分 |
| §14 功能完备性与 README 覆盖 | 2 | #2 公开 API 清单失准（列了不可达的 14 个，漏了 4 常量 + 3 成员）、#3 缺关键限制段落（结果集独占、事务属性只记录） |
| 文件覆盖（§13 等） | 18/18 | 本部分清单 18 个文件全部读完，逐个做了「文档承诺 → 代码位置」核对（见文件覆盖表） |

### 第 2 部分

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

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：#1、#2、#3、#4、#6；设计：`common` 只放可与 fdbm 共用的载荷与类型映射、`driver` 只放 std 接口实现，依赖方向单向（`driver → common`、`common` 不引用驱动），分层无违规；语言特性：`Array<ColumnInfoImpl> → Array<ColumnInfo>` 因泛型不变逐项转换（`result.cj:70-75`）正确、`asTarget` 用 `case x: T` 收口正确；安全性：metadata 走 `toUrlMasked()`，测试逐项断言密码不出现（`DbdConnection_test.cj:112-115`），无注入面（SQL 由 `SqlPayload` 参数化下发），本部分无裸凭据 |
| §1 死代码 | 0 | 已逐个搜：`private`（`asTarget` / `decodeCellAsAny` / `decoded` / `runeOf` / `fallbackAsAny` / `isStreamColumn` / `openStreamAsAny` / `invalidateStreams` / `ensureReadable` / `DbdTypeInfo` / `resolve*` / `parenBaseOf` / `cellOf` / `isIntegerTarget` / `TI_*` / `PAREN_BASES` / `configuredNameOrNone` / `missingNameError` / `configuredName` / `timeoutOf` / `codeOf` / `messageOf` / `formatPct` / `largerOf` / `medianOf` / `MissPlainClass` / `MyInputStream` / `MyStreamImpl` / `PlainValue` / `PlainProbe` / `DribbleStream` / `RecordingStream` / `FailingStream` / `Timing` / `Row` / `TypeInfoCache` / `Dispatch`）在 `f_dbd` 内全部有调用；`internal`（`requestBlock` / `columnIndex` / `invalidate` / `DbdInputStream.init` / `credential` / `ensureNoOpenResult` / `registerResult` / `request` / `unsubscribe` / `DbdOptions` 全部字段）在包内有调用；无 `protected` 声明；`public` 均为对外可达（`dbd.cj` 的 `public import` 链完整），按硬原则一不判。仅记录信息：`SqlTypes.readStream(result,index,size)`（`types.cj:428-430`）仓内只有 `sqltypes_test` 引用，但它是 `public struct` 的 `public static func`，属对外 API，不是死代码；`DbdDriver()` 无参构造（`DbdDriver.cj:43-45`）仓内无调用，同为对外 API |
| §2 重复逻辑 | 3 | 已把 20 个文件的函数体两两比对：#5（流解码两处 try/catch）、#7（三个超时分支）、#9（两个同体用例 + 两个同体桩助手）。`DbdErrorCode` 的 `value` / `toString` / `parse` 是同一张表的三个方向，输出不同，不算重复；`decodeCellAsAny` 的 19 个 `case` 与 `Dispatch.canonicalB` 形状相同但一个是生产代码、一个是实验桩，语义目标不同 |
| §3 空实现 | 0 | 全部分文件搜 `TODO` / `FIXME` / `UnsupportedException` 无命中；`QueryResultImpl.close()`（`result.cj:189-193`）与 `DbdConnection.close()`（`DbdConnection.cj:102-107`）的 `catch (_: Exception) { () }` 都有注释说明是"关闭失败不要求应用再写一遍清理"的有意策略，且随后一定置 `closed_` / 释放本地状态（有用例 `closeFailureStillReleasesLocalState` 钉住），不算静默吞异常 |
| §4 栈溢出 | 0 | 本部分无递归：`next` / `getOrNull` / `read` / `readChunk` 均为平铺循环；`toString` / `==` 都不递归子结构；无深拷贝 |
| §5 OOM | 1 | #4（LOB 整块物化）。其余容器都有界：`streams_` / `nullStreams_` 按列数（`result.cj:55-57`），`params` 由调用方逐个 `add`（`payload.cj:41-48`），`columnInfos` 由首包长度决定 |
| §6.1 热点瓶颈 | 0 | 本部分没有 `cjprof` / `cjpm bench` 数据，`dispatch_perf_test` 只测分派本身（不含 I/O 与解码），不构成任何热点结论；四条线索已进「待验证假设」 |
| §6.2 大粒度锁 | 0 | `DbdConnection` 唯一一把 `Mutex` 只保护 `closed` / `activeResult` 两个字段，临界区内无 I/O、无日志、无回调（`close()` 特意把 `r.close()` 挪到锁外，`DbdConnection.cj:98-108`）；不存在"一把全局锁保护多个无关资源" |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池使用；`DbdInputStream` 的块请求是同步往返，属协议约定（一问一答），不是"形式并发" |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无热路径 `contains` / `remove(at:)`；`medianOf` 的冒泡排序只在测试里对 5 个元素用；类型归一的 `PAREN_BASES` 是 39 项线性前缀扫描（每列一次，不随行数增长），不属热点 |
| §7 降堆内存方案 | 1 | `readChunk` 的固定 64 KiB 缓冲 + 双拷贝（无基线，已标「待验证」） |
| §8 降 CPU 方案 | 1 | `DbdInputStream.read` 的逐字节搬运（无基线，已标「待验证」） |
| §9 local mode 可行性 | 0 | 本部分临时对象峰值就是单块 64 KiB（`readChunk`）与 `query` 时的列信息数组，生命周期随单次调用结束但都要返回/逃逸（`Array<Byte>` 返回、`QueryResultImpl` 持有列信息），不满足"不离开函数"；要做也只能拿到峰值内存对照才成立，本部分无数据 |
| §11 现有代码的 BUG（存量） | 11 | #1–#11 全部标「存量」（4 一般 + 7 轻微）；本部分读到的其余函数（`DbdErrorCode.parse` 的越界回退、`UpdateResultPayload` 的 `@DataExclude` 线缆键、`QueryResultImpl` 的 `exhausted` 终态、`DbdInputStream` 的 EOF 幂等、`DbdDatasource.connect` 的异常清理）边界与空值均已逐条核对，无额外缺陷 |
| §12 并发安全与锁粒度 | 1 | #3（`close` / `registerResult` 的状态互斥缺失）。`QueryResultImpl` / `DbdInputStream` 自身无锁，它们按 `DbdConnection` 的"结果集独占"不变量（`DbdConnection.cj:28-35`）只在持有连接的单条执行链上使用，属线程封闭；本部分其余共享点只有 `DbdDriver` 的 `static init`（包初始化时执行一次）与 `DriverManager` / `Config`（std 与 `f_config` 自身线程安全）。锁粒度见 §6.2 行 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`，README / `fdbm/doc/详细设计.md` 的对照归第 1、2、4、5 部分；仅从代码侧核对：`dbd.cj` 的重导出覆盖了 `common.*`（含 `DbdException`，实现体在 `common/DbdException.cj`，`exception/` 只有一行 `public import`）与 `driver`/`multid` 的入口类型，`fdBDVersion` 有测试，无"注册了但没人用"的接线缺口（`fetchRows` 已在 `DbdStatement.cj:94` 接到 `chunkSize`） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.md`，§13 的文档一致性不适用于本部分 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性：#1、#3、#4、#12；设计：`MultiDatasource` 把"池 + 负载均衡"收在自己的 `init`（见 #2 的回滚问题），`driver` 层依赖方向为 `driver → common`、`multid → driver`，无反向依赖；语言特性：`Data`/`SqlDbType` 的 `match` 分派用具体类匹配（`setSqlDbType` 38 个分支，`case _` 收口），`?T` 用 `setNullable` 统一收敛，惯用法正确；可读性：#5（残留 import 误导）；安全性：savepoint 名走白名单校验（`DbdTransaction.cj:130-157`，用例 `savepointNameInjectionIsRejected` 钉住 6 种注入串），`getMetaData` 走 `toUrlMasked()`、密码不进 metadata，`DbdUrl` 的 `%XX` 解码对非法 UTF-8/残缺转义报 `CONFIG`，本部分无硬编码凭据、无 SQL 拼接（除已挡的 savepoint 名） |
| §1 死代码 | 3 | #5（3 个未用 import）、#6（`StubFdbm.consumes` / `clear` 无调用者，全仓 grep 确认）、#8（`driver/placeholder.cj` 零声明）。其余已逐个搜：`private`（`ensureExecutable` / `sqlPayloadOf` 私有成员 / `timeoutOf` / `checkIndex` / `bind` / `encode` / `setSqlDbType` / `setNullable` / `ensureBegun` / `check` / `isIdentifier` / `isStart` / `isPart` / `ensureOpen` / `checked` / `errorOf` / `onNoResponse` / `firstSegmentOf` / `hexByte` / `nibbleOf` / `percentDecode` / `percentEncode` / `isUnreserved` / `intOf` / `boolOf` / `segmentsOf` / `anyPoolClosed` / `effectiveWeights` / `algorithmOf` / `legacySqlPayloadOf` / `encoded` / `expectBytes` / `dbdBenchEnabled` / `dbdSettle` / `dbdMeasure`）在包内均有调用；`internal`（`sqlPayloadOf`、`NO_TIMEOUT`、`withCredentials`、`StubFdbm` 的成员、`QueryScript`、`FailingUpdateScript` / `NotEncodable`、`freePort`、`commandName`、`codeOf` / `messageOf` / `waitUntil`）在包内均有引用，唯 #6 两处例外；`protected`：只有 `MultiDConfig`（`protected struct`），其 14 个 `public static` 方法全部被 `Datasource.cj:60-73` 消费，按"非公共顶级声明里的 public 成员"口径逐一核对过，无死代码；`public`：`DbdStatement` / `DbdTransaction` / `DbdTransport`（非 public 类，成员均为包内放宽，已逐个核对使用）/ `DbdUrl` / `MultiD` / `MultiDatasource` 均为对外可达，按硬原则一不判，仅记录信息：`DbdUrl.toUrl()` 仓内只有用例引用（生产走 `toUrlMasked()`），`DbdStatement.query(params)` / `update(params)`、`DbdTransaction.save/release` 仓内也只有用例调用，都是对外 API；包级 `let testProtocolHostIdSetup`（两个 setup 文件）名字零引用但初始化器有副作用（写 `protocol_hostId`），不算死代码 |
| §2 重复逻辑 | 1 | #7 合并了四组同语义实现（超时取值、`codeOf`、空闲端口探测、`toUrl`/`toUrlMasked`）。另外核对过：`PayloadWrapping_test` 的 `legacySqlPayloadOf` 与生产 `sqlPayloadOf` 结构相同但**是有意的等价基准**（用例名 `payloadBytesMatchLegacy` 就是它的目的），不算重复；`QueryScript.handler` 与 fdbm 真实分发不是同一职责；两个 `placeholder.cj` 与两个 setup 文件是"每包一份"的必然重复，不合并 |
| §3 空实现 | 0 | 全部分文件搜 `TODO` / `FIXME` / `UnsupportedException` 无命中；两处 `catch (_: Exception) { () }`（`DbdStatement.close`、`DbdTransport.close`）都是"幂等关闭、对端失败不要求应用重试"的有意策略且有注释，随后一定释放本地状态（`openResult = None` / `closed = true`）；`DbdStatement.parameterColumnInfos` 返回空数组是契约本身（设计 §5.5「恒为空、不提供服务端参数元数据」），不是空实现。#4 的"设置后无下行效果"按契约不符归 §11，不重复计入本节 |
| §4 栈溢出 | 0 | 本部分无递归：`isPart → isStart` 是单层调用，`DbdUrl` 的解析全是直线扫描，`sqlPayloadOf` 是 `while` 累加；递归深度不由 URL / 参数 / 节点数驱动，无可达深度上界问题 |
| §5 OOM | 1 | #1（按 max index 全量物化 payload + 参数表无界）。其余容器有界：`MultiDatasource` 的池按 `maxSize` 限流，`nodes` / `weights` / `pools` 由 URL 与配置长度决定，`DbdUrl.percentDecode` 的 `ArrayList<Byte>` 上界是 URL 字节数 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `cjpm bench` 数据；`PayloadWrapping_test` 的 bench 默认 `F_DBD_BENCH!=1` 直接 `println("SKIP")` 返回，不产生可复核数据。四条线索已进「待验证假设」，未当作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分临界区只有字段读写：`DbdConnection` 的 `Mutex`（属第 3 部分，此处只作对照）与 `RoundRobin` 内部 `Mutex`（`f_concurrent`）。`DbdTransport` 本身无锁，`MultiDatasource.connect` 不持锁发包，`begin/commit` 也不在锁内做 I/O |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get` / 线程池；一条连接上一问一答是协议约定（`QueryResultColumnPayload` 不带结果标识），不是"形式并发"。`MultiDatasource` 借连接是单次调用，不存在批内逐个 `get()` |
| §6.4 低效算法 | 1 | #1 的 `while (i <= max)` + 每轮一次 `HashMap.get`（复杂度随最大 index 线性，与参数个数无关）；#7 的"求 max 再逐位取"也在优化方案里一并处理。其余无嵌套循环匹配 / 热路径 `contains` / `remove(at: 0)` |
| §7 降堆内存方案 | 1 | 参数表 `HashMap → 稠密数组`（无基线，已标「待验证，不进 tasks」） |
| §8 降 CPU 方案 | 0 | 没有基线数据，故不出方案；三条 CPU 线索（参数组装自耗时、每查询闭包分配、`RoundRobin.next()` 的锁）已进「待验证假设」1–3 |
| §9 local mode 可行性 | 0 | 逃逸检查全部不通过：`sqlPayloadOf` 的 `SqlPayload` 要上线（逃逸到 `DbdTransport`）、`percentDecode` 的字节缓冲要变成 `DbdUrl` 的成员、`DbdStatement.query` 的 `QueryResultImpl` 返回给应用；`DbdUrl.isIdentifier` 的 `toRuneArray()` 虽不逃逸，但只在 savepoint 上调用（非热点、长度极小），收益无法用峰值内存证明，故不出方案 |
| §11 现有代码的 BUG（存量） | 13 | #1–#13 全部标「存量」（4 一般 + 9 轻微）。本部分读到的其余边界与空值已逐条核对：`DbdUrl` 的 `%` 截断判断（`i + 2 >= size`）、缺 host/空库名/端口越界、`DbdTransaction.isIdentifier` 先判空再取 `runes[0]`、`DbdStatement.close` 的幂等、`DbdTransport.onNoResponse` 的"先关链再判 IO/TIMEOUT"、`MultiDConfig` 的负数/零边界（`MaxWaiting<=0 → Duration.Max`）均无额外缺陷 |
| §12 并发安全与锁粒度 | 1 | #3（闸门检查-后-写入）。共享点与同步手段：`MultiDatasource.closed`（`AtomicBool.swap`）、`LoadBalance`（`TreeMap` 只在 init 写、读侧 `forward`，`RoundRobin` 自带锁）、`DbdTransport.client`（`f_net.Client.transfer` 内部按 `MessageID` 复用）、`DbdStatement.parameters` / `openResult`（无同步，仅在持有连接的单条执行链上使用，属线程封闭）。锁粒度见 §6.2 行 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`（README / `doc/**` 的对照归第 1、2 部分）。代码侧核对：`DbdStatement.setOption` 的 `fetch_rows` 已接到 `QueryResultImpl` 的 `chunkSize`（`DbdStatement.cj:94`）、`query_timeout`/`update_timeout` 分别接到 query/update、`DbdTransaction` 的六个方法都在 `Transaction` 上接线、`MultiD.open` 已接到 `MultiDatasource`、`multiDDriver()` 有 `fdbmdemo` 消费，无"注册了没人用"的缺口；唯一"能力存在但不下发"的是 #4（已计入 §11） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.md`，§13 的文档一致性不适用（`.md` 只用于取证：`doc/详细设计.md` §5.1/§5.5/§5.8/§5.9/§6.1/§6.4 逐条对照过实现） |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：#1（同一 URL 两个 database 值）、#7（用例失效时挂起）；可维护性：#6；设计：#2（测试桩继承生产并发度）；语言特性：`String.split` 的空段语义、`startsWith` / 字节切片均按 std 文档核对（`core_package_structs.md` §`func split(String, Bool)`），`?T` 与 `match` 用法符合惯用法；安全性：`parseNode` 只重建 URL 不拼 SQL，进程内无凭据进日志，本部分无外部输入落盘；`MultiDUrl` 的错误消息会回显整条 URL（含明文密码），与 `DbdUrl` 的既有做法一致（`DbdUrl.cj:58` 同形），不单列 |
| §1 死代码 | 2 | #4（`nodes.isEmpty()` 不可达，已用 std 文档证明 `split` 对非空串至少一段）、#8（`placeholder.cj` 零声明）。机械核对：`private` 符号 `firstSegment` / `schemeRest` / `parseNode` 均有文件内调用；`MultiStub`（非 public 类）的 `port` 被 `MultiDatasource_test.cj:107/132/165` 使用、`received` 被 `:182` 使用、`close` 被 6 个用例的 `finally` 使用、`hits` 在类内 handler 与 `received` 中使用；`freePortOf` 被 `MultiD_test.cj:200` 使用；`useConfig` / `twoNodeUrl` / `borrowAndCount` 均被本文件用例调用；4 个文件的 import 逐项核对，无未使用项；`MultiDUrl` 是对外可达的 public 类型，按硬原则一不判死代码 |
| §2 重复逻辑 | 4 | #1（`firstSegment` vs `DbdUrl.firstSegmentOf`）、#3（两个 `tryParse`）、#6（13 个配置键字面量跨测试文件各写一份）、#5 中的 `freePortOf` vs `driver/stub_fdbm_test.cj` 的 `freePort`（该条已计入第 4 部分 #7，合并时保留一条）。另核对：`MultiStub` 与 `StubFdbm` 都是 `Server<DataAny>` 桩，但职责不同（计数 vs 记录/脚本化应答），不合并；`MultiDatasource_test` 的三个 helper 与 `MultiD_test.cj` 的 `codeOf` 不是同一语义，不合并 |
| §3 空实现 | 0 | 4 个文件无 `TODO` / `FIXME` / `UnsupportedException`；`stub_test.cj:50-52` 的 `catch (_: Exception)` 有注释说明（`close()` 把 `accept()` 带出，属正常收尾），且随后无状态需清理；`tryParse` 返回 `None` 是契约本身（#3 判的是捕获范围，不是空实现）；`placeholder.cj` 是零声明文件，按 §1 计，不重复计入本节 |
| §4 栈溢出 | 0 | 无递归：`MultiDUrl.parse` 是直线扫描 + 单层循环；`parseNode` 只调一次 `DbdUrl.parse`（后者也无递归）；深度由 URL 段数决定且无自调用 |
| §5 OOM | 1 | #2（每桩 200 条常驻线程，10 个桩 = 2,000 条；有界但每实例放大 200 倍，且 `close()` 不回收）。其余容器有界：`nodes` / `nodesPart.split` 上界是 URL 字节数，`ArrayList<DbdUrl>` 一条节点一个元素；测试侧 `borrowAndCount` 固定 100 次 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据（本部分只有解析代码与用例）；两条线索（桩线程数、每报文分发开销）已进「待验证假设」，未当缺陷 |
| §6.2 大粒度锁 | 0 | 本部分代码无锁：`MultiDUrl` 纯函数；`MultiStub` 只有 `AtomicInt64`；`Server` / `Executors` 内部的队列与条件变量属 `f_net` / `f_concurrent` 范围 |
| §6.3 并发串行 | 0 | 每个桩只有一条 `spawn`（accept 循环），是按需起服务的必要形态，不是 `spawn` 后立刻 `get()`；用例串行借还连接，无批内并发 |
| §6.4 低效算法 | 0 | `parse` 对 URL 一次线性扫描；`firstSegment`/`schemeRest` 为 `indexOf` + 切片；`borrowAndCount` 线性 100 次；无嵌套循环匹配、无热点 `contains`、无 `remove(at: 0)` |
| §7 降堆内存方案 | 0 | 本部分没有可量化的对象生命周期问题（解析产物随 `MultiDUrl` 存活，属预期）；按铁律无基线不出方案 |
| §8 降 CPU 方案 | 0 | 同上，无基线数据；解析只在启动/建池前调用一次，不在请求主路径 |
| §9 local mode 可行性 | 0 | 逃逸检查不通过：`MultiDUrl` 的 `nodes` / `database` 要作为字段返回给调用方；剩余临时对象（`ArrayList`、`split` 结果）只在一次解析内存活但无峰值内存证据，收益无法证明，故不出方案 |
| §11 现有代码的 BUG（存量） | 8 | #1–#8 全部「存量」。本部分读到的其余边界已核对：`multidbm://h1:9001`（缺库名）、`multidbm://h1:9001/`（空库名）、`multidbm:///db0`（空节点列表）、`multidbm://h1:9001,,h2:9002/db0`（空节点）、`multidbm://:9001/db0`（缺 host）均按 `CONFIG` 抛出，与 `MultiD_test.cj:160-173` 的用例一致；端口越界 / 非数字由 `DbdUrl.parsePort` 兜住（`DbdUrl.cj:152-161`）；`parseNode` 已把 `DbdException` 包成带 cause 的 `CONFIG` |
| §12 并发安全与锁粒度 | 0 | 逐点核对：`MultiStub.hits` 用 `AtomicInt64`（`:32`，handler 线程写、测试线程读）；`server` / `port` 在 `init` 内先赋值（`:37-38`）再 `spawn`（`:39`），`this` 虽然在 `init` 返回前逸出到 accept 线程，但所有字段已就绪，无"构造未完成即发布"；`respond` 是不可变参数；`MultiDatasource_test.useConfig` 写的是进程级 `Config`（第 4 部分 #13 已记，是否并行执行待确认）；`MultiDatasource` 的共享状态不属本部分文件 |
| §14 功能完备性与 README 覆盖 | 1 | #7（Step 4.4 用例矩阵的 4 处缺口，承诺源 `doc/开发计划.md:295-299`）。产品侧接线无缺口：`MultiDUrl.parse/tryParse` 已在 `MultiD.open` → `MultiDatasource` 链路上生效（`Datasource.cj:45`），`MultiStub` 的 `PING` 依赖由 `Server` 内置满足（`server.cj:165-168`）；本部分无 `README` / `doc/**` 文件，README 覆盖归第 1 部分 |
| 文件覆盖（§13 等） | 4/4 | 无缺文件；本部分无 `.md`，§13 不适用。`doc/详细设计.md` §6.2（`MultiDUrl` 字段与形状）、`doc/开发计划.md` Step 4.2 / 4.4 仅作为判据引用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 16 |
| 轻微 | 28 |
| 其中存量 | 38 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分全是文档，但文档质量直接决定接入成本，结论是「主体准确、边角失准」。经逐条核对，README 的协议口径（查询不预读、每次 `next()` 发 `NEXT_ROW`、关闭走 `UNSUBSCRIBE(qid)`→`ACK`、流列按 `bufSize` 分块、NULL 用 `CELL(index,-1)` 探测、类型口径 B）与 `src/common/result.cj`、`src/driver/DbdStatement.cj`、`src/driver/DbdTransport.cj` 完全对得上；类型映射也站得住：`SqlTypes.resolveSqlName`（`types.cj:259-275`）覆盖了 std 全部 19 个非空 `Sql*` 类型（`SqlBigInt`…`SqlVarchar`，逐一比对 `database_sql_package_classes.md`），`SqlNullable*` 由 `replace('nullable','')` 统一归一，方言/`unsigned`/`(n)` 后缀/包名前缀各分支与 `详细设计.md` §8 的登记一致；多节点 13 个 `multidbm_*` 默认值与单位也和 `multid/Config.cj` 逐项相同；两份 README 中英同步、无单向缺失。

风险集中在文档的「可操作性」而非协议本身：**选项键名 camelCase 是最该先修的一条**——它不会报错，只会让超时与分块设置悄无声息地退回默认值，排障成本远高于改四个字符串；其次是把 `protected` 类型的静态方法当成对外 API 列出，以及 ResultSet 独占、事务属性只记录这两条硬限制完全没写进 README，接入方很可能在第一次复用连接时就被 `CURSOR_STATE` 拦住却找不到解释。变更文档侧只有两处卫生问题（P1 计数 29/33、规格文件双份），不影响当时的实现结论。

本部分存量缺陷 6 条（一般 3、轻微 3），默认只报不修，是否纳入修复待用户决定。`.cj` 侧的协议、类型与生命周期结论需第 2–5 部分合并后才有完整口径；「范围外提示」中的两条请由对应部分复核定级。

**第 2 部分**：本部分的代码本体（异常类型 + 列信息线上载体 + 3 个测试文件）是干净的：无并发、无句柄/连接资源、无不可达语句、无无界容器，`@DataExclude` 与短名键集合的回归用例写得比多数模块扎实。真正的问题集中在两处**跨层契约**：

1. **诊断链断裂**（#1）：`DbdException.cause` 是 13 个生产调用点都在写的字段，却既不进 `Exception.causedBy`，也没有任何生产代码读取，`f_log` 打印时根因直接消失。断链/握手/转换失败恰恰最需要它，属应排期修的一般项（修法很小：构造器里同步 `causedBy`）。
2. **文档与实现相反**（#2、#3）：`readChunk(size<=0)` 的语义写反，若照文档"修正"代码会让流列静默截断；§8 的类型归一判定顺序与 §3.9 和实现三方不一致，会让排障者找不到 WARN 线索、也可能诱使后来者删掉 `resolveSqlName`/`resolveDialect`。两处都应随下一轮文档回填一次改齐。

无阻塞发布项：本部分不含协议状态机与连接生命周期，无法就这两项下总体结论（见其余 4 个部分）。存量缺陷共 6 条（3 一般 + 3 轻微），是否纳入修复待用户决定；两条优化方案均无基线，只作下轮补数据用。

**第 3 部分**：本部分（`common` 的载荷 / 结果集 / 类型映射 + `driver` 的四个入口类）整体质量偏好：状态机（`next` → `rowValid` → `exhausted` → `closed_`）、流列句柄复用与失效（`streams_` / `nullStreams_` / `invalidate`）、`NEXT_ROW(-1)` 与 `CELL(index,-1)` NULL 探测的协议约定都有注释与用例互相对齐，没有空实现、没有不可达代码、没有递归与无界容器；连接级"结果集独占"这一不太直观的不变量也有专门用例守住。

主要风险集中在两处：

1. **类型映射表的缺口（#1）**——这是唯一会直接产生"错误数据视图"的问题：`int(11)` / `real` 这类真实存在的列类型静默降级成 `String`，只在日志里留一条 WARN，业务侧看到的是字符串比较/排序。修起来只是补两个表项 + 三条用例，建议优先排期。
2. **`decodeStrict` 的 flag 恒为 0（#2）**——注释与代码互相矛盾，眼下靠 `DataObject<T>` 快路径遮住；它属于"下一次重构就会全线崩"的潜伏项，值得连带补一条非同型输入的用例。

资源与生命周期方面，`DbdConnection.close()` 与 `registerResult()` 的状态交错（#3）与 `readData` 的 LOB 整块物化（#4）是两个需要设计决策的点：前者要决定"关闭中的连接是否允许新游标"，后者要决定"是否给 LOB 设上限"。其余为重复逻辑与注释/测试质量问题，可随手清理。

无阻塞性（严重）问题；本部分共 **11 条存量缺陷（0 严重 / 4 一般 / 7 轻微）**，是否纳入修复、以及 #3、#4 是否需要先定契约，待用户决定。两条优化方案均无基线数据，仅作下一轮补测量的候选，不进 `tasks.md`。

**第 4 部分**：本部分（`Statement` / `Transaction` / `Transport` / `DbdUrl` / 多节点配置与数据源）的协议实现质量偏好：载荷判别一律 `decodeStrict` + 明确错误码（不宽容降级）、`transfer` 返回 `None` 一律关传输以避免错位、`qid` 用请求 `MessageID` 且与服务端 `handler.cj` 的 `cursor.qid` 口径一致、savepoint 名白名单挡住注入、`SqlDbType` 的 38 个分支与 `SqlTypes.encodeParameter` 支持类型逐一对齐（`SqlByte → Int8`、`SqlChar → String`、`SqlInterval → Duration` 与 `f_orm` 读侧的 `Sql*` 名称映射不矛盾）。死代码与重复逻辑都在少量残留层面，没有空实现、没有递归、没有不可达语句。

主要风险按优先级：

1. **#1 参数 index 无上界**——唯一能一次把进程打挂的点（错一个下标 → 十亿次循环 + 十亿个占位参数）。修法很小（一个上限常量 + 一条用例），建议优先排期。
2. **#3 结果集闸门非原子**——设计上把"同一连接至多一个未关闭结果集"当成不变量，实现却不是原子的；一旦有调用方跨线程共用连接，会静默错行（`QueryResultColumnPayload` 不带结果标识）。与第 3 部分 #3 是同一不变量上的两个交错，合并报告时建议并成一条"连接级独占不变量未原子维持"。
3. **#2 建池无回滚 / #4 事务属性静默无效**——前者是多节点场景的资源与启动耦合问题，后者是对 std 契约的静默偏离；都属于"平时不发作、故障时难查"的类型，可排期处理，其中 #4 最省的修法是先加一条 WARN。

存量共 13 条（4 一般 + 9 轻微），是否纳入修复待用户决定。本部分无阻塞级（严重）缺陷。

**第 5 部分**：本部分代码量小，质量基线不错：`MultiDUrl` 的双 scheme、节点顺序、空库名 / 空节点 / 缺 host 的错误映射都统一到 `CONFIG`，`parseNode` 用 `DbdException` 包 cause 保留了底层定位信息；`MultiStub` 用回环随机端口 + `AtomicInt64` 计数，避开了跨线程可见性问题，且正确利用了 `Server` 内置的 `PING` 应答（计数只含 `CONSUME`，67/33 的分布断言口径成立）；`MultiDatasource_test` 把"零权重节点不得覆盖前一桶"这条历史坑钉成了用例。

主要风险按优先级：

1. **#1 database 口径漂移**——`MultiDUrl` 复制了一份切分逻辑，少做"切 `?`"和"`percentDecode`"两步，同一个 URL 在 `MultiDUrl.database` 与 `nodes[i].database` 上得到两个值，且与自己的注释（"与 `DbdUrl` 口径一致"）矛盾。当前无仓内消费者，但它是对外 public 字段（README 明列），属"看起来对、下游判定会偏"的类型；修法是复用 `DbdUrl` 的同一份实现，改动很小。
2. **#2 测试桩 200 线程/桩**——测试进程资源随桩数线性放大、`close()` 不回收，是 CI 上最容易被忽略的成本项；`executors: 1` 一行可解，建议与 `driver` 的桩一起改。
3. **#6 / #7 用例与配置**——`MultiDatasource` 是模块里唯一"池 + 路由"的组装点，现有用例没覆盖双池、重复归还、建池后 `setOption`，`setOption` 失效还会表现成 6 小时挂起；补齐成本不高，收益是这条链路真正有回归网。

无严重项、无阻塞级缺陷。存量共 8 条（2 一般 + 6 轻微，含与第 4 部分 #7 / #8 同源的两条重复记录），是否纳入修复待用户决定。
