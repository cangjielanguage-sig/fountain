# f_orm 模块审查报告（第 1/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（全模块 111 个源文件；**本部分覆盖 15 个**：`ORM` / `ProtectedMacros/EmbedSensitive` / `base/ArgAnyBinding_test` / `base/ArgBindCount_test` / `base/ArgInSql_test` / `base/ArgSqlText_test` / `base/ChooseCondition` / `base/ColumnInfo_test` / `base/Columns` / `base/CondRelOp` / `base/Condition` / `base/ConditionTrim_test` / `base/Connection_test` / `base/DAO_test` / `base/Datasource_test`）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，HEAD `8c0ce643a`，工作区干净；快照模式无 diff，本部分发现全部记为「存量」）
- **审查重点**：ORM 条件 / 列 / 连接抽象的正确性、SQL 注入面、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（部分报告，待主 Agent 合并为 `docs/review/f_orm_review_20261128.md`）
- **说明**：本文件统计**只含第 1/8 部分**的 15 个文件，不含 f_orm 其余 96 个文件；合并时勿与本部分数字直接相加覆盖。本部分不含 `.md`（模块 README / `doc/**` 由其它部分与合并阶段覆盖）；为取证本次读过 `f_orm/README.md` §10.1 / §11.1-11.5 / §14.0 与 `f_config/README.md` §6。

## 发现

### [严重][存量] `Columns.tableAlias_` 挂在生成的进程级单例上：一次设别名永久污染该 PO 的所有后续查询，且并发写无同步

- **位置**：`f_orm/src/base/Columns.cj:28-32`（`protected var tableAlias_` + `public func tableAlias`）、`:23-27`（同一单例上的私有 `executor`）；共享实例的来源见 `f_orm/src/macros/QueryMappersGenerator.cj:486-494`（`static let instance` + `private init()`）、`:182-184`（`tableColumns()` 直接返回 `.instance`）、`:471`（`toString()` 在渲染时读 `super.tableAlias_`）
- **来源**：存量（`git blame -L 28,32 -- f_orm/src/base/Columns.cj` → `889fe61fe1` 2026-09-12；`git blame -L 486,494 -- f_orm/src/macros/QueryMappersGenerator.cj` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）、§11（契约与实现不符）、§2（跨层复制的可变状态）
- **证据**：静态确定 —— 每个 `@QueryMappersGenerator` 生成的列集合类都是 `static let instance = X__cOlUmns___()` 且 `private init()`，`static func tableColumns()` 只返回这一个实例；`Columns.tableAlias(alias)` 是它唯一的写入入口，全类无任何复位逻辑（`tableAlias_` 初值 `''`，只有 `= alias` 赋值）。渲染期 `toString()` 读的是 `super.tableAlias_` 的**当时值**。
- **描述**：`T.tableColumns().tableAlias('u')`（README §10.1 明确推荐的用法）把别名写进该 PO 的全局单例，此后**所有** `select ... from T` 的列都会带 `u.` 前缀，即使调用方从未要求别名；由于 `u` 没在该语句的 FROM/JOIN 里声明，渲染出的 SQL 直接报「unknown table alias」——一次设置，此后该表的普通查询全部失败。没有任何 API 能清除该别名（`tableAlias('')` 虽可调用但无文档、无调用点）。同时两个线程用不同别名调用即为同一个 `String` 字段的并发写 / 读，无锁无原子，仓颉不保证该场景的可见性与原子性（同一请求内也可能读到另一个线程刚写的别名，渲染出不属于本语句的前缀）。
- **影响面**：仓内 `git grep 'tableAlias('` 只有生成器一处调用（下游使用者才会触发），因此当前无线上表现；但这是 public 契约（README §10.1 第 1094 行）自身不可用。
- **建议**：`tableAlias` 不应改单例状态。两条路：(1) 让 `tableColumns()` 每次返回 `X__cOlUmns___()` 新实例（去掉 `private init` / 单例），别名随实例生命周期结束；(2) 保留单例但把别名改为**参数**传入渲染（`toString(alias: String)`），由调用方在本次 SQL 构造内持有。无论哪条，都要在 README §10.1 删掉“别名设置必须在取用列之前完成”这类隐含全局状态的说明，并补一条并发用例（两个线程各设不同别名，断言互不影响）。

### [一般][存量] `ChooseCondition` 的“无值 / 只有片段”分支不可用：默认分支留下 `?` 绑定空串（`WHERE ?` 静默空结果），显式 `otherwise` 则抛 `SqlException`

- **位置**：`f_orm/src/base/ChooseCondition.cj:22`（`emptyPartial = {=> ('', '')}`）、`:24`（`_otherwise` 初值）、`:80-106`（`gen(partial)` 的三条 `else`）、`:91-94`（有片段 / 非 argInSql：无条件 `executor.add(arg)`）、`:102-105`（空片段 / 非 argInSql：同样无条件 add）、`:107-112`（无命中走 `otherwise`）；下游 `SqlExecutor.add(arg: Any)` 在 `f_orm/src/base/SqlExecutor.cj:859-865`
- **来源**：存量（`git blame -L 90,105` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（边界 / 空值未处理、契约与实现不符）、§3（静默产出无效语句）、§13（README 示例与实现相反）
- **证据**：静态确定 —— ①未调用 `otherwise()` 时 `_otherwise` 是 `('', '')`：`frag` 为空、`arg` 为 `''`，走 `:102-105` ⇒ 语句里多一个 `?` 并绑定空串，`Condition.WHERE{}` 包出来就是 `WHERE ?`；②`otherwise(partial: () -> String)` / `partial(partial: () -> String)` 经 `callee`（`:57-59`）包成 `(frag, ())`，`frag` 非空时走 `:91-94` 的 `executor.add(())` ⇒ `add(Any)` 的 match 里 `Unit` 既不是 `ToString` 也不是 `InputStream`，抛 `SqlException('Unsupported data type')`（`Unit` 不支持 `ToString`，见官方文档 `docs/dev-guide/source_zh_cn/basic_data_type/unit.md:5`；仓内也无 `extend Unit <: ToString`）。
- **描述**：README §11.3 的主示例 `:1265-1271` 正是 `.otherwise { ('1 = 1', ()) }`（未开 `argInSql`）——按上面第 ② 条，一旦所有 `condition` 都不命中就会抛 `SqlException`；而 README §11.5 表格 `:1310` 写的是“不配 `argInSql` 会为该片段留下一个多余的 `?`”，与实现（抛异常）也不一致。第 ① 条更隐蔽：`WHERE ?` 在多数数据库里按布尔求值（空串为假），结果集为空且不报错，属静默错误结果。测试只覆盖了 `argInSql` 打开的情况（`ArgInSql_test.cj:159-183` 的 ⑤），这两条默认路径零覆盖。
- **建议**：把“值”改成 `?Any`，`None` 表示“只有片段、不绑定”，`Some(())` 直接拒绝；`gen` 里仅当 `arg.isSome()` 才 `add` + 出 `?`，`frag` 为空且无值时应产出空串（而不是 `? `）。同时修正 README §11.3 示例与 §11.5 表格，并补 3 条用例：无 `otherwise`、`otherwise` 只给片段、`otherwise` 给 `()`。

### [一般][存量] `Column.toString()` 依赖 ThreadLocal 当前执行器，脱离执行上下文即抛 `NoneValueException`（ToString 契约不符）

- **位置**：`f_orm/src/base/Columns.cj:102-106`（`private prop executor` → `SqlExecutor.getCurrent()`）、`:120-143`（`toString` 首行 `let exe = executor`）
- **来源**：存量（blame `1ee1e0ec49` 2026-10-01）
- **判据**：review-checklist §11（契约与实现不符）、§10（仓颉语言特性 / 隐式上下文依赖）
- **证据**：静态确定 —— `SqlExecutor.getCurrent()`（`f_orm/src/base/SqlExecutor.cj:133-135`）实现为 `current.get().getOrThrow()`，`current` 是 `ThreadLocal<SqlExecutor>`，只在 `getInstance()`（`:113-132`）里被 `set`。因此 `Column('id').toString()` / `'${col}'` 在没先取过执行器的线程上必然抛 `NoneValueException`（不是 `ORMException`，错误信息也看不出原因）。
- **描述**：`Column` 是 `ToString` 的公开类型（README §10.1），却被实现成“必须先有 ORM 执行上下文才能打印”。任何把 SQL 片段拼装挪到执行器之外（日志、单测、异步线程、缓存预热、`println(col)`）的用法都会崩；`toString` 在错误类型上也与 ORM 自己的异常体系不一致，调用方无法按 `ORMException` 捕获。
- **建议**：`toString` 只在确实需要引用符时才取执行器；取不到时退化为“原样输出标识符 + 一次性 `warn` 日志”，或把方言作为显式参数（`toString(dialect: SqlDialect)`），保留一个不带方言的 `toString()` 走默认方言。至少在 `getCurrent()` 的 `None` 分支抛 `ORMException('column toString requires an active SqlExecutor')` 让错误可诊断。

### [一般][存量] 标识符引用可被“以引用符开头”绕过，别名 / 列名无任何校验（注入面）

- **位置**：`f_orm/src/base/Columns.cj:114-118`（`Column.tableAlias`）、`:28-32`（`Columns.tableAlias`）、`:100-101`（`public Column(let name: String)`）；引用实现（范围外，取证用）`f_orm/src/base/Dialect.cj:44-52`
- **来源**：存量（blame `889fe61fe1` / `1ee1e0ec49`）
- **判据**：review-checklist §10（安全性 / 注入）、§11（外部输入未校验）
- **证据**：静态确定 —— `involvedIdentifier` 的第一条分支是 `if(identifier.startsWith(startInvolver)){ return identifier }`，即“看起来已经加过引用符”的输入原样返回；后续分支也只是用引用符包裹，**不转义输入内部的引用符**（MySQL 下 `` ` ``，PostgreSQL 下 `"`）。`Columns.tableAlias` / `Column.tableAlias` / `Column(name)` 均不校验字符集。因此 `` col.tableAlias("` ; drop table t; --") `` 在 MySQL 方言下直接拼进 SQL。
- **描述**：`Column` / `Columns` 是本模块把外部字符串送进标识符引用的主要入口，且是公开 API。仓内 `git grep 'tableAlias('` 只有生成器 `QueryMappersGenerator.cj:471`（实参是 `super.tableAlias_`，源头仍是调用方传给 `Columns.tableAlias` 的字符串）；**是否可被利用取决于下游是否把用户输入当列名 / 别名**——这一点无法从本仓取证（标 `待确认`）。同一模式还导致“列名里含 `.`”被拆成两段引用（`Dialect.cj:47-48`），跨 schema 与含点列名无法区分。
- **建议**：`involvedIdentifier` 改成“遇到引用符一律转义（`` ` `` → ` `` `、`"` → `""`）后整体包裹”，删除 `startsWith` 短路分支；`tableAlias` / `Column(name)` 增加白名单校验（`[A-Za-z_][A-Za-z0-9_]*`，或显式 `RawIdentifier` 类型）并在 README §10.1 写明“标识符必须来自代码常量，不得传用户输入”。

### [一般][存量] `@ORMEmbedSensitive` 的“各驱动前缀变体”依赖**编译期** `orm_drivers`，未配置时这些键不登记，日志脱敏静默失效；README §14.0 未声明

- **位置**：`f_orm/src/ProtectedMacros/EmbedSensitive.cj:35-41`（`for(d in ORMConfig.getDriverNames())`）、`:29-33`（固定三项）；配置来源 `f_orm/src/wrap/ORMConfig.cj:144-146`（`Config.getString(drivers)?.split(',') ?? []`）、`:160-162`
- **来源**：存量（`git blame -L 28,42 -- f_orm/src/ProtectedMacros/EmbedSensitive.cj` → `f2846c10ed` 2026-10-02 文件迁位；`for(d in ...getDriverNames())` 一行可追到 `f792151167` 2026-09-23）
- **判据**：review-checklist §13（文档承诺与实现不符）、§14.1（承诺了但只做了一半）；`fountain-baseline` §6（日志中不得出现凭据）
- **证据**：静态确定（代码路径）+ 待确认（编译机是否提供配置）—— 宏体在**宏展开期**执行，`getDriverNames()` 读的是编译期 `Config.getString('orm_drivers')`；返回空数组时 `keys` 只有 `orm_connectionUrl` / `orm_option_username` / `orm_option_password` 三项。而运行期真正取值走 `getConf(driverName, key)` = `"<driver>_orm_option_password"`（`ORMConfig.cj:93-95`、`:134-140`）。一旦编译期没配 `orm_drivers`（或配置只在部署环境提供），`<driver>_orm_option_password` 这类键**不在脱敏表里**，值原样出现在日志 / 配置导出中。README §14.0（`README.md:1552-1554`）只写“以及各驱动的前缀变体”，未提“需编译期配置”。
- **描述**：脱敏是安全兜底，失效是静默的（无日志、无异常）。另外 `split(',')` 不 trim，`orm_drivers = "mysql, pgsql"` 会产出带前导空格的键名（`getConf` 用同样的原始串，两边“碰巧”都带空格才一致；宏侧 `quote` 会把空格当分隔符吃掉），属于同一处的边界问题。
- **建议**：宏里对 `d` 做 `trimAscii()` 并跳过空项；README §14.0 补一句“驱动变体键取决于**编译期**的 `orm_drivers`，编译环境须与运行环境一致，否则这些键不会被登记为敏感项”；若无法保证，改为运行期按 `orm_drivers` 动态 `registerSensitive`（代价是脱敏表不再编译期固化）。

### [轻微][存量] `Column.toString()` 的互斥错误文案写错，且 `'*'` 分支静默忽略 alias / sort

- **位置**：`f_orm/src/base/Columns.cj:121-123`（文案）、`:125-131`（`'*'` 分支）
- **来源**：存量（blame `1ee1e0ec49`）
- **判据**：review-checklist §11（语义与命名 / 注释不符）、§10（可读性）
- **证据**：静态确定 —— 条件是 `alias_.size > 0 && sort.size > 0`，消息却是 `'column alias and column alias cannot be set at the same time'`（应为 alias 与 ASC/DESC）；README `:1093` 原样抄了这条错误消息，两边一起错。`name == '*'` 时直接返回 ` * ` / ` <表别名>.* `，`alias_`、`sort` 都不参与，调用方拿到的是“没报错但设置丢了”。
- **建议**：文案改为 `column alias and sort order cannot be set at the same time`（README 同步）；`'*'` 分支遇到 `alias_`/`sort` 时补一条显式异常或 `warn`，不要静默丢弃。

### [轻微][存量] `Condition.delimiter` 在 `finally` 里复位为 `''` 而非恢复旧值：嵌套 `SET`/`WHERE` 会吞掉外层的连接词

- **位置**：`f_orm/src/base/Condition.cj:40-52`（`SET`）、`:54-69`（`WHERE`），复位点 `:49-51` / `:66-68`
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11（边界 / 重入）、§12.1（共享可变状态）
- **证据**：静态确定 —— `delimiter` 是 `ThreadLocal<String>`（`:22-30`），`SET`/`WHERE` 先 `set` 再在 `finally` 无条件 `= ''`；嵌套调用时内层结束后外层拿不回 `'and'` / `','`，此后 `meet(...).done()` 不再补连接词，片段直接相连。仓内没有嵌套 `SET{}`/`WHERE{}` 的写法（`git grep` 只有 `RootDAO.cj:545-551` 的单层入口），因此当前无已知触发路径（影响面 `待确认`）。
- **建议**：进入时保存旧值、`finally` 恢复旧值（`let prev = delimiter; try { ... } finally { delimiter = prev }`），或改成显式参数传递（把 delimiter 传给 `MeetCondition` 而不是读全局）。补一条嵌套用例。

### [轻微][存量] `Condition.trim` 把 `prefix`/`suffix` 当正则片段拼接：传 `(`、`*` 等字符直接抛异常，契约未声明

- **位置**：`f_orm/src/base/Condition.cj:70-82`（动态分支 `:79`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11（参数校验缺失）、§10（契约与实现不符）
- **证据**：静态确定 —— `'^\\s*(${prefix})\\s*|\\s*(${suffix})\\s*$'.regex(flags: [IgnoreCase])`：`prefix = '('` 得到 `(()`，括号不配对，`Regex` 构造失败；`prefix = '*'` 得到 `(*)`（nothing to repeat）同样失败。README §11.1 `:1199` 只写“用正则裁掉片段首尾”，未说明参数是**正则表达式片段**而非字面量。
- **建议**：README 明确“prefix/suffix 是正则片段，由调用方负责转义”；或把签名拆成 `trimLiteral(prefix:suffix:)`（内部 `Regex.escape`）与 `trimPattern(...)`，让最常见用法不会因 `(` 崩。

### [轻微][存量] §2 重复逻辑：`Condition.SET` / `WHERE`、`Condition.trim` / `TableClause.appendPartial`、`ChooseCondition.done` / `MeetCondition.done` 三组同语义实现

- **位置**：`f_orm/src/base/Condition.cj:40-52` 与 `:54-69`；`f_orm/src/base/Condition.cj:33-35/70-82` 与 `f_orm/src/base/TableClause.cj:20-21/44-62`；`f_orm/src/base/ChooseCondition.cj:76-116` 与 `f_orm/src/base/MeetCondition.cj:122-136`
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 字面量复制 / 近似重复）
- **证据**：静态确定 ——
  1. `SET` 与 `WHERE` 的函数体逐行对齐，只差“分隔符来源、裁剪用的 prefix/suffix、外层关键字”三个点，`try/finally` 与空串早退完全一致；
  2. 裁剪 `and|or` 与 `,` 的正则被写了两份且**模式文本不同**：`Condition` 是 `^\s*(and|or)\s*|\s*(and|or)\s*$`（替换成 `' '`），`TableClause` 是 `^(\s*and|or\s*)|(\s*and|or\s*)$`（替换成 `''`）——分组位置不同，边界输入（如 `" or and "`）结果不同，属“近似重复 + 行为漂移”；
  3. `done()` 的值分派（`ToString` 内联 / `add` + `?`）在 `ChooseCondition` 与 `MeetCondition` 各写一份，已经漂移成“一处抛异常、一处绑空串”（见本部分「一般」第 2 条）。
- **建议**：把 1 抽成 `private static func wrap(keyword, delimiter, prefixPattern, suffixPattern, partial)`；把 2 收敛到 `Condition` 的预编译常量并让 `TableClause.appendPartial` 复用（替换串作为参数）；把 3 抽成 `arg 渲染` 的一个私有函数（`render(arg: ?Any, argInSql: Bool): String`），让三处共用同一套分支，避免再漂移。

### [轻微][存量] §1 死代码：`Columns.executor`、`EmbedSensitive.cj` 四个未用 import、`DAO_test.cj` 整文件注释

- **位置**：`f_orm/src/base/Columns.cj:23-27`；`f_orm/src/ProtectedMacros/EmbedSensitive.cj:18-24`；`f_orm/src/base/DAO_test.cj:18-110`
- **来源**：存量
- **判据**：review-checklist §1（private 无引用 / 未使用 import / 兼容残留）
- **证据**：静态确定 ——
  - `Columns.executor` 是 `private prop`，同文件只在 `Column`（`:102-106`）另有一份同名私有属性被 `:124` 使用；`Columns` 那份在本文件零引用，private 也无法被生成代码访问 ⇒ 死代码；
  - `EmbedSensitive.cj` 全文 42 行只用到 `std.ast.*`（`Tokens`/`quote`）、`fountain::f_config.*`（`EmbedSensitive`）、`fountain::f_orm.wrap.ORMConfig`；`std.database.sql.SqlOption`、`stdx.crypto.crypto.*`、`fountain::f_macros.*`、`fountain::f_base.UnsafeBytes` 零出现（对照 `QueryMappersGenerator.cj` 确实需要 `f_macros`，可排除“宏隐式依赖”误判）；
  - `DAO_test.cj` 从第 18 行到文件尾全部是 `//` 注释（含 `TestService` / `TestDAO` / `User` 的旧实现），无任何可执行声明，等于一个空文件；同目录已有 `ORM_test.cj` 等真实用例。
- **建议**：删除 `Columns.executor`、四个未用 import、`DAO_test.cj` 整个文件（或把仍有价值的旧用例迁进现有测试类）。这些都不涉及对外契约。

### [轻微][存量] 测试质量：用 `DateTime.now()` 做性能断言语义不稳、执行器不关闭、`MOCKDB.execution` 全局钩子不恢复、测试替身无注释地空实现

- **位置**：`f_orm/src/base/ArgAnyBinding_test.cj:83-107`（计时断言 `:91-103`）；`f_orm/src/base/ArgBindCount_test.cj:36-72`（无 `ex.close()`，`:41-54` 设全局钩子）；`f_orm/src/base/ArgInSql_test.cj:54-68`（`run` 无 close，`:57-63` 设全局钩子）；`f_orm/src/base/Connection_test.cj:35-38`（`close()` 空、`isClosed()` 恒 false）；`f_orm/src/base/Datasource_test.cj:22-27`（`setOption`/`close` 空）
- **来源**：存量（`ArgAnyBinding_test.cj:83-107` → `d488431810` 2026-10-06；`ArgBindCount_test.cj:36-72` → `4f1a463c76` 2026-10-06；`ArgInSql_test.cj:54-68` 同批新增用例）
- **判据**：review-checklist §11（资源不对称）、§6.1（无基线的性能断言不可作为判据）、§12.1（测试间共享可变状态）
- **证据**：静态确定 + 需实测 —— ①`@Assert(true, anyNs <= typed * 10 + 1000)` 以 Wall clock 单轮 1000 次为分母，`typed` 若被计时器分辨率截断为 0，阈值只剩 1µs；CI 抖动即可假失败（要证明稳定性需多轮 P99 数据）；②`ArgAnyBindingTest` 在 `finally` 里 `ex.close()`，而 `ArgBindCountTest` / `ArgInSql_test` 不关，同一测试进程里 `SqlExecutor.currents` 会留下未释放的连接（`SqlExecutor.getInstance` 的 ThreadLocal 缓存）；③`MOCKDB.execution` 是**进程级** `AtomicOptionReference`（`f_mockdb/src/mockdb.cj:57`，`clear()` 明确“不动 execution”，`:71-90`），两个用例都只设不复位，而复位入口 `clearExecution()` 是包内可见（`:92-95`）——f_orm 的用例无法恢复默认夹具，后续用例若依赖 `EMPTY_EXECUTION` 会读到上一个用例的行 / 列信息；④`ConnectionTest.close()` / `DatasourceTest.setOption()` 是空实现、`isClosed()` 恒 `false`，类上与该函数上都没有一句“这是 Null Object”的说明，若将来有用例断言关闭语义，替身会静默让断言恒真。
- **建议**：性能护栏移出单元测试（或改成 `Assert` 10× 的宽松上界并只打日志）；所有用例统一 `finally { ex.close() }`；给 `f_mockdb` 补一个 public 的 `resetExecution()`（或在 `clear()` 里一并复位）供跨包用例使用，并在每个用例末尾复位；给两个测试替身补类注释，明确“`close()` 是 no-op、`isClosed()` 恒 false，不模拟真实连接状态”。

### [轻微][存量] `Datasource_test.cj` 的注释是 PDF 拷贝残留（含“版权所有，禁止扩散”），与文件头 Apache-2.0 声明冲突

- **位置**：`f_orm/src/base/Datasource_test.cj:29-36`
- **来源**：存量（`git blame -L 29,36 -- f_orm/src/base/Datasource_test.cj` 落在 `4be871f2fd` 2026-10-02 的行重排 / LF 统一提交，再往前的历史行不可追；内容形态是更早遗留）
- **判据**：review-checklist §10（可读性 / 可维护性）、§13（文档与代码一致性）；`fountain-baseline` §3（文件头与许可）
- **证据**：静态确定 —— 注释原文为“返 回 一 个 可 用 的 连 接 … （续下页） 567 版权所有，禁止扩散 （接上页）”，逐字带排版断行与页码，是从受版权保护的 PDF 粘贴而来；文件头却是 Apache-2.0。功能上该注释对 `connect()` 无任何补充信息。
- **建议**：删除该段，改写为一句自述（“测试替身：每次返回一个新的 ConnectionTest”）。顺带确认仓内没有其他同类残留（本次 15 个文件里只此一处）。

## 优化可行性方案

### [CPU] `Column.toString()` 每次渲染重复查方言表

- **现状**：`Columns.cj:124` 取一次 ThreadLocal 执行器；每次 `involve`（`:127/132/134/136/138/140/142`）都走 `SqlExecutor.dialect`（`SqlPartial.cj:93-100`）→ `SqlDialectMediator.getDialect`（`Dialect.cj:175-182`，`ConcurrentHashMap` 查询），而 `involvedIdentifier` 内部还要再读两次 `startInvolver` / `endInvolver`（`Dialect.cj:161/166`，各自再查一次表）。一张 20 列表的 SELECT 列表 + ORDER BY 约 60+ 次 map 查找，且每次渲染都重来。
- **方案**：在 `SqlExecutor` 上把 `dialect` 结果缓存为字段（driverName 在实例生命周期内不变，`SqlExecutor` 本身就是每线程每驱动一个），或在 `TableClause`/一次 SQL 渲染内传入 `SqlDialect`，让 `Column.toString(dialect:)` 复用。
- **预期**：省掉每次标识符渲染的 3 次并发 map 查找；端到端收益取决于 SQL 渲染在请求中的占比（未测）。
- **代价**：`Column.toString()` 需增加带方言的重载；`dialect` 缓存要保证驱动切换时失效（`ORM.deregister` 场景）。
- **验证**：`cjpm bench -O2`，固定 20 列表、100 万次渲染，对比中位数；`cjprof record` 看 `getDialect` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `Column.toString()` 用字符串插值拼 3~4 段，每列产生多个中间 `String`

- **现状**：`Columns.cj:127-142` 每个分支都是一次 `' ${...}.${...} AS ${...} '` 插值，`involve` 每次又新建一个 `String`（`Dialect.cj:48-50` 的插值）；一次 20 列的排序 / 选择列表会产生 60~80 个短生命周期 `String`。
- **方案**：渲染侧改用一个 `StringGenerator`（或 `StringBuilder`）顺序 `append`，`involvedIdentifier` 增加“写入 builder”的重载，避免中间串。
- **预期**：单次渲染分配的对象数从 ~4n 降到 ~n（n = 列数）；峰值与 GC 压力下降，未测。
- **代价**：`toString` 的返回类型不变，`involve` 需要新增重载；代码可读性略降。
- **验证**：`getAllocatedHeapSize()` 前后对照，跑 10 万次 20 列渲染，比较分配量中位数与 GC 次数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 方言表查找是 SQL 渲染的主要 CPU 开销之一 | `Columns.cj:124-142`、`Dialect.cj:175-182` | `getDialect` 自耗时占比、每请求渲染次数 | `cjprof record` 跑 20 列表 × 10 万次渲染，看 self time 与调用次数 |
| 2 | 每列多次 `String` 插值是渲染路径的分配热点 | `Columns.cj:127-142`、`Dialect.cj:48-50` | 每请求分配字节数 / 对象数 | 计数埋点 + `getAllocatedHeapSize()`，对比 StringGenerator 版本 |
| 3 | `Condition.trim` 的自定义组合每次编译正则在业务侧有调用 | `Condition.cj:79` | 自定义 prefix/suffix 的调用频次 | 全仓 `git grep 'Condition.trim'` 只有测试与 `SET/WHERE`（内部走预编译常量）；需下游调用方数据，当前**不构成热点** |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/ORM.cj` | .cj | ✅ | 仅 `public import fountain::f_orm.base.*`，无逻辑；版权头合规 |
| 2 | `f_orm/src/ProtectedMacros/EmbedSensitive.cj` | .cj | ✅ | 死 import + 编译期配置依赖，见「一般」第 4 条 / 「轻微」第 5 条 |
| 3 | `f_orm/src/base/ArgAnyBinding_test.cj` | .cj | ✅ | 计时断言不稳，见「轻微」第 6 条 |
| 4 | `f_orm/src/base/ArgBindCount_test.cj` | .cj | ✅ | 占位符/绑定数护栏有效；不关执行器 + 全局钩子，见「轻微」第 6 条 |
| 5 | `f_orm/src/base/ArgInSql_test.cj` | .cj | ✅ | 5 组用例覆盖 `argInSql` 分派；缺非 `argInSql` 的 Unit 分支（「一般」第 2 条的取证依据） |
| 6 | `f_orm/src/base/ArgSqlText_test.cj` | .cj | ✅ | 逐字节钉住批量拼接文本，设计合理；无缺陷 |
| 7 | `f_orm/src/base/ChooseCondition.cj` | .cj | ✅ | 见「一般」第 2 条、「轻微」第 4 条 |
| 8 | `f_orm/src/base/ColumnInfo_test.cj` | .cj | ✅ | 测试替身（`displaySize`/`length` 恒 8、`nullable` 恒 false），无注释说明取值依据；仅作观察，不单列缺陷 |
| 9 | `f_orm/src/base/Columns.cj` | .cj | ✅ | 见「严重」1、「一般」3/4、「轻微」1/5 |
| 10 | `f_orm/src/base/CondRelOp.cj` | .cj | ✅ | 3 值枚举 + 小写 `toString`，与 README §10.2 一致；无缺陷 |
| 11 | `f_orm/src/base/Condition.cj` | .cj | ✅ | 见「轻微」2/3/4 |
| 12 | `f_orm/src/base/ConditionTrim_test.cj` | .cj | ✅ | 期望值取自修复前实测，输出契约钉得清楚；无缺陷 |
| 13 | `f_orm/src/base/Connection_test.cj` | .cj | ✅ | 测试替身：`close()` 空、`isClosed()` 恒 false，无注释；见「轻微」第 6 条 |
| 14 | `f_orm/src/base/DAO_test.cj` | .cj | ✅ | 整文件注释，见「轻微」第 5 条 |
| 15 | `f_orm/src/base/Datasource_test.cj` | .cj | ✅ | PDF 注释残留，见「轻微」第 7 条 |

合计：`.cj` 15 个 / `.md` 0 个（本部分不含 `.md`；取证读过 `f_orm/README.md`、`f_config/README.md` 相关小节，不计入本表），共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 3（ChooseCondition 值分派、`delimiter` 重入、`Column.toString` 上下文依赖）；设计 3（单例上的可变 `tableAlias_`、`Column` 的三重重载歧义、互斥检查延迟到渲染期）；语言特性 2（`ToString` 实现依赖 ThreadLocal、`Unit` 不满足 `ToString` 导致 `add` 抛错）；可读性 2（错误文案、PDF 注释残留）；安全性 1（标识符引用绕过；`argInSql` 的注入面属 bug-orm ORM-C5 已判定的设计决定，不重复计缺陷） |
| §1 死代码 | 3 | 已逐符号机械过：`private`（`Columns.executor`、`Condition._delimiter`/`TRIM_*`、`Column.executor`/`tableAlias_`、`ChooseCondition.callee`/`emptyPartial`）全仓搜；`internal`（`Condition.delimiter`）在本包及子包搜；extend 内的辅助入口（`SqlExecutor.involve`）按仓内引用搜（`Columns.cj` / `SqlFunc` 多处调用）；`protected`（`Columns.tableAlias_`、`SqlExpr.alias_`/`sort`）按“public 非 sealed 类的扩展点”豁免。命中：`Columns.executor`（零引用）、`EmbedSensitive.cj` 4 个未用 import、`DAO_test.cj` 整文件注释。`Column`/`Columns`/`CondRelOp`/`QueryMappersObject`/`Condition.*`/`ChooseCondition` 均为对外可达 public（或经宏生成调用），按硬原则一不判死代码，仅记“仓内无直接调用” |
| §2 重复逻辑 | 3 | 已把 15 个文件的函数体按「输入-输出-副作用」两两比对：`Condition.SET` vs `WHERE`（3 处差异）、`Condition.trim` vs `TableClause.appendPartial`（正则文本+替换串不同）、`ChooseCondition.done` vs `MeetCondition.done`（已漂移）。其余：`ChooseCondition.callee` 两个重载是类型适配不是同语义；`Column.tableAlias` 与 `Columns.tableAlias` 分属“单列 / 列集合”，语义不同，不判重复；测试代码里的准备逻辑按误报边界排除 |
| §3 空实现 | 1 | 命中 2 个测试替身（`Connection_test.cj:35-38` 的 `close()` 空 + `isClosed()` 恒 false、`Datasource_test.cj:22-27` 的 `setOption`/`close` 空），均无注释说明“为何可以空”——它们是有意的 Null Object，按清单只算“缺注释”，已并入「轻微」第 6 条，不单列缺陷。`DatasourceTest` 的 `connect()`/`getMetaData()` 有实现，非空；`ORM.cj` 无函数体可空 |
| §4 栈溢出 | 0 | 本部分无递归：`ChooseCondition.done` 的两个嵌套函数是重载互调（`gen()` → `gen(partial)`），不构成自递归；`Condition`/`Column` 无对象图遍历；无 `clone`/`deepCopy` |
| §5 OOM | 0 | 无全量物化、无按不可信长度预分配；`ChooseCondition.conditions` 与 `Columns` 的列集合规模由代码常量决定；`executor.partials` 属每线程执行器生命周期（`TableClause.condition` 进出即 `clear`），本部分不构成无界增长 |
| §6.1 热点瓶颈 | 0 | `scope.md`「已有性能资料」为空，未提供 profile / bench；所有性能线索（方言表查找、`String` 插值、自定义 trim 正则）已降级进「待验证假设」与优化方案，不作发现 |
| §6.2 大粒度锁 | 0 | 本部分 15 个文件不含任何 `synchronized` / `Mutex` / 锁；`ThreadLocal` 只用于分隔符与当前执行器，不构成临界区 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无任务提交；`Columns` 的问题是共享可变状态（归 §12.1），不是并发度问题 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `contains`/`indexOf` 热点、无 `remove(at: 0)`；`ChooseCondition.done` 对分支列表单遍扫描（分支数由代码常量决定）；`Condition.trim` 的正则次数固定为 2 次替换 |
| §7 降堆内存方案 | 1 | `Column.toString` 的多次插值中间串（无基线，标待验证）；`Condition` 的三条预编译正则已是既有优化，无进一步收益证据 |
| §8 降 CPU 方案 | 1 | `Column.toString` 每次重复查方言表（无基线，标待验证）；`Regex` 预编译改造已落地（`ConditionTrim_test` 钉住输出），不再重复建议 |
| §9 local mode 可行性 | 0 | 本部分无“函数内创建、函数内销毁且不逃逸”的大对象：`Column.toString` 的中间串、`ChooseCondition.done` 的片段都作为 SQL 文本逃逸到 `SqlExecutor`；`Unit`/`String` 为不可变基础类型，无 mode 重载可用。缺峰值内存数据，不列方案 |
| §11 现有代码的 BUG（存量） | 12 | 严重 1（单例上的可变别名）、一般 4（ChooseCondition 值分派、`toString` 上下文依赖、标识符引用绕过、脱敏宏编译期依赖）、轻微 7（错误文案/`'*'` 静默、`delimiter` 重入、`trim` 正则契约、3 组重复逻辑、3 处死代码、测试质量、PDF 注释）。全部标 `[存量]`，默认只报不修 |
| §12 并发安全与锁粒度 | 1 | 共享点逐个核对：`Columns.tableAlias_`（生成单例，跨线程读写无同步——命中，见严重项）；`Condition.delimiter`（`ThreadLocal`，线程封闭，仅重入问题）；`SqlExecutor.current`/`currents`（`ThreadLocal`，线程封闭）；`ChooseCondition`/`MeetCondition`（每次构造、只持有本线程执行器，无线程共享）；`Column` 由生成器每次 new（`QueryMappersGenerator.cj:465-469`），不共享。**锁粒度**：本部分无锁，无需判 |
| §14 功能完备性与 README 覆盖 | 0 | 已把本部分 public 声明逐项对照 README：`Columns`/`Column`/`SqlExpr`/`CondRelOp`/`QueryMappersObject`（§10.1-10.2）、`Condition`/`MeetCondition`/`ChooseCondition`/`LoopCondition`（§11.1-11.5）、`ORMEmbedSensitive`（§14.0）均有条目；无“承诺未实现”。缺口是**内容与实现不符**（已计入 §13），不是缺条目 |
| 文件覆盖（含 §13） | 15/15 | 本部分 15 个文件全部读完（逐文件结论见表）；`.md` 不在本部分清单内，模块 README 由其它部分覆盖；§13 的对照证据取自 `f_orm/README.md` 与 `f_config/README.md` |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

> 本部分存量缺陷合计 12 条（含轻微），默认只报不修；是否纳入修复清单请用户在门禁决定。统计只含 15 个文件，不含 f_orm 其余 96 个文件。

## 总评

本部分是 f_orm 的“SQL 条件 / 列抽象 + 宏 + 测试夹具”，代码量不大但处在 ORM 的公共契约面上，风险集中在三处：

1. **`Columns.tableAlias_` 挂在生成的进程级单例上**（严重）：别名一旦设置不可撤销，会污染该 PO 的所有后续 SQL，并且是两个线程之间的无同步读写。这是本部分唯一的阻塞项，改法明确（去单例或把别名改成参数），但涉及宏生成代码，需与 `QueryMappersGenerator` 一起改。
2. **`ChooseCondition` 的“无值 / 只有片段”分支不可用**（一般）：默认分支留下 `WHERE ?` 会静默返回空集，显式 `otherwise` 只给片段则抛 `SqlException`；而 README §11.3 的主示例正是这种写法、§11.5 的描述与实现相反。当前测试只覆盖了 `argInSql` 打开的那一半，建议先补 3 条默认路径用例再改实现。
3. **`Column.toString()` 依赖 ThreadLocal 执行器**（一般）：ToString 在无 ORM 上下文的线程上必抛 `NoneValueException`，且不是 `ORMException`；同一处的标识符引用还存在“以引用符开头即原样返回”的绕过，属对外 API 的注入面（是否可被利用取决于下游是否传外部输入，标 `待确认`）。

其余问题按后果排序：`@ORMEmbedSensitive` 的驱动变体键依赖编译期 `orm_drivers`，未配置时敏感值不脱敏且无任何提示，属安全兜底静默失效，建议先补文档再评估是否改成运行期注册；`delimiter` 重入、`trim` 的正则契约、错误文案与 `'*'` 静默丢弃是可读性 / 可诊断性问题，改起来都是一两行。死代码与重复逻辑命中具体但便宜：`Columns.executor`、4 个未用 import、整个 `DAO_test.cj`、以及三组同语义实现（其中 `and|or` 裁剪已有两份正则、文本不同），建议与上面的语义修正一并清理，避免下一次修复又在两份实现里改一处漏一处。

正面评价：`Condition` 的预编译正则、`ArgSqlText_test` 的逐字节文本护栏、`ArgBindCount_test` 的“占位符数 == 绑定数”不变量设计都很扎实，说明这批代码是有意在做“改动不漂移”的工程化；`argInSql` 的注入面也已在 README §11.5 与测试里显式声明为设计决定（bug-orm ORM-C5），本报告不重复判缺陷。本部分没有锁、没有 I/O 主路径，`§6/§9` 无结论；性能只有两条“看起来能省”的线索，均无基线，已按要求放进待验证假设，不进修复清单。
