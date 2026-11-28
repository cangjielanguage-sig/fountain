# f_orm 模块审查报告

> **模块第 4/8 部分**（本报告只覆盖 `files/f_orm.part4.txt` 列出的 20 个文件，全部是 `src/base/` 下的 `.cj`：`NestQueryMapper` → `SqlExecutorArgBranches_test`，其中 4 个 `_test.cj`、0 个 `.md`。模块共 111 `.cj` + 11 `.md`，其余文件由第 1–3、5–8 部分产出；本部分编号独立，合并时以主 Agent 为准。README / `doc/**` 不在本部分，只在需要取证时被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（本部分 20 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，源码无 diff ⇒ 全部问题记「存量」；`git blame` 抽样落在 `ae7aa2263c 2026-09-13` / `4be871f2fd 2026-10-02` / `f56b276758 2026-10-05` / `9fe28abd50 2026-09-13`）
- **审查重点**：executor 生命周期与线程内复用语义、连接与事务、SQL 注入与参数绑定、大粒度锁、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 4/8 部分）

本部分是**执行与映射的主干**：`SqlExecutor`（1105 行，线程内 executor、结果缓存、事务传播）、`ORM`（数据源注册表）、`RootDAO`（参数绑定与条件 DSL）、`SqlDSL`（DSL 编译）、`QueryMappers` / `QueryMapper` / `NestQueryMapper`（结果映射）以及 `RootService` / `Pagination` / `Partials` / `NoneConnection` / `ORMColumn` / `ORMInitializer`。三个严重缺陷分别落在**子类型映射器的数组索引**、**DSL 集合参数的双重占位符**、**事务内结果缓存的可变别名**——都不在常规单测覆盖范围内（`setSqlFromObject` / `setSqlFromMap` 全仓零调用，`QueryMappers.create` 只由宏展开产生）。

## 发现

### [严重][存量] #1 `QueryMappers.create` 尾部元素取 `mappers[i]` 而不是 `mappers[i - oMappers.size]`：父类有映射器时必然下标越界

- **位置**：`f_orm/src/base/QueryMappers.cj:41-61`（关键 `53-60`，错在 `58` 行 `mappers[i]`）；调用源 `f_orm/src/macros/QueryMappersGenerator.cj:138-144`（`QueryMappers<$st>.create<$name>(creator, mappers)`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，`55` 行 `i => if (i < oMappers.size)`）
- **判据**：review-checklist §11「边界差一 / 越界」、§10「正确性」
- **证据**：静态确定 —— 数组长度写成 `oMappers.size + mappers.size`（记 `A`、`B`），初始化 lambda 对 `i ∈ [A, A+B-1]` 取 `mappers[i]`；`mappers` 的长度只有 `B`，而最大下标 `A+B-1 ≥ B`（只要 `A ≥ 1`）。宏侧传入的 `mappers` 只含**本类自己的**字段映射器（`QueryMappersGenerator.cj:126-131` 只拼 `generateMappers(name, props…)` 与实例变量），父类映射器由 `oMappers` 提供，因此这两个数组不重叠。
- **描述**：任何 `@QueryMappersGenerator` 标注的类，只要它有一个"有映射字段"的父类（`A ≥ 1`），`create` 在静态初始化 `_qUEry__mAppErs_` 时就会抛 `IndexOutOfBounds`/等价异常，或（若驱动/运行时对数组初始化惰性求值）把父类字段映射错位。当前仓库内没有继承式 POJO 的例子，所以这条路径没有被任何用例守住；一旦下游项目用继承复用基础字段（`create<T>` 的存在就是为这个场景），类加载即失败。附带：`42` 行的 `TypeInfo.of<O>().isSubtypeOf(TypeInfo.of<Object>())` 恒为真，属恒真条件。
- **建议**：改为 `mappers[i - oMappers.size]`，并把条件判空（`if (A == 0) { return None }` 或直接 `Array(…)` 用两次 `add` 拼装）；补一条用例：`open class Base { var id: Int64 }` + `class Sub <: Base { var name: String }`，断言 `Sub.queryMappers().mappers.size == 2` 且字段名分别是 `id` / `name`。

### [严重][存量] #2 `SqlDSL.convert` 的 `Iterable<Data>` 分支每元素**多输出一个 `?`**，且逗号插在占位符之后：占位符数 2N、绑定参数 N

- **位置**：`f_orm/src/base/SqlDSL.cj:112-122`（`115` 递归 `convert` 已写入一个占位符，`117-119` 又写 `','` + `'?'`）
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误」、§10「正确性（参数绑定）」
- **证据**：静态确定 —— 两个被证实的点：
  1. `convert` 的标量分支末尾统一 `sqlgen.append(' ? ')`（`125`），所以递归调用 `convert<T>(exe, sqlgen, name, d)` **每个元素已经产出 1 个 `?` 并 `exe.arg(...)` 绑定 1 个参数**；`119` 行又 `append('?')` ⇒ 每个元素 2 个占位符；
  2. 逗号位置在 `if(c > 0)` 之后、`'?'` 之前（`116-119`），而内层文本已经先写进去了，输出形如 ` ? ? ? , ?`（两个元素 4 个占位符），不是 ` (?,?)`。
  可达性：`DataList <: Data & Collection<Data>`（`f_data/src/base/DataList.cj:18-33`，`Collection<Data>` 即 `Iterable<Data>`），它不匹配前面任何 `DataBool/DataString/DataReal/DataCollection<Array<Byte>,Byte>` 分支，必然落到本条分支。
- **描述**：把集合字段（`DataList`）经 `:{path}` 或 `setSqlFromObject` 绑定进 `in (...)` 时，生成 SQL 的占位符数是参数数的 2 倍且逗号错位。驱动要么报"参数个数不匹配"，要么按位置宽松绑定把后续谓词的值整体错位——静默查错数据。
- **建议**：删掉 `117-119` 的两行（占位符由内层 `convert` 负责），逗号改为在内层调用**之前**按 `c > 0` 输出，并对空集合返回 `''`（与 `RootDAO.arg<I,T>` 的 `n == 0 → ''` 口径一致）。补用例：`DataList` 两个元素，断言 SQL 文本为 ` (? , ? )`、`args.size == 2`。

### [严重][存量] #3 结果缓存直接返回**同一个可变实例**：事务内重复 `list` / `mapList` / `first` 拿到共享对象，调用方就地修改即污染后续结果

- **位置**：`f_orm/src/base/SqlExecutor.cj:905-919`（`916` 行 `cache[key] = v`；`908` 行 `case Some(v: T) => v` 原样返回）；受影响入口 `557-565`（`list`）、`573-581`（`mapList`）、`532-540`（`first`）
- **来源**：存量（`git blame`：`f56b276758 2026-10-05`，`916` 行）
- **判据**：review-checklist §12.1「共享可变状态」、§11「逻辑错误（缓存别名）」
- **证据**：静态确定 —— `v` 是 `exec()` 的返回值，类型为 `ArrayList<T>` / `ArrayList<HashMap<String,Any>>` / `Option<T>`，以 `Any` 存进 `cache`；命中分支不做任何复制，直接把同一引用交回调用方。缓存的生命周期是"本次事务"：`close()`（`153-174`）只在非事务路径执行，事务内 `cache` 不被清空，所以同一事务里「同一 SQL + 同一参数」的第二次查询必然命中同一个对象。
- **描述**：最典型的形态是 `let rows = ex.setSql('select …').list<User>()`，业务在同一个事务里对 `rows` 做 `sortBy` / `remove` / 补字段，再查一次同一语句（分页复用、循环重查）时拿到的仍是上一次那个被改过的列表——**返回值与数据库不一致，且没有任何编译或运行期提示**。`first<T>` 共享 POJO 同理：改动对象字段后重查旧值，会让"读—改—写"路径基于脏副本。
- **建议**：命中缓存时返回防御性副本（`list` / `mapList` 复制容器；`first` 只缓存不可变快照或干脆不缓存非标量结果），或把缓存的语义收窄为"只缓存标量 / 只读数据"（`singleFirst` / `singleList` 之外的入口不建 key）。若确认下游不会就地修改，至少在 README 与 `list` 的注释里写明"事务内命中缓存时返回共享实例"。

### [一般][存量] #4 `SqlDSL.compile` 的 data-path 循环条件用了外层 `token`（恒为 `LCURL`）：`:{a.b}` 永远读到语句末尾

- **位置**：`f_orm/src/base/SqlDSL.cj:64-76`（`64` 行 `let token = tokens[i]` 遮蔽外层同名变量，`71` 行 `while(i < tokens.size && token.kind != RCURL)`）
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误（变量遮蔽）」、§13/§14「文档承诺但不可用」
- **证据**：静态确定 —— `token` 在 `64` 行绑定的是 `:{` 之后那一个 token（即 `LCURL`），循环条件里 `token.kind` 因此恒等于 `LCURL`，`!= RCURL` 永真；循环只能靠 `i < tokens.size` 退出，于是 `} ` 及其之后的所有 token 都被塞进 `path`。随后 `75` 行的检查写成「当前 token 不是 `RCURL` **或** 整个 DSL 的最后一个 token 不是 `RCURL`」：只要 `:{…}` 后面还有其他文本（`… :{a.b} and x=1` 这种最常见写法），就抛 `IllegalArgumentException('not completely data path in …')`；只有路径恰好位于语句末尾时才放过，但 `path` 里仍含 `} `（`85` 行 `name` 取到 `'}'`），`DataPath.solid` 也拿不到合法路径。
- **描述**：`f_orm/README.md:822` 明确承诺 `| :{a.b.c} | 绑定数据路径（DataPath），取对象的嵌套值 |`，而代码里这条语法在正常写法下必然抛异常。全仓 `setSqlFromObject` / `setSqlFromMap` 零调用（只有 `SqlDSL.cj` 内的定义与 `SqlDSL` 接口声明），也没有任何 DSL 用例，所以缺陷未暴露。
- **建议**：条件改成 `tokens[i].kind != RCURL`；`75` 行改成只检查"循环是否因找到 `RCURL` 而退出"（`i >= tokens.size || tokens[i].kind != RCURL` ⇒ 抛错），并把 `}` 从 `path` 中排除；补三条用例：路径在语句中间、路径在末尾、缺 `}`。

### [一般][存量] #5 `readOnly` 一旦置真永不复位：`isReadOnly` 与 `beforeCommit(readOnly)` 在后续写语句/事务里继续报"只读"

- **位置**：`f_orm/src/base/SqlExecutor.cj:84-87`（唯一置位点）、`97-106`（`clearSql` 只清 `sql_` 与 `args`）、`107-111`（对外 `isReadOnly`）、`1048` / `1071` / `1087`（事务切面传给钩子）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，`85` 行）
- **判据**：review-checklist §11「状态未复位 / 契约与实现不符」、§12.1「共享可变状态」
- **证据**：静态确定 —— `grep readOnly f_orm/src` 只有三处：字段声明（`47`）、`85` 置 `true`、`109` 读取；没有任何 `= false` 或"按语句重算"的路径。`sql` 的 setter 对新语句只做 `isSelectStatement → true`，而 `clearSql()` 不复位。
- **描述**：同一线程的 executor 是跨语句复用的，只要执行过一次 `select`，`isReadOnly` 之后永远是 `true`。对外：调用方拿 `isReadOnly` 判断"能否走只读库/只读事务"会误判；对内：`ORM.hooks.beforeCommit(this.isReadOnly)` 把"先读后写"的事务也当成只读提交，读修复/审计类钩子据此做出的决策全错。当前仓内没有 `TransactionHook` 实现读这个参数，所以属"契约错但暂时无人受伤"。
- **建议**：把 `readOnly` 改成按语句计算（在 `clearSql()` 里置 `false`，或直接让 `isReadOnly` 返回 `isSelectStatement(sql_)`）；`beforeCommit` 的语义若指"整个事务只读"，应在事务开始时按首条语句定一次并显式命名（`txReadOnly`），与语句级只读分开。

### [一般][存量] #6 线程内 `current` 是单槽：`close()` 无条件清空、`getInstance` 无条件覆盖，跨驱动混用时 DSL 绑到错误 executor 或直接抛异常

- **位置**：`f_orm/src/base/SqlExecutor.cj:130`（`current.set(exe)`）、`153-174`（`155` 行 `current.set(None)` 不判断 `getCurrent() == this`）、`133-135`（`getCurrent` 取不到即抛 `NoneValueException`）；消费方 `f_orm/src/base/ExtendString.cj:26-27`、`SqlDSL` 之外的 `f_orm/src/base/RootDAO.cj:563-567`（`SqlFunc.toString`）、`f_orm/src/base/Columns.cj:25` / `104`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1「共享可变状态 / 可见性」、§11「契约与实现不符」
- **证据**：静态确定 —— `current` 是 `ThreadLocal<SqlExecutor>` 的单槽（`45`）：`getInstance(driverName)` 每调用一次就覆盖，`close()` 每结算一次就清空，两者都不校验"当前槽位是否就是本次操作的 executor"。而 `SqlFunc.toString()`、`Columns`、`ExtendString` 的 `AND/OR/NOT` 属性在**构建 SQL 文本时**用 `getCurrent()` 取 executor 做标识符引用（`fun`/`involve`）。
- **描述**：`let a = ORM.executor("a"); let b = ORM.executor("b")` 之后对 `a` 拼 SQL（`a.setSql('select ${COUNT(col)} …')`），`SqlFunc.toString` 取到的是 `b`，引用字符与方言按 `b` 的驱动生成；`a.close()` 之后更是把槽位清空，`b` 上继续拼 SQL 直接抛 `NoneValueException`。单驱动场景因为"每次操作都以 `getInstance` 开头"而不易暴露，多数据源（本项目 `f_orm` 明确支持多 driver）会踩。
- **建议**：`close()` 里改成 `if (current.get() == Some(this)) { current.set(None) }`（或用 `currents` 里的实例做身份比较）；更彻底的做法是取消"线程内隐藏当前 executor"，让 `SqlFunc` / `Columns` / `ExtendString` 显式接收 executor（它们都已经在 `TableClause` / `RootDAO` 的 `executor` 字段作用域内）。

### [一般][存量] #7 `QueryResultIterator.next()` 在映射抛异常时不关闭结果集：executor 的"活动结果集"标记永久为真，后续查询全部被拒

- **位置**：`f_orm/src/base/QueryResultIterator.cj:77-88`（`81` 行 `mappers.doMap(result)` 无 `try/finally`）；同样的形态 `101-115`（`SingleColumnIterator.next`）；状态位 `f_orm/src/base/SqlExecutor.cj:53`、`964-966`、`181-184`
- **来源**：存量（`git blame`：`f56b276758 2026-10-05`，`81` 行；该类本身是 bug.md §1.5 修复时新增，已给 `close()` 做了兜底，但没覆盖 `next()` 的异常路径）
- **判据**：review-checklist §11「资源不对称：异常跳过释放」、§12.1「异步/资源」
- **证据**：静态确定 —— `next()` 只在 `doMap` 返回 `None` 时调用 `close()`（`82-85`），异常路径直接向调用方抛出；`activeQueryResult` 由 `execute(closeBeforeReturning:false…)` 置真（`972`），只有 `mustClose` 分支（`1005-1007`）或 `AbstractQueryResultIterator.close()` → `releaseActiveQueryResult()`（`181-184`）才会复位。映射过程中的类型转换失败（`ORMConverter.convert` 抛错、列缺失、`getOrThrow`）完全可能发生。
- **描述**：一条查询只要有一行的字段转换失败，异常冒到业务层后：结果集未关、`Statement` 未关、executor 的 `activeQueryResult` 仍为 `true`，该线程后续任何 `setSql(...).first()` 都抛 `"cannot execute SQL while a previous query result is still active"`——**线程被自己的错误永久锁死**，只能靠显式 `it.close()` 或新建线程恢复（而 `it` 往往已经随异常栈丢失）。
- **建议**：把 `mappers.doMap` 包进 `try { … } catch (e) { close(); throw e }`（或 `finally` 里按"未取到值就关闭"的语义处理）；`SingleColumnIterator.next` 同理。补用例：mockdb 返回一列无法转成目标类型的值，断言迭代器抛错后 `ex.isClosed()` / 同一 executor 可以继续查询。

### [一般][存量] #8 事务内结果缓存**无容量上限、不随语句释放**：长事务里每条不同参数的 SELECT 全量留存结果集

- **位置**：`f_orm/src/base/SqlExecutor.cj:54-56`（`cache` 字段）、`62-67`（默认 `useCache = … ?? true`）、`915-917`（写缓存）、`923-926`（只在写语句后清）、`153-174`（`cache.clear()` 只在非事务 `close()` 里）
- **来源**：存量（`git blame`：`f56b276758 2026-10-05`，`916` 行）
- **判据**：review-checklist §5「缓存键无界 / 无界容器」、§7「有界化」
- **证据**：静态确定 —— 事务中 `close()` 因 `tx.isSome()` 提前返回（`154`），`cache.clear()` 与 `clearSql()` 都不执行；缓存键是 `SqlCacheKey(sql, args)`（`25-39`），每次参数不同就是新键，既没有容量上限也没有 TTL/淘汰，写语句才整体清空一次。缓存值是完整结果集（`ArrayList<O>` / `ArrayList<HashMap>`），每行都是新对象。
- **描述**：批量任务在**一个事务**里按 id 循环 `select … where id = ?`（很常见的写法）时，N 次查询的 N 个结果集全部驻留到事务结束，峰值 ≈ 结果总量，且这部分对象在事务提交前不可能被回收。触发条件明确（同一事务 + 循环查询），但没有实测峰值，故不定为严重。
- **建议**：给 `cache` 设容量上限（如 128 条 / 按行数估算字节数）并在超限时整体清空；或把缓存语义限制为"同一语句在同一事务内的重复查询"——即 key 里带 executor 的语句序号，语句变化即失效。验证：mockdb 事务内跑 1k 次不同 id 的 `first<T>`，采 `getAllocatedHeapSize()` 与 RSS，确认稳态不随 N 增长。

### [一般][存量] #9 `Pagination` 未校验 `size` / `page`：`size == 0` 除零，`page < 1` 得到负 offset

- **位置**：`f_orm/src/base/Pagination.cj:30-41`（`36` 行 `rows / size`、`37` 行 `rows % size`）、`49-53`（`51` 行 `(page - 1) * size`）
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`，`36` 行）
- **判据**：review-checklist §11「除零 / 边界差一」、§10「正确性」
- **证据**：静态确定 —— `size` 是公开构造参数（`public let size!: Int64`），两个 `init` 都直接参与除法与乘法，没有 `size > 0`、`page >= 1` 的断言。
- **描述**：分页参数来自 HTTP 查询串是常态：`pageSize=0` 时构造 `Pagination` 立即除零抛 `ArithmeticException`（不是 400，而是 500）；`page=0` 时 offset 为负，`LIMIT … OFFSET -n` 在 PostgreSQL/MySQL 上行为不同（报错或忽略），同一份业务代码在两种库上表现不一致。
- **建议**：构造时统一钳制：`size <= 0 → 抛 ORMException("page size must be positive")`（或取默认 20），`page < 1 → 1`、`rows < 0 → 0`；`pages` 用 `(rows + size - 1) / size` 一次算完，避免 `%` 分支。补用例：`size = 0`、`page = 0`、`rows = 0`。

### [一般][存量] #10 `RootDAO.arg<I,T>`（集合元素绑定）缺 `Data` / `?Any` 分支：与 `arg(Any)` 行为漂移，`IN` / `loop` 传 `Data` 元素直接抛错

- **位置**：`f_orm/src/base/RootDAO.cj:323-389`（分支表 `333-376`，`375` 行兜底 `throw ORMException('type does not support')`）；对照 `252-307`（`arg(Any)`，含 `case x: Data` 与 `case x: ?Any`）；第三份同表 `f_orm/src/base/SqlExecutor.cj:610-653`（`add<T>`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`，`333` 行）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（只改载体）」、§11「契约与实现不符」
- **证据**：静态确定 —— 同一套 40+ 类型分支在本部分出现三份（`arg(Any)` 22 行 + 可空组、`arg<I,T>` 20 行 + 可空组、`add<T>` 20 行 + 可空组），三处的差异是**实质性的**：`arg(Any)` 有 `case x: Data => arg(x)`（把 `DataString/DataReal/DataNone…` 再分派一次），`arg<I,T>` 没有；`arg(Any)` 有 `case x: ?Any` 兜住"Option of 未列类型"，`arg<I,T>` 没有。代码注释（`327-332`）只要求"顺序保持一致"，未要求"分支集合一致"。
- **描述**：`IN(values)` / `loop(values)` 对 `Iterable<T>` 逐元素走 `arg<I,T>`。业务把 `Data` 当参数容器（`Map<String,Any>` 取出的值、`toData()` 结果）传进集合时，标量路径 `arg(Any)` 能绑、集合路径抛 `"type does not support"`；同一个值走 `BETWEEN` 可以、走 `IN` 不行。三份分支表各自漂移的风险还会随新增类型继续放大（本部分之外的 `RootDAO.arg(Any)` 就曾在重排时去掉过恒不可达分支）。
- **建议**：把三处合并为一处分派：`arg<I,T>` 直接复用 `arg(Any)`（`for (v in value) { arg(v) }` 后只拼占位符），或在 `arg<I,T>` 里补 `case x: Data => arg(x)` 与 `case x: ?Any`。若为性能刻意保留展开，加一个机械护栏：用反射/源码扫描断言三张表的 `case` 多重集一致（`SqlExecutorArgBranches_test.cj:47-49` 已用同样思路做过一次人工核对）。

### [一般][存量] #11 嵌套映射器的接线断了：`newNest` / `newNullableNest` 无人调用、`NullableNestQueryMapper` 的 `nestGetter` 没有任何实现路径、子类型映射走 `new<T>()` 丢嵌套

- **位置**：`f_orm/src/base/NestQueryMapper.cj:25-30`（`newNest`）、`46-52`（`newNullableNest`）、`53-57`（`populate` 无条件 `nestPutter`）；`f_orm/src/base/QueryMappers.cj:53-60`（`create` 调用 `oMappers[i].new<T>()`，即 `QueryMapper.new`，`f_orm/src/base/QueryMapper.cj:37-44`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，`25` / `46` 行）
- **判据**：review-checklist §1「无调用者」、§14「接线缺失 / 半成品」、§11「契约与实现不符」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）搜 `newNest` / `newNullableNest` 只命中定义本身；`nestGetter` 只在 `newNullableNest` 的包装闭包里被引用（`49` 行），而 `populate`（`53-57`）只读 `nested` 与 `nestPutter`。宏只构造这两个类的实例（`QueryMappersGenerator.cj:350-354`、`390-393`），从不调用 `newXxx`。
- **描述**：三条后果串在一起：(a) `NullableNestQueryMapper` 名为 nullable，`populate` 却总是 `nested.map(result)` 后无条件 `nestPutter(o, n)`——左连接没有匹配行时会构造一个"全空字段的对象"塞进字段，而不是留 `None`（`nestGetter` 本应在这里做"是否为空"的判断），而非空类型的嵌套字段在 NULL 列上还会在 `ORMConverter.convert` 里抛错；(b) 子类型继承映射（`QueryMappers.create`）用 `QueryMapper.new<T>()` 复制父类映射器，`NestQueryMapper` 没有覆写 `new`，父类的嵌套字段退化成 `putter: {o, v =>}`（`NestQueryMapper.cj:23` 的 no-op putter），**嵌套对象永远不被填充**；(c) 两个 `newXxx` 方法既没人调也不是 `new`，属死代码。
- **建议**：把 `newNest` / `newNullableNest` 改成 `override new<T>()`（或让 `QueryMapper.new` 用一个可覆写的 `rebind` 钩子），使 `create` 走同一条路；`NullableNestQueryMapper.populate` 用 `nestGetter` + "嵌套映射器的所有列是否都为空"决定是否 `None`。补两条用例：左连接空行 → 字段为 `None`；子类 `queryMappers()` 的父类嵌套字段能被填充。

### [一般][存量] #12 `commit` / `rollback` / `save` / `release` 在无事务时静默成功：`Option` 被丢弃，调用方无法知道保存点没生效

- **位置**：`f_orm/src/base/SqlExecutor.cj:298-306`（`commit` / `rollback`）、`307-342`（`finishTransaction` 在 `tx.isNone()` 时整段跳过）、`389-394`（`tx?.save` / `tx?.release`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「错误处理缺失或静默」、§3「`Option` 分支被吃掉」
- **证据**：静态确定 —— `finishTransaction` 只有 `if (let Some(tx) <- this.tx)` 一个分支，`None` 时既不打日志也不抛错；`save` / `release` 直接 `tx?.save(...)`，返回值（`Unit`）与"是否执行"都没有表达。
- **描述**：`newTxAndBegin(propagation: Supports)` / `NotSupported` / `Nested` 在无外层事务时用的是 `DummyTransaction`（`wrap/DummyTransaction.cj:66-70` 的 `commit` / `rollback` / `save` / `release` 全为空体），此时 `save("sp1")` 静默 no-op，随后 `rollback("sp1")` 也 no-op——业务以为回滚到了保存点，实际什么都没发生，**部分写入被提交**。这条与"dummy 事务就是设计"并不矛盾：问题在于**保存点语义没有降级提示**。
- **建议**：`save` / `release` 在 `tx.isNone()` 或 `tx.isDummy` 时抛 `SavepointNotSupportedException`（或返回 `Bool` 让调用方判断）；`commit()` 无事务时至少 `logger.warn`。补用例：`Supports` 传播下 `save` → 断言抛错/告警。

### [一般][存量] #13 `RequiresNew` / `NotSupported` 分支先取新连接再建事务：`createTransaction()` 返回 `None` 时这条连接无人关闭

- **位置**：`f_orm/src/base/SqlExecutor.cj:226-252`（`229-233` 与 `246-250` 取 `getConnection(driverName)`；`234` / `263` 只处理 `Some`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「资源不对称（打开未关）」、§12.1「跨线程资源」
- **证据**：待确认 —— 需要驱动的 `Connection.createTransaction()` 在"不支持事务"时返回 `None` 的行为（std 接口签名是 `?Transaction`，语义上允许 `None`）。代码侧确定：连接变量是局部 `let`，除 `TransactionWrap` 构造外没有其他引用，`if (let tx <- …)` 失败后既不 `close()` 也不保存。
- **描述**：一旦某驱动对嵌套/新事务返回 `None`，池里的这条连接就永久占用（直到进程退出），`hasRealTx` 仍为旧值，后续 `Required` 判断也会错。当前仓内驱动（postgres/mysql/mockdb）预计都返回 `Some`，所以是潜在缺陷。
- **建议**：`if (let tx <- …) { … } else { connection.close(); newDummyTx(mode: StartFailure, ex: ORMException("driver returned no transaction")) }`；`RequiresNew` 里新取的连接用 `try/finally` 兜底关闭。

### [一般][存量] #14 测试替身 `QueryResultTest.getOrNull` 的 `match(None<T>)` 恒不命中类型分支：任何取值都抛 `Exception("get error")`，且 `isClosed()` 恒 `false`

- **位置**：`f_orm/src/base/QueryResult_test.cj:71-89`（`75` 行 `match(None<T>)`、`87` 行兜底抛错）、`19-23`（`isClosed` 恒 `false`、`close` 空体）、`37-70`（`next(values)` 用 `i > 2`、`next()` 用 `row < 4`，两套行计数互不相关）
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13` 前后，bug.md 之前的替身）
- **判据**：review-checklist §11「逻辑错误」、§3「空实现（替身无注释）」
- **证据**：静态确定 —— `match (None<T>)` 匹配的是 `Option<T>` 的 `None` 实例，类型模式 `case _: Int64` / `String` / `Bool` / `DateTime` 判的是**值的运行时类型**，`None<Int64>` 的运行时类型是 `Option<Int64>`，四个分支都不可能命中 ⇒ 永远落到 `case _ => throw Exception("get error")`。同文件 `i`（`34`）只在 `next(values)` 里自增、`row`（`66`）只在 `next()` 里自增，两条 API 的行数口径也不一致。
- **描述**：这个替身仍被 `Statement_test.cj:25` / `37` 用作 `query()` 的返回值（`StatementTest` 本身已无调用者，属第 3 部分 #19 描述的旧替身链）；只要有人再用它跑"读一行"的用例，就会得到与被测逻辑无关的 `get error`，或永远读到 `isClosed() == false` 把资源释放问题掩盖掉。
- **建议**：直接删掉 `QueryResultTest` / `StatementTest`（mockdb 已覆盖同一场景），或按 `TypeInfo.of<T>()` 分派（`match (TypeInfo.of<T>()) { case t where t == TypeInfo.of<Int64>() => … }`）并给 `close()` 一个真实状态位。

### [一般][存量] #15 `SqlCacheKey` 持有**活的可变** `SqlArgs`：`clearArgsAfterExec: false` 时键构造后参数还会继续追加，`hashCode`（记忆值）与 `==`（内容比较）契约被破坏

- **位置**：`f_orm/src/base/SqlExecutor.cj:25-39`（`28` 行构造时算 `h`、`34` 行 `==` 比 `args`）；`97-106`（`clearArgsAfterExec == false` 时**不换** `args` 实例）；唯一使用点 `f_orm/src/base/SqlPartial.cj:295`（`setSql(countSql, clearArgsAfterExec: false)`）
- **来源**：存量（`git blame`：`f56b276758 2026-10-05`）
- **判据**：review-checklist §11「契约与实现不符（hash/equals 不变式）」、§5「长期持有」
- **证据**：待确认 —— 需要在事务内构造出"同一 `SqlArgs` 实例先做缓存键、随后又被 `add`"的时序（`count` 语句后紧接拼接语句）。代码侧确定：`SqlCacheKey.h` 只在构造时计算一次，`SqlArgs.add` 会把 `h` 复位为 0（`wrap/SqlArgs.cj:31-37`），但 `SqlCacheKey` 里的 `h` 不会重算，而 `==` 用的是 `args == other.args`（内容）——键放进 `HashMap` 后再变化，等于把条目放进了一个"用旧哈希、按新内容比较"的桶。
- **描述**：后果是缓存偶发不命中（性能）或条目不可达（内存滞留，因为 key 强引用了仍在增长的 `args`）；极端情况下同一个 key 的 `hashCode` 与 `equals` 自相矛盾，`HashMap` 的行为未定义。它不会直接产生错误结果（命中失败就重查），但会让 `orm_useCache` 的语义不可预测。
- **建议**：`SqlCacheKey` 构造时对 `args` 做**不可变快照**（复制列表，或存 `args.toString()` / 预先算好的参数摘要），使 key 一旦构造就不再变化；`clearArgsAfterExec: false` 的路径改用独立的"多段 SQL 绑定"缓存，不复用结果缓存 key。

### [轻微][存量] #16 `ORM.register` 六个重载重复同一段前置检查，且日志与行为不一致（其中一路完全不检查）

- **位置**：`f_orm/src/base/ORM.cj:88-132`（`89-92` 检查 + `warn`、`97-99` 检查但**静默** `return`、`104-107` / `111-115` 检查 + `warn`（后者缺 `debug`）、`121-132` 四个 `String` 重载**完全不检查**）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2「字面量/结构复制导致行为漂移」、§11「错误处理不一致」
- **证据**：静态确定 —— 五个 `Driver` 重载里 `96-102` 的重复分支只 `return`（没有 `log.warn`），`111-117` 少了 `log.debug`；`register(driver: String, …)` 系列（`121-132`）先 `NamedDatasource(getDriver(driver))` **急切建对象**，再交给 `register(datasource)`，重复时走 `datasources.addIfAbsent` 失败的 `datasource.close()`（`80`）——新建的 `NamedDatasource` 被静默关掉，既不告警也不告知调用方"这次注册被忽略，默认库也没改"。
- **描述**：基线约定"同名注册启动直接失败"（`fountain-baseline.md` §4），这里实现的是"先注册先赢 + 静默丢弃后者"，且两条注册路径的日志口径不同：走 `Driver` 重载能看到 `warn`，走 `String` 重载什么都没有。
- **建议**：抽一个 `private func alreadyRegistered(name: String, source: String): Bool`，统一 `warn` 文案；`String` 重载在创建 `NamedDatasource` **之前**做检查，避免白建连接；若按基线要"启动失败"，改成抛 `ORMException`。

### [轻微][存量] #17 `ORM.close()` 用 `e.printStackTrace()` 而非 `f_log`；`deregisterAndReplaceDefault` 不校验新默认库是否已注册

- **位置**：`f_orm/src/base/ORM.cj:46-54`（`51` 行）、`166-169`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：`fountain-baseline.md` §6「日志走 `f_log`，热点路径不 `println`」、review-checklist §11「边界校验」
- **证据**：静态确定 —— 同文件已有 `LoggerFactory.getLogger<ORM>()`（`37`）与 `log.error`（`153`），只有退出路径用 `printStackTrace`；`deregisterAndReplaceDefault` 直接 `default = newDefault`，不做 `datasources.contains` 检查。
- **描述**：退出阶段关闭失败只打到 stderr，容器/日志采集通常看不到；`deregisterAndReplaceDefault("typo")` 之后所有 `ORM.executor()` 都会在 `datasources[default]`（`187`）上抛底层容器异常（不是 `ORMException("default datasource is not specified")`）。
- **建议**：改为 `log.error('failed to close datasource', e)`；`deregisterAndReplaceDefault` 先 `if (!datasources.contains(newDefault)) { throw ORMException(...) }`。

### [轻微][存量] #18 `ORM_test` 是空用例（唯一一行被注释），且 `protected import …wrap.*` 已无使用者

- **位置**：`f_orm/src/base/ORM_test.cj:20-27`
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §3「空实现」、§1「未使用的 import」
- **证据**：静态确定 —— `@TestCase public func test()` 函数体只有注释 `// topTest()`；`wrap` 包的类型在文件内零引用。
- **描述**：这条用例永远是绿的，`ORM.register` / `deregister` / `executor` 这几条容易出错的路径没有任何回归保护（本部分 #6 / #16 的问题正因如此没被发现）。
- **建议**：补真实断言（注册重复驱动 → 断言只保留一份且 `default` 不变；`deregister` 后 `ORM.executor(name)` 抛明确异常），或删掉这条空用例与无用 import。

### [轻微][存量] #19 死代码：`ORM.driverNames`、`Partials` 的 8 个 `AND/OR/NOT/PAREN` 重载 + 2 个 `append` 重载、`NestQueryMapper.newNest` / `NullableNestQueryMapper.newNullableNest`

- **位置**：`f_orm/src/base/ORM.cj:55-59`；`f_orm/src/base/Partials.cj:28-35`（两个 `append`）、`40-71`（`AND/OR/NOT/PAREN` 各两个重载）；`f_orm/src/base/NestQueryMapper.cj:25-30`、`46-52`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02` / `ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §1「`protected` 除「`public open`/`public abstract` 非 `sealed` 类成员」外无引用即死代码；`internal` 在本包及子包无引用即死代码」
- **证据**：静态确定（全仓搜索，排除 `.worktrees`）——
  - `ORM.driverNames`：`ORM` 是 `public class`（非 `open`/`abstract`），成员是 `protected`，全仓零引用；
  - `Partials` 是 `protected class`（非 public），`grep 'partials\.'` 只命中 `append` / `clear` / `toString` 与 `operator()`（`ExtendString.cj:49` / `53` 两个重载都在用），`AND/OR/NOT/PAREN` 两个重载与 `append(op, sql)` / `append(op, () -> Unit)` 零引用（它们只互相调用）；
  - `newNest` / `newNullableNest`（默认 `internal`）全仓只命中定义，见 #11。
- **描述**：`Partials.AND/OR/NOT` 与 `ExtendString` 的 `'x'.AND` 是同一能力的第二套实现（第 3 部分 #21 已记），保留死分支会让人误以为 DSL 走的是 `Partials`。`ORM.driverNames` 与 `ORM.databasesNames`（`170-174`，返回 `DriverManager.drivers()`）名字相近但语义不同，也容易误用。
- **建议**：删除上述死成员；若 `ORM.driverNames` 是给下游子类的扩展点，请把 `ORM` 声明成 `open class` 并加注释说明用途（否则按基线判死代码）。

### [轻微][存量] #20 `@ORMColumn` 注解在本仓没有任何消费者：标注后不产生任何效果

- **位置**：`f_orm/src/base/ORMColumn.cj:18-21`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3「契约承诺有行为、实现为空」、§14「接线缺失」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）搜 `ORMColumn` 只命中定义本身；`QueryMappersGenerator` 读取的是 `@QueryMappersGenerator` 的属性（`QueryMappersGenerator.cj:240-260` 的 `meta` 来自宏属性），不读字段上的注解；也没有任何 `TypeInfo.getAnnotations` 之类调用。
- **描述**：注解声明了 `name` / `id` 两个参数（`id` 对应 `isId` 语义），看起来是"给字段指定列名 / 标主键"的入口；实际标注在任何属性/变量上都不会改变生成的 mapper（列名仍按 `CaseFormat.Pascal → lower_underscore` 推导）。这会诱导使用者写出"标了没生效"的代码。
- **建议**：要么在 `QueryMappersGenerator` 里读 `MemberProperty/MemberVariable` 的 `@ORMColumn`（`name` 覆盖列名、`id` 置 `isId`），要么删掉该注解。

### [轻微][存量] #21 `waitConnecting` 是无退让的自旋：连接推进慢时独占一个核直到超时

- **位置**：`f_orm/src/base/SqlExecutor.cj:400-408`（`403-407` 循环体只有 `MonoTime.now()` 与超时判断）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，bug-orm.md §3.2 ORM-L9 修复时加了超时，但没加让出）
- **判据**：review-checklist §6.4「低效实现（忙等）」、§8「降 CPU」
- **证据**：静态确定（形态）—— 循环内没有 `sleep` / `yield` / 条件变量，每轮只读 `state` 与时钟；上界由 `ORMConfig.getConnectingTimeout` 决定。**没有线程状态与 CPU 采样数据，故不声称占比**。
- **描述**：池化驱动把连接推进放到后台线程时，调用线程会在这段时间里 100% 占用一个核；并发 N 个请求同时 Connecting 就是 N 个核空转，且 `state` 的读取频率不受控。
- **建议**：循环里加 `sleep(Duration.millisecond * 1)`（或指数退避到 10ms），或改用驱动提供的连接完成回调/条件变量；顺带把 `MonoTime.now()` 改为每 N 轮取一次。

### [轻微][存量] #22 `SqlExecutor` 构造即建连：`ORM.executor(name)` 只取不用时，连接悬挂到线程内下一次 `getInstance` 或线程退出

- **位置**：`f_orm/src/base/SqlExecutor.cj:61-69`（`68` 行 `_connection_ = getConnection(driverName)`）、`113-132`（每线程一份，`close()` 才归还）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「资源生命周期」、§7「缩短生命周期」
- **证据**：静态确定（机制）—— 构造函数直接取连接；`close()` 只在语句执行完（`896-898`）、事务结束（`1101`）、迭代器关闭（`183`）时调用。`RootService.dao<T>()` / `ORM.executor()` 这类"只取实例"的入口不会触发 `close()`。
- **描述**：请求线程调用 `dao<X>()` 但本次没有执行任何 SQL（缓存命中、提前返回、只做校验）时，池里那条连接会一直被该线程持有；线程池长期存活时表现为"空闲连接数 = 线程数"，连接池较小时会挤掉真正要用的请求。是否是问题取决于 `f_dbpool` 的池大小与线程数配置（待确认）。
- **建议**：改为惰性连接（`statement` / `connection` 首次访问时再取），或在 `getInstance` 里对"上次使用时间超过 N 秒"的 executor 主动 `close()`。

## 优化可行性方案

> 不是缺陷，是"还能更好"。每条都必须可执行、可验证。

### [堆内存] 给结果缓存加容量上限与"语句级失效"

- **现状**：`SqlExecutor.cache`（`SqlExecutor.cj:54-56`）在事务内跨语句存活，键是 `(sql, args)`，值是完整结果集；没有容量、TTL、淘汰（见 #8）。对象数 ≈ Σ(每次查询的行数 × 每行对象数)，生命周期 = 整个事务。
- **方案**：`cache` 增加 `maxEntries`（默认 128）与 `maxRows`（按 `ArrayList.size` 累计），超限整体清空；`clearSql()` 时把"上一语句的键"标记为可淘汰（LRU 保留最近 K 条）。
- **预期**：长事务内的常驻结果集从"全部查询之和"降到"最近 K 条"；峰值应显著下降（**无实测**）。
- **代价**：命中率下降（重复查询跨语句时不再命中）；需要新增两个配置项并进 README 的配置表。
- **验证**：mockdb 事务内跑 1k / 10k 次不同 id 的 `first<T>`，对比 `getAllocatedHeapSize()` 峰值与 RSS，并对比总耗时确认没有明显回退（`-O2`，同机，中位数）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 延迟建连 + 空闲 executor 回收

- **现状**：每线程每驱动一个 `SqlExecutor`，构造即取连接（#22）；请求只取 DAO 不执行 SQL 时连接闲置到下一次 `getInstance` 或线程退出。
- **方案**：`_connection_` 初值设为 `NoneConnection.instance`，`connection` 属性首次访问时才 `getConnection`；`getInstance` 里按 `lastUsedAt` 回收超过 N 秒未使用的 executor（`close()` 即可）。
- **预期**：空闲连接数从"线程数 × 驱动数"降到"活跃请求数"（**无实测**）。
- **代价**：首条语句多一次建连/取池开销；需要给 `lastUsedAt` 打点（`DateTime.now()` 每次执行已有 `start`，可复用）。
- **验证**：线程池 200 线程、池大小 20、QPS 由 0 阶跃到峰值，采 `f_dbpool` 的活跃/空闲连接计数与 `pg_stat_activity` 连接数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 三处 40+ 分支的 `Any` 分派合并为一张类型表

- **现状**：`RootDAO.arg(Any)`（`258-306`）、`RootDAO.arg<I,T>`（`333-376`）、`SqlExecutor.add<T>`（`610-653`）各有一份"按运行时类型逐条 `case`"的线性分派，合计约 120 个 `case` 行；绑定热路径上每个参数都要走一遍（含 `?T` 组，最坏命中位置 40+）。三份还必须手工保持同序（注释 `327-332`、`607-609` 明确要求"与另一处保持同步"）。
- **方案**：抽出 `private func bind(exe: SqlExecutor, v: Any): Unit` 单点分派，三处改为调用它；若要进一步降开销，用 `ConcurrentHashMap<TypeInfo, (SqlExecutor, Any) -> Unit>` 做一次查表（类型数有界、可缓存），避免每参数多次 `is` 检查。
- **预期**：单参数分派失败检查次数从"位次"降到 O(1)；对 `IN (10k)` 这类批量绑定应能看到端到端改善（**无实测**，按 `SqlExecutorArgBranches_test` 的注释，历史重排曾把 Int64 的检查次数从 8 降到 1）。
- **代价**：一次哈希查表（可能比 1~2 次 `is` 检查更贵）+ 一张需要维护的类型表；语义必须保持"不支持类型抛 `SqlArgException`"。
- **验证**：`cjpm bench -O2`，对 `IN` 100 / 1k / 10k 元素 + 单参数 `first` 各跑 10 轮取中位数；同时用 `SqlExecutorArgBranches_test` 做等价性回归。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `waitConnecting` 退让

- **现状**：忙等（#21），循环体只有状态读与时钟读，无退让。
- **方案**：`sleep(1ms)` 起步、逐步退避到 10ms；超时判断用预先算好的 deadline，避免每轮 `MonoTime.now()`。
- **预期**：Connecting 期间 CPU 占用从"一核"降到"每秒千次状态读"；对连接建立慢的驱动（建连 50ms+）效果明显（**无实测**）。
- **代价**：连接就绪的发现延迟最多增加一个 sleep 周期（1~10ms）；建连本身远大于这个量级。
- **验证**：mock 一个 `Connecting` 持续 200ms 的连接，采 `cjprof` 的 CPU 占用与该函数的 self time，对比改前改后；同时断言端到端建连耗时增量 < 10ms。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每条 SQL 都跑一次 `Regex.replaceAll` 做空白归一，短 SQL 高 QPS 下占可观 CPU | `f_orm/src/base/SqlExecutor.cj:76` | `blankRegex.replaceAll` 的 self time 占比 | `cjprof record` 跑 10 万次 `setSql`+`first`，看该函数与 `Regex` 相关帧占比是否 >5% |
| 2 | `Any` 入口的线性类型分派是参数绑定的主开销 | `f_orm/src/base/RootDAO.cj:258-306`、`SqlExecutor.cj:610-653` | 绑定阶段耗时占端到端比例 | 分段计时：`IN(10k)` 的 `arg` 总耗时 / 整条语句耗时；`cjprof` 看 `arg`/`add` 系 self time |
| 3 | 缓存键对 `SqlArgs` 求哈希时会把 BLOB 参数整体转字符串，形成等大内存峰值 | `f_orm/src/base/SqlExecutor.cj:27-29`、`wrap/SqlArgs.cj:109-119` | 单次 `hashCode` 的分配量与耗时（按 BLOB 大小） | 用 1MB / 10MB `Array<Byte>` 参数跑一次 `first`，采 `getAllocatedHeapSize()` 与耗时 |
| 4 | DSL 编译缓存命中率低（`dslcache` 10000 条 / 1 天）导致重复 `cangjieLex` | `f_orm/src/base/SqlDSL.cj:45-47` | 命中率 | 在 `compile()` 外挂计数（命中/未命中），跑真实业务 10 分钟 |
| 5 | `groupedList` 每行一次 `LinkedHashMap.get(id, false)` + 分组 `populate` 在 1:N 大结果集上是热点 | `f_orm/src/base/QueryMappers.cj:92-109` | 行数、分组基数、该循环占比 | 造 10 万行 / 1 万分组的 mock 结果集，`cjprof` 看 `groupedList` self time |
| 6 | 事务内结果缓存（#8）在批量任务里是峰值内存主项 | `f_orm/src/base/SqlExecutor.cj:54-56`、`915-917` | 事务内不同键数、结果集总量 | 1k/10k 次 `first<T>` 事务内循环，采 RSS 与 `getUsedHeapSize()` 曲线 |

**范围外提示**（不计入本部分统计）：

1. `DirtyTag` 的"全局 `beforeDirty` + 线程私有 `dirtyFields`"并发丢更新问题见第 3 部分 #3（`DirtyTag.cj:23-79` 与 `SqlExecutor.cj:172`），本部分不重复报，只确认 `SqlExecutor.close()` 是它的触发点之一。
2. `partials` 在字符串拼接路径上"只增不清"见第 3 部分 #10；本部分 `SqlExecutor.clearSql()`（`97-106`）确实不触碰 `partials`，与该结论一致。
3. `TableClause` 的 INSERT 列名列表（`TableClause.cj:441-448`）会把嵌套映射器的空 `columnName` 拼进列清单（`insert into t(a,,b)`），属第 3 部分文件；与本部分 #11 同源（嵌套映射器 `dataType: UnknownDataType(true,'','')`）。
4. README（第 8 部分范围）`f_orm/README.md:388-393` 把结果缓存描述为"读操作按 SQL + 参数缓存，写操作整体清空"，未说明"非事务路径每条语句都清空、只有事务内才命中"；与本部分 #3 / #8 同源。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/base/NestQueryMapper.cj` | .cj | ✅ | 见 #11（`newNest` / `newNullableNest` 死代码、nullable 语义缺实现）；`populate` 的 `nested.map` 每行重建嵌套对象，属设计 |
| 2 | `f_orm/src/base/NoneConnection.cj` | .cj | ✅ | 内部类的 `Connection` 接口实现（`getMetaData` / `prepareStatement` / `createTransaction` 抛 `IllegalAccessException`）属父类契约实现，不判死代码；`close()` 空体 + `isClosed()` 恒真与 `_connection_` 哨兵语义一致 |
| 3 | `f_orm/src/base/ORM.cj` | .cj | ✅ | 见 #16（register 重载漂移）、#17（退出日志/默认库校验）、#19（`driverNames` 死代码）；`register()` 的 mockdb 分支 `138-143` 用 `for + return` 表达"只注册 mockdb"，逻辑成立但可读性差；`databasesNames` 返回 `DriverManager.drivers()` 与名字不符（信息） |
| 4 | `f_orm/src/base/ORMColumn.cj` | .cj | ✅ | 见 #20（注解无消费者） |
| 5 | `f_orm/src/base/ORMInitializer.cj` | .cj | ✅ | 结构体 `Initializer` 实现，`register` + `dependencies = ['fountain::f_bean']`；`initialize()` 直接转 `ORM.initialize()`，无问题 |
| 6 | `f_orm/src/base/ORM_test.cj` | .cj | ✅ | 见 #18（空用例 + 未使用 import） |
| 7 | `f_orm/src/base/Pagination.cj` | .cj | ✅ | 见 #9（`size == 0` 除零、`page < 1` 负 offset）；`dataFields` 的 `creator` 直接抛 `IllegalAccessException`（只读对象，`fromData` 不可用），未在注释里说明 |
| 8 | `f_orm/src/base/Partials.cj` | .cj | ✅ | 见 #19（10 个死成员）；`toString()` 依赖"末表达式推断返回类型"返回 `String`，`TableClause.cj:140` 按 `sql.size` 使用，成立 |
| 9 | `f_orm/src/base/QueryMapper.cj` | .cj | ✅ | `new<T>()` 的重绑定是 `create` 的唯一路径（见 #11）；`get<T>` 的三分支 `match` 覆盖 `T` / `?T`，无缺陷 |
| 10 | `f_orm/src/base/QueryMapperConverter.cj` | .cj | ✅ | 两个 JSON 转换器；`convert` 读流不关（注释 `49-51` 说明所有权），`lookup` 的 `computeIfAbsent` 以类型名缓存、键有界；未发现问题 |
| 11 | `f_orm/src/base/QueryMappers.cj` | .cj | ✅ | 见 #1（`create` 索引错位）、#11（`create` 走 `new<T>()`）；`groupedList` 的 `map.get(id, false)` 是 `LinkedHashMap` 的"不触 LRU"重载，用法正确 |
| 12 | `f_orm/src/base/QueryMappersInit.cj` | .cj | ✅ | 接口 + 17 个 `extend … <: SimpleDataQueryMappersInit`；`SimpleDataQueryMappersInit.queryMappers()` 抛 `"not supported"` 由 `isSimpleData()` 守卫（`SqlExecutor.cj:542/567/588/600`），属契约，不是空实现 |
| 13 | `f_orm/src/base/QueryResultIterator.cj` | .cj | ✅ | 见 #7（映射异常不释放）；`close()` 的 `result → statement → releaseActiveQueryResult` 顺序与注释一致，兜底正确 |
| 14 | `f_orm/src/base/QueryResultIterator_test.cj` | .cj | ✅ | 5 条用例覆盖"返回后可读/事务内只关结果集/活动结果集拒绝新查询/try-with-resources/按列名取值"；未发现问题 |
| 15 | `f_orm/src/base/QueryResult_test.cj` | .cj | ✅ | 见 #14（`getOrNull` 恒抛、`isClosed` 恒 false、双行计数） |
| 16 | `f_orm/src/base/RootDAO.cj` | .cj | ✅ | 见 #10（集合绑定缺 `Data` 分支、三份分支表漂移）；`arg<I,T>` 的 `"?" * (n-1)` 拼装与 `ArgSqlText_test` 的 `' (?,?)'` 口径一致；`SqlFunc.toString` 的异常文案写成 "alias and SqlFunc alias"（复制残留，轻微） |
| 17 | `f_orm/src/base/RootService.cj` | .cj | ✅ | `dao<T>` 依赖"SqlExecutor 被扩展成 DAO 接口"的运行时类型测试；两个 `dao` 重载只差 driver 参数，`executor(name)` 已把空串归一，属可合并的薄封装（不单独报） |
| 18 | `f_orm/src/base/SqlDSL.cj` | .cj | ✅ | 见 #2（集合参数双占位符）、#4（`:{…}` 解析条件恒真）；`compile` 缓存 10000 条 / 1 天，键为 DSL 文本，有界 |
| 19 | `f_orm/src/base/SqlExecutor.cj` | .cj | ✅ | 见 #3（缓存别名）、#5（`readOnly` 不复位）、#6（`current` 单槽）、#8（事务内缓存无界）、#12（无事务静默）、#13（新连接泄漏）、#15（缓存键可变）、#21/#22；`execute` 的 `activeQueryResult` / `handedOver` / `mustClose` 三态与 `QueryResultIterator_test` 的断言一致，异常路径的资源释放核对无误 |
| 20 | `f_orm/src/base/SqlExecutorArgBranches_test.cj` | .cj | ✅ | 反向例（`TransactionStatus.Unknown` → `SqlArgException` / `toString` 兜底）与正向 21 个类型的分支护栏成立；`52` 行注释确认"executor 与结果缓存按线程复用" |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 #1 / #2 / #3 / #7 / #9 / #10 / #11 / #12 / #14 / #15；设计 #5（语句级状态与事务级状态混用）、#6（线程内隐藏 executor）；安全性：参数绑定统一走 `arg(...)` / `?`，未发现字符串插值外部输入（`SqlPartial` / `TableClause` 的拼串都是标识符与常量）；语言特性：#5 的 `Option` 静默丢弃、#10 的类型模式分派 |
| §1 死代码 | 1 | #19（`ORM.driverNames` 1 个 + `Partials` 10 个 + `newNest`/`newNullableNest` 2 个，全仓搜索确认零引用）；另核对：`NoneConnection` 的 3 个抛异常方法是 `Connection` 接口实现（豁免）、`QueryMapper.new` / `isGrouped` / `isId` 是 `public open class` 的 protected 扩展点（豁免）、`QueryMappers.idName` 被 `TableClause.cj:283+` 使用、`QueryMapperConverter.lookup` 被宏（`QueryMappersGenerator.cj:289+`）使用、`SqlExecutor.releaseActiveQueryResult` 被迭代器使用、`SqlDSL` 的 private 分片类型全部有构造点 |
| §2 重复逻辑 | 2 | #10（三份 40+ 类型的 `Any` 分派，且 `Data`/`?Any` 分支不一致）、#16（6 个 `register` 重载的同一段前置检查，日志口径不一致）；另核对：`RootService.dao` 两个重载是薄封装、`SqlExecutor.update`/`delete` 共用 `updateOrDelete`、`singleFirst`/`singleList` 的 index/column 变体差异在 `get` 的重载，均属刻意展开，不判重复 |
| §3 空实现 | 2 | #14（测试替身的 `close` 空体 + `isClosed` 恒 false，且 `getOrNull` 恒抛）、#18（空 `@TestCase`）；`NoneConnection.close()` 是哨兵对象的正确 no-op（`state == Closed`），`DummyTransaction` 的空实现是传播语义（`begin` 里按 mode 抛错），均不算 |
| §4 栈溢出 | 0 | 唯一自递归是 `SqlExecutor.connection`（`409-431`）与 `DirtyTag` 的二层自递归：`connection` 只在 `_connection_ is NoneConnection` 时重新取连接再递归一次，`NamedDatasource.connect()` 恒返回 `ConnectionWrap`（`wrap/NamedDatasource.cj:47-49`），深度 ≤ 2；`RootDAO.arg(?Any)` → `arg(Any)` 的递归每层剥一层 `Option`，层数由调用方写死的嵌套决定，无环 |
| §5 OOM | 1 | #8（事务内结果缓存无容量上限、不随语句释放）；另核对：`SqlDSL.compile` 的 `HeapCache` 有 `maxSize: 10000` / 1 天过期（有界）、`rollbackExceptions` 以配置字符串为键（有界）、`list`/`mapList` 的全量物化是 API 语义本身 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据：`blankRegex.replaceAll`、`Any` 分派、`SqlArgs` 哈希、DSL 编译缓存、`groupedList` 五条疑似热点全部进「待验证假设」，不作缺陷、不进 tasks |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / `ReentrantLock`；并发面只有 `ThreadLocal`（`currents` / `current`）与 `ConcurrentHashMap`（`ORM.datasources` / `QueryMapperConverter.converters` / `SqlExecutor.rollbackExceptions`），不存在「锁内 I/O / 锁内回调」形态 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；executor 线程封闭，事务内"单连接串行"是数据库会话的固有约束，不是可并行化的串行段 |
| §6.4 低效算法 | 1 | #21（Connecting 忙等无退让）；另核对：`isSelectStatement` 是 O(1) 前缀判断、`arg<I,T>` 的占位符已改为一次 `"?" * (n-1)`、`groupedList` 用 `LinkedHashMap` O(1) 取行 |
| §7 降堆内存方案 | 2 | 结果缓存上限（#8 的对应方案）、延迟建连 + 空闲 executor 回收；`partials` 的降内存方案已在第 3 部分给出，本部分不重复 |
| §8 降 CPU 方案 | 2 | `Any` 分派合并为类型表、`waitConnecting` 退让；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有"函数内创建、函数内用完的大临时对象"：结果集、映射对象、缓存值都要逃逸出函数（返回给调用方或存进 `cache`）；`SqlDSL.compile` 的中间 `Tokens`/`ArrayList` 会被 `HeapCache` 长期持有，也不满足"函数返回即释放"。收益只能靠峰值内存对照证明，当前无数据 ⇒ 不列方案 |
| §11 现有代码的 BUG（存量） | 22 | 本部分 22 条发现全部为存量（快照无 diff）：逐条核对了 `Pagination` 的除法/offset、`SqlDSL` 的两处循环与占位符、`QueryMappers.create` 的数组下标、`SqlExecutor` 的状态位（`readOnly` / `activeQueryResult` / `hasRealTx` / `clearCache`）、`ORM` 的注册与默认库切换、5 个文件的 `Option` 使用点（`commit`/`save`/`release`/`current.get()`/`tx?.`）；`hasRealTx` 不复位经核对不构成泄漏（`close()` 会丢弃整个 executor 实例） |
| §12 并发安全与锁粒度 | 2 | #6（线程内 `current` 单槽被跨驱动覆盖/清空，共享路径是 `ThreadLocal` 单槽 + 所有 SQL 构造点）、#7（`activeQueryResult` 在异常路径不复位，`SqlExecutor` 线程封闭但状态机不自洽）；`DirtyTag.clearAll()` 的跨线程污染属第 3 部分 #3（同源，已交叉引用）；`ORM.datasources` 用 `addIfAbsent` 的检查-然后-写入已核对：`Driver` 重载的 "contains → register" 是竞态窗口，但最终由 `addIfAbsent` 兜住（表现为 #16 的静默丢弃），未造成重复注册 |
| §14 功能完备性与 README 覆盖 | 2 | #4（README:822 承诺的 `:{a.b.c}` 不可用）、#11（嵌套映射器的 `newXxx` 未接线、nullable 语义未实现）；README 其余段落不在本部分文件清单内，`public` 声明与 README 的逐项对照留给第 8 部分 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完，无 `.md` ⇒ §13 文档一致性主体不在本部分，只在 #4 / #20 处引用了 README 与宏作为承诺源 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 12 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分的代码质量呈"两段式"：`SqlExecutor` / `QueryResultIterator` 明显经过一轮 bug.md 修复，`activeQueryResult` 三态、`handedOver`、`Statement` 所有权移交、`clearSql` 换实例这些细节都有注释和用例钉住，异常路径的资源释放核对下来是自洽的；问题集中在**没有被用例覆盖的旁路**——子类型映射（`QueryMappers.create`）、SQL DSL（`setSqlFromObject` / `setSqlFromMap` 全仓零调用）、事务内结果缓存，以及几处"状态位只置不复位"（`readOnly`）和"线程内单槽"（`current`）。

阻塞项建议按此顺序处理：#1（继承映射必崩）、#2（集合参数占位符翻倍，DSL 一用就错）、#3（缓存返回共享可变实例，事务内读到脏副本）。三者都属于"下游一用就出事、仓内没有用例"的类型，修完应各补一条回归。其余一般项可以排期：#5 / #6 / #7 是状态机与生命周期的小修，#8 / #9 / #10 / #11 / #12 / #13 是边界与降级语义，#15 需要先确认 `clearArgsAfterExec: false` 的真实时序。

死代码与重复逻辑各有一处集中点（`Partials` 的 10 个死成员、三份 40+ 类型分派表），清理成本低但要连同 `ExtendString` 的重复实现一起决策，建议在第 3 部分 #21 的结论出来后一并处理。

存量 22 条，是否纳入修复待用户决定。
