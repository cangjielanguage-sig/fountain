# R3: fdbm 文档、配置、资源、服务器生命周期、缓存、ID 生成

审查时间：2026-10-21

### 审查范围

工作树：`.worktrees/review_fdbm_stack_202610210649`（基线 `7ca82fcc`，只读）

**文档/构建/部署（对照基线）**

- `fdbm/README.md`、`fdbm/README_en.md`
- `fdbm/doc/详细设计.md`、`fdbm/doc/开发计划.md`、`fdbm/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/fdbm/spec.md`
- `fdbm/cjpm.toml`、`fdbm/boot.sh`

**源码（R3 范围）**

- `fdbm/src/main.cj`、`fdbm/src/main_test.cj`
- `fdbm/src/config/{FdbmConfig.cj,FdbmConfig_test.cj,models.cj,settings.cj,source.cj,BootScriptWriter.cj,BootScriptWriter_test.cj}`
- `fdbm/src/exception/{FdbmException.cj,FdbmException_test.cj}`
- `fdbm/src/resources/{DatabaseResources.cj,DatabaseResources_test.cj,placeholder.cj}`
- `fdbm/src/route/cache.cj`（仅缓存，路由算法/规则留给 R4）、`fdbm/src/route/global.cj`（仅逻辑库→物理库查询）
- `fdbm/src/idmaker/{IdMakers.cj,IdMakers_test.cj,placeholder.cj}`
- `fdbm/src/server/{FdbmServer.cj,handler.cj,SessionRegistry.cj,InFlight.cj,DriverLoader.cj,CustomLoader.cj,context.cj,Server_test.cj,Handler_test.cj,Integration_test.cj}`
- `fdbm/src/execute/session.cj`（仅会话/游标释放路径，用于校验 §10.4 关停顺序）
- `fdbm/test/lifecycle_test.sh`、`fdbm/test/e2e/lib.sh`、`fdbm/test/e2e/backends/*.sh`（部署/启动配置证据）

**引用但不重复审查**：`fdbm/src/sql/*`、`fdbm/src/route/{algorithms.cj,router.cj}`、`fdbm/src/execute/{cursor.cj,executors.cj,dispatcher.cj}` 仅在核对文档承诺时读取，具体问题留给 R4/R5（涉及 SHOW/EXPORT 一致性的用例除外）。

### 发现

#### [严重] 逻辑库集合被自动填入物理库名，导致会话默认库错位、分库规则整体失效

- **位置**：`fdbm/src/config/FdbmConfig.cj:519-529`、`fdbm/src/config/settings.cj:109-117`
- **描述**：
  `logicalDatabases()` 在读完 `fdbm_db_logicalDatabase_<logical>` 后，额外把**每一个物理库名**也注册成一个逻辑库（`if (!logicals.contains(database)) logicals[database] = all`）。于是：

  1. 只要配置了 `fdbm_db_logicalDatabase_order='db_0,db_1,db_2,db_3'`（设计 §10.6 与随包 `boot.sh:50` 的示例），`logicals` 就至少有 4 个 key（`order` + `db_0..db_3`），`logicals.size == 1` 永不成立；
  2. `defaultDatabaseOf` 走 `nodes[0].databases[0]`，会话当前库变成**物理库名** `db_0`；
  3. 路由器按 `(currentDatabase, table)` 查规则（`route/router.cj:143`），`('db_0','orders')` 查不到 `('order','orders')`，于是该表被当成"未分库表"，`PartitionRouter.route` 走 `Single(physicals[0])`（`route/router.cj:166-172`）；
  4. 结果：所有不带 `order.` 限定的读写全部静默落到 `db_0`，水平分库完全失效，且**没有任何错误或日志**。

  证据：`fdbm/test/e2e/backends/mysql.sh:92` 把逻辑库名故意取成物理库名 `db0`（`fdbm_db_logicalDatabase_db0=$DB_LIST`），`fdbm_db_database_name0=db0,db1,db2,db3`，从而让 `defaultDatabase == 'db0'` 与规则 `fdbm_partition__t_step="db0,step,id"` 恰好对上；`Integration_test.cj:221-242` 也只有物理库名、没有逻辑库映射。两套测试都因此绕开了该缺陷。

  连带现象（同一根因，独立修复点见下一条）：`SHOW DATABASES` 永远看不到 `order`；`show tables`（无参，取 `session.database='db_0'`）反而可用，但 `show tables order` 报 `ROUTE_FAILED`。

- **建议**：
  1. `logicalDatabases()` 只登记显式配置的 `fdbm_db_logicalDatabase_*`；需要"物理库也是一个可访问库"时，在 `show databases`/路由回退处做**显式**的物理→逻辑映射，而不是污染逻辑库表；
  2. `defaultDatabaseOf` 改为"显式逻辑库唯一 → 取它；否则取该逻辑库映射的第一个物理库/第一个节点的第一个物理库"；
  3. 补一条"逻辑库名 ≠ 任何物理库名"的集成用例：配置 `order→db_0,db_1` + `fdbm_partition__orders='order,step,id'`，断言 `insert ... (id=1500)` 落到 `db_1`、会话默认库为 `order`。

#### [严重] `UuidIdGenerator` 的 v1/v6 时间戳恒为 0，且每生成一个 ID 新建一个临时目录与文件

- **位置**：`fdbm/src/idmaker/IdMakers.cj:46-53`
- **描述**：
  ```cangjie
  case 6 => UUID.timeBased().randomNode().toString()
  case _ => UUID.timeBased(timeLowFirst: true).registerFileSequenceGenerator().randomNode().toString()
  ```
  `f_util` 的 `TimeBasedUUIDBuilder` 只有 `randomSeq`/`serialSeq` 两个属性会调用 `genTimestampAndSequence`（`f_util/src/uuid.cj:477-501`），而 `randomNode()`/`node()`/`generate()` 直接使用 `timestamp`、`seq` 字段（`uuid.cj:585-600`）。本实现从未触发时间戳/序列生成，因此 v1/v6 的 `time_low/time_mid/time_hi` 与 clock_seq **恒为 0**，UUID 之间只靠 6 字节随机 node 区分——v1/v6 的时间有序语义完全丢失（设计 §7 明确要求 v6 用 `UUID.timeBased()`）。

  另外 `registerFileSequenceGenerator()` 每次调用都会 `Directory.createTemp('/tmp')` + 建文件（`f_util/src/uuid.cj:650-655`），而本路径生成的 builder 用完即弃，只靠 `TimestampSequenceBuilder` 的 `~init()` 在 GC 时关文件、临时目录永不删除。设计默认 `fdbm_idmaker=uuid,1`（`详细设计.md:107`），即"INSERT 缺分库列值"这条高频路径每生成一个 ID 就在 `/tmp` 留一个目录与文件，长时间运行会耗尽 inode。
- **建议**：
  1. 改用 `UUID.timeBased(...).serialSeq.randomNode()`（或 `randomSeq`），让时间戳与 clock_seq 真正填充；
  2. 复用**单实例** builder（`UuidIdGenerator` 持有一个 `TimeBasedUUIDBuilder`，`nextStringId` 复用），不要每个 ID 都新建；若必须用文件序列生成器，则在 `UuidIdGenerator` 生命周期内持有并 `close()`；
  3. 补 v1/v6/v7 的用例：解析后断言 `version` 与 `time` 非 0、跨 1000 次单调。

#### [一般] `SHOW DATABASES` / `SHOW TABLES` 只认物理库名，与「列出逻辑库」的文档承诺不符

- **位置**：`fdbm/src/execute/executors.cj:860-892`（`Databases` 分支取 `resources.databases()`；`Tables` 分支用 `resources.contains(database)` 校验）
- **描述**：设计 §8.1 要求 `SHOW DATABASES` 列出**全部逻辑库名**、§9.5 要求返回"`fdbm_db_logicalDatabase_*` 与节点配置推导出的逻辑库集合"。`ShowExecutor` 只持有 `NodeAccessor`（物理库视图），拿不到 `FdbmSettings.logicalDatabases`；`SHOW TABLES <logical>` 用 `contains()` 判定，逻辑库名会被判为"unknown database"并回 `ROUTE_FAILED`。此前 e2e/集成用例的库名恰好同形，掩盖了该问题。
- **建议**：把逻辑库视图（`logicalDatabases` 的 key 集合 + `logical → physical`）注入 `ShowExecutor`：`Databases` 输出逻辑库名（排序）；`Tables` 先把逻辑库名解析为首个物理库再校验/下推，逻辑库不存在时才报错。执行器内部实现细节由 R4/R5 复核。

#### [一般] 未配置的逻辑库未按设计「隐式包含全部物理库」展开，分区规则在启动自检被拒

- **位置**：`fdbm/src/config/FdbmConfig.cj:506-531`、`fdbm/src/config/FdbmConfig.cj:434-437`
- **描述**：设计 §3.1 规定"未配置的逻辑库视为包含全部物理库"。实现只把**物理库名**补成逻辑库，任意逻辑名（如 `order`）若没有对应的 `fdbm_db_logicalDatabase_order`，就不会出现在 `logicals` 里，于是 `validatePartitions` 的 `if (!logicals.contains(rule.database))` 直接抛 `PARTITION_CONFIG`，进程起不来。也就是说"只写一条 `fdbm_partition__orders='order,hash,id'`"这种符合文档的最简配置无法启动。
- **建议**：在 `logicalDatabases()` 中为分区/全局表引用到、但未显式配置的逻辑库补一条"全部物理库"的映射（顺序按节点×库配置顺序），再交给 `validate` 做引用完整性检查；补一条"分区规则引用未显式配置的逻辑库可正常启动"的正向用例。

#### [一般] 自定义扩展与内置名称重名未被启动自检拒绝，可静默覆盖内置实现

- **位置**：`fdbm/src/config/FdbmConfig.cj:420-454`（`validatePartitions`）、`fdbm/src/config/FdbmConfig.cj:456-493`（`validateIdMaker`）、`fdbm/src/server/CustomLoader.cj:92-114`
- **描述**：`CustomLoader` 只拒绝"自定义之间"重名；`validate` 把内置名与自定义名合成一个 `known` 集合，只校验"配置里引用的名字是否在集合中"，**从不检查自定义名是否与内置名相同**。而 `PartitionAlgorithmFactory` 先查自定义（`详细设计.md:419`），`IdMakers.forTable` 也先查 `custom.get(config.kind)`（`IdMakers.cj:184-186`），因此一个名为 `hash`/`uuid` 的扩展库会**静默替换**内置实现。设计 §10.5/§11 明确"不允许覆盖内置实现，启动失败"。
- **建议**：在 `validate` 开头加两条显式检查：`customAlgorithms ∩ BUILTIN_ALGORITHMS → PARTITION_CONFIG`、`customIdGenerators ∩ {uuid,snowflake,sequence} → CONFIG`；补负例用例（自定义名 `hash` / `uuid`）。

#### [一般] `fdbm_global__<table>` 的逻辑库未做启动校验，错误推迟到运行期

- **位置**：`fdbm/src/config/FdbmConfig.cj:201-218`、`fdbm/src/config/FdbmConfig.cj:345-379`（`validate` 未涉及 `confs.globalTables`）、`fdbm/src/route/global.cj:59-64`
- **描述**：`validate` 只校验 `confs.partitions` 的逻辑库引用，全局表配了不存在的逻辑库（`fdbm_global__dict='cfg'` 而 `cfg` 既不是逻辑库也不是物理库）时启动照常成功；运行期 `GlobalTableRouter.physicalDatabases('cfg')` 返回空数组，路由退化为 `Unroutable`/空广播，客户端只看到 `ROUTE_FAILED`。设计 §11 的"引用完整性"应覆盖这一类。
- **建议**：`validate` 增加对 `confs.globalTables` 的校验：`rule.database` 必须存在于 `logicals`（或按上一条的隐式展开规则补齐），错误码 `CONFIG`（或与分区一致的 `PARTITION_CONFIG`，需在文档中钉死）。

#### [一般] `sequence` 启动自检缺少 `fountain_sequence` 表存在性检查

- **位置**：`fdbm/src/config/FdbmConfig.cj:479-484`
- **描述**：设计 §11 与 spec「启动自检失败即结束进程」要求"`fdbm_idmaker=sequence` 但分配库中不存在 `fountain_sequence` 表 → `ID_GENERATOR`，退出码非 0"。实现只校验 `sequenceDatabase` 是已知物理库（不存在时也报 `ID_GENERATOR`，但语义不同），表缺失要等第一条缺分库列值的 INSERT 才在 `readSequence` 抛出。开发计划"阶段 6"也要求该负例。
- **建议**：在 `FdbmServer` 构造期（驱动/资源就绪后、监听前）对分配库执行一次 `select 1 from fountain_sequence where 1=0`（或 `information_schema` 探测），失败即 `FdbmException(ID_GENERATOR)`；补启动负例用例（可用 f_mockdb 断言探测 SQL 被下发）。

#### [一般] `fdbm_sequenceDatabase` 的「逻辑库 vs 物理库」口径自相矛盾

- **位置**：`fdbm/src/config/FdbmConfig.cj:325-337`、`fdbm/src/config/FdbmConfig.cj:479-484`；（文档侧）`fdbm/doc/详细设计.md:119`、`fdbm/doc/详细设计.md:1089`、`fdbm/boot.sh:80`
- **描述**：文档 §3.1 说默认值是"逻辑库的第一个物理库"，§10.6 的 `boot.sh` 示例直接写 `export fdbm_sequenceDatabase='order'`（逻辑库名）；实现 `getSequenceDatabase` 默认取 `nodes[0].databases[0]`（第一个节点的第一个物理库，可能与目标逻辑库的物理库集合不相交），`validateIdMaker` 又要求该值**必须是物理库名**（`databases.contains`）。按文档示例配置 `order` 时启动直接失败。随包 `boot.sh:80` 已改成物理库 `db_0`，与 §10.6 示例不一致。
- **建议**：二选一并统一三处：① 语义定为"逻辑库名"，`getSequenceDatabase` 解析为该逻辑库的第一个物理库，`validate` 校验逻辑库；② 语义定为"物理库名"，则修正 §3.1 默认值描述与 §10.6 示例，并在 README 配置表标注"必须是物理库"。同时补一条"显式配置逻辑库名/物理库名"的用例。

#### [一般] 连接池异常未映射为 `TIMEOUT`/`IO`，池耗尽统一变成 `INTERNAL`

- **位置**：`fdbm/src/resources/DatabaseResources.cj:146-162`、`fdbm/src/server/handler.cj:45-47`
- **描述**：设计 §5 明确"池耗尽等待超时同样表现为 `ConnectionException`（映射 `TIMEOUT`）"，开发计划 Step 4.2 也要求"池耗尽 → `TIMEOUT`"用例。实现里 `selectRead`/`selectWrite`/`selectAllWrite` 直接透传 `f_dbpool` 的 `ConnectionException`，全仓 `fdbm/src` 没有任何 `ConnectionException` 捕获（`grep` 为空），最终落到 handler 的 `catch (e: Exception)` → `DbdErrorCode.INTERNAL`。`DbdErrorCode.TIMEOUT` 在 fdbm 内**零引用**，`CACHE` 同样零引用。
- **建议**：在 `DatabaseResources` 的取连接处把 `ConnectionException` 包成 `FdbmException(TIMEOUT, ..., caused)`（池已关闭可映射 `IO`），其余原样上抛；补 `maxSize=1` + 不归还连接的池耗尽用例，断言错误码为 `TIMEOUT`。

#### [一般] `normalize()` 对「区块内外同键」的优先级与设计相反，且不记 WARN

- **位置**：`fdbm/src/config/BootScriptWriter.cj:343-379`（尤其 357-374 的区块外覆盖）
- **描述**：设计 §3.5「启动时自动整理」明确"同一键同时出现在区块内外时，**区块内优先**，记 WARN"。实现先把区块内可写键读入 `entries`，随后扫描区块外顶层 `export fdbm_*` 时执行 `entries[key] = value`，**区块外覆盖区块内**，且没有任何 WARN。运维手工在区块外补的一行会静默改写 managed 区块里的值，与"区块由 fdbm 独占、区块内为准"的模型冲突。
- **建议**：区块外只补 `entries` 中不存在的键（`if (!entries.contains(key))`），冲突时记 WARN（只记键名）；补一条"区块内外同键 → 区块内值保留 + 区块外行被删除"的用例。

#### [一般] `BootScriptWriter` 非线程安全：并发 `export` 会竞争 `pending` 与固定 `.tmp` 文件名

- **位置**：`fdbm/src/config/BootScriptWriter.cj:76`（`private let pending = HashMap<...>`）、`fdbm/src/config/BootScriptWriter.cj:87-94`（`set`）、`fdbm/src/config/BootScriptWriter.cj:96-127`（`flush`）、`fdbm/src/config/BootScriptWriter.cj:440-460`（`writeAtomically`，`'${target}.tmp'`）
- **描述**：`ExportExecutor` 在 f_net 的线程池上并发执行（`executors.call`），同一进程的多条 `export` 会同时 `set`/`flush`：`HashMap` 并发写无保护（可能破坏内部结构），两次 `flush` 共用同一个 `boot.sh.tmp` 并各自 `rename`（后写者覆盖，甚至 `rename` ENOENT 抛 `CONFIG`）。设计未提及并发约束，但服务端是对多连接并发的。
- **建议**：为 `set`/`flush` 加 `Mutex`；临时文件用 `boot.sh.<pid>.<序号>.tmp` 之类的唯一名；补"两条连接并发 export"的用例（断言两个键最终都在区块内、脚本仍可解析）。

#### [一般] `FdbmServer.start()` 吞掉监听循环异常，进程以退出码 0 结束

- **位置**：`fdbm/src/server/FdbmServer.cj:135-143`
- **描述**：`server.start {...}` 抛异常时只 `logger.error` 后正常返回，`main()` 随后 `return 0`。此时服务已不再接受连接，但 `boot.sh status`/容器编排看到的是"正常退出"，与 README「启动失败 → 退出码 1」以及开发计划 Step 8.4「启动自检失败 → 返回 1」不符。`boot.sh start` 只在"启动 10s 内进程消失"时判失败，接入 supervisor 时会被反复重启/误判。
- **建议**：`start()` 捕获后包成 `FdbmException(IO, ...)` 重新抛出（或在 `started` 之外记录失败标志），让 `main` 返回 1；同时把端口绑定失败的映射从 `CONFIG` 改成 `IO`（`FdbmServer.cj:128-129`）。

#### [一般] 优雅停止丢弃 `closeAndAwait` 结果，超时/异常无任何 WARN 日志

- **位置**：`fdbm/src/server/FdbmServer.cj:163`、`fdbm/src/resources/DatabaseResources.cj:226-241`
- **描述**：设计 §10.4 第 4 步要求"逐池 `closeAndAwait`，未按期终止则记 WARN 并继续收尾"。`FdbmServer.stop()` 丢弃返回值；`DatabaseResources.closeAndAwait` 对每个池 `catch (_: Exception) { all = false }` 也不记日志，`PartitionCache.close`/`DatabaseResources.close` 同样静默吞异常。关停期的连接未归还、池未终止在日志中完全不可见，事故排查只能靠猜。
- **建议**：`DatabaseResources.closeAndAwait` 在返回 `false` 或捕获异常时 `logger.warn`（池名 + 原因）；`stop()` 对返回 `false` 记一条汇总 WARN。补"期限 1ms + 有未归还连接 → false 且不抛"的用例（开发计划 Step 4.2 已列）。

#### [一般] 会话游标状态无并发保护：巡检/关停与请求处理可能竞争

- **位置**：`fdbm/src/server/SessionRegistry.cj:112-142`（`sweep` 先摘表再 `session.close()`）、`fdbm/src/server/handler.cj:74-92`（`executeSql` 写 `session.cursor`）、`fdbm/src/execute/session.cj:49-79`（`DbdSession.cursor` 为普通 `var`）
- **描述**：`DbdSession.cursor` / `pinned` 是普通字段，读写分别发生在 f_net 的 executor 线程（handler）和 `Timer` 线程（`sweep`）/ 信号处理线程（`closeAll`）。典型交错：`sweep` 判定连接已关闭并把会话从表里摘掉 → 同时一个已受理的请求执行完查询，`session.cursor = Some(cursor)` 写回一个已"不存在"的会话 → 该游标再也不会被关闭，其持有的 `PooledConnection` 泄漏（`closeAndAwait` 随之超时）。`closeCursor` 与 `closeSessionCursor` 也存在同一把游标被两边 `close()` 的可能。
- **建议**：给 `DbdSession` 的 `cursor`/`pinned` 访问加会话级 `Mutex`（或改为原子状态机），`sweep`/`closeAll` 与 handler 走同一把锁；补"查询执行中客户端断连"的并发用例（慢查询 + 短巡检周期），断言连接归还次数恰好 1。

#### [一般] `PartitionCache` 关闭标志非原子，关闭后静默降级

- **位置**：`fdbm/src/route/cache.cj:52-60`（`get` 读 `closed_`）、`62-85`（`put` 读 `closed_`）、`118-120`（`isClosed`）
- **描述**：`closed_` 是普通 `Bool`，在 `stop()`（信号线程）里被置位，同时在多个执行器线程里被读取，无锁也无 `AtomicBool`（同文件的 `count_` 另有保护，对比 `DatabaseResources.closed` 用了 `AtomicBool`）。此外关闭后 `get` 返回 `None`、`put`/`remove` 直接 `return`，调用方无法区分"未命中"与"缓存已关闭"；开发计划 Step 5.3 明确要求"关闭后 `get` 抛 `FdbmException(CACHE)`"，且 `DbdErrorCode.CACHE` 在 fdbm 内零引用。
- **建议**：`closed_` 改 `AtomicBool`；关闭后 `get`/`put` 抛 `FdbmException(CACHE, ...)`（与开发计划对齐），或反过来把开发计划改成"降级为未命中"并说明理由，二者取一并同步文档。

#### [一般] 启动失败路径未释放已创建的资源

- **位置**：`fdbm/src/server/FdbmServer.cj:64-100`（`PartitionCache` 在驱动校验/`DatabaseResources` 之前创建）、`fdbm/src/resources/DatabaseResources.cj:57-97`（构造中途 `driver.open`/`DatabasePool` 抛异常时已建池不回收）
- **描述**：`FdbmServer` 构造顺序是"缓存 → 路由 → 驱动 → 资源"，任一后续步骤抛错（典型：`NO_DRIVER`、某个节点连不通导致 `DatabasePool` 构造失败）时，已打开的 `f_store`（含后台 compaction 线程）与已建好的 `DatabasePool` 都不会被关闭；`DatabaseResources` 自身在循环中途抛错也会遗留前几个池。进程随后 `exit(1)` 由内核兜底，但在"进程内嵌 `FdbmServer` + 重试"的用法（构造函数支持 `driver!` 注入，说明存在这种用法）下就是泄漏。
- **建议**：构造体内用 `try { ... } catch (e) { 已建资源逐个 close; throw e }` 收尾，或把"资源装配"抽成可回滚的步骤；至少把 `PartitionCache` 的创建推迟到驱动/资源校验之后。

### 测试覆盖缺口（R3 范围）

| 功能域 | 现有用例 | 缺口 |
| --- | --- | --- |
| 配置 `get*`（`FdbmConfig_test.cj`，25 例） | 端口/节点/池/权重/分区/substr/全局表/idmaker/缓存/时长默认值与非法值 | `fdbm_partition_step<=0`、`fdbm_cache_size<0`、`shutdownTimeout/checkDuration/unavailableChecked` 非法值、`getSequenceDatabase` 默认值、`fdbm_global__` 空值；**无"逻辑库名 ≠ 物理库名"的用例** |
| `validate`（`FdbmValidateTest`，8 例） | 驱动不一致、逻辑库/权重引用、未知算法、`partition` 无表名、snowflake 序号、sequence 库不存在 | 自定义与内置重名、`fdbm_global__` 逻辑库不存在、`fountain_sequence` 表缺失、`shutdownTimeout=Duration.Max`、`checkDuration<=0` |
| `BootScriptWriter`（11 例） | 白名单、旧标记迁移、分块/排序/注释、单引号转义、幂等、原子写可执行位、失败不阻塞 | 值含空格、`.tmp` 残留/并发写、区块内外同键优先级、非白名单键在区块内被丢弃时的 WARN、权限位（仅覆盖可执行位） |
| `PartitionCache`（`Route_test.cj` 2 例 + `Server_test.cj` 1 例） | put/get/remove/count、同键覆盖不增计数、容量停写、重启后命中 | `expire` 过期、原始键格式字节、关闭后行为（当前实现与开发计划不一致）、容量计数含过期键、`init` 统计与 `put` 并发的竞态 |
| `IdMakers`（4 例） | uuid v4 唯一性、snowflake 单调、sequence 取号、`forTable` 三种内置 | v1/v6/v7 的版本与时间戳（**当前实现有缺陷，用例缺失**）、非法版本构造、`nextIntId` 对 uuid 抛 `IdGeneratorException`、多线程唯一性、sequence 行缺失 → `ID_GENERATOR`、按 `(logical,table)` 隔离 |
| `DatabaseResources`（4 例） | 两节点读写、零权重排除、无读节点、关闭幂等 | 权重分布/`roundrobin` 取模、池耗尽 → `TIMEOUT`、`closeAndAwait` 超时返回 `false`、`Duration.Zero/Max` 抛 `IllegalArgumentException`、构造失败回收 |
| `SessionRegistry`/`InFlight`（4 例） | 同连接同会话、断开后巡检回收、enter/leave、await 超时 | `closeAll` 回收游标与 pin 的归还次数断言、巡检与请求并发、`InFlight` 计数在并发下不丢 |
| `FdbmServer` 生命周期（3 例 + `lifecycle_test.sh`） | 起停/幂等/端口不可连、驱动名不匹配、真实进程 start/status/stop 与优雅标记 | **关停顺序**（会话先于 `closeAndAwait`）、在途慢语句等待、`closeAndAwait` 超时 WARN、监听异常 → 退出码非 0、`boot.sh` 的 start 超时/restart 分支 |
| `CustomLoader`/`DriverLoader`（4 例） | 目录缺失=空、损坏库=`CONFIG`、0/2 个库=`NO_DRIVER` | "全部加载后才 `initialize()`"、`initialize()` 抛异常、自定义重名、与内置重名、单库成功（仅靠 e2e/生命周期脚本） |
| `main`（1 例） | `FountainVersion` 非空 | 启动自检失败 → 返回 1、正常 SIGTERM → 返回 0（开发计划 Step 8.4 要求） |
| SHOW / EXPORT | 集成用例覆盖 `show databases`/`show tables`（mockdb 不支持）/`export` 落盘 | 逻辑库名出现在 `show databases`、`show tables <logical>`、`export` 非法键 → `CONFIG`、并发 export |

补充说明（空实现/占位/跳过）：

- 全量 `grep` 未发现 `TODO`/`FIXME`/`Unimplemented`/`throw Unimplemented`；`fdbm/src` 中无空函数体（`(){}`），`catch (_: Exception) { () }` 的 30 处均为"尽力关闭资源"的收尾写法。
- 15 个测试文件共 190 个 `@TestCase`、约 630 条 `@Assert`，**未发现空测试类、无断言的 `@TestCase` 或被 `@Ignore`/`@Skip` 的用例**。
- `fdbm/src/{idmaker,route,execute,resources,sql}/placeholder.cj` 5 个文件只有 License 头 + `package` 声明（如 `fdbm/src/idmaker/placeholder.cj:16` 后即结束），无任何声明，属无意义占位文件。
- `test/lifecycle_test.sh:15-22` 在缺少 `fdbm` 可执行文件或 `libf_mockdb` 时打印 `SKIP` 并 `exit 0`：CI 若未先 `cjpm build/install`，该"唯一覆盖真实 SIGTERM 优雅停止"的脚本会静默通过，建议改为可配置的显式失败（如 `FDBM_ALLOW_SKIP=1`）或在 CI 中强制要求执行。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 2 |
| 一般 | 14 |
| 轻微 | 7 |

#### 轻微问题清单

1. `fdbm/boot.sh:165-187` 的 `stop` 固定等待 30s，与可配置的 `fdbm_shutdownTimeout`（可 > 30s）脱钩；`restart()`（`204-207`）不检查 `stop` 的返回值，停止超时后 `start` 只会打印 `already running` 并返回 0。
2. `fdbm/src/config/BootScriptWriter.cj:434-439` 注释声称"权限位偏差已在详细设计登记"，但 `详细设计.md` §3.5（`详细设计.md:284,300`）仍写"复制原文件权限位"，文档未登记该偏差。
3. `fdbm/src/config/FdbmConfig.cj:519-526` 用 `HashSet` 迭代生成"全部物理库"数组，顺序不确定；该数组会作为广播/多分片的库顺序（行序=库序），跨进程不可复现。
4. `fdbm/src/config/FdbmConfig.cj:130-132` 对 `weights.get(suffix).isSome()` 的"重复权重键"检查永远不成立（`source.all()` 的键天然唯一），属死校验；`validateNodes`（`381-388`）与 `getNodes` 的重名检查重复。
5. `fdbm/src/config/source.cj` 之外，`FdbmConfig.getPort` 把空字符串判为 `CONFIG`，而其他键把空值当"取默认值"（`stringOf/intOf`），空值口径不一致。
6. `fdbm/src/config/FdbmConfig.cj:624-631` 读出的 `fdbm_databasePoolMaxWaiting` 实际不会被使用（`DatabaseResources` 统一走 `pool.connect()` → `getConnection(timeout: connectTimeout)`）；`0/负数 → Duration.Max` 的映射更强化了"配了也不生效"的误解，README 未说明。
7. `fdbm/src/resources/DatabaseResources.cj:189-195` 的 `databases()` 返回节点配置的插入顺序而非文档/开发计划要求的"排序稳定"；`driver(database)`（`204-210`）在多节点同名库时只保留最后一个节点的驱动名。

### 总评

R3 范围内的骨架是扎实的：配置项与设计 §3.1 基本逐条对应、默认值一致，`fdbm_config` 的解析错误统一为 `CONFIG` 且带键名与原值；`BootScriptWriter` 的分块/注释/排序/幂等/原子写与 §3.5 高度吻合；服务生命周期六步（关监听 → 等在途 → 关会话 → 关池 → 关缓存 → 退出）实现顺序正确且 `stop()` 幂等；handler 对"任何请求必有回包"与 `FdbmException`/`SqlException` 的映射完整；未发现 TODO/Unimplemented/空函数/空测试，15 个测试文件 190 例全部带断言。

但存在两个必须在合并前处理的**严重**问题：① `logicalDatabases()` 把物理库名灌进逻辑库表，使会话默认库落在物理库上，按文档以逻辑库名配置的分库规则**整体不生效且静默**——现有 e2e/集成用例因为把逻辑库名取成物理库名而完全掩盖了它；② `UuidIdGenerator` 的 v1/v6 从未触发时间戳生成，时间字段恒为 0，并且每个 ID 都在 `/tmp` 新建一个临时目录与文件，既破坏 UUID 语义又带来 inode 耗尽风险。

其余一般问题集中在四类：启动自检缺项（自定义与内置重名、全局表逻辑库、`fountain_sequence` 表、`sequenceDatabase` 语义）、错误码映射缺口（连接池 `ConnectionException` → `INTERNAL` 而非 `TIMEOUT`）、关停期可观性（`closeAndAwait` 结果被丢弃、缓存/池关闭静默吞异常）、并发安全（会话游标、`PartitionCache.closed_`、`BootScriptWriter`）。测试层面，配置与协议层覆盖较好，但 `idmaker`（4 例）、`DatabaseResources`（4 例）、`main`（1 例）与"关停顺序/在途等待"几乎空白，恰好覆盖不到上述严重问题，建议随修复同步补齐表中缺口用例，并把 `lifecycle_test.sh` 的静默跳过改成 CI 可强制的失败。
