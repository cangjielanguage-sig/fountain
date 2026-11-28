# f_orm 模块审查报告

> **模块第 3/8 部分**（本报告只覆盖 `files/f_orm.part3.txt` 列出的 20 个文件，全部是 `src/base/` 下的 `.cj`：`ArgInSql_test` → `MeetCondition`，其中 8 个 `_test.cj`。模块共 111 `.cj` + 11 `.md`，其余文件由第 1、2、4–8 部分产出；本部分编号独立，合并时以主 Agent 为准。README / `doc/**` 不在本部分，只在需要取证时被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（本部分 20 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，无源码 diff ⇒ 全部问题记「存量」；`git blame` 抽样落在 `9fe28abd50 2026-09-13` / `e494170cc4 2026-09-15` 等旧提交）
- **审查重点**：executor 生命周期与线程内复用语义、连接与事务、SQL 注入与参数绑定、大粒度锁、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 3/8 部分）

本部分实际内容是 **SQL 片段构造层**：条件构建器（`MeetCondition` / `LoopCondition` / `ChooseCondition`）、表达式树（`LogicalExpr` 家族 / `Column` / `SqlExpr`）、方言与标识符引用（`Dialect`）、脏字段标记（`DirtyTag`）、分组映射器（`GroupedQueryMapper`）以及 8 个测试文件。这一层的共同特征是**在 `toString()` / `done()` 里产生副作用（把参数绑进线程内 executor）**，本部分 3 条严重缺陷全部来自这个设计。

## 发现

### [严重][存量] #1 `ParenExpr.toString()` 对内层表达式求值两次：参数被重复绑定，占位符与参数数量失配

- **位置**：`f_orm/src/base/LogicalExpr.cj:252-258`（`253` 行 `let s = expr.toString()`、`257` 行 `return '(${expr})'`）；构造入口 `f_orm/src/base/RootDAO.cj:509-510`、`515-516`、`521-522`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`，`253-256` 为 `e494170cc4 2026-09-15` 追加）
- **判据**：review-checklist §11「逻辑错误」、§10「正确性」、§2「近似重复导致的行为漂移」（`ParenExpr` 用 `isEmpty()`、其它处用 `emptyLogicalExpr`，见 #17 说明）
- **证据**：静态确定 —— `CmpExpr.toString()`（`125-155`）在 `136` / `144` 行调用 `exec.arg(...)`，而 `arg` 的实现是「`executor.add(x)` + 返回 `?`」（`RootDAO.cj:330-332` 的注释原文：`arg(x)` 内部是 `executor.add(x)` 并返回 `'?'`），即 **`toString()` 不是纯函数**。`ParenExpr.toString()` 先 `expr.toString()` 取一次用于判空，再在 `257` 行用插值 `${expr}` 取第二次 ⇒ 内层每个比较值被 `add` 两次。`RelationExpr.toString()`（`227-249`）内部也是逐子表达式 `toString()` 一次，所以 `ParenExpr(RelationExpr(...))` 会把整棵子树的参数全部绑定两遍。
- **描述**：`RootDAO.AND(exprs: () -> Array<LogicalExpr>)` / `OR` / `NOT` 三个 lambda 变体（`509-522`）都包了一层 `ParenExpr`，这层包装是 DAO DSL 的对外能力（`RootDAO` 是 `public interface`，仓内 `grep 'AND {'` 零命中，说明这条路径交给下游使用、没有回归用例）；只要 DAO 方法里写了 `AND { [user.age.gt(18), user.name.eq('x')] }`，最终 SQL 得到 `( age > ? AND name = ? )` 两个占位符，而 `args` 里是 4 个值（18、'x'、18、'x'），第一次执行就会因参数个数不匹配报驱动错误；若驱动按位置宽松绑定，则第 3、4 个参数会与后续谓词的占位符错位，**静默查错数据**。同一根因还让该 DSL 无法缓存/重放 SQL 文本（每次 `toString` 都在改参数表）。
- **建议**：`ParenExpr.toString()` 只求值一次：`let s = expr.toString(); if (emptyLogicalExpr(s)) { '' } else { '(${s})' }`（同时把空判断口径统一成 `emptyLogicalExpr`，与 `RelationExpr:239` 一致）。更彻底的做法是把表达式求值改成「一次遍历产出 (sqlText, args)」的纯函数、由执行器统一绑定，`toString()` 只读缓存结果；短期至少要给出「表达式对象只允许 `toString()` 一次」的约束并加用例（`AND { [col.gt(1)] }` 断言 `args.size == 1`）。

### [严重][存量] #2 `BETWEEN` 的一侧是 `Column`、另一侧是值时，`Column` 被当作**字符串值**绑进参数

- **位置**：`f_orm/src/base/LogicalExpr.cj:130-139`（`133-136` 行只区分了「两边都是 `Column`」与「其它」）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误 / 契约与实现不符」、§10「正确性」
- **证据**：静态确定 —— `CmpExpr.toString()` 的 BETWEEN 分支只写了两个 case：`case (x: Column, y: Column)` 走「裸列名」，其余全部落到 `case _ => ' ${column} ${op} ${exec.arg(x[0])} AND ${exec.arg(x[1])} '`（`136` 行）。而 `Column <: SqlExpr & ToString`（`Columns.cj:100`），`SqlExecutor.add(arg: Any)` 对 `ToString` 走 `add<ToString>(x)` → 最终 `case x => add(x.toString())`（`SqlExecutor.cj:610-653`、`859-866`），即把 `Column.toString()` 的结果（形如 ` "price" `，带引号的列名文本）当成**绑定值**加进 `args`。
- **描述**：`SqlExpr.BETWEEN(one: Any, two: Any)`（`Columns.cj:87-89`）的签名允许任意组合，且实现专门为「两边都是列」留了分支，说明「列参与 BETWEEN」是设计意图；于是 `price.BETWEEN(cost, 100)` 这种最自然的写法（上界常量、下界来自另一列）不会被编译器拦住，却生成 `price BETWEEN ? AND ?` 并绑定 `'"cost"'` 字符串，语义从「与另一列比较」变成「与字符串 `"cost"` 比较」——多数数据库会直接报类型错，宽松类型（SQLite）则静默返回错误结果集。仓内 `grep '\.BETWEEN('` 只命中文档注释（`macros/DAO.cj:67`），这条路径同样无回归用例。
- **建议**：把 BETWEEN 的两个操作数都按 `SqlExpr` 分流（`case x: SqlExpr => '${x}'`，否则 `exec.arg`），与 `CmpExpr` 的 `case _ => match(value) { case x: SqlExpr => ... }`（`141-145`）保持同一套规则；或直接提供 `BETWEEN(one: SqlExpr, two: Any)` / `BETWEEN(one: Any, two: SqlExpr)` 重载让类型系统兜住。补两条用例：`(Column, Int64)` 与 `(Int64, Column)`。

### [严重][存量] #3 `DirtyTag.beforeDirty` 是**进程级共享**布尔、脏字段表却是线程私有的，`clearAll()` 只清当前线程：并发读+关闭会丢更新，导致 `UPDATE ... dirty` 静默漏写

- **位置**：`f_orm/src/base/DirtyTag.cj:23`（`DIRTY_TAGS` 全进程共享）、`26`（`dirtyFields` 是 `ThreadLocal`）、`50-58`（`setBeforeDirty` 读旧值再整体替换）、`72-79`（`clear<T>` / `clearAll`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入」、§11「并发正确性」
- **证据**：静态确定 —— 三条互相印证的事实：
  1. `beforeDirty` 是 `DirtyTag` 的普通 `let` 字段（`25`），`DirtyTag` 以 `TypeInfo` 为键存进 `ConcurrentHashMap`（`23`），所有线程读写同一个条目；
  2. `setBeforeDirty<T>()`（`50-58`）是「`get` → 读 `tag.beforeDirty` → 构造新 `DirtyTag` → `DIRTY_TAGS[typeInfo] = 新值`」的**非原子读改写**；`clear(typeInfo)`（`66-71`）结构相同（写入 `beforeDirty: false`）；
  3. 两者唯一的调用点是按线程执行的 `SqlExecutor`：`setBeforeDirty` 在 `first<T>` / `list<T>` 的 `finally`（`SqlExecutor.cj:537`、`562`），`clearAll` 在 `close()`（`SqlExecutor.cj:172`）——每个线程在请求结束各自 close 一次。
- **描述**：`SqlExecutor` 是线程封闭的（`currents` / `current` 都是 `ThreadLocal`，`SqlExecutor.cj:44-45`），但 `DirtyTag` 的「是否已开启脏跟踪」开关是全局的。两种坏交错都有实际后果：(a) 线程 A `close()` 的 `clearAll` 与线程 B 读完结果集后的 `setBeforeDirty<T>` 并发，B 的写入可能被 A 的替换覆盖 ⇒ B 后续对该类型对象的 setter 不再记录脏字段，`UPDATE<T>(..., dirty: true)` 读到空集合直接 `return 0`（`SqlPartial.cj:226-231`）——**对象改了、SQL 一条没发**；(b) 反向丢失 `clear` ⇒ 跟踪开关永久开着，且 `clear` 只执行 `tag.dirtyFields.set(None)`（`68`），**只清调用线程的 `ThreadLocal`**，其它线程的旧脏字段集合原样保留，下一次「读 → 改两个字段 → UPDATE dirty」会把上一轮残留的字段一起写回。`ThreadLocal` 与共享布尔混用使这套状态无法用单把锁简单修好。
- **建议**：把 `beforeDirty` 也收进 `ThreadLocal<Bool>`（与 `dirtyFields` 同生命周期，语义变成「本线程是否已为 T 开启跟踪」），`clearAll` 只清本线程；若必须保持「类型级一次性开关」，则改用 `ConcurrentHashMap.compute` / CAS 做原子替换，并把 `dirtyFields` 的 `set(None)` 改成「按线程注册表遍历清理」或直接换成 `ThreadLocal.withInitial`+显式 `remove`。补用例：两线程各自 `first<T>()` 后各自改字段，再各自 `UPDATE dirty:true`，断言两次更新的列集合互不含对方字段。

### [一般][存量] #4 `ChooseCondition` 在非 `argInSql` 路径**无条件**绑定参数：片段型 `partial` 多出 `"()"` 参数与悬空 `?`，未设 `otherwise` 时多出 `? `

- **位置**：`f_orm/src/base/ChooseCondition.cj:80-105`（`91-93` 与 `102-104` 两个 `else` 分支）、默认兜底 `22`、`54-59`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误 / 空值未处理」、§3「契约与实现不符」
- **证据**：静态确定 —— `gen()` 的四个分支里，只有 `_argInSql == true` 且 `arg` 是 `ToString` / `Unit` 时才「不绑定、只拼片段」；`_argInSql == false` 时无论 `arg` 是什么都执行 `executor.add(arg)` 并输出一个 `?`。两条具体路径：
  - `partial(partial: () -> String)` 经 `callee`（`57-59`）包装成 `('片段', ())`，`arg` 是 `Unit`；`Unit` 实现 `ToString`（`cangjie-doc/md/doc/core.md:29`），于是 `add(())` 落到 `SqlExecutor.cj:652` 的 `case x => add(x.toString())`，把字面量 `"()"` 绑进参数；
  - `otherwise` 未设置时取 `emptyPartial = {=> ('', '')}`（`22`），`frag` 为空、`arg` 为 `''`，走 `102-104` 行 ⇒ 输出 ` ? `（无左侧列名）并把空串绑进参数。
- **描述**：`partial(() -> String)` 与 `otherwise(() -> String)` 两个重载是公开 API，语义只能是「只提供 SQL 片段、不带值」；但在默认（参数化）模式下它们必然多生成一个占位符，例如 `choose.condition{...}.partial{'1 = 1'}.done()` 产出 `1 = 1 ?`、参数多一个 `"()"`，语句直接失败；忘记写 `otherwise` 时产出 `and ?`（绑定空串），要么语法错，要么被当成恒真/恒假谓词改变过滤结果。测试 `ArgInSql_test.cj:161-183` 只覆盖了 `argInSql` 打开的情况，等于把这个失败路径排除在回归之外。
- **建议**：`gen()` 里按「片段是否自带值」分支，而不是按 `argInSql` 分支：`arg` 为 `Unit` 时只 `' ${frag} ${delimiter} '`、不 `add`；`frag.isEmpty() && arg 为空串` 时整体返回 `''`（而不是 `' ? '`）。补两条用例：不带 `argInSql` 的 `partial{'1 = 1'}` 与不设 `otherwise` 的 `choose`，断言 SQL 无多余 `?` 且 `args.size == 0`。

### [一般][存量] #5 `LoopCondition` 传给 `condition` / `partial` 的 `Int64` 是「已接受元素个数」，不是元素下标

- **位置**：`f_orm/src/base/LoopCondition.cj:88-112`（`90` 行 `var i = 0`、`91` 行 `for (v in values where _condition(v, i))`、`111` 行 `i++`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「语义与命名不符 / 边界」、§10「正确性」
- **证据**：静态确定 —— `where` 子句在每次迭代**先于**循环体求值，而 `i++` 在循环体末尾（`111`），被 `where` 过滤掉的元素不会让 `i` 前进。因此 `_condition(v, i)` 收到的 `i` 等于「此前通过条件的元素个数」，而不是「当前元素在 `values` 中的位置」；`_partial(v, i)`（`95`）同理。
- **描述**：参数名是 `i`、类型是 `Int64`，任何按「下标」使用的写法都会得到错误结果，而且是**静默**的：`condition {v, i => i >= 2}`（想跳过前两条）永远在 `i == 0` 上判定，一条也进不来 ⇒ 生成的 `WHERE` 少了整段条件，查询范围变大；`partial {v, i => ('c${i} = ?', v)}`（按下标取列）在有任何元素被过滤后会错位到别的列上。`ArgSqlText_test.cj:54` 的 `anyPartial = {v, i => i}` 正是把它当下标用（该用例全靠所有元素都通过才成立）。
- **建议**：把计数与下标分开：`for ((idx, v) in values.iterator().enumerate())` 或手工 `while` + `let cur = i; i++` 放在 `where` 判定**之前**；若确实想保留「已接受个数」语义，就把形参改名 `acceptedCount` 并在 README 写清。补用例：`[1,2,3,4]` + `condition {v, i => i != 0}`，断言只输出第 2–4 个元素且 `partial` 收到的是 1、2、3。

### [一般][存量] #6 `IN` / `loop` 两端都没处理：0 个元素生成 `in ()`（语法错误），N 个元素没有上限（占位符串与参数表随输入线性膨胀）

- **位置**：`f_orm/src/base/MeetCondition.cj:72-111`（`74`/`94` 行先写 `' in ('`，循环体内无「空则整体返回空」），`f_orm/src/base/LoopCondition.cj:85-116`（`115` 行无条件拼 `wrapLeft`/`wrapRight`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`、`e494170cc4 2026-09-15`）
- **判据**：review-checklist §11「空集合未处理」、§5「OOM：无界容器 / 无拒绝路径」
- **证据**：静态确定 —— `MeetCondition.IN(空集合)`：`i` 恒为 0，`builder` 得到 `' in ('` + `')'` = `' in () '`，`frag()` 再拼成 `'<partial>  in ()  '`。`LoopCondition(空集合).wrap('(', ')').done()`：`sqlFrag` 经 `Condition.trim('','')` 变成单个空格（`ConditionTrim_test.cj:61` 断言 `trim('') == ' '`），再被 `115` 行拼成 ` (   ) `。两者都不是合法 SQL，而且**没有**像 `RootDAO.IN`（`RootDAO.cj:447-453`）那样在空集合时返回 `''`。上限方面：元素逐个 `executor.add` + 逐个 append `?`（或 `StringBuilder`），全流程无计数、无阈值、无分批。
- **描述**：`ex.meet(cond, 'id').IN(ids)` / `ex.loop(ids)....done()` 是公开写法，`ids` 常来自上游查询结果（可能为空，也可能上万）。空集合时 SQL 变成 `id in ()`，语句失败；元素很多时，一条语句的占位符文本与 `SqlArgs` 同步线性增长，既可能撞数据库的参数个数上限（PostgreSQL 65535、SQLite 999 之类），也会在驱动侧一次性物化全部绑定值——没有任何「拒绝/分批」路径。仓内 `IN(empty)` 有用例（`ArgSqlText_test.cj:65` 断言 `ex.arg(empty) == ''`），但 `MeetCondition.IN` / `LoopCondition` 这两条路径没有用例。
- **建议**：空集合统一返回 `''`（与 `RootDAO.IN` 对齐，交给外层 `Condition.trim` 裁掉）；给出可配置的分批阈值（如 `ORMConfig.maxInSize`，超过则拆成多个 `OR id in (...)` 或临时表），并在超限时抛明确异常而不是拼一条超长 SQL。补空集合与 10k 元素两条用例。

### [一般][存量] #7 `NullableGroupedQueryMapper.populate` 的 `prevSize == list.size` 恒为假：`ignoreNone: false` 承诺的 `None` 元素永远不会写入

- **位置**：`f_orm/src/base/GroupedQueryMapper.cj:90-104`（`92` 行取 `prevSize`、`95` 行无条件 `list.add(groupedValue)`、`100` 行判 `prevSize == list.size`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §1「恒真恒假分支」、§11「逻辑错误」、§3「契约与实现不符」
- **证据**：静态确定 —— `add` 在 `95` 行先执行，判定在 `100` 行，此时 `list.size` 必然等于 `prevSize + 1`，条件恒假；`ignoreNone` 只影响这个死分支，`let ignoreNone!` 事实上没有可观察效果。宏侧确实按 `ignoreNone: false` 生成这个映射器（`f_orm/src/macros/QueryMappersGenerator.cj:294-299`，可空实体列表且无转换器时）。
- **描述**：可空的分组关联（`ArrayList<?Entity>`）在左连接结果全为 NULL 时，期望得到 `[None]`（这正是 `ignoreNone: false` 的字面语义），实际得到「一个所有字段都为 `None` 的空实体」并被无条件追加。调用方据此判断「有没有关联记录」会永远得到「有」，属于静默的语义错误；而 `ignoreNone: true` 时则应当丢弃整组，当前实现同样做不到（只是恰好没写 `None`）。
- **建议**：按「本组是否有任一列非 NULL」判定：先把 `mappers` 的取值结果收集起来（`mapper.dataType.get(result)`），全为 `None` 时 `if (ignoreNone) return o else list.add(None)`，否则才 `creator()` + 逐字段写。补用例：驱动返回一行全 NULL 的左连接结果，断言 `ignoreNone=false` 得到 `[None]`、`=true` 得到 `[]`。

### [一般][存量] #8 `InExpr` / `In2Expr` 用 `Column.name` 直出，绕过标识符引用与表别名

- **位置**：`f_orm/src/base/LogicalExpr.cj:175-181`（`178` 行 `' ${x.name} ${op} ...'`）、`190-196`（`193` 行同）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「语义与命名不符 / 与同族实现漂移」、§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— 同文件的 `CmpExpr`（`135-144`）用 `${column}`（走 `Column.toString()`，内部 `exe.involve(...)` 加引号并带 `tableAlias_`，`Columns.cj:120-143`），而 `InExpr` / `In2Expr` 专门 `match` 出 `Column` 后取 `x.name` 原始字段名；`case x =>` 分支才用 `${x}`。
- **描述**：`user.name.IN(list)` 生成 ` name IN (?,?) `：没有方言引号（MySQL 下 `order`、`key` 这类列名直接语法错），也没有表别名（多表 join 时列名歧义 → 报错或解析到另一张表）。同一文件里两种取列方式并存，说明这是遗漏而非设计。
- **建议**：两个 `match` 分支合并为 `' ${x} ${op} ${exec.arg<...>(value)} '`（`Column.toString()` 已处理 `*`、别名、排序与引用）；若要保留「不带排序/别名」的语义，应显式调 `executor.involve(x.name)` 而不是裸 `name`。补用例：`Column('order').IN([1,2])` 断言输出含方言引号。

### [一般][存量] #9 executor 生命周期耦合：`toString()` 阶段就从**线程内 current executor** 取连接并绑定参数，跨线程构造 SQL 或跨语句复用构建器会静默绑错

- **位置**：`f_orm/src/base/Columns.cj:102-106`（`Column.executor` → `SqlExecutor.getCurrent()`）、`120-143`（`toString` 内 `exe.involve`）、`f_orm/src/base/LogicalExpr.cj:129`/`144`/`148`（`ExprSqlExec()` + `exec.arg` + `getCurrent()`）、`f_orm/src/base/ExtendString.cj:26-31`（`getCurrent().partials`）
- **来源**：存量（快照无基线；`git blame`：`9fe28abd50 2026-09-13` / `e494170cc4 2026-09-15`）
- **判据**：review-checklist §11「契约与实现不符」、§10「设计合理性 / 仓颉语言特性」、`fountain-baseline.md` §2「不跨语句复用 `SqlExecutor`」
- **证据**：静态确定（机制）+ 待确认（是否有跨线程构造 SQL 的调用方）—— `SqlExecutor` 按线程隔离（`SqlExecutor.cj:44-45` 的 `currents` / `current` 都是 `ThreadLocal`，`133-135` 的 `getCurrent()` 取不到就 `getOrThrow` 抛 `NoneValueException`）；而 `Column.toString()` / `CmpExpr.toString()` / `String.AND|OR|NOT` 三个入口都在**字符串化时**读取 current 并往它的 `args` / `partials` 写入。
- **描述**：两条现实风险：(a) 在 A 线程拼好 SQL 文本、在 B 线程 `setSql(...).list()` 执行——参数落在 A 的 executor 上（A 若无 current 则直接抛 `NoneValueException`），B 执行时占位符无值；(b) 先 `ORM.executor()` 拿到 `ex`、`ex.close()` 归还连接后，再让 `Column` / `ExtendString` 参与字符串拼接，`add` 会写进已关闭实例的 `args`（`close()` 只清 `current` 与 `currents` 映射、`cache`，不清 `args`，见 `SqlExecutor.cj:153-174`），下一个 `executor()` 是**新实例**，参数丢失。本模块自己也把「单条语句执行后 current 会被清空、每次操作重新 `executor()`」写进基线，说明这条约束客观存在，但构造层没有把它显式化（参数藏在 `toString()` 里，调用方看不出来）。
- **建议**：把「求值」与「绑定」拆开：表达式树只产出 `(sql, Array<Any>)`，由执行器在 `setSql` 后统一 `add`；短期至少在 `getCurrent()` 失败时抛带上下文的 `ORMException('SQL 片段必须在持有 executor 的线程内构造')`，并在 README 写明「片段构造与执行必须同线程、同一语句生命周期」。

### [一般][存量] #10 executor 的 `partials` 缓冲在字符串拼接路径上**只增不清**：长事务内随语句数累积

- **位置**：`f_orm/src/base/MeetCondition.cj:41-49`（`47` 行 `executor.partials.append(sql)`）、`f_orm/src/base/ChooseCondition.cj:113-115`（`114` 行同）、`f_orm/src/base/ExtendString.cj:29-31`；对照「唯一的清理点」`f_orm/src/base/TableClause.cj:136-146`、`191-199`、`208-217`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §5「长期持有 / 无界容器」、§7「缩短生命周期」
- **证据**：静态确定 —— `Partials` 内部是一个 `StringGenerator`（`Partials.cj:19`），`clear()` 只在 `TableClause.condition` / `PAREN` 的 `try/finally` 里调用；`SqlExecutor.clearSql()`（`97-106`）只重置 `sql_` 与 `args`，**不动 `partials`**；`close()`（`153-174`）同样不清（且事务中 `close()` 直接 `return`，`154` 行的守卫）。三个 `append` 点（`MeetCondition.frag`、`ChooseCondition.done`、`String.AND/OR/NOT`）都发生在普通 `setSql` 拼接路径上。
- **描述**：每次 `meet(...).done()` / `choose...done()` / `'x' AND 'y'` 都会把一段 SQL 追加进该线程 executor 的 `StringGenerator`，而这条路径没有对应的释放点。非事务语句结束时实例被 `close()` 摘出 `currents`，随 GC 回收（只是白留一份）；**事务内** `close()` 被 `tx.isNone()` 挡住，同一个 executor 贯穿整个事务，于是「事务里跑了 N 条语句」就留下 N 段永不使用的片段文本——批量任务里是可观且无界的增长，直到事务结束。另有一个正确性隐患：这些残留片段若被后续某个 `TableClause.condition{}` 在 `clear()` 之前读到（当前实现先 `clear()` 再执行，所以暂不成立），会拼进别人的 WHERE。
- **建议**：`clearSql()` 里同步 `partials.clear()`（或让 `MeetCondition`/`ChooseCondition` 不再往共享缓冲追加、只返回字符串）；`close()` 的早退分支至少也应 `partials.clear()`。补用例：同一事务内连做 1000 次 `meet(...).done()`，断言 `partials` 内部长度不随次数增长（需要暴露只读长度或在 `Partials` 上加计数）。

### [一般][存量] #11 `Condition.SET` / `WHERE` 把 `delimiter` 无条件复位成 `''`：嵌套调用会清掉外层的分隔符

- **位置**：`f_orm/src/base/Condition.cj:40-52`（`42` 设 `','`、`50` 复位 `''`）、`54-69`（`59` 设、`67` 复位）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误（状态未保存/恢复）」、§12.1「共享可变状态」
- **证据**：静态确定（机制）+ 待确认（嵌套调用是否存在）—— `delimiter` 是 `ThreadLocal<String>`（`22-30`），`SET` / `WHERE` 用 `try/finally` 把它设为本次分隔符并在 `finally` 里写 `''`，而不是恢复进入前的值。`ChooseCondition.gen`（`85-104`）与 `MeetCondition.frag`（`43`）都依赖这个值拼分隔符。
- **描述**：只要在外层 `WHERE { ... }` / `SET { ... }` 的片段构造过程中再调用一次 `Condition.WHERE(...)` 或 `SET(...)`（典型场景是用 `MeetCondition.EXISTS { ... }` 里再写一个子查询的 WHERE，或手工拼嵌套 `SET`），内层返回后 `delimiter` 变成 `''`，外层后续片段全部丢失 `and` / `,` 分隔符 ⇒ 生成 `a = ? b = ?` 这类语法错误的 SQL。线程隔离本身是对的（不会跨线程串扰），问题只在「保存/恢复」缺失。
- **建议**：`finally { delimiter = previous }`（进入时先 `let previous = Condition.delimiter`），或把分隔符改成随 `WHERE` / `SET` 作用域传递的参数（`LoopCondition` / `MeetCondition` 已在构造时持有 executor，同样可以持有 delimiter），彻底去掉这个线程内隐式状态。补用例：嵌套两层 `WHERE`，断言外层分隔符仍为 `and`。

### [一般][存量] #12 `SqlDialect.involvedIdentifier`：「已带引号即直通」+「只拆第一个 `.`」，前者是注入面、后者让三段式标识符引用错位

- **位置**：`f_orm/src/base/Dialect.cj:44-52`（`45-46` 行直通、`47-48` 行按第一个 `.` 切分）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §10「安全性：注入」、§11「逻辑错误 / 边界」
- **证据**：静态确定 —— `if (identifier.startsWith(startInvolver)) { return identifier }`：只要字符串以引号字符开头就**原样返回**，不再做任何包装/转义。所有标识符最终都走这里（`SqlPartial.cj:95-100` 的 `involve` → `dialect.involvedIdentifier`），而标识符来源包括 `Column(name)`、`AS(alias)`、`Columns.tableAlias(alias)` 等调用方传参。
- **描述**：(a) 安全面：任何把外部输入当列名/别名/表别名传入的调用方（`AS(用户输入)`、按字段名动态拼接的查询构造器）都能用 `"` 开头绕过引用，后续 SQL 文本直接进入语句——`involvedIdentifier` 事实上是「引用函数」，使用者会默认它安全；(b) 正确性：`schema.table.column` 只在第一个 `.` 处切分，产出 `"schema"."table.column"`，引用错位（同名的 schema 限定查询直接失败）。
- **建议**：直通分支改为「已完整加引号」的严格校验（首尾都是 `endInvolver` 且中间不含引号字符），否则一律重新包装并对内嵌引号做转义（MySQL 用 ```` `` ````、其余用 `""`）；切分改用 `identifier.split('.')` 逐段引用。同时在 README 明确「标识符必须来自代码常量，不得传用户输入」。

### [一般][存量] #13 `Columns.tableAlias()` 写的是**单例**上的可变字段：别名跨查询粘滞、跨线程串扰

- **位置**：`f_orm/src/base/Columns.cj:28-32`（`protected var tableAlias_` + `tableAlias(alias)` 直接赋值）；单例来自 `f_orm/src/macros/QueryMappersGenerator.cj:486-489`（`static let instance = $columnsName()`，`tableColumns()` 返回该实例），读取点 `QueryMappersGenerator.cj:471`（每列 `.$columnName.tableAlias(super.tableAlias_)`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §12.1「共享可变状态无保护」、§11「契约与实现不符」
- **证据**：静态确定（机制）+ 待确认（仓内无调用点）—— `TableMetas`/`tableColumns()` 返回的是 `static let instance`，`tableAlias` 是 `public func` 直接在它身上赋值，没有副本、没有复位入口、没有同步；`toString()` 每次都读这个字段。
- **描述**：`Q.tableColumns().tableAlias('u')` 一次调用之后，该实体在所有线程、所有后续查询里的列前缀都变成 `u.`，直到有人显式 `tableAlias('')`；两个线程同时对同一实体设置不同别名会互相覆盖，产生「A 的查询用了 B 的别名」这类极难定位的错误。仓内目前没有调用点（grep `tableAlias(` 只命中定义与宏生成代码），属于给下游埋的坑。
- **建议**：改成不可变/返回值语义：`public func tableAlias(alias: String): C`（或返回 `Columns` 的浅拷贝，`tableAlias_` 用 `let` 并在构造时注入），让生成器的 `static let instance` 退化成「模板」；若必须保留原地修改，至少把别名做成 `ThreadLocal<String>` 并在 `SqlExecutor.close()` 里复位。

### [轻微][存量] #14 两套语义相同的三值枚举 `CondRelOp` / `RelationOp`（大小写与空格不同）

- **位置**：`f_orm/src/base/CondRelOp.cj:18-29`（`'and'` / `'or'` / `'not'`，小写无空格）与 `f_orm/src/base/LogicalExpr.cj:210-221`（`' AND '` / `' OR '` / `' NOT '`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」，差异点仅「大小写 + 前后空格」
- **证据**：静态确定 —— 两个枚举成员完全相同（AND / OR / NOT），`toString()` 输出只差格式；使用方各一处：`TableClause.PAREN(op: CondRelOp, ...)`（`TableClause.cj:208-222`，拼 `' ${op} ('`）与 `RelationExpr`（`LogicalExpr.cj:229-245`，用 `builder.append(op)` + 自己的空格）。
- **描述**：同一个概念两处定义，任何一边新增运算符（如 `XOR`）都要改两处；格式差异（大小写/空格）已经让「谁负责补空格」变得不一致（`PAREN` 依赖枚举自带空格，`RelationExpr` 自己再补）。
- **建议**：保留 `RelationOp`（表达式树用），`TableClause.PAREN` 改用它并统一在拼装处补空格；`CondRelOp` 删除（`PAREN` 是 `public` API，属破坏性变更，需用户确认下游依赖）。

### [轻微][存量] #15 `Condition.SET` 与 `WHERE` 是同一段模板复制两遍

- **位置**：`f_orm/src/base/Condition.cj:40-52` 与 `54-69`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §2「换控制流 / 字面量复制」
- **证据**：静态确定 —— 两者结构逐行对齐：`try { 设 delimiter → trim(prefix, suffix) → 空则 '' 否则包关键字 } finally { delimiter = '' }`，差异只有 `delimiter`（`,` vs 传入值）、`trim` 的 prefix/suffix（`,`/`,` vs `and|or`/`and|or`）、关键字（`' SET ${p} '` vs `' WHERE ${p} '`）。`#11` 的缺陷正是这两份副本共有的。
- **描述**：模板复制导致的维护风险（修 #11 必须记得改两处），本身没有行为差异。
- **建议**：抽 `private static func wrap(keyword: String, delimiter: String, prefix: String, suffix: String, partial: () -> String): String`，`SET` / `WHERE` 各自一行转调；顺带把 #11 的「保存/恢复 delimiter」统一在模板里做。

### [轻微][存量] #16 复制粘贴的错误文案：两处都写「alias 与 alias 不能同时设置」

- **位置**：`f_orm/src/base/Columns.cj:121-123`（应说 alias 与 **sort**）、`f_orm/src/base/LogicalExpr.cj:126-128`（文案写的还是 `SqlFunc alias and SqlFunc alias`，且该类是 `CmpExpr`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §10「可读性 / 必要注释」、§11「语义与命名不符」
- **证据**：静态确定 —— 触发条件是 `alias_.size > 0 && sort.size > 0`（`Columns.cj:121`、`LogicalExpr.cj:126`），文案却重复了同一个词，`LogicalExpr` 那份还提到了不存在的 `SqlFunc` 类型（`SqlFunc` 在 `SqlFunc.cj`，本文件未定义）。
- **描述**：用户按异常文案排查时拿不到「到底哪两个属性冲突」，`SqlFunc` 更是误导。
- **建议**：改为 `'alias and sort cannot be set at the same time on <type>'`，两处共用同一个常量文案。

### [轻微][存量] #17 `Column('*')` 的别名被静默丢弃；空判断口径与 `RelationExpr` 不一致

- **位置**：`f_orm/src/base/Columns.cj:125-130`（`name == '*'` 分支只处理 `tableAlias_`，`alias_` 直接被忽略）；`f_orm/src/base/LogicalExpr.cj:254`（`isEmpty()`）与 `239`（`emptyLogicalExpr`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「契约与实现不符（静默丢失）」、§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— `Column('*').AS('cnt').toString()` 走 `125-130` 分支返回 `' * '`，`AS` 完全不生效；`ParenExpr` 只把「严格空串」当空，而 `RelationExpr` / `TableClause.appendPartial` 用 `emptyLogicalExpr`（空白与 `()` 也算空）。
- **描述**：`COUNT(*)` 这类写法若用 `Column('*')` 起手再加别名，得到的是无别名的 `*`（结果集列名变成 `*`，映射失败）；空白片段的判定口径不统一则让 `( )` 漏到 SQL 里。
- **建议**：`*` 分支同样处理 `alias_`（`' * AS ${exe.involve(alias_)} '`），或让 `AS` 对 `*` 直接抛 `SqlArgException`；`ParenExpr` 统一用 `emptyLogicalExpr`。

### [轻微][存量] #18 非 public 符号无调用者：`Columns.executor`、`GroupedQueryMapper` 三个 `newXxx`、`SqlDialectMediator` 的 3 个 `lastInsertId` 重载与 `limit`

- **位置**：`f_orm/src/base/Columns.cj:23-27`；`f_orm/src/base/GroupedQueryMapper.cj:27-32`、`52-57`、`78-84`；`f_orm/src/base/Dialect.cj:186-198`
- **来源**：存量（快照无基线；`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §1（`private` 全仓搜、默认 `internal` 在本包及子包搜）
- **证据**：静态确定 —— `Columns` 的 `private prop executor` 在本类内无任何读取（`Columns` 只有 `tableAlias`，列引用发生在子类 `Column` 自己的同名 prop，`102-106` 行是另一个声明）；`newGrouped` / `newGroupedSingle` / `newNullableGrouped` 全仓（排除 `.worktrees`）只有定义处命中，宏也不生成这三个名字（`QueryMappersGenerator.cj` 直接 `new` 构造器）；`SqlDialectMediator` 是 `struct`（非 public），其 `lastInsertId(dialect:id:)` / `(…: DataType)` / `(…: IdQueryMapper)` 与 `limit(dialect:size:offset:)` 全包无调用者（外部一律 `dialect.lastInsertId(...)` 直调，见 `TableClause.cj:489`/`539`）。
- **描述**：死代码占用维护面积，其中 `SqlDialectMediator.lastInsertId` 三个重载还暗示「方言解析应经中介者」，与实际的直调写法冲突，容易诱导后来者走错路径。
- **建议**：删除上述 7 个符号；若 `newXxx` 是给宏预留的扩展点，就在宏里接上或加注释说明「预留、当前无调用」。

### [轻微][存量] #19 测试文件残留：`DAO_test.cj` 整文件被注释，`DriverTest` / `DatasourceCreatorImpl` / `DatasourceTest` 组成的替身链已无使用者

- **位置**：`f_orm/src/base/DAO_test.cj:18-110`（全部为 `//` 注释，无任何声明）；`f_orm/src/base/Driver_test.cj:18-70`；`f_orm/src/base/Datasource_test.cj:18-40`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §1「兼容残留 / 无调用者」、§3「半成品」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）搜 `DatasourceCreatorImpl` 只有 `DAO_test.cj:24` 的注释行；`DriverTest` 只被 `DatasourceCreatorImpl` 使用（`Driver_test.cj:63`、`67`），`DatasourceTest` 只被 `DriverTest` 使用（`55`），`ConnectionTest` 只被 `DatasourceTest` 使用（`38`）——整条链的根（`DAO_test`）是注释，所以四个类在测试构建里都是死代码。文件里没有 `@Test`，`DAO_test.cj` 甚至编译不出任何符号。
- **描述**：`DAO_test.cj` 里注释掉的是一份「手写事务模板 + `@DAO` 示例」，包含 `@QueryMappersGenerator` / `@DAO` 的旧写法，长期不同步会误导读者（其中 `args.meet(!namePrefix.isEmpty(), "username like", "${namePrefix}%", prefix: "where")` 的 `prefix` 参数在当前 `MeetCondition` 上已不存在）。
- **建议**：删除 `DAO_test.cj`；`DriverTest` / `DatasourceCreatorImpl` / `DatasourceTest` / `ConnectionTest` 若没有实际用例驱动，一并删除（`ConnectionTest` 至少还被 `DatasourceTest` 引用，但根已死）；需要 driver/datasource 替身时统一用 `f_mockdb`。

### [轻微][存量] #20 测试替身的空实现没有注释，且 `close()` 与 `isClosed()` 互相矛盾

- **位置**：`f_orm/src/base/Datasource_test.cj:22-27`（`setOption` 空体、`isClosed` 恒 `false`、`close` 空体）、`f_orm/src/base/Connection_test.cj:35-38`（`close()` 空体、`isClosed()` 恒 `false`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §3「空实现」（Null Object 必须注释说明）、§11「契约与实现不符」
- **证据**：静态确定 —— `Connection.close()` 无任何状态变更，`isClosed()` 恒返回 `false`，即「关闭后仍报未关闭」；`Datasource.setOption` 丢弃全部入参。
- **描述**：作为测试替身这是可接受的简化，但没有一行注释说明「为什么可以空」；若将来有用例依赖 `isClosed()` 判断连接是否被正确归还，这个替身会永远给出「没关」，把资源释放缺陷掩盖掉。
- **建议**：加 `private var closed = false`，`close()` 置真、`isClosed()` 返回该值；`setOption` 加一句 `// 测试替身：忽略连接选项`。

### [轻微][存量] #21 `String` 的 `AND` / `OR` / `NOT` 扩展与 `Partials.AND/OR/NOT` 是同一件事的两套实现，且带隐式全局副作用

- **位置**：`f_orm/src/base/ExtendString.cj:18-56`（`append` `29-32` 往 `getCurrent().partials` 追加 `' and '` 等）；对照 `f_orm/src/base/Partials.cj:40-57`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §2「换控制流 / 跨层复制」、§10「仓颉语言特性（扩展的可见性副作用）」
- **证据**：静态确定 —— `Partials.AND(sql)` 的语义就是「追加 `' and '` + 片段」，`ExtendString` 把同一动作挂到 `String` 的**属性读取**上（`'x'.AND`），两者都写同一个缓冲区；`extend String` 在 `f_orm.base` 包内对所有可见该包的类型生效，`'随便一个字符串'.AND` 就会去取 current executor。
- **描述**：`prop AND: String` 这个名字让「读属性」看起来是纯操作，实际是「往当前线程 executor 的缓冲区追加文本并在当前没有 executor 时抛 `NoneValueException`」。日志、断言、`toString` 里误用都会踩到；两套实现还让「哪个才是推荐写法」没有答案。
- **建议**：删除扩展（`Partials` 已覆盖同一能力），或把它改成显式函数 `sqlAnd(fragment: String)`；若保留，属性名改成动词形态（`asAndClause`）并在注释里写明「依赖线程内 executor」。

### [轻微][存量] #22 `ChooseCondition` 的三组同名重载对字面 lambda 有歧义，用户必须显式标注变量类型

- **位置**：`f_orm/src/base/ChooseCondition.cj:60-65`（`partial(() -> Any)` / `partial(() -> String)`）、`70-75`（`otherwise` 同）、`43-53`（`partial(() -> (String, Any))`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §10「可读性 / 契约」、§14「示例可用性」
- **证据**：静态确定，且有仓内自证 —— `ArgInSql_test.cj:163-165` 的注释原文：「partial / otherwise 的实参先落到带类型的变量上：直接写字面 lambda 会在 `() -> (String, Any)` / `() -> String` / `() -> Any` 三个重载之间产生歧义」，用例本身就是为了绕开这个歧义而多写了两行变量声明。
- **描述**：正常写法 `.partial({=> 'x = 1'})` 编译不过，用户只能写 `let p: () -> String = {=> 'x = 1'}`，文档示例若直接写 lambda 会不可用。
- **建议**：把三个重载合并为一个 `partial(partial: () -> (String, Any))` + 两个命名不同的便捷方法（`partialSql(...)` / `partialValue(...)`），消除重载歧义。

### [轻微][存量] #23 `Condition.trim` 把自定义 `prefix` / `suffix` 直接插进正则，未转义

- **位置**：`f_orm/src/base/Condition.cj:78-80`（`'^\\s*(${prefix})\\s*|\\s*(${suffix})\\s*$'.regex(...)`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「边界 / 错误处理」、§10「安全性（把数据当模式）」
- **证据**：静态确定 —— 三个内部组合被预编译成常量（`33-35`、`72-77`），其它取值一律走字符串插值；`prefix = '('` 会构造 `^\s*(()\s*|\s*()\s*$` 这类非法/语义错误的模式并抛正则编译异常，`prefix = '.'` 则退化成「匹配任意字符」。
- **描述**：`trim` 是 `public` API，参数名 `prefix` / `suffix` 读起来像字面量，实际要求是正则片段（只有读过实现才知道 `'and|or'` 是交替）。误用要么抛异常，要么静默裁掉不该裁的字符。
- **建议**：参数改名为 `prefixPattern` / `suffixPattern` 并在 README 写明是正则；或在内部 `Regex.escape(prefix)`（`f_regex` 若有对应能力）并对内部三组继续走常量，另加参数校验（拒绝含 `\` 与括号的取值）给出明确异常。

### [轻微][存量] #24 `SqlDialectMediator.getDialect`：懒填充是「检查-然后-写入」，且未注册方言直接抛 `KeyNotFoundException`

- **位置**：`f_orm/src/base/Dialect.cj:175-182`（`176` 行 `if (dialects.isEmpty())`、`181` 行 `dialects[dialect]`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §12.1「检查-然后-写入」、§11「错误处理缺失」
- **证据**：静态确定 —— `dialects` 是 `ConcurrentHashMap`（`184`），但「空则整体填充」不是原子操作：两个线程可同时看到 `isEmpty()` 为真并各自 `lookupList<SqlDialect>()` 全量写入（值相同、结果幂等，但多付一次启动期反射）；`dialects[dialect]` 对缺失键的行为是抛 `KeyNotFoundException`（`ConcurrentHashMap` 的 `[]` 非 `get`），而 `orm_drivers` 里出现未内置的方言名（如 `kingbase`）时，每个 SQL 调用点都会收到这个与业务无关的异常。
- **描述**：启动期多线程同时构造 `TableClause` 时可能重复填充（无害但无必要）；配置写错时错误信息不含「已注册的方言列表」，排查成本高。
- **建议**：用 `computeIfAbsent` 做单次初始化（`dialects.computeIfAbsent(dialect) { ... }` 或加一个 `AtomicBool` 门闩），缺失键改成抛 `ORMException('dialect ${dialect} is not registered, available: ${dialects.keys}')`。

## 优化可行性方案

### [堆内存] 让 `partials` 与 `args` 跟随语句生命周期归零

- **现状**：每个线程一个 `SqlExecutor`，其 `partials`（`StringGenerator`）与 `args`（`SqlArgs`）在事务内跨语句存活。`clearSql()`（`SqlExecutor.cj:97-106`）换掉 `args` 实例但**不触碰** `partials`；`close()`（`153-174`）在事务中直接返回。字符串拼接路径（`MeetCondition.frag` / `ChooseCondition.done` / `ExtendString.append`）持续追加，量级 ≈ 每条语句的片段字节数 × 事务内语句数（未测）。
- **方案**：`clearSql()` 增加 `partials.clear()`；`Partials` 增加只读 `size` 供观测；`close()` 的早退分支也清一次。
- **预期**：事务内常驻片段文本从「N × 片段长度」降到「当前语句一份」；对长事务批量任务（1k+ 语句）应能把该项常驻降到常数级（**无实测**）。
- **代价**：若确有调用方依赖「跨语句累积片段」的隐式行为（当前实现没有这样的显式入口），会改变语义；需要在 `TableClause` 之外补一个用例确认无回归。
- **验证**：同一事务内循环 1k / 10k 次 `meet(...).done()`，采 `getAllocatedHeapSize()` 与 RSS，确认曲线变平；同时对比 SQL 文本逐字节一致（复用 `ArgSqlText_test` 的口径）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 表达式树 `toString()` 单次求值 + 消除 `ParenExpr` 的重复遍历

- **现状**：`ParenExpr.toString()`（`LogicalExpr.cj:252-258`）对内层树求值两次；`RelationExpr.toString()`（`227-249`）对每个子表达式求值一次并 `emptyLogicalExpr` 再扫一遍文本；`CmpExpr.toString()` 每次都新建 `ExprSqlExec()`（`129`/`142`）。输入规模是一次 WHERE 的条件数 n（典型个位数到几十）。
- **方案**：#1 修完后顺带把「一次遍历产出 sql + args」落地（表达式节点缓存本次求值结果，或在 `toString` 外层包一个求值上下文），`RelationExpr` 的空判断改为「求值结果为空则跳过」而不是对字符串再做一次扫描。
- **预期**：条件数为 n 时，字符串化次数从「约 2n」降到「n」；`ExprSqlExec` 分配次数同比例下降（**无实测**，占比未知，可能低于 5% 噪声阈值）。
- **代价**：需要给表达式节点加「已求值」状态或引入显式求值器，改动面覆盖 `LogicalExpr.cj` 全部 7 个类；缓存状态还可能引入新的可变性（必须与 #9 的「求值/绑定分离」一起做）。
- **验证**：`cjpm bench -O2`，同一 DAO 方法（10 个条件）执行 10 万次，对比 `cjprof record` 中 `LogicalExpr.toString` 系函数的自耗时占比与总耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 字符串拼接路径的 `partials` 残留是长事务的内存增长主项之一 | `f_orm/src/base/MeetCondition.cj:47`、`ChooseCondition.cj:114`、`ExtendString.cj:30` | 事务内语句数、每条语句片段字节数、`StringGenerator` 实际占用 | 在 `Partials.append` 处加计数（次数 + 累计字节），跑一个 10k 语句的批量事务，对照 RSS 与 `getAllocatedHeapSize()` |
| 2 | `LogicalExpr` 系 `toString()` 的重复求值在条件多的查询里占可观 CPU | `f_orm/src/base/LogicalExpr.cj:252-258`、`227-249` | 自耗时占比、条件数分布 | `cjprof record` 跑 10 万次 10 条件查询，看 `LogicalExpr.toString` 系函数 self time 是否 >5% |
| 3 | `Condition.trim` 的自定义分支每次调用都编译一次正则，是低频热点的隐藏开销 | `f_orm/src/base/Condition.cj:79` | 自定义 prefix/suffix 的调用次数 | 全仓搜 `Condition.trim(prefix:` 的非常量实参调用点；有则加计数并计时，无则可忽略 |
| 4 | `SqlDialectMediator` 的懒填充在启动期被并发触发多次 | `f_orm/src/base/Dialect.cj:176-182` | 填充次数（是否 >1） | 在 `176` 分支内加计数，`fboot` 冷启动 100 次统计非 1 的比例 |

**范围外提示**（不计入本部分统计）：

1. `QueryMappersGenerator.cj:319-323` 生成 `GroupedQueryMapper<...>(name: $columnName, grouped: ..., groupedGetter: ...)`，而本部分的 `GroupedQueryMapper` 构造器只有 `grouped!` / `groupedGetter!` 两个形参（`GroupedQueryMapper.cj:21-26`）。一旦某个 `@QueryMappersGenerator` 类出现 `ArrayList<实体>`（非可空、无转换器）字段，宏展开即编译失败。仓内已用的 PO（`f_llm` / `fdemo` / `fdbm`）没有这种字段，所以当前未被触发；归第 4/5 部分（宏）确认。
2. `SqlDialect` 家族里 `OracleDialect` / `DB2Dialect` 未覆写 `lastInsertId`，采用基类返回 `''`（`Dialect.cj:22-24`），即这两种方言插入后拿不到自增 ID；`PostgresDialect` 的 `' returning ${id}'` 未对标识符加引号（`99-101`）。是否属已知限制需要 README 侧确认（不在本部分）。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/base/ArgInSql_test.cj` | .cj | ✅ | 7 条用例钉住 `argInSql` 口径（值内联、非 ToString 仍绑定、`IN` 逐元素混用）；`161-183` 的用例注释自证 #22（重载歧义），同时暴露 #4（片段型 `partial` 只在 `argInSql` 下被测） |
| 2 | `f_orm/src/base/ArgSqlText_test.cj` | .cj | ✅ | 逐字节钉 `arg` / `IN` / `NOT_IN` / `loop` 文本；`65` 行断言空 `arg` 返回 `''`，与 #6（`MeetCondition.IN` / `LoopCondition` 没有同等空集合处理）形成对照；`54` 行把 `i` 当下标用，见 #5 |
| 3 | `f_orm/src/base/ChooseCondition.cj` | .cj | ✅ | 见 #4（无条件绑定 + 默认 `otherwise` 悬空 `?`）、#22（重载歧义）；`condition`/`partial` 配对的 `pair` 状态机本身正确（缺 `partial` 时 `done` 抛异常） |
| 4 | `f_orm/src/base/ColumnInfo_test.cj` | .cj | ✅ | `ColumnInfo` 的固定值替身（`displaySize`/`length` 恒 8、`nullable` 恒 false），被 `QueryResult_test.cj:27-30` 使用；无缺陷 |
| 5 | `f_orm/src/base/Columns.cj` | .cj | ✅ | 见 #8（`Column.toString` 是引用入口）、#9（`getCurrent` 耦合）、#13（`tableAlias` 写单例）、#16（文案）、#17（`*` 丢别名）、#18（死 `executor`）；`SqlExpr` 的 16 个运算符方法均转调 `CmpExpr`/`InExpr`/`BetweenExpr`/`NullExpr`，无重复实现 |
| 6 | `f_orm/src/base/CondRelOp.cj` | .cj | ✅ | 见 #14（与 `RelationOp` 重复）；`match` 穷尽三个成员，无 `_` 兜底 |
| 7 | `f_orm/src/base/Condition.cj` | .cj | ✅ | 见 #11（`delimiter` 复位为 `''`）、#15（`SET`/`WHERE` 重复）、#23（自定义 prefix 未转义）；`TRIM_*` 三个预编译正则在 `ConditionTrim_test` 有逐条对照，`ThreadLocal` 保证不跨线程串扰 |
| 8 | `f_orm/src/base/ConditionTrim_test.cj` | .cj | ✅ | 5 组用例钉 `trim` / `SET` / `WHERE` / `emptyLogicalExpr` 输出；`61` 行 `trim('') == ' '` 正是 #6 里 `LoopCondition` 空集合产出 `( )` 的一环；无不一致 |
| 9 | `f_orm/src/base/Connection_test.cj` | .cj | ✅ | 见 #20（空 `close` + 恒 false 的 `isClosed`）；`createTransaction` 返回 `TransactionTest`（不在本部分），`prepareStatement` 返回 `StatementTest`，替身链见 #19 |
| 10 | `f_orm/src/base/DAO_test.cj` | .cj | ✅ | 整文件 18-110 行全部注释，无声明；见 #19（旧 `@DAO` / `@QueryMappersGenerator` 写法，`meet(..., prefix: "where")` 的签名已不存在） |
| 11 | `f_orm/src/base/Datasource_test.cj` | .cj | ✅ | 见 #19（替身链根已死）、#20（`setOption` 空实现）；文档注释 `29-36` 是从某份 JDBC 手册粘贴的（含「567 / 版权所有，禁止扩散」），属残留文案 |
| 12 | `f_orm/src/base/Dialect.cj` | .cj | ✅ | 见 #12（`involvedIdentifier`）、#18（中介者 4 个死方法）、#24（懒填充 + 缺失键异常）；9 个方言类的 `@Bean` 条件互不重叠（`mysql`/`mariadb`/`sqlite`/`postgres`/`opengauss`/`oracle`/`db2`/`mockdb` 共 8 个 `@Bean` 实现 + 1 个抽象基类），`limit` 的参数顺序与 `SqlPartial.cj:297`/`311`、`TableClause.cj:236` 的绑定顺序一致（Oracle 的 `(offset, size)` 与 `OFFSET ? ROWS FETCH NEXT ?` 对齐） |
| 13 | `f_orm/src/base/DirtyTag.cj` | .cj | ✅ | 见 #3（`beforeDirty` 全局 + `dirtyFields` 线程内）；`register`/`setDirtyField` 的二层自递归深度固定为 1，`clearAll` 遍历 `ConcurrentHashMap` 同时替换值属弱一致迭代，不抛异常 |
| 14 | `f_orm/src/base/Driver_test.cj` | .cj | ✅ | 见 #19（`DriverTest` / `DatasourceCreatorImpl` 无使用者）；`60-65` 的注释记录「接口要求实现 `driverName`，原先缺这个成员导致编译不过」，属已修历史 |
| 15 | `f_orm/src/base/ExtendString.cj` | .cj | ✅ | 见 #9（读 current）、#21（与 `Partials` 重复 + 属性读取带副作用）；`append` 返回 `''` 只为满足 `prop` 的返回类型，属刻意写法 |
| 16 | `f_orm/src/base/GroupedQueryMapper.cj` | .cj | ✅ | 见 #7（`prevSize` 判定恒假）、#18（三个 `newXxx` 死代码）；三个类的 `isGrouped` 覆写都返回 `true`，属父类契约实现，不判死代码 |
| 17 | `f_orm/src/base/IdQueryMapper.cj` | .cj | ✅ | `id(...)` 用 `getOrThrow()` 把 `None` 转异常，`isId` 覆写返回 `true`；被宏生成的 mapper 列表（`QueryMappers.cj:94`、`SqlPartial`）使用，无缺陷 |
| 18 | `f_orm/src/base/LogicalExpr.cj` | .cj | ✅ | 见 #1（`ParenExpr` 二次求值）、#2（BETWEEN 混型）、#8（`InExpr` 裸列名）、#16（文案）、#17（空判断口径）；`EmptyExpr` 的 14 个 no-op 覆写是 Null Object（由 `RootDAO.meet` 返回，`407`/`414`/`420`/`427`），属父类覆盖，不判死代码；`RelationExpr` / `ParenExpr` / `CommaExpr` 均由 `RootDAO` 构造，无未使用符号 |
| 19 | `f_orm/src/base/LoopCondition.cj` | .cj | ✅ | 见 #5（`i` 语义）、#6（空集合 + 无上限）；`sep` 预拼与 `frag.isEmpty()` 跳过是 ORM-N1 的优化，文本由 `ArgSqlText_test.cj:75-79` 钉住 |
| 20 | `f_orm/src/base/MeetCondition.cj` | .cj | ✅ | 见 #6（空 `IN`）、#10（`partials` 追加）；`condition == false` 时 `frag()` 不会被求值（`42-46`），因此不会出现「条件不成立却多绑参数」，这一点核对无误 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1 / #2 / #4 / #5 / #6 / #8；设计 #9（求值与绑定耦合）、#13（单例可变）；安全性 #12（标识符直通）；可读性 #16 / #21 / #22；语言特性：`Unit` 实现 `ToString`（`core.md:29`）导致 #4 的 `"()"` 绑定，`ThreadLocal` 语义见 #3 / #9 |
| §1 死代码 | 2 | 已逐个 `private`（全仓搜）/ 默认 `internal`（本包及子包搜）/ `protected` 排查：#18 列出 7 个无引用符号（`Columns.executor`、3 个 `newXxx`、`SqlDialectMediator` 的 3 个 `lastInsertId` + `limit`）；#19 列出测试替身链（`DatasourceCreatorImpl` → `DriverTest` → `DatasourceTest` → `ConnectionTest`）与注释文件。无不可达语句（`return` 后无同层语句）；`Columns.tableAlias_` / `SqlExpr.alias_|sort` / `DirtyTag` 的 `protected` 成员分别属于「`public abstract class` 的扩展点」与「有引用」，不判；对外可达的 `public`（`SqlExpr` 16 个运算符、`LoopCondition` 8 个链式方法、`Column`、`EmptyExpr`、`InExpr` 等）一律不判，其中 `LoopCondition.wrapLeft/wrapRight/trimLeft/trimRight`、`Columns.tableAlias` 仓内零调用（`IdQueryMapper.id` 被 `QueryMappers.cj:97` 使用，不在此列），记「对外 API、仓内无引用」作为信息 |
| §2 重复逻辑 | 3 | 同文件两两比对 20 个文件的函数体：`Condition.SET` vs `WHERE`（#15）、`CondRelOp` vs `RelationOp`（#14）、`ExtendString.AND/OR/NOT` vs `Partials.AND/OR/NOT`（#21）。另核对：`CmpExpr` vs `InExpr` vs `In2Expr` 的 `toString` 骨架相似但取值规则不同（差异已被 #8 报为缺陷，不重复计）；`MeetCondition.IN` vs `NOT_IN` 只差 `' in'`/`' not in'`（两个公开重载，语义对称，属预期形态，不判）；`GroupedQueryMapper` 三个 `populate` 的 getter 形态不同（`ArrayList.add` vs 逐 mapper 写），不构成重复 |
| §3 空实现 | 1 | #20（测试替身 `close`/`setOption` 空体、`isClosed` 恒 false，且无注释说明）；`GroupedQueryMapper` 的 `super(putter: {o, v =>}, ...)` 是刻意的 no-op putter（分组映射器不用 `putter`，字段由 `populate` 写），不算空实现；`SqlDialect.lastInsertId` 基类返回 `''` 已在「范围外提示 2」记录 |
| §4 栈溢出 | 0 | 仅 `DirtyTag.setDirtyField` / `setBeforeDirty` 的二层自递归（`47` / `56`），`register<T>()` 后必然命中 `Some`，深度固定为 1；`LogicalExpr` 的表达式树按「用户手写的嵌套深度」递归，无自引用环、无用户输入的深层结构（DAO 代码里手写的条件层数是个位数量级），不构成 §4 风险 |
| §5 OOM | 2 | #6（`IN`/`loop` 元素数无上限、无拒绝路径，占位符串与参数表同步线性增长）、#10（`partials` 在长事务内只增不清）。已核对：`ChooseCondition.conditions` / `LoopCondition` 的临时对象都随构建器实例死亡；`GroupedQueryMapper` 的 `ArrayList` 由结果集行数决定（属结果集本身）；`DIRTY_TAGS` 以 `TypeInfo` 为键，类型数有界 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，2 条疑似热点（重复求值、正则构造）全部进「优化可行性方案」+ 待验证假设，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex`；并发面只有 `ConcurrentHashMap`（`DirtyTag`、`SqlDialectMediator`）与 `ThreadLocal`（`Condition.delimiter`、`SqlExecutor.current`），不存在「锁内做 I/O」形态。`DirtyTag` 的无锁读改写已在 #3 按正确性报 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无线程池；executor 是线程封闭的（`ThreadLocal`），不存在「并发度配成 1」的串行段 |
| §6.4 低效算法 | 0 | 逐个核对：`RelationExpr`/`CommaExpr` 是 O(子表达式数)；`LoopCondition` 单趟遍历 + `StringGenerator`；`MeetCondition.IN` 单趟；`Condition.trim` 的正则替换是 O(片段长度)，内部三组已预编译；无嵌套循环匹配、无 `remove(at: 0)`、无循环内 `+` 拼串（`builder` 累积）；`Dialect.involvedIdentifier` 的 `indexOf` 是 O(长度)，不构成量级问题 |
| §7 降堆内存方案 | 1 | 优化方案 1（`partials` / `args` 随语句清零），标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 优化方案 2（表达式树单次求值），标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分的临时对象都是「要逃逸的最终产物」：`LoopCondition.done()` / `MeetCondition.frag()` 的字符串要进 SQL 文本、`Column.toString()` 的结果要进语句、`PARTIALS` 的 `StringGenerator` 是 executor 字段——逃逸检查直接不通过；`GroupedQueryMapper.populate` 的 `ArrayList` 是返回值的一部分。没有「函数内建、函数内销毁」的大对象，也没有 `getAllocatedLocalObjectSize()` 前后峰值数据 |
| §11 现有代码的 BUG（存量） | 24 | 本部分 24 条全部为存量（快照无 diff，`git blame` 落在 `9fe28abd50 2026-09-13` / `e494170cc4 2026-09-15`）。另逐项核对了本轮读到的边界与空值：`MeetCondition.condition == false` 不执行 `frag()`（正确，不会多绑参数）；`ChooseCondition` 的 `pair` 状态机缺 `partial` 时抛异常（正确）；`Dialect.limit` 的返回顺序与三处绑定点一致（正确）；`Condition.trim` 的内部三组输出由 `ConditionTrim_test` 逐字符钉住（正确） |
| §12 并发安全与锁粒度 | 3 | 并发安全 #3（`DirtyTag.beforeDirty` 共享无同步 + `clearAll` 只清本线程）、#13（`Columns` 单例可变字段）、#24（`getDialect` 检查-然后-写入，幂等无害但非原子）。已核对的同步手段：`SqlExecutor` 全部状态线程封闭（`currents`/`current` 为 `ThreadLocal`）；`Condition.delimiter` 线程封闭；`DIRTY_TAGS`/`dialects` 用 `ConcurrentHashMap` 但只保证单次操作原子。锁粒度：#3 需要「跨线程共享的开关 + 线程私有集合」统一到同一作用域，不能靠加锁解决 |
| §14 功能完备性与 README 覆盖 | 0 | README / `doc/**` 不在本部分（第 1、2 部分），本部分只核对了 public 声明与调用链：`LoopCondition` 的 `wrapLeft/wrapRight/trimLeft/trimRight`、`Columns.tableAlias`、`IdQueryMapper.id` 仓内零调用但属对外 API；`GroupedQueryMapper` 构造器与宏生成实参不一致已在「范围外提示 1」记录，无法在本部分给出「承诺源 + 缺失证据」双证，故不计 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`，§13 文档一致性留给第 1、2 部分（本报告只引用了 `cangjie-doc/md/doc/core.md:29` 作为 `Unit <: ToString` 的判据） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 10 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

（存量 24 条，是否纳入修复待用户决定；本部分未做任何源码修改。）

## 总评

本部分是 `f_orm` 的 **SQL 片段构造层**，没有连接池、事务、锁，但它是全模块参数绑定的唯一出口：`Column.toString()` / `CmpExpr.toString()` / `MeetCondition.done()` 都在「字符串化」阶段把值塞进线程内 executor 的 `args`。把「求值」和「绑定」揉进 `toString()` 是这一层所有问题的共同根因，也是最值得优先动的一处结构性改造。

- **阻塞项（3 条严重）**：#1 `ParenExpr` 对子表达式求值两次，`AND/OR/NOT` 的 lambda 变体（DAO DSL 的公开写法）会得到「2 个占位符 / 4 个参数」或参数错位；#2 `BETWEEN` 混合 `Column` 与常量时把 `Column` 当字符串值绑定，静默查错数据；#3 `DirtyTag` 把「是否开启脏跟踪」放在全局、把脏字段放在线程内，`clearAll` 只清当前线程，并发下会丢更新，`UPDATE ... dirty` 可能一条 SQL 都不发。三条都只需局部改动（一次求值、操作数分流、开关下放到 `ThreadLocal`），但都需要补用例才能防回归。
- **契约面缺陷（#4–#8）**：`ChooseCondition` 的片段型 `partial` 与缺省 `otherwise` 在默认模式下必然多绑参数（#4）、`LoopCondition` 的 `Int64` 形参不是下标（#5）、`IN`/`loop` 空集合生成 `in ()` 且元素数无上限（#6）、`NullableGroupedQueryMapper` 的 `None` 兜底是死分支（#7）、`InExpr` 绕过引用与表别名（#8）——都是「写得出来、跑起来错」的形态，且有 4 条属于「同族实现已经写对，只有这一处漂移」，修法明确。
- **生命周期与内存（#9–#10）**：executor 的线程内 `current` 与「语句结束即 `close()`」是本模块的既有约束（基线 §2 明写），但构造层把参数绑定藏在 `toString()` 里，违反约束时没有编译期或运行期的明确报错；`partials` 缓冲在字符串拼接路径上只增不清，长事务里会随语句数累积。这两条不一定会立刻出错，但会把「偶发参数错位」变成不可复现的线上问题。
- **并发与单例状态（#13 / #3 / #24）**：`Columns` 是 `static let instance`，`tableAlias()` 直接改它的字段，别名会粘滞到后续所有查询并跨线程串扰。这类「给下游埋的坑」目前仓内零调用，所以没有任何用例能暴露它。
- **可维护性（#14–#24）**：两套 `AND/OR/NOT` 枚举、`SET` 重复实现 `WHERE` 的模板、复制粘贴的异常文案、`String` 的 `AND` 属性带隐式全局副作用、`ChooseCondition` 的重载歧义（测试注释自证）、`DAO_test.cj` 整文件注释 + 一条已死的替身链——单条都不重，但合起来是这一层「读代码比读文档更可靠」的原因。
- **未确认项**：宏生成的 `GroupedQueryMapper(name: ...)` 与本部分构造器形参不一致（范围外提示 1），一旦有实体类出现 `ArrayList<实体>` 字段就会编译失败，需要第 4/5 部分确认；Oracle / DB2 没有 `lastInsertId` 实现（范围外提示 2）需要 README 侧确认是否为已知限制。
- **性能与内存**：本部分没有任何改前/改后数据，1 条堆内存方案与 1 条 CPU 方案都标「无基线（待验证）」，4 条假设不进修复清单。下一轮最值得先补的是假设 1（事务内 `partials` 增长）——它同时决定 #10 的修复优先级。
