# f_orm 模块审查报告

> **模块第 7/8 部分**（本报告只覆盖 `files/f_orm.part7.txt` 列出的 20 个文件，全部为 `.cj`：`src/migro/` 6 个 + `src/orm_test/` 2 个 + `src/wrap/` 12 个。`README.md` / `README_en.md` / `doc/**` 与其余 91 个 `.cj` 由第 1–6、8 部分产出；本部分编号独立，合并时以主 Agent 为准。README 仅作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（本部分 20 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，`git status` 只有未跟踪的报告目录，无源码 diff 可比 ⇒ 全部问题记「存量」，blame 依据见各条）
- **审查重点**：executor 生命周期与线程内复用语义、连接与事务、SQL 注入与参数绑定、大粒度锁、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 7/8 部分）

## 发现

### [严重][存量] #1 迁移命令的入口 `groupBy` 恒返回空 map —— `dbmigro` 一条 SQL 都不生成，且退出码为成功

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:29-30`（`TableMetas.tableMetas().groupBy{m => m.driver}`）；下游 `33-53`、`60-75`、`79-101` 全部以它为输入
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02，早于本轮快照）
- **判据**：review-checklist §11「错误处理缺失或静默 / 失败路径当成功」、§14「承诺了但没实现」
- **证据**：静态确定 —— 被调用的 `groupBy` 是 `f_base/src/ExtendIterator.cj:108-119` 的扩展实现，循环体只有一次 `m.get(k)`（读），`if`/`else` 两个分支返回的 `ArrayList<T>` 被 `.add(t)` 后即丢弃，**全程没有任何 `m[k] =` / `m.add`**，因此从 `HashMap<K, ArrayList<T>>()` 建好到 `118` 行 `m` 返回，map 始终为空。`std` 的 `Iterator` 没有 `groupBy`（标准库文档全量检索无 `func groupBy`），所以解析到的一定是这个坏扩展。
- **描述**：`generate(cmdargs)` 的全部输出都来自 `metasByDriver.iterator().flatMap{...}`（`30-58`）与 `metasByDriver.iterator().flatMap{...}`（`60-75`）。`metasByDriver` 恒为 `HashMap()` ⇒ 两个 `flatMap` 都不迭代 ⇒ `allSqls` 恒为空 ⇒ 四种模式（`file` / `auto` / `dry` / `interactive`）全部**什么都不做**：不打印、不写 `./migro.sql`、不执行；`MigroCommand.exec` 返回 `0`（`src/migro/SubCommand.cj:30-33`）。用户看到的是"迁移成功、无变更"，实际是彻底空转。同一根因还有两个连带后果（根因文件属 `f_base`，由该模块报告覆盖，这里只确认调用点）：
  1. `SchemaFinderMediator.cj:45-46` 的 `finder.findIndexes(...)` → `MysqlSchema.cj:88` 内的 `groupBy{po => po.name}` 同样恒空 ⇒ 库里的索引永远"查不到"，`generateIndexSql` 会把所有已存在的索引当成"缺失"再 `add` 一次（`alter table ... add index` 对已存在索引必然报错，然后被 #3 吞掉）。
  2. 孤儿表清理（`60-75`，正是 `doc/优化方案.md` 记录的"P1 generateDropTableSql 从未被调用"的修复）随 `metasByDriver` 一起失效，等于该修复被回退。
- **建议**：修 `ExtendIterator.groupBy`（写入 map），并在 `SchemaFinderMediator` 侧加一条自检：`metasByDriver` 为空但 `TableMetas` 非空时抛 `ORMException`（"no table meta grouped by driver"），不要"空输入 → 静默成功"。补一条用例：注册 2 个驱动各 1 张表，断言 `generate` 至少产出 2 条 `create/alter` SQL；目前 `migro_test.cj` 只测 `SchemaFinder` 的 DDL 生成（不经 `generate`），所以这条断链没有任何用例覆盖。

### [严重][存量] #2 `use <db>;` 与后续 DDL 不在同一会话执行 —— 修好 #1 后多库场景的建表/删表会落到连接的默认库

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:103-113`（`for` 循环内每条语句 `try(exe = ORM.executor(driver))`）与 `47-49`（每条驱动只插一条 `['use ${m.database};']`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「语义与注释/契约不符」、§12.1「跨线程资源 / 会话状态」
- **证据**：静态确定 —— `execute` 把 `try (exe = ORM.executor(driver))` **放在 `for` 循环体内**，每条 SQL 进出一次作用域；`SqlExecutor.close()`（`f_orm/src/base/SqlExecutor.cj:141-160`）会 `current.set(None)`、`currents.get()?.remove(driverName)`、`close()` 连接并把 `_connection_` 换成 `NoneConnection.instance`。下一条语句的 `ORM.executor(driver)` 因此**重新 `getConnection`**，拿到池里另一条物理连接。`USE db` 是会话级状态，换连接即丢失；`m.database` 与连接串默认库不同时（`@DatabaseSchema[database: ...]` 正是为这种场景准备的），`create table users(...)` / `drop table t;` 这些**不带库名前缀**的语句会落到默认库。
- **描述**：`'use ${m.database};'` 是本模块唯一表达"目标库"的手段，而它的作用域被逐语句关闭 executor 的行为抹平。两个附加事实：① PostgreSQL 没有 `USE` 语句，这一行对 `postgres` / `opengauss` 驱动本身就是语法错误（被 #3 吞掉后继续）；② 每条语句新建并关闭一次 executor ⇒ N 条语句 = N 次建连/归还，迁移期间连接数抖动。当前被 #1 掩盖（`allSqls` 恒空），修好 #1 后立刻生效。
- **建议**：`execute` 把 `ORM.executor(driver)` 提到按驱动分组的外层（每个驱动一个 executor / 一次会话，语句间不关闭），或在 SQL 文本里直接拼库名（`${database}.${table}`）；`use` 语句只对支持它的方言生成（放进 `SchemaFinder` 的方言能力里，而不是在 mediator 里硬编码）。连接复用要顺带核对 README `README.md:545` 的 `close()` 语义（事务中不关闭、提交后由 `finishTransaction` 收尾），别在事务里提前关。

### [一般][存量] #3 迁移语句失败被就地吞掉，命令恒返回 0 —— 部分应用的 DDL 与"成功"无法区分

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:107-111`（`try { exe.setSql(sql).update } catch(e: Exception) { e.printStackTrace() }`）；退出码在 `f_orm/src/migro/SubCommand.cj:30-33`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §3「静默吞异常」、§11「错误处理缺失」
- **证据**：静态确定 —— `catch` 只 `printStackTrace()`，不计数、不抛出、不改变返回值；`generate` 返回 `Unit`，`MigroCommand.exec` 无条件 `0`。
- **描述**：DDL 逐条独立执行（见 #2），任一条失败后**后续语句继续**，最终库处于"改了一半"的状态，但进程退出码为 0。`auto` 模式（无人值守）下 CI / 发布脚本无法感知失败；配合 #1 的"0 条 SQL"场景，"什么都没做"与"全部成功"完全同形。
- **建议**：`execute` 返回失败条数（或收集 `(sql, exception)`），`generate` 在有失败时抛 `ORMException`（带第一条失败 SQL 与计数），`MigroCommand.exec` 返回非 0；`auto` 模式建议整体放进一个事务（MySQL DDL 隐式提交，需按方言说明"不可回滚"）。

### [一般][存量] #4 表元数据里的 driver 没有对应 `SchemaFinder` 时抛 `NoneValueException`，且不带驱动名

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:34`、`62`（`let finder = finders[driver]`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「空值未处理」「错误处理缺失」
- **证据**：静态确定 —— `finders` 是 `ConcurrentHashMap<String, SchemaFinder>`，本 SDK 的 `operator func [](key: K): V` 在键不存在时抛 `NoneValueException`（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:1832-1852`），不是返回 `?V`。`finders` 只在 `init`（`24-27`）里用 `lookupList<SchemaFinder>()` 填充，仓内实现的 `driverName` 只有 `mysql` / `mariadb` / `postgres` / `opengauss`（`MysqlSchema.cj:165/173`、`PostgresSchema.cj:223/231`）。
- **描述**：`@DatabaseSchema[driver: ...]` 可以写任意驱动名（`mockdb`、`sqlite`、`dm`…）。这类表一旦进入 `TableMetas`，`generate` 直接抛 `NoneValueException`（栈里没有驱动名、没有表名），用户无法判断是"这个驱动不支持 DDL"还是"注册丢了"。`init` 里 `lookupList` 返回空（bean 未初始化）时也是同一现象。
- **建议**：改用 `finders.get(driver)`，`None` 时抛 `ORMException('no SchemaFinder registered for driver ${driver}; registered: ${...}')`；`init` 末尾对空 `finders` 打一条 warn。

### [一般][存量] #5 `-m` 是最后一个参数时 `cmdargs[i + 1]` 越界崩溃；同一循环只处理第一个 `-m`

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:79-80`（`for(i in 0 .. cmdargs.size where ...) { match(cmdargs[i + 1]) ... }`），`89-97`（interactive），`100`（`break`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「边界差一 / 越界」、§10「缺少边界校验」
- **证据**：静态确定 —— `i` 的取值域是 `0 .. cmdargs.size`，当 `-m`/`--mode` 位于末尾时 `i + 1 == cmdargs.size`，`Array` 下标越界抛 `IndexOutOfBoundsException`。循环体末尾的 `break` 又保证只认第一个 `-m`，`-m auto -m file` 静默丢弃后者。
- **描述**：`dbmigro -m` 这类少写一个参数的调用直接崩栈，报错与"参数缺失"无关；多写一个 `-m` 时不报错也不算。两种都是"用户输入未被校验"。
- **建议**：先 `if (i + 1 >= cmdargs.size) throw ORMException('--mode requires a value')`；收集全部 `-m` 后按"后者覆盖前者 或 重复即报错"明确一种语义（fountain 基线偏好"同名冲突直接失败"）。

### [一般][存量] #6 孤儿表清理阶段：视图未过滤、只覆盖 `metas[0].database`、无白名单/无确认

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:60-75`（`knownNames` 在 `63-66`，`metas[0].database` 在 `68`，`filter{!knownNames.contains(...)}` 在 `69`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02；`doc/优化方案.md:16-19` 记录该能力是本次新增）
- **判据**：review-checklist §11「契约与实现不符」、§5「无拒绝路径」、§10「安全性（数据破坏面）」
- **证据**：静态确定（代码形态）+ 待确认（方言事实）—— `listTables` 的实现是 `select table_name from information_schema.tables where table_schema = ?`（`MysqlSchema.cj:62-66`），**没有 `table_type = 'BASE TABLE'` 过滤**；MySQL 的 `information_schema.tables` 同时包含视图，视图会被 `generateDropTableSql` 生成 `drop table <view>` 并在 `auto` 模式执行（必然报错，再被 #3 吞掉）。`metas[0].database` 只取该驱动第一张表的库：同一驱动下声明了多个 `database` 时，其余库的孤儿表永远不会被列出，而生成的 `drop` 又不带库名前缀（见 #2），存在"在错的库里删同名表"的窗口。
- **描述**：`drop table` 的集合 = "库里所有未声明的表"，没有任何排除清单（视图、他人维护的表、临时表），`auto` 模式也没有确认步骤。这是设计选择（注释写明 "orphaned tables"），但对共享库/生产库是数据破坏面；对多库 + 视图则确定是错的。
- **建议**：`listTables` 增加 `table_type = 'BASE TABLE'`；按 `database` 分组生成（而不是 `metas[0]`）；`drop` 之前要求显式开关（如 `--allow-drop`）或至少把 `drop` 语句单独成段、`auto` 模式下默认不执行。

### [一般][存量] #7 `makeReader` 与 `toMap()` 是两张 typeName 表，同名类型结论不一致（`SqlByte` → `Int8` vs `UInt8`）

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:66`（`case 'SqlByte' | 'Int8' => getOrNull<Int8>`）与 `1013`（`case 'SqlByte' | 'Byte' | 'UInt8' => get<UInt8>`）；另一处口径差在 `60-79`（`makeReader` 无任何 `SqlNullable*` 分支，未知名落 `String` 兜底，`78`）与 `1002-1029`（`toMap` 逐个处理 `SqlNullable*`）
- **来源**：存量（`git blame`：`66` 为 `83e7547f7` 2026-10-05，`1013` 同文件历史更早；两表并行存在）
- **判据**：review-checklist §2「字面量复制 / 只改类型名」、§13（同文件内对同一 typeName 的两处结论不同）
- **证据**：静态确定 —— 同一列 `typeName = 'SqlByte'`，走 `get<Int8>()` 得到有符号值，走 `toMap()` 得到无符号值（-1 → `Int8(-1)` vs `UInt8(255)`）。`SqlNullable*` 只在 `toMap` 里被识别，`makeReader` 一律走 `getOrNull<String>`，于是"nullable 数字列"实际是靠 `convertFromString` 二次解析救回来的（见 #13），"nullable bool / blob / clob" 则救不回来（`convertFromString` 没有 Bool，Blob 走 `?String` 分支必然抛）。
- **描述**：`doc/spec/fix-orm-queryresultwrap-type-alias/design.md:77` 已把"两张表未来可能再次漂移"记为已知结构性风险，本次审查确认漂移已经发生（`SqlByte`）。本仓三个驱动上报仓颉类型名（同文档 `design.md:12`），所以 `Sql*` 名字只有第三方驱动才会出现——影响面因此是"接第三方驱动时行为不一致"，而不是全量错。
- **建议**：合并成一张 `typeName -> (getter, 是否可空)` 表，`makeReader` 与 `toMap` 共用；先行补 `SqlNullable*` 到 `makeReader`（或把两处的未知名兜底都改成显式报错），并用 `QueryResultWrap_test.testEveryReaderBranchAndAlias` 之外再加一条"同一 typeName 经 get 与 toMap 结果一致"的用例。

### [一般][存量] #8 配置解析失败的处理策略不统一：声明"退回默认值"，实际 6 个 getter 直接抛异常

- **位置**：`f_orm/src/wrap/ORMConfig.cj:129`（`Bool.parse(x)`）、`338`、`347`、`357`、`366`、`372`、`378`（`Int64.parse` / `Int32.parse`）；对照 `184-192` 的 `get<T>`（用 `T.tryParse` 退回 `default`）与 `178-183` 的注释承诺
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「契约与注释不符」、§10「错误处理」
- **证据**：静态确定 —— `parse` 解析失败抛异常、`tryParse` 返回 `None`（`stdlib/doc/libs/std/convert/convert_package_api/convert_package_interfaces.md:758-768`）。注释 `179-182` 明确写"配置里写错值不该让进程在读取时抛异常……非法值应按默认值处理"，`ORMConfigTest.testPoolMaxWaiting`（`ORMConfig_test.cj:41-42`）钉的也是这条。但 `getUseCache`（每个 `SqlExecutor` 构造都会调，`SqlExecutor.cj:62`）与 6 个 `getStdPool*`（`NamedDatasource.cj:67-84` 在 `useStdPool` 默认 true 时逐个调）用的是 `parse`。
- **描述**：`orm_useCache=yes` 会在**第一次执行 SQL** 时抛 `IllegalArgumentException`；`orm_stdPoolMaxSize=10x` 会在**构造数据源**时抛异常 ⇒ 启动失败。同一份配置文件，一半键非法会退回默认、另一半会炸，行为不可预期；错误信息也不含键名。
- **建议**：全部改成 `get<T>(...)`（`T <: Parsable<T>`）或 `tryParse` + 默认值；非法值时打 warn（含键名与原文）。`transactionIncluding/Excluding` 的 `Regex(reg)`（`74-79`）同理：非法正则目前会让 `static init` 直接抛，建议 try 住并 warn + 视为"不配置"。

### [轻微][存量] #9 `wrap/NoneConnection.cj` 与 `base/NoneConnection.cj` 逐行重复、全仓零引用

- **位置**：`f_orm/src/wrap/NoneConnection.cj:21-43`（对应 `f_orm/src/base/NoneConnection.cj:21-43`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02，与 base 那份同批存在）
- **判据**：review-checklist §1「非 public 顶层类型无引用 ⇒ 其 `public` 成员同样不可达」、§2「只改类型名/跨包复制」
- **证据**：静态确定 —— 全仓 `grep -rn NoneConnection --include=*.cj` 只命中 `f_orm/src/base/SqlExecutor.cj:117/119/126/171/329/411`，它们都在 `fountain::f_orm.base` 包内、解析到 base 那份；`src/wrap/` 内及任何其它包对 `fountain::f_orm.wrap.NoneConnection` 零引用。两份文件的类名、单例 `instance`、5 个成员逐行一致（后者只差 `package` 声明）。
- **描述**：该类没有访问修饰符 ⇒ 只在本包可见，属"包内放宽的 `public` 成员"，全项目无使用即死代码。风险不只是冗余：`SqlExecutor` 的 `_connection_ is NoneConnection` 绑定的是 base 类型，若本包内有人写 `NoneConnection.instance`（同名、同包），拿到的是另一个类型，`getInstance` 的"Closed → 重置连接"判断会静默失效。
- **建议**：删除 `src/wrap/NoneConnection.cj`；确需跨包引用就改成重导出（`public import fountain::f_orm.base.NoneConnection`），不要复制类。

### [轻微][存量] #10 4 处 `case _ where !driverName.isEmpty()` 回退分支恒等价（死分支）

- **位置**：`f_orm/src/wrap/ORMConfig.cj:130`（`getUseCache`）、`296`（`getTransactionLevel`）、`309`（`getTransactionAccessMode`）、`323`（`getTransactionDeferrableMode`）；依据 `getConf` 在 `134-140`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §1「恒真恒假分支 / 死分支」
- **证据**：静态确定 —— `getConf` 的语义是"驱动键有值就用驱动键，否则返回全局键"。因此它返回 `None` ⇒ 全局键也是 `None`；此时递归调用 `driverName = ''` 仍读同一个全局键，必然还是 `None`。两个分支同值，递归只多一次配置读取。
- **描述**：这 4 处读起来像"驱动级缺失时回退全局"，实际上回退已由 `getConf` 完成；留着会让后续维护者以为驱动级配置有独立的兜底链（`getUseCache` 的 `?Bool` 默认值另有 `?? true`，更容易看错）。
- **建议**：删掉 4 个分支，直接 `case _ => None<...>`；把"驱动优先、全局兜底"的说明集中写在 `getConf` 上。

### [轻微][存量] #11 `getOrNull` 的 18×18 转换矩阵与 `convertFromString` / `toMap` 是三份同语义实现

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:134-979`（矩阵）、`108-133`（字符串解析）、`997-1034`（`toMap`）
- **来源**：存量（`git blame`：`83e7547f7` 2026-10-05 起的逐类型展开）
- **判据**：review-checklist §2「只改类型名 / 换算复制」
- **证据**：静态确定 —— 矩阵按"源 `Option` 类型 × 目标类型"逐条展开，`?Int8 → ?Int16 => Int16(x)`、`?Int16 → ?Int8 => Int8(x)`……共 13×13 组、每组 5 行；规则只有"宽窄转换 + `None` 传播 + 不支持则抛"一条。
- **描述**：新增一种类型（`Float16` 只在字符串路径、`Bool` 两条路径都缺）要在三处同步；#7 的 `SqlByte` 漂移就是这么来的。~700 行同构代码也是审查与改动成本（任何一处改错都只在特定类型组合上暴露）。
- **建议**：抽"统一升到 `Int64`/`Float64`/`BigInt`/`Decimal` 再降"的一条转换链 + `None` 短路，`toMap` 复用同一张列类型表；必须用等价性用例锁住 `None` 传播与异常文案。与 #O4 是同一处改造。

### [轻微][存量] #12 interactive 模式执行后不退出循环，第二次输入 `y` 会重放全部 DDL

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:89-97`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「逻辑错误（控制流）」
- **证据**：静态确定 —— `while(let Some(r) <- getStdIn().read())` 的 `'y'` 分支只调 `execute(allSqls)`，没有 `break`；提示语在循环外只打一次，`'n'`/EOF 才退出。
- **描述**：用户按提示输入 `y` 后程序继续读下一行；再输入任何 `y` 会把全部 SQL（含 `drop table`、`alter table ... drop column`）再执行一遍，第二次必然报错并被 #3 吞掉。脚本化输入（`printf 'y\ny\n'`）可稳定复现。
- **建议**：`'y'` 分支执行完 `break`；`_` 分支重打提示或直接退出。

### [轻微][存量] #13 `convertFromString` 缺 `Bool`/`Rune` 分支，且用 `match(None<T>)` 当类型探针

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:108-133`（分支在 `111-128`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「语义与实现不符」、§10「语言特性（用值做类型探针）」
- **证据**：静态确定（分支缺失）+ 待确认（`?X` 目标是否命中）—— 分支表只有 Int8…UInt64、Float16/32/64、BigInt、Decimal、Duration、DateTime，没有 `Bool`、`Rune`；因此 typeName 未识别（落 `String` 兜底）而目标类型是 `Bool`/`Rune` 时，必然抛 `ORMException('String ${x} cannot be parsed to ...')`。目标类型靠 `match(None<T>)` 的 `_: ?X` 模式判定，而 `None<T>` 的静态类型是 `Option<T>`：`T` 为具体类型时命中，`T` 本身可空（`?Int32`）时是否命中取决于 `Option<Option<Int32>>` 与 `?Int32` 的类型测试语义，本轮未实测。
- **描述**：从签名看不出支持哪些目标类型，遗漏分支没有编译期提示（`Bool` 就是这么漏的）；字符串兜底是"未知 typeName"的唯一出路，这条路径上少两种类型就是少两种可用映射。
- **建议**：改用 `TypeInfo.of<T>()` 一次查表（与 #O4 合并），补齐 `Bool`（`true/false/1/0`）与 `Rune`；不支持时抛带列名与目标类型的 `ORMException`。

### [轻微][存量] #14 列名重复时 `columnInfoMap` 静默覆盖，按名取值与 `toMap` 只保留最后一列

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:51-53`（`columnInfoMap[columns[i].name] = i`）、`988-993`、`997-1032`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「边界/空集合未处理」
- **证据**：静态确定 —— 构造期按列名写 map，同名后写覆盖先写；`getOrNull<T>(columnName)` 与 `toMap()` 都以该 map 为唯一入口，`toMap` 的 `for ((column, index) in columnInfoMap)` 因此只产出 1 个条目。
- **描述**：`select a.id, b.id from ...`、`select 1 as x, 2 as x` 这类结果集里，按名取 `id` 静默拿到最后一列；`toMap()` 的条目数比 `columnInfos.size` 少。无异常、无日志。
- **建议**：重名时保留首个或直接抛 `ORMException`（与"同名注册直接失败"的项目偏好一致）；`toMap` 改为遍历 `columnInfos`。

### [轻微][存量] #15 事务切面正则用可变静态字段，跨线程写读无同步

- **位置**：`f_orm/src/wrap/ORMConfig.cj:69-70`、`72-81`、`259-262`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1「可见性」「共享可变状态无保护」
- **证据**：待确认 —— 写入点是 `static init()` 与 `Config.refresher` 注册的 `fn`（`ORMConfig.cj:82-85`），`fn` 由 `Config.set` 在**调用方线程**同步执行（`f_config/src/Config.cj:101-126`）；读取点是 `transactionable`（事务切面，可在任意请求线程）。字段是普通 `private static var`，无原子/无同步/无 `volatile` 语义；引用赋值不会撕裂，但可见性无保证。若配置只在启动期 `set`，实际影响≈0。
- **描述**：当前"启动期一次性写入"把问题掩盖了；一旦运行期 `Config.set` 改事务切面正则，其他线程可能长期读到旧 `Regex` 或 `None`——属于"写完立刻被看到"的可见性假设。
- **建议**：把两个正则合成一个不可变快照（`?Regex, ?Regex`）用原子引用整体替换；或读侧加一次 `synchronized`。

### [轻微][存量] #16 `AnnotatedQueryMappers_test.cj` 只有 SPDX 行，缺 Apache 2.0 版权头

- **位置**：`f_orm/src/orm_test/AnnotatedQueryMappers_test.cj:1-2`
- **来源**：存量（`git blame`：该文件创建时即如此）
- **判据**：fountain 基线 §3（每个 `.cj` 必须有 Apache 2.0 注释且在 `package` 之前）
- **证据**：静态确定 —— 第 1 行 `// SPDX-License-Identifier: Apache-2.0`，第 2 行即 `package fountain::f_orm.orm_test`；同目录 `ORM_test.cj:1-15` 与本部分其余 18 个文件都是完整的 15 行头。
- **描述**：许可证声明形式与全仓不一致；按行号提取头部的脚本会漏掉该文件。
- **建议**：替换成标准头（与 `ORM_test.cj:1-15` 一致）。

### [轻微][存量] #17 `getOrNull` 只校验上界，负索引直接落到 `list[index]`

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:94-97`（`if(columns.size <= index) return None`）、`134`（`match(list[index])`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「边界差一 / 越界」
- **证据**：静态确定 —— `index = -1` 时 `columns.size <= -1` 为假，`99` 的 `if (index >= list.size)` 也为假（不填充），随后 `list[-1]` 抛 `IndexOutOfBoundsException`，被 `980-983` 包成 `ORMException`，文案变成"colum index: -1 ... requires: ..."。
- **描述**：按列序号取值时传负数，拿到的是"列类型不匹配"式异常，定位成本高；而 `getOrNull` 的契约是越界返回 `None`。
- **建议**：`if (index < 0 || columns.size <= index) { return None<T> }`。

### [轻微][存量] #18 示例 DAO 在 SET 片段全空时生成 `update ... where ...`（缺 SET 子句）

- **位置**：`f_orm/src/orm_test/ORM_test.cj:32-48`（SET 在 `35-40`，WHERE 在 `41-46`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「边界/空集合未处理」、§10「可读性（示例会被照抄）」
- **证据**：静态确定 —— `Condition.SET`（`f_orm/src/base/Condition.cj:40-52`）在片段 trim 后为空时返回 `''`；该 DAO 的 SET 只有 `param.name`、`param.gender` 两个可选片段，两者都不满足时整条 SQL 变成 ``update `character` WHERE `id`=?``（`WHERE` 的 delimiter 为空串，`Condition.cj:54-57`），执行必报语法错误。WHERE 里 `${meet(..., '`name`=')}` 靠 `trim` 去掉悬空 `and`（`Condition.cj:66-84`）是安全的，说明 SET 侧本该有同样的保护。
- **描述**：这是 `_test.cj` 里的示例，但它示范了 `SET{}` + `meet()` 的标准写法；使用者照抄后"所有可选字段都为空"就是必现的语法错误。
- **建议**：示例里补一条"SET 为空则跳过执行"的守卫（或在 `SET` 侧明确要求调用方保证至少一个片段），并加一条对应用例。

### [轻微][存量] #19 `NamedDatasource` 对同一组 options 应用两次（`open(url, options)` 与 `setOptions`）

- **位置**：`f_orm/src/wrap/NamedDatasource.cj:59-60`（`driver.open(url, options)`）与 `107`（`setOptions(ds, options)`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §2「同语义副作用执行两遍」
- **证据**：静态确定 —— `newDatasource` 把 `options` 传给 `driver.open`，返回后无条件再逐项 `ds.setOption`；`setOptions` 在 `newDatasource` 内只被调用这一处。
- **描述**：对幂等 option 无害（多数驱动如此），但驱动若把 `setOption` 实现成"重建连接/只对新建连接生效"，第二次写入会与 `DatabasePool` 的预建连（`initSize`，`f_dbpool/src/DatabasePool.cj:62-72` 的 `creator`）交错——顺序不确定。更根本的是它掩盖了"以 `open` 的参数为准还是以 `setOption` 为准"这个问题。
- **建议**：二选一——`open(url)` 之后只 `setOptions`，或全部交给 `open` 并删掉 `setOptions`；在注释里写清选择理由。

### [轻微][存量] #20 `ORMConfigTest.testORMConfig` 用空 fn 覆盖全局 refresher —— 之后配置刷新不再重编事务切面正则

- **位置**：`f_orm/src/wrap/ORMConfig_test.cj:23-26`（`ORMConfig.refresh {}`）；机制在 `f_orm/src/wrap/ORMConfig.cj:82-85`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1「共享可变状态」、§11「测试污染既有全局状态」
- **证据**：静态确定 —— `refresh(fn)` 的实现是 `Config.refresher(confPrefix, fn); fn()`，即**用传入的 `fn` 覆盖** `REFRESHER['orm_']`（`f_config/src/Config.cj:101-103`）。`static init` 注册的是"重编两个 `Regex`"的闭包（`ORMConfig.cj:72-81`），测试传入的是 `{}`，之后 `Config.set` 触发的刷新永远只执行空闭包。
- **描述**：该用例只验证"`refresh` 不抛异常"，却把产品行为改掉了：同一进程内后续用例若依赖 `orm_transactionIncluding/Excluding` 生效（事务切面），看到的是 `static init` 当时的旧正则；运行期 `Config.set` 改了正则配置也不再生效。测试执行顺序不同 → 结果不同。
- **建议**：`refresh` 改成"注册即执行"且不覆盖既有回调（或提供 `refreshRegex()` 供测试）；用例改成断言"刷新后 `transactionable` 反映新正则"，而不是只调一次空 `refresh`。

## 优化可行性方案

### [堆内存] #O1 `getOrNull` 每个单元格都新构造一个 reader 闭包

- **现状**：`QueryResultWrap.cj:101` 对每个未读单元格调 `makeReader(result, columns[i].typeName)(i + indexStartsWith)`；`makeReader`（`59-80`）返回 `(Int64) -> Any`，捕获 `result` 的闭包每次都是新对象。一次 `n 行 × m 列` 的结果集最多 `n×m` 个闭包，存活到该单元格读完（其余部分随 `list` 一起被 `next()` 的 `clear()` 丢弃）。
- **方案**：给 `QueryResultWrap` 增加 `private var readers: Array<?(Int64) -> Any>`（构造期按列懒填：`readers[i]` 为 `None` 时才 `makeReader`），一个结果集内每列只构造一次。
- **预期**：闭包对象数从 `n×m` 降到 `m`（列数），即同一查询下降 `n` 倍；`n=10^4` 时约 10^4 倍对象数差。
- **代价**：多一个 `Array<?(Int64)->Any>` 成员（`m×8` 字节）；`makeReader` 仍需 static。
- **验证**：`cjpm bench -O2` 同输入（10k 行 × 20 列）对照 `getAllocatedHeapSize()` 与 `cjprof heap`；RSS 稳态对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] #O2 `getOrNull` 用 `ArrayList<Any>` 缓存整行（含装箱与"前置列连带读取"）

- **现状**：`QueryResultWrap.cj:26`、`99-105`：读到第 `i` 列时会把 `list.size..i` 的所有列都读出来塞进 `ArrayList<Any>`（每格一次 `Any` 装箱），`next()` 时 `clear()`。若只映射最后一列，前面所有列（包括 BLOB/CLOB 的 `InputStream`）都会被驱动取出并留在 `list` 里直到下一行——流不会被关闭。
- **方案**：只缓存"被请求过的列"（`HashMap<Int64, Any>` 或 `Array<?Any>` 按需填），不做前缀填充；`hadStream` 保持现有置位点。
- **预期**：每行装箱数从 `m` 降到"实际读取列数"；避免为未读列创建流对象（BLOB 列在前时尤其明显）。
- **代价**：`Array<?Any>` 需要判空；若某驱动的 `getOrNull` 依赖"按列顺序读取"（需核对三个驱动的实现），则不能跳过前置列——这是方案的前提，必须先确认。
- **验证**：`getAllocatedHeapSize()` 对照 + 句柄数（`/proc/<pid>/fd`）在"只读最后一列、前面 3 个 BLOB 列"场景下是否不增长。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] #O3 `ORMConfig` 每次 getter 调用都全量复制一遍配置表

- **现状**：`ORMConfig.cj:96-105` 的 `getAllConfigs` 每次 `Config.getAll('orm')` + 逐键 `replace` 构造新 `HashMap`；`getConf`/`get<T>` 每个键都走一次。`NamedDatasource.newDatasource`（`NamedDatasource.cj:89-103`）一次性调用 12 个池参数 getter，`useStdPool` 分支另有 6 个 `getStdPool*`（`67-84`），外加 `getNoPool` / `getUseStdPool`；`SqlExecutor` 每次构造还要 `getUseCache`。
- **方案**：`NamedDatasource`/`SqlExecutor` 侧一次 `getAllConfigs` 拿到快照后本地取键；或给 `ORMConfig` 加"按 driverName 缓存的只读快照"，在 `Config.refresher` 回调里失效重建（与 `static init` 的刷新机制天然对齐）。
- **预期**：数据源初始化时的配置表复制次数从 ~14 降到 1；Executor 构造从 1 次全量复制降到 0（命中快照）。绝对耗时只在启动/首请求，量级小。
- **代价**：多一份缓存（配置量级，KB 级）；需要与 `Config.set` 的刷新路径严格对齐，否则读到陈旧值。
- **验证**：启动期分段计时（`MonoTime`）+ 分配计数；`cjpm bench -O2` 对 `NamedDatasource(driver)` 构造 1000 次对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] #O4 `getOrNull` 的 18×18 类型矩阵：每格两次类型测试

- **现状**：`QueryResultWrap.cj:134-979` 对 `list[index]` 先做一层 ~18 分支类型匹配，每个分支内再对 `None<T>` 做一层 ~15 分支匹配来判定目标类型；每读一格至少一次多层 `match`（`TypeInfo` 比较）。`convertFromString`（`108-133`）与 `toMap`（`997-1034`）是同一套映射的另外两份（见 #7、#11）。
- **方案**：按"目标类型 `TypeInfo.of<T>()` → 一次查表得到转换函数"重构；数值之间统一走 `toInt64()/toFloat64()/toBigInt()` 等标准转换，不再枚举 `?Int8→?Int16` 这类组合。
- **预期**：每格的分支数从 O(源类型数) 降到 O(1)（一次查表）；代码行数从 ~700 行降到 ~80 行，顺带消除 #7 的漂移。收益需 profile 证明（结果映射是每单元格都走的路径，但占比未知）。
- **代价**：行为等价性要逐类型用例锁定（当前的宽窄转换、`None` 传播、异常文案都不能变）；`toMap` 的 `Rune`/`Nullable` 语义要保留。
- **验证**：`cjprof record` 跑"10k 行 × 20 列"查询，看 `getOrNull` 自耗时占比；改造后同输入对照 + `QueryResultWrap_test` 全绿。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑，只用于下一轮补数据。不计入模块统计，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `getOrNull` 的多层 `match` 是结果映射的主要 CPU 自耗时 | `f_orm/src/wrap/QueryResultWrap.cj:134-979` | 自耗时占比、调用次数 | `cjprof record` 跑 10k 行 × 20 列的 `iterator<T>()` 映射，1 万次迭代 |
| 2 | 每单元格一个 reader 闭包造成可观的分配量 | `f_orm/src/wrap/QueryResultWrap.cj:101` | 分配字节数 / GC 次数 | `cjprof heap` + `getAllocatedHeapSize()` 前后对照（同查询、同并发） |
| 3 | 迁移时逐语句建连/关闭带来明显的连接建立开销 | `f_orm/src/migro/SchemaFinderMediator.cj:103-113` | 建连次数与总耗时占比 | 100 条 DDL 的迁移，分段计时 + 驱动侧连接日志（对比"一次会话执行"） |
| 4 | `ORMConfig` 每次 getter 全量复制配置表拖慢启动 | `f_orm/src/wrap/ORMConfig.cj:96-105`（调用点 `NamedDatasource.cj:89-103`） | 构造 1 个数据源的配置读取耗时/分配 | `MonoTime` 分段计时 + 分配计数，构造 1000 次取中位数与离散度 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/migro/SchemaFinder.cj` | .cj | ✅ | 接口定义，7 个方法均有实现（`MysqlSchema` / `PostgresSchema`，范围外）；无问题 |
| 2 | `src/migro/SchemaFinderMediator.cj` | .cj | ✅ | 见 #1 #2 #3 #4 #5 #6 #12 |
| 3 | `src/migro/SubCommand.cj` | .cj | ✅ | 注册 + 恒返回 0，见 #3；`struct` 注册为 `static init`，无状态，值拷贝无影响 |
| 4 | `src/migro/f_mockdb_po_test.cj` | .cj | ✅ | 6 个用例实际测的是 `f_data` 的 `DataObject<ColumnMeta>.populate`，与文件名/migro 无关（测试组织问题，未单列） |
| 5 | `src/migro/imports.cj` | .cj | ✅ | 包级集中 import；`f_base.*` 供扩展方法（`groupBy`/`flatMap` 等）在作用域内，非死 import |
| 6 | `src/migro/migro_test.cj` | .cj | ✅ | 15 个用例覆盖 4 个 DDL 生成方法，但不经 `generate()`（#1 因此无覆盖）；`testPostgresAlterNotNull:189-191` 的断言近乎恒真（弱断言） |
| 7 | `src/orm_test/AnnotatedQueryMappers_test.cj` | .cj | ✅ | 版权头只有 SPDX 行，见 #16 |
| 8 | `src/orm_test/ORM_test.cj` | .cj | ✅ | 演示用 `@DAO`（`_test.cj` 后缀 ⇒ 不随库发布）；见 #18 |
| 9 | `src/wrap/ConnectionWrap.cj` | .cj | ✅ | 纯委托，`driverName` 透传给 `StatementWrap`；`createTransaction` 用 `this` 作 connection，索引基数链路完整；无问题 |
| 10 | `src/wrap/DataType.cj` | .cj | ✅ | 20 个 `DataType` 子类由宏按名拼接生成（`QueryMappersGenerator.cj:248`），非死代码；3 个 `type` 别名服务同一命名规则 |
| 11 | `src/wrap/DatabasePool.cj` | .cj | ✅ | 纯重导出（`public import`），注释已说明迁移后的构造器差异；无问题 |
| 12 | `src/wrap/DatasourceCreator.cj` | .cj | ✅ | 对外扩展点，README 有文档（`README.md:2187`），实现方为用户代码；无问题 |
| 13 | `src/wrap/DummyTransaction.cj` | .cj | ✅ | 空 `commit/rollback/save/release` 是 README 记录的 Null Object（`README.md:2194`），不判空实现 |
| 14 | `src/wrap/InputStreamOwnership_test.cj` | .cj | ✅ | 反向护栏用例（不关闭调用方流），断言与 `SqlArgs.set` 行为一致；无问题 |
| 15 | `src/wrap/NamedDatasource.cj` | .cj | ✅ | 池选择/参数装配逻辑，见 #O3；`setOptions` 与 `driver.open(url, options)` 重复应用同一组 options，见 #19 |
| 16 | `src/wrap/NoneConnection.cj` | .cj | ✅ | 整文件死代码，见 #9 |
| 17 | `src/wrap/ORMConfig.cj` | .cj | ✅ | 见 #8 #10 #15；配置键与 README 表（`README.md:185`、`236-241`）逐项核对一致 |
| 18 | `src/wrap/ORMConfig_test.cj` | .cj | ✅ | 见 #20（`refresh{}` 覆盖全局 refresher） |
| 19 | `src/wrap/Propagation.cj` | .cj | ✅ | 7 个枚举值与 README/`SqlExecutor` 用法一致；`Nested` 注释把"保存点"写成"新事务"，属措辞不精确，未单列 |
| 20 | `src/wrap/QueryResultWrap.cj` | .cj | ✅ | 见 #7 #13 #14 #17；`next(values)` 抛 `ORMException` 与 README `README.md:2192` 记录的 deprecated 口径一致，不判缺陷 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1 #4 #5；错误处理 #3 #8；安全性 #6（DDL 破坏面、标识符未加引号）；语言特性：`ConcurrentHashMap[]` 的抛异常语义、`parse`/`tryParse` 语义均已查文档（#4 #8） |
| §1 死代码 | 2 | 已对每个 `private`/`internal`/`protected` 符号全仓搜引用：`wrap/NoneConnection` 整文件零引用（#9）；`ORMConfig` 4 处 `case _ where !driverName.isEmpty()` 回退分支恒等价（#10）。`DataType` 子类与 3 个 `type` 别名由宏按名拼接（`QueryMappersGenerator.cj:248`），不算死代码；`DatabasePool.cj` 是 `public import` 重导出、`DatasourceCreator`/`DummyTransactionMode`/`Propagation` 是对外可达或已被 `SqlExecutor` 使用，均不判。`QueryResultWrap.next(values)` 的未用形参属接口实现，不判。 |
| §2 重复逻辑 | 4 | `wrap/NoneConnection` 与 `base/NoneConnection` 逐行重复（#9）；`makeReader` / `toMap` 两张 typeName 表（#7）；`getOrNull` 的 18×18 转换矩阵与 `convertFromString` 再一份（#11）；同一组 options 经 `open` 与 `setOption` 各应用一遍（#19）。`DataType` 20 个类的样板与 `ORMConfig` 4 个 `getStdPool*` 的近似重复按"宏/字面量差异属业务要求"记录在 #11/#O3，未单列。 |
| §3 空实现 | 0 | 逐函数体核对：`DummyTransaction.commit/rollback/save/release` 与 `NoneConnection.close` 是 README 明文记录的 Null Object（`README.md:2194`、`README.md:386/545`），有契约、有调用方；无 `TODO`/`FIXME`；`catch` 全部有日志或重抛（`SchemaFinderMediator:109` 的"吞"已按 #3 计缺陷）。 |
| §4 栈溢出 | 0 | 全部分无递归：`ORMConfig.getTransactionLevel/AccessMode/DeferrableMode/getUseCache` 的自递归都把 `driverName` 降为空串后终止（`getConf` 在 `134-140` 已合并全局键，见 #10），不存在无界递归；无递归遍历、无自引用结构。 |
| §5 OOM | 0 | `generate` 把全部 SQL 物化成 `ArrayList<(String,String)>`，上界=表数×列数（schema 规模，KB 级）；`QueryResultWrap.list` 上界=列数；`converterMap`/`finders` 只在启动写一次、按驱动/类型为键，有界。无按不可信长度预分配、无只增不减的全局容器。 |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据，无法成立热点结论；`getOrNull` 多层 match、reader 闭包、逐语句建连、配置全量复制 4 项已列入「待验证假设」并给出采数方法。 |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件无 `Mutex`/`synchronized`/`ReentrantLock`；唯一的并发结构是 `ConcurrentHashMap`（`SchemaFinderMediator.finders`、`ORMConfig.converterMap`），无临界区、无锁内 I/O。 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`；迁移语句串行执行是 CLI 语义（不是把可并行任务串行化）。 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无热点 `contains`/`indexOf`、无 `remove(at: 0)`、无循环内字符串拼接（`StringGenerator` 已用）；`getAllConfigs` 的逐键 `replace` 与按列前缀读取归入 #O2/#O3 待验证。 |
| §7 降堆内存方案 | 2 | #O1（reader 闭包按列复用）、#O2（只缓存被请求列）；均无基线，标注"待验证"。 |
| §8 降 CPU 方案 | 2 | #O3（配置快照）、#O4（类型矩阵查表化）；均无基线。 |
| §9 local mode 可行性 | 0 | 本部分热点候选（`getOrNull` 的闭包/中间 `Any`）都是会被调用方持有或跨函数返回的值（`?T` 返回、`list` 成员），逃逸检查不通过；没有 peak memory 前后对照也无法证明收益，故不作为方案。 |
| §11 现有代码的 BUG（存量） | 10 | #1 #2 #3 #4 #5 #6 #7 #8 #13 #17（其余 #9 #10 #11 #12 #14 #15 #16 #18 #19 #20 为死代码/重复/测试/可读性类）。本轮读到的 20 个文件里每个 `Option`/越界/空集合路径均已核对：`columns.size <= index` 有上界检查但无下界（#17）；`columnInfoMap` 重名覆盖（#14）；`convertFromString` 缺 Bool/Rune（#13）。 |
| §12 并发安全与锁粒度 | 2 | 共享点只有 `ORMConfig.transactionIncludingRegex/transactionExcludingRegex`（`private static var`，`static init`/`Config.set` 回调写、`transactionable` 读，无原子/无同步 ⇒ 弱可见性，见 #15）；同一个 `refresh` 入口还能被调用方覆盖掉刷新回调（#20）。`finders`/`converterMap` 为 `ConcurrentHashMap` 且启动后只读，安全。无锁粒度问题。 |
| §14 功能完备性与 README 覆盖 | 1 | `dbmigro` 端到端不可用（#1）；README 对本部分涉及的 `QueryResultWrap`/`DummyTransaction`/`StatementWrap`/`DatasourceCreator`/`ORMConfig` 均已逐符号对照，无"README 承诺但代码没有"的其它项。 |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md` 文件，§13 无审查对象；对 part7 涉及符号抽查了 `README.md:185/236-241/386/545/2191-2194` 与 `README_en.md` 对应段落，未发现与本部分代码相反的表述（`orm_pooledDatasourceMaxLifeTime` 这类反直觉键名 README 已显式说明，不算漂移）。 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 6 |
| 轻微 | 12 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分的风险高度集中在 `src/migro/`：**整条迁移链路当前是空转的**——入口 `groupBy` 恒返回空 map（根因在 `f_base`，已由该模块报告覆盖），导致 `dbmigro` 一条 SQL 都不生成却返回成功；就算修好这一处，`use <db>;` 也会因为逐语句新建/关闭 executor 而失效（多库场景把 DDL 打到默认库），失败语句还会被就地吞掉、退出码仍是 0。这三点构成一个完整阻塞项：迁移功能在端到端意义上不可用，且没有任何用例覆盖 `generate()` 这一层（现有 15 个用例只测 DDL 字符串生成）。建议按 #1 → #3 → #2 的顺序修，并把"`generate` 至少产出一条 SQL""失败必须非 0 退出"写成用例。

`src/wrap/` 侧质量明显更好：`QueryResultWrap` 的类型映射虽然有 700 行矩阵、且与 `toMap()` 存在已实现的漂移（`SqlByte`），但取值语义、流所有权（`hadStream`）、异常文案都有明确的 bug 编号与用例护栏；真正的结构性欠债是"同一份 typeName 在取数与 `toMap` 两处各写一遍"（设计文档自己也承认）。`ORMConfig` 的主要问题是错误处理策略不一致（一半配置项退回默认、一半直接抛），这在启动期是可观察的行为差异，但不是崩溃级缺陷。`DataType` / `ConnectionWrap` / `DummyTransaction` / `DatabasePool` 属薄壳或宏驱动，未发现问题。

死代码只有一处：`wrap/NoneConnection.cj` 与 `base/NoneConnection.cj` 逐行重复且全仓零引用（`SqlExecutor` 引用的是 base 包那份）——留在 `wrap` 包里是个隐形陷阱（同包内写 `NoneConnection.instance` 会拿到另一个类型，`is NoneConnection` 状态判断会失效）。建议直接删除该文件。

存量缺陷共 20 条（2 严重 / 6 一般 / 12 轻微），是否纳入修复、按哪个优先级排期，请用户决定；本报告不改源码、未跑构建，全部结论来自静态阅读 + 官方文档核对。
