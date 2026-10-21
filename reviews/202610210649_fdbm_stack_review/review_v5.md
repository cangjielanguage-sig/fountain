# R5: fdbm 路由、执行器、游标/会话/事务与错误路径

审查时间：2026-10-21

### 审查范围

- `fdbm/src/route/router.cj`
- `fdbm/src/route/algorithms.cj`
- `fdbm/src/route/cache.cj`
- `fdbm/src/route/global.cj`
- `fdbm/src/route/placeholder.cj`
- `fdbm/src/execute/dispatcher.cj`
- `fdbm/src/execute/executors.cj`
- `fdbm/src/execute/cursor.cj`
- `fdbm/src/execute/session.cj`
- `fdbm/src/execute/placeholder.cj`
- 错误路径/游标关闭握手相关：`fdbm/src/server/handler.cj`、`fdbm/src/server/SessionRegistry.cj`、`fdbm/src/server/InFlight.cj`、`fdbm/src/resources/DatabaseResources.cj`
- 测试：`fdbm/src/route/Route_test.cj`、`fdbm/src/execute/Dispatcher_test.cj`、`fdbm/src/execute/ExecutorFeature_test.cj`、`fdbm/src/server/{Handler,Integration,Server}_test.cj`
- 参照：`fdbm/doc/详细设计.md` §5/§6.2/§8.1/§9/§10.2/§10.3/§10.4

### 功能完备性矩阵（对照设计 §6.2 / §9）

| 设计条目 | 实现 | 结论 |
| --- | --- | --- |
| Single / Multi / Broadcast / Empty / Unroutable 五种路由形态 | `router.cj:130-202` | 已实现；Scope 见 S2 |
| 等值/IN + 范围（仅 step）合并、交集、Empty | `router.cj:295-341`、`algorithms.cj:78-118` | 已实现 |
| 同分库维度 JOIN 取交集 | `router.cj:396-414` | 已实现，但"同维度"判定缺分片空间（G8） |
| 派生表沿内层计算 + 分页拒广播 | `router.cj:285-293`、`executors.cj:218-223` | 已实现 |
| 缓存命中校验物理库存在、失效重算 | `router.cj:205-232` | 已实现 |
| DELETE 三步（查键 → 删 → 失效） | `executors.cj:469-565` | 已实现（顺序严格，失败不失效：T3） |
| 全局表写广播、全部成功才算成功 | `executors.cj:152-192` | 已实现（忽略 pin：G5；计数：T6） |
| DDL 广播 + 成功/失败库清单 | `executors.cj:983-1020` | 已实现（Scope S2、pin 假成功 S4） |
| 事务 pin：begin/commit/rollback/savepoint | `executors.cj:1031-1065` | 已实现（错误清理 G7；多目标未拒绝 S1） |
| `returning` 方言判定、单目标、首行首列 | `executors.cj:751-849` | 已实现 |
| `count(*)` 逐库求和、Empty→0、pin+多库拒绝 | `executors.cj:275-348` | 已实现（广播范围 S2） |
| 多段游标、无预读、当前行缓冲、流句柄复用 | `cursor.cj:112-224` | 已实现（异常后状态 G9） |
| 游标关闭握手（drain → close → ACK，幂等） | `handler.cj:106-135`、`cursor.cj:194-206` | 已实现 |
| `show databases` 返回逻辑库清单 | `executors.cj:862-875` | ❌ 返回物理库名（G2） |
| `show tables [<logical>]` 方言分支 | `executors.cj:876-916` | ⚠ 逻辑库名不被识别（G1），错误路径泄漏（G3） |
| 错误码映射（DB_ERROR/TIMEOUT/ID_GENERATOR…） | `handler.cj:41-47`、`resources:146-162` | ⚠ TIMEOUT/ID_GENERATOR 未落地（G6） |
| 会话巡检回收断连游标/pin | `SessionRegistry.cj:112-150` | 已实现（与在途请求竞争：G11） |
| 优雅停止六步 | `FdbmServer.cj:147-166` | 已实现 |

### 发现

#### [严重] S1: 事务 pin 下多目标路由未拒绝，同一 SQL 在同一个 pin 连接上重复执行

- **位置**：`fdbm/src/execute/executors.cj:429-441`（UPDATE）、`:493-504`（DELETE）、`:523-524`（DELETE 查键）、`:228-231`（SELECT 多段）
- **描述**：`borrow()`（`:68-80`）在 `session.pinned.isSome()` 时无条件返回 pin 连接并标记 `owns=false`。于是 `plan.kind == Multi`（IN 列表 / step 范围命中多片）或 `Unroutable` 的 SELECT 广播时，循环里每个"物理库"实际拿到的都是同一个 pin 连接：
  - UPDATE/DELETE：同一条 SQL 在**同一物理库**上执行 N 次，`rowCount` 被累加 N 倍；其余分片的数据根本没有被修改，客户端却收到成功；
  - SELECT：同一结果集被打开 N 次（部分驱动会直接报"结果集独占"），或同一批行重复返回 N 遍；
  - 设计只对 `count(*)` 和 `returning` 显式拒绝（`executors.cj:285-289`、`:779-782`），说明作者已知 pin 只对应一个物理库，但 UPDATE/DELETE/SELECT 漏了同样的守卫。
- **建议**：在执行器入口统一检查 `session.pinned.isSome() && plan.databases.size > 1` → `ROUTE_FAILED`（文案说明事务内只能命中一个物理库）；或把该判定下沉到 `borrow()`/路由层，避免四个执行器各写一遍。

#### [严重] S2: Unroutable/广播回退到"全部物理库"，跨逻辑库查询、计数与 DDL

- **位置**：`fdbm/src/execute/executors.cj:260-272`（`targetDatabases` 的 `Unroutable` 分支返回 `allDatabases(resources)`）、`:280`（count 复用同一分支）、`:154`（`broadcastWrite` 的 `targets` 回退）、`:985`（DDL 的 `databases` 回退）
- **描述**：设计 §6.2/§9.2 要求 `Unroutable` 的 SELECT 与 DDL/全局表写只在**该逻辑库包含的物理库**内广播；实现直接取 `NodeAccessor.databases()`（部署内全部物理库）。多逻辑库部署下，逻辑库 A 的无分库条件查询会读到逻辑库 B 的物理库，`count(*)` 把 B 的数据一起求和，DDL/全局表写会改到 B 的表。这是可见的错误结果与越界写入。`emptyOutcome`（`:363-373`）取 `allDatabases(resources)[0]` 取列信息，也有同样的 scope 问题。
- **建议**：统一经 `GlobalTableRouter.physicalDatabases(logicalOf(statement, session.database))` 求目标库，取不到时报 `ROUTE_FAILED`；只有确知"未配置逻辑库映射（等于全部物理库）"时才允许回退，且回退后仍应记录一次性 WARN。

#### [严重] S3: 会话默认库取到物理库名，未限定表名匹配不到分库/全局表规则

- **位置**：`fdbm/src/config/settings.cj:109-117`（`defaultDatabaseOf` 依赖 `logicals.size == 1`）+ `fdbm/src/config/FdbmConfig.cj:519-530`（把每个物理库名也注册为逻辑库键，且顺序来自 `HashSet` 迭代）
- **描述**：配置 `fdbm_db_logicalDatabase_app=db0,db1` 时，`logicalDatabases()` 会额外加入 `db0`、`db1` 两个"逻辑库"（映射到全部物理库），`logicals.size` 变成 3，`defaultDatabaseOf` 的"只有一个逻辑库时取它"分支永远不命中，会话默认库落到物理名 `db0`。随后 `PartitionRouter.route`（`router.cj:135-151`）用 `db0` 当作逻辑库去查 `fdbm_partition__t='app,step,id'`，key `db0.t` 不命中 ⇒ 分片表被当成"未分库表"，返回 `Single(physicals[0])`；而 `logicals['db0']` 的数组由 `HashSet` 迭代构造，`physicals[0]` 在进程间不确定。结果：未限定表名的 SELECT/INSERT/UPDATE 只在某一个分片上读写（写入位置不确定、读取结果缺片），全局表也不会被识别为全局。测试全部使用"逻辑库名 == 物理库名"（如 `db0`），因此没有暴露。
- **建议**：区分"已配置的逻辑库"与"用于查找的全量回退项"（例如单独保存 `configuredLogicals`，或在 `defaultDatabaseOf` 里用配置来源判断是否显式配置了单个逻辑库）；默认库必须能稳定映射到该逻辑库的物理库集合，且集合顺序按节点/配置顺序（不要用 `HashSet` 迭代）。

#### [严重] S4: DDL 在事务 pin 下对同一连接重复执行并逐库报成功

- **位置**：`fdbm/src/execute/executors.cj:990-1013`（`borrow` 在 `:994`）
- **描述**：DDL 广播循环对 `databases` 中每个物理库调用 `borrow`，pin 时全部返回同一个 pin 连接：`create table` 第一次成功、第二次通常报"表已存在"，于是把第二个库记为 failed 并抛 `DB_ERROR`（假失败）；`alter table` 之类幂等语句则会在同一库重复执行，并把**所有**库名加入 `succeeded`（假成功），真正的其它物理库从未收到 DDL。
- **建议**：与 S1 同一守卫：pin 下若目标库多于一个直接 `ROUTE_FAILED`；或明确 DDL 不使用 pin（`selectAllWrite`）并在文档中写明"DDL 不参与会话事务"。

#### [一般] G1: `show tables` 把逻辑库名当物理库校验，限定逻辑库时必然失败

- **位置**：`fdbm/src/execute/executors.cj:876-885`
- **描述**：`database = statement.database ?? session.database` 后直接 `resources.contains(database)` 并 `resources.driver(database)`，两者都只认物理库名。设计 §8.1/§9.5 明确写成 `SHOW TABLES [<logical>]`，因此 `show tables app` 在正常部署（逻辑名 `app` ≠ 物理名 `db0`）下会返回 `ROUTE_FAILED('unknown database app')`。
- **建议**：先把入参解析为逻辑库 → 取该逻辑库第一个物理库（或读节点）再取方言/执行；解析不到逻辑库时再按物理库名兜底。

#### [一般] G2: `show databases` 返回物理库名，与设计"逻辑库清单"不符

- **位置**：`fdbm/src/execute/executors.cj:862-875`（`sortedNames(resources.databases())`）
- **描述**：设计 §8.1（`详细设计.md:570`）与 §9.5 要求返回逻辑库名；实现返回 `NodeAccessor.databases()`（物理库）。`Dispatcher_test.cj:343-359` 也按物理名断言，说明测试固化了错误语义。
- **建议**：改为 `settings.logicalDatabases` 的键集合（或经 `GlobalTableRouter` 暴露逻辑库清单），并同步修正用例。

#### [一般] G3: `show tables` 失败路径泄漏语句与连接

- **位置**：`fdbm/src/execute/executors.cj:886-891`
- **描述**：`selectRead` → `prepareStatement` → `query()` 之间没有 `try/finally`；`prepareStatement` 或 `query()` 抛异常时连接不会归还（`Connection` 只在 `CursorSegment.close()` 里关闭）。默认池 `maxSize=1`，一次失败即可把该物理库的连接永久占住，后续请求全部超时。
- **建议**：按 `openSegment`（`:375-396`）的写法包 `try/catch`，异常时依次关闭 `prepared` 与 `connection`；或复用 `openSegment`。

#### [一般] G4: 多行 INSERT 未"同一事务内"执行，部分成功不回滚

- **位置**：`fdbm/src/execute/executors.cj:597-614`、`:663-668`（insert…select 逐行）、`:787-800`
- **描述**：设计 §9.2 明确"`values` 多行按行分组路由（逐行执行、**同一事务内**）"；实现每行都独立 `borrow` + `executeUpdate`，非 pin 时等价于逐条自动提交。第 3 行失败时前 2 行已落库，客户端只看到 `ERROR`，与"同一事务"承诺不符（同分片内本可用一次 `begin/commit` 包住）。
- **建议**：对同一物理库的多行使用一个事务（`begin` → 逐行 → `commit`，异常 `rollback`）；跨物理库的行保留"已执行分片不回滚"的限制，并在错误信息中体现。

#### [一般] G5: 全局表写广播绕过会话事务（pin 被静默忽略）

- **位置**：`fdbm/src/execute/executors.cj:152-192`（`broadcastWrite` 用 `selectAllWrite`）、`:413-416`、`:471-474`、`:767-771`
- **描述**：`begin` 之后对全局表做 INSERT/UPDATE/DELETE，写操作走独立连接并各自提交，`rollback` 无法撤销；客户端却认为这些写属于当前事务。设计 §9.3 要求"随后所有语句（含 SELECT）都走该连接"，§9.4 只说明"每库独立事务"，两者在全局表 + pin 的组合下冲突且实现选择了静默绕过。
- **建议**：pin 下对全局表写直接 `ROUTE_FAILED`/`UNSUPPORTED_SQL`（明确"全局表写不支持事务"），或写入时使用 pin 连接并只广播到 pin 所在库；至少在文档与错误信息中显式声明。

#### [一般] G6: 错误码映射缺口：连接池失败与 ID 生成异常落到 INTERNAL

- **位置**：`fdbm/src/resources/DatabaseResources.cj:146-162`（`selectRead`/`selectWrite` 未捕获 `ConnectionException`）、`fdbm/src/server/handler.cj:45-47`（兜底 `INTERNAL`）、`fdbm/src/execute/executors.cj:743-749`（`idLiteral` 直接调用生成器）
- **描述**：设计 §5 规定"池耗尽等待超时同样表现为 `ConnectionException`（映射 `TIMEOUT`）"，实现中 `fdbm/src` 完全没有 `ConnectionException` 与 `TIMEOUT` 的引用：不可达库/池耗尽/取连接超时都会冒泡到 handler 的通用 `catch (e: Exception)`，回 `INTERNAL`。同理自定义 `IdGenerator` 抛出的 `IdGeneratorException`（f_dbm 接口默认实现）在 `nextIntId/nextStringId` 处未包装，回 `INTERNAL` 而不是 `ID_GENERATOR`；`CACHE`/`IO` 两个错误码在本模块无任何落点。
- **建议**：在 `DatabaseResources.select*`/`selectAllWrite` 捕获 `ConnectionException` 并转 `FdbmException(TIMEOUT, ..., caused)`；在 `idLiteral`（或 `IdMakers`）捕获 `IdGeneratorException` 转 `ID_GENERATOR`；补一条用例断言不可达库/池耗尽/生成器失败的错误码。

#### [一般] G7: `begin` 失败或 `commit/rollback` 归还失败后 pin 状态未清理

- **位置**：`fdbm/src/execute/executors.cj:1033-1042`（begin）、`:1043-1055`（commit/rollback）
- **描述**：`begin` 先 `session.pinned = Some(pinned)` 再执行 `begin`，若物理库返回错误（如连接已坏、权限不足），异常直接上抛，`pinned` 留在会话上且 `transactionOpen=true`，后续语句会继续复用这条连接，直到会话断开；`commit/rollback` 的 `finally` 里先 `pinned.close()` 再 `session.pinned = None`，`close()` 若抛出（`PinnedConnection.close` 已吞异常，但换成别的实现或未来改动时）`pinned = None` 会被跳过，会话永久卡在"已 pin"状态。
- **建议**：`begin` 失败时 `pinned.close()` 并清空 `pinned`；`commit/rollback` 先清 `session.pinned`，再在 `try/catch` 中归还，返回值与清理互不阻塞。

#### [一般] G8: "同分库维度"判定未比较分片空间，跨逻辑库 JOIN 误判为 Empty

- **位置**：`fdbm/src/route/router.cj:396-404`
- **描述**：`allSameDimension` 只比较 `rule.column` 与 `rule.algorithm.name`。两个不同逻辑库（分片数不同）但同列、同算法的表会被当成同一维度，随后直接取库名交集（`:189-201`）。物理库名不同时交集为空 → 返回 `Empty`（0 行），而设计 §6.2 要求"不同维度…要求各表收敛到同一个物理库，否则 `Unroutable`（错误信息给出两张表的库名）"。用户看到的是"查询成功但无数据"，不是错误。
- **建议**：维度判定加入分片空间（算法内部的 `databases` 集合或 `(logical, 表的分片库列表)`）；不同逻辑库的表直接 `Unroutable`。

#### [一般] G9: `QueryCursor.next()` 抛异常后行缓冲与 `rowValid` 未复位

- **位置**：`fdbm/src/execute/cursor.cj:126-138`
- **描述**：`segment.result.next()` 抛异常时，`rowValid` 仍是上一行的 `true`，`cells`/`streams` 也保留上一行内容。客户端收到 `NEXT_ROW` 的 `ERROR` 后再读列，会拿到**上一行**的缓存值（`cell()` 只在 `rowValid` 为 false 时才拒绝），造成静默串行数据。
- **建议**：`next()` 中用 `try/catch` 包住物理推进，异常时 `clearRow()` 并重新抛出（或把游标置为错误态，后续 `cell()` 一律 `CURSOR_STATE`）。

#### [一般] G10: 自定义分区算法可覆盖内置实现（与设计 §10.5 相反且未校验）

- **位置**：`fdbm/src/route/algorithms.cj:288-293`（"先查自定义（同名可覆盖内置）"）、`fdbm/src/config/FdbmConfig.cj:423-428`（自定义名只做并集，未拒绝与内置重名）
- **描述**：设计 §10.5 要求"与内置重名由 `FdbmConfig.validate` 拒绝，不允许覆盖内置实现"。实现中 `validate` 只把自定义名加入 `known`，`PartitionAlgorithmFactory` 又以自定义优先，因此一个叫 `step` 的自定义扩展会静默接管全部分片路由，且无启动报错。`IdGenerator` 一侧同理（`:489` 只判断 `contains`）。
- **建议**：`validate` 中显式拒绝 `customAlgorithms ∩ BUILTIN_ALGORITHMS` 与 `customIdGenerators ∩ {uuid,snowflake,sequence}`，抛 `PARTITION_CONFIG`/`CONFIG`；工厂注释改为"内置优先/重名已拒绝"。

#### [一般] G11: 会话巡检与在途请求并发关闭同一会话

- **位置**：`fdbm/src/server/SessionRegistry.cj:112-141`（`sweep`）
- **描述**：`sweep()` 在定时线程里发现 `buffer.isClosed()` 就把会话移出并 `session.close()`（关游标、归还 pin 连接），此时 handler 线程可能仍在同一会话上执行语句/读游标（`Server` 的读循环与执行器不在同一线程）。结果是连接在查询进行中被归还或关闭，可能出现"归还后又 close"、结果集被并发关闭。
- **建议**：为会话加引用计数（`InFlight` 级别或 `DbdSession.retain/release`），巡检只标记并在计数归零后回收；或在会话上加锁，`close()` 与请求执行互斥。

#### [轻微] T1: Multi 路由的库顺序不是逻辑库配置顺序

- **位置**：`fdbm/src/route/router.cj:189-201`、`:320-340`
- **描述**：`mapped`/`intersection` 的顺序来自等值字面量出现顺序（`IN (1500, 5)` → `[db1, db0]`），设计 §6.2 要求"Multi 按逻辑库配置的物理库顺序"。多段游标的行序因此依赖 SQL 写法，同一查询不同参数顺序会得到不同行序。
- **建议**：按逻辑库的物理库列表对结果排序后再返回。

#### [轻微] T2: `PartitionRouter` 构造参数 `custom` 未使用

- **位置**：`fdbm/src/route/router.cj:111-113`
- **描述**：`custom` 传入后从未读取（自定义算法已由 `PartitionAlgorithmFactory` 在构造规则时解析），属于遗留死参数，容易让调用方误以为路由器还要做自定义分派。
- **建议**：删除该参数（连同 `FdbmServer.cj:86-87` 的实参），或在文档里注明保留原因。

#### [轻微] T3: DELETE 删除阶段失败时不失效缓存

- **位置**：`fdbm/src/execute/executors.cj:505-511`
- **描述**：三步顺序中第三步（`invalidate`）在删除循环之后顺序执行，任一分片删除抛异常时整条语句直接上抛，前面已删除分片对应的键不会失效。设计把失效列为第三步，但未要求"失败也执行"。
- **建议**：把失效放进 `finally`（或先记录 `plan.databases` 内已成功删除的库再统一失效），避免部分删除后缓存与数据不一致。

#### [轻微] T4: `PartitionCache` 吞掉关闭异常，读取未做字节校验

- **位置**：`fdbm/src/route/cache.cj:110-114`（`close` 内 `catch (_: Exception) { () }`）、`:57`（`String.fromUtf8(bytes)`）
- **描述**：`Store.close()` 失败被完全吞掉（设计 §10.4 要求 `syncWAL` 后关闭，失败应至少记 WARN）；`get` 未校验缓存值的编码，缓存文件被外部破坏/版本不一致时异常会冒泡成 `INTERNAL`，而 `DbdErrorCode.CACHE` 在模块内无任何使用。
- **建议**：`close` 失败记 WARN；`get` 捕获解码异常并按"未命中"处理（同时 `remove` 脏键）。

#### [轻微] T5: `murmur` 分区用 `UInt128.hashCode()` 而非设计规定的低 64 位

- **位置**：`fdbm/src/route/algorithms.cj:225`、`:282`
- **描述**：设计 §6.1 写"`murmurHash` 取低 64 位后取模"，实现取 `UInt128.hashCode()` 再做有符号取模。当前版本内结果稳定，但 `hashCode` 的具体实现不属于稳定契约，跨语言/跨版本升级可能导致同一键落到不同分片。
- **建议**：显式取低 64 位（如 `UInt64(hash & 0xFFFF_FFFF_FFFF_FFFF)`）后再取模。

#### [轻微] T6: `broadcastWrite` 对同一物理库的多个写节点重复累加 `rowCount`

- **位置**：`fdbm/src/execute/executors.cj:160-168`
- **描述**：`selectAllWrite(database)` 返回该物理库**全部写节点**（负载均衡的等价副本），循环对每个节点执行同一条 INSERT/UPDATE 并把 `rowCount`/`lastInsertId` 覆盖累加。客户端看到 `rowCount = 节点数`，`lastInsertId` 只保留最后一个节点的值。
- **建议**：明确"广播写只写一个节点"（`selectWrite`）或"每库只统计一次"，并在注释中说明多写节点的语义。

#### [轻微] T7: 目标库为空时返回"无列空游标"而非报错

- **位置**：`fdbm/src/execute/executors.cj:215-217`
- **描述**：`Unroutable` 且 `resources.databases()` 为空时返回 `QueryCursor([], [])`，客户端收到 0 列的 `QueryResultServerPayload`，表现为"查询成功但没有列"，与"路由失败"难以区分。
- **建议**：抛 `ROUTE_FAILED('no physical database is configured')`。

#### [轻微] T8: 无列清单的 INSERT 会消耗一个 ID 后被丢弃

- **位置**：`fdbm/src/execute/executors.cj:709-731`
- **描述**：解析器接受 `insert into t values (…)`（无列清单）。`fillAndRoute` 判定"缺分库列"后创建生成器与 `literal`，但后续只有 `!columns.isEmpty()` 或 `hasPairs` 两个分支会追加，两者都为空时生成值被丢弃；随后路由得到 `Unroutable`，抛 `ROUTE_FAILED('insert cannot determine a target database')`。`sequence` 生成器会白耗一个号，错误文案也没有指出"需要列清单"。
- **建议**：在 `fillAndRoute` 开头对"无列清单且无 SET"的 INSERT 直接抛 `UNSUPPORTED_SQL('insert requires an explicit column list')`（在设计 §8.1 已限定该形态），避免先取号再失败。

#### [轻微] T9: `route/placeholder.cj`、`execute/placeholder.cj` 为空文件

- **位置**：`fdbm/src/route/placeholder.cj:16`、`fdbm/src/execute/placeholder.cj:16`
- **描述**：两个文件除 license 头与 `package` 声明外无任何声明（判定依据：文件仅 16 行，第 16 行为 `package …`，其后无内容）。不属于"空实现函数"，但作为占位文件无编译产物，易被误读为遗漏实现。
- **建议**：删除，或在文件头注明"目录占位，无声明"。

#### [轻微] T10: DELETE 查键一次性载入全部键并使用读连接

- **位置**：`fdbm/src/execute/executors.cj:516-565`（`:524` 用 `write: false`、`:532-541` 全量 `keys.add`）
- **描述**：大表 DELETE 会把所有受影响分库键读入内存（无上限）；查键走读连接而删除走写连接，读写分离下读副本滞后会漏键（当前缓存键是确定映射，影响有限，但语义上不一致）。
- **建议**：查键与删除使用同一写连接/同一 pin；对键数量设上限或分批处理。

### 测试覆盖

用例规模：`Route_test.cj` 22 个用例 / 75 断言；`Dispatcher_test.cj` 26 / 69；`ExecutorFeature_test.cj` 16 / 46；`Handler_test.cj` 11 / 28；`Integration_test.cj` 5 / 21；`Server_test.cj` 11。未发现空用例、无断言用例、`@Ignore`/禁用用例。

已覆盖：路由（等值/IN/step 范围/Empty/派生表/全局表/缓存/算法边界）、执行器（select/update/insert/delete/count/returning/show/export/ddl/全局表部分失败）、协议（首包/逐行/列读/UNSUBSCRIBE 幂等/qid 不匹配/新语句关旧游标）、会话（pin 单库、巡检回收、InFlight）。

缺口（与上文问题对应）：

| 缺口 | 对应用例缺失 |
| --- | --- |
| 事务 pin + Multi/Unroutable 的 UPDATE/DELETE/SELECT | S1 无用例；现有 `countMultiShardInsideTransactionIsRejected` 只覆盖 count |
| `Unroutable` SELECT / count 的广播范围（多逻辑库） | S2 无用例；现有广播用例的逻辑库与物理库同集合 |
| 逻辑名 ≠ 物理名的部署（默认会话库、路由、show） | S3/G1/G2 无用例；所有用例都用 `db0` 作为逻辑名与物理名 |
| DDL + pin、DDL 全成功路径 | S4；现有仅 `ddlPartialFailureListsDatabases` |
| 不可达库/池耗尽/取连接超时、IdGenerator 抛异常的错误码 | G6 无用例 |
| `show tables` 查询失败后的资源归还 | G3 无用例 |
| 多行 INSERT 中途失败的回滚 | G4 无用例 |
| 不同分片空间 JOIN → `Unroutable` | G8；现有 `sameDimensionJoinIntersects` 仅同维度 |
| cursor：跨段 NEXT_ROW、`next()` 异常后列读、`drain()` 中途异常、未 `NEXT_ROW` 直接读列 | G9 及 cursor 单元用例整体缺失（仅经 handler 间接覆盖） |
| `begin` 失败、`commit` 归还失败后的会话状态 | G7 无用例 |
| 巡检与在途请求并发 | G11 无用例（`sweepReclaimsDisconnectedSession` 无并发请求） |

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 4 |
| 一般 | 11 |
| 轻微 | 10 |

### 总评

路由与执行器的主干（五形态路由、单/多段游标、无预读与行缓冲、DELETE 三步、returning/count/派生表分页的错误码落点、DDL 部分失败报告、优雅停止）与设计 §9 基本对齐，代码结构清晰，`try/finally` 覆盖率总体较好，游标关闭握手与幂等 ACK 的实现与 f_dbd 契约一致，测试对公开行为的覆盖也较扎实。

但事务边界是最薄弱的一环：pin 只对应一个物理库这一前提只在 `count(*)`/`returning` 上被校验，UPDATE/DELETE/SELECT 与 DDL 在 `Multi`/广播时会静默地在同一个连接上重复执行，产生"部分分片未改却报成功"和"重复计数"；同时"Unroutable 广播"回退到部署内全部物理库，而不是逻辑库的物理库，在多逻辑库部署下越界读写。另一个系统性问题是逻辑库名与物理库名混用：默认会话库在显式配置逻辑库时实际取到物理名，导致未限定表名的分片表被当成未分库表路由（现有测试因逻辑名等于物理名而全部通过），建议优先修复默认库解析并补一条"逻辑名 ≠ 物理名"的端到端用例。错误码映射（TIMEOUT/ID_GENERATOR）与 `show databases`/`show tables` 的语义偏差属于文档承诺未落地，修复成本低。
