# 设计：fdbm 栈评审缺陷修复

> 证据基线：`reviews/202610210649_fdbm_stack_review/`（`review_v1.md` … `review_v6.md`、`todo.md`、`scope.md`），
> 基线提交 `7ca82fcc`。本文中的 `R{n}S{m}` / `R{n}G{m}` 指 `todo.md` 的轮次与条目序号，
> `file:line` 为基线位置。所有修复先写失败用例（红），再最小实现（绿）。

## 1. 约束与不变量

1. **不改 `f_orm`**：方言选择仍由应用侧 `dbd_driverName` 决定；本次只让该口径自洽。
2. **不破坏协议**：消息种类、载荷形状、错误码数值（`DbdErrorCode.value`）不变。唯一新增是
   `QueryResultColumnPayload.cell(index, bufSize = -1)` 的**保留值语义**（NULL 探测），
   旧客户端不发、旧服务端按既有 `bufSize <= 0` 分支处理 ⇒ 双向兼容。
3. **对外只抛 `SqlException`**（f_dbd）：所有编码/解码/URL/超时错误必须在驱动边界包成
   `DbdException`；不得让 `OutOfMemoryError`、`IllegalArgumentException`、`Rune(UInt32)` 越界等裸异常穿透。
4. **`fdbm` 的所有失败路径必须回包**，且错误码与 `详细设计.md` §11 / 错误码表一致。
5. **不引入 2PC**：跨物理库的原子性仍不在承诺内；本次只把「同库内应原子」的路径改成事务，
   并把无法保证的组合显式文档化（G25）。
6. **标识符只重写引用符**：不改写用户写的名字，只按目标方言输出引用符；下推时去掉逻辑库限定符。

## 2. 去重映射与逐条处置

### 2.1 严重项：16 条 → 12 个缺陷族

| ID | 缺陷（根因） | 合并的条目 | 处置 |
| --- | --- | --- | --- |
| D01 | `InputStream` 参数编码按 `Int64.Max` 分配，循环内重复申请（OOM + O(n²)） | R1S1、R2S1 | 修复 |
| D02 | `readData` 对流列只取一块 64 KiB；`Unknown` 误走流分支 | R1S2 | 修复 |
| D03 | 逻辑库集合被物理库名污染，会话默认库/路由/SHOW/`sequenceDatabase` 全部按物理名解释 | R3S1、R5S3、R3G「SHOW 只认物理库」、R3G「未配置逻辑库未展开」、R3G「sequenceDatabase 口径」、R5G1、R5G2 | 修复 |
| D04 | pin 时 `borrow()` 无视目标库，多目标在同一连接重复执行 | R5S1、R5S4 | 修复 |
| D05 | `Unroutable` / DDL 回退到部署内全部物理库（越界广播/越界写） | R5S2 | 修复 |
| D06 | 非标量参数 `toString()` 拼 SQL，产生语法非法语句 | R4S1 | 修复 |
| D07 | 数值字面量经 `Float64` 中转，大整数/高精度小数静默失真 | R4S2 | 修复 |
| D08 | 派生表形状校验只统计 `from`，JOIN / UPDATE / DELETE 放行 | R4S3 | 修复 |
| D09 | 自定义扩展名可覆盖内置（校验缺失 + 工厂自定义优先 + 用例固化错误语义） | R2S4、R5G10、R6S1（语义部分） | 修复 |
| D10 | UUID v1/v6 未触发时间戳/序列生成（恒 0），且每次生成建临时目录/文件 | R3S2 | 修复 |
| D11 | `IdGeneratorException` 无消费者映射；按算法名而非生成器能力选 ID 类型 | R2S2 | 修复 |
| D12 | `DbdUrl` 混用字节下标与字符下标；`%XX` 按 Rune 还原；`database` 不解码 | R2S3、R1G「percentDecode」 | 修复 |

> R6S1 的另一半（自定义扩展链路零 e2e）落入 P2/T07；D09 负责把用例期望从「覆盖内置」改为「拒绝冲突」。

### 2.2 一般项：51 条 → P1 29 项 + 并入 P0 8 条 + P2 9 条（无遗漏、无重复）

| ID | 缺陷 | 来源 | 处置 |
| --- | --- | --- | --- |
| G01 | 非法/非正超时被清成 `None`（无限等待），与注释相反 | R1G | 修复 |
| G02 | 根包 `fountain::f_dbd` 空壳、注释停留在「阶段 0」、无重导出 | R1G | 修复 |
| G03 | 驱动注册名三处文档矛盾；`static init` 未配置即 `exit(1)` 杀死只用 MultiD 的进程；测试依赖未文档化的 env | R1G(×2)、R2G | 修复 |
| G04 | `getOrNull<InputStream>` 对 NULL 返回 `Some(空流)` | R1G | 修复 |
| G05 | 流列标量读取只回首块且不报错 | R1G | 修复 |
| G06 | `MultiDatasource.connect()` 用消息子串判定「池已关闭」 | R1G | 修复 |
| G07 | 连接池 `ConnectionException` 未映射，池耗尽统一 `INTERNAL`；`TIMEOUT`/`CACHE` 零落点 | R3G、R5G6 | 修复 |
| G08 | `fdbm_global__<table>` 的逻辑库未做启动校验 | R3G | 修复 |
| G09 | `sequence` 自检缺少 `fountain_sequence` 表存在性检查 | R3G | 修复 |
| G10 | `normalize()` 区块外覆盖区块内且无 WARN | R3G | 修复 |
| G11 | `BootScriptWriter` 非线程安全（`pending` 并发写、固定 `.tmp` 名） | R3G | 修复 |
| G12 | `start()` 吞监听异常，进程退出码 0 | R3G | 修复 |
| G13 | 优雅停止丢弃 `closeAndAwait` 结果，超时/异常无日志 | R3G | 修复 |
| G14 | 启动失败路径不释放已建资源（缓存/连接池） | R3G | 修复 |
| G15 | `PartitionCache.closed_` 非原子，关闭后静默降级 | R3G | 修复 |
| G16 | 会话 `cursor`/`pinned` 无并发保护（巡检 vs 请求 vs 关停） | R3G、R5G11 | 修复 |
| G17 | WHERE 内子查询返回 `SQL_SYNTAX`，设计要求 `UNSUPPORTED_SQL` | R4G | 修复 |
| G18 | 引用别名、库限定名的引用符在 AST/渲染中丢失；`ColumnExpression` 单标志导致表名被一起引用 | R4G(×2) | 修复 |
| G19 | 标识符比较大小写敏感，`WHERE ID = 5` 无法路由 | R4G | 修复 |
| G20 | 别名限定的分库键抽取不到 | R4G | 修复 |
| G21 | MySQL 家族字符串参数未转义反斜杠 | R4G | 修复 |
| G22 | 逻辑库限定名原样下推，逻辑名 ≠ 物理名时读错库 | R4G | 修复 |
| G23 | `show tables` 失败路径泄漏语句与连接 | R5G3 | 修复 |
| G24 | 多行 INSERT 逐行自动提交，部分成功不回滚 | R5G4 | 修复（同库分组事务；跨库无 2PC 记录在案） |
| G25 | 全局表写广播绕过会话事务（pin 被静默忽略） | R5G5 | **记录不修**：pin 只对应一个物理库，广播写无法纳入同一事务；无 2PC 时任何「修复」都是伪原子。改为显式文档化（§9.4 例外）、首次发生时记 WARN、并用例固定「独立连接、各自提交」行为 |
| G26 | `begin` 失败或 `commit` 归还失败后 pin 状态残留 | R5G7 | 修复 |
| G27 | 「同分库维度」未比较分片空间，跨逻辑库 JOIN 误判 `Empty` | R5G8 | 修复 |
| G28 | `QueryCursor.next()` 抛异常后 `rowValid`/行缓冲未复位 | R5G9 | 修复 |
| G29 | `fdbm_sessionSweepInterval` 是唯一无正数校验的时间键（0 会忙轮询） | R6G | 修复 |

并入 P0 族的一般项（8 条）：percentDecode → D12；SHOW 逻辑库（R3G / R5G1 / R5G2）、未配置逻辑库展开、
`sequenceDatabase` 口径 → D03；自定义覆盖（R3G / R5G10）→ D09。

落入 P2 的一般项（9 条）：`f_dbm` 零测试、`encodeParameterUnsupportedTypeThrows` 名实不符、
类型矩阵不足、`nullShortCircuit` 无断言、公开行为缺口清单、列类型归一零断言、优雅停止零测试、
零并发用例、连接归还不可观测 → T01–T12（逐条见 `tasks.md` §3）。

**51 条一般项的逐条去向见附录 A**（与 `todo.md` 顺序一一对应，无遗漏、无一项被静默丢弃）。

## 3. P0 设计

### D01 流参数编码（`f_dbd/src/common/types.cj`）

- **根因**：`encodeParameter` 调 `readChunk(x, Int64.Max)`；`readChunk` 每轮 `Array<Byte>(want - got)`
  在 `read` 之前分配。
- **方案**：
  1. `readChunk(stream, size)` 每轮只分配 `min(remaining, DEFAULT_STREAM_CHUNK)`（64 KiB）缓冲，
     累积到 `ArrayList<Byte>`；`size <= 0` 仍表示「读至 EOF」。
  2. `encodeParameter` 的 `InputStream` 分支改为 `readChunk(x, 0).toData()`（语义：读至 EOF），
     内存上界为「对象本身大小 + 一块缓冲」。
  3. 读取期异常（`IOException` 等）包成 `DataException`，沿用 `DbdStatement.encode` 的
     `CONVERSION` 包装（`DbdStatement.cj:198-205`）。
- **验证**：1 MiB 流参数编码成功且字节一致；>64 KiB 时 `read` 调用次数 ≥ 2 且每次 buffer ≤ 64 KiB；
  编码耗时线性（以 1 MiB/4 MiB 两次调用的字节数而非时间断言，避免 flaky）。

### D02 流列整读与 `Unknown` 归 String（`types.cj:347-370`）

- **方案**：`readData` 增加显式分支——`SqlReadType.Stream => readChunk(readStream(result, index), 0).toData()`；
  `SqlReadType.Unknown => cellOf<String>(...)`（`readType` 已把未识别拼写归 `Unknown`，`canonicalName`
  同一判定记 WARN）。删除 `case _` 兜底，改为编译期穷举（`match` 无 `_`）。
- **验证**：200 KiB BLOB 经 `readData` 完整返回；`typeName='weird_type'` 按 `String` 读且日志含原拼写。

### D03 逻辑库命名空间（`fdbm/src/config/{FdbmConfig,settings}.cj`、`route`、`execute`）

- **模型**：新增 `LogicalCatalog`（`fdbm/src/config/catalog.cj`）：
  - `logical → Array<String>`（物理库，**配置顺序去重**）；
  - `names(): Array<String>`（按名称排序，保证跨进程确定性）；
  - `physicals(name): ?Array<String>`；
  - `default(): String`。
- **装载规则**（`logicalDatabases()` 重写）：
  1. 只收 `fdbm_db_logicalDatabase_<logical>` 显式项；
  2. 只扫描 `fdbm_partition__*` 引用的逻辑名，未显式配置的补成「全部物理库」（排序去重）；
     `fdbm_global__*` **不**触发隐式展开，必须显式引用已存在的逻辑库，否则 `validateGlobalTables` 报 `CONFIG`；
  3. 仍为空时：单一物理库 → 以该物理库名作为唯一逻辑命名空间（仅此一处回退，记 WARN）；
     多物理库 → 取排序后的第一个物理库名作命名空间并记 WARN（不阻断启动，兼容旧部署）。
- **默认库**：`defaultDatabaseOf` 只在逻辑命名空间内选择：`names.size == 1` → 它；否则排序第一个并记 WARN
  （协议无「连接时声明 database」，多逻辑库部署必须用 `logical.table` 限定，已在 §9.1 登记）。
- **校验**：
  - `validatePartitions` 的逻辑库引用改为「在 catalog 中」；
  - `validate` 新增 `globalTables` 的逻辑库引用校验（G08）；
  - `sequenceDatabase` 允许逻辑名或物理名：逻辑名 → 其物理库排序第一个；两者都不是 → `ID_GENERATOR`。
- **SHOW**：`ShowExecutor` 注入 `LogicalCatalog`；`SHOW DATABASES` = `catalog.names()`；
  `SHOW TABLES <logical>` 先 `physicals(logical)`，未知 → `ROUTE_FAILED('unknown database')`，
  用该集合首个物理库的驱动与连接做内省。
- **兼容**：`FdbmSettings.logicalDatabases` 保留字段类型（`HashMap`），内部由 catalog 产出；
  既有只配物理名（逻辑名==物理名）的部署行为不变。
- **验证**：`logical=app, physical=db0..db3` 时默认库为 `app`、`order` 表按 `app` 命中规则；
  `SHOW DATABASES` 只含 `app`；`SHOW TABLES app` 成功；`fdbm_global__dict='cfg'`（未配置）启动失败。

### D04 事务 pin 的目标唯一性（`execute/executors.cj`）

- **方案**：新增 `ensurePinnedTargets(session, count, what)`：`session.pinned.isSome() && count > 1`
  → `FdbmException(ROUTE_FAILED, '<what> spanning N physical databases is not allowed inside a transaction')`。
  调用点：
  - `SelectExecutor.execute`（广播/Multi，取 `targetDatabases` 之后）；
  - `SelectExecutor.executeCount`（保留现有判断，改用公共 helper）；
  - `SelectExecutor.openSegment` 前的循环由上游保证；
  - `DmlExecutor` / `DeleteExecutor`（`plan.kind == Multi` 且 pin）；
  - `DeleteExecutor.queryKeys`（多库 + pin）；
  - `DdlExecutor`（pin 时直接拒绝：DDL 必须广播到逻辑库全部物理库）。
- **不做**：不把多目标语句「拆成多次同一连接」——那正是当前错误；也不做 pin 自动升级为多连接（会破坏 read-your-writes）。
- **验证**：pin 下 `id in (1, 10000001)` 的 UPDATE/DELETE/SELECT、DDL 均 `ROUTE_FAILED`，物理库只收到 `begin`
  与 `commit`；非 pin 下同样语句逐库执行并累加。

### D05 广播范围收敛到逻辑库（`executors.cj`）

- **方案**：`SelectExecutor.targetDatabases` 的 `Unroutable` 分支改为 `scopeOf(statement, session)`：
  首个表引用的 `database`（逻辑库）否则 `session.database`，经 `LogicalCatalog.physicals` 解析；
  未知逻辑库 → `ROUTE_FAILED`。`emptyOutcome` 用同一 scope 取列信息。`DdlExecutor` 的
  `configured.isEmpty()` 回退改为 `catalog.physicals(session.database)`，为空才 `ROUTE_FAILED`。
  `broadcastWrite` 的 `databases` 为空时不再回退到 `resources.databases()`，改为抛
  `FdbmException(ROUTE_FAILED, '... has no physical database')`。
- **验证**：两个逻辑库 `app(db0,db1)`、`cfg(db2,db3)`；`app` 上无分库条件 SELECT 只触达 db0/db1，
  `count(*)` 不含 db2/db3；DDL 只改 db0/db1。

### D06 参数→字面量白名单（`sql/{ParameterBinder,SqlRenderer}.cj`）

- **方案**：
  1. `ParameterBinder.bindExpression` 对 `params[i].data` 做 `LiteralGuard.check(data)`：
     支持 `DataString` / `DataReal` / `DataBool` / `DataNone` / `DataDateTime` / `Array<Byte>`
     （`DataCollection<Array<UInt8>, UInt8>`）；其它 → `FdbmException(CONVERSION,
     'parameter ${index} of type <T> cannot be used as a SQL literal')`，在**渲染之前**失败。
  2. `SqlRenderer.literal(data, dialect! = Unknown)`：
     - `DataString` → `quoteText(value, dialect)`；
     - `DataReal` → `data.data.toString()`（不经 `Float64`）；
     - `DataBool` / `DataNone` → 原样；
     - `DataDateTime` → 引号包裹的 `yyyy-MM-dd HH:mm:ss[.fffffffff]`（本地时区，不转换）；
     - 字节序列 → MySQL `X'<hex>'`、其它 `'\x<hex>'`；
     - 其它 → 抛 `CONVERSION`（fail-closed，渲染器不再输出 `toString()` 文本）。
  3. `Duration`、`DataUnit`、`DataList`、`DataMap`、`DataObject` 等一律不支持（SQL 无可移植字面量），
     错误码 `CONVERSION`，文档 §8.1 参数表同步标注。
- **兼容**：`SqlRenderer.literal(data)` 单参重载保留（等价 `dialect = Unknown`）。
- **验证**：`DateTime` / 字节参数生成合法 SQL 并被 mock 物理库按同名参数回读；`Duration` 参数 →
  `CONVERSION` 且物理库未收到语句。

### D07 数值字面量精度（`sql/SqlParser.cj:742-770`）

- **方案**：`numberOf` / `negatedNumberOf` 先 `Int64.tryParse`（快路径），失败后直接
  `DataReal(text)`（`Decimal.parse`，保留原文精度）；`Decimal.parse` 失败才回退
  `Float64.tryParse`（记 WARN，仅接受指数等 Decimal 不支持的写法），再失败 → `SQL_SYNTAX`。
- **验证**：`12345678901234567890` 解析为 `DataReal` 且 `toString()` 与原串数值一致；
  `123456789012345678.90` 小数位不丢；负号路径同样成立。

### D08 派生表形状（`sql/SqlParser.cj`）

- **方案**：`derivedTablesOf(statement)` 统计 `from` **与 `joins`** 的派生表；`validateSelectShape`
  用该计数（因此 `derivedCount != 1 || from.size != 1 || !joins.isEmpty()` 会拒绝「派生表在 JOIN 中」）。
  新增 `validateUpdateShape` / `validateDeleteShape`：任一 `join.table.derived.isSome()` → `UNSUPPORTED_SQL`
  （`update/delete ... join (select ...)`），错误文案含位置。`tableRef` 仍允许解析派生表，由形状校验拒绝，
  保证错误码统一。
- **验证**：三条来自 R4S3 的语句均 `UNSUPPORTED_SQL`；合法 `update t join u on ... set ...` 不受影响。

### D09 内置名保护（`config/FdbmConfig.cj`、`route/algorithms.cj`、`idmaker/IdMakers.cj`）

- **方案**：
  1. `validatePartitions`：`customAlgorithms ∩ BUILTIN_ALGORITHMS != ∅` → `PARTITION_CONFIG`
     （信息含冲突名与「内置实现不可覆盖」）；未知算法仍 `PARTITION_CONFIG`。
  2. `validateIdMaker`：`customIdGenerators ∩ {uuid, snowflake, sequence} != ∅` → `CONFIG`。
  3. 工厂与 `IdMakers.forTable` 保留「自定义优先」查找顺序（校验已保证不冲突），但补一句注释说明
     该顺序不再是覆盖机制；`create` 对未知名仍 `PARTITION_CONFIG`。
  4. `Route_test.cj:113-116` 的期望反转为「注册 `hash` 后启动校验失败」；新增正向用例：
     自定义名 `myhash` 正常生效且 `hash` 仍为内置。
- **验证**：见上；`CustomLoader` 的自定义之间重名路径不变。

### D10 UUID v1/v6（`fdbm/src/idmaker/IdMakers.cj`、`f_util/src/uuid.cj`）

- **根因**：`f_util` 的时间戳写入在 `Int64` 纳秒左移时溢出（`timestampNanos` 恒 0）；旧路径
  `registerFileSequenceGenerator()` 还会为每次生成建临时目录/文件。
- **方案**：`UuidIdGenerator` 持有**进程级复用的** `TimeBasedUUIDBuilder`（`version == 1` 用
  `UUID.timeBased(timeLowFirst: true)`，`6` 用 `UUID.timeBased()`），构造时调一次
  `registerSequenceGenerator()`（内存原子序列，不建临时文件/目录）；`nextStringId()` 在
  `Mutex` 内执行 `.serialSeq.randomNode().toString()`（builder 的 `timestamp`/`seq` 字段非线程安全，
  必须由调用方串行化）。v4/v7 路径不变。
- **验证**：连续 1000 个 v1 的 `timestampNanos` 非零且单调不减；v6 同；`/tmp` 下不新增目录
  （对比生成前后目录项数）；并发 8 线程各 200 个 ID 无重复、时间戳非零。

### D11 ID 生成器能力与异常映射

- **方案**：
  1. `InsertExecutor.idLiteral`：按算法期望类型优先（`step`/`snowflake`/`sequence` → 先 `nextIntId`；
     其它 → 先 `nextStringId`），捕获 `IdGeneratorException` 后尝试另一方法；两者都失败 →
     `FdbmException(ID_GENERATOR, 'id generator \'<name>\' supports neither int nor string id: <msg>')`。
  2. `FdbmHandler.handle` 在 `SqlException` 之前增加 `catch (e: IdGeneratorException)` →
     `errorOf(..., ID_GENERATOR, ...)`（防御任意扩展直接抛出）。
  3. 文档：`f_dbm/README.md` 与 `详细设计.md` §7 明确「只实现一种能力是合法用法」。
- **验证**：仅实现 `nextStringId` 的生成器配 `step` 表 → 落字符串 ID（不报 `INTERNAL`）；
  两者都抛 → `ID_GENERATOR`；`fdbm_idmaker=uuid,1` + `step` 算法 → 走字符串回退成功。

### D12 DbdUrl 编码与下标（`f_dbd/src/driver/DbdUrl.cj`）

- **方案**：
  1. 删除 `take`/`countOf`（Rune 下标），全部改用 `String` 的**字节切片** `s[start..end]`
     （`indexOf`/`lastIndexOf` 返回字节下标，与 `MultiDUrl.cj` 一致）。
  2. `percentDecode` 改为字节级：`%XX`（两位十六进制，大小写均可）→ 一个字节；其它字符按其 UTF-8
     字节原样写入；结果 `String.fromUtf8`，非法 UTF-8 或残缺 `%` → `DbdException(CONFIG)`。
  3. `database` 也走 `percentDecode`（与 `percentEncode` 对称）；`firstSegmentOf` 仍按字节切。
  4. `Rune(UInt32)` 不再参与解码，消除 `%FFFFFF` 的越界异常。
- **验证**：`fdbm://u:p%40ss@h:1/%E5%BA%93` 解析出 `p@ss` / `库`；`parse(toUrl(x))` 对中文用户名、
  口令、库名三重往返相等；`%FF`（非法 UTF-8）→ `CONFIG`；13 条既有 ASCII 用例不变。

## 4. P1 设计要点

### 4.1 配置与文档

- **G01**：`DbdOptions.timeoutOf` 返回 `?Duration` 只表达「解析成功」；`apply` 仅在 `Some` 时赋值，
  `None` 保留原值并 WARN。`0`/负数同 WARN（不再被当成「无限」）。
- **G02**：`f_dbd/src/dbd.cj` 补 `public import` 重导出（`common.*`、`exception.*`、
  `driver.{DbdDriver,DbdUrl,dbdDriver}`、`multid.{MultiD,MultiDUrl,MultiDatasource}`）与
  `public func fdBDVersion(): String`；删除「阶段 0」注释；`dbd_test.cj` 改为断言重导出可用。
  `ImportPath` 冲突时按「最少重导出」收敛（以编译通过为准）。
- **G03**：注册名唯一口径 = `dbd_driverName`（后端方言名）。`static init` 改为「配置了才注册，
  未配置记 INFO 跳过」；`DbdDriver()` 无配置抛 `DbdException(CONFIG)`；`dbdDriver()` 语义不变。
  若 `fdbm` 未被占用，额外注册兼容别名 `fdbm`（INFO 日志），避免旧应用 `getDriver('fdbm')` 立刻失败。
  文档同步：`f_dbd/README{,_en}.md`、`详细设计.md` §5.2、`spec.md`、`tasks.md`、类注释。
  测试改为显式 `Config.set([('dbd_driverName', 'postgres')])`，不再依赖外部 env。
- **G29**：`getSessionSweepInterval` 校验 `> 0 && != Duration.Max`，与 `shutdownTimeout` 同口径。

### 4.2 生命周期与资源

- **G14**：`FdbmServer` 构造改为「驱动校验 → 缓存 → 资源 → 路由」，任一步失败时按逆序关闭已建对象；
  `DatabaseResources` 构造函数用 `try/catch` 包住建池循环，失败先 `close` 已建池再抛。
- **G12**：`start()` 的监听异常在 `!closed` 时包成 `FdbmException(INTERNAL, 'listener failed')` 抛出，
  `main` 返回 1；`closed` 已置位（正常停止）时保持吞掉。
- **G13**：`stop()` 记录 `closeAndAwait` 返回值，`false` → WARN；`DatabaseResources.closeAndAwait`
  逐池失败/超时记 WARN（含池名）；`PartitionCache.close` 失败记 WARN。
- **G23**：`ShowExecutor` 的 `selectRead → prepareStatement → query` 用 `try/finally`：任何一步失败
  都关闭已建 statement/connection（沿用 `openSegment` 的写法）。
- **G26**：`begin` 先 `selectWrite` + `executeUpdate('begin')`，成功后才 `session.pin(...)`；
  `commit/rollback` 的 `finally` 先 `session.unpin()` 再 `PinnedConnection.close()`。

### 4.3 并发

- **G11**：`BootScriptWriter` 增加 `Mutex`，`set`/`flush`/`normalize` 全程持锁；临时文件名带
  进程内唯一序号（`'${target}.tmp.${serial}'`），`rename` 后清理；`pending` 只在锁内读写。
- **G16**：`DbdSession` 增加 `Mutex` + `closed_`，公开方法：
  `installCursor(cursor): Bool`（会话已关 → 立刻关闭新游标并返回 false）、`takeCursor(): ?QueryCursor`
  （原子摘除，供 close 使用）、`pin(p)`/`unpin(): ?PinnedConnection`、`close()`（置位后摘除并关闭）。
  `sweep` 与 `closeAll` 都通过 `takeCursor`/`unpin` 摘除；`handler.executeSql` 用 `installCursor`。
- **G15**：`closed_` → `AtomicBool`；`get/put/remove` 关闭后抛 `FdbmException(CACHE, 'partition cache is closed')`
  （`get` 不再静默 `None`）；`count` 保持锁内。
- **G28**：`QueryCursor.next()` 的 `segment.result.next()` 包 `try/catch`：异常时
  `rowValid = false; clearRow();` 再抛（`memory` 分支同样处理）。

### 4.4 协议语义

- **G04**：`bufSize = -1` 定义「流列探测」：
  - 客户端：`getOrNull<InputStream>` 首次打开时发 `CELL(index, -1)`；`DataNone` → `None<T>`；
    字节块 → 构造 `DbdInputStream(..., initial = 块)`（本地先消费该块）。
  - 服务端：`QueryCursor.cell(index, bufSize < 0)` 对流列用 `result.getOrNull<InputStream>(index)`
    判定 NULL：`None` → `DataNone`（并记住该列 NULL，后续块请求回空数组）；`Some` → 读首个
    `DEFAULT_STREAM_CHUNK` 返回。
  - 兼容：旧服务端把 `-1` 当 `<=0` 返回首块（NULL 时为空数组）→ 客户端只会退化为「空流」而非报错；
    旧客户端从不发 `-1` → 行为不变。
- **G05**：`getOrNull<T>` 在 `isStreamColumn(index)` 且 `T` 非流目标时抛
  `CONVERSION('column N is a stream column; read it as InputStream')`（不再让服务端回一块）。
- **G06**：`MultiDatasource.connect` 捕获 `ConnectionException` 后按状态判定：`closed.load()` 或
  任一节点池 `isClosed()` → `CONFIG`；否则 `TIMEOUT`。
- **G07**：`DatabaseResources.select{Read,Write,AllWrite}` 捕获 `ConnectionException` →
  `FdbmException(TIMEOUT, 'cannot borrow a connection from <database>: <msg>')`；`ensureOpen` 仍 `CONFIG`。

### 4.5 SQL 语义

- **G17**：`inExpression` 在 `(` 后若为 `select` → `unsupported('subquery in IN (...) is not supported', pos)`；
  `factor` 在 `Ident` 为 `select`（或 `exists` 后跟 `(`）时同样 `UNSUPPORTED_SQL`。
- **G18**：AST 加法（均为**带默认值的尾随参数**，源码兼容）：
  `SelectItem(..., aliasQuoted: Bool = false)`；`TableRef(..., databaseQuoted: Bool = false,
  aliasQuoted: Bool = false)`；`ColumnExpression(..., tableQuoted: Bool = false)`（`quoted` 仅指列名）。
  解析器从 `Token.quoted` 分别填；渲染器分别决定是否加引用符。`parse → render → parse` 用例覆盖
  `select id as "order" from "shop"."T" as "select"` 与 `select t."COL" from t`。
- **G19**：`Identifier.equalsName` / `==` 与分库列比较改为 ASCII 大小写不敏感（保留原始拼写供下推）；
  规则查找键同样归一（`rules.get('<logical>.<table>')` 用小写键，配置写入时也用小写键）。
- **G20**：`PartitionKeyExtractor.extract/extractRange` 接受**限定符集合**（`HashSet<String>`）：
  由调用方传 `{rule.table} ∪ {statement 中该表的 alias}`；`None` 限定符仍匹配。
- **G21**：`quoteText(value, dialect)`：MySQL 家族先把 `\` → `\\`、`'` → `''`；其它方言只 `'` → `''`。
- **G22**：`SqlRenderer.render(..., unqualified!: Bool = false)`，执行器传 `true`：渲染表引用时忽略
  `TableRef.database`（逻辑库），由目标连接默认库定位；`SHOW`/文档/测试路径保持 `false`。
- **G27**：`allSameDimension` 同时比较 `rule.algorithm.name`、`rule.column` 与两张表解析后的
  物理库集合（排序后逐项相等）；不同 → `Unroutable`，错误信息列出两表库名。
- **G24**：`InsertExecutor.insertRows` 与 `insertFromSelect`：先按 `fillAndRoute` 得到每行的目标库，
  若所有行同库 → 单连接 `begin/commit` 包住全部行；跨库 → 按库分组，每组一个事务，组间失败时
  回滚当前组并返回 `DB_ERROR`（列出已提交库），文档登记「跨库无 2PC」。

## 5. 协议与公开 API 兼容性

| 变更 | 类型 | 兼容性 | 处理 |
| --- | --- | --- | --- |
| `bufSize = -1` 流列探测 | 协议语义（保留值） | 旧客户端不发；旧服务端按 `<=0` 处理 | 新行为写入 `详细设计.md` §3.6 / §7.2 |
| `DbdErrorCode` 数值/枚举 | 不变 | 完全兼容 | — |
| 注册名以 `dbd_driverName` 为准 | 行为 | 旧应用按 `getDriver('fdbm')` 仍可用（兼容别名） | README 迁移说明 |
| `DbdDriver()` 无配置：`exit(1)` → 抛 `CONFIG` | 行为 | 进程不再被杀；调用方需捕获 | `详细设计.md` §5.2 登记 |
| `static init` 未配置不注册 | 行为 | `dbdDriver()` 仍抛 `CONFIG`（信息不变） | 测试显式配置 |
| 根包新增 `public import` 重导出 | 增量 | 只增不改 | `Reexport_test.cj` 固化 |
| `SqlRenderer.literal(data, dialect!)` | 增量重载 | 单参重载保留 | — |
| `SqlRenderer.render(..., unqualified!)` | 增量参数 | 默认 `false`，行为不变 | — |
| AST 新增 `aliasQuoted` / `databaseQuoted` / `tableQuoted` | 增量字段（默认值） | 既有构造调用不变 | 往返用例 |
| 流列标量读 → `CONVERSION` | 行为（收紧） | 之前返回截断数据，属缺陷 | README「B 口径」 |
| `getOrNull<InputStream>` NULL → `None` | 行为（修正） | 之前返回空流 | spec 与 README 同步 |
| `PartitionCache` 关闭后抛 `CACHE` | 行为（收紧） | 关闭只发生在停止流程 | 与开发计划 Step 5.3 对齐 |
| 自定义名与内置冲突 → 启动失败 | 行为（收紧） | README 早已承诺 | CHANGELOG 记录 |
| 多行 INSERT 同库事务 | 行为（增强） | `rowCount` 语义不变 | — |
| 逻辑库限定符下推时去掉 | 行为 | 逻辑名≠物理名从「读错库」变为「读对库」 | 文档 §8.2 |
| `DatabasePool.closeAndAwait` 等待在借连接 | 行为（收紧） | 有未归还连接时超时返回 `false`（原只看内部线程） | 仅影响优雅停止；`close()` 不变 |

## 6. 失败模式与回滚

- **D03 是新旧语义分界**：旧部署若故意用物理库名当逻辑库（如 e2e 的 `db0`），修复后仍可用
  （只有 `fdbm_partition__*` 引用的名字会隐式展开为全部物理库；`fdbm_global__*` 必须显式引用已存在
  的逻辑库，否则 `CONFIG`），但 `SHOW DATABASES` 的输出集合会变化；文档与 e2e 断言同步更新。
- **D05 收紧广播范围**：若语句带未知逻辑库限定，之前会「广播成功」，之后 `ROUTE_FAILED`。这是有意的
  安全收紧，登记为已知变更。
- **G22 去限定符**：若客户端用限定名指向**另一个**逻辑库（`cfg.t`），语句的目标库由路由决定，
  渲染不再保留 `cfg.`，但连接仍是路由得到的物理库 ⇒ 语义与「按路由执行」一致；文档写明
  「限定名只用于选择逻辑库，不参与物理定位」。
- 所有收紧项均在 `详细设计.md` 的「已知偏差/限制」小节登记，并在 `CHANGELOG` 顶层列一条汇总。

## 7. 验收标准

1. `cd f_dbm && cjpm test`、`cd f_dbd && cjpm test`、`cd fdbm && cjpm test` 全绿（记录断言数）。
2. `fdbm/test/e2e/run.sh` 在 `postgres` 与 `mysql` 两个后端全绿，且部署改为**逻辑库名 ≠ 物理库名**。
3. 每个 P0 缺陷至少一条「红→绿」用例；每个 P1 项要么有对应用例，要么有显式「不修」记录（G25）。
4. `cjpm build` 无新增 warning；`详细设计.md` / README / `开发计划.md` 与代码一致。
5. 协议回归：既有 `f_dbd` 桩用例（消息矩阵、游标、超时）不改断言即通过；仅新增 `-1` 探测用例。
6. `f_orm` 全量测试不受影响（不修改 `f_orm`，但需跑一次确认）。

## 8. 证据索引

| 轮次 | 文件 | 主要覆盖 |
| --- | --- | --- |
| R1 | `reviews/.../review_v1.md` | f_dbd 类型/流/URL/驱动注册/多节点 |
| R2 | `review_v2.md` | f_dbd 测试矩阵、f_dbm 零测试、重名覆盖 |
| R3 | `review_v3.md` | fdbm 配置/逻辑库/自检/生命周期/并发 |
| R4 | `review_v4.md` | SQL 解析/渲染/标识符/精度/派生表 |
| R5 | `review_v5.md` | 执行器/pin/广播/DDL/错误码/游标 |
| R6 | `review_v6.md` | 测试完整性矩阵、扩展链路、优雅停止、并发 |

## 附录 A：51 条一般项逐条处置

序号与 `todo.md` 中「一般」条目的出现顺序一致（R1→R6，轮内自上而下）。

| # | 轮次 | 一般项（摘要） | 去向 | 处置 |
| --- | --- | --- | --- | --- |
| 1 | R1 | `percentDecode` 按 Rune 还原非 ASCII | D12 | 修复 |
| 2 | R1 | 非法超时被静默改成无限等待 | G01 | 修复 |
| 3 | R1 | 根包为空、无注册入口/重导出 | G02 | 修复 |
| 4 | R1 | 驱动注册名三处文档矛盾 | G03 | 修复 |
| 5 | R1 | `static init` 未配置即 `exit(1)` | G03 | 修复 |
| 6 | R1 | `getOrNull<InputStream>` 对 NULL 返回 `Some(空流)` | G04 | 修复 |
| 7 | R1 | 流列标量读只回首块且不报错 | G05 | 修复 |
| 8 | R1 | `MultiDatasource` 用消息子串判定池关闭 | G06 | 修复 |
| 9 | R2 | `f_dbm` 零测试 | T01 | 修复（补测试） |
| 10 | R2 | `encodeParameterUnsupportedTypeThrows` 名实不符 | T02 | 修复（改用例） |
| 11 | R2 | `f_dbd` 测试依赖 env 且断言与文档相反 | G03 + T02 | 修复 |
| 12 | R2 | 类型矩阵少于 spec 承诺 | T03 | 修复（补测试） |
| 13 | R2 | `nullShortCircuit` 无断言 | T02 | 修复（改用例） |
| 14 | R2 | 公开行为缺口清单（10 条分支无用例） | T10 | 修复（补测试） |
| 15 | R3 | `SHOW DATABASES/TABLES` 只认物理库 | D03 | 修复 |
| 16 | R3 | 未配置逻辑库未隐式展开 | D03 | 修复 |
| 17 | R3 | 自定义名与内置重名未拒绝 | D09 | 修复 |
| 18 | R3 | `fdbm_global__` 逻辑库未启动校验 | G08 | 修复 |
| 19 | R3 | `sequence` 自检缺表存在性 | G09 | 修复 |
| 20 | R3 | `sequenceDatabase` 逻辑/物理口径矛盾 | D03 | 修复 |
| 21 | R3 | 连接池异常未映射 `TIMEOUT` | G07 | 修复 |
| 22 | R3 | `normalize()` 区块外覆盖区块内 | G10 | 修复 |
| 23 | R3 | `BootScriptWriter` 并发不安全 | G11 | 修复 |
| 24 | R3 | `start()` 吞监听异常，退出码 0 | G12 | 修复 |
| 25 | R3 | 优雅停止丢弃 `closeAndAwait` 结果 | G13 | 修复 |
| 26 | R3 | 会话游标状态无并发保护 | G16 | 修复 |
| 27 | R3 | `PartitionCache` 关闭标志非原子、静默降级 | G15 | 修复 |
| 28 | R3 | 启动失败不释放已建资源 | G14 | 修复 |
| 29 | R4 | WHERE 子查询报 `SQL_SYNTAX` | G17 | 修复 |
| 30 | R4 | 引用别名/库名引用符丢失 | G18 | 修复 |
| 31 | R4 | `ColumnExpression` 单 `quoted` 把表名一起引用 | G18 | 修复 |
| 32 | R4 | 标识符比较大小写敏感 | G19 | 修复 |
| 33 | R4 | 别名限定的分库键抽不到 | G20 | 修复 |
| 34 | R4 | MySQL 字符串未转义反斜杠 | G21 | 修复 |
| 35 | R4 | 逻辑库限定名原样下推 | G22 | 修复 |
| 36 | R5 | G1 `show tables` 把逻辑库当物理库 | D03 | 修复 |
| 37 | R5 | G2 `show databases` 返回物理库 | D03 | 修复 |
| 38 | R5 | G3 `show tables` 失败泄漏语句/连接 | G23 | 修复 |
| 39 | R5 | G4 多行 INSERT 非同一事务 | G24 | 修复（同库事务；跨库限制记录） |
| 40 | R5 | G5 全局表写绕过会话事务 | G25 | **记录不修**：无 2PC；文档化 + WARN + 用例固定 |
| 41 | R5 | G6 池失败与 ID 生成异常落 `INTERNAL` | G07 + D11 | 修复 |
| 42 | R5 | G7 `begin`/`commit` 失败后 pin 残留 | G26 | 修复 |
| 43 | R5 | G8 同维度未比较分片空间 | G27 | 修复 |
| 44 | R5 | G9 游标 `next()` 异常后状态未复位 | G28 | 修复 |
| 45 | R5 | G10 自定义算法覆盖内置 | D09 | 修复 |
| 46 | R5 | G11 巡检与在途请求并发关闭会话 | G16 | 修复 |
| 47 | R6 | 列类型归一零断言 | T06 | 修复（补测试） |
| 48 | R6 | 优雅停止语义零测试 | T05 | 修复（补测试） |
| 49 | R6 | 零并发用例 | T04 | 修复（补测试） |
| 50 | R6 | 启动自检负例 13/16、退出码未测；`sessionSweepInterval` 无校验 | G29 + T08 | 修复 |
| 51 | R6 | 连接/游标归还没有可观测断言 | T09 | 修复（`maxSize=1` 强约束 + 计数桩） |

统计：修复 50 条（P0 族 8 条、P1 族 33 条次的代码/文档改动、P2 9 条测试），记录不修 1 条（#40）。
