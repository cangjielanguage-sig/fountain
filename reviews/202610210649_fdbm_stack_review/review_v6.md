# R6: f_dbd / f_dbm / fdbm 测试用例充分性汇总与跨模块功能矩阵

审查时间：2026-10-21

### 审查范围

工作树 `.worktrees/review_fdbm_stack_202610210649`（基线 `7ca82fcc`，只读，未修改任何文件）。

**f_dbd（21 个测试文件，其中 3 个为纯夹具）**

`src/common/{DbdException,column,error,payload,result,sqltypes,types,dispatch_perf}_test.cj`、
`src/driver/{DbdUrl,DbdDriver,DbdConnection,DbdStatement,DbdTransaction,DbdTransport}_test.cj`、
`src/driver/{stub_fdbm,testkit}_test.cj`（夹具）、`src/exception/Reexport_test.cj`、
`src/multid/{MultiD,MultiDatasource}_test.cj`、`src/multid/stub_test.cj`（夹具）、`src/dbd_test.cj`

**f_dbm**

无任何 `*_test.cj`、无 `test/` 目录、`cjpm.toml` 无 `[test-dependencies]`（仅 `f_base`）。

**fdbm（15 个测试文件）**

`src/config/{FdbmConfig,BootScriptWriter}_test.cj`、`src/exception/FdbmException_test.cj`、
`src/execute/{Dispatcher,ExecutorFeature}_test.cj`、`src/idmaker/IdMakers_test.cj`、
`src/main_test.cj`、`src/resources/DatabaseResources_test.cj`、`src/route/Route_test.cj`、
`src/server/{Handler,Server,Integration}_test.cj`、
`src/sql/{SqlParser,SqlSupport,SqlFeature}_test.cj`

**e2e 与进程级脚本**

`fdbm/test/e2e/{run.sh,lib.sh,README.md}`、`test/e2e/backends/{postgres,mysql}.sh`、
`test/e2e/client/src/main.cj`、`test/e2e/orm_client/src/main.cj`、
`test/e2e/driver_bundle_{mysql,postgres}/`、`test/{mysql_e2e,postgres_e2e}/run.sh`、
`test/lifecycle_test.sh`

**参照文档**：`f_dbd/doc/spec/.../specs/f-dbd/spec.md`、`fdbm/doc/详细设计.md`（§9.6/§10.2/§10.4/§11）、
`fdbm/doc/开发计划.md`、`fdbm/README.md`、`f_dbm/README.md`、`fdbm/test/e2e/README.md`

**方法与限制**

- 只读静态审查：按 `@Test` 类 / `@TestCase` / `@Assert` 逐文件统计，并按 `@TestCase` 边界切块判定"无断言"，未依赖文件名或注释。
- 未执行 `cjpm test`：`f_dbd/src/driver/DbdDriver.cj:53` 的包级 `static init` 依赖环境变量（R2 已登记 G3），`dispatch_perf_test` 单轮约 4.8×10⁸ 次分派，真库 e2e 需外部 PostgreSQL/MySQL。因此"用例是否通过"不在本轮结论内，本轮只判定"用例是否存在、是否可能失败"。
- 细节缺陷不复述 R1/R2/R3/R4/R5 已给出的结论，仅在其上做覆盖度归并并标注引用。

---

### 测试规模

| 模块 | 测试文件 | `@Test` 类 | `@TestCase` | `@Assert` | 测试代码行 | 实现代码行 |
| --- | --- | --- | --- | --- | --- | --- |
| f_dbd | 21（18 含用例） | 24 | 180 | 641 | 4149 | 3326 |
| f_dbm | 0 | 0 | 0 | 0 | 0 | 81 |
| fdbm | 15 | 26 | 190 | 630 | 4392 | 8482 |
| **合计** | **36** | **50** | **370** | **1271** | **8541** | **11889** |

e2e 层（非 `@TestCase` 计数）：

| 载体 | 断言形态 | 数量 |
| --- | --- | --- |
| `test/e2e/client` | `check/checkInt/checkText` 96 个调用点（循环展开后约 108 / MySQL 106） | PostgreSQL 108、MySQL 106 |
| `test/e2e/orm_client` | 同上 27 个调用点（实体插入循环展开后 28） | 28 |
| `test/e2e/run.sh` + `lib.sh` | 端口就绪、`E2E_DONE`、`checks=..failures=0`、export 内容、缓存目录非空、停止标记、重启探针 | 8 |
| `backends/*.sh::backend_verify` | 逐库 SQL 核对 | PG 13 / MySQL 14 |
| `lifecycle_test.sh` | pid 消失 + `fdbm is stopping` 日志 | 2 |

**按包分布**

| 包 | 用例 | 断言 | 备注 |
| --- | --- | --- | --- |
| f_dbd.common | 102 | 355 | 含 4 例性能实验（3 例 0 断言） |
| f_dbd.driver | 58 | 206 | `DbdUrl` 14 例纯解析；连接/语句/事务/传输 33 例经 `StubFdbm` 回环；`DbdDriver` 11 例为不建链的构造/注册断言 |
| f_dbd.multid | 16 | 72 | 6 例回环 |
| f_dbd.exception / 根包 | 4 | 8 | 含 1 例占位 |
| fdbm.sql | 52 | 187 | 密度最高（74 个公开成员） |
| fdbm.execute | 42 | 115 | 8 个执行器 |
| fdbm.config | 36 | 147 | 36 个配置键 |
| fdbm.server | 27 | 75 | 11 例协议回环、5 例全栈、11 例生命周期 |
| fdbm.route | 22 | 75 | |
| fdbm.resources | 4 | 13 | 14 个公开成员，最薄 |
| fdbm.idmaker | 4 | 9 | 内置实现，仅一条非法 kind 负例 |
| fdbm.exception / main | 3 | 9 | 含 1 例占位 |

**测试类型切分（按是否起 socket / 起真库）**

- 纯单测（内存/桩，无网络）：f_dbd 约 141 例（`common` 102、`exception`/根包 4、`multid` 中约 10、`DbdUrl` 14、`DbdDriver` 11）；fdbm 170 例。
- 进程内回环集成（真 `f_net.Server` + `Client`）：f_dbd 约 39 例（`DbdConnection`/`DbdStatement`/`DbdTransaction`/`DbdTransport` 33、`multid` 中 6）；fdbm 15 例（`Handler_test` 11、`Server_test` 4）。
- 全栈进程内（真 f_dbd 客户端 ↔ 真 fdbm 服务 ↔ `f_mockdb`）：5 例（`Integration_test.cj`）。
- 真库 e2e：2 后端 × 1 客户端 + 1 f_orm 客户端 + 重启探针 + 逐库 SQL。
- 进程级：`lifecycle_test.sh` 1 条路径。

结论：金字塔形状合理（370 单测/集成 + 约 150 e2e/后端），**但顶端两层覆盖的是"能跑通"，不是"失败时正确"**——见发现 2–5。

---

### 覆盖矩阵 A：模块 → 公开能力 → 测试层级

图例：✅ 有能失败的断言；◐ 只覆盖部分分支/类型；❌ 无用例。

| # | 公开能力 | 单测 | 进程内集成 | 真库 e2e | 结论 |
| --- | --- | --- | --- | --- | --- |
| 1 | 协议请求/响应/超时/错误回包（CONSUME/RESP/UNSUBSCRIBE/ACK/ERROR） | f_dbd `DbdTransport` 10 | fdbm `Handler` 11 | 全链路 | ✅ |
| 2 | 查询游标不变量（无预读、行缓冲、终止、关闭幂等、qid 不匹配） | f_dbd `result` 21 | fdbm `Handler` 7 + `Integration` 2 | `cursorSemantics` 7 checks | ✅ |
| 3 | 流列分块与句柄复用 | f_dbd 9 | fdbm `Integration` 1 | ❌（e2e README 已列为已知边界） | ◐ |
| 4 | 列类型归一（详细设计 §9.6） | 仅映射函数 3 例（在 f_dbd） | ❌ | ❌（从不断言 `typeName`） | ❌ |
| 5 | 事务 / savepoint / `TX_STATE` | f_dbd 5 | fdbm `Dispatcher` 1 | 5 checks（savepoint 仅此处） | ◐ |
| 6 | 分库路由（step/hash/substr/IN/范围/空区间/派生表） | — | `Route` 22 + `Dispatcher` 8 | 约 29 | ✅ |
| 7 | 全局表广播 / 读一副本 / 部分失败 | — | `Dispatcher` 3 | 8 | ✅ |
| 8 | DDL 广播（create/drop） | — | `Dispatcher` 2 | 12 + 逐库核对 | ✅ |
| 9 | SHOW（方言族/like/列名） | — | `Dispatcher` 6 | 5 | ✅ |
| 10 | EXPORT 白名单与落盘 | — | `Dispatcher` 3 + `BootScriptWriter` 11 | 2 | ✅ |
| 11 | `count(*)` / 派生表分页 / `RETURNING` | — | `ExecutorFeature` 9 | 8–12（PG 含 returning 4 条） | ✅ |
| 12 | ID 生成（uuid/snowflake/sequence） | — | `IdMakers` 4（3 正例 + 1 条非法 kind） | 仅 sequence | ◐ |
| 13 | 自定义扩展（f_dbm SPI → `custom/*.so` → 工厂/`forTable`） | **0** | 仅空目录/坏库 2 例 | `custom/` 恒为空 | ❌ |
| 14 | 连接池借还 / 耗尽 / 检查 | f_dbd `multid` 6 | `resources` 4（只断言数量） | 仅隐式 | ◐ |
| 15 | 读写分离 / 负载均衡 | f_dbd `multid` 5 | `resources` 2（只断言"被排除"） | 双账号但无读路径断言 | ◐ |
| 16 | 优雅停止（在途 → 会话 → 池 → 缓存） | — | `Server` 11（仅空载 stop） | 停止标记 + 重启探针 | ◐ |
| 17 | 分库缓存（命中/失效/容量/落盘/过期） | — | `Route` 2 + `Server` 1 | 目录非空 | ◐ 过期未测 |
| 18 | 启动自检（详细设计 §11 共 16 行） | — | 13 行（见矩阵 C） | 0 | ◐ |
| 19 | 配置解析（36 个键） | — | `FdbmConfig` 25 + `BootScriptWriter` 11 | 覆盖 20+ 键 | ✅ |
| 20 | `boot.sh` 生命周期（start/status/stop/restart） | — | ❌ | start/status/stop | ◐ `restart`、重复 `start` 未测 |
| 21 | 进程退出码（配置错误 → 1，且未监听） | — | ❌ | ❌ | ❌ |
| 22 | f_dbm 契约（`PartitionAlgorithm`/`IdGenerator`/`IdGeneratorException`） | ❌ | ❌ | ❌ | ❌（同 R2 矩阵 D） |

**完全无测试的公开能力（明确清单）**

1. `f_dbm` 全部 6 个公开成员（同 R2 矩阵 D）。
2. `QueryCursor.columnsOf` / `SqlTypes.canonicalName` 在 fdbm 的接线（矩阵 4）。
3. `CustomExtensions` 的正向加载与注入（矩阵 13）。`CustomLoader` 只有"目录不存在"和"库损坏"两条负例（`fdbm/src/server/Server_test.cj:152-167`）。
4. `SessionRegistry.closeAll`（`fdbm/src/server/SessionRegistry.cj:71-94`）与 `InFlight.await` 的唤醒路径（`fdbm/src/server/InFlight.cj:52-71`）。
5. `DatabaseResources.closeAndAwait` 的 `false` 分支（`DatabaseResources.cj:226-241`），`selectAllWrite` 的已借连接回滚（`DatabaseResources.cj:176-185`）。
6. `main()` 的失败退出（`fdbm/src/main.cj:30-41`）与 `boot.sh restart`（`fdbm/boot.sh:204-213`）。
7. `PartitionCache` 的过期分支与关闭后读写（`fdbm/src/route/cache.cj:52-65,77-80`）。
8. `MemoryQueryResult` 的 `CONVERSION`/`CURSOR_STATE` 分支（`fdbm/src/execute/cursor.cj:256-287`）——客户端正常路径读不到这些分支，只有手写报文才能触达。

---

### 覆盖矩阵 B：错误码 → 生产方 → 是否有用例

统计方式：源码与测试中 `DbdErrorCode.<CODE>` 的出现次数（前者含注释性质的引用，仅用于判断"是否有生产点"）。

| 错误码 | 源码引用 | 单测引用 | 真库 e2e | 判定 |
| --- | --- | --- | --- | --- |
| INTERNAL | 26 | 22 | 0 | ✅ |
| PROTOCOL | 24 | 12 | 0 | ✅ |
| SQL_SYNTAX | 18 | 14 | 1 | ✅ |
| UNSUPPORTED_SQL | 28 | 21 | 1 | ✅ |
| ROUTE_FAILED | 32 | 11 | 1 | ✅ |
| PARTITION_CONFIG | 12 | 4 | 0 | ◐ 仅配置解析 |
| NO_DRIVER | 13 | 5 | 0 | ✅ |
| CURSOR_STATE | 21 | 13 | 2 | ✅ |
| TX_STATE | 9 | 4 | 2 | ◐ 缺 savepoint/release 未开启事务 |
| DB_ERROR | 9 | 6 | 1 | ✅ |
| TIMEOUT | 9 | 7 | 0 | ◐ 全在 f_dbd，fdbm 侧借用超时无断言 |
| CONFIG | 119 | 46 | 1 | ✅ |
| CACHE | **0** | 0 | 0 | ❌ 契约里的死码（无任何生产点） |
| IO | 8 | 4 | 0 | ◐ |
| ID_GENERATOR | 6 | 1 | 0 | ◐ 只有 `FdbmConfig` 的启动期一处；运行期映射见 R2 [严重] 第 2 条 |
| CONVERSION | 13（全在 fdbm） | 2（全在 f_dbd） | 1 | ❌ fdbm 侧 0 断言 |

要点：

- `CACHE`（`f_dbd/src/common/error.cj:44`）在 f_dbd/fdbm 全仓无生产点，属"协议契约里有、实现从不返回"的码；`error_test.cj:30` 只断言编号表完整性，不校验可达性。
- `CONVERSION` 在 fdbm 有 13 处生产点（`cursor.cj` 7、`executors.cj` 2 等），fdbm 侧 0 断言；f_dbd 的 2 处断言测的是客户端自己的类型转换，不覆盖服务端。
- `ID_GENERATOR` 唯一用例是 `FdbmConfig_test.cj:436-447`（启动自检），运行期 `IdGeneratorException` 的映射无人覆盖（R2 已定性）。

---

### 覆盖矩阵 C：`fdbm/doc/开发计划.md` 要求的用例 vs 现状

| 计划条目 | 要求 | 现状 |
| --- | --- | --- |
| 开发计划:54 | `fdbm_partition`（无 `__`）→ `CONFIG` **并验证 main 退出码非 0** | 解析层有负例（`FdbmConfig_test.cj:231-233`），**退出码无** |
| 开发计划:59 | `validate` 表驱动负例逐条（§11 共 16 行） | 13 行有函数级用例；缺自定义重名、`checkDuration<=0`/`unavailableChecked<=0`、`shutdownTimeout<=0/Max`（substr 行的 `start<0`/`length<0` 亦未覆盖） |
| 开发计划:67 | `flush()` ①–⑥（含"无 `.tmp` 残留"） | ①–⑤ 有（`BootScriptWriter_test.cj:54-143,218`），**⑥ 无** |
| 开发计划:149 | `closeAndAwait` ②1ms 有借用 → `false`；③`Zero`/`Max` → `IllegalArgumentException` | 只有 ①（`DatabaseResources_test.cj:109`） |
| 开发计划:235 | `SelectExecutor` ⑥ 列类型归一表驱动（`SqlVarchar/int4/TINYINT(1)/bytea/GEOMETRY`） | **无**（见发现 2） |
| 开发计划:278 | `FdbmServer.start()` 自检负例 → **进程退出码非 0（脚本化）** | **无**（见发现 5） |

---

### 无效 / 弱测试清单（判定依据）

全量 36 个测试文件、370 个 `@TestCase` 中：

| 判定 | 位置 | 判定依据 |
| --- | --- | --- |
| 无任何断言 | `f_dbd/src/common/dispatch_perf_test.cj:60`（`perTypeMatrix`）、`:99`（`missProbes`）、`:123`（`nullShortCircuit`） | 三例函数体内只有 `println`/`timed`，无 `@Assert`；`timed` 不做 witness 校验，用例不可能失败 |
| 无任何断言 | `f_dbd/src/driver/DbdDriver_test.cj:158`（`unknownOptionIsIgnored`） | 只有 `setOption`/`close` 调用（R2 已登记） |
| 无任何断言 | `fdbm/src/config/FdbmConfig_test.cj:449-459`（`positiveSettingsPassValidation`） | 函数体只调用 `FdbmConfig.validate`，靠"不抛"表达通过；无 `@Assert`，失败信息只有异常栈 |
| 占位/平凡用例 | `f_dbd/src/dbd_test.cj:22-34`、`fdbm/src/main_test.cj:22-29` | 注释自述"阶段 0 平凡用例/占位"，只断言 `FountainVersion`，未触达模块任何声明 |
| 名实不符 | `f_dbd/src/common/sqltypes_test.cj:140-149` | 名称"应抛"、断言 `!threw`（R2 已登记，`types.cj:454` 分支仍零覆盖） |
| 反惯用写法 | `fdbm/src/server/Integration_test.cj:78` | `@Assert(true, false)` 作"不应到达"标记；应用 `@Fail`，否则失败信息只有 `expected false` |
| 断言错误契约 | `fdbm/src/route/Route_test.cj:113-116` | 用自定义 `'hash'` 覆盖内置并断言覆盖生效（见发现 1） |
| 空测试类 | 无 | 50 个 `@Test` 类均含 ≥1 个 `@TestCase` |
| 被注释 / 禁用 / 跳过 | 无 | 全仓无 `@Ignore`/`@Skip`/`@Disabled`/`@ExpectFail`，无注释掉的 `@TestCase` |
| 脚本级静默跳过 | `fdbm/test/lifecycle_test.sh:15-22` | 缺二进制/缺 `.so` 时 `echo SKIP; exit 0`，与"通过"不可区分 |

---

### 发现

#### [严重] 自定义扩展链路（f_dbm 的唯一交付物）零端到端用例，且唯一涉及内置重名的用例把"覆盖内置"固化为期望

- **位置**：`fdbm/src/route/Route_test.cj:113-116`；`fdbm/src/server/Server_test.cj:151-167`；`fdbm/src/server/CustomLoader.cj:65`；`fdbm/src/idmaker/IdMakers.cj:184-186`；`fdbm/test/e2e/run.sh:42`；`fdbm/test/e2e/lib.sh:66`
- **描述**：
  `f_dbm` 的全部职责就是"第三方实现 `PartitionAlgorithm` / `IdGenerator`，由 fdbm 从 `custom/` 发现并注入"。这条链路的每一段在测试里都被绕开了：

  1. **f_dbm 侧 0 用例**（同 R2 矩阵 D）；
  2. **发现层**只有两条负例——目录不存在（`Server_test.cj:152-156`）与库损坏（`:158-167`）；全仓没有一条用例加载过真实的自定义 `.so`；
  3. **注入层**在 `Dispatcher_test.cj:176` 直接把 `HashMap<String, IdGenerator>` 传给 `ExecutorDispatcher`，跳过了 `IdMakers.forTable` 的 custom 分支（`IdMakers.cj:184-186`）；
  4. **e2e 层** `run.sh:42` 建了 `$WORK/custom` 目录，`lib.sh:66` 把它作为 `fdbm_customDir` 传入，但从未向其中放入任何库——扩展目录在全部 e2e 中恒为空；
  5. 唯一触及"内置名 + 自定义"的用例 `Route_test.cj:113-116` 注册 `custom['hash']` 并断言 `partition('x') == 'db1'`，即**断言自定义实现覆盖内置实现**。这与 `f_dbm/README.md:59`"与内置重名同样拒绝，不允许覆盖"相反。

  第 5 条是本轮新增的事实修正：R2 [严重] 第 3 条曾记"没有任何测试覆盖内置名冲突场景"；更准确的表述是——**唯一的冲突场景用例断言的正是那个错误语义**。这会带来两个后果：其一，按 README 修复 `validatePartitions`/工厂优先级时该用例必然变红，实施者若不了解上下文很可能反过来"修测试"；其二，这条链路改变的是分库**落点**（`hash` 被换掉后同一用户的数据会写到别的物理库），属于最需要回归网的位置，而它恰好处在三层测试的公共盲区。
- **建议**：
  1. 新增一个随 e2e 编译的自定义扩展样例模块（同时实现 `PartitionAlgorithm` 与 `IdGenerator`），由 `run.sh` 构建成 `.so` 放进 `$WORK/custom`，e2e 断言：自定义算法被路由实际使用（落点符合样例逻辑）、自定义生成器回填了自增键；
  2. `Route_test.cj:113-116` 改为"内置名冲突 → `PARTITION_CONFIG`"的负例（与 `f_dbm/README.md:59` 对齐），并另加一条"自定义独有名 → 生效"的正例；
  3. `IdMakers.forTable` 的 custom 分支补一条直测（当前只经执行器间接、且绕过了该函数）；
  4. f_dbm 侧补接口默认实现/异常用例（R2 已给出清单，此处不重复）。

#### [一般] 列类型归一（§9.6）在 fdbm 侧无任何断言，mockdb 恒报仓颉类型名使该路径只走"透传"

- **位置**：`fdbm/src/execute/cursor.cj:97-104`（唯一归一口 `QueryCursor.columnsOf` → `SqlTypes.canonicalName`）；举证：`fdbm/src/server/Handler_test.cj:56`（`typeName: 'Int64'`）、`fdbm/src/execute/Dispatcher_test.cj:747`（`'String'`）、`fdbm/src/server/Integration_test.cj:197`（`'Int64'`）；`fdbm/test/e2e/client/src/main.cj:433`（e2e 只读 `columnInfos[0].name`）
- **描述**：
  详细设计 §12 把"列类型只在线上出现仓颉类型名"列为拍板决策：物理方言的 `int4`/`TINYINT(1)`/`bytea`/`GEOMETRY` 必须由 fdbm 归一成 `Int32`/`Bool`/`Array<Byte>`/`String`，客户端不认识方言拼写。实现只有 `cursor.cj:100` 一处调用，而 **fdbm 的全部 190 条用例里，mockdb 的 `typeName` 都直接写成仓颉名**，于是 `canonicalName` 在执行器/协议层始终命中"原样返回"分支；e2e 只用真实驱动跑了 CRUD，客户端从不看 `typeName`，所以归一表在真实方言下也没有任何断言。

  现状是：映射函数本身有 3 条单测（`f_dbd/src/common/sqltypes_test.cj:96-122`），但它**是否被接到 RESP 里**没有任何用例钉住。若 `columnsOf` 被改成直接透传，或映射表少一行（例如 `int4 → Int32` 被误删），370 条用例全绿，而客户端 `get<Int32>` 会在运行期变成 `CONVERSION`。开发计划:235 ⑥ 已明确把这条列为验收项，属计划内未完成。
- **建议**：在 `Dispatcher_test`/`Handler_test` 加一条表驱动（mockdb 分别报 `SqlVarchar`、`int4`、`TINYINT(1)`、`bytea`、`GEOMETRY`），断言 RESP 的 `columnInfos[i].typeName`；e2e 在 `driverAndMetadata` 或 step 查询后补 `columnInfos[0].typeName == 'Int64'` 一条，用真实方言验证。

#### [一般] 优雅停止的"等待与释放"语义无测试：`InFlight` 唤醒路径、`closeAll`、`closeAndAwait` 超时全部缺位

- **位置**：`fdbm/src/server/FdbmServer.cj:139-165`；`fdbm/src/server/InFlight.cj:52-71`；`fdbm/src/server/SessionRegistry.cj:71-94`；`fdbm/src/resources/DatabaseResources.cj:226-241`；用例侧 `fdbm/src/server/Server_test.cj:41-58,171-198`、`fdbm/src/resources/DatabaseResources_test.cj:102-118`、`fdbm/test/lifecycle_test.sh:72-82`
- **描述**：
  README（`fdbm/README.md:49-51`）承诺的停止顺序是"停止接受新连接 → 等在途请求 → 关闭全部会话与游标（归还借用连接）→ 逐池 `closeAndAwait` → 关缓存 → 退出码 0"。现有用例覆盖的是：

  - `InFlight` 的"计数为 0 立即返回"和"超时返回 false"（`Server_test.cj:41-58`），**`leave()` 触发 `condition.notifyAll()` 把阻塞中的 `await` 唤醒**这条路径从未执行——它是"等在途请求"唯一真正生效的分支；
  - `serverStartsServesAndStops`（`:171-198`）在**无在途请求、无打开游标、无 pin 事务**的空载状态下 stop；
  - `closeAndAwait` 的唯一断言是"`true`"（`DatabaseResources_test.cj:109`），但同一用例前一行已 `resources.close()`：`closeAndAwait` 进来时 `closed.swap(true)` 已为真，**直接返回 `true`（`DatabaseResources.cj:227-229`），逐池循环（`:231-239`）从未执行**。开发计划:149 要求的"有借用 + 1ms → false"和"`Zero`/`Max` → `IllegalArgumentException`"均缺；
  - `closeAll` 关闭会话时释放游标与 pin 连接（`SessionRegistry.cj:87-93`、`execute/session.cj:62-83`）无任何用例；
  - 进程级只验证 pid 消失与 `fdbm is stopping` 日志，`boot.sh stop` 是后台 `kill -TERM`，**脚本拿不到退出码**，因此"退出码 0"这条文档承诺没有任何可执行断言。

  影响：停止流程一旦顺序写错（例如先 `resources.closeAndAwait` 再 `sessions.closeAll`），空载用例照样全绿，而线上表现为"有长查询时停服把连接判为未归还、超时后强杀进程"。
- **建议**：
  1. `InFlight` 增加 spawn 用例：线程 A `await(5s)`，线程 B 延迟 50ms 后 `leave()`，断言 A 返回 `true` 且耗时 < 5s；
  2. `Server`/`Integration` 增加"打开游标 + 开启事务后 `stop()`"，用 `maxSize=1` 的池断言停止后连接已归还（见发现 6 的观测手段）；
  3. 补 `closeAndAwait` 的 `false` 与 `IllegalArgumentException` 两条；
  4. `lifecycle_test.sh` 改为前台启动并 `wait` 取退出码（或 `boot.sh stop` 后读 pidfile + `wait`），断言 `== 0` 并校验日志顺序。

#### [一般] 零并发用例：服务端全部共享状态只在单线程下验证

- **位置**：`fdbm/src/server/Handler_test.cj:215-230`（`twoConnectionsHaveIndependentSessions`）；`fdbm/src/server/InFlight.cj:36-46`；`fdbm/src/server/SessionRegistry.cj:46-58`；`fdbm/src/route/cache.cj:62-96`；`fdbm/test/e2e/client/src/main.cj:164-202`（单客户端串行）
- **描述**：
  全仓测试中 `spawn` 只出现 5 次，且全部是"起服务端"的夹具（`stub_fdbm_test.cj:47`、`stub_test.cj:39`、`Handler_test.cj:318`、`Integration_test.cj:210`、`Server_test.cj:179`），**没有一处让两个请求同时执行**。`twoConnectionsHaveIndependentSessions` 名为"两个连接"，实际是 A 发完、B 再发（`:221-224`）。因此：

  - `InFlight.enter/leave` 的并发增减（`AtomicInt64` + `Mutex` 组合）只在单线程计数 0→2→0；
  - `SessionRegistry.of()` 的"同 buffer 取或建"只在同线程连续调用；
  - `PartitionCache.put` 的容量判定与计数（`cache.cj:68-84`）虽整体在 `Mutex` 内，但只在单线程下验证过；并发写入时 `store` 的行为、`count_` 与落盘键数的一致性没有用例；
  - 设计 §12 明说"池 `maxSize` 需 ≥ 并发长查询数"，这条前提也没有任何用例测过并发长查询。

  对一个以"一条 TCP 一个会话 + 在途计数 + 周期巡检"为核心状态模型的中间件，这属于最大的结构性缺口。
- **建议**：补 3 条 spawn 用例（① 8 线程各发 N 次 CONSUME，结束后 `sessions.size()==0`、`InFlight.count()==0`；② 8 线程并发 `cache.put` 不同键，断言 `count() <= capacity`；③ 2 个连接同时打开游标，断言互不干扰且各自 `CURSOR_STATE` 独立）。e2e 可选加 `FDBM_E2E_CLIENTS=4` 并行客户端。

#### [一般] 启动自检负例覆盖 13/16 行，"配置错误 → 进程退出码 1"完全没测；`fdbm_sessionSweepInterval` 是唯一未做正数校验的时间参数

- **位置**：`fdbm/src/config/FdbmConfig.cj:296-322`（`sessionSweepInterval` 无校验；`shutdownTimeout`/`checkDuration`/`unavailableChecked` 有校验）、`:372-377`（validate 复检）、`:585-607`（`durationOf` 接受 0/负值）；`fdbm/src/config/FdbmConfig_test.cj:307-325`（只给正例 15/20s/45/5）；`fdbm/src/main.cj:30-41`；`fdbm/src/config/FdbmConfig_test.cj:449-459`
- **描述**：
  详细设计 §11 是"报错并结束进程"的清单，开发计划:59/278 要求"每条一个用例，断言 `FdbmException.code`"并"脚本化验证退出码非 0"。实际：

  - 已覆盖：驱动唯一性、坏库、分区缺 `__`、substr 规格缺失/非法 hash、权重后缀、逻辑库引用、未知算法、snowflake 序列号、sequence 分配库、节点地址、EXPORT 白名单；
  - 未覆盖：`checkDuration <= 0`、`unavailableChecked <= 0`、`shutdownTimeout <= 0 / Duration.Max`、自定义扩展与内置/自定义重名（§11 第 3 行）；另 `substr` 行的 `start < 0` / `length < 0`（`FdbmConfig.cj:441-443`）无负例；
  - `fdbm_sessionSweepInterval` 是唯一**既无校验也无负例**的时间键：`durationOf` 会把 `0`/负数原样返回，`SessionRegistry` 直接交给 `Timer.repeat(interval, interval)`（`SessionRegistry.cj:42`），配置成 0 可能形成忙轮询；
  - 全部用例都停在函数级，没有任何用例让 `main()` 以坏配置启动并断言"退出码 1 + 端口未监听"，而 `fdbm/README.md:70` 明确承诺"任一失败在接受连接之前报错退出"。
- **建议**：`FdbmConfig_test` 补 4 条负例（含自定义重名）；`getSessionSweepInterval` 加正数校验并写入 §11 表；新增 `fdbm/test/startup_failure_test.sh`：以缺驱动/坏端口/`fdbm_partition` 无 `__` 三种配置各启动一次，断言退出码 1、目标端口连接失败、日志含对应错误码。

#### [一般] 连接/游标的"归还"没有可观测断言，资源泄漏只能靠"后续还能跑"间接推断

- **位置**：`fdbm/src/resources/DatabaseResources.cj:164-187`（广播部分失败的连接清理）、`:226-241`（`closeAndAwait`）；用例侧 `fdbm/src/server/Integration_test.cj:88-105`、`fdbm/src/execute/Dispatcher_test.cj`（全部用例仅在 `finally` 里 `resources.close()`）
- **描述**：
  fdbm 侧没有任何用例读取连接池的活跃/空闲计数，也没有用 `maxSize=1` 制造"泄漏即失败"的强约束。因此：

  - "关闭游标归还连接"只由 `closeSendsUnsubscribeAndReleasesCursor`（`Integration_test.cj:88-105`）间接证明——它的夹具 `maxSize=4`，即使泄漏一根也照样能跑第二条查询；
  - `selectAllWrite` 在部分广播失败时关闭已借连接（`DatabaseResources.cj:176-185`）从未被执行：`FailingAccessor` 在 accessor 层抛错，绕过了 `DatabaseResources` 自己的 catch；
  - `Dispatcher_test` 的 `resources.close()` 只保证"不挂"，不证明归还。

  这与发现 3 的"停止时归还"是同一观测能力缺失的两面。
- **建议**：把夹具的 `maxSize` 设为 1 并循环"查询→关闭游标"超过 2 次（泄漏即第二次借不到）；补一条 `selectAllWrite` 部分失败用例（第 2 个池 `connect` 抛错，随后用同一 `maxSize=1` 池成功借到连接，证明第 1 根已归还）；若 `f_dbpool` 暴露统计（活跃/空闲），直接断言其归零更佳。

#### [轻微] 无 CI、无一键入口，三个模块的测试各自依赖不同的外部前提

- **位置**：仓库根（无 `.github/`/`.gitlab-ci.yml`、`scripts/` 下无测试入口）；`f_dbd/src/driver/DbdDriver.cj:53,108-117`（需 `dbd_driverName`）；`fdbm/test/e2e/run.sh:32-33`（需 `cjpm`、`CANGJIE_STDX_DYNAMIC_PATH` 与外部库）；`fdbm/test/lifecycle_test.sh:11-22`（需先 `build`+`install`）
- **描述**：370 条用例、两套真库 e2e 全部依赖人工按文档执行；`f_dbd` 在干净环境 `cjpm test` 会在包初始化阶段 `exit(1)`（R2 G3），`lifecycle_test.sh` 缺失前置时静默 `exit 0`。合入前无法用一条命令回答"这套改动是否破坏了测试"。
- **建议**：加根级 `scripts/test_all.sh`（依次 `f_dbd`（导出 `dbd_driverName=testdialect`）、`f_dbm`、`fdbm`，可选 `--e2e`），并接入 CI；`lifecycle_test.sh` 的 SKIP 改为 `exit 77` 或非零，避免"跳过"被当作"通过"。

#### [轻微] 分库缓存与 `boot.sh` 的边界分支缺用例

- **位置**：`fdbm/src/route/cache.cj:52-65`（关闭后 `get`/`put` 静默返回）、`:77-80`（`expire` 分支）、`fdbm/src/config/BootScriptWriter.cj:440-459`（临时文件 + rename）；用例 `fdbm/src/route/Route_test.cj:124-158`（只构造 `expire=None`）、`BootScriptWriter_test.cj`（无 `.tmp` 残留/原子性用例）、`fdbm/boot.sh:135-137,204-213`
- **描述**：`PartitionCache` 的容量与命中已有用例，但 `expire=Some(...)` 的过期语义、`close()` 之后 `get/put` 的"静默无效"语义无用例；`BootScriptWriter.writeAtomically` 的失败清理（`.tmp` 删除）与开发计划:67 ⑥ 无对应用例；`boot.sh` 的 `restart`、重复 `start`（`boot.sh:135-137`）、陈旧 pidfile 的 `status` 未覆盖。
- **建议**：`Route_test` 加一条 `expire=50ms` 的"写入→过期→未命中"；`BootScriptWriter_test` 加一条"目标目录只读 → 抛 `CONFIG` 且无 `.tmp` 残留"；`lifecycle_test.sh` 补 `restart` 与重复 `start` 的幂等断言。

#### [轻微] e2e README 宣称"读走 `fdbm_ro`"，但没有断言能区分读请求落在哪个账号

- **位置**：`fdbm/test/e2e/README.md:63`；`fdbm/test/e2e/lib.sh:78-79`（权重 `name0: w,1;r,0`、`name1: w,0;r,1`）；`fdbm/test/e2e/backends/postgres.sh:8-9,62-63`（两个账号）；`fdbm/test/e2e/client/src/main.cj`（全篇无读节点观测）
- **描述**：`fdbm_ro` 只授予 `SELECT`，因此"写落到读节点"会失败，但"读落到写节点"不会被任何断言发现；客户端也无法观测自己用了哪个账号。`DatabaseResources_test.zeroWeightsExcludeNodes` 只断言"读节点数量为 1"，不断言选中的是 `name1`（mockdb 单驱动下无法区分）。所以"读走 `fdbm_ro`"这条覆盖声明目前是**未验证**的。
- **建议**：给只读账号一条可观测探针（例如 client 先执行 `select current_user()` 并断言等于 `fdbm_ro`/`fdbm_rw`），或在 `backend_verify` 侧用只读账号写一条并期望权限错误，以证明读写确实分流。

#### [轻微] 夹具与用例混用 `*_test.cj` 命名，跨文件共享夹具造成隐式依赖

- **位置**：`f_dbd/src/driver/stub_fdbm_test.cj`（204 行，0 用例）、`f_dbd/src/driver/testkit_test.cj`（58 行，0 用例）、`f_dbd/src/multid/stub_test.cj`（77 行，0 用例）；`fdbm/src/server/Handler_test.cj:279`（`Harness` 定义）↔ `fdbm/src/server/Server_test.cj:64,85`（直接使用该 `Harness`）
- **描述**：三个 `*_test.cj` 不含任何 `@TestCase`，纯夹具却按"测试文件"命名，脚本化统计（本轮即需人工剔除）会把 f_dbd 的测试文件数从 18 虚报为 21；`Server_test` 的三个用例依赖 `Handler_test.cj` 里的 `Harness`，一旦按文件粒度拆分/裁剪协议用例，`Server_test` 会编译失败且原因不直观。
- **建议**：夹具改名为 `*_fixture.cj`/`testkit.cj`（仍会被 `cjpm test` 编译进测试包），或把 `Harness` 上提到独立的 `server_testkit_test.cj` 并在注释里说明它被哪些测试文件共享。

---

| 严重程度 | 数量 |
|---------|------|
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 4 |

### 总评

**规模与工程形态是健康的**：370 条 `@TestCase` / 1271 条断言 / 8541 行测试代码，对 11889 行实现；无空测试类、无 `@Ignore`/`@Skip`、无注释掉的用例；f_dbd 的连接/语句/事务/传输 33 例统一经进程内真实回环的 `StubFdbm` 驱动，fdbm 有 5 例"真客户端 ↔ 真服务 ↔ mockdb"的全栈用例，e2e 还额外用两个真实后端各跑约 150 条断言并逐库核对物理数据。断言普遍打在"线上报文 / 下推 SQL / 状态机"这类可观测行为上，而不是"能编译"，f_dbd 的游标不变量与 fdbm 的 `Dispatcher` 用例质量明显高于仓库平均。

**缺口不在数量而在分布**，且四个空白恰好都压在跨模块契约上：

1. **f_dbm 契约零测试，消费侧也没有一条正向用例**——扩展目录在全部 e2e 中恒为空，`CustomLoader` 只测空/坏目录，唯一涉及内置重名的用例（`Route_test.cj:113-116`）反而断言"自定义覆盖内置"。R2 在这一面发现的两个严重缺陷（`IdGeneratorException` 未映射、内置算法可被静默覆盖）之所以能存在，正是因为这条链路没有任何一条"实现 → 发现 → 注入 → 落库"的测试。这是本轮唯一按严重计的问题，也是修复 R2 严重项前必须先改的测试。
2. **列类型归一只有函数级用例、没有接线用例**（发现 2）。§9.6 是"客户端不认识方言拼写"这一决策的唯一实现点，却因为 mockdb 恒报仓颉名而在 190 条 fdbm 用例里从未真正执行。
3. **生命周期只测了"能停"，没测"怎么停"**（发现 3、6）：`InFlight` 的唤醒、`closeAll` 的释放、`closeAndAwait` 的超时、连接归还的观测全部缺位，进程级还拿不到退出码。
4. **并发是零覆盖**（发现 4）：在途计数、会话注册表、缓存容量这三处共享状态只在单线程下被验证过。

**建议的补齐优先级**：先做发现 1（改 `Route_test` 的错误断言 + 一条自定义 `.so` 的 e2e），因为它是 R2 两个严重项的验证载体；再做发现 3/6 用"`maxSize=1` 池"这一低成本强断言把归还与停止钉住；发现 2、5 各自只需 3–5 条表驱动用例，性价比最高；发现 4 需要引入 spawn，建议与 `InFlight` 唤醒用例一并完成。按此顺序补齐后，这套测试才配得上"f_dbware 主链路"的定位——当前的测试能证明"正常路径是对的"，尚不能证明"异常路径也是对的"。
