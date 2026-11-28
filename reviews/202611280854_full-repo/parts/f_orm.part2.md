# f_orm 模块审查报告

> **模块第 2/8 部分**（只覆盖 `files/f_orm.part2.txt` 列出的 14 个文件：`README_en.md` + `doc/**` 9 个 `.md` + 4 个 `.cj`。本部分的 `.cj` 是「模块门面 / 编译期敏感信息宏 / 两个参数绑定护栏用例」，**不含** `SqlExecutor`、连接、事务、`SqlPartial` 的实现——这些属于同模块其他部分，本报告只在核对文档时把它们当判据引用，不计入覆盖、不展开审查。README 的中文版 `README.md` 不在本部分清单内。）
>
> - **审查日期**：2026-11-28
> - **模块路径**：`f_orm`（本部分 4 个 `.cj` / 10 个 `.md`；模块共 111 `.cj` + 11 `.md`）
> - **基线**：工作区快照（无 diff ⇒ 全部问题记「存量」）
> - **审查重点**：executor 生命周期与线程内复用语义（文档断言核对）、连接与事务（文档断言核对）、SQL 注入与参数绑定（`arg` / `add` 护栏用例）、大粒度锁、OOM、死代码、重复逻辑、存量 BUG
> - **报告版本**：v1（第 2/8 部分）

## 发现

### [轻微][存量] #1 `ArgBindCount_test` 把进程级 `MOCKDB.execution` 换掉后不还原，给后续用例留下外来夹具

- **位置**：`f_orm/src/base/ArgBindCount_test.cj:41-54`（设置 `MOCKDB.execution`）、`40`（只调 `MOCKDB.clear()`）、`61-65`（用完直接 `ex.clearSql()` 结束，无 `finally` 还原）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「资源不对称 / 副作用未回滚」、§12.1「共享可变状态」、§14「测试隔离」
- **证据**：静态确定（结构）—— `MOCKDB.clear()` 明确**不**重置 `execution`（`f_mockdb/src/mockdb.cj:71` 的注释与 `77-90` 的实现都写明「不动 execution 与 toThrowOn* 标志」），唯一能还原的 `clearExecution()` 是包内可见的 `static func`（`mockdb.cj:92-95`），`f_orm` 的用例调不到；而 `MOCKDB.execution` 是 `AtomicOptionReference` 的进程级单例（`mockdb.cj:57`、`105-112`），`cjpm test` 同进程内所有用例共享。这个夹具会给**每一次** SQL 执行追加一列 `n`（`SqlBigInt`）和一行 `[1]`（`52-53`）。
- **描述**：今天尚未造成红——本模块 11 处设置 `MOCKDB.execution` 的用例都在各自开头覆盖了它（`ArgInSql_test` / `SqlResultCache*_test` / `SqlPartialColumnKey_test` / `SqlExecutorArgBranches_test` / `SqlExecutorStatement_test` / `QueryResultIterator_test` 等），其余不执行 SQL 的用例（`ArgSqlText_test` / `QueryResultWrap_test` / `migro_test` / `f_mockdb_po_test` 等）不会走到 `execution`；唯一会执行 SQL 却未设夹具的 `SqlExecutorConnectingTimeout_test.cj:104-108` 在建连阶段就抛超时，也到不了夹具。风险是**潜伏**的：下一个「执行 SQL 但忘了设夹具」的用例会静默继承本夹具（多一列一行、`first` 返回非 `None`），且失败与否取决于执行顺序。
- **建议**：① `f_mockdb` 把 `clearExecution()` 提升为 `public`（或提供 `reset()`），让用例能对称还原；② 本用例改成 `try { ... } finally { MOCKDB.clearExecution() }`；③ 更好的做法是把 `execution` 做成可嵌套的「夹具作用域」helper（设置→返回捕获对象→`finally` 还原），供全模块 11 处赋值点统一使用（其余 10 处见「范围外提示」）。

### [一般][存量] #2 README 关于 `SqlExecutor.isReadOnly` 「恒为 false」的说明与实现相反，且实现侧的粘滞语义未被文档化

- **位置**：文档 `f_orm/README_en.md:406`、`561`；实现 `f_orm/src/base/SqlExecutor.cj:83-86`（`isSelectStatement(normalized)` 成立时 `readOnly = true`）、`47`（`private var readOnly = false` 初始化）、`107-111`（getter）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「API / 行为与源码不符」、§11「语义与注释不符」
- **证据**：静态确定 —— README 写「the current implementation only sets false for non-select and has no branch setting true, so it is **always false**」「`beforeCommit(readOnly)` … which is **always `false`** in the current implementation」；实际 `sql` 的 setter 在语句以 `select` 开头时把 `readOnly` 置 `true`，全文件只有 `47`（初值）、`85`（置 true）、`109`（读）三处，`close()`（`153-174`）与 `clearSql()`（`97-105`）都**不复位**。
- **描述**：两层后果。① 文档层面：使用者会以为 `isReadOnly` 是永远 false 的死开关，从而不校验它；② 行为层面：同一个 executor 实例内先跑过任何 `select` 之后，再跑 `update`，`readOnly` 仍为 `true`，`beforeCommit(readOnly)`（`SqlExecutor.cj:1048/1071/1087`）与 `isReadOnly` 都会向事务钩子报「只读」——写事务被当成只读事务处理。
- **建议**：文档改成「select 置 `true`，当前实现不复位（粘滞），因此只应作为『本实例曾执行过 select』的弱提示」；实现上应在 `setSql`/`clearSql` 里成对复位（`readOnly = isSelectStatement(normalized)`），或在 `close()` 里复位——这部分属 `base/SqlExecutor.cj`（其他部分），本部分只负责把文档口径改对。

### [一般][存量] #3 README 第 18 章「敏感信息」的三条断言与代码不符（运行期不读 `sensitiveMap` / 全局名不嵌入 / 宏文件路径）

- **位置**：文档 `f_orm/README_en.md:2288-2291`（「只读 `Config`（环境变量），**不读** `sensitiveMap`，嵌入值在运行期不会被自动使用」）、`2326-2327`（同义重复）、`2318`（`Embedding rules (macros/EmbedSensitive.cj)`）、`2320-2323`（「只嵌入带驱动名前缀的键；全局名不会原样嵌入」）；实现 `f_orm/src/ProtectedMacros/EmbedSensitive.cj:29-41`、`f_config/src/Config.cj:186-198`、`163-168`、`297-301`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档与代码相反」、§14「承诺与实现不一致」、§10「安全性描述」
- **证据**：静态确定，三条逐条取证：
  1. **运行期确实读 `sensitiveMap`**：`ORMConfig.getConf` → `Config.getString(key)`；`Config.getString` 的四段回退是 `ARGS[key]` → `ARGS['orm_'+key]` → **`sensitiveMap[key]`** → **`sensitiveMap['orm_'+key]`**（`f_config/src/Config.cj:186-198`，解码走 `sensitive2Str`），`Config.getAll` 也会把 `sensitiveMap` 合并进结果（`163-168`）。因此「嵌入值运行期不会被使用」是错的——它是环境变量缺失时的兜底来源，`getUrl` / `getUsername` / `getPassword` 都吃这条路径。
  2. **全局名会原样嵌入**：本部分宏先把 `ORMConfig.connectionUrl` / `username` / `password` 三个**全局键**放进 `keys`（`ProtectedMacros/EmbedSensitive.cj:29-33`），再逐个驱动追加 `genKey(d, …)` 前缀键（`35-41`），最后整体交给 `@EmbedSensitive`；`@EmbedSensitive` 对每个**值非空**的键调 `Config.registerSensitive(k, …)`（`f_config/src/macros/EmbedSensitive.cj:24-38`）。故 `orm_connectionUrl` / `orm_option_username` / `orm_option_password` 也会被嵌入，与「全局名不会原样嵌入」相反。
  3. **路径不存在**：`f_orm/src/macros/` 下只有 `DAO.cj` / `ORMField.cj` / `QueryMappersGenerator.cj` / `TransactionalService.cj`（`macro package fountain::f_orm.macros`），没有 `EmbedSensitive.cj`；真正干这件事的是 `f_orm/src/ProtectedMacros/EmbedSensitive.cj`（`protected macro package fountain::f_orm.ProtectedMacros`，在 `src/base/imports.cj:38` 以 `@ORMEmbedSensitive()` 触发）。
- **描述**：这一段是使用者的「凭据从哪来」说明，三条同时错会直接把排查带偏：按文档会认为「编译期嵌入是白做的、运行期必须配环境变量」，而实际上是「环境变量优先、嵌入值兜底」；同时「全局名不嵌入」会让多数据源排查时漏掉全局兜底这一层。附带两处未说明的风险：① SM4 的 key/iv/aad 与密文**同批嵌入**（`f_config/src/macros/EmbedSensitive.cj:40-48`，解密在 `Config.cj:174-182`），拿到二进制即可解密，SM4 保护的实际强度只是「产物里不出现明文字符串」；② 嵌入发生在 **`f_orm` 自身**的编译单元（`base/imports.cj:38`），下游以预编译 `dynamic` 库依赖时，嵌入值来自 `f_orm` 的构建机而非应用构建机，文档只写「构建环境」未点明这一层（`cjpm.toml:28` `output-type = "dynamic"`）。
- **建议**：重写 18 章开头与「Embedding rules」段：键集合写成「3 个全局键 + 每个 `orm_drivers` 驱动的 3 个前缀键」、路径改成 `src/ProtectedMacros/EmbedSensitive.cj`、取值优先级写成「环境变量 > 嵌入值（`Config.getString` 的 `sensitiveMap` 回退）」；补一句「SM4 密钥与密文同在原产物内」与「嵌入发生在 f_orm 编译期」。

### [一般][存量] #4 README 完全没有记录两个公开的「保护性上限」配置：`orm_connectingTimeout` 与 `orm_databasePoolMaxWaiting`

- **位置**：文档 `f_orm/README_en.md:185-201`（§3.1 表）、`231-243`（§3.3 表）、`256-329`（§3.5 公开 API 块）均无；源码 `f_orm/src/wrap/ORMConfig.cj:28`（常量）、`237-240`（`getConnectingTimeout`，默认 5000ms）、`51`（常量）、`244-252`（`getPoolMaxWaiting`，默认 30000ms，`<=0` 表示无限等待）；使用点 `f_orm/src/base/SqlExecutor.cj:402-404`、`f_orm/src/wrap/NamedDatasource.cj:101`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14.2「公开 API / 配置未文档化」、§13
- **证据**：静态确定 —— 两版 README（`README_en.md` / `README.md`）对 `connectingTimeout` / `maxWaiting` 的检索命中数为 0；`ORMConfig` 的 §3.5 清单里 `getConnectTimeout` / `getPoolCheckSql` 都在，唯独缺这两个 getter，§3.3 的 11 个池参数里也缺 `orm_databasePoolMaxWaiting`。
- **描述**：这两个键恰好是**唯一能终止两类挂死**的旋钮：驱动把连接停在 `Connecting` 空转（源码注释写明「原来这个等待没有上限、且是纯空转」，默认 5s 后抛 `ConnectionException`），以及池耗尽时 `get(timeout: Duration.Max)` 的等待上限（默认 30s 后返回 `None`）。文档缺项的直接后果是运维只能改代码或读源码才发现它们，线上卡死时无从调参。
- **建议**：`orm_connectingTimeout`（毫秒，默认 5000）补进 §3.1 表并在 §3.5 加 `getConnectingTimeout`；`orm_databasePoolMaxWaiting`（毫秒，默认 30000，`<=0`=无限）补进 §3.3 表与 §3.5。中文 `README.md` 同缺（属其他部分范围，建议同批改）。

### [轻微][存量] #5 6 个未使用的 `import`（宏 5 个 + 用例 1 个）

- **位置**：`f_orm/src/ProtectedMacros/EmbedSensitive.cj:19`（`std.database.sql.SqlOption`）、`20`（`stdx.crypto.crypto.*`）、`21`（`fountain::f_config.*`）、`22`（`fountain::f_macros.*`）、`24`（`fountain::f_base.UnsafeBytes`）；`f_orm/src/base/ArgAnyBinding_test.cj:20`（`std.collection.ArrayList`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— `EmbedSensitive.cj` 全文只用到 `std.ast.*`（`Tokens` / `quote`，`28-42`）、`ORMConfig`（`23` 导入、`30-39` 使用）与 `EmbedSensitive`（`26` 导入、`42` 使用）；`SqlOption` / `crypto` / `f_config.*` / `f_macros.*` / `UnsafeBytes` 在 18-43 行内零出现（`f_config.*` 的那次 `public import` 走的是 `f_config.macros` 子包，与本条 `21` 无关）。`ArgAnyBinding_test.cj` 的 `cases` 用的是 `Array<(String, Any)>`（`45`），全文无 `ArrayList`。
- **描述**：编译期残留，产生 unused 警告，也让「这个宏依赖了 crypto」的误读成立（实际 SM4 在 `f_config` 侧）。
- **建议**：删这 6 行；`EmbedSensitive.cj` 只保留 `std.ast.*`、`fountain::f_orm.wrap.ORMConfig` 与那条 `public import fountain::f_config.macros.EmbedSensitive`。

### [轻微][存量] #6 `testEverySupportedTypeStillBinds` 的「全类型」护栏漏掉 4 个标量族与几乎所有 `?T` 变体

- **位置**：`f_orm/src/base/ArgAnyBinding_test.cj:45-67`（21 条 `cases`）；对照 `f_orm/src/base/RootDAO.cj:252-306`（`arg(Any)` 的分支表）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14「测试覆盖与承诺不符」、§11
- **证据**：静态确定 —— 用例文档注释（`27-33`）声称「每个受支持类型（含 `Data` 包装值）都必须命中具体分支」，但 `cases` 里没有 `Float16`、`BigInt`、`Decimal`、`InputStream`（这 4 个都在 `arg(Any)` 的标量段：`RootDAO.cj:263`、`273`、`274`、`278`），`?T` 只有 `nbool` / `nint64` / `nnull` 三个，`Data` 只有 `DataString` / `DataReal`（缺 `DataBool` / `DataDuration` / `DataDateTime` / `DataCollection` / `DataAny` / `DataNone`）。
- **描述**：删掉 `arg(Any)` 里 `Float16` / `BigInt` / `Decimal` 分支，或用例所谓的「`Data` 可达性护栏」被破坏时，这条用例仍然全绿——它实际覆盖 16/20 个标量分支、2/20 个 `?T` 分支、2/8 个 `Data` 子类，`?Any` 也未覆盖。
- **建议**：把 `RootDAO.cj:258-306` 的分支表逐条镜像成 `cases`（`?T` 用 `Some`/`None` 各一），或用宏/反射按类名驱动；至少补齐 `Float16` / `BigInt` / `Decimal` / `InputStream` 与 `DataBool` / `DataNone`。

### [轻微][存量] #7 该护栏只看返回值 `'?'`，无法发现「返回 `'?'` 但没有绑定参数」的回归

- **位置**：`f_orm/src/base/ArgAnyBinding_test.cj:70-76`（只断言 `sql != '?'`）；`f_orm/src/base/SqlExecutor.cj:48`（`private var args` 外部不可读）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14「护栏强度不足」、§11
- **证据**：静态确定 —— 用例名与注释都写「StillBinds」（`28-31`：「`arg(x)` 内部调 `executor.add`」），但断言只比较 `arg` 的返回值；`SqlExecutor.args` 是 `private`（`SqlExecutor.cj:48`）、`SqlArgs` 也没有公开 `size`，用例**没有办法**观察绑定数。同一个仓库里的 `ArgBindCount_test.cj:41-54` 已经演示了可行做法（用 `MOCKDB.execution` 的 `args` 参数数数）。
- **描述**：把某个分支从 `arg(x)` 改成字面 `'?'`（漏 `add`）时，文本仍为 `?`、用例仍绿，运行期表现为「SQL 里 1 个占位符、0 个参数」，驱动报参数个数不符或绑定错位——正是这条护栏声称要防的形态。
- **建议**：给 `SqlExecutor` 加只读的 `prop argCount: Int64`（或包内可见的测试钩子），或改用 `MOCKDB.execution` 捕获 `args`，断言「占位符数 == 绑定数 == 1」。

### [轻微][存量] #8 计时型用例单次采样 + 墙钟阈值，共享 CI 机上可能误报

- **位置**：`f_orm/src/base/ArgAnyBinding_test.cj:84-107`（`91-101` 两段 1000 次循环各只跑一遍，`103` 断言 `anyNs <= typed * 10 + 1000`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §6.1「基准口径」（单次最快值 / 无重复轮次不可作为结论）、§11「测试可靠性」
- **证据**：待确认 —— 结构上确定：无预热、无多轮取中位数、无离散度，阈值是相对倍数 + 1µs 绝对容差；是否会翻红取决于 CI 机器的 GC/调度抖动（`typed` 约 45ns/元素时阈值约 1.45µs/元素，一次 1.4ms 的停顿摊到 1000 次就会击穿）。
- **描述**：这是模块里唯一把**性能比值**写成硬断言的用例；在共享构建机上它是「偶发红」的常见来源，而偶发红通常被当成噪声忽略，最终等于失去护栏。
- **建议**：改成「先跑 3 轮预热，再取 5 轮中位数」，并把阈值放宽到注释里实测值（≈1.5×）的 3~5 倍；或把它降级为 `@Bench` / 打印而不 `@Assert`，真正的回归门槛放到 `cjpm bench` 对照。

### [轻微][存量] #9 README 的 `UPDATE<UserPO>(map)` 示例注释写错 WHERE 列

- **位置**：文档 `f_orm/README_en.md:790-792`（`map[...id] = 1` 后 `executor.UPDATE<UserPO>(map) // where username = ?`）；实现 `f_orm/src/base/SqlPartial.cj:148-179`（`idField`/`idColumn` 取自 `m.isId`，`174` 用主键列拼 `WHERE`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「示例与实现不符」
- **证据**：静态确定 —— `UPDATE<T>(values: Map<String, Any>)` 遍历 mapper 时把 `isId` 的列记为 `idColumn` 并在 `continue` 前跳过（`155-159`），末尾 `sql.append(' WHERE ').append(involve(idColumn))`（`174`），故 `map` 里带 `id=1` 时生成的是 `where id = ?`（`username` 只进 `SET`）。
- **描述**：「无 id 版 UPDATE 用主键做 WHERE」正是这一节要讲的重点（`768-772` 的正文写对了），只有示例行内注释写反，读示例的人会以为可以在 `SET` 里改主键或 WHERE 用的是别的列。
- **建议**：改成 `// where id = ?`。

### [轻微][存量] #10 README 头部元信息与 `cjpm.toml` 不一致（版本号、依赖清单）

- **位置**：`f_orm/README_en.md:3`（`version 1.3.6`）、`5-6`（依赖清单）；`f_orm/cjpm.toml:31`（`version = "1.3.2021"`）、`1-17`（含 `fountain::f_dbpool`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档与工程元数据不符」
- **证据**：静态确定 —— 版本号两处不同；依赖清单漏 `fountain::f_dbpool`（正文 §3.3 又说 `DatabasePool` 已迁到该模块，前后不一致），另漏 `test-dependencies` 的 `fountain::f_mockdb`（`cjpm.toml:19-20`，属测试依赖，可不写）。
- **描述**：使用者按头部清单做依赖预检时会漏装 `f_dbpool`；版本号不一致则让「本文档对应哪个产物」无法判断（`1.3.2021` 本身也像是 `1.3.6` 之类的笔误）。
- **建议**：以 `cjpm.toml` 为准刷新头部；`f_dbpool` 补进清单；顺便确认 `1.3.2021` 是否是预期的版本号。

### [轻微][存量] #11 `doc/优化方案.md` 的「待修复」与用例计数已过期

- **位置**：`f_orm/doc/优化方案.md:46-49`（`[P4] SchemaFinder.cj 残留注释块 … SchemaFinder.cj:21-38 … 待修复`）、`61-63` / `74-78`（`migro_test.cj (12 测试用例)`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期」（行号 / 结论漂移）
- **证据**：静态确定 —— `f_orm/src/migro/SchemaFinder.cj:20` 起直接是 `public interface SchemaFinder {`，21-38 行是接口方法声明，**没有**被注释的字段块，该「待修复」项已不存在；`f_orm/src/migro/migro_test.cj` 现有 15 个 `@TestCase`，不是 12 个。
- **描述**：审计文档的剩余待办里混着一条已完成项，会让下一轮审查重复排查；用例计数偏差会让「覆盖是否减少」无法判断。
- **建议**：删掉 `SchemaFinder.cj:21-38` 那条（或标「已随 xx 清理」），用例计数改成当前值；行号引用统一改成「符号名」而非行号，避免每次重构后失效。

## 范围外提示

- **`SqlExecutor.readOnly` 粘滞**：`f_orm/src/base/SqlExecutor.cj:85` 置 `true` 后，`close()`（`153-174`）与 `clearSql()`（`97-105`）都不复位（全文件只有 `47` / `85` / `109` 三处触碰该字段）。同一 executor 实例内「先 select 后 update」，`beforeCommit(readOnly)`（`1048` / `1071` / `1087`）仍是 `true`。属 `base/SqlExecutor.cj`（其他部分），本部分只把 README 的相反描述记成 #2。
- **同类夹具泄漏还有 10 处**：`ArgInSql_test.cj:57`、`QueryResultIterator_test.cj:39/136`、`SqlExecutorArgBranches_test.cj:58`、`SqlExecutorStatement_test.cj:71`、`SqlPartialColumnKey_test.cj:94`、`SqlResultCacheStream_test.cj:47/58`、`SqlResultCache_test.cj:44/88` 都是「设了 `MOCKDB.execution` 不还原」，与 #1 同源，建议一次性加 fixture 作用域 helper。
- **`f_orm/README.md` 同样缺** `orm_connectingTimeout` / `orm_databasePoolMaxWaiting`，也写着同样的 `isReadOnly` / 敏感信息章节（与 #2 / #3 / #4 同源，中文版归对应部分）。

## 优化可行性方案

**本部分 0 条。** 理由：本部分没有任何生产侧可优化代码（`ORM.cj` 只有一行 `public import`；`EmbedSensitive.cj` 是编译期宏，循环上界 = 驱动数，编译期开销可忽略；其余两个文件是测试）。唯一有数据的候选——`SqlPartial.UPDATE` 的 `HashMap<String,Any>` 中转——已由同模块 spec 记录并**决策不做**（`f_orm/doc/spec/test-f-orm-update-column-keys/design.md:9-15`：mock 下每次 UPDATE 16,763 B、中间映射 1,542 B ≈ 9%；local 化被 `Any` 的 local 限定阻断；替代方案会改掉「重复键 last-wins」与「缺键抛 `values[idColumn]` 异常」语义），故不重复提议，只列入下方假设等待真实链路数据。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | UPDATE 的中间映射 1,542 B/次（9%）在真实 DB I/O 下可忽略；若真实链路占比明显更高，才值得动 `SqlPartial.UPDATE` 的结构 | `f_orm/src/base/SqlPartial.cj:123-142` | 真实驱动下单次 UPDATE 的分配总量与 `HashMap` 占比 | 接真实 pgsql/mysql 跑 1 万次三列 UPDATE，`getAllocatedHeapSize()` 前后差 + `cjprof heap` 看 `HashMap` 分配占比 |
| 2 | #1 的夹具泄漏在「新增一个只执行 SQL、不设夹具」的用例后确实会显形（当前无受害用例，属潜伏） | `f_orm/src/base/ArgBindCount_test.cj:41` | 追加临时用例后的实际行为 | 在 `ArgBindCount_test` 之后追加一个只跑 `select` 的临时用例（不设 `MOCKDB.execution`），断言结果集列数/行数是否被改成 1 列 1 行；再删掉临时用例 |
| 3 | #8 的计时断言在本仓 CI 上的翻红概率 | `f_orm/src/base/ArgAnyBinding_test.cj:103` | 失败率与 `anyNs` 分布 | CI 上重复 200 次，记录 `anyNs`/`typed` 的 P50/P99 与超阈值次数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/README_en.md` | .md | ✅ | 2417 行逐节读完（1-600 / 601-1200 / 1201-1800 / 1801-2417）；见 #2（`isReadOnly`）、#3（§18 敏感信息）、#4（缺两个配置键）、#9（UPDATE 示例注释）、#10（头部元信息）。其余核对通过的断言：§5.5 `close()` 顺序（对 `SqlExecutor.cj:153-174`）、§13 类型名表（对 `QueryResultWrap.cj:59-80`）、§19.4 `DirtyTag` 可见性（对 `DirtyTag.cj:34/50/59/66/72/75`）、§4 `deregisterAndReplaceDefault` 语义（对 `ORM.cj:166-169`）、§5「同一 executor 不许并发执行」文案（对 `SqlExecutor.cj:965`）均一致 |
| 2 | `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/design.md` | .md | ✅ | 与现状一致：`makeReader` 只剩 `Sql*` 抽象名 + 仓颉类型名，方言拼写已删（`QueryResultWrap.cj:60-79`），未知名走 `String` 兜底（`78`）；决策 5「不依赖 f_dbd」与 `cjpm.toml:1-17` 一致 |
| 3 | `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/proposal.md` | .md | ✅ | 同上；所述 6 处契约外拼写已不在 `QueryResultWrap_test.cj`（检索 `bytea`/`money`/`int4`/`float8` 为 0 命中） |
| 4 | `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/specs/orm-result-type-mapping/spec.md` | .md | ✅ | 两个 Scenario 的映射逐条比对 `QueryResultWrap.cj:61-77`，全部命中（含 `SqlInterval`→`Duration`、`Array<UInt8>`→`Array<Byte>`、`std.math.numeric.Decimal`）；未识别拼写走 `String` 兜底的 Requirement 与 `78` 一致 |
| 5 | `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/tasks.md` | .md | ✅ | 记录的 RED/GREEN 与现状自洽：`testSqlSpellingTypeNamesAreTreatedAsUnknown` 存在于 `QueryResultWrap_test.cj:138` |
| 6 | `f_orm/doc/spec/test-f-orm-update-column-keys/design.md` | .md | ✅ | 与现状一致：`SqlPartialColumnKey_test.cj` 5 个 `@TestCase`、实体 `OrmUpdateProbe`；16,763 B / 1,542 B / 120 B 三个数是该文档自报数据，本轮未复测（已进假设 1） |
| 7 | `f_orm/doc/spec/test-f-orm-update-column-keys/proposal.md` | .md | ✅ | 与 design 一致；「不改生产代码」成立（本部分读到的 `SqlPartial.cj:123-190` 仍是字符串键中转形态） |
| 8 | `f_orm/doc/spec/test-f-orm-update-column-keys/specs/orm-update-binding/spec.md` | .md | ✅ | 两个 Requirement 与 `SqlPartial.cj:123-190` 一致：Column 键先 `values2[k.name] = v` 再转字符串键重载（`140-142`、`181-187`） |
| 9 | `f_orm/doc/spec/test-f-orm-update-column-keys/tasks.md` | .md | ✅ | 任务项与产物对得上（测试文件、`docs/LocalMode.md:325` 的 f_orm 行含「local 化被 Any 的 local 限定阻断」） |
| 10 | `f_orm/doc/优化方案.md` | .md | ✅ | 见 #11（`SchemaFinder.cj:21-38` 注释块已不存在、用例计数 12→15）；其余 P0-P3 修复结论与 `mysql`/`mariadb` 两个 `@Bean` 的 `driverName`（`MysqlSchema.cj:166-179`）相符 |
| 11 | `f_orm/src/ORM.cj` | .cj | ✅ | 18 行门面：仅 `package` + `public import fountain::f_orm.base.*`，无声明；与 README §1「模块入口」描述一致。无死代码/空实现（无函数体） |
| 12 | `f_orm/src/ProtectedMacros/EmbedSensitive.cj` | .cj | ✅ | 见 #3（嵌入的键集合与 README 相反）、#5（5 个未使用 import）；宏体 `28-42` 逻辑本身正确：全局 3 键 + 每驱动 3 前缀键，交给 `@EmbedSensitive` 按「编译期值非空」过滤 |
| 13 | `f_orm/src/base/ArgAnyBinding_test.cj` | .cj | ✅ | 见 #5（未使用 `ArrayList`）、#6（类型覆盖不全）、#7（未验证绑定）、#8（计时断言）；`@Assert(expected, actual)` 用法已核对（`cangjie-doc/md/doc/cj_unittest.md:13-14`：两参为「期望/实际，不等即失败」，故 `103` 行是有效断言而非空断言） |
| 14 | `f_orm/src/base/ArgBindCount_test.cj` | .cj | ✅ | 见 #1（夹具不还原）；「按字节数 `?`」的计数实现（`43-48`）与 `f_mockdb` 的先例一致，断言（`71`）有效 |

合计：`.cj` 4 个 / `.md` 10 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #2（`readOnly` 文档相反且实现粘滞）、#9（示例 WHERE 列错）、#1（夹具顺序依赖）；设计：本部分无分层/依赖问题（`ORM.cj` 只做再导出）；语言特性 #6 / #7（用 `Any` 分派 + `ArgAnyBinding` 的可观测性受 `private args` 限制）；可读性 #5 / #11；安全性 #3（凭据来源与 SM4 强度描述） |
| §1 死代码 | 1 | 逐个符号过了一遍：本部分 4 个 `.cj` 里**没有任何** `private` / `internal` / `protected` 成员声明（唯一的 `protected` 是 `EmbedSensitive.cj:16` 的包声明；`ORM.cj` 只有一条 `public import`；`EmbedSensitive.cj` 是一个 `public macro` + 一条 `public import`；两个用例类的成员都被 `@TestCase` 引用），因此「非 public 符号无调用者」类 0 命中；`public` 侧：`ORMEmbedSensitive` 是宏（对外/对内扩展点，`base/imports.cj:38` 有调用），测试类与 `@TestCase` 由框架调用，均不判。唯一命中是 6 个未使用 `import`（#5）。另核对：`EmbedSensitive.cj:26` 的 `public import ...EmbedSensitive` 的 `public` 在 `protected macro package` 内实际不可跨模块引用，但其导入本身被 `42` 行使用，只作信息，不单列 |
| §2 重复逻辑 | 0 | 同文件两两比对：`ArgAnyBinding_test` 两个用例无同语义（一个验分支存在性、一个验分派成本）；`ArgBindCount_test` 与 `ArgAnyBinding_test` 的不变量不同（占位符=绑定数 vs 返回 `?`），不算重复。跨文件：两处「按字节数 `?`」的计数（`ArgBindCount_test.cj:43-48`）与本仓 `f_mockdb` 的先例同形，属测试辅助，按 §2 误报边界不计。文档层：事务回调顺序表在 §5.4（`550-560`）与 §14.4（`1786-1794`）各有一份，`14.4` 显式指向 `5.4` 且少了 `rollbackFor` 命中行，属有意摘要，不判重复（若将来改一处忘另一处，风险已在 #3 那类文档问题里体现） |
| §3 空实现 | 0 | 逐处核对：`ORM.cj` 无函数体（纯再导出）；`ORMEmbedSensitive` 的宏体非空且有实际产出（`29-42`）；两个用例的 `@TestCase` 全有断言（`@Assert` 双参语义已查文档确认）；无 `TODO` / `FIXME` / `UnsupportedException` / `catch { }` / 空 `case _ => ()`。`MOCKDB.execution` 的缺省 `EMPTY_EXECUTION`（`mockdb.cj:38-40`）是「没有夹具」的 Null Object，有注释说明，不判 |
| §4 栈溢出 | 0 | 无递归：宏体只有一层 `for`（`35-41`），用例无递归、无自引用结构、无深度拷贝；`quote` / `@EmbedSensitive` 的展开深度由驱动数决定（配置常量级） |
| §5 OOM | 0 | 编译期：`keys` 只随 `orm_drivers` 条目数线性增长（每驱动 3 个 token），无用户可控长度；运行期：本部分无容器、无 `readToEnd`、无按报文长度预分配。用例侧 `ArgAnyBinding_test:92-100` 每次 `arg` 会往 `SqlArgs` 追加 1000 个参数，但只活在一个用例内且随后 `close()`，不构成模块级 OOM 风险 |
| §6.1 热点瓶颈 | 0 | 未提供任何 `cjprof` / `cjpm bench` 数据；本部分唯一与耗时相关的是 `ArgAnyBinding_test` 的自计时用例，其阈值稳定性进假设 3，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁：宏在编译期单线程执行，用例无 `synchronized` / `Mutex` |
| §6.3 并发串行 | 0 | 无 `spawn`、无并发度配置、无单消费者队列 |
| §6.4 低效算法 | 0 | 宏里 `keys += quote(...)` 是编译期字符串拼接，O(驱动数²) 但规模是配置级（≤ 数个驱动），不构成运行时成本；用例的两个 1000 次循环是 O(n) |
| §7 降堆内存方案 | 0 | 见「优化可行性方案」：本部分无生产侧分配热点；唯一有数据的候选已被 spec 决策否决 |
| §8 降 CPU 方案 | 0 | 同上；`arg(Any)` 的分派顺序与成本属 `base/RootDAO.cj`（其他部分），本部分只用例护栏 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内用完」的大对象；模块内唯一候选（`SqlPartial.UPDATE` 的中间 `HashMap`）已在 `doc/spec/test-f-orm-update-column-keys/design.md:9-15,30-38` 用探针证明被 `Any` 的 local 限定阻断（1,542 B→120 B 可达但真实代码编译不过），结论为不可行，无需重复评估 |
| §11 现有代码的 BUG（存量） | 11 | 11 条全部为存量（快照无 diff）：代码/测试侧 #1、#5、#6、#7、#8；文档侧 #2、#3、#4、#9、#10、#11。另逐项核对了本轮读到的边界与空值：`ArgBindCount_test` 的 `problems[0]` 取值前有 `size > 0` 守卫（`66-70`）、`ArgAnyBinding_test` 的 `finally { ex.close() }`（`78-80`、`104-106`）、宏的 `for(d in getDriverNames())` 空集合退化（只嵌全局键，与 `ORMConfig` 的取值回退一致），均无缺陷 |
| §12 并发安全与锁粒度 | 1 | #1：`MOCKDB.execution` 是进程级 `AtomicOptionReference` 单例（`f_mockdb/src/mockdb.cj:57`），用例写后不还原 ⇒ 同进程后续用例会读到别人的夹具（顺序依赖；当前无实际受害用例，属潜伏）。本部分无锁，故锁粒度 0 命中；宏的编译期执行也无线程共享面。已核对：两个用例都在 `try/finally` 里 `close()` executor，没有连接泄漏 |
| §14 功能完备性与 README 覆盖 | 2 | #4（两个公开配置键 + 两个 getter 完全无文档，已点名 `orm_connectingTimeout` / `orm_databasePoolMaxWaiting` / `getConnectingTimeout` / `getPoolMaxWaiting`）、#3（§14.0 的承诺其实成立，§18 却断言运行期不读，同一份文档自相矛盾）。其余 public 符号抽查（`ORM` 静态 API、`SqlDSL`、`Pagination`、`SqlDialect`、`QueryMapper` 家族、`DirtyTag`）在 README 中均有登记 |
| 文件覆盖（§13 等） | 14/14 | 无缺文件；10 个 `.md` 全部逐节对照实现（#2/#3/#4/#9/#10/#11 为命中项，其余章节一致） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分是全模块里「最薄」的一片：一个 18 行的门面、一个编译期敏感信息宏、两条参数绑定护栏用例，外加 10 个 `.md`。因此**没有**执行器生命周期、连接/事务、锁粒度层面的实现可供审查——这些风险在 `base/SqlExecutor.cj`、`wrap/*` 等其他部分；本部分的实际产出是「把文档当作契约去核对」，而问题恰好集中在文档：

- 最值得先改的是 **#2 与 #3**：README 关于 `isReadOnly` 与敏感信息的两段说明都与代码相反（前者把「select 后置 true」说成「恒 false」，后者把「`sensitiveMap` 兜底」说成「运行期不读」），前者还会掩盖一个真实的行为缺陷——`readOnly` 置 true 后永不复位，写事务会被当作只读事务交给 `beforeCommit`（该缺陷在 `base/SqlExecutor.cj`，属其他部分，本报告只作范围外提示）。文档口径不改，下一轮审查还会被同一段误导。
- **#4** 是纯覆盖缺口但影响运维：两个「保护性上限」（连接卡在 `Connecting` 的 5s、池耗尽的 30s）是线上卡死时唯一的旋钮，两版 README 都查不到。
- **#1** 是测试卫生里的潜伏项：`MOCKDB.execution` 是进程级单例且 `clear()` 明确不重置它，`clearExecution()` 又是包内可见，`f_orm` 用例只能覆盖不能还原。当前每个真正执行 SQL 的用例都自己重设夹具，所以还没翻红；但「下一个忘了设夹具的用例静默继承别人的结果集」这类失败极难定位，且同模块还有 10 处同样写法，建议一次改成「夹具作用域」。
- **#5-#8** 是宏与用例的清扫项（未使用 import、护栏只覆盖 16/20 标量分支与 2/20 `?T`、只验占位符不验绑定、计时断言可能抖动）；#9-#11 是文档细节（示例注释、版本/依赖头、审计文档过期）。这 7 条都不影响运行，随下次触碰顺手改即可。
- 明确**没有**命中的维度：死代码（本部分无 `private`/`internal`/`protected` 声明，唯一命中是未使用 import）、重复逻辑（两处测试辅助按误报边界不计）、空实现、栈溢出、OOM、锁与并发串行、local mode（唯一候选已被同模块 spec 用探针否决）。
- 两个 spec 目录（`fix-orm-queryresultwrap-type-alias`、`test-f-orm-update-column-keys`）与当前实现逐条自洽，未发现规格漂移；`优化方案.md` 只有一处已完成项未打勾（#11）。

存量缺陷共 11 条（严重 0 / 一般 3 / 轻微 8），是否纳入修复待用户决定；本报告只读代码，未做任何修改。
