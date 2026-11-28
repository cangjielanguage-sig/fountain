# f_orm 模块审查报告（第 2/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（本部分 15 个源文件；模块共 111 个）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，工作区干净；无 diff，全部按存量审）
- **审查重点**：方言 / 脏标记 / 查询映射 / ORM 核心的正确性、并发安全、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（部分报告，供主 Agent 合并；与 `f_orm.part1.md` 交叉引用处已标注）

## 发现

### [严重][存量] 非事务查询结束时 `DirtyTag.clearAll()` 紧跟在 `setBeforeDirty()` 之后执行，脏字段追踪被立即清空：`UPDATE(dirty: true)` 静默返回 0

- **位置**：`f_orm/src/base/DirtyTag.cj:50-79`（`setBeforeDirty` / `clearAll`）、`f_orm/src/base/SqlExecutor.cj:532-540`、`:557-565`（`first` / `list` 的 `finally` 调 `setBeforeDirty`）、`:886-900`（`execute` 的 `finally` 调 `close()`）、`:153-173`（`close()` 末尾 `DirtyTag.clearAll()`）；消费侧 `f_orm/src/base/SqlPartial.cj:224-231`
- **来源**：存量（快照模式无基线；`git blame` 全落在 `4be871f2fd` 的 CRLF→LF 归一化，无法细分原始提交）
- **判据**：review-checklist §11（契约与实现不符 / 静默失效）、§3（开关打开后走进空分支）
- **证据**：静态确定 —— 调用顺序可逐行核对：
  1. `first<T>(mappers)` 在 extractor 的 `finally` 里 `DirtyTag.setBeforeDirty<T>()`（`SqlExecutor.cj:537`），`list<T>(mappers)` 同理（`:562`）；
  2. 消费型查询走 `execute<T>(extract: (QueryResultWrap) -> T)`（`:1013-1015`）→ `execute<T>(true){...}` → 最外层 `execute<T>(executor: () -> T)`；其 `finally` 在非事务（`tx.isNone()`）且连接未关时调用 `this.close()`（`:895-900`）；
  3. `close()` 末尾 `DirtyTag.clearAll()`（`:172`）对**本线程**所有已注册类型执行 `clear`：`dirtyFields.set(None)` 并把 `beforeDirty` 写回 `false`（`DirtyTag.cj:66-79`）；
  4. 之后 `@ORMField` 生成的 setter 调用 `DirtyTag.setDirtyField<T>`（`QueryMappersGenerator.cj:204`），因 `beforeDirty == false` 直接跳过（`DirtyTag.cj:36-44`）；
  5. `SqlPartial.UPDATE(..., dirty: true)` 拿到空集合即 `return 0`，不执行 SQL（`SqlPartial.cj:224-231`，README:753 也写明“无脏字段直接返回 0”）。
- **描述**：只要“装载”和“按脏字段更新”不在同一个事务里，脏标记在查询返回的瞬间就被清空，更新变成静默 no-op（0 行、无 SQL、无日志）。而 README 的脏更新说明（`f_orm/README.md:753`）没有“必须包在事务里”的限制，按文档写法（`first` → 改字段 → `UPDATE(dirty: true)`）正好命中该路径。另：迭代器路径 `iterator<T>()` 全程没有任何 `setBeforeDirty`（全仓 `grep setBeforeDirty` 仅 `SqlExecutor.cj:537/562` 两处），即便在事务内，迭代器装载的实体也永远不会被脏追踪。
- **建议**：`beforeDirty` 改为 `ThreadLocal<Bool>`（或按“装载轮次”计数），`close()` 不再清 `beforeDirty`；`iterator` 路径在结果集交付/读尽时补 `setBeforeDirty<T>()`；README 若确实要求事务内使用，须显式写明并给出示例，否则按“跨语句可用”修。

### [严重][存量] `DirtyTag` 的 `beforeDirty` 是类型级进程共享标志，`register` / `setBeforeDirty` / `clear` 都是“检查-然后-写入”，多线程下脏字段丢失或误标

- **位置**：`f_orm/src/base/DirtyTag.cj:25`（`beforeDirty` 字段）、`:27-32`（`register`：`contains` → `set`）、`:50-58`（`setBeforeDirty`：`get` → `set`）、`:66-71`（`clear`：`get` → `set`）；触发方 `f_orm/src/base/SqlExecutor.cj:172`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（检查-然后-写入 / 共享可变状态无保护）、§6.2（并发容器不等于复合操作原子）
- **证据**：静态确定 —— `DIRTY_TAGS` 虽是 `ConcurrentHashMap`（`DirtyTag.cj:23`），但三处都是先读后写：
  - 两个线程首次注册同一类型：都看到 `contains == false`，各自 `DirtyTag()`（各带一个**独立** `ThreadLocal`），后写者覆盖前者，前者已记录的脏字段与 `ThreadLocal` 一起丢失；
  - 线程 A 查询后 `setBeforeDirty` 置 `true`；线程 B 结束自己的执行器触发 `clearAll`（`SqlExecutor.cj:172`）把该类型的 `beforeDirty` 全局置回 `false` → A 之后的 setter 不再记录，A 的 `UPDATE(dirty)` 静默 0（数据未落库）；
  - 反向：B 的 `setBeforeDirty` 也会让 A 误以为“已装载”，A 的 setter 把字段记进 A 自己的 `ThreadLocal` → A 的 `UPDATE(dirty)` 会更新它并未修改过的字段（用它手里的旧值覆盖），属于错误写入。
- **描述**：`dirtyFields` 是每线程一份，`beforeDirty` 却是每类型一份，两种粒度混用；再加上非原子的读改写，脏标记在并发下既会漏也会多。`ORM`/`SqlExecutor` 默认按“会被多线程调用”审（每线程一个执行器，但 `DirtyTag` 是 `static` 全局）。
- **建议**：`beforeDirty` 与 `dirtyFields` 同粒度放 `ThreadLocal`；`DIRTY_TAGS` 用 `putIfAbsent` / `computeIfAbsent`；`clear` 改成“整体替换该 type 的不可变快照”，不要读-改-写。补一个双线程“A 装载 / B 关闭”的并发用例。

### [严重][存量] `Nullable` 关联映射的空值检测整体失效：`NullableGroupedQueryMapper` 的条件恒假、`NullableNestQueryMapper` 的 `nestGetter` 从未使用，NULL 关联被映射成空对象而非 `None`

- **位置**：
  - `f_orm/src/base/GroupedQueryMapper.cj:90-104`（`prevSize = list.size` → `list.add(groupedValue)` → `if (!ignoreNone && prevSize == list.size)`）；
  - `f_orm/src/base/NestQueryMapper.cj:38-58`（`nestGetter` 只在 `:41` / `:46-52` 转存，`populate` `:53-57` 完全不读）；
  - 生成侧固定 `ignoreNone: false`：`f_orm/src/macros/QueryMappersGenerator.cj:294-298`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（恒假分支 / 未使用参数导致语义缺失）、§1（读了不用）、§2（两份近似实现发生漂移）
- **证据**：静态确定 ——
  - Grouped：`list.add(groupedValue)` 必然让 `size` 加 1，之后 `prevSize == list.size` **永远为 false**；`!ignoreNone` 在宏生成的 `ignoreNone: false` 下为 true，但被后半条件短路。因此 `Option<T>.None` 永远不会被加入 `ArrayList<Option<T>>`，`ignoreNone` 参数（默认 `true`）也完全无效——true 时被 `!ignoreNone` 短路，false 时被 size 比较短路。
  - Nest：`NullableNestQueryMapper.populate` 无条件 `nested.map(result)`（`QueryMappers.map` 总会 `creator()` 出一个新 T 并逐列 populate，`QueryMappers.cj:77-83`），再 `nestPutter(o, n)`。全 NULL 的一对一关联因此变成“字段全默认值的空对象”，而字段类型是 `?T`/`Option<T>`，语义应为 `None`。
- **描述**：一对多 / 一对一关联在 left join 下必然产生“父行 + 全 NULL 子列”的行。当前实现会为每个父对象追加/写入一个空子对象，而不是 `None`；下游用 `Option` 判空、或用集合长度判断“有没有子记录”时全部判错。仓内无任何 grouped/nest 的测试（`grep "ArrayList<实体>" *_test.cj` 零命中），该路径完全未覆盖。
- **建议**：Grouped 先判断本行分组列是否全 NULL（可用 `grouped` 各 mapper 的 `dataType.get(result)` 或 `QueryResultWrap` 的列值判定），非 NULL 才 `creator()` + `add`；`ignoreNone` 要么实现要么删掉。Nest 用 `nestGetter(o)` 与结果列判定，NULL 时跳过 `nestPutter`（保持 `None`）。补 left join 的三种用例：无子行、部分列 NULL、正常行。

### [一般][存量] `SqlDialectMediator.getDialect` 的懒加载没有“初始化完成”标志：填充过程中并发查询会 `KeyNotFoundException`

- **位置**：`f_orm/src/base/Dialect.cj:175-182`（`if (dialects.isEmpty()) { for (...) dialects[...] = ... }`），消费点 `f_orm/src/base/SqlPartial.cj:95`、`f_orm/src/base/TableClause.cj:75`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（惰性初始化 / 发布逸出）、§11（错误类型与可诊断性）
- **证据**：静态确定 —— `isEmpty()` 在第一条 `put` 之后即为 false，此时其余方言尚未写入。线程 1 正在 `for` 循环填充，线程 2 调 `getDialect('mysql')` 会直接执行 `dialects['mysql']`，未命中即抛 `KeyNotFoundException`（不是 `ORMException`，也没有“方言未注册”的上下文）。同理，若在 `@Bean` 初始化完成前被调用（如静态初始化/预热），map 只会填到“当时已注册”的子集，后续再不补齐（`isEmpty()` 永假）。
- **描述**：首次 SQL 渲染发生在并发请求里时存在一个短暂窗口，表现为随机 `KeyNotFoundException`；重试后恢复，属于难复现的偶发故障。
- **建议**：先在局部 `HashMap` 里完整构建，再一次性发布（原子替换引用 / `ConcurrentHashMap` 整体替换）；或用 `computeIfAbsent` 按需填充并保证 `lookupList` 已就绪；未命中时抛 `ORMException('dialect ${name} is not registered, orm_drivers=...')`。

### [一般][存量] `ORM.default` 是普通 `static var`，注册/注销与读取之间无同步

- **位置**：`f_orm/src/base/ORM.cj:38`（`private static var default`）、`:74-82`（`register` 写）、`:157-169`（`deregister` / `deregisterAndReplaceDefault` 写）、`:175-179`、`:181-203`（`hasDefault` / `connection` / `executor` 读）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性）
- **证据**：静态确定 —— 字段无锁、无原子、无线程封闭；`ORM` 是进程级门面，`datasources` 用了 `ConcurrentHashMap`，唯独 `default` 是裸 `var`。两个并发 `register(..., default: true)` 后写覆盖；`deregister` 与 `executor()` 并发时可能读到刚被清空/刚被替换的驱动名，进而 `datasources[name]` 抛 `KeyNotFoundException`。写入主要发生在启动期，但 `deregister` 是 public、可在运行期调用。
- **建议**：改为 `Atomic<String>`（或把“默认驱动名”与注册表放进同一把锁保护）；至少在文档声明“只允许启动期注册/注销”。

### [一般][存量] `ORM.close()` 只关闭数据源、不清理注册表：关闭后再 `register` 会被判为重复，新数据源被立即关掉，ORM 无法重新初始化

- **位置**：`f_orm/src/base/ORM.cj:46-54`（`close` 遍历 `datasources` 关闭，但不 `remove`、不清 `default`）、`:74-82`（`addIfAbsent` 命中旧条目后 `datasource.close()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源 / 状态不一致）、§12.1（跨线程状态）
- **证据**：静态确定 —— `close()` 后 `datasources` 仍保留“已关闭的 `NamedDatasource`”；下一次 `register(ds)` 的 `addIfAbsent` 返回 `Some(旧)`，走 `else` 分支把**新**数据源 `close()` 掉。随后 `connection()` 取到的是已关闭的旧数据源（`NamedDatasource.connect()` 直接 `datasource.connect()`，`wrap/NamedDatasource.cj:47-49`，对已关闭池通常抛异常）。唯一绕法是先 `deregister`，但 `close()` 的语义没有提示这一点。
- **描述**：`close()` 是 public（且注册为进程退出回调），测试复用、热重启、多阶段初始化都会踩到；表现为“重新初始化后第一个请求就报连接已关闭”，且新注册的数据源被静默丢弃（无日志）。
- **建议**：`close()` 内对每个条目 `datasources.remove(name)` 并清 `default`；或新增“已关闭”状态，`register` 时检测旧实例 `isClosed()` 就替换而不是关闭新实例。

### [一般][存量] `IN` / `NOT_IN` 空集合生成非法 SQL：`InExpr` / `In2Expr` 生成 `col IN`，`MeetCondition` 生成 `in ()`，`LoopCondition` 生成 `(  )`

- **位置**：`f_orm/src/base/LogicalExpr.cj:175-181`（`InExpr.toString`）、`:190-195`（`In2Expr.toString`）；`f_orm/src/base/MeetCondition.cj:72-111`（`IN` / `NOT_IN`）；`f_orm/src/base/LoopCondition.cj:85-116`（`done`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（空集合未处理）、§2（与 `RootDAO.IN` 的近似实现漂移）
- **证据**：静态确定 —— `RootDAO.arg<I, T>` 对空 `Iterable` 返回 `''`（`RootDAO.cj:323-388`），而 `RootDAO.IN` / `NOT_IN` 明确用 `if (args.isEmpty()) return ''` 兜底（`RootDAO.cj:448-462`）；上述三处都没有这个兜底：
  - `InExpr` / `In2Expr` 空集合 → `' col IN  '`（占位符为空）；
  - `MeetCondition.IN` → `' in () '`；
  - `LoopCondition` 空 `values` + `wrap('(', ')')` → `' (  ) '`，正是 README §11.4 示例的写法（`id in ${loop(ids).wrap('(',')')...}`）。
- **描述**：业务传空列表（分页筛选、批量查询）是最常见边界；当前直接拼出非法 SQL，运行期报驱动语法错误，且错误信息只会指向整条 SQL，很难定位到“空集合”。
- **建议**：三处统一成“空集合返回 `''`”（与 `RootDAO.IN` 一致，交由 `emptyLogicalExpr` / trim 处理），或显式抛 `SqlArgException('IN list must not be empty')`，不要静默拼空。

### [一般][存量] `LoopCondition.condition` 的索引只在元素被接受后自增：按“下标”过滤会从第二个元素起整体失效

- **位置**：`f_orm/src/base/LoopCondition.cj:89-111`（`var i = 0`，`for (v in values where _condition(v, i))`，`i++` 在循环体末尾）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与文档不符）、§10（正确性 / 边界）
- **证据**：静态确定 —— `where` 子句里读到的 `i` 是“已接受元素个数”，不是源迭代下标；被过滤掉的元素不会自增。例：`loop([a,b,c,d]).condition {v, i => i % 2 == 0}`：a 时 `i=0` 接受 → `i=1`；b 时 `i=1` 拒绝且 `i` 不变；c、d 仍然看到 `i=1` 全部拒绝，最终只剩 a。README §11.4 明确写“第二参为下标”，用户按文档写 `i` 取下标必然踩坑。
- **描述**：这是“过滤器里放索引条件就冻结”的隐蔽错误；且 `LoopCondition` 仓内零调用（`grep ".loop("` 仅定义）、零测试，问题不会被现有用例发现。
- **建议**：先自增再判断（`for ((v, idx) in values enumerate)` 或把 `i++` 提到 `where` 之前），明确文档语义为“源下标”；补一条 `i % 2` 的过滤用例。

### [一般][存量] `InExpr` / `In2Expr` 对 `Column` 直接用未加引用符、且丢失表别名的 `name`

- **位置**：`f_orm/src/base/LogicalExpr.cj:177-180`、`:192-195`（`case x: Column => ' ${x.name} ...'`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约不一致）、§2（同一 DSL 两套列名渲染）
- **证据**：静态确定 —— `Column.toString()` 会按方言 `involve(name)`（反引号/双引号）并拼接 `tableAlias_`（`Columns.cj:114-143`）；`CmpExpr` 对所有列都用 `' ${column} '`（`LogicalExpr.cj:135/143/144`），而 `InExpr` / `In2Expr` 特判 `Column` 取 `x.name`（裸列名、无别名），else 分支才用 `' ${x} '`。于是 `col.eq(v)` 生成 `` `u`.`col` = ? ``，`col.IN(list)` 生成 `col IN (...)`。
- **描述**：保留字列（`order`、`group`）、大小写敏感列、带 `tableAlias` 的列在 `IN` 下三种情况都会拼错或失去别名限定；同一 DSL 里 `eq` 与 `IN` 的列名渲染不一致，也会让 SQL 快照测试“时对时错”。
- **建议**：删除 `Column` 特判，统一 `' ${x} '`；若担心双重引用，应在 `Column.toString` 层解决，而不是在表达式层绕开。

### [一般][存量] `NOT` / `CommaExpr` 不跳过空逻辑表达式：`NOT` 一个空条件生成 `NOT ()`，`CommaExpr` 尾部空元素生成尾随逗号

- **位置**：`f_orm/src/base/LogicalExpr.cj:227-248`（`RelationExpr.toString` 的 `NOT` 分支 `:229-235`，`AND/OR` 分支有 `emptyLogicalExpr` 跳过 `:239-241`）、`:262-271`（`CommaExpr.toString`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（空值未处理 / 恒假分支）、§2（同一类内两种空处理策略）
- **证据**：静态确定 —— `EmptyExpr.toString()` 返回 `''`（`LogicalExpr.cj:55-57`），`emptyLogicalExpr` 的正则 `^[\s()]*$` 也能识别空串。但：
  - `NOT` 分支先 `builder.append(op)` 再无条件 `append(' (').append(exprs[0]).append(') ')`，不判空 → `NOT(meet(false){...})` 得到 `' NOT  () '`，外层 `ParenExpr` 再包一层 → `WHERE ( NOT () )`，非法 SQL；
  - `CommaExpr` 逐元素 `append`，`[非空, 空]` 会先补 `','` 再追加 `''` → 尾随逗号 `a,`；
  - `exprs` 为空数组时 `NOT` 分支的 `exprs[0]` 直接越界（当前 `RootDAO.NOT` 只传 `[exprs]` 单元素，触发面 `待确认`）。
- **描述**：`meet(condition, ...)` 的条件为假时返回 `EmptyExpr`，这是本 DSL 的常规写法；把这样的表达式再包 `NOT` 或放进 `CommaExpr` 就会拼出非法 SQL，而不是“整体省略”。
- **建议**：`NOT` 分支先取 `exprs[0].toString()`，`emptyLogicalExpr` 命中时返回 `''`；空数组显式抛 `SqlArgException`；`CommaExpr` 与 `RelationExpr` 一样先跳过空元素再决定是否补分隔符。

### [一般][存量] `MockdbDialect` 默认代理 `opengauss`，只配置 `mockdb` 时被代理方言的 `@Bean` 不存在：分页与标识符引用抛 `KeyNotFoundException`

- **位置**：`f_orm/src/base/Dialect.cj:136-169`（`mock_` 默认 `'opengauss'` `:139`；`limit` / `startInvolver` / `endInvolver` 走 `getDialect(this.mock_)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（初始化顺序 / 配置组合边界）、§12.1（懒加载）
- **证据**：静态确定 —— `OpenGaussDialect` 的装配条件是 `orm_drivers` 包含 `opengauss`（`Dialect.cj:103-104`）；`orm_drivers=mockdb` 时 Bean 不存在，`SqlDialectMediator` 里没有 `opengauss` 条目，`getDialect('opengauss')` 抛 `KeyNotFoundException`。触发点：对 mockdb 执行任何分页（`SqlPartial.cj:297/311`、`TableClause.cj:236`）或任何 `Column.toString()`（经 `involve` → `startInvolver`）。
- **描述**：mockdb 是测试/本地开发驱动，README §19.1 写“默认 `opengauss`”，但没写“必须同时把 opengauss 配进 `orm_drivers`”。单独配 mockdb 时，简单查询能跑，一分页就抛异常，排查成本高。
- **建议**：`mock_` 默认值改为一个必然存在的方言（如 `sqlite`），或在 `MockdbDialect` 的装配条件里要求 `opengauss`；`getDialect` 未命中时抛带方言名与配置值的 `ORMException`；README 补充组合要求。

### [一般][存量] README 承诺 MySQL 追加 `; select last_insert_id()`，`MySqlDialect` 并未覆盖 `lastInsertId`：MySQL/MariaDB 下拿不到自增 id

- **位置**：`f_orm/src/base/Dialect.cj:56-72`（`MySqlDialect` 只覆盖 `dialect`/引号，无 `lastInsertId`）、`:22-24`（基类返回 `''`）；拼接点 `f_orm/src/base/TableClause.cj:488-490`、`:538-540`；文档 `f_orm/README.md:1015`、`f_orm/README_en.md:1099`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现不符）、§14.1（承诺了但没实现）
- **证据**：静态确定 —— 全仓 `lastInsertId` 的覆盖只有 `PostgresDialect`（`Dialect.cj:99-101`）；`MySqlDialect` / `MariaDBDialect` / `SqliteDialect` / `OracleDialect` / `DB2Dialect` 都继承基类空串（README §19.1 自己也把“默认 ''”写进签名注释）。`TableClause.VALUES` 只是 `sqlgen.append(dialect.lastInsertId(idType))`，空串等于什么都没加。
- **描述**：README 用 MySQL 作为“自动追加 lastInsertId 片段”的示例，实际 MySQL 路径什么也不追加，`UpdateResult.lastInsertId` 拿不到自增值。使用方若依赖返回 id（很常见），会得到 0 或驱动默认值，且无任何提示。
- **建议**：`MySqlDialect` 覆盖 `lastInsertId` 返回 `'; select last_insert_id()'`（或改用驱动的 `getGeneratedKeys`），并确认多语句开关与结果集处理；若暂不支持，删除 README 的 MySQL 示例并写明“仅 PostgreSQL 支持”。

### [一般][存量] README 承诺 `@ORMColumn` 与 `@ORMField` 等价，但全仓没有任何宏或代码消费该注解：标注后被静默忽略

- **位置**：`f_orm/src/base/ORMColumn.cj:19-21`；文档 `f_orm/README.md:1791`、`:2212`、`f_orm/README_en.md:1949`、`:2400`；宏侧 `f_orm/src/macros/QueryMappersGenerator.cj` 只解析 `@ORMField`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现 / 接线缺失）、§13（文档与实现不符）
- **证据**：静态确定（README + 搜索）—— 全仓 `grep -rn ORMColumn --include=*.cj`（排除定义文件）零命中；`f_orm/src/macros/` 无 `ORMColumn` 字样，`@QueryMappersGenerator` 的列名/主键/脏标记生成只读 `@ORMField`（`QueryMappersGenerator.cj:215-410`、`ORMField.cj`）。`ORMColumn` 只是声明了 `@Annotation[target: [MemberProperty, MemberVariable]]`，没有任何读取方。
- **描述**：用户在成员上写 `@ORMColumn[name: 'user_name']` 时代码能编译（注解类存在），但宏完全不看它，列名仍按 `LowerUnderScore` 生成，查询/写入落到错误列。这属于“文档承诺的能力不存在”，且失败是静默的（既不报错也不警告）。按 §14 的严重度口径可判严重；因无法完全排除下游自有宏消费该注解，本部分记“一般 + 待确认”，确认无下游后应升级。
- **建议**：在 `@QueryMappersGenerator` / `@ORMField` 的注解读取里增加 `ORMColumn` 分支（name / id 映射到现有列名与主键判定），并补一条用例；或删除注解类与 README 两处条目，避免误导。

### [轻微][存量] §1 死代码：5 个 `newXxx`、`SqlDialectMediator` 4 个方法、`ORM.driverNames`、`DirtyTag.clear<T>`、未用 import

- **位置与证据**（全部为“全仓/本 module 搜索仅定义处命中”）：
  - `GroupedQueryMapper.cj:27-32` `newGrouped`、`:52-57` `newGroupedSingle`、`:78-84` `newNullableGrouped`；`NestQueryMapper.cj:25-30` `newNest`、`:46-52` `newNullableNest` —— 均为 `internal`，宏已改用公开构造函数直接 `new`（`QueryMappersGenerator.cj:279/294/304/319/350/390`），零调用；
  - `Dialect.cj:186-194` 三个 `SqlDialectMediator.lastInsertId`、`:196-198` `limit` —— `internal struct` 成员，调用方一律 `getDialect(...).xxx`，零调用；
  - `ORM.cj:55-59` `driverNames` —— `protected`，`ORM` 是 `public class` 且非 open/sealed，全仓零引用；
  - `DirtyTag.cj:72-74` `clear<T>` —— `protected`，`public struct` 不可被继承，全仓零引用（README:2213 却把它列为“框架内部使用”）；
  - `ORM_test.cj:20` `protected import fountain::f_orm.wrap.*` —— 测试体为空，未使用。
- **判据**：review-checklist §1（非 public 符号无调用者 / 未使用 import）；`protected` 仅“`public open` / `public abstract`（非 sealed）类的成员”豁免，本处不满足。
- **描述**：`newXxx` 看着像 `QueryMapper.new<T>` 的覆盖路径，但名字不同、`QueryMappers.create` 只调基类 `new<T>()`（`QueryMappers.cj:53-60`）——继承场景下 grouped/nest 映射会退化成普通 `QueryMapper`，怀疑是未完成的设计残留（`待确认`）。
- **建议**：删除；若确要支持继承 + 关联映射，应把 `newXxx` 改成 `new<T>` 的真正覆盖（或让 `QueryMappers.create` 按 `isGrouped` 分派），并补用例。

### [轻微][存量] §2 重复逻辑：`ExtendString` 与 `Partials` 两套 AND/OR/NOT、`MeetCondition` 两组仅差字面量、`ORM` 8 个 register 重载、两份 `NoneConnection`

- **位置**：
  - `f_orm/src/base/ExtendString.cj:29-47` vs `f_orm/src/base/Partials.cj:40-57`：同名 AND/OR/NOT；`Partials` 版会 `trimAscii` 判空并只在有内容时补关键字，`ExtendString` 版无条件 append、不判空，且 `"xxx" AND` 会**丢弃字符串接收者**（接收者从未被 append）。仓内零调用（`grep ".AND"` 只命中 `RelationOp.AND`），README §19.4 有描述；
  - `f_orm/src/base/MeetCondition.cj:50-71`（BETWEEN / NOT_BETWEEN）、`:72-111`（IN / NOT_IN）：函数体逐行相同，只差 `between/not between`、`in/not in` 字面量；
  - `f_orm/src/base/ORM.cj:88-132`：8 个 `register` 重载重复“查重 +（部分）warn + 构造 `NamedDatasource`”；其中 `register(driver, opts)`（`:96-102`）少了另外三个都有的 `warn`（README 已声明为静默，属有意漂移，但读代码时极易漏改）；
  - `f_orm/src/base/NoneConnection.cj` 与 `f_orm/src/wrap/NoneConnection.cj` 逐字节相同（仅 `package` 不同），后者全仓零引用（范围外文件，仅提示）。
- **判据**：review-checklist §2（语义相同的多份实现 + 行为漂移）。
- **描述**：这些不是语法重复，是“看起来不是一件事、实际是同一件事”，最容易在下次修改时改一处漏一处；`ExtendString` 版已经和 `Partials` 版行为不同，`NoneConnection` 两副本会随 `Connection` 接口变化漂移。
- **建议**：`ExtendString` 直接转调 `Partials.AND/OR/NOT` 或整段删除；`MeetCondition` 的 IN/BETWEEN 用带 `op` 参数的私有 `frag` 模板合并（保留 `_argInSql` 分派差异）；`ORM.register` 收敛到一个私有实现 + 薄重载；删除 `wrap/NoneConnection.cj`。

### [轻微][存量] 测试质量：`ORM_test.cj` 的唯一用例是空的；`Driver_test.cj` 的测试替身忽略入参且唯一引用被注释

- **位置**：`f_orm/src/base/ORM_test.cj:22-28`（`@Test` 类里 `test()` 只有 `// topTest()`）、`f_orm/src/base/Driver_test.cj:54-56`（`open` 忽略 `connectionString` / `opts`）、`:59-70`（`DatasourceCreatorImpl` 仅被 `DAO_test.cj:23-24` 的注释引用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（空实现 / 空用例）、§10（可测试性）
- **证据**：静态确定 —— `test()` 方法体只有注释，恒过、零断言；`ORM` 的注册/默认驱动/关闭语义（本报告 S1/G5/G6）因此没有任何用例兜底。
- **建议**：补 `register` → `executor` → `close` → 重注册的用例，以及 dirty 更新在事务内/事务外的行为用例；测试替身补一行注释说明“只用于编译/接口占位”。

### [轻微][存量] 文案 / 异常类型 / 命名问题：`CmpExpr` 互斥消息、`connection` 抛 `KeyNotFoundException`、`databasesNames` 名不副实

- **位置**：`f_orm/src/base/LogicalExpr.cj:126-128`（消息 `'SqlFunc alias and SqlFunc alias cannot be set at the same time'`，实际条件是 alias 与 sort）；`f_orm/src/base/ORM.cj:185-191`（`connection(name)` 未做 `hasDefault` / 未命中即 `KeyNotFoundException`）；`:170-174`（`databasesNames` 返回 `DriverManager.drivers()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与命名 / 注释不符）、§10（可读性）
- **证据**：静态确定 —— `Column.toString` 有同款文案错误，part1 已报（`f_orm.part1.md` 轻微第 1 条）；`ORM.connection("")` 在 `default == ''` 时直接 `datasources['']`，抛的是集合的 `KeyNotFoundException` 而非 `ORMException('default datasource is not specified')`（`connection()` 无参版有 `hasDefault`，带参版没有）；`databasesNames` 的返回值是驱动名，与 `datasources` 键集无关（README:370 已说明，但命名仍误导）。
- **建议**：文案改为 `alias and sort order cannot be set at the same time`（README 同步）；`connection(name)` 空名走 `hasDefault()`、未命中抛带驱动名的 `ORMException`；`databasesNames` 改名 `driverNames`（内部成员同名，需一并调整）或补注释。

### [轻微][存量] 设计小疵：`ORM.close()` 用 `printStackTrace`、`argInSql` 读属性带副作用、`ExprSqlExec` 每次 `toString` 新建实例

- **位置**：`f_orm/src/base/ORM.cj:48-52`（`catch { e.printStackTrace() }`）；`f_orm/src/base/LoopCondition.cj:65-70`、`f_orm/src/base/MeetCondition.cj:24-29`（`argInSql` getter 里 `_argInSql = true`）；`f_orm/src/base/LogicalExpr.cj:118`（`private struct ExprSqlExec <: RootDAO {}`）+ `:129/:176/:191`（每次 `toString` 新建）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可读性 / 语言特性）、`fountain-baseline` §6（日志走 f_log）
- **证据**：静态确定 —— `printStackTrace` 绕开 `f_log`，退出阶段也可能写 stderr；`argInSql` 是“读一个属性就改对象状态”，链式调用时顺序敏感、也无法复用；`ExprSqlExec` 每次渲染分配一个 `RootDAO` 实例且依赖 ThreadLocal 当前执行器（与 part1 的 `Column.toString` 同类问题）。
- **建议**：日志改 `log.warn(e)`；`argInSql` 改成返回 `This` 的普通方法（或 `mut prop`）；`ExprSqlExec` 用 `static let instance` 复用，或直接 `SqlExecutor.getCurrent().arg(...)`。

## 范围外提示

- `f_orm/src/macros/QueryMappersGenerator.cj:319-323` 以 `name: $columnName` 构造 `GroupedQueryMapper`，但 `GroupedQueryMapper` 的构造函数（本部分 `GroupedQueryMapper.cj:21-24`）只有 `grouped!` / `groupedGetter!`，没有 `name`。该分支（非可空、非简单类型、无 converter 的 `ArrayList<实体>` 字段）一旦被使用会编译失败；仓内无此类实体，故未在构建中暴露。属宏文件（其它部分），仅提示，不计入本部分统计。

## 优化可行性方案

### [堆内存] `DirtyTag.clearAll()` 每次非事务查询都为每个已注册类型分配一个 `DirtyTag` 并写回 `ConcurrentHashMap`

- **现状**：`close()`（`SqlExecutor.cj:172`）在**每条**非事务 SQL 结束后调用 `clearAll()`（`DirtyTag.cj:75-79`），后者遍历 `DIRTY_TAGS` 并对每个类型执行 `clear`：`tag.dirtyFields.set(None)` + `DIRTY_TAGS[typeInfo] = DirtyTag(beforeDirty: false, dirtyFields: tag.dirtyFields)`。对象数/写入次数 = 本线程查询过的 PO 类型数 N（每次查询 N 次 map 写 + N 个 struct 分配）；生命周期仅到下一次查询。
- **方案**：把 `beforeDirty` 并入 `ThreadLocal`（与 `dirtyFields` 同粒度），`close()` 不再全表重写；`clearAll` 改成“清空当前线程自己的 `ThreadLocal` 容器”，或只在 `dirtyFields` 非空时 `clear()`。
- **预期**：去掉每查询 O(N) 次 map 写与 N 个结构体分配；N=PO 类型数（本项目单模块常见 10~100）。
- **代价**：需重做 `DirtyTag` 状态模型（S1/S2 的修法本身就会覆盖这一项）；若同时修复并发问题，收益与正确性修复合并计算，不能单独归因。
- **验证**：固定 50 个 PO 类型、跑 10 万次 `list` 查询，对比 `getAllocatedHeapSize()` 与 RSS 稳态；用 `cjprof` 看 `DirtyTag.clear` 的 self time 与分配占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 生成的 setter 每次赋值都做 `ConcurrentHashMap.get(TypeInfo)` + `HashSet.add`

- **现状**：`DirtyTag.setDirtyField<T>`（`DirtyTag.cj:34-49`）被 `@ORMField` 生成的 setter 每次调用（`QueryMappersGenerator.cj:204`），先 `DIRTY_TAGS.get(TypeInfo.of<T>())` 再 `ThreadLocal` 取值、`HashSet.add`；批量映射/批量赋值时是“每字段一次 map 查找”。
- **方案**：在 `ThreadLocal` 中缓存“当前线程当前类型的 `DirtyTag` 句柄”（按 `TypeInfo` 命中一次即可），后续 `setDirtyField` 走线程本地直取；或在 `QueryMappers` 生成时把 tag 句柄绑定到 mapper 上。
- **预期**：把每字段一次并发 map 查找降为一次 ThreadLocal 取值；收益取决于字段数与赋值频率。
- **代价**：多一层缓存失效管理（类型注册后需刷新）；语义不变。
- **验证**：`cjpm bench -O2` 对比“100 万次 setter”与“10 万对象映射”，看中位数与 P95；`cjprof` 看 `ConcurrentHashMap.get` 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DirtyTag.clearAll` 的 O(#types) 全表重写在“每语句一次 close”下构成固定开销 | `DirtyTag.cj:75-79` + `SqlExecutor.cj:172` | 每次 `close` 的耗时、占比、N 的实际分布 | `cjprof record` 跑 10 万次 `list`（50 个 PO 类型），看 `clearAll` self time 与分配量 |
| 2 | 生成 setter 里的 `DirtyTag.setDirtyField` 是批量赋值/映射的主要额外开销 | `DirtyTag.cj:34-49`、`QueryMappersGenerator.cj:204` | 每字段查找耗时、调用次数 | 对 10 万对象 × 20 字段做赋值/映射，`cjprof` 看 `ConcurrentHashMap.get` / `TypeInfo.of` 占比 |
| 3 | `SqlDialectMediator.getDialect` 的字符串 key 查表在 SQL 渲染里占比可观（本部分补充 `MockdbDialect` 的二次查表） | `Dialect.cj:175-182`、`:156-168` | 每请求渲染次数、自耗时 | 20 列 × 10 万次 `toString`，`cjprof` 分段计时（与 part1 假设 #1 同源，合并采一次即可） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/base/Dialect.cj` | .cj | ✅ | 见「一般」1（懒加载竞态）、8（mockdb 耦合）、9（MySQL lastInsertId）、「轻微」1（mediator 死代码） |
| 2 | `f_orm/src/base/DirtyTag.cj` | .cj | ✅ | 见「严重」1/2（脏追踪被清空、跨线程标志）、「轻微」1（`clear<T>` 死代码） |
| 3 | `f_orm/src/base/Driver_test.cj` | .cj | ✅ | 测试文件（`_test.cj`）：`DriverTest` / `DatasourceCreatorImpl` 仅测试引用，接口实现齐全；无缺陷，见「轻微」3 |
| 4 | `f_orm/src/base/ExtendString.cj` | .cj | ✅ | 与 `Partials` 的 AND/OR/NOT 重复且行为漂移、仓内零调用；见「轻微」2 |
| 5 | `f_orm/src/base/GroupedQueryMapper.cj` | .cj | ✅ | 见「严重」3（`prevSize` 恒假）、「轻微」1（3 个 `newXxx` 死代码） |
| 6 | `f_orm/src/base/IdQueryMapper.cj` | .cj | ✅ | `id()` 用 `getOrThrow()`，NULL 主键抛 `NoneValueException` 而非 `ORMException`（与「轻微」4 的异常类型问题同类，未单列）；其余无缺陷 |
| 7 | `f_orm/src/base/LogicalExpr.cj` | .cj | ✅ | 见「一般」4（空 IN）、6（IN 列名不引用）、7（NOT/Comma 空表达式）、「轻微」4（文案）/5（`ExprSqlExec` 每次分配） |
| 8 | `f_orm/src/base/LoopCondition.cj` | .cj | ✅ | 见「一般」5（索引不自增）、4（空集合）；`argInSql` getter 副作用见「轻微」5 |
| 9 | `f_orm/src/base/MeetCondition.cj` | .cj | ✅ | 见「一般」4（IN 空集合）、「轻微」2（IN/BETWEEN 两组重复）、5（getter 副作用） |
| 10 | `f_orm/src/base/NestQueryMapper.cj` | .cj | ✅ | 见「严重」3（`nestGetter` 未用 → NULL 关系变空对象）、「轻微」1（2 个 `newXxx` 死代码） |
| 11 | `f_orm/src/base/NoneConnection.cj` | .cj | ✅ | Null Object 语义正确（`close()` 空、`state=Closed`）；与 `wrap/NoneConnection.cj` 重复，见「轻微」2 |
| 12 | `f_orm/src/base/ORM.cj` | .cj | ✅ | 见「一般」2（`default` 竞态）、3（`close` 不清理注册表）、「轻微」2（8 个重载）、4/5 |
| 13 | `f_orm/src/base/ORMColumn.cj` | .cj | ✅ | 见「一般」10（注解无消费者，README 承诺等价能力） |
| 14 | `f_orm/src/base/ORMInitializer.cj` | .cj | ✅ | `static init` 注册 `InitializerCollection`，`dependencies=['fountain::f_bean']` 与实际初始化顺序一致（`f_config` 无 Initializer，配置按需读），无缺陷 |
| 15 | `f_orm/src/base/ORM_test.cj` | .cj | ✅ | 唯一用例为空，见「轻微」3 |

合计：`.cj` 15 个 / `.md` 0 个（本部分清单不含 `.md`；§13 对照读过 `f_orm/README.md`、`f_orm/README_en.md` 相关小节，未计入本表），共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 13 | 正确性 7（脏追踪被清空、NULL 关联映射、空 IN、循环索引、NOT 空表达式、IN 列名、MySQL id）；设计 3（`DirtyTag` 粒度混用、`ORM.close` 状态机缺失、`ORMColumn` 空挂）；语言特性 2（`argInSql` getter 副作用、`ExprSqlExec` 每次分配 + ThreadLocal 依赖）；可读性 2（错误文案、`databasesNames` 命名）；安全性 0（`argInSql` 直接拼值属 README §11.5 明示的受控特性，不重复计缺陷；`involvedIdentifier` 的注入面已由 part1 一般第 4 条覆盖） |
| §1 死代码 | 1（涉及 12 个符号） | 逐个机械过：5 个 `newXxx`（全仓 `grep` 仅定义处）、`SqlDialectMediator` 3 个 `lastInsertId` + `limit`（internal，仅定义处）、`ORM.driverNames`（protected，ORM 非 open/sealed）、`DirtyTag.clear<T>`（protected，public struct 不可继承）、`ORM_test.cj` 1 个未用 import、`NullableNestQueryMapper.nestGetter`（私有字段未读，并入「严重」3）。private 符号（`DirtyTag.register`/`clear(typeInfo)`、`MockdbDialect.mock_`、`ExprSqlExec`、`ExtendString.getPartials/append`、`LoopCondition` 全部字段）均有引用；对外可达 public（`SqlDialect.*`、`ORM.register*`、`ORMColumn`、`ExtendString`、`NoneConnection.instance`、`DriverTest`）按硬原则一不判，只记“仓内无引用” |
| §2 重复逻辑 | 1（4 组） | 已按「输入-输出-副作用」两两比对 15 个文件：`ExtendString` vs `Partials`（行为已漂移）、`MeetCondition` IN/NOT_IN 与 BETWEEN/NOT_BETWEEN（仅字面量差）、`ORM` 8 个 register 重载、`NoneConnection` 两份逐字节副本。`GroupedQueryMapper` / `NestQueryMapper` 与 `Nullable*` 的 populate 属“近似重复且少了空值判断”，已并入「严重」3，不另计。方言子类仅 `dialect` 字面量不同，属枚举式实现，不判重复 |
| §3 空实现 | 1 | `ORM_test.test()` 空用例（「轻微」3）。`NoneConnection.close()` / `EmptyExpr` 的一批 no-op 是有意的 Null Object（`EmptyExpr` 由 `RootDAO.meet` 在条件为假时返回，见 `RootDAO.cj:398-430`），按清单不判缺陷；`SqlDialect.lastInsertId` 默认 `''` 是 README 明示的默认行为 |
| §4 栈溢出 | 0 | `DirtyTag.setDirtyField` / `setBeforeDirty` 的 `else { register(); 递归 }` 是 2 层有界重试（`register` 必写入，`DIRTY_TAGS` 只增不删）；无对象图/树/JSON 递归，无自引用结构，无递归 `clone`/`deepCopy` |
| §5 OOM | 0 | `DIRTY_TAGS` 键为 PO 类型（有界），`ThreadLocal<HashSet<String>>` 按 线程×类型 有界；无全量读入/按报文长度预分配/无界缓存；`GroupedQueryMapper` 的 `ArrayList` 大小由结果集行数决定，属业务数据量而非无界增长 |
| §6.1 热点瓶颈 | 0 | `scope.md`「已有性能资料」为空，未提供 profile/bench；`clearAll`、`setDirtyField`、`getDialect` 三条线索全部降级为「待验证假设」与优化方案，不作发现 |
| §6.2 大粒度锁 | 0 | 本部分 15 个文件无 `synchronized` / `Mutex` / 显式锁；并发问题均为“缺同步”而非“锁太大”，归 §12.1 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无任务提交/线程池 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `contains`/`indexOf` 热路径、无 `remove(at: 0)`；`register()` 里 `for (... where d == mockdb)` 是常量级小数组扫描，不构成发现。`clearAll` 的 O(#types) 属待验证性能假设（见上） |
| §7 降堆内存方案 | 1 | `clearAll` 每查询 N 个 `DirtyTag` 分配（无基线，标「无基线（待验证，不进 tasks）」） |
| §8 降 CPU 方案 | 1 | setter 内 `ConcurrentHashMap.get` / `TypeInfo.of` 的每字段开销（无基线，同上） |
| §9 local mode 可行性 | 0 | 本部分无“函数内创建、函数内销毁且不逃逸”的大对象：SQL 片段都以 `String` 返回并进入执行器/结果，`StringGenerator` 为引用类型且跨函数传递；缺峰值内存基线，不列方案 |
| §11 现有代码的 BUG（存量） | 18 | 严重 3（脏追踪清空、跨线程脏标志、NULL 关联映射失效）、一般 10、轻微 5；全部标 `[存量]`，默认只报不修。每条均有位置 + 判据 + 证据等级 |
| §12 并发安全与锁粒度 | 3 | 共享点逐个核对：`ORM.default`（裸 static var，读写无同步）→「一般」2；`DirtyTag.beforeDirty`（类型级全局 + 读改写非原子）→「严重」2；`SqlDialectMediator.dialects`（`isEmpty` 判空 + 循环填充）→「一般」1。另观察：`MockdbDialect.mock_` 由 public `mut prop` 写入、`limit`/引号属性读取，无同步（通常只在测试初始化设置，未单列，并入 `待确认`）。`DirtyTag.dirtyFields`、`SqlExecutor.current/currents`、`Condition.delimiter` 均为 `ThreadLocal`，线程封闭；**锁粒度**：本部分无锁，无从谈粒度 |
| §13 文档一致性 | 3 | (1) README:1015 / README_en:1099 的 MySQL `last_insert_id` 与实现相反（「一般」9）；(2) README §11.4 写 `condition` 第二参为“下标”，实现是“已接受元素个数”（「一般」5）；(3) README:2213 把 `DirtyTag.clear<T>` 列为“框架内部使用”，实际零调用（「轻微」1）。其余 `SqlDialect` 签名、`MeetCondition` / `LoopCondition` 成员、`ORM` 全部重载、`Grouped/Nest/Nullable*` 构造函数与 README §19.1/§13.3 逐项一致，`README_en` 与中文版章节同步 |
| §14 功能完备性与 README 覆盖 | 1 | `@ORMColumn` 被 README 承诺为“与 `@ORMField` 等价”，全仓无消费者（「一般」10）。其余 public 声明均能在 README 找到条目；`ExtendString` / `DirtyTag` / `ORMInitializer` 见 §19.4；本部分无“新 public API 未进 README” |
| 文件覆盖（§13 等） | 15/15 | 本部分 15 个文件全部读完，逐文件结论见上表；`.md` 不在本部分清单内，模块 README 的一致性按上表 §13 结论执行 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 10 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

> 本部分存量缺陷合计 18 条（含轻微），默认只报不修；是否纳入修复清单请用户在门禁决定。统计只含这 15 个文件，不含 `f_orm` 其余 96 个文件；`f_orm.part1.md` 已报的 `Column.toString` ThreadLocal 依赖、标识符引用绕过、`ChooseCondition.done`/`MeetCondition.done` 重复不在此重复计数。

## 总评

本部分是 f_orm 的“方言 + 脏标记 + 关联映射 + ORM 门面”，是 ORM 的核心契约面。三个阻塞项都在“静默失效”这一类：

1. **脏字段更新在非事务路径下完全不工作**（严重）：`setBeforeDirty` 之后 `execute` 的 `finally` 立刻 `close()` → `DirtyTag.clearAll()`，把刚打开的追踪关掉；`UPDATE(dirty: true)` 因此静默返回 0。README 没有“必须事务内”的限制，按文档写就是错的；迭代器装载的实体更是永远不开启追踪。修法是 `beforeDirty` 线程本地化 + `close` 不清状态，同时补 iterator 路径。
2. **`DirtyTag` 的状态粒度混用**（严重）：`dirtyFields` 每线程、`beforeDirty` 每类型，加上三处“检查-然后-写入”，并发下既漏标也误标；误标会导致“更新了没改过的字段”。这条与第 1 条同源，建议一次性重做状态模型（ThreadLocal 内同时放 beforeDirty 与集合）。
3. **Nullable 关联映射的空值语义丢失**（严重）：`NullableGroupedQueryMapper` 的 `prevSize == list.size` 是恒假条件（`add` 之后比较），`NullableNestQueryMapper` 的 `nestGetter` 根本没被读；left join 的全 NULL 子行会变成空对象而不是 `None`，且这两条路径零测试。

其余按后果排序：`getDialect` 懒加载竞态与 `ORM.default` 无同步是偶发 `KeyNotFoundException` 的来源；`ORM.close()` 不清注册表让“关闭后重新初始化”不可用；空 `IN` 集合与 `NOT(EmptyExpr)` 会在常规边界拼出非法 SQL；MySQL 的 `last_insert_id`、`@ORMColumn` 两处是 README 承诺与实现相反/为空，属于文档或功能闭环问题，建议先修文档再决定是否补实现。死代码与重复逻辑命中具体但便宜（5 个 `newXxx`、4 个 mediator 方法、`ORM.driverNames`、`DirtyTag.clear<T>`、两份 `NoneConnection`、`ExtendString` 与 `Partials` 两套 AND/OR/NOT），建议与上面的语义修正一并清理。性能线索（`clearAll` 的 O(#types) 重写、setter 的每字段 map 查找）没有 profile 数据，只作为「待验证假设」和「无基线优化方案」，不进修复清单。
