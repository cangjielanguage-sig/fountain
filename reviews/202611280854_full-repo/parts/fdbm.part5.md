# fdbm 模块审查报告（第 5/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fdbm/src/route`、`fdbm/src/server`、`fdbm/src/sql`（本部分 18 个源文件，全部 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源记「存量」
- **审查重点**：多数据源与连接生命周期、启动期装配、并发安全、死代码、重复逻辑
- **报告版本**：分部分 v1（本部分；合并结果由主 Agent 写入 `fdbm_v2.md`）

> 契约证据取自 `fdbm/doc/详细设计.md`（不在本部分文件清单内，仅作「承诺源」引用，不展开审查）。
> 语言/标准库语义已用 `cangjie-doc-lookup` 核对（`std.sync` 的 `Condition.wait` 返回值、`Timer.repeat` 签名）。

## 发现

### [严重][存量] 非分库列条件被展开成「全部分片」，UPDATE/DELETE 静默广播到所有物理库

- **位置**：`fdbm/src/route/router.cj:316`、`:320-336`（`expressionConstraint`）；配合 `fdbm/src/sql/PartitionKeyExtractor.cj:79-90`、`:289-296`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）、§2（近似重复导致的分支漂移）；设计承诺见 `doc/详细设计.md:460`、`:464`
- **证据**：静态确定 —— 逐分支推演即可复现（见描述）
- **描述**：
  1. `RangeContext.collect` 对非 `AND/OR/`比较运算/`NOT`/`IN` 的子树直接返回 `RangeResult(true)`（`PartitionKeyExtractor.cj:293`），即「可判定但无边界」。于是 `WHERE name = 'x'`、`WHERE name LIKE 'a%'`、`WHERE id != 5` 这类条件经 `extractRange` 得到 `Some(PartitionRange(None, true, None, true))`（`PartitionKeyExtractor.cj:86-89`）。
  2. `expressionConstraint` 只用 `ranges.isNone()` 区分「有没有范围条件」（`router.cj:316`），把「无边界」当成「有范围」；`case step` 分支随即调用 `step.partitionRange(None, true, None, true)`（`router.cj:324`），该实现把无边界视为完整数据域 `[1, N*step]`（`fdbm/src/route/algorithms.cj:91`、`:104`），返回**全部**物理库。
  3. 结果：`plan.kind == Multi`（全部库）而不是 `Unroutable`。`UpdateExecutor`/`DeleteExecutor` 对 `Multi` 逐库执行并累加 `rowCount`（`fdbm/src/execute/executors.cj:521-537`、`:591-...`），只有 `Unroutable` 才报 `ROUTE_FAILED`（`:513-516`、`:577-580`）。受影响面是 `step` 分片；其它算法走 `router.cj:330-333` 的 `case _` 分支，无等值时返回 `None`，行为正确。
  4. 与设计相反：设计明确「有分片表但抽不到条件 → `Unroutable`」「`UPDATE`/`DELETE` 缺分库列条件 → 报错 `ROUTE_FAILED`」（`doc/详细设计.md:460`、`:464`）。实际效果是 `DELETE FROM t WHERE name='x'` 在**所有分片**上执行，唯一的安全闸门被绕过；事务内还会因为 `Multi` 触发 `ensurePinnedTargets` 得到另一种错误，行为前后不一致。
  5. 旁证：`PartitionRange.isEmpty()`（`PartitionKeyExtractor.cj:37-53`）从未被调用——「空/无边界」的判定本应在这里，但没接线。
  6. 现有用例只覆盖「完全无 WHERE」（`fdbm/src/route/Route_test.cj:266-269`）与「等值 + 范围」（`:290-295`），没有「只有非分库列条件」的用例，所以缺陷未被发现。
- **建议**：在 `expressionConstraint` 里显式区分「有边界」与「无边界」：
  ```cangjie
  let hasBound = match (ranges) {
      case Some(r) => r.lo.isSome() || r.hi.isSome()
      case None => false
  }
  if (equals.isEmpty() && !hasBound) { return None<Array<String>> }
  ```
  并补两条用例：`update t set name=1 where name='x'` → `RouteKind.Unroutable`；`delete from t where id != 5` → `Unroutable`。`PartitionRange.isEmpty()` 要么接到这里，要么删除（见轻微条目）。

### [严重][存量] 递归下降解析器无深度上限，单条深嵌套 SQL 可使 fdbm 进程栈溢出

- **位置**：`fdbm/src/sql/SqlParser.cj:601-603`、`:613-626`、`:628-667`、`:714-735`（`factor` 的 `LParen` 分支在 `:731-735` 回到 `expression()`）；同类递归 `:845-853`（派生表 `tableRef` → `select()`）
- **来源**：存量
- **判据**：review-checklist §4（无界递归）、§11（崩溃）
- **证据**：静态确定 —— 递归入口只由输入 token 驱动，代码中无深度计数、无迭代栈、无长度上限
- **描述**：`expression → orExpression → andExpression → notExpression → comparison → additive → multiplicative → factor`，每遇到一个 `(`、一个 `NOT` 或一层派生表就再进一轮（约 7~8 个栈帧/层）。SQL 文本来自客户端，`Dispatcher.execute` 对每条语句直接 `SqlParser.parse`（`fdbm/src/execute/dispatcher.cj:79`）；`f_protocol` / `f_net` 未发现单条报文长度上限（全仓无 `maxLength`/`sizeLimit` 类限制）。因此 `select ((((…1…))))` 这类几千层括号的请求即可耗尽 worker 线程栈，栈溢出导致整个 fdbm 进程退出（不是单请求失败）。`notExpression` 的 `not not not …` 与派生表嵌套同理。同一输入还会依次进入 `PartitionKeyExtractor.collect`、`BindContext.bindExpression` 的递归，深度与解析深度同阶，属同一根因。
- **建议**：在 `SqlParser` 增加 `depth: Int64` 字段，`expression()` / `tableRef()` 进入时 `+= 1`、退出 `-= 1`，超过常量（如 200）抛 `FdbmException(UNSUPPORTED_SQL, 'expression nesting too deep')`；或在 lexer 层限制括号嵌套深度。补一条超深输入的负向用例。

### [一般][存量] 无 `from` 的常量查询（如 `select 1`）被路由成 Broadcast，结果按物理库份数重复

- **位置**：`fdbm/src/route/router.cj:166-178`（`!hasNonGlobalTable` 分支）；配合 `fdbm/src/execute/executors.cj:311-315`、`:331-336`、`:294-308`
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误）、§10（正确性）
- **证据**：静态确定 —— 路由分支 + 执行器合并路径可完整推演
- **描述**：
  1. `select 1` 的 `statement.tables` 为空（`fdbm/src/sql/ast.cj:338-353`），`route()` 的循环不执行，`hasNonGlobalTable` 与 `hasPartitionedTable` 均为 `false`，于是进入 `:172` 的「全部是全局表」分支，取 `globals.physicalDatabases(logical)`。该映射来自 `LogicalCatalog`，被分库规则引用的逻辑库会隐式展开为**全部**物理库（`fdbm/src/config/catalog.cj:75-77`），因此 `plan.kind == Broadcast`（`:174-176`）。
  2. `SelectExecutor.targetDatabases` 对 Broadcast 只做「全局表只取一份」的优化，而 `globalOnly()` 对空 `tables` 明确返回 `false`（`executors.cj:313-315`），于是所有物理库都保留；`:297-301` 每库开一段 `CursorSegment`，:308 串成一个游标 → 客户端读到 N 行 `1`（N = 物理库数）。
  3. 影响：`select 1` / `select 'x'` / `select ?` 这类探活、常量查询在分片库上返回重复行；客户端 `query.next()` 循环、`count` 统计都会多算。f_dbd 的池检查 SQL 默认就是 `select 1`（`f_dbd/src/multid/Config.cj:137`），只调 `next()` 时不会报错，所以问题被掩盖。该问题只在 `logicalDatabases` 已装配（生产路径由 `FdbmServer.cj:81-82` 传入 `catalog.toMap()`）时出现；`Handler_test` 的 `Harness` 用 `GlobalTableRouter([])` 未传映射，`physicals` 为空 → 走 `Unroutable`，因此现有用例覆盖不到。
- **建议**：在 `route()` 开头对 `statement.tables.isEmpty()` 单独处理：返回 `RoutePlan.single(physicals[0])`（逻辑库首个物理库，与「未分库表」一致），或在执行器侧把「无表」视作只需一份副本（`globalOnly` 返回 `true`）。补用例：双物理库下 `select 1` 只返回 1 行。

### [一般][存量] 优雅停止存在会话泄漏窗口：`InFlight` 与 `SessionRegistry` 都不检查 `closed`

- **位置**：`fdbm/src/server/FdbmServer.cj:197-199`、`fdbm/src/server/InFlight.cj:36-38`、`fdbm/src/server/SessionRegistry.cj:46-58`（`of`）、`:71-94`（`closeAll`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 异步语义）、§11（资源不对称）
- **证据**：静态确定（缺失守卫）+ 依赖 `f_net` 的关闭语义：`Server.close()` 只关监听与缓冲，不 join 每连接线程、不等待 `executors.call` 排队中的任务（`f_net/src/server/server.cj:169`、`:209-211`）
- **描述**：`stop()` 先用 `InFlight.await` 等在途请求归零（只统计**已经**调用过 `enter()` 的请求），再 `sessions.closeAll()`、`resources.closeAndAwait()`。但 `f_net` 的关闭不等待已排队/正在启动的 handler，于是存在如下交错：`await` 返回 `true` → `closeAll()` 清空并关闭全部会话、取消巡检定时器 → 一个刚被调度到的 `FdbmHandler.handle` 才执行 `InFlight.enter()`（`handler.cj:64`）→ `sessions.of(buffer)`（`handler.cj:79`）在 `closed == true` 的注册表里**新建并放入**一个会话。该会话此后既不会被巡检回收（`timer.cancel()` 已执行），也不会再被 `closeAll` 关闭，其游标/`pin` 连接留到进程退出；若它借到了正在关闭的连接池，还会让 `closeAndAwait` 走到超时分支（`:199-201` 只记 WARN）。
- **建议**：`SessionRegistry.of()` 先判 `closed.load()`，关闭后不再新建：返回一个已关闭的会话，或让 `of` 返回 `?DbdSession` 并在 handler 回 `CURSOR_STATE`/`INTERNAL`；同时让 `InFlight.enter()` 返回 `Bool`（`closed` 则拒绝），`handle` 在 `closed` 时直接回错误包。这样「关闭后不再产生新会话/新查询」成为显式契约，而不是依赖 `f_net` 恰好没有排队任务。

### [一般][存量] `stop()` 与 `start()` 对 `server` 字段的发布无同步，启动期停止可能漏关监听

- **位置**：`fdbm/src/server/FdbmServer.cj:50`（`private var server`）、`:151-165`（写）、`:188-196`（读）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 发布逸出）
- **证据**：静态确定（无锁、无原子、非线程封闭；`closed`/`started` 的原子操作不覆盖该字段的读写配对）
- **描述**：`start()` 在 `:151` 检查 `closed`/`started` 后构造 `Server` 并在 `:165` 赋值 `this.server`；`stop()` 在 `:184` 置 `closed` 后于 `:188` 读 `server`。若另一线程（内嵌用法、信号线程）在 `:151` 与 `:165` 之间调用 `stop()`，它会看到 `server == None` 而跳过 `close()`，随后继续关会话与连接池并返回；`start()` 接着进入 `server.start` 的 accept 循环，`closed` 已为 `true` 但监听无人关闭，再次调用 `stop()` 又在 `:184` 直接返回。后果：进程不退出、端口继续监听，而连接池已关，接入的请求全部 `INTERNAL`。窗口很窄（构造 `Server<>` 期间），但 `stop()` 是公开方法，任何线程都可调用。
- **建议**：把 `server` 的发布/读取纳入同一把锁（或用一个 `AtomicOptionReference`/`Mutex` 保护的 `Option<Server>`），并在 `start()` 赋值后再检查一次 `closed`：已关闭则立刻 `server.close()` 并返回。另可让 `stop()` 在 `server == None` 时记 WARN，便于发现该路径。

### [一般][存量] 协议错误日志打印完整客户端 payload，存在日志放大与敏感数据落盘

- **位置**：`fdbm/src/server/handler.cj:213`
- **来源**：存量
- **判据**：review-checklist §10（安全性：敏感数据进日志）；`fountain-baseline.md` §6（不得记录凭据 / 完整报文）
- **证据**：静态确定 —— `message.data` 是客户端原始 payload（`CONSUME` 时可能是含 SQL 与参数的 `SqlPayload`），日志未截断、未脱敏
- **描述**：`protocolError` 在无法识别 payload / command 时执行 `logger.warn('${reason} (command=${message.command}, payload=${message.data})')`。两个问题：(a) `message.data` 长度由客户端决定，可把任意大小的报文一次性写进日志（`WARN` 级别通常默认开启），构成日志放大；(b) SQL 文本与绑定参数、以及任意二进制内容会原样落盘，且内容中的换行可污染按行解析的日志。
- **建议**：只记录 `message.id`、`command` 的类型名与 `payload` 的类型/字节长度（例如 `payloadType=SqlPayload, size=…`）；确需细节时用 `debug` 且截断到固定长度。错误响应（`DbdErrorPayload`）已带原因，日志无需重复报文。

### [一般][存量] `CustomLoader` 与 `DriverLoader` 四个辅助函数逐字复制，且 `joinNames` 有三份、分隔符不一致

- **位置**：`fdbm/src/server/CustomLoader.cj:120-163` 与 `fdbm/src/server/DriverLoader.cj:96-139`（`librariesOf` / `isLibrary` / `withoutExtension` / `sort`）；`fdbm/src/route/router.cj:477-488`、`fdbm/src/server/DriverLoader.cj:84-93`、`fdbm/src/execute/executors.cj:194-202`（`joinNames`）
- **来源**：存量
- **判据**：review-checklist §2（只改参数名的复制、字面量复制导致的行为漂移）
- **证据**：静态确定 —— 四处函数体逐行对齐，仅形参名不同；`joinNames` 一处用 `','`、两处用 `', '`
- **描述**：`librariesOf`（目录遍历 + `isLibrary` + 插入排序）、`isLibrary`、`withoutExtension`、`sort` 在两文件里完全一致，约 70 行重复；插入排序另在 `fdbm/src/config/catalog.cj:184-195`、`fdbm/src/execute/executors.cj:1206-1218` 还有两份，共 4 份。重复已经开始漂移：`isLibrary` 大小写不敏感、`withoutExtension` 大小写敏感（见轻微条目），两处副本同时带着这个缺陷，说明是复制而来。`joinNames` 三个副本的拼接分隔符不同（`a,b` vs `a, b`），同一类错误信息在不同执行器里格式不一致。
- **建议**：两个 loader 同在 `fountain::fdbm.server` 包内，抽一个包级 `internal` 辅助（如 `server/LoaderSupport.cj`：`librariesOf(dir)`、`isLibrary`、`withoutExtension`、`sortedInPlace`），两侧改为调用；`joinNames` 收敛到一处（建议统一 `', '`），其余两处删除。抽取消除了 `:151-163` 与 `:127-139` 的整段重复，也让大小写修复只需改一处。插入排序若要复用，应放到 `fdbm` 内的通用 util，而不是跨层依赖 `f_util`（`f_dbm` 层不得反向依赖上层）。

### [轻微][存量] `isLibrary` 与 `withoutExtension` 的大小写口径不一致

- **位置**：`fdbm/src/server/CustomLoader.cj:137-149`；同缺陷复制在 `fdbm/src/server/DriverLoader.cj:113-125`
- **来源**：存量
- **判据**：review-checklist §11（同一功能内判定口径不一致）、§2（复制后漂移）
- **证据**：静态确定 —— `isLibrary` 先 `name.toLower()` 再判后缀（`:137-140`），`withoutExtension` 直接对原串 `endsWith('.so')`（`:142-149`）
- **描述**：名为 `PG.DLL` / `libFoo.SO` 的驱动或扩展会被 `isLibrary` 认定为库并进入 `librariesOf` 结果，但 `withoutExtension` 不会剥离大写扩展名，`PackageInfo.load('/…/PG.DLL')` 直接失败，启动报 `CONFIG`/`NO_DRIVER`，而正确行为应是加载成功。
- **建议**：`withoutExtension` 与 `isLibrary` 共用同一份小写判定：先 `let lower = path.toLower()`，命中后缀后按 `ext.length` 切片；两处修复后合并为同一辅助函数（见发现 #7）。

### [轻微][存量] 7 处未使用 import

- **位置**：`fdbm/src/server/FdbmServer.cj:18`（`HashMap`）、`fdbm/src/server/InFlight.cj:18`（`Condition`）、`fdbm/src/server/handler.cj:26`（`ExecutionOutcome`）、`fdbm/src/server/GracefulShutdown_test.cj:20`（`DataAny`）、`fdbm/src/server/Handler_test.cj:24`（`DataBool`）、`fdbm/src/server/Handler_test.cj:35`（`DbdSession`）、`fdbm/src/server/Server_test.cj:27`（`LoggerFactory`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 逐个符号在本文件内做整词搜索，仅 import 行命中（`UnicodeStringExtension` 这类为扩展方法提供可见性的 import 已排除，不算未使用）
- **描述**：冗余 import 不影响运行，但会掩盖真实的依赖方向，且 `cjlint` 会报警告。
- **建议**：删除上述 7 个符号；`FdbmServer` 若后续需要 `HashMap` 再引入。

### [轻微][存量] 无引用声明与不可达语句

- **位置**：`fdbm/src/route/router.cj:271-273`（`PartitionRouter.isPartitioned`）、`fdbm/src/sql/PartitionKeyExtractor.cj:37-53`（`PartitionRange.isEmpty`）、`fdbm/src/server/Handler_test.cj:466-476`（`freePort`）、`fdbm/src/server/Handler_test.cj:439`（`while (true)` 之后的 `0`）
- **来源**：存量
- **判据**：review-checklist §1（非 public 顶级声明里的 public 成员无使用 = 死代码；return 之后同层语句）
- **证据**：静态确定 —— 在 `fdbm/src`、`f_orm/src`、`f_dbd/src` 全量搜索符号名，仅定义处命中；`PartitionRouter` 与 `PartitionRange` 都是 `protected` 类型，对外不可达，成员 `public` 不构成对外契约；`freePort` 仅在一行注释里被提到
- **描述**：四处均为历史残留。`PartitionRange.isEmpty()` 尤其值得注意：它本可用于区分「无边界」，但调用点缺失（见发现 #1）。
- **建议**：`isPartitioned`、`freePort`、`uniquePort` 末尾的 `0` 直接删除；`isEmpty()` 若用于修复发现 #1 则保留并接线，否则删除。

### [轻微][存量] `SqlParser.factor` 解析完函数实参后立即抛错，`args` 从未被读取

- **位置**：`fdbm/src/sql/SqlParser.cj:768-776`
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 无效工作）
- **证据**：静态确定 —— `args.add(...)` 之后无条件 `throw unsupported(...)`，`args` 与 `expect(RParen)` 的结果都不参与错误消息
- **描述**：函数调用一律不支持，解析实参只为推进游标；游标随后丢弃（异常直接上抛），因此这段解析完全是白做的，且在超长实参列表上白白消耗 CPU。
- **建议**：`if (accept(TokenKind.LParen))` 后直接抛 `unsupported`；若要保留「定位到右括号」的错误信息，应把 `peek().position` 用进消息，而不是构造 `args`。

### [轻微][存量] 测试夹具忽略 `waitForPort` 的返回值

- **位置**：`fdbm/src/server/Handler_test.cj:403`、`fdbm/src/server/Integration_test.cj:304`
- **来源**：存量
- **判据**：review-checklist §11（返回值被忽略导致失败点错位）
- **证据**：静态确定 —— `waitForPort` 返回 `Bool`（`Handler_test.cj:443`），两处调用都丢弃结果
- **描述**：端口在 5s 内没有就绪时，后续 `Client.build()` 会抛连接异常，测试失败信息指向「连接被拒」而不是「服务未起来」，排查成本高；`Server_test` 的正确用法是 `@Assert(waitForPort(port), true)`（`:237`、`:316`）。
- **建议**：两处改为断言或抛带端口的明确错误。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下均无改前/改后对照数据，**不进 `todo.md` / `tasks.md`**。

### [堆内存] 缓存 `statement.tables` 的展开结果，避免每次路由重复构造

- **现状**：`SelectStatement.tables` 是计算属性，每次访问都新建 `ArrayList` 并递归 `collectTables()`（`fdbm/src/sql/ast.cj:338-353`）。`route()` 一次调用里至少访问两次（`:147` 循环、`:262` `logicalOf`），`qualifiersOf`（`:416`）还会对每个分片表再访问一次；每条 SELECT 至少多出 2~3 个数组与一轮递归展开。
- **方案**：在 `PartitionRouter.route` 入口取一次 `let tables = statement.tables`，把 `logicalOf`/`qualifiersOf` 改为接收该数组；或在 AST 构造时把 `tables` 作为 `let` 字段计算一次（AST 不可变，缓存无失效问题）。
- **预期**：每条 SELECT 少 2~3 次 O(表数) 分配与递归；对象数下降与语句数成正比。
- **代价**：改 3 个私有函数签名；AST 增加一个字段（构造期一次展开）。
- **验证**：`cjpm bench -O2` 跑 10k 条 1~3 表 SELECT，对比中位数与 `getAllocatedHeapSize()`。
- **证据状态**：`无基线（待验证）`

### [CPU] 每条 SQL 被词法分析两次

- **现状**：`SqlParser.parse` 先调 `parseSessionCtl(sql)`（内部 `Lexer(sql).tokenize()`，`:62-64`），返回 `None` 后再 `Lexer(sql).tokenize()` 一次（`:52`）。非会话语句（绝大多数请求）都走两遍；`Dispatcher.execute` 每条语句都调用 `parse`（`fdbm/src/execute/dispatcher.cj:79`）。
- **方案**：先 tokenize 一次，把 token 数组同时用于会话控制判定与完整解析；`parseSessionCtl` 保留一个接收 `Array<Token>` 的重载（现有测试签名不变）。
- **预期**：词法分析次数减半，每语句少一次 O(n) 扫描 + 一个 token 数组分配（n = SQL 长度）。
- **代价**：小重构，`parseSessionCtl` 多一个入口；会话控制判定逻辑不变。
- **验证**：`cjpm bench -O2` 对 `Dispatcher.execute` 跑 10k 条典型 SQL（10~200 字符）对比中位数；`cjprof` 看 `Lexer.tokenize` 自耗时占比。
- **证据状态**：`无基线（待验证）`

### [CPU] 缩小 `SessionRegistry.sweep` 的临界区（锁内不做跨对象调用）

- **现状**：`sweep()` 在 `synchronized(mutex)` 内遍历全部会话，并逐条调用 `isBufferClosed(buffer)`（`SessionRegistry.cj:117-133`）；同一把 `mutex` 在请求主路径的 `of()`（`:48`）与 `size()`（`:106`）上被争用。`buffer.isClosed()` 是跨对象调用（可能抛异常、由 `isBufferClosed` 吞掉），其耗时不在本模块可控范围。
- **方案**：锁内只拷贝 `(key, session)` 快照并释放；锁外判定 `isBufferClosed`；再进锁按 key 删除，删除前比对引用（`sessions.get(key)` 仍是同一 session 才删），避免误删巡检期间重建的会话。
- **预期**：巡检的锁持有时长从「O(会话数) × isClosed」降为「O(会话数) 拷贝」，缩短请求路径的等待。
- **代价**：多一次快照分配与一次引用比对；删除逻辑从无条件 `remove` 变为条件删除，需补并发用例（巡检与 `of` 并发 100 轮，断言不误删活跃会话——可扩展 `Server_test.cj:330-349`）。
- **验证**：1000 连接、1ms 巡检周期下采样线程状态（BLOCKED 时长）与 `of` 的 P99；`cjprof record` 线程状态。
- **证据状态**：`无基线（待验证）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `statement.tables` 重复展开在单次路由中的占比可观（表多时更明显） | `fdbm/src/route/router.cj:147`、`:262`、`:416` | `collectTables` 自耗时占比、每语句分配次数 | `cjprof record` 跑 10k 条 1/3/5 表 SELECT，按表数分组 |
| 2 | `sweep` 的锁等待会拉高请求路径 P99（连接数大、巡检周期短时） | `fdbm/src/server/SessionRegistry.cj:117-133` | 锁等待时长、BLOCKED 线程数 | 1000 空闲连接 + 1ms 巡检，采样线程状态 10 分钟 |
| 3 | 双重词法分析占端到端比例（短 SQL 上可能低于噪声） | `fdbm/src/sql/SqlParser.cj:48`、`:52` | `Lexer.tokenize` 自耗时占比、SQL 长度分布 | `cjprof record` + 分段计时，分别统计会话控制与非会话语句 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fdbm/src/route/router.cj` | .cj | ✅ | 见发现 #1、#3、#7；`isPartitioned` 无引用（轻微条目） |
| 2 | `fdbm/src/server/CustomLoader.cj` | .cj | ✅ | 见发现 #7；`isLibrary`/`withoutExtension` 大小写不一致 |
| 3 | `fdbm/src/server/DriverLoader.cj` | .cj | ✅ | 见发现 #7；与 CustomLoader 四函数重复 |
| 4 | `fdbm/src/server/FdbmServer.cj` | .cj | ✅ | 见发现 #4、#5；启动装配与失败清理已逐分支核对 |
| 5 | `fdbm/src/server/FdbmTestSetup_test.cj` | .cj | ✅ | 测试配置，与实现一致 |
| 6 | `fdbm/src/server/GracefulShutdown_test.cj` | .cj | ✅ | 覆盖关闭顺序；未覆盖「关闭后新建会话」路径 |
| 7 | `fdbm/src/server/Handler_test.cj` | .cj | ✅ | 见轻微：`freePort` 无引用、`uniquePort` 末尾不可达、`waitForPort` 返回值被忽略 |
| 8 | `fdbm/src/server/InFlight.cj` | .cj | ✅ | 见发现 #4；`Condition.wait` 返回值语义已核对文档 |
| 9 | `fdbm/src/server/Integration_test.cj` | .cj | ✅ | 端到端链路；`waitForPort` 返回值被忽略 |
| 10 | `fdbm/src/server/Server_test.cj` | .cj | ✅ | 覆盖启动/停止/加载器；`stamp()` 只用于「必然不存在」的路径名，秒级精度不影响用例结果 |
| 11 | `fdbm/src/server/SessionRegistry.cj` | .cj | ✅ | 见发现 #4、优化方案 3；巡检与关闭路径已核对 |
| 12 | `fdbm/src/server/context.cj` | .cj | ✅ | 纯依赖容器，无问题 |
| 13 | `fdbm/src/server/handler.cj` | .cj | ✅ | 见发现 #6；游标关闭/幂等路径已逐分支核对 |
| 14 | `fdbm/src/sql/Dialect.cj` | .cj | ✅ | 方言映射与引用转义正确 |
| 15 | `fdbm/src/sql/ParameterBinder.cj` | .cj | ✅ | 递归覆盖全部含子节点的表达式类型（Binary/In/Not/Function） |
| 16 | `fdbm/src/sql/PartitionKeyExtractor.cj` | .cj | ✅ | 见发现 #1；`PartitionRange.isEmpty` 无引用 |
| 17 | `fdbm/src/sql/SqlFeature_test.cj` | .cj | ✅ | 覆盖引用标识符/派生表/方言；未覆盖非分库列条件 |
| 18 | `fdbm/src/sql/SqlParser.cj` | .cj | ✅ | 见发现 #2、轻微（`args` 未读）；解析分派已逐语句类型核对 |

合计：`.cj` 18 个 / `.md` 0 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 发现 #1/#3/#5/#6 + 轻微 #8/#12；语言特性方面核对了 `Array` 引用语义、`Option` 处理与 `synchronized` 返回值，未发现按值/按引用误用 |
| §1 死代码 | 3 | 已逐个 `private`/`internal`/`protected` 符号全仓搜引用：`isPartitioned`（router.cj:271）与 `PartitionRange.isEmpty`（PartitionKeyExtractor.cj:37）零引用；`freePort` 零引用；`uniquePort` 末尾 `0` 不可达；`factor` 的 `args` 只写不读；另 7 处未使用 import。`InFlight.count`/`SessionRegistry.size`/`FdbmServer.isClosed` 仅测试引用，属可见性建议，不计死代码 |
| §2 重复逻辑 | 1 | 发现 #7：`librariesOf`/`isLibrary`/`withoutExtension`/`sort` 两文件逐行相同；`joinNames` 三份且分隔符不一致；插入排序全模块 4 份。其余函数已按「输入-输出-副作用」两两比对，无同语义实现 |
| §3 空实现 | 0 | `catch (_: Exception) { () }` 全部位于清理/幂等路径（`closeCache`、`installCursor` 的关闭失败、`takeCursor` 后重复关闭），吞掉的是清理动作本身的失败，不影响主流程返回值；无 `TODO`/`FIXME`/`UnsupportedException` 占位在主路径 |
| §4 栈溢出 | 1 | 发现 #2：表达式/派生表递归无深度上限；`route` 的 `selectConstraint` 递归深度受同一输入约束（同根因，未重复计数） |
| §5 OOM | 0 | 路由与加载器处理的是启动期配置规模（规则数、物理库数）；无按报文长度预分配、无全局只增容器；`protocolError` 的日志放大归入安全性条目，不计 OOM |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，三处线索（双次词法、`tables` 重复展开、`sweep` 锁）全部列入「待验证假设」，未作缺陷 |
| §6.2 大粒度锁 | 0 | `sweep` 临界区含 `isBufferClosed` 跨对象调用，但没有持有时长/竞争线程数数据，只写成优化方案 3；判定依据为设计面（§12.2），不作性能结论 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` 后立即 `get()`、无单消费者串行段（测试夹具里的并发用例不属于产品路径） |
| §6.4 低效算法 | 0 | `intersect`/`sameSet` 用 `contains` 为 O(n²)，但 n = 物理库数（个位数）；`remove(at: 0)`、循环拼串、重复解析正则均未出现。`tables` 重复展开归入 §8 方案 |
| §7 降堆内存方案 | 1 | 方案 1（缓存 `statement.tables`）；无基线，标注待验证 |
| §8 降 CPU 方案 | 2 | 方案 2（去掉一次词法分析）、方案 3（缩小 `sweep` 临界区）；均无基线 |
| §9 local mode 可行性 | 0 | 解析产物（AST/token）作为返回值逃逸出 `parse`，不满足 local region 的逃逸约束；loader/路由为启动期一次性路径，峰值内存不构成问题。结论：本部分无可行改造点 |
| §11 现有代码的 BUG（存量） | 5 | 发现 #1/#2/#3/#4/#5 均为本轮读到的既有逻辑缺陷，逐条给了位置与推演；`handler` 的游标状态机、`ParameterBinder` 的参数计数、`insertConstraint` 的列匹配已逐分支核对，未发现额外缺陷 |
| §12 并发安全与锁粒度 | 3 | 发现 #4（关闭竞态）、#5（`server` 字段发布）、优化方案 3（`sweep` 锁粒度）；`InFlight` 的 `enter/leave/notifyAll` 配对与 `Condition.wait` 返回值语义已按文档核对 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分清单不含 `README.md` / `README_en.md` / `doc/**`，无法做 README 对照；留给包含文档的部分，避免重复统计 |
| 文件覆盖（§13 等） | 18/18 | 清单 18 个 `.cj` 全部读完；本部分无 `.md`，§13 不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

> 轻微 5 条分别见发现 #8~#12（大小写口径不一致、未使用 import、死声明与不可达语句、`factor` 的无效实参解析、`waitForPort` 返回值被忽略）。

## 总评

本部分代码的整体结构是健康的：`FdbmServer` 在构造期完成「自定义扩展 → 配置校验 → 驱动唯一性 → 资源/路由/缓存」的装配，失败路径对缓存与连接池做了成对清理（`FdbmServer.cj:88-134`），`handler` 的每个分支都保证回包，会话/游标的关闭顺序有专门用例（`GracefulShutdown_test`），加载器的错误码区分也符合设计。分层与依赖方向没有违规：`route` 不借连接、`sql` 不感知执行器、`server` 只做协议编排。

阻塞项有两个，都属于「唯一闸门失效」类：
1. **范围路由把「无边界」当「全范围」**（发现 #1）——`UPDATE`/`DELETE` 缺少分库键条件时不会按设计报错，而是静默在全部物理库执行。这是本轮最该先修的一条，改动仅在 `expressionConstraint` 的一个判定加两条用例。
2. **解析器递归无深度上限**（发现 #2）——SQL 是客户端可控输入，且协议层没有长度上限，深嵌套即可打崩整个 fdbm 进程，属于远程 DoS 面。建议按常量深度上限拦截并补负向用例。

其余为排期级：`select 1` 重复行（发现 #3）影响探活/常量查询的正确性，值得随 #1 一起修；关闭期会话泄漏与 `server` 字段发布竞态（#4/#5）窗口窄、影响限于停机流程，可在下个迭代补守卫；错误日志打印完整 payload（#6）按安全基线整改；加载器四函数重复（#7）与 5 条轻微项属可维护性，可与本轮修复一并处理。

性能方面本轮没有可复核数据，三处线索（每条 SQL 两次词法分析、`statement.tables` 重复展开、`sweep` 锁内跨对象调用）只列入优化方案与待验证假设，未计入缺陷，也未进修复清单。

本部分共 12 条发现（严重 2 / 一般 5 / 轻微 5），全部为存量；是否纳入修复待用户在门禁决定。

**范围外提示**：`fdbm/src/execute/executors.cj:882-913` 的 `fillAndRoute` 在「无列清单、无 SET 对」（如 `insert into t values (1,'a')`）时会先调用 `idLiteral` 生成并消费一个 ID，但 `columns`/`pairs` 两个分支都为空，生成的 ID 被丢弃，随后仍按 `Unroutable` 处理；该文件不在本部分清单内，仅记一句，交由对应部分核实。
