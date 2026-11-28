# fdbm 模块审查报告（模块第 4/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fdbm/src/{execute,idmaker,resources,route}` + `fdbm/src/main.cj`（19 个文件，本部分）
- **基线**：工作区快照（`master` 与 `sts/1.3.x` 同一提交，`git diff` 为空）⇒ 全部记「存量」
- **审查重点**：多数据源与连接生命周期、启动期装配、并发安全、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `docs/review/2026-11-28/fdbm_v2.md`）
- **范围**：仅本部分 19 个文件；其他部分的文件只在判「重复 / 无用」时作引用证据，不展开审查

> 说明：本部分全是 `protected` / 包内实现与测试，没有对外可达的 `public` 契约面（`main.cj` 的 `main` 除外），因此 §13 / §14 的「README 覆盖」由模块其他部分承担，这里只给结论。

## 发现

### [严重][存量] 每行 INSERT 都新建 `SnowflakeIdGenerator`，同一毫秒内两次构造返回相同 ID

- **位置**：`fdbm/src/idmaker/IdMakers.cj:262`（`return Some(SnowflakeIdGenerator(serial))`）；触发点 `fdbm/src/execute/executors.cj:898`（`fillAndRoute` 里**每行**调用 `IdMakers.forTable`）；机理依据 `f_util/src/IdMaker.cj:26,32,41`
- **来源**：存量（`git blame` c81e5dcc2a，2026-10-18，`IdMakers.cj:262` 与 `executors.cj:897-913` 同一提交）
- **判据**：review-checklist §11（数据错误 / 契约不符）+ §5（`IdMakers.cj:31-37` 注释声称「进程级复用」，实现每次新建，语义与注释不符）
- **证据**：静态确定 —— `IdMaker` 的种子是实例字段 `startMillis = now().toMilliseconds()`（`IdMaker.cj:26`），初值 `current = (hostSerial << 53) | (startMillis << 12)`（`:32`），`nextInt64()` 返回 `current.fetchAdd(1)` 的自增前值（`:41`）。两个实例若 `hostSerial` 相同且在同一毫秒内构造，则初值完全相同，首个 `nextInt64()` 必然返回同一个 `Int64`
- **描述**：`insert into t (name) values ('a'), ('b')`（未给分库列）在 `insertRows` 里逐行走 `fillAndRoute`（`executors.cj:705-711`），每行都新建一次生成器。分库键通常就是该 ID（主键/唯一键），两行拿到同一个值 → 第二条 INSERT 主键冲突，或（无唯一约束时）出现两条同 ID 记录，路由与唯一性契约同时被破坏。`insert ... select` 逐行插入时同样成立。概率取决于两行之间是否跨毫秒（同一语句内通常在同一毫秒），因此表现为「偶发重复键」，最难定位
- **建议**：生成器按 `(kind, arg)`（或按分库表）在 `InsertExecutor` 构造期缓存一份，`fillAndRoute` 只取缓存实例；`fillAndRoute` 本身也应改为一次取生成器、多行复用。若短期不改缓存，至少在 `SnowflakeIdGenerator` 内部把 `IdMaker` 做成 `static`（按 serial 分桶）以保证同进程单调唯一。补一条用例：`insert into t (name) values ('a'),('b')` 在 snowflake 表上断言两个分库键不同

### [严重][存量] `insert ... select` 全量物化后再逐行插入，无任何行数上限

- **位置**：`fdbm/src/execute/executors.cj:830-857`（`rows = ArrayList<Array<SqlExpression>>()`，`while (cursor.next())` 全读）
- **来源**：存量（`git blame` c81e5dcc2a，2026-10-18）
- **判据**：review-checklist §5（一次性物化 / 无拒绝路径）
- **证据**：静态确定 —— 物化循环无 `limit`、无分批、无行数上限；随后 `for (row in rows) statements.add(fillAndRoute(...))` 又把每行扩成一条 `InsertStatement`（每行再分配 3 个 `ArrayList` + 3 个 `Array`，`executors.cj:864-918`）。**峰值内存阈值需实测**
- **描述**：`insert into t (c1,c2) select ... from big_table` 会把源结果整表读进内存：每行 ≈ 1 个 `Array<SqlExpression>` + 每列 1 个 `LiteralExpression`/`Data`，加上第二阶段的 `InsertStatement` 常驻副本。按 1M 行 × 5 列、每格 50–100 B 粗估，单次插入峰值可达 0.5–1 GB 量级；源表由用户决定，服务端没有拒绝路径，容器内存上限到达即 OOM。`executors.cj:809-812` 的注释只解释了「为什么要物化」（游标占连接 → `maxSize=1` 会自锁），没有给出容量约束
- **建议**：改为有界分批（例如每 N 行一组：物化 → `executeAll` → 释放），`N` 取池大小与行宽的折中并写进配置；或先对源 SELECT 施加 `limit` 上限并在超限时返回明确错误码。分块后仍需保证「同库同事务」的分组语义（可复用 `executeAll` 的按库分组逻辑）
- **验证**：同输入下记录 `getUsedHeapSize()` / RSS 峰值与插入耗时，确认峰值与总行数脱钩

### [一般][存量] 无列清单的 INSERT 生成了分库 ID 却丢弃，最终以「无法判定目标库」报错

- **位置**：`fdbm/src/execute/executors.cj:905-913`（`literal` 已算好，只在 `columns` 非空或 `hasPairs` 时追加）
- **来源**：存量（`git blame` 4aa0684f2c / c81e5dcc2a，2026-10-18）
- **判据**：review-checklist §11（语义与命名/注释不符、错误处理不准确）
- **证据**：静态确定 —— `missing` 为真（`columns` 与 `pairs` 都为空时恒真，`:894-896`），生成器被调用（`:905` 产生了副作用），随后 `if (!columns.isEmpty()) … else if (hasPairs) …` 两个分支都不成立，`literal` 被直接丢弃
- **描述**：`insert into t values (…)`（省略列清单）在分库表上会先生成 ID（`sequence` 生成器会真的开事务、`update fountain_sequence`；`snowflake` 会消耗一个时间戳序号），然后把值扔掉。该语句随后在 `router.insertConstraint`（`route/router.cj:384-397`）因「列清单为空且 setPairs 为空」返回 `None` → `RoutePlan.unroutable()` → `executors.cj:1003-1005` 抛 `ROUTE_FAILED: insert cannot determine a target database`。用户看到的是路由错误而不是「省略列清单时无法补分库列」，同时白烧一次序列值
- **建议**：`missing && columns.isEmpty() && !hasPairs` 时直接抛 `UNSUPPORTED_SQL`/`ROUTE_FAILED`：「省略列清单的 INSERT 必须显式提供分库列」；或在生成 ID 之前就判定，避免生成器副作用

### [一般][存量] 分库缓存容量计数只增不减，TTL 过期后永久停写新键

- **位置**：`fdbm/src/route/cache.cj:36,67-90`（`count_` 只在 `put` 自增、`remove` 自减）
- **来源**：存量（本文件 2026-10 提交，快照模式无 diff）
- **判据**：review-checklist §11（契约与实现不符）+ §5（缓存键无界 / 计量漂移）
- **证据**：静态确定 —— `f_store` 的 TTL 是**读取时过滤**（`f_store/src/Store.cj:149-170` 的 `checkExpiryAndGet`，`LevelManager.get(key, now)`），过期条目不会回调 `PartitionCache.remove`；而 `closed`/`count_` 没有任何重算路径。`init` 只在启动时扫一次 prefix 计数（`cache.cj:45-51`）
- **描述**：进程长期运行后，凡是写过的键数累计到 `fdbm_cache_size`，`put` 就永久走 `count_ >= capacity` 分支停止写新键（每个新键只 WARN 一次），即便其中绝大多数条目已过期、store 实际体积已回落。更进一步：同一键过期后再次 `put`，`store.get(key).isNone()` 为真 → `count_` 再加 1，漂移比真实键数更快。表现为「缓存跑一段时间后突然全部不命中」，而 `fdbm_cache_size` 形同虚设
- **建议**：计数改为「写时按 store 返回值判定 + 定期重算」（例如每 N 次 `put` 或每次启动后按 `store.prefix` 重新计数，或把过期条目在 `put` 路径上顺带 remove）；容量判定改用 `store` 的真实键数或独立的持久化计数键

### [一般][存量] `DbdSession.installCursor` 在互斥锁内关闭旧游标（含连接归还与驱动 I/O）

- **位置**：`fdbm/src/execute/session.cj:100-122`（`synchronized(lock)` 内 `existing.close()`）
- **来源**：存量
- **判据**：review-checklist §12.2 / §6.2（锁内 I/O）
- **证据**：静态确定 —— `QueryCursor.close()`（`cursor.cj:198-209`）→ `CursorSegment.close()`（`cursor.cj:42-64`）→ `result.close()` / `statement.close()` / `connection.close()`，后者把连接归还 `DatabasePool`（可能触发驱动侧的往返或池内 `checkOnReturning` 校验）；同类 `DbdSession.close()`（`session.cj:147-164`）采用的是「先 `takeCursor()` 摘除，再在锁外关闭」，本方法没有沿用
- **描述**：会话锁同时保护 `pinned`（`pinnedConnection()`）与 `cursor`。旧游标关闭期间的网络/池等待全部落在锁内，此时另一线程（巡检 `SessionRegistry`、关停线程）取 `pinnedConnection()` 会被一起阻塞；`maxSize=1` 或池等待上限较长时，阻塞时间可达秒级。正确性没有问题（没有回调回本锁），但这是「锁内做大粒度 I/O」
- **建议**：与 `close()` 对齐：锁内 `let old = cursor; cursor = Some(value)`，锁内只做「已关闭则关新游标」的判定，`old.close()` 移到锁外

### [一般][存量] 事务 pin 的「检查已 pin」与「写入 pin」分两次取锁

- **位置**：`fdbm/src/execute/executors.cj:1352-1362`（`if (session.isPinned())` … 之后 `session.pin(pinned)`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入）
- **证据**：待确认 —— `isPinned()`（`session.cj:78-82`）与 `pin()`（`:133-137`）是两次独立加锁；当前依赖上层「每个连接独占一个处理线程」的约束（`server/handler.cj:100` 注释「正常客户端按连接级独占拦截」），因此现状不会并发进入。缺的信息：是否存在其他线程对同一 `DbdSession` 执行语句（例如未来的并行执行或后台重放）
- **描述**：一旦同一会话被两个线程同时执行 `BEGIN`，两者都会看到 `isPinned() == false`，第二个 `pin()` 覆盖第一个 `PinnedConnection` 且不关闭它 → 池连接泄漏 + 事务归属错乱。后果是资源泄漏与事务语义破坏，但因为当前有上层独占约束，暂定「一般」
- **建议**：把「检查 + pin」收成一个原子方法（`tryPin(value): Bool`，锁内判空后写入），`Begin` 分支用它的返回值决定是否关闭新连接

### [轻微][存量] `PinnedConnection.transactionOpen` 只写不读

- **位置**：`fdbm/src/execute/session.cj:27`（声明）；唯一写入点 `fdbm/src/execute/executors.cj:1361`
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死字段）
- **证据**：静态确定 —— 全仓搜索 `transactionOpen`：代码侧只有声明与 `pinned.transactionOpen = true` 一处写入；其余命中都在 `fdbm/README.md:261`、`README_en.md:299`、`doc/详细设计.md:719` 的「公开 API」列表里
- **描述**：字段对外不可达（所属 `PinnedConnection` 是 `protected class`），仓内零读取，属于兼容残留/预留位。它同时被 README 当作公开能力描述，会把使用者引向并不存在的语义
- **建议**：删除字段并同步 README 的「其他公开 API」段；若要保留「事务是否打开」的可观测性，至少让 `SessionCtlExecutor` 在读侧使用它（例如 `COMMIT` 前后校验），并补用例

### [轻微][存量] `warnPinnedGlobalWrite` 每条语句都打 WARN，与「首次发生」的注释不符

- **位置**：`fdbm/src/execute/executors.cj:140-146`（函数内无 once 标志），调用点 `:504`、`:568`、`:994`
- **来源**：存量
- **判据**：review-checklist §11（注释与实现不符）+`perf §9.1`（日志放大）
- **证据**：静态确定 —— 注释写「首次发生时记 WARN」，实现每次调用都 `execLogger.warn(...)`
- **描述**：事务内的批量全局表写入（循环 INSERT / 批量 UPDATE）会为每条语句输出一条同样的 WARN，把限制说明变成噪声；若日志按条同步落盘还会放大延迟
- **建议**：改为「每会话一次」（`DbdSession` 加 `globalWriteWarned: Bool`，锁内判定）或「每进程一次」（`AtomicBool`），并让注释与实现一致

### [轻微][存量] DDL 广播用「全局 firstCause」当收尾失败标志，后续库的收尾异常被吞

- **位置**：`fdbm/src/execute/executors.cj:1299-1306`（`closeAfterExecution(found, firstCause.isSome())`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理不完善 / 资源释放不对称）
- **证据**：静态确定 —— `firstCause` 是整轮循环的累计状态：只要前面任一库失败过，后面**成功**库的 `connection.close()` 异常都会走「已失败」分支只记 WARN（`executors.cj:36-45`），不再抛给调用方
- **描述**：失败库数 ≥1 时，后续库的归还失败（连接未真正回到池里、池计数漂移）在日志级别上与首错混在一起，既不计数也不回报，`closeAndAwait` 之后才暴露。`broadcastWrite` 用的是逐库 `try { close } catch { warn }`，语义可接受；这里的问题是把「本轮是否已失败」当成「本次关闭是否需要上报」
- **建议**：把标志改为本次迭代的局部 `failed`（与 `DmlExecutor` 的 `var failed` 写法一致），首错仍由 `firstCause` 保留，两者分开

### [轻微][存量] `DeleteExecutor.queryKeys` 用 `ArrayList.contains` 去重，复杂度 O(n²)

- **位置**：`fdbm/src/execute/executors.cj:635-644`
- **来源**：存量
- **判据**：review-checklist §6.4（热点里对 `ArrayList` 反复 `contains`）
- **证据**：静态确定（复杂度）；实际耗时占比未测
- **描述**：`delete from t where …` 命中 k 行去重分库键时是 O(k²) 字符串比较，k 由受影响行数决定（无 `limit`）。键值基数通常远小于行数，所以多数场景不痛；大范围 DELETE 时会变成主要 CPU 项。同类去重散落在 `router.cj:337-343`、`:402-408`（`ArrayList.contains` 去重）
- **建议**：改用 `HashSet<String>` 去重后再 `toArray()`；`router.cj` 的同款写法一并处理

### [轻微][存量] `MemoryQueryResult` 的 `close()` 是空转，`next()` / `getOrNull()` 也不检查 `closed`

- **位置**：`fdbm/src/execute/cursor.cj:250-322`（`close()` 只置 `closed = true`；`next()` `:267-270`、`getOrNull()` `:284-313` 均未检查）
- **来源**：存量
- **判据**：review-checklist §3（空实现）+ §11（契约与实现不符：`QueryCursor` 关闭后访问抛 `CURSOR_STATE`，内存结果不抛）
- **证据**：静态确定 —— `QueryCursor.close()`（`cursor.cj:198-209`）只关闭 `segments`，从不关闭 `memory`；全仓也没有其它调用 `MemoryQueryResult.close()` 的路径，因此 `closed` 永远为 `false`
- **描述**：`SHOW DATABASES` / `count(*)` 走内存结果，客户端在 `UNSUBSCRIBE` 之后再发 `NEXT_ROW`/列读时：`QueryCursor` 会抛 `CURSOR_STATE`，而内存通道（若游标还没被摘下）仍能继续返回行。两套结果通道的关闭语义不一致，属于「关闭后仍可读」
- **建议**：`next()`/`getOrNull()` 首行加 `if (closed) throw FdbmException(CURSOR_STATE, …)`，并让 `QueryCursor.close()` 一并关闭 `memory`

### [轻微][存量] 重复逻辑：逐库执行与「广播 + 部分失败」模板各写了多份

- **位置**：逐库执行块 3 份 —— `fdbm/src/execute/executors.cj:521-536`（UPDATE）、`:591-606`（DELETE）、`:1016-1031`（INSERT）；广播 + 部分失败聚合 2 份 —— `:224-256`（`broadcastWrite`）、`:1283-1313`（`DdlExecutor.execute`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 跨函数复制）
- **证据**：静态确定 —— 逐库块逐行同构（`borrow` → `executeUpdate` → 累加 `rowCount`/`lastInsertId` → `finally { if (owns) closeAfterExecution(connection, failed) }`），只有「执行什么」不同；广播块同构（遍历库 → `try` 执行 → `succeeded`/`failed` 列表 → `firstCause` → `DB_ERROR: … success: […] failed: […]`），差异只有连接来源（`selectAllWrite` vs `borrow`）与是否累加 `lastInsertId`
- **描述**：三份逐库块已经出现漂移风险信号（DDL 那份把失败标志写成全局 `firstCause`，见上一条）；两份广播块的错误消息前缀不同（`'global table write partially failed'` vs `'ddl partially failed'`），文案可参数化
- **建议**：抽两个模块内辅助：`forEachTarget(session, databases, write, (Connection) -> UpdateResult)` 返回 `(rowCount, lastInsertId)`；`broadcastEach(databases, openConnections, what, (Connection) -> Unit)` 统一部分失败聚合。语义差异（错误前缀、是否 `lastInsertId`）显式参数化，不合并成泛型模板

### [轻微][存量] 重复逻辑：`joinNames` / 收尾工具 / 桶下标计算 / 测试 `codeOf` 各有多份

- **位置**：
  - `joinNames`：`fdbm/src/execute/executors.cj:194-203`、`fdbm/src/route/router.cj:477`（`Array<String>` 版）、`fdbm/src/server/DriverLoader.cj:84`（`ArrayList<String>` 版）
  - 收尾工具：`fdbm/src/execute/executors.cj:36-45`（`closeAfterExecution`）与 `fdbm/src/idmaker/IdMakers.cj:171-180`（`SequenceIdGenerator.closeResource`），语义完全一致（`!failed` 则抛出，否则 WARN），只有日志文案不同
  - 哈希 → 桶下标：`fdbm/src/route/algorithms.cj:163`、`:226`、`:270`、`:283` 四份 `((hash % n) + n) % n`，而 `:28-31` 已有 `bucketOfString`（仅覆盖 `UInt64`）
  - 测试 `codeOf` 系列：`fdbm/src/route/Route_test.cj:459`（`partitionCode`）与 `:472`（`cacheCodeOf`）**函数体逐字相同**，另有 `fdbm/src/resources/DatabaseResources_test.cj:159`（`fdbmCodeOf`）、`fdbm/src/execute/Dispatcher_test.cj:1297`、`fdbm/src/execute/Cursor_test.cj:50`、`fdbm/src/server/Server_test.cj:382`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定（函数体两两比对；`partitionCode` 与 `cacheCodeOf` 逐行相同）
- **描述**：`cacheCodeOf` 与同文件 `partitionCode` 完全重复（名字不同、语义相同），属于纯冗余；`closeAfterExecution` / `closeResource` 的一致性靠人工维持，后续任一处改动都会让「首错优先」规则在两条路径上分叉
- **建议**：`executors.cj` 与 `IdMakers.cj` 共用同一个收尾辅助（放 `fdbm/src/execute` 或 `fdbm/src/util`，同包内可见即可）；`algorithms.cj` 把有符号哈希的取模也收进 `bucketOfString`（重载 `Int64` 版）；测试 `codeOf` 合并成一个包内 `func`（`fdbmCodeOf` 已是最通用名字，其余别名删除）

### [轻微][存量] 测试断言强度不足：自比较断言、靠 `sleep` 制造竞态、码点切分未验证

- **位置**：`fdbm/src/route/Route_test.cj:70,74,76,84,93`（`@Assert(x.partition(k), x.partition(k))` 同一表达式自比较）；`:88`（只断言 `size > 0`）；`:178`（`sleep(5ms)` 后 `close`，`concurrentPutsAndCloseStayConsistent`）；`fdbm/src/main_test.cj:28`（只断言版本串非空）
- **来源**：存量
- **判据**：review-checklist §11（可测试性）/ §14（示例覆盖）
- **证据**：静态确定 —— 自比较断言对「分布是否合理」「跨进程是否稳定」没有任何约束；`substringPartitionUsesRunes` 的注释声称「多字节按码点切，不会切出半个字符」，但没有一处断言实际切片结果（例如 `partition('中文')` 等于 `partition('中')` 在 1 码点规格下的值）；`sleep(5ms)` 期间若 1000 次 `put` 已经跑完，该用例根本没有覆盖 `close` 与 `put` 的交错
- **描述**：这些用例能让 CI 常绿，但无法发现本部分最需要保护的两类回归：哈希/切片分布漂移、缓存关闭竞态
- **建议**：`partition` 用例改为断言**已知期望值**（先跑一次固化期望，或用固定算子的 `FixedAlgorithm` 作对照）；`substringPartitionUsesRunes` 断言 `runes` 级切片结果；竞态用例改为「持有 `Store` 锁/屏障 + 确定性交错」，或至少断言「观察到至少一次 `CACHE` 异常」

### [轻微][存量] 仅被测试引用的包内 API（可见性建议，不计死代码）

- **位置**：`fdbm/src/route/global.cj:70-75`（`GlobalTableRouter.tables`，只被 `Route_test.cj:336` 用）；`fdbm/src/resources/DatabaseResources.cj:35,232-237`（`NodeAccessor.readNodes` / 实现，仅 `DatabaseResources_test.cj:97,122` 用）；`fdbm/src/route/cache.cj:103-107`（`PartitionCache.count`，仅测试用）
- **来源**：存量
- **判据**：review-checklist §1（仅测试使用 → 可见性建议，不是死代码）
- **证据**：静态确定 —— 在 `fdbm/src` 全量搜索，三者都只在 `*_test.cj` 命中；`readNodes` 是接口成员（实现类必须提供），不判死代码
- **描述**：三个符号在生产路径零引用，只有测试在用；`readNodes` 的接口声明还要求所有 `NodeAccessor` 实现（含测试桩）都实现它
- **建议**：保留但显式注释「测试/诊断用」；或把 `readNodes` 从 `NodeAccessor` 移到 `DatabaseResources` 的具体方法上（测试直接依赖具体类型），减少实现桩的负担

## 优化可行性方案

> 以下都不是缺陷；均无改前基线，按铁律只能作为「待验证」的候选，不进 `tasks.md`。

### [堆内存] 游标行缓冲用两个 `HashMap` 改为按列下标的 `Array<?Data>`

- **现状**：`QueryCursor` 持有 `cells: HashMap<Int64, Data>` 与 `streams: HashMap<Int64, InputStream>`（`fdbm/src/execute/cursor.cj:85-86`），每行 `clearRow()`（`:242-246`）清空再逐格 `add`。列数在 `infos` 里已知，但缓冲仍按哈希表组织：每格一次哈希 + 每次 `add` 可能的扩容；`clear()` 只清元素不还物理内存（`mem §3.2`），行缓冲的桶数组会长期驻留
- **方案**：改为 `Array<?Data>(infos.size, repeat: None)` + `Array<?InputStream>`，`clearRow()` 改成「按已写下标置 `None`」或直接 `Array` 重建（`infos.size` 是常量级小数组）
- **预期**：每行每列省一次哈希与装箱查找；行缓冲常驻内存从「按峰值列数 × 负载因子」降到「列数 × 8B 指针」；`clear()` 不再留下不回收的桶数组
- **代价**：`cell(index)` 的越界判定改用 `infos.size`（已有），语义不变；`streams` 需要额外的「已打开」标记来区分 `None`（未打开）与「打开后为 null」，实现上比 `HashMap` 多一个布尔数组
- **验证**：同 SQL、同结果集（1 万 / 10 万行，10 列）跑 `cjpm bench -O2`，对照 `getAllocatedHeapSize()` 增量与单行 `NEXT_ROW`+列读的中位耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 分库缓存启动期全量 prefix 计数改为持久化计数

- **现状**：`PartitionCache.init`（`fdbm/src/route/cache.cj:45-51`）用 `store.prefix(Array<Byte>())` 遍历**全部**键来初始化 `count_`，每个键分配一次迭代器条目；键数到百万级时启动时间与峰值内存都随库体积线性增长
- **方案**：在同一个 `Store` 里维护一个保留键（例如 `\x00.count`）记录键数，`put`/`remove` 原子更新；启动时只读一个键。若担心历史数据没有计数键，可只在「计数键缺失」时退回一次全量扫描并写回
- **预期**：启动期从 O(键数) 降为 O(1)；启动峰值内存不再随缓存体积增长
- **代价**：多一次 `Store` 读写（`put` 路径），计数与真实键数仍可能漂移（需与「TTL 过期」一并处理，见「一般」条目）
- **验证**：预置 100 万键的 store 目录，对照 `PartitionCache` 构造耗时与 RSS 峰值（改前/改后各 5 次取中位数）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 按表缓存 ID 生成器，去掉逐行构造与逐行读配置

- **现状**：`InsertExecutor.fillAndRoute` 每行调用 `IdMakers.forTable`（`fdbm/src/execute/executors.cj:898`）→ `uuid` 每次新建 `TimeBasedUUIDBuilder` 并 `registerSequenceGenerator()`（分配 2 个原子 + 闭包，`f_util/src/uuid.cj:689-704`）；`snowflake` 无 `arg` 时每行 `Config.getValue<Int64>(IdMaker.HOST_SERIAL)`（`IdMakers.cj:255-260`）；`IdMaker` 构造还要取一次毫秒时间戳
- **方案**：`InsertExecutor` 构造期按 `(logical, table)`（或 `(kind, arg)`）建 `HashMap<String, IdGenerator>` 缓存；`fillAndRoute` 只查表。与「每行新建生成器导致重复 ID」是同一处改动
- **预期**：每行省掉 1 次生成器构造 + 1 次配置读取 + 1 次时间戳/随机数初始化；批量 INSERT 的固定开销与行数解耦
- **代价**：生成器变成进程级共享，必须保证线程安全（`UuidIdGenerator` 已有 `Mutex`，`SequenceIdGenerator` 每次借连接，`IdMaker` 内部是 `AtomicInt64`）；配置变更不再对已缓存的生成器生效（配置本来只在启动读一次，符合基线 §5）
- **验证**：`cjpm bench -O2`，1000 行单语句 INSERT（uuid v1 / snowflake 各一组），对照总耗时中位数与 `cjprof` 里 `IdMakers.forTable` 的自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 分库缓存：去掉重复 `store.get`，把磁盘 I/O 移出会话级热点锁

- **现状**：`PartitionCache.put`（`fdbm/src/route/cache.cj:74,81`）对同一个 key 连续 `store.get` 两次；`get`/`put`/`remove` 全部在**同一把** `Mutex` 内做 `f_store` 读写（磁盘/内存表 + WAL append），而路由在每次未命中时都会调用 `routeByValue` → `store.get`（`route/router.cj:222`）
- **方案**：`put` 先算 `existing = store.get(key)` 复用结果（`store.add` 的返回值本身也带回旧值，可直接用）；锁内只做 `count_` 与容量判定的状态维护，`store.get`/`store.add` 移到锁外（注意 `count_` 的检查-然后-写入需与 `store` 操作配对，可用「先占位后写」或按 key 分片）
- **预期**：每次 `put` 少一次 `get`；`maxSize=1` 部署下路由不因缓存写盘阻塞其它会话
- **代价**：锁外 I/O 需要重新设计 count 的不变量（容量上限可能被短暂突破），或改分片锁
- **验证**：`cjprof` 看 `routeByValue` 自耗时占比 + 线程状态（BLOCKED 时长）；10 万次不重复键的路由调用
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `insert ... select` 的峰值内存与源行数线性相关，1M 行时进入 GB 量级 | `fdbm/src/execute/executors.cj:830-857` | 每行实测字节数、峰值 RSS | 造 10 万/100 万行源表，记录 `getAllocatedHeapSize()` 与 RSS 峰值，中位数 5 次 |
| 2 | 逐行构造 ID 生成器在批量 INSERT 中占可观自耗时 | `fdbm/src/execute/executors.cj:898`、`fdbm/src/idmaker/IdMakers.cj:262` | `IdMakers.forTable` 的 self time 占比 | `cjprof record` 跑 1000 行/语句 uuid v1 与 snowflake，对比缓存版 |
| 3 | 分库缓存 `Mutex` 内的 `f_store` 读写在并发路由下形成串行段 | `fdbm/src/route/cache.cj:54-101` | 锁等待时长、BLOCKED 线程数 | 8 线程 × 10 万次未命中路由，采线程状态（CPU profile 看不到锁竞争） |
| 4 | `queryKeys` 的 O(n²) 去重在大范围 DELETE 上是主要 CPU 项 | `fdbm/src/execute/executors.cj:635-644` | 命中行数 k 与该方法耗时占比 | 对 1 万/10 万行 DELETE 分段计时，配合 `HashSet` 版对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fdbm/src/execute/ExecutorFeature_test.cj` | .cj | ✅ | 断言强度、夹具复用正常；`returning`/`count(*)` 用例未覆盖多行 snowflake 取号 |
| 2 | `fdbm/src/execute/cursor.cj` | .cj | ✅ | 见「一般/轻微」：`MemoryQueryResult` 关闭语义；行缓冲入优化方案 |
| 3 | `fdbm/src/execute/dispatcher.cj` | .cj | ✅ | 单入口分发，未见缺陷；`ensureKnownLogicalDatabase` 只在 catalog 存在时校验 |
| 4 | `fdbm/src/execute/executors.cj` | .cj | ✅ | 主要问题集中处：重复 ID、全量物化、丢弃生成的 ID、重复逻辑、日志放大、DDL 收尾 |
| 5 | `fdbm/src/execute/placeholder.cj` | .cj | ✅ | 仅版权头 + `package`，占位文件，无代码 |
| 6 | `fdbm/src/execute/session.cj` | .cj | ✅ | 锁内关闭旧游标（一般）、`transactionOpen` 死字段（轻微） |
| 7 | `fdbm/src/idmaker/IdMakers.cj` | .cj | ✅ | 每行新建生成器（严重）；`closeResource` 与 `closeAfterExecution` 重复 |
| 8 | `fdbm/src/idmaker/IdMakers_test.cj` | .cj | ✅ | 依赖 `/tmp` 下 17 位文件名做断言（环境相关），其余用例覆盖 D10 并发与失败收尾，质量较好 |
| 9 | `fdbm/src/idmaker/placeholder.cj` | .cj | ✅ | 占位文件，无代码 |
| 10 | `fdbm/src/main.cj` | .cj | ✅ | 入口仅两条 `catch`，返回显式退出码；无误 |
| 11 | `fdbm/src/main_test.cj` | .cj | ✅ | 只断言版本非空（测试强度） |
| 12 | `fdbm/src/resources/DatabaseResources.cj` | .cj | ✅ | 构造期失败回滚（G14）正确；`databases()/readNodes()` 返回内部数组（封装泄漏，未单列） |
| 13 | `fdbm/src/resources/DatabaseResources_test.cj` | .cj | ✅ | `fdbmCodeOf` 与其它测试同名辅助重复 |
| 14 | `fdbm/src/resources/placeholder.cj` | .cj | ✅ | 占位文件，无代码 |
| 15 | `fdbm/src/route/Route_test.cj` | .cj | ✅ | 自比较断言、`sleep` 竞态（测试强度） |
| 16 | `fdbm/src/route/algorithms.cj` | .cj | ✅ | 桶下标计算 4 份（重复逻辑）；边界（`Int64.Max/Min`、`low>high`）处理正确 |
| 17 | `fdbm/src/route/cache.cj` | .cj | ✅ | 容量计数漂移（一般）、锁内 I/O（优化方案） |
| 18 | `fdbm/src/route/global.cj` | .cj | ✅ | `tables` 仅测试引用（可见性建议） |
| 19 | `fdbm/src/route/placeholder.cj` | .cj | ✅ | 占位文件，无代码 |

合计：`.cj` 19 个 / `.md` 0 个 / 共 19 个，全部读完（与 `files/fdbm.part4.txt` 逐行一致）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：重复 ID、丢弃生成的 ID、缓存计数漂移、内存结果关闭语义；设计：`DdlExecutor` 借用 `GlobalTableRouter` 解析 DDL 目标库（能用但职责错位，未单列）；安全性：SQL 全部经 `SqlRenderer.literal` 渲染，未见拼接注入 |
| §1 死代码 | 1 | 已逐个比对：`private`（`pinTarget`、`queryKeys`、`openSegment`、`closeResource`、`hasColumn`、`isCountOnly`、`hasDerivedTable`、`keyOf`、`bucketOfString`…）均有调用者；`internal` 顶层函数（`borrow`/`dialectOf`/`joinNames`/`broadcastWrite`/`smallestName`/`allDatabases`/`int64Of`/`detailOf`/`ensurePinnedTargets`/`warnPinnedGlobalWrite`/`reasonSuffix`/`closeAfterExecution`）全部有引用；`protected` 类型成员逐个搜过，唯一无读取的是 `PinnedConnection.transactionOpen`（已报）；接口实现（`PartitionAlgorithm`/`IdGenerator`/`QueryResult`/`Resource`/`NodeAccessor` 成员）按豁免不判；对外不可达的 `public` 成员（`MemoryQueryResult.close`、`CursorSegment.statement` 等）均在类内或测试中被使用 |
| §2 重复逻辑 | 2 | 已把本部分全部函数体压成「输入→输出→副作用」两两比对；同文件内命中：`partitionCode`/`cacheCodeOf`（逐字相同）、桶下标计算 4 份；跨文件命中：逐库执行 3 份、广播+部分失败 2 份、`joinNames` 3 份、收尾工具 2 份、测试 `codeOf` 7 份 |
| §3 空实现 | 1 | 全部函数体与分支均已读；无 TODO/FIXME、无「开关打开走进空分支」；`CursorSegment.close`（`cursor.cj:42-64`）等关闭路径上的 `catch (_: Exception) {}` 属有意 no-op（关闭失败无处上报，且按序尽力而为），不判；命中项为 `MemoryQueryResult.close()` 空转 |
| §4 栈溢出 | 0 | 已核对：本部分无递归函数（`sortedNames` 插入排序、`broadcastWrite`/`executeAll` 均为迭代），无自引用结构遍历，无每帧大对象 |
| §5 OOM | 1 | 命中 `insertFromSelect` 全量物化（严重）；`queryKeys` 的全量键收集为有界于行数，已归到 §6.4；`PartitionCache` 的键数受 `capacity` 约束（但计数漂移，见一般条目） |
| §6.1 热点瓶颈 | 0 | 本轮未提供 `cjprof`/`cjpm bench` 数据，任何「热点」结论都不成立；已转成「待验证假设」4 条（生成器构造、缓存锁、queryKeys、物化峰值） |
| §6.2 大粒度锁 | 0 | `PartitionCache` 的「一把锁 + 锁内磁盘 I/O」形态成立，但缺单次持有时长与竞争线程数；按铁律未定为缺陷，写入优化方案与待验证假设第 3 行。`DbdSession.installCursor` 的锁内关闭按 §12.2 记为一般（静态可判，不需要测量） |
| §6.3 并发串行 | 0 | 本部分无 `spawn … get()`、无单消费者队列、无并发度=1 的批处理；游标多段是「按库串行打开」但不同库对应不同池，不构成串行段 |
| §6.4 低效算法 | 1 | `queryKeys` 的 `ArrayList.contains` 去重（O(k²)）；`route/router.cj` 的同款去重记为同一根因 |
| §7 降堆内存方案 | 2 | 游标行缓冲改 `Array`、缓存启动计数；两条均无基线 |
| §8 降 CPU 方案 | 2 | 生成器缓存、缓存重复 `get` + 锁内 I/O 外移；两条均无基线 |
| §9 local mode 可行性 | 0 | 本部分最大临时对象是 `insertFromSelect` 的 `rows`，它必须逃逸到后续 `executeAll`（跨函数、进 `InsertStatement` 列表），逃逸检查不通过；其余临时对象（`joinNames` 的 `StringBuilder`、`keyOf` 的字节数组）为短小单次分配，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 8 | 本部分 15 条发现全部为存量（快照模式无基线）；其中逻辑/契约/资源/错误处理类 8 条：重复 ID、`insert…select` 全量物化、丢弃已生成的 ID、缓存计数漂移、锁内关闭游标、pin 检查-然后-写入、DDL 收尾标志、内存结果关闭语义。已核对本部分全部边界/空值/错误/资源路径：`partitionRange` 的 `Int64.Max/Min` 与 `low>high`、`StepPartition` 的 `N*step` 溢出校验、`step` 的 `[1, N*step]` 边界、`MemoryQueryResult` 的行/列越界、`QueryCursor` 的段耗尽与 `closed` 状态、`DatabaseResources` 的建池失败回滚与 `closeAndAwait` 参数校验均正确 |
| §12 并发安全与锁粒度 | 2 | 已列出共享点：`DbdSession.cursor/pinned`（`Mutex` + `AtomicBool`，语义正确）、`DatabaseResources` 构造后不可变 + `AtomicBool`、`PartitionCache.count_/capacityWarned`（单锁）、`IdMaker.current`（`AtomicInt64`）、`UuidIdGenerator`（`Mutex`）。命中：锁内关闭旧游标（12.2）、pin 的检查-然后-写入（12.1，依赖上层独占，记待确认） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无对外可达的 `public` 新能力（全部为 `protected` 实现），故不存在「public API 未进 README」；README 与 `protected` 成员的错配已在其它部分报告（`transactionOpen` 等）。`insert … select`、`show tables`、`export`、DDL/事务控制均已在 dispatcher 完整接线，无空分支、无 TODO |
| 文件覆盖（§13 等） | 19/19 | `files/fdbm.part4.txt` 逐行核对，无未读文件；本部分无 `.md`，§13 不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 4 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分（执行器 / ID 生成 / 资源装配 / 路由算法）整体工程质量偏上：资源收尾几乎每条路径都有 `try/finally` + `closeAfterExecution`，错误统一走 `FdbmException(code)`，事务 pin、游标摘除、缓存关闭都有并发用例，`warn/fail` 的边界注释也写得清楚。**两个阻塞项都在「取号」与「物化」上**：

1. **每行新建 ID 生成器导致同毫秒重复 ID**（`IdMakers.cj:262` + `executors.cj:898`）——数据正确性问题，且只在多行 INSERT/`insert … select` 上偶发，建议优先修并补用例；
2. **`insert … select` 全量物化无上限**（`executors.cj:830-857`）——OOM 面，需要分批或行数上限。

其余为「一般」4 条（无列清单 INSERT 白烧一次 ID、缓存容量计数漂移、会话锁内关闭游标、pin 的检查-然后-写入）与 9 条轻微（死字段、日志放大、DDL 收尾标志、O(n²) 去重、内存结果关闭语义、两组重复逻辑、测试强度、仅测试 API）。重复逻辑集中在「逐库执行 / 广播部分失败」模板与 `codeOf` 系列测试辅助，是后续改动最可能产生行为分叉的地方，建议与上述修复同期收敛。

本部分 **存量缺陷 15 条**（严重 2 / 一般 4 / 轻微 9），是否纳入修复待用户决定；4 条优化方案与 4 条待验证假设均无基线，不进入 `tasks.md`。
