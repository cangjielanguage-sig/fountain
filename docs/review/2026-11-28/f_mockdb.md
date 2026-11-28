# f_mockdb 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_mockdb`（13 个 `.cj` + 2 个 `.md`，共 15 个文件；9 个实现类文件 + 1 个静态门面 + 3 个测试文件 + 两版 README）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支；无 diff，全部问题记「存量」）
- **审查重点**：SQL 解析 / 模拟正确性、空实现与假实现、死代码、重复逻辑、并发安全、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [一般][存量] #1 两版 README 都把 `currentThreadId` 列为 `MOCKDB` 公开成员，代码里是包内可见

- **位置**：`f_mockdb/src/mockdb.cj:97-101`；`f_mockdb/README.md:49`；`f_mockdb/README_en.md:49`
- **来源**：存量（快照模式无基线）。`git blame -L 97,101 -- f_mockdb/src/mockdb.cj` → `4be871f2fd 2026-10-02`；`git blame -L 49,49 -- f_mockdb/README.md` → `924ec6f8bc 2026-10-04`（该提交把「`MOCKDB` 公开成员」清单写进 README，同时把 `verbose` 提升为 `public`，但没给 `currentThreadId` 加 `public`）。
- **判据**：review-checklist §13（文档与代码不符）+ §14.2（公开 API 清单与实际可见性不一致）
- **证据**：静态确定 —— `mockdb.cj:97` 声明为 `static prop currentThreadId: Int64`，没有 `public`（仓颉缺省为 `internal`）。全仓 `grep currentThreadId` 只有三类命中：定义处、模块内日志/异常文案（`Datasource.cj:47`，`Transaction.cj:58,63,68,71,76,79,83,86,91,94,98,101`）、两版 README 的公开成员清单。`f_orm` / `f_dbd` / `f_dbpool` / `fdbm` / `fdemo` 对它的引用数为 0。
- **描述**：使用者按 README 写 `MOCKDB.currentThreadId` 会编译失败（no accessible member）。清单里其余 12 个成员都是真 `public`，唯独这一个越界，属于清单手写时的漏检。
- **建议**：二选一并中英同步。首选从 README.md:49 / README_en.md:49 删掉 `currentThreadId`——它目前只用于拼日志，没有对外价值；若确实要暴露，则在 `mockdb.cj:97` 补 `public`，并同时在「公开类型」表里说明它的用途。

### [一般][存量] #2 `close()` 只翻标志位：连接/语句/结果集关闭后仍可正常 prepare、执行、读行

- **位置**：`f_mockdb/src/Connection.cj:42-45`（`close`）与 `:29-38`（`createTransaction` / `prepareStatement` 不校验 `closed_`）；`f_mockdb/src/Statement.cj:103-108`（`close`/`isClosed`）与 `:56-102`（`set`/`setNull`/`query`/`update` 不校验）；`f_mockdb/src/QueryResult.cj:58-63` 与 `:32-57`（`next`/`get`/`getOrNull` 不校验）
- **来源**：存量（`git blame -L 42,45 -- f_mockdb/src/Connection.cj` → `close` 由 `4be871f2fd 2026-10-02` 写入、`:44` 的赋值由 `ba04b79f09 2026-10-04` 调整；`Statement.cj:103-108`、`QueryResult.cj:58-63` 同样为 `4be871f2fd`）。
- **判据**：review-checklist §3（接口方法只有标志位副作用，等同假实现）+ §11（`state` 报 `Closed` 却仍可用，语义自相矛盾）
- **证据**：静态确定 —— 模块内 `closed_` 只被 `isClosed()` 和 `Connection.state` 读取（`Connection.cj:20-28,39-41`），`prepareStatement`（`:36-38`）、`MockStatement.query/update`（`Statement.cj:72-102`）、`MockQueryResult.getOrNull`（`:42-57`）都没有读各自的 `closed_`。
- **描述**：被测代码若在 `close()` 之后继续 `prepareStatement` / `query` / 读列，mock 全部静默成功；`Connection.state` 同时返回 `Closed`。这让「关闭后误用」「连接已归还仍持有 statement」这类缺陷在单测里永远不暴露，而 mock 的主要价值正是拦这类问题。注意 README.md:47 只承诺「`isClosed()` 为 `true`、`state` 为 `Closed`、重复关闭幂等」，没有承诺关闭后的行为，所以这是保真度缺口，不是文档违约。
- **建议**：在 `prepareStatement` / `createTransaction` / `query` / `update` / `set` / `setNull` / `next` / `getOrNull` 入口加 `if (closed_) { throw SqlException('... has been closed') }`，与真驱动口径一致；若担心影响既有用例，至少要在 README「关闭语义」段写明「mock 不校验关闭后调用，关闭后仍可执行」，把盲区显式化。

### [一般][存量] #3 `update()` 的 `lastInsertId` / `rowCount` 跨执行残留：夹具只设 `rowCount` 时，DELETE 结果里带着上一条 INSERT 的主键

- **位置**：`f_mockdb/src/Statement.cj:72-87`（`update()` 执行前只调 `MOCKDB.clearQueryResult()`；`:86` 直接读线程级 `MOCKDB.lastInsertId` / `MOCKDB.rowCount`）；状态源在 `f_mockdb/src/mockdb.cj:60-61,142-157`
- **来源**：存量（`git blame -L 72,87 -- f_mockdb/src/Statement.cj`：函数骨架 `4be871f2fd 2026-10-02`，`clearQueryResult` 与 `args.clear()` 分别由 `75d72989dd` / `7704cd9191 2026-10-04` 加入，快照由 `ab85d05138 2026-10-04` 加入——即「每次执行只清行/列」是后加的，`lastInsertId`/`rowCount` 的重置一直没跟上）。
- **判据**：review-checklist §11（契约与实现不符）+ §2 相邻语义不一致（与 README「一次执行一份结果」的口径不对称）
- **证据**：静态确定 —— `update()` 只清行与列信息；`lastInsertId_` / `rowCount_` 是 `ThreadLocal`（`mockdb.cj:60-61`），除 `MOCKDB.clear()`（`:78-90`）外没有任何地方重置；`MockStatement` 里也没有「执行前归零」的分支。
- **描述**：同一线程内先执行 INSERT 夹具（`lastInsertId = 100`、`rowCount = 1`），再执行一条只设 `rowCount = 5` 的 DELETE 夹具，返回的 `UpdateResult.lastInsertId` 仍是 100。而 README.md:29-30 写「默认是 0」、README.md:43 写「一次执行一份结果」，读者会以为每次执行都从 0 起算。下游确实有只设 `rowCount` 的夹具（`fdbm/src/execute/Dispatcher_test.cj:913` 为范围外提示），一旦同一用例前面插过数据，被测代码按 `lastInsertId` 取主键就会拿到上一条的值，测试断言与业务值都可能错。
- **建议**：把「执行前重置」做成一个入口（例如 `update()`/`query()` 共用的 `beginExecution()`：`clearQueryResult()` + `lastInsertId = 0` + `rowCount = 0`），与「一次执行一份结果」的既有承诺对齐；若确实想要 SQLite 式「lastval 持久」语义，则在 README「时序与约定」里写清「`lastInsertId` / `rowCount` 是线程级持久，直到 `clear()`」，并让 `update()` 的注释与之一致。

### [一般][存量] #4 `execution` 是进程级唯一寄存器，其余夹具按线程隔离——多线程用例会互相覆盖夹具

- **位置**：`f_mockdb/src/mockdb.cj:57`（`private static var execution_ = AtomicOptionReference<Box<(String, ArrayList<Any>) -> Unit>>()`）与 `:105-112`（公开 `execution` get/set）；对照 `:58-69` 的 12 个 `ThreadLocal` 夹具
- **来源**：存量（`git blame -L 57,57 -- f_mockdb/src/mockdb.cj` → `4be871f2fd 2026-10-02`，此后未改）。
- **判据**：review-checklist §12.1（共享可变状态：跨线程共享的唯一夹具入口）+ §14.2（README 只写「夹具按线程隔离」，未说明 `execution` 例外）
- **证据**：静态确定 —— 共享路径完整：`MockStatement.query()`/`update()`（`Statement.cj:80,96`）每次执行都读同一个静态 `execution_`；12 个夹具字段（行、列信息、`lastInsertId`、`rowCount`、`toThrowOn*`、`metadata`）却是 `ThreadLocal`。`AtomicOptionReference` 保证的是引用读写的原子性，不提供任何隔离语义。
- **描述**：两个线程各设自己的 `execution` 时，后写者覆盖前者，且不会报错——线程 A 的 SQL 会跑线程 B 的夹具，行/列信息却写回线程 A 自己的 `ThreadLocal`，表现为「夹具莫名其妙没生效 / 拿到别人的数据」。README.md:57 明确写「夹具……都按线程隔离」，容易被读成整体隔离。仓内当前未见并发使用 mock 的用例（`f_dbpool/src/DatabasePool_test.cj:28` 的注释显示那批 `spawn` 已因挂死被移除），所以是潜在设计风险而非现网故障。
- **建议**：把 `execution_` 也改成 `ThreadLocal<(String, ArrayList<Any>) -> Unit>`（`clear()` 不清它，保持现有语义），与其余夹具一致；若坚持全局，则在 README「时序与约定」首条写明「`execution` 是进程级唯一，多线程并行用例必须共用同一夹具或串行执行」。

### [一般][存量] #5 三个测试文件缺 Apache 2.0 版权头

- **位置**：`f_mockdb/src/mockdb_core_test.cj:1`、`f_mockdb/src/mockdb_exception_test.cj:1`、`f_mockdb/src/mockdb_transaction_test.cj:1`
- **来源**：存量（三个文件均由 `4be871f2fd 2026-10-02` 新建，首行直接是 `package`）。
- **判据**：`fountain-baseline.md §3`（每个 `.cj` 必须有 Apache 2.0 头且位于 `package` 之前，缺头按「一般」报）
- **证据**：静态确定 —— 三个文件第 1 行均为 `package fountain::f_mockdb`，无注释头；同模块 10 个实现文件全部合规（`mockdb.cj:1-15` 等）。同仓其它模块的测试文件普遍带头（`f_orm/src/base/SqlResultCache_test.cj:1`、`f_util/src/CaseFormat_test.cj:1`、`f_util/src/CrcEngine_test.cj:1` 等），说明这是本模块遗漏而非仓库约定。
- **描述**：文件头缺失会让许可证扫描（`license = ["Apache-2.0"]` 已写进 `cjpm.toml:6`）漏掉这三个文件；属于机械性问题，无运行时影响。
- **建议**：按 `mockdb.cj:1-15` 的模板补齐，年份用 `2026`（首次提交 2026-10-02）。

### [轻微][存量] #6 `setNull()` 里 `if(index < args.size)` 是恒真分支

- **位置**：`f_mockdb/src/Statement.cj:63-71`（守卫在 `:68`）
- **来源**：存量（`git blame -L 65,71` → `4be871f2fd 2026-10-02`；`checkIndex` 调用由 `0742124b7f 2026-10-04` 加入）。
- **判据**：review-checklist §1（恒真恒假分支）
- **证据**：静态确定 —— `:65-67` 的 `for(_ in args.size ..= index) { args.add(None<Any>) }` 会把 `args.size` 顶到 `index + 1`（区间在进入循环时求值一次，`args.size > index` 时区间为空、`== index` 时补 1 个元素），因此 `:68` 的 `index < args.size` 恒为 `true`。
- **描述**：分支无副作用差异，只是让人误以为存在「补位失败」的可能；与 `set()`（`:56-62`）的无守卫写法不一致。
- **建议**：删掉守卫直接 `args[index] = None<Any>`；或抽 `ensureSize(index)` 让 `set`/`setNull` 共用。

### [轻微][存量] #7 `query()` 与 `update()` 逐行同构，仅结果类型不同；`set()` 与 `setNull()` 同理

- **位置**：`f_mockdb/src/Statement.cj:72-87`（`update`）与 `:88-102`（`query`）；同类小规模复制在 `:56-62` / `:63-71`
- **来源**：存量（`4be871f2fd 2026-10-02` 建骨架，后续 `75d72989dd` / `540db7cae3` / `7704cd9191` / `ab85d05138` / `924ec6f8bc` 五次修补都成对施加）。
- **判据**：review-checklist §2（表现形式不同的重复逻辑：只改类型名/返回值）
- **证据**：静态确定 —— 两个函数体逐行对齐：注释（`clearQueryResult` 的理由）→ `MOCKDB.clearQueryResult()` → `toThrowOnExecuting` 判断 + 同一句错误文案 `'failed to execute sql: ${sql}'` → `try { MOCKDB.execution(sql, args) } finally { args.clear() }`；唯一差异是结尾 `MockUpdateResult(MOCKDB.lastInsertId, MOCKDB.rowCount)` vs `MockQueryResult()`。`set`/`setNull` 也只差最后写入的值。
- **描述**：这组复制已经产生过一次行为漂移——`clearQueryResult` 与 `args.clear()` 是分两次提交分别加到两条路径上的（`75d72989dd` / `7704cd9191`），说明「改一处漏一处」的风险真实存在；`'not supported'` 字面量同样在 `Statement.cj:28,34` 与 `QueryResult.cj:33` 各写一遍。
- **建议**：抽 `private func runFixture(): Unit`（清结果 → 判 `toThrowOnExecuting` → 执行 → `finally` 清参数），`query`/`update` 只保留「构造结果对象」一行；`'not supported'` 提成 `private const UNSUPPORTED = 'not supported'`。

### [轻微][存量] #8 三组 savepoint 抛异常开关的 setter/getter 完全同构，只有 `ThreadLocal` 字段名不同

- **位置**：`f_mockdb/src/mockdb.cj:190-205`（`toThrowOnReleasing`）、`:214-229`（`toThrowOnRollbackingSavePoint`）、`:231-246`（`toThrowOnSavingSavePoint`）
- **来源**：存量（6 个函数全部由 `4be871f2fd 2026-10-02` 写入，未再改动）。
- **判据**：review-checklist §2（只改字段名的字面量复制）
- **证据**：静态确定 —— 三对函数的函数体逐行一致：`match(ThreadLocal.get())` → `Some(m) => m[savepoint] = toThrow` / `_ => 新建 HashMap、set、写键值`；getter 是 `m.get(savepoint) ?? false`。56 行里唯一的差异是 `toThrowOnReleasing_` / `toThrowOnRollbackingSavePoint_` / `toThrowOnSavingSavePoint_` 三个字段名。
- **描述**：三份实现让「新增一类 savepoint 失败模拟」必须复制 18 行，也埋下不一致的隐患（例如将来给一处加 `clear` 语义）。
- **建议**：保留三个 `ThreadLocal<HashMap<String, Bool>>` 字段，抽 `private static func setSavepointFlag(holder: ThreadLocal<HashMap<String, Bool>>, savepoint: String, toThrow: Bool)` 与 `private static func savepointFlag(holder: ThreadLocal<HashMap<String, Bool>>, savepoint: String): Bool`，三个公开函数各一行转发；公开签名不变。

### [轻微][存量] #9 `placeholderCount()` 按字节数 `?`，把字符串字面量与注释里的 `?` 也算进上界

- **位置**：`f_mockdb/src/Statement.cj:36-46`
- **来源**：存量（`git blame -L 37,46` → `0742124b7f 2026-10-04`，为修「大索引补出天量占位符」引入）。
- **判据**：review-checklist §11（模拟正确性：SQL 解析口径与真驱动不符）
- **证据**：静态确定 —— 函数对 `sql.toArray()` 逐字节比较 `63`（`'?'`），不区分引号、标识符、注释；`SELECT '?' AS q, ? FROM t` 会算出 2 个占位符，而真驱动只有 1 个。
- **描述**：上界偏大会让 `set(1, ...)` 这类「真实不存在的参数位」通过校验，夹具里出现比 SQL 占位符更长的 `args`；上界偏小不会发生（只会多算）。影响限于参数个数校验，不会写坏数据；README.md:44 已把该上界描述为「按真驱动口径定上界」，措辞比实现严格。
- **建议**：最小修法是跳过 `'...'` / `"..."` / `--` 行注释与 `/* */` 块注释后再计数（单趟状态机，约 20 行）；或者把 README 的措辞降级为「按 SQL 文本里 `?` 字符个数（不做词法分析）」，避免读者以为能挡住 `?` 字面量。

### [轻微][存量] #10 `verbose_` 是普通静态可变字段，与同文件其余状态（`ThreadLocal` / `AtomicOptionReference`）的同步手段不一致

- **位置**：`f_mockdb/src/mockdb.cj:41-50`（`private static var verbose_` + `public static mut prop verbose`）、`:52-56`（`log`）
- **来源**：存量（`git blame -L 41,50` → `924ec6f8bc 2026-10-04`，即把 `verbose` 提升为 `public` 的那次提交）。
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性）
- **证据**：静态确定 —— `verbose_` 无锁、无原子、无 `ThreadLocal`；写入点在任意线程的 `set`，读取点在所有线程的 `MOCKDB.log`。影响面仅限日志开关（bool 的单字读写不会撕裂，也没有跨字段不变量），不会破坏夹具。
- **描述**：同一文件里夹具走 `ThreadLocal`、`execution` 走原子引用，唯独诊断开关裸写，读者无法判断这是刻意（性能优先）还是遗漏。
- **建议**：改为 `ThreadLocal<Bool>`（与「每线程一份夹具」的模型一致，避免一个线程开 verbose 把整套用例日志刷满），或加一句注释说明「刻意不加同步，仅诊断用」。

### [轻微][存量] #11 README 缺三处对外可见的行为说明：空列信息抛异常、`next(values)`/`query(params)` 不支持、行内 NULL 的写法

- **位置**：`f_mockdb/README.md:43-46`（「时序与约定」段）、`:61-63`（公开类型表）；对应实现 `f_mockdb/src/QueryResult.cj:24-31`（`columnInfos` 空则抛 `MockDbException`）、`:32-34`（`next(values)` 抛 not supported）、`f_mockdb/src/Statement.cj:27-35`（`query(params)` / `update(params)` 抛 not supported）
- **来源**：存量（README 该段由 `924ec6f8bc 2026-10-04` 写入；`columnInfos` 抛异常与 `next(values)` 的抛法来自 `4be871f2fd 2026-10-02`）。
- **判据**：review-checklist §14.2（关键行为未文档化）+ §13（文档与实现口径不一致）
- **证据**：静态确定 —— README.md:63 只列 `columnInfos`、`next()`、`get`、`getOrNull` 四个成员，未提「列信息为空时 `columnInfos` 抛 `MockDbException`」（`QueryResult.cj:26-28`，且被 `mockdb_core_test.cj:677-682` 断言）、未提 `next(values)` 抛 not supported（`QueryResult.cj:32-34`）、未提 `query(params)`/`update(params)` 抛 not supported（`Statement.cj:27-35`，README:61 只写了「unsupported」没说抛什么）。另外「行里怎么表达 SQL NULL」全篇没有示例，只有测试用了 `None<Any>`（`mockdb_core_test.cj:191-193`）。
- **描述**：使用者第一次写「无列信息的空结果集」或「NULL 列」夹具时，会先撞上 `MockDbException('column infos from QueryResult must not be empty')`，README 里搜不到这句，只能去读源码；任何按 `next(values: Array<SqlDbType>)` 取流式列的调用方（`f_dbd/src/common/result.cj:115` 实现了这个入口）一旦跑在 mock 结果集上就会直接吃 `not supported`，而 README 没有预警。
- **建议**：在「结果集契约」条里补两句：①`columnInfos` 在夹具未加列信息时抛 `MockDbException`；②`next(values)` / `query(params)` / `update(params)` 一律抛 `MockDbException('not supported')`。在「参数槽」后补一行「行内 NULL：`row` 里放 `None<Any>`」，中英同步。

### [轻微][存量] #12 README 称事务异常「含 SQL 文本或 savepoint 名」，`MockTransaction` 的 begin/commit/rollback 异常只带步骤名

- **位置**：`f_mockdb/README.md:50`（`README_en.md:50` 同）；实现 `f_mockdb/src/Transaction.cj:62-63,70-71,85-86`（`begin`/`commit`/`rollback` 的文案只有步骤名）
- **来源**：存量（README.md:50 由 `924ec6f8bc 2026-10-04` 写入；`Transaction.cj` 文案来自 `4be871f2fd 2026-10-02`）。
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：静态确定 —— `MockTransaction` 不持有 SQL（类里没有 `sql` 字段，`Connection.cj:29-31` 也不传入），`begin`/`commit`/`rollback` 的 message 形如 `'failed to commit transaction, threadID: ...'`；只有 `release`/`rollback(sp)`/`save` 三个带 `savePointName`。
- **描述**：读者会以为事务失败信息里能定位到具体 SQL，实际只有步骤；排查「哪条语句的事务提交失败」时信息不足。
- **建议**：把 README 该句改成「含出错步骤名；带 savepoint 的三个操作含 savepoint 名」，或让 `MockTransaction` 持有创建它的连接的最近 SQL 并拼进文案（改动更大，不建议为 mock 引入）。

### [轻微][存量] #13 README 建议 `args[i].isNone()`，模块自身用例走的是 `Option<Any>` 模式匹配两步判定

- **位置**：`f_mockdb/README.md:44`（`README_en.md:44` 同）；用例 `f_mockdb/src/mockdb_core_test.cj:710-719`
- **来源**：存量（README.md:44 由 `924ec6f8bc 2026-10-04` 写入；用例写法自 `4be871f2fd 2026-10-02` 起未变）。
- **判据**：review-checklist §13（示例不可直接用）+ §14.2
- **证据**：待确认 —— `args` 的元素静态类型是 `Any`（`Statement.cj:20` `ArrayList<Any>`），README 让读者直接 `args[i].isNone()`；模块自己的用例却写成 `if (let x: Option<Any> <- capturedArgs[0]) { @Assert(true, x.isNone()) } else { @Assert(false) }`。缺的是 `Any` 是否提供 `isNone()` 的标准库文档/编译验证（本地 SDK 只带 `.cjo` 二进制，无 `std.core` 文档可核）。
- **描述**：若 `Any` 无此方法，README 的参数断言示例编不过；若有，用例的多余模式匹配就是无用样板。两种情况下文档与用例至少有一边需要改。
- **建议**：核对 `std.core` 的 `Any` 扩展后统一口径：能给一行就统一成一行示例，不能则把 README 改成用例里的 `if (let x: Option<Any> <- args[i])` 写法。

### [轻微][存量] #14 `metadata` 的 setter 直接存引用，与本模块「对外返回副本」的其它入口不对称

- **位置**：`f_mockdb/src/mockdb.cj:166-173`（setter `metadata_.set(value)`）；对照 `:28-34`（`copyMap`）、`Connection.cj:32-35`、`Datasource.cj:29-33`
- **来源**：存量（`git blame -L 166,173` → `4be871f2fd 2026-10-02`）。
- **判据**：review-checklist §11（防御性拷贝不对称，夹具可被外部事后改写）
- **证据**：静态确定 —— `set` 只把传入的 `Map` 引用塞进 `ThreadLocal`；`getMetaData()` 与 `options` 都返回 `copyMap` 副本。用例 `mockdb_core_test.cj:557-568` 只覆盖「读出来的是副本」，没覆盖「传进去后再改原 map」。
- **描述**：`let meta = HashMap(...); MOCKDB.metadata = meta; meta['k'] = 'v2'` 会静默改掉夹具；而 README.md:32 只承诺 `getMetaData()` 返回副本，读者容易以为夹具已经被复制。
- **建议**：setter 里 `metadata_.set(copyMap(value))`（与本文件 `copyMap` 复用），或在 README 明确「`metadata` 保存的是传入的 map 本体，传参后不要再改它」。

**范围外提示**（不计入本模块统计）：`src/mockdb/mockdb.cj:16-18` 的 `public import fountain::f_mockdb.*` 门面包存在，与根 `README.md:295` 的说明一致，无需处理；`fdbm/src/execute/Dispatcher_test.cj:913` 这类「只设 `rowCount`」的夹具会受到发现 #3 影响，建议 fdbm 轮次一并确认断言是否依赖 `lastInsertId`。

## 优化可行性方案

> 本模块是单测替身：无 I/O、无锁、无并发、无序列化，代码路径都在「构造夹具 → 拷快照」上。下列两条都属微优化，收益量级在微秒/几百字节，仅作为记录。

### [CPU] `placeholderCount()` 每次绑参都重扫整条 SQL

- **现状**：`Statement.cj:37-46` 在每次 `set`/`setNull` 里重新执行 `sql.toArray()`（复制整条 SQL 字节）再逐字节扫 `?`；绑定 k 个参数即 k 次 O(L) 分配 + k·L 字节扫描。典型 SQL 100~500 字节、参数 ≤ 10，单次开销在微秒以下。
- **方案**：`sql` 是构造后不可变的（`Statement.cj:21`），在构造时算一次存 `private let placeholderCount_: Int64`，`checkIndex` 直接读字段；顺带可把 `toArray()` 换成不复制字节的遍历。
- **预期**：绑参路径从 O(k·L) 降到 O(L) + k·O(1)，`Array<Byte>` 分配从 k 次降到 1 次。
- **代价**：`MockStatement` 多 8 字节字段；语义不变。若将来支持「执行中改 SQL」（当前没有），需要重新计数。
- **验证**：`cjpm bench -O2`，SQL 长度 1k / 10k 两档 × 100 个参数，比较 `set` 总耗时中位数与分配量；同机器、同 SDK、重复 5 轮。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `MockQueryResult` 对行与列信息各复制一份引用数组

- **现状**：每次 `query()` 构造结果集时，`QueryResult.cj:22` 调 `MOCKDB.getQueryResultRows().toArray()` 复制一次 `ArrayList` 的引用数组，`:23` 的 `MOCKDB.queryResultColumnInfos` 内部又 `toArray()` 复制一次（`mockdb.cj:139`）。行对象本身共享，多出来的是两个指针数组：n 行 + m 列时约 `(n+m)×8` 字节/结果集，生命周期跟结果集一样长。
- **方案**：`MockStatement.query()` 执行完把线程级列表「交给」结果集（执行前本来就 `clearQueryResult()` 新建列表，所有权可安全转移），`MockQueryResult` 直接持有该 `ArrayList` 引用；列信息同理。或退一步只去掉 `columnInfos` 的第二次 `toArray()`。
- **预期**：每个结果集少 2 个数组分配（n+m 指针 + 两次扩容），GC 压力按查询次数线性下降；绝对量小。
- **代价**：需要保证「交出所有权后本线程不再往里 add」——当前 `query()` 前的 `clearQueryResult()` 已满足，但改法要写注释固定这一不变量，否则 `MOCKDB.addQueryResultRow` 会污染已有结果集。
- **验证**：连续 N 次 `query()` 的 `getAllocatedHeapSize()` 与 GC 次数对照（同输入、`-O2`），并断言「新查询不会改变旧结果集」的既有用例（`mockdb_core_test.cj:329-345`）仍通过。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 绑参是 mock 执行路径上的主要开销（每次 `set` 重扫 SQL 并分配 `Array<Byte>`） | `f_mockdb/src/Statement.cj:37-46,57,64` | `set` 在整条执行路径里的自耗时占比与分配占比 | `cjprof record` 跑一个 10k 次「prepare → 绑 10 个参数 → query」的循环（`-O2`），看 `placeholderCount` 采样占比；同时统计 `getAllocatedHeapSize()` 差值 |
| 2 | 结果集快照复制带来的 GC 压力可测 | `f_mockdb/src/QueryResult.cj:22-23` | 每次查询的分配字节数与 GC 次数 | 同输入下对比「复制 / 转移所有权」两版：`getAllocatedHeapSize()`、GC 次数、10 万次查询总耗时中位数 |
| 3 | 并发用例下 `execution` 全局共享会实际造成夹具串扰（发现 #4） | `f_mockdb/src/mockdb.cj:57,105-112` | 并行用例的失败率 / 串数据样本 | 写一个 8 线程并行、每线程设不同 `execution` 的回归用例，跑 1000 轮统计「SQL 与夹具不匹配」的次数；或改用 `ThreadLocal` 后复跑对照 |

## 文件覆盖

> 与 `{workdir}/files/f_mockdb.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mockdb/README.md` | .md | ✅ | 结构完整（导入 / 使用 / 时序与约定 / 公开类型），示例 API 名与签名可对上源码；4 条文档问题见发现 #1 / #11 / #12 / #13，`lastInsertId` 语义见 #3 |
| 2 | `f_mockdb/README_en.md` | .md | ✅ | 与中文版 68 行对 68 行逐段对齐，无译漏、无结论相反；#1 / #11 / #12 / #13 同源（同一句译文） |
| 3 | `f_mockdb/src/ColumnInfo.cj` | .cj | ✅ | 6 个 getter + 3 个字段，`displaySize=Int64.Max`、`length/scale=0` 与 README:46 一致；版权头合规；无问题 |
| 4 | `f_mockdb/src/Connection.cj` | .cj | ✅ | `state`/`isClosed` 一致；`close()` 只翻标志（发现 #2）；`getMetaData` 返回副本（正确） |
| 5 | `f_mockdb/src/Datasource.cj` | .cj | ✅ | `connectionString`/`options` 载体，`copyMap` 拷贝正确；`setOption` 调 `MOCKDB.log`（内部符号，有调用者）；`close()` 后 `connect()` 仍返回连接（并入 #2 的假实现口径，未单列） |
| 6 | `f_mockdb/src/Driver.cj` | .cj | ✅ | `static init()` 注册 `mockdb`；`name`/`version`/`preferredPooling` 与 README:58 一致；`open` 记录连接串与选项；无问题 |
| 7 | `f_mockdb/src/MockDbException.cj` | .cj | ✅ | 两个 `public init`，`super(message)` 正确；对外可达，不判死代码 |
| 8 | `f_mockdb/src/QueryResult.cj` | .cj | ✅ | `getOrNull` 三态区分正确（未就绪/越界抛 `SqlException`，真 NULL 返 `None`，类型不符抛 `SqlException`）；`columnInfos` 空则抛（README 未写，发现 #11）；`next(values)` 不支持（#11）；`close()` 无校验（#2）；快照复制见优化方案 |
| 9 | `f_mockdb/src/Statement.cj` | .cj | ✅ | 占位符上界 + 参数槽语义正确；问题集中在 `setNull` 恒真分支（#6）、`query`/`update` 重复（#7）、关闭后仍可执行（#2）、`lastInsertId` 残留（#3）、`?` 计数口径（#9） |
| 10 | `f_mockdb/src/Transaction.cj` | .cj | ✅ | 状态机（未 begin / 重复 begin / 已结束）完整，异常文案带步骤名；README「含 SQL 文本」措辞不符（#12）；三个 savepoint 开关的调用约定与 `mockdb.cj` 一致 |
| 11 | `f_mockdb/src/UpdateResult.cj` | .cj | ✅ | 构造时快照两个 `Int64`，与 README:64 一致；无问题 |
| 12 | `f_mockdb/src/mockdb.cj` | .cj | ✅ | 静态门面：12 个 `ThreadLocal` 夹具 + `execution` 原子引用；`currentThreadId` 可见性（#1）、`execution` 全局性（#4）、`verbose_` 无同步（#10）、三组 savepoint 开关重复（#8）、`metadata` 存引用（#14） |
| 13 | `f_mockdb/src/mockdb_core_test.cj` | .cj | ✅ | 37 个用例覆盖连接/语句/结果集/夹具隔离/快照/可见性与参数槽；缺版权头（#5）；`args[i]` 的判定写法与 README 不一致（#13） |
| 14 | `f_mockdb/src/mockdb_exception_test.cj` | .cj | ✅ | 5 个用例覆盖 `toThrowOnExecuting` 与异常文案（含 SQL 文本断言）；缺版权头（#5）；无其它问题 |
| 15 | `f_mockdb/src/mockdb_transaction_test.cj` | .cj | ✅ | 15 个用例覆盖事务状态机、三步 savepoint 开关、三个模式属性；缺版权头（#5）；无其它问题 |

合计：`.cj` 13 个 / `.md` 2 个 / 共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：`getOrNull` 三态、占位符上界、快照隔离都已用逐用例核对，缺陷见 #3（跨执行残留）、#9（`?` 计数口径）；另有 baseline §3 的版权头缺失（#5）。设计：分层清晰（Driver → Datasource → Connection → Statement → Result，门面 `MOCKDB` 只存夹具），职责单一，唯一设计问题是 `execution` 与其余夹具的隔离模型不一致（#4）。语言特性：`ThreadLocal` + `AtomicOptionReference` 用法正确，`match`/`if-let`/`Option` 使用规范，无 `mut` 误用。可读性：命名一致（`xxx_` 私有字段）、注释解释了「为什么」（副本、快照、清参数槽），仅 `setNull` 的冗余守卫降低可读性（#6）。安全性：无外部输入解析（唯一「解析」是 SQL 里的 `?` 计数）、无凭据、日志只输出连接串与选项名值（测试替身场景下可接受），0 条。 |
| §1 死代码 | 1 | 已逐个符号机械搜索：`copyMap` 3 处、`MOCKDB.log` 10 处、`MockDatasource.setConnectionString` 2 处、`placeholderCount`/`checkIndex` 各 3 处、`EMPTY_EXECUTION` 5 处、`output` 2 处，均有调用者；12 个 `ThreadLocal` 字段与 `verbose_`/`execution_` 都被对应属性或函数读写；`clearExecution`（`mockdb.cj:93-95`）只被 `mockdb_core_test.cj:671` 使用，属「仅测试使用的非 public 符号」→ 可见性建议（保持 `internal` 合理，注释已说明），不算死代码；无 `return`/`throw` 后置语句；无未读局部变量。唯一命中是 `setNull` 的恒真守卫（#6）。`MockDbException.init()` 无仓内调用，但所在类是 `public` 且对外可达，按硬原则一不判死代码。 |
| §2 重复逻辑 | 2 | 已把 13 个文件的函数体压成「输入→输出→副作用」摘要两两比对：`query`/`update`（含 `set`/`setNull`）逐行同构（#7）；三组 savepoint 开关 6 个函数仅字段名不同（#8）。跨文件按错误文案与字面量搜过：`'not supported'` 3 处（`Statement.cj:28,34`、`QueryResult.cj:33`，并入 #7）、`'failed to execute sql: ...'` 2 处（同一文件同一段，并入 #7）、`copyMap` 只定义一次被两处复用（正确复用，不是重复）。`clear()` 与 `clearQueryResult()` 是包含关系而非重复。 |
| §3 空实现 | 1 | 无 `TODO`/`FIXME`/`catch {}`/`throw UnsupportedException`。`MockStatement.setOption`（`:30-32`）只打日志、丢弃选项，`MockQueryResult.next(values)`、`query(params)`、`update(params)` 统一抛 `MockDbException('not supported')`——这些是 mock 有意的降级，README 已声明 unsupported（`next(values)` 漏写见 #11），不按严重处理；真正的问题是 `close()` 系列只有标志位副作用（#2）。 |
| §4 栈溢出 | 0 | 全模块无递归（无自调用、无自引用结构），最深调用链固定 4 层（`MOCKDB.execution` → 夹具闭包 → `addQueryResultRow` → `ThreadLocal.get`）；不存在由输入深度决定的栈增长。 |
| §5 OOM | 0 | 唯一的长度相关分配是 `placeholderCount` 的 `Array<Byte>(len(sql))` 与结果集快照，都由调用方 SQL/行数决定且无放大；`set` 的补位循环受 `checkIndex` 上界保护（`index < 占位符数`），此前「大索引补出天量占位符」的路径已被 0742124b7f 修掉（`mockdb_core_test.cj:607-634` 有用例）；夹具集合都按线程隔离且无只增不减的全局容器。 |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 `cjprof` / `cjpm bench` 数据，按铁律不立热点结论；可疑点（每次绑参重扫 SQL）已写入「待验证假设」第 1 条。 |
| §6.2 大粒度锁 | 0 | 全模块无 `synchronized` / `Mutex` / 读写锁，`AtomicOptionReference` 只是一次原子引用替换，不存在临界区。 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 队列 / 批处理，不涉及并发度配置。 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `contains`/`indexOf` 热路径、无 `remove(at: 0)`、无循环内字符串拼接、无正则。`placeholderCount` 的 k·L 重复扫描属线性重复而非复杂度量级跳变，且无耗时数据，归入待验证假设第 1 条。 |
| §7 降堆内存方案 | 1 | 见「优化可行性方案 / [堆内存] 结果集快照复制」，标注 `无基线（待验证）`，不进修复清单。 |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案 / [CPU] 占位符计数缓存」，标注 `无基线（待验证）`，不进修复清单。 |
| §9 local mode 可行性 | 0 | 函数内唯一临时大对象是 `placeholderCount` 里的 `Array<Byte>`，逃逸检查可过，但收益上限受单条 SQL 长度约束（几百字节），且需 `--experimental --enable-local-mode` 并锁 SDK；没有改前/改后峰值内存数据，无法证明收益，不成立为方案。 |
| §11 现有代码的 BUG（存量） | 3 | 本轮读到的 13 个文件里所有边界/空值路径均已核对（空结果集、未 `next()` 取列、负索引、超占位符索引、空列信息、未 begin 的事务、重复 begin、`None<Any>` 参数）：取列三态与事务状态机正确。命中：#3（`lastInsertId`/`rowCount` 跨执行残留）、#9（`?` 计数把字面量算进去）、#14（`metadata` 存引用）。`MockDatasource.connect()` 在 `close()` 后仍返回连接，与 #2 同源（关闭后无校验），并入 #2 计数。 |
| §12 并发安全与锁粒度 | 2 | 共享点已逐一列举：`verbose_`（普通静态 var，跨线程读写，#10）、`execution_`（原子引用但全局唯一，语义不隔离，#4）、`output`（`ConsoleWriter` 跨线程写，仅 verbose 打开时触发，量小未单列）、`MockDatasource.options_`（open 期单线程写入，`Datasource` 由调用方独占，不判）、`MockStatement.args` / `closed_`（随对象，真驱动同样不保证线程安全，不判）。锁粒度：本模块无锁，不存在「锁太大」；#4 的替代方案是线程封闭（`ThreadLocal`）而不是去锁，符合「先安全后粒度」。 |
| §13 文档与代码一致性 | 3 | #1（`currentThreadId` 被写成公开成员）、#12（事务异常「含 SQL 文本」）、#13（`args[i].isNone()` 示例口径）。其余核对一致：`MockColumnInfo` 三个契约值与 `ColumnInfo.cj:24-51` 相符；`MockDriver` 的 `name`/`version`/`preferredPooling` 与 `Driver.cj:20-38` 相符；关闭语义与 `Connection.cj:20-45` 相符；`preferredPooling=false`、`public import std.database.sql.*` 转出清单、`MockUpdateResult` / `MockColumnInfo` 的公开构造都与源码一致；两版 README 逐段同步。 |
| §14 功能完备性与 README 覆盖 | 1 | 逐个 `public` 声明对照两版 README：`MOCKDB` 的 21 个公开成员、`MockDriver`(4)、`MockDatasource`(6)、`MockConnection`(6)、`MockStatement`(10)、`MockTransaction`(9)、`MockQueryResult`(7)、`MockColumnInfo`(7)、`MockUpdateResult`(3) 均在 README 中出现（#1 属「多写」，计入 §13）。唯一覆盖缺口是行为说明而非符号（#11）。功能完备性：`cjpm.toml` 版本 `1.3.2021` 与根 `cjpm.toml` 一致，模块已登记在 `.modules:30` 与根 `README.md:292-297`，`fountain::fountain.mockdb` 门面 `src/mockdb/mockdb.cj:16-18` 存在；代码侧无 TODO、无未接线配置、无 `match` 漏分支（`MockTransaction` 六个方法全覆盖）。 |
| 文件覆盖 | 15/15 | 15 个文件（13 `.cj` + 2 `.md`）全部读完，无抽样、无跳过、无超时。 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷 14 条（5 一般 + 9 轻微），全部为存量（工作区快照无 diff），是否纳入修复待用户决定。

## 总评

实现质量在「单测替身」这个品类里属于上游：职责按 std 的驱动契约切得干净（Driver → Datasource → Connection → Statement → QueryResult/UpdateResult），夹具用 `ThreadLocal` 做线程隔离 + `AtomicOptionReference` 做执行器替换，快照语义（行、列信息、`UpdateResult`）都有对应用例；取列的三种状态（行未就绪 / 列越界 / 真 NULL）区分正确，参数槽「执行后清空 + 越界按占位符数校验」两处是典型的「踩过一次坑后补对」的写法，注释也解释了原因。`getOrNull` 按 `Option` 类型匹配而不是「取不到就 `None`」，避免了把类型错误静默成 NULL，这是本模块最值得保留的设计。死代码只剩一处恒真守卫（#6），接口层唯一的「空」是 `close()` 系列（#2）。

风险按优先级排：

1. **`lastInsertId` / `rowCount` 跨执行残留（发现 #3，建议优先排期）**：这是本轮唯一会直接把错值交给被测代码的问题——同一用例里 INSERT 之后跑 UPDATE/DELETE，返回的 `UpdateResult` 带着上一条 INSERT 的主键。修法很小（执行前归零），但需要和 README「一次执行一份结果」的口径一起定，否则下一次改动还会漂。
2. **关闭后仍可用（发现 #2）**：mock 的职责是拦「用坏了」，现在 `close()` 只是翻标志，`prepare/execute/读行` 全部放行，同时 `state` 又报 `Closed`。补 4~6 个守卫即可，代价低、收益明确。
3. **`execution` 的全局性与其余夹具的线程隔离不一致（发现 #4）**：当前仓内没有并发用 mock 的用例，属潜在风险；若后续 `f_dbpool` / `fdbm` 要做并发单测，这里会变成难查的偶发失败。
4. 文档三处（#1 `currentThreadId`、#11 行为说明缺失、#12 事务文案）+ 版权头（#5）都是轻量收尾项，适合顺手改。

优化方案两条（占位符计数缓存、结果集快照去复制）都是微优化，收益量级在微秒与几百字节，**没有改前基线**，按规范只登记为待验证，不进修复清单。综合结论：无阻塞级缺陷，代码质量良好；建议本轮只处理 #3 与 #2，其余排期或随手修。
