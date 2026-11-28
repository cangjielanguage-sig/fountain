# f_dbd 模块审查报告（第 2/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（全模块 49 个源文件；**本部分覆盖 15 个**：`dbd` / `dbd_test` / `common/types_test` / `common/types_matrix_test` / `driver/DbdConnection(+_test)` / `driver/DbdDatasource` / `driver/DbdDriver(+_test)` / `driver/DbdOptions` / `driver/DbdStatement(+_test)` / `driver/DbdTestSetup_test` / `driver/DbdTransaction(+_test)`）
- **基线**：工作区快照（`sts/1.3.x`，`git status` 仅见本次审查产物；快照模式无 diff，本部分发现全部记为「存量」）
- **审查重点**：驱动 / 连接 / 语句 / 事务生命周期、资源释放、并发安全与锁粒度、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（部分报告，待主 Agent 合并为 `docs/review/f_dbd_review_20261128.md`）
- **说明**：本文件统计**只含第 2/4 部分**；模块 README / `doc/**` / `common` 其余文件 / `multid` / `DbdTransport` 归其它部分，合并时勿与本部分数字直接相加覆盖。

## 发现

> 编号对照（供下文「文件覆盖」「覆盖自检」「总评」引用）：#1 结果集独占竞态（严重）｜#2 参数 index 无上界｜#3 事务互斥缺失｜#4 关闭等 `UNSUBSCRIBE` 阻塞 6h｜#5 选项表并发｜#6 `dbdDriver()` 补注册异常面｜#7 事务三属性静默无效｜#8 超时兜底重复｜#9 未使用 / 重复 import｜#10 关闭状态边界｜#11 测试断言与资源。每条的位置见对应小节标题下的「位置」。

### [严重][存量] 连接级「结果集独占」是检查-然后-发包-再登记，并发 `query()` 可同时通过闸门，两个游标并存导致行数据错位

- **位置**：`f_dbd/src/driver/DbdStatement.cj:82-98`（`ensureExecutable()` → `connection.request(...)` → `openResult = result` → `connection.registerResult(result)` 四步跨一次网络往返）；闸门与登记在 `f_dbd/src/driver/DbdConnection.cj:124-142`
- **来源**：存量（`git blame -L 120,142 -- f_dbd/src/driver/DbdConnection.cj` 全部落在 `ef7b9b06ee` 2026-10-18；`DbdStatement.query` 同批次）
- **判据**：review-checklist §12.1（检查-然后-写入 / 共享可变状态无保护）、§6.2（用并发容器或单锁当复合操作原子）、§11（契约与实现不符）
- **证据**：静态确定 —— `ensureNoOpenResult` 只在 `synchronized(lock)` 内**读** `activeResult` 后立即释放锁，`DbdStatement.query()` 随后在锁外调用 `connection.request(sqlPayload(), timeout)`（一次 `client.transfer` 往返），直到拿到 `QueryResultServerPayload` 才 `registerResult`（`DbdConnection.cj:138-141`，`activeResult = result` 无条件覆盖，既不校验 `closed` 也不校验已有值）。两个线程同时 `query()` 时都能在对方登记之前通过闸门并各自发包。
- **描述**：类注释 `DbdConnection.cj:28-35` 明确把「同一时刻连接上至多一个未关闭的 `QueryResult`」写成**不变量 6**，理由也写清了：`QueryResultColumnPayload` 不带结果标识，并发会让旧结果集的 `next/get` 作用到新游标。当前实现只挡住了**顺序**复用（前一个结果已登记且未关），挡不住**并发**：两个 `QueryResultImpl` 同时存活、`activeResult` 被后者覆盖，两个线程的 `NEXT_ROW` 交替打到同一连接级游标上 —— `next()` 返回的行属于对方的游标，`get<T>(i)` 读到的是别人的行，且不抛任何异常。触发面：任何把 `DbdConnection` 借给多线程的调用方（`f_dbpool.PooledConnection` 归还后又被另一线程借出、或调用方自行共享连接）；`DbdStatement` 与 `DbdTransaction` 自身无任何同步，同源。
- **建议**：在**同一临界区内完成「占位」与「登记」**，把闸门从 "check" 改成 "acquire"：`ensureNoOpenResult` 改名 `acquireQuerySlot()`，在锁内判断后立刻写入一个 `queryInFlight` 占位（或用 `activeResult` 存一个 pending 标志），发包失败 / 解码失败 / 非查询路径（`update`、事务语句）在 `finally` 里释放；`registerResult` 校验占位归属，`close()` 把占位一并清掉。补一个并发用例：8 线程对同一连接各 `query()` 一次，断言**恰好 1 个成功、其余 `CURSOR_STATE`**（现有用例 `DbdConnection_test.cj:128-154` 只覆盖单线程顺序）。

### [一般][存量] `SqlPayload` 参数按最大 index 逐位补 NULL，`set(index)` 只挡负数 —— 巨大 index 直接 O(n) 分配

- **位置**：`f_dbd/src/driver/DbdStatement.cj:249-266`（`sqlPayloadOf` 的 `while (i <= max)`）、`:64-73`（`set` / `setNull`）、`:168-172`（`checkIndex` 只判 `< 0`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（按不可信长度预分配 / 一次性物化）、§6.4（已知规模却用线性填充）
- **证据**：静态确定 —— `max` 只由调用方传入的 `index` 决定，`checkIndex` 仅拒绝负数；`while (i <= max)` 对每个空洞 `payload.addNull()`，即 `params` 长度恒为 `max + 1`，每个元素是一个 `DataAny` 包装。
- **描述**：`Statement.set<T>(index: Int64, value)` 是 std 公开契约，`index` 由应用代码给出。写错一个量级（例如 `set(1_000_000, v)`，或把 0 起索引误当成 1 起后随手写了个大数）就会构造百万级 `DataAny` 并在编码时全部序列化上链：按单元素约 30–50 字节估算，百万级即数十 MB 的瞬时分配，`Int64` 上界的一半就是必然 OOM / 长时间卡在 `while` 里。当前没有任何上界、也没有「参数个数」与 SQL 中 `?` 个数的核对。
- **建议**：给参数 index 加上界（例如 `> 65535` 直接 `CONVERSION`，或按驱动允许的最大占位符数），并在 `query()/update()` 前核对「参数个数 vs SQL 中 `?` 个数」（本模块目前没有占位符扫描工具，`common/placeholder.cj` 只有包注释，需要新增一次 SQL 文本扫描或由 fdbm 回带占位符数），把「参数多/少」从服务端错误提前成客户端 `CONVERSION`；若要保留稀疏语义，改成记录 `holes` 数量而非逐位补对象。

### [一般][存量] 连接上无事务互斥：两个 `DbdTransaction` 可同时 `begin`，std 契约要求的「已处于事务状态」拦截缺失

- **位置**：`f_dbd/src/driver/DbdConnection.cj:72-74`（`createTransaction()` 直接 new，不登记）、`f_dbd/src/driver/DbdTransaction.cj:72-78`（`begin()` 只校验自身的 `begun`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— `DbdConnection` 只有 `activeResult` 一个连接级状态，没有「当前事务」字段；`DbdTransaction.begun` 是实例字段，`txA.begin()` 对 `txB.begun` 无影响。std 文档（`std/database_sql/database_sql_package_api/database_sql_package_interfaces.md:116-127`）明确 `createTransaction()` 在「已经处于事务状态，不支持并行事务时」应抛 `SqlException`。
- **描述**：`txA.begin(); txA` 之后 `txB = connection.createTransaction(); txB.begin()` 会把第二条 `begin` 发到同一会话。后果取决于后端（**待确认**：MySQL 语义下第二条 `BEGIN` 会隐式提交前一个事务）：最坏是把未提交的事务静默提交，破坏原子性；最轻也是服务端告警/报错，而客户端两条 `DbdTransaction` 都认为自己「在事务中」，后续 `commit/rollback` 归属混乱。结果集有独占闸门，事务反而没有，属于同一层不变量缺了一半。
- **建议**：在 `DbdConnection` 增加 `activeTx: ?DbdTransaction`，`createTransaction()` 在 `synchronized(lock)` 内检查并登记（已有未结束事务 → `TX_STATE`），`DbdTransaction.commit/rollback` 结束时（含失败路径）注销；错误码沿用 `DbdErrorCode.TX_STATE`，与 `begin` 重复的拦截口径保持一致。

### [一般][存量] 关闭连接时用 `query_timeout` 等 `UNSUBSCRIBE` 的 ACK，未配置超时即最长阻塞 6 小时

- **位置**：`f_dbd/src/driver/DbdConnection.cj:97-113`（`close()` 里 `r.close()`）、`f_dbd/src/driver/DbdStatement.cj:84-92`（`closer` 闭包捕获 `timeout = timeoutOf(options.queryTimeout)`）、`f_dbd/src/driver/DbdTransport.cj:32`（`NO_TIMEOUT = Duration.hour * 6`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源释放路径的阻塞风险）、§12.1（跨线程资源 / 关闭路径可挂死）
- **证据**：静态确定 —— `QueryResultImpl.close()`（`f_dbd/src/common/result.cj:185-197`）首次调用同步等待 `closer_` 返回，而 `closer_` 就是 `{request => connection.unsubscribe(request, timeout)}`；`timeout` 在 `query()` 时取值，`queryTimeout` 为 `None` 时等于 `NO_TIMEOUT`（6 小时）。
- **描述**：连接上有未关闭游标时，`close()` 会先同步发 `UNSUBSCRIBE` 并等 ACK。对端半死（TCP 未断但对端不处理）时，`transfer` 要等满超时；未配置 `query_timeout` 的应用（默认 `None`，`DbdOptions.cj:35`）就要等 6 小时。这条路径在连接池淘汰、进程优雅退出、健康检查失败回收时都会走，表现为「关闭动作卡死」，比直接报错更难排查。`r.close()` 已吞异常，问题不在错误处理而在等待上限。
- **建议**：关闭路径改用独立的短超时（例如 `min(queryTimeout, 关闭超时, 默认 1–2s)`），或先 `transport.close()` 让在途请求立即 fail-fast，再尝试 `UNSUBSCRIBE`（当前顺序相反）。不要复用查询超时。

### [一般][存量] `DbdDatasource.setOption` 与 `connect()` 并发：选项表是裸 `var`，可能取到错配的 user/password

- **位置**：`f_dbd/src/driver/DbdDatasource.cj:34-46`（`credential()` 读 `options.user` / `options.password`）、`:86-88`（`setOption` → `options.apply`）、`f_dbd/src/driver/DbdOptions.cj:30-39`（字段全是普通 `var`，无同步）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（共享可变状态无保护）、§11（契约与线程安全声明不符）
- **证据**：静态确定 —— `DbdDatasource` 是公开的长生命周期对象（`Datasource` 的实现，被 `f_dbpool.DatabasePool` 持有并多线程 `connect()`）；`setOption` 直接改 `options`，`connect()` 在 `credential()` 里分两次读 `user` 与 `password`，再 `options.copy()` 逐字段读一遍；无锁、无原子、无 `volatile` 语义。注释（`DbdDatasource.cj:80-85`）只说「下次 `connect()` 生效」，没有声明线程安全。
- **描述**：一个线程 `connect()` 与另一个线程 `setOption(username/password)` 并发时，可能建出一条「新用户名 + 旧密码」的连接（认证失败，且错误信息里带的是新用户名，排查时会误判是密码错），也可能 `copy()` 读到半更新的超时组合。实际触发面窄（配置通常启动期写一次），但 `setOption` 是公开 API 且文档允许运行期调用，缺失同步是实打实的。
- **建议**：二选一并写进注释：(1) 声明 `DbdDatasource` 的选项只能在 `connect()` 之前设置（`closed` 之外的第二个状态位，运行期 `setOption` 抛 `CONFIG`）；(2) 把选项表改成不可变快照 + 原子替换（`setOption` 复制一份再 `AtomicReference` 换引用），`connect()` 只读一次快照。

### [一般][存量] `dbdDriver()` 注释与实现相反，且按需补注册是 check-then-act，并发首用会抛出未包装的 `SqlException`

- **位置**：`f_dbd/src/driver/DbdDriver.cj:132-152`（注释 `:133` 说「没注册到就抛 `DbdException(CONFIG)`」，实现 `:147-150` 是「按需补注册」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符 / 错误处理契约不符）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— `DriverManager.getDriver(name)` 返回 `None` 后才 `DriverManager.register(name, driver)`；std 文档（`database_sql_package_api/database_sql_package_classes.md:149-165`）写明 `register` **并发安全**，但「当指定的驱动名称已经存在时，抛出异常」（`SqlException`）。
- **描述**：两个线程在「配置晚于包初始化写入」的场景同时首次调用 `dbdDriver()`，都能看到 `None`，都构造实例并注册 —— 先到者成功，后到者从 `register` 拿到 `SqlException`。该异常不是 `DbdException`，绕过了本模块「对外只抛 `SqlException`/`DbdException`」的统一错误面；调用方按 `DbdException.code` 分支的代码会直接漏到通用异常处理。注释声称的「抛 `DbdException(CONFIG)`」也与实现相反，会误导排障。
- **建议**：补注册路径捕获 `SqlException` 后重查一次 `getDriver`（拿到即返回，仍为空才抛 `DbdException(CONFIG, cause: e)`）；同步修正 `:133` 的注释。若认为「包初始化后配置不应再变」，则删掉补注册分支、恢复成抛 `CONFIG`，与 `missingNameError()` 的口径一致。

### [一般][存量] `Transaction` 的 `isoLevel` / `accessMode` / `deferrableMode` 只记录不生效，设置后静默无效

- **位置**：`f_dbd/src/driver/DbdTransaction.cj:44-69`（三个 `mut prop` 只读写本地字段）、`:24-28`（注释自认「只作记录」）、`:72-78`（`begin` 恒发 `'begin'`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（公开契约承诺行为但实现为空分支）、§11（语义与约定不符）
- **证据**：静态确定 —— 三个字段除 getter/setter 外无任何读取点（全文件仅 `begin()` 发固定 `'begin'`）；测试 `DbdTransaction_test.cj:29-51` 把这一行为固化为断言（「属性只记录，`begin` 的 SQL 不随属性变化」）。std 文档（`database_sql_package_interfaces.md:590-620`）把三者定义为「事务的访问模式 / 延迟模式 / 隔离级别」，是描述驱动器行为的契约而非纯展示字段。
- **描述**：`tx.isoLevel = Serializable` 之后 `begin()` 发出的仍是裸 `begin`，事务实际隔离级别完全由后端默认值决定，且客户端不报错、不告警。调用方据此认为已获得串行化隔离，是典型的「静默失效」——一旦用于扣减/对账类逻辑会直接落地成数据一致性问题。
- **建议**：三选一并在 README 写明：(1) 对非 `Unspecified` 的赋值，在 `begin()` 时按方言拼 `begin isolation level ...`（fdbm 是代理，需后端支持，故至少要把值透传）；(2) 不支持时 `begin()` 抛 `DbdException(UNSUPPORTED/CONFIG)`，绝不静默；(3) 保留现状但每次 `begin()` 打一条 WARN。同时删除或改写 `:24-28` 的「只作记录」注释，避免与 std 契约冲突。

### [一般][存量] 关闭状态的边界检查不完整：已关闭连接仍可 `prepareStatement`/`createTransaction`，`registerResult` 不校验 `closed`，`close()` 只关闭快照中的结果集

- **位置**：`f_dbd/src/driver/DbdConnection.cj:65-74`（两个工厂方法不查 `closed`）、`:97-113`（先取快照 `pending` 再在锁外 `r.close()`，最后 `activeResult = None`）、`:138-141`（`registerResult` 无条件覆盖）；`f_dbd/src/driver/DbdStatement.cj:64-73`（`set`/`setNull` 不查 `closed`）、`:121-132`（`close()` 只关自己的 `openResult`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（空值 / 状态边界、资源释放不对称）、§12.1（关闭与在途请求竞态）
- **证据**：静态确定 —— 三处读 `closed` 的只有 `state`、`isClosed`、`ensureExecutable`；`registerResult` 与 `prepareStatement` 完全不看它。`close()` 的 `pending` 是锁内快照，之后的 `r.close()` 在锁外执行，期间别的线程仍可通过闸门（`closed` 不参与判断）并 `registerResult`。`DbdStatement.close()` 关掉结果集后也不通知连接，`connection.activeResult` 会继续强引用这个已关闭的结果集，直到下一次闸门或连接关闭。
- **描述**：(1) `connection.close()` 之后 `prepareStatement("select 1")` 成功返回一个句柄，真正的错误要等到发包时才以 `IO`（"transport is closed"）出现，与「连接已关闭」的直觉不符；(2) 关闭与在途 `query()` 竞态时，快照之后登记的结果集不会被 `close()` 收掉，随后的 `transport.close()` 让它变成一条悬空游标（下一次 `next()` 抛 `IO`），且它的 `UNSUBSCRIBE` 永远不会发；(3) `statement.close()` 之后 `set(0, x)` 仍会写入 `parameters`，句柄永远不会再用，纯属滞留内存。
- **建议**：`prepareStatement` / `createTransaction` / `set` / `setNull` 先判 `closed` 抛 `DbdException(CURSOR_STATE)`（与 `ensureExecutable` 同一口径）；`registerResult` 在锁内校验 `closed`，已关闭则立即 `result.close()` 并抛错；`close()` 改为「锁内置 `closed` + 取走 `activeResult` 置 `None`」，锁外关闭，不再二次加锁回头清空。

### [轻微][存量] 重复逻辑：`?Duration` → `NO_TIMEOUT` 的兜底写了两遍，同名 `timeoutOf` 还有第三种语义

- **位置**：`f_dbd/src/driver/DbdStatement.cj:161-166`（`private static func timeoutOf(configured: ?Duration)`）与 `f_dbd/src/driver/DbdTransaction.cj:113-116`（`execute()` 内联 `match (options.queryTimeout) { case Some(t) => t; case None => NO_TIMEOUT }`）；同名不同义：`f_dbd/src/driver/DbdOptions.cj:82-95`（字符串 → `?Duration`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名的重复 / 命名漂移）
- **证据**：静态确定 —— 两处「`Option` 为空则取 `NO_TIMEOUT`」逐行等价；`DbdOptions.timeoutOf` 名字相同但参数/返回完全不同（解析 + 校验），三者散落在同一包内。
- **描述**：语义相同的兜底重复两份，改默认超时策略（例如把 `NO_TIMEOUT` 换成 30s 或按操作区分）时必须同时改两处，漏改即行为漂移；同名函数承担解析与解包两种职责，搜索 `timeoutOf` 会误读。
- **建议**：抽成包内顶层 `func effectiveTimeout(configured: ?Duration): Duration`（放 `DbdOptions.cj` 或 `DbdTransport.cj` 旁边），`DbdOptions` 的解析函数改名 `parseTimeout`。差异点只有「解析失败保留原值」，与解包无关，可安全合并。

### [轻微][存量] 未使用的 import；测试文件重复 import 同一包

- **位置**：`f_dbd/src/driver/DbdStatement.cj:23`（`DataAny` 只出现在 import 行，全文无引用）；`f_dbd/src/driver/DbdDriver_test.cj:18-20`（`import std.database.sql.*` 之后又 `import std.database.sql.{DriverManager, SqlOption}`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（无调用者 / 未使用的 import）
- **证据**：静态确定 —— `grep -n "DataAny" f_dbd/src/driver/DbdStatement.cj` 仅命中第 23 行；`DbdDriver_test.cj` 的具名 import 与通配 import 覆盖同一批符号。
- **描述**：`DataAny` 自 `sqlPayloadOf` 改为 `payload.add<Data>(...)` / `addNull()` 后已无用处；测试里的重复 import 增加了「改了通配就得同步改具名」的维护面。不影响行为。
- **建议**：删除 `DataAny`；`DbdDriver_test.cj` 保留具名 import、删掉通配（该文件只用到 `DriverManager` / `SqlOption` / `ConnectionState` / `Connection` 等少数符号，保留通配则删掉具名）。

### [轻微][存量] 类型矩阵测试用 `toString()` 比较、不释放结果集、依赖全局 `MOCKDB`

- **位置**：`f_dbd/src/common/types_matrix_test.cj:112-119`（`@Assert(actual.toString(), expected.toString())`）、`:178-209`（`QueryResultImplTestResult` 与 `matrixResult` 从不 `close()` 语句/结果集，且每次先 `MOCKDB.clear()` 改全局状态）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（测试的资源对称性 / 断言强度）、§13 误报边界（测试准备代码不算重复逻辑，但断言写法仍可评）
- **证据**：静态确定 —— 断言两侧都转成字符串；`matrixResult` 返回 `QueryResult` 后调用方只 `readData` / `get`，无 `close`；三个 `@TestCase` 共享 `MOCKDB` 单例。
- **描述**：类型矩阵的本意是「任何一层漏一种类型都在这里失败」，但 `toString()` 相等会把「类型错了但文本一样」判为通过（例如 `String` 与 `Decimal` 都渲染成 `123.45`），矩阵的判别力被削弱一档；不关闭结果集靠 GC 兜底，一旦 `MOCKDB` 未来支持并行执行，`clear()` + `execution` 覆写会互相污染。
- **建议**：按 `Data` 的具体分支断言（`match (actual) { case d: DataString => ... }` 或直接比 `actual == expected`）；`matrixResult` 的调用方 `try/finally` 关闭结果集；把 `MOCKDB` 的准备逻辑收敛到 `@BeforeEach`。

> **范围外提示**：`f_dbd/README.md:25` 把单节点数据源签名写成 `DbdDatasource(url: String, opts!)`，代码是 `init(url: DbdUrl, opts!)`（`DbdDatasource.cj:34`），示例直接照抄会编译失败 —— 该文件归模块报告其它部分，此处只记一句。

## 优化可行性方案

本部分**无带基线的优化方案**：`scope.md`「已有性能资料」为空，本部分也没有 `cjprof` / `cjpm bench` 数据。可以想到的候选（`sqlPayloadOf` 逐位填充、`getMetaData` 每次新建 `HashMap`、`state` 每次取锁）缺改前基线，按铁律只能进下面的「待验证假设」，不得进 `todo.md` / `tasks.md`。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每行每列一次往返（无预读）使端到端延迟由 RTT 主导，`DbdConnection.request` 成为单位时间调用数最高的函数 | `f_dbd/src/driver/DbdConnection.cj:145-147`（经 `DbdStatement.query` / `QueryResultImpl.next` / `get`） | 请求数 / 行数比、单次 RTT、端到端 P95 | 对 1 万行 × 5 列的查询跑分段计时（`query` / `next` 循环 / `get` 循环），并统计 `transfer` 次数 |
| 2 | 连接池借出检查频繁调用 `isClosed()` → `state` 的 `Mutex`，在 32+ 并发借还下成为锁竞争点 | `f_dbd/src/driver/DbdConnection.cj:51-63`、`:115-117` | `BLOCKED` 线程占比、锁等待时长 | 32 线程压 `PooledConnection` 借还 5 分钟，采集线程状态（CPU profile 看不出锁竞争） |
| 3 | `getMetaData()` 每次新建 `HashMap` 并做 URL 正则之外的字符串拼接，被监控/上报按请求调用时可观 | `f_dbd/src/driver/DbdConnection.cj:81-91` | 调用频次、单次耗时与分配量 | 在 `getMetaData` 埋计数 + `getAllocatedHeapSize()` 对照，跑 10 分钟稳态 |
| 4 | `DbdTransaction` savepoint 名校验每次 `toRuneArray()` 分配，事务密集场景可优化为 `Byte` 扫描 | `f_dbd/src/driver/DbdTransaction.cj:136-147` | 每秒 savepoint 调用数、单次耗时 | `cjpm bench -O2` 对照 `save('sp1')` 100 万次 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_dbd/src/common/types_matrix_test.cj` | .cj | ✅ | 类型矩阵用例；见轻微「测试断言与资源」 |
| 2 | `f_dbd/src/common/types_test.cj` | .cj | ✅ | `decodeStrict` 正反例，覆盖到位 |
| 3 | `f_dbd/src/dbd.cj` | .cj | ✅ | 根包重导出 + 版本入口，无逻辑 |
| 4 | `f_dbd/src/dbd_test.cj` | .cj | ✅ | 重导出的编译期验证 |
| 5 | `f_dbd/src/driver/DbdConnection.cj` | .cj | ✅ | 见严重 #1、一般 #3/#4/#10 |
| 6 | `f_dbd/src/driver/DbdConnection_test.cj` | .cj | ✅ | 状态机 / 独占闸门 / 关闭握手；独占用例只覆盖顺序复用 |
| 7 | `f_dbd/src/driver/DbdDatasource.cj` | .cj | ✅ | 见一般 #5 |
| 8 | `f_dbd/src/driver/DbdDriver.cj` | .cj | ✅ | 见一般 #6 |
| 9 | `f_dbd/src/driver/DbdDriver_test.cj` | .cj | ✅ | 见轻微「未使用 / 重复 import」 |
| 10 | `f_dbd/src/driver/DbdOptions.cj` | .cj | ✅ | `?Duration` 解析与「非法值保留原值」逻辑自洽 |
| 11 | `f_dbd/src/driver/DbdStatement.cj` | .cj | ✅ | 见严重 #1、一般 #2/#4/#10、轻微 #8/#9 |
| 12 | `f_dbd/src/driver/DbdStatement_test.cj` | .cj | ✅ | 参数顺序 / 空洞 / deprecated 重载 / 流列，覆盖较全 |
| 13 | `f_dbd/src/driver/DbdTestSetup_test.cj` | .cj | ✅ | 顶层 `let` 以初始化副作用写入 `protocol_hostId`，无读取方但不是死代码（同 `multid/MultiDTestSetup_test.cj:22` 的既有约定） |
| 14 | `f_dbd/src/driver/DbdTransaction.cj` | .cj | ✅ | 见一般 #3/#7、轻微 #8 |
| 15 | `f_dbd/src/driver/DbdTransaction_test.cj` | .cj | ✅ | 状态机 / savepoint 注入 / 结果集互斥；把「属性只记录」固化成了断言 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分不含 `.md`，模块 README 与 `doc/**` 归其它部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 #1/#2/#3/#10；设计：职责划分清楚（Connection 管闸门、Statement 管参数、Transport 管收发），主问题是不变量只覆盖顺序路径；语言特性：`Option` 用法正确、`synchronized` 作用域窄；安全性：savepoint 名做了标识符白名单（`DbdTransaction.cj:130-147`），metadata 走 `toUrlMasked()` 屏蔽密码（`DbdConnection.cj:85`），未发现注入或凭据泄漏 |
| §1 死代码 | 1 | 已逐个搜索 `private` / 包内符号：`url`/`transport`/`options`/`lock`/`closed`/`activeResult`/`parameters`/`openResult`/`registeredName`/`NAME_KEY`/`logger` 均有读写点；`ensureNoOpenResult`/`registerResult`/`request`/`unsubscribe`/`sqlPayloadOf` 在包内均有调用者；`configuredName`/`configuredNameOrNone`/`missingNameError` 互链无孤立；`public` 且对外可达（`DbdDriver`/`DbdDatasource`/`DbdConnection`/`DbdStatement`/`DbdTransaction`/`dbdDriver`/`fdBDVersion`）一律不判；`DbdTransaction` 的三个 prop 是接口实现、豁免；唯一命中是未使用的 import 与测试里的重复 import（轻微 #9） |
| §2 重复逻辑 | 1 | 同文件两两比对：`DbdStatement` 8 个私有函数与 `DbdTransaction` 6 个私有函数语义各异，`setSqlDbType` 的 19 对（38 个分支）是类型分派表（差异即类型，不可合并）；跨文件按字面量搜：`'begin'`/`'savepoint '`/`'rollback to savepoint '` 各只一处，错误消息无复制。唯一同语义重复是 `?Duration → NO_TIMEOUT` 两处（轻微 #8）。测试脚本 `ConnScript` 与 `QueryScript` 形似，但按 checklist 误报边界（测试准备代码）不计 |
| §3 空实现 | 0 | `parameterColumnInfos` 返回空数组是协议事实（fdbm 无服务端参数元数据）且有注释；`DbdDatasource.close()` 只置标志，因为没有需要释放的资源（连接各自持 Client），注释已说明；无 `TODO`/`FIXME`/裸 `catch {}`（两处 `catch (_: Exception) { () }` 分别是「关闭结果集失败不阻断关闭」与「transport.close 幂等」，均有注释且是刻意的降级）。近似空实现的是事务三属性（一般 #7，按契约不符单列） |
| §4 栈溢出 | 0 | 本部分无递归：`isIdentifier`/`isStart`/`isPart` 是单层循环，`sqlPayloadOf` 是 `while`，无自引用结构遍历；`DbdStatement.setSqlDbType` 是 `match` 分派 |
| §5 OOM | 1 | #2（按调用方给的 index 逐位补 NULL，`max` 无上界）。其余路径有界：`parameters` 条目数 = 不同 index 数，`getMetaData` 固定 7 项，`close()` 不复制集合 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench（`scope.md`「已有性能资料」为空），本部分也无分段计时；4 条候选全部进「待验证假设」，不参与严重度统计 |
| §6.2 大粒度锁 | 0 | `DbdConnection` 的唯一互斥区只读/写两个字段（`closed`、`activeResult`），无 I/O、无解析、无回调；`close()` 的 `r.close()`（会发网络包）刻意放在锁外（`DbdConnection.cj:102-108`），`unsubscribe`/`request` 全程不持锁 —— 锁粒度本身没问题，问题在锁保护的「复合操作」不完整（见 #1） |
| §6.3 并发串行 | 0 | 本部分不 `spawn`、无 `Future.get`、无线程池；一条连接天然串行是协议约束（`QueryResultColumnPayload` 无结果标识），不是可优化的串行段 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`/`indexOf`、无 `remove(at:0)`、无循环内字符串拼接；唯一与规模线性相关的 `sqlPayloadOf` 已按 OOM 计入 #2，不重复计数 |
| §7 降堆内存方案 | 0 | 无基线数据，候选（缩短 `activeResult` 对已关闭结果集的强引用、Statement 复用时不重复 `options.copy()`）无法给量化收益，按要求不写成方案 |
| §8 降 CPU 方案 | 0 | 同上；`getMetaData`、`isIdentifier` 的分配量缺调用频次数据，只进待验证假设 |
| §9 local mode 可行性 | 0 | 逃逸检查不通过：`sqlPayloadOf` 构造的 `SqlPayload` 是返回值（逃逸），`getMetaData` 的 `HashMap` 是返回值，`isIdentifier` 的 `toRuneArray()` 结果虽不逃逸但仅数十字节、无峰值内存收益；且无前后峰值数据，只能作废 |
| §11 现有代码的 BUG（存量） | 8 | 已核对本部分全部边界/空值/错误/资源路径：#2（index 上界）、#3（事务互斥）、#4（关闭路径 6h 阻塞）、#5（选项表数据竞争）、#6（补注册异常面）、#7（事务属性静默无效）、#8（重复导致的行为漂移）、#10（关闭状态边界）。`DbdTransaction.check` 在 `runes[0]` 前先判空串（`:131`），无越界；`DbdStatement.sqlPayloadOf` 对空参数集 `max = -1` 不进入循环，无差一 |
| §12 并发安全与锁粒度 | 4 | 共享路径与同步手段逐条列：`DbdConnection.activeResult`（有 `Mutex`，但检查与登记跨 RTT，见 #1）、`DbdConnection.closed` 与 `registerResult`（关闭竞态，见 #10）、`DbdDatasource.options`（裸 `var` 无同步，见 #5）、`DbdConnection` 上的事务状态（完全缺失，见 #3）。`DbdStatement` / `DbdTransaction` 无同步，注释也未声明线程安全，属同一根因的放大面；锁粒度本身合理（临界区只有字段读写） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 public 面是 std 接口实现（`Connection`/`Statement`/`Transaction`），README 不作为其契约来源；本部分涉及的入口 `dbdDriver()` / `DbdDatasource` / `dbd_driverName` 在 `f_dbd/README.md:5,17,25` 均有登记；选项表（`query_timeout`/`update_timeout`/`fetch_rows`）未进 README，属模块 README 的覆盖问题，留给对应部分判定。未发现「承诺但未接线」的功能（`f_dbd/src/driver/placeholder.cj` 只有包注释，无占位实现） |
| 文件覆盖（§13 等） | 15/15 | 本部分无 `.md` 文件，§13 文档一致性不适用；`f_dbd/README.md:25` 的签名漂移已作范围外提示 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 7 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 11 条（本部分全部为存量，快照模式无基线），是否纳入修复待用户决定。

## 总评

连接 / 语句 / 事务这一层的**结构**是清楚的：Connection 持有传输与「结果集独占」闸门，Statement 只做本地参数收集，Transaction 只发会话控制语句，`DbdOptions` 用「拷贝一份给下游」避免串改；锁的临界区也刻意只包字段读写、把网络 I/O 留在锁外，这几点都对。资源释放的对称性基本到位（`close()` 均为幂等、结果集先于传输关闭、`transport.close()` 吞异常）。

主要风险集中在**「不变量只在顺序路径成立」**：类注释把「同一时刻至多一个未关闭结果集」提升为不变量，但实现是「检查 → 发包 → 登记」三段式，锁只保护了中间的空档，并发 `query()` 可以同时通过并让两条游标共存，后果是行数据静默错位（#1，本部分唯一阻塞项）。同一层的另外两个缺口是**事务互斥完全缺失**（#3）和**关闭路径缺少独立超时**（#4，未配 `query_timeout` 时最长阻塞 6 小时），前者可能破坏事务原子性，后者会让连接池淘汰与进程退出挂死。

可以排期的：参数 index 无上界导致的 O(n) 分配（#2）、选项表与关闭状态的边界（#5/#10）、`dbdDriver()` 的异常面与注释不符（#6）、事务三属性静默无效（#7）。纯整洁类的是重复的超时兜底（#8）、未使用的 import（#9）与类型矩阵测试的断言强度（#11）。

性能方面本部分没有可用数据，四条候选（往返放大、`state` 取锁、`getMetaData` 分配、savepoint 校验）已按铁律放进「待验证假设」，不作为结论。
