# 任务：修复 fdbm 栈评审缺陷并补齐回归

> **DoD（每个任务）**：① 先写失败用例（红，必须能复现 `todo.md` 描述的现象）→ 最小实现（绿）→ 重构；
> ② `cjpm test`（f_dbm / f_dbd / fdbm）全绿；③ `cjpm build` 无新增 warning；④ 行为与
> `doc/详细设计.md` 一致，偏差同提交改文档；⑤ 每个缺陷族独立提交（`AGENTS.md`：有单元测试后再提交）。
> 标注 `[e2e]` 的需要真实 PostgreSQL / MySQL（本机 5432 免密；MySQL 8.0.46 `127.0.0.1:13306`，root 空密码）。
> 证据列 `R{n}S/G` 对应 `reviews/202610210649_fdbm_stack_review/todo.md`。

## 0. 基线与去重确认

- [x] 0.1 记录三模块基线断言数：`f_dbm`（无测试）、`f_dbd`（`dbd_driverName=postgres` 下运行）、`fdbm`；
  若 `f_dbd` 在干净环境启动即退出，先按 P1/G03 的临时开关记录现象（作为红例证据）
- [x] 0.2 建立缺陷族到用例的映射表（`design.md` §2），确认 12 P0 + 29 P1 + 12 P2 无遗漏
- [x] 0.3 跑一次 `fdbm/test/e2e/run.sh`（postgres）与 `run.sh mysql`，记录基线断言数
  （2026-10-21 实测全绿：postgres client=108 / orm=28 / probe=2；mysql client=106 / orm=28 / probe=2）
- [x] 0.4 记录当前「逻辑库名 == 物理库名」的 e2e 配置（`backends/*.sh`），作为 D03 红例前提

## 1. P0 正确性（12 个缺陷族，红→绿成对提交）

### D01 流参数编码不再申请 EiB 内存（R1S1 / R2S1）

- [x] 1.1 红：`types_test.cj` —— 1 MiB `ByteBuffer`/自定义流经 `encodeParameter` 成功且字节一致；
  当前实现抛分配失败（用例须在修复前失败）
- [x] 1.2 红：`readChunk` 分块断言 —— 输出 200 KiB、单次 `read` 的 buffer 长度 ≤ 64 KiB，调用次数 ≥ 4
- [x] 1.3 绿：`readChunk` 每轮只分配 `min(remaining, 64 KiB)`；`encodeParameter` 用「读至 EOF」语义
- [x] 1.4 绿：读取异常包成 `DataException`，`DbdStatement.encode` 仍包 `CONVERSION`（新增 1 条用例）

### D02 流列整读与 `Unknown` 归 String（R1S2）

- [x] 1.5 红：`readData` 对 200 KiB 流列返回全部字节（当前只 64 KiB）
- [x] 1.6 红：`readData(typeName='weird_type')` 按 `String` 读，日志含原拼写
- [x] 1.7 绿：`readData` 增加 `Stream` / `Unknown` 显式分支，`match` 穷举、无 `_`

### D03 逻辑库命名空间隔离（R3S1 / R5S3 / R5G1 / R5G2 / R3G×3）

- [x] 1.8 红：`FdbmConfig_test.cj` —— `logical=app`、`physical=db0..db3` 时
  `logicalDatabases.keys == ['app']`（当前含 db0..db3）
- [x] 1.9 红：`settings` —— 默认库为 `app`；多逻辑库时取排序第一个逻辑名，绝不为物理名
- [x] 1.10 红：仅配 `fdbm_partition__orders='order,hash,id'`（无 `fdbm_db_logicalDatabase_order`）时启动成功，
  `catalog.physicals('order')` = 全部物理库（当前 `PARTITION_CONFIG`）
- [x] 1.11 红：`SHOW DATABASES` 返回逻辑库集合；`SHOW TABLES app` 成功，`SHOW TABLES nope` → `ROUTE_FAILED`
- [x] 1.12 红：`fdbm_sequenceDatabase='order'`（逻辑名）解析为 `order` 的首个物理库；未知值 → `ID_GENERATOR`
- [x] 1.13 绿：新增 `LogicalCatalog`（排序 names、physicals、default）；重写 `logicalDatabases()` 与
  `defaultDatabaseOf`；`validatePartitions`/`validateIdMaker`/`validate` 改用它
- [x] 1.14 绿：`ShowExecutor` 注入 catalog，按逻辑库解析内省库；`Dispatcher_test` 的物理名断言改为逻辑名
- [x] 1.15 `[e2e]` 改 e2e 部署：逻辑库 `app`，物理库 `db0..db3`；客户端断言未限定读写命中正确分片、
  `show databases` 只含 `app`（PG 123 / MySQL 121 断言；顺带修 `begin` 的 pin 目标未解析逻辑名）

### D04 事务 pin 的目标唯一性（R5S1 / R5S4）

- [x] 1.16 红：pin 下 `id in (1, 10000001)` 的 SELECT/UPDATE/DELETE 均 `ROUTE_FAILED`，
  且 `rowCount` 不翻倍（断言错误码与单目标结果；UPDATE 不再在同一库执行两次）
- [x] 1.17 红：pin 下 DDL → `ROUTE_FAILED`，不向任何库下发（当前同库重复执行并假成功）
- [x] 1.18 绿：`ensurePinnedTargets` 接入 SELECT/count/UPDATE/DELETE/取键五个调用点，DDL 在 pin 下内联拒绝
  （两处行为等价：都保证 pin 只允许单目标）
- [x] 1.19 回归：非 pin 下同样语句仍逐库执行并累加，`rowCount` 不变

### D05 广播范围收敛到逻辑库（R5S2）

- [x] 1.20 红：`app(db0,db1)` + `cfg(db2,db3)`，`app` 上无分库条件 SELECT 只触达 db0/db1；
  `count(*)` 不含 db2/db3（当前触达 4 个库）
- [x] 1.21 红：同一部署下 DDL 只改 db0/db1；`emptyOutcome` 取列信息也用 `app` 的库
- [x] 1.22 绿：`Unroutable`/`emptyOutcome`/`DdlExecutor`/`broadcastWrite` 统一经 catalog 解析 scope；
  未知逻辑库 → `ROUTE_FAILED`

### D06 参数→字面量白名单（R4S1）

- [x] 1.23 红：`DateTime` / 字节参数生成合法 SQL 且 mock 物理库按同名参数回读（当前为裸文本）
- [x] 1.24 红：`Duration`、`DataList`、`DataMap`、`DataUnit` 参数 → `CONVERSION`，物理库未收到语句
- [x] 1.25 绿：`ParameterBinder` 绑定期校验（错误含参数序号）；`SqlRenderer.literal(data, dialect!)` 白名单 +
  方言字节字面量；删除 `other => other.toString()`

### D07 数值字面量精度（R4S2）

- [x] 1.26 红：`12345678901234567890`、`123456789012345678.90`、负数三种输入的 `Decimal` 原值断言
- [x] 1.27 绿：`numberOf`/`negatedNumberOf` 改走 `DataReal(String)`；`Decimal.parse` 失败才 `Float64` 回退并 WARN

### D08 派生表形状覆盖 JOIN / UPDATE / DELETE（R4S3）

- [x] 1.28 红：三条语句（JOIN 派生表、`update ... join (select...)`、`delete ... join (select...)`）
  均 `UNSUPPORTED_SQL` 且含位置（当前放行）
- [x] 1.29 绿：`derivedTablesOf` 统计 from + joins；新增 `validateUpdateShape`/`validateDeleteShape`
- [x] 1.30 回归：合法 `update t join u on ...` / `select ... from a join b` 不受影响

### D09 内置名保护（R2S4 / R5G10 / R6S1）

- [x] 1.31 红：自定义名 `hash`（分区）/ `uuid`（ID）→ 启动失败（`PARTITION_CONFIG` / `CONFIG`）
- [x] 1.32 绿：`validatePartitions` / `validateIdMaker` 增加交集检查；工厂与 `IdMakers` 注释说明顺序
- [x] 1.33 反转 `Route_test.cj:113-116`：从「自定义覆盖 hash」改为「冲突拒绝」，并新增 `myhash` 正向用例

### D10 UUID v1/v6 时间戳与临时文件（R3S2）

- [x] 1.34 红：v1/v6 连续 1000 个 ID 的 `timestampNanos > 0` 且单调不减；`/tmp` 目录项数不增
- [x] 1.35 绿：进程级复用 `TimeBasedUUIDBuilder` + `registerSequenceGenerator()`；`Mutex` 内 `.serialSeq`
- [x] 1.36 红/绿：8 线程 × 200 个 ID 无重复、时间戳非零

### D11 ID 生成器能力与异常映射（R2S2）

- [x] 1.37 红：仅实现 `nextStringId` 的生成器配 `step` 表 → 落字符串 ID（当前 `INTERNAL`）
- [x] 1.38 红：两种方法都抛 `IdGeneratorException` → `ID_GENERATOR`；handler 直抛也映射 `ID_GENERATOR`
- [x] 1.39 绿：`idLiteral` 按期望类型尝试 + 失败回退另一方法；`FdbmHandler` 增加 `catch (IdGeneratorException)`

### D12 DbdUrl 字节下标与 `%XX`（R2S3 / R1G）

- [x] 1.40 红：中文用户名/口令/库名 URL 解析正确且 `parse(toUrl(x))` 往返相等；`%FF` → `CONFIG`
- [x] 1.41 红：`fdbm://u:密@host:9000/db` 的 `password == '密'`（当前为 `密@h`）
- [x] 1.42 绿：删除 `take`/`countOf`，改用字节切片；`percentDecode` 字节级 + `String.fromUtf8` + 非法/残缺 → `CONFIG`；
  `database` 也解码

## 2. P1 文档 / 配置 / 生命周期（29 项）

### 2.1 配置与文档口径

- [x] 2.1 红/绿 G01：非法、`0`、负数超时都保留原值并 WARN（`DbdOptions` 单测 3 条）
- [x] 2.2 红/绿 G02：根包重导出与 `fdBDVersion()`；`Reexport_test.cj` 断言 `DbdUrl`/`DbdException`/`MultiDUrl`
  可从 `fountain::f_dbd` 直接取到；删除「阶段 0」注释
- [x] 2.3 红/绿 G03：`dbd_driverName` 未配置时 `DbdDriver()` 抛 `CONFIG`（进程不退出）；`static init` 只注册不退出；
  配置了 `postgres` 时注册 `postgres` 且 `fdbm` 兼容别名可用
- [x] 2.4 G03 文档：`f_dbd/README{,_en}.md`、`详细设计.md` §5.2、`spec.md`、类注释统一「注册名 = 后端方言名」
- [x] 2.5 红/绿 G29：`fdbm_sessionSweepInterval` 为 `0`/负数/`Duration.Max` → `CONFIG`

### 2.2 协议语义补强（f_dbd）

- [x] 2.6 红/绿 G04：NULL 流列 `getOrNull<InputStream>` → `None`；非 NULL → 首块可直接读出；
  旧服务端（`-1` 当 `<=0`）下退化为空流但不报错
- [x] 2.7 红/绿 G05：流列 `get<Array<Byte>>` / `get<String>` → `CONVERSION`，不发列读请求
- [x] 2.8 红/绿 G06：节点池已关闭 → `CONFIG`（不依赖消息文本），池耗尽 → `TIMEOUT`；改消息文本后用例仍绿

### 2.3 资源与生命周期

- [x] 2.9 红/绿 G14：注入构造失败（驱动缺失/某节点不可连）后，已建缓存与池全部关闭（用可观测的 close 计数/后续可重开证明）
- [x] 2.10 红/绿 G12：监听失败（端口占用）→ `main` 返回 1；正常停止时不误报
- [x] 2.11 红/绿 G13：`closeAndAwait` 返回 `false` 时有 WARN 且含池名；`stop()` 记录结果
- [x] 2.12 红/绿 G23：`show tables` 在 `prepareStatement`/`query` 抛错后连接可再次借出（`maxSize=1`）
- [x] 2.13 红/绿 G26：`begin` 失败后 `pinned == None`；`commit` 的 `finally` 先解 pin 再 close

### 2.4 并发安全

- [x] 2.14 红/绿 G11：两线程各 100 次 `export set+flush` 后文件内容为最后一次写入的并集，无 `CONFIG`/ENOENT
- [x] 2.15 红/绿 G16：`sweep` 与在途请求并发 100 轮，无「归还后再 close」「游标泄漏」；`closeAll` 后新游标立即关闭
- [x] 2.16 红/绿 G15：`put` 与 `close` 并发 1000 次无 panic；关闭后 `get`/`put` → `CACHE`
  - 用例暴露并修复了 `PartitionCache` 的关闭竞态：`get`/`put`/`remove` 与 `close` 共用同一把锁，
    避免检查通过后 store 被关闭而抛非 `CACHE` 异常
- [x] 2.17 红/绿 G28：`segment.result.next()` 抛异常后 `cell()` → `CURSOR_STATE`（不再返回上一行）

### 2.5 错误码与启动自检

- [x] 2.18 红/绿 G07：池耗尽/借连接失败 → `TIMEOUT`；资源已关闭 → `CONFIG`（`DatabaseResources` 单测）
- [x] 2.19 红/绿 G08：`fdbm_global__dict='cfg'`（未配置逻辑库且非物理库）→ 启动失败；合法逻辑库通过
- [x] 2.20 红/绿 G09：`sequence` 且分配库无 `fountain_sequence` 表 → `ID_GENERATOR`，不监听
- [x] 2.21 红/绿 G10：同键区块内外并存时区块内优先并 WARN；区块外行保留在区块外
- [x] 2.22 红/绿 G27：跨逻辑库同列同算法但分片空间不同 → `Unroutable`（信息列两表库名），不再 `Empty`

### 2.6 SQL 语义

- [x] 2.23 红/绿 G17：`where id in (select ...)`、`where exists (select ...)`、`select (select ...)` → `UNSUPPORTED_SQL`
- [x] 2.24 红/绿 G18：`select id as "order" from "shop"."T" as "select"` 与 `select t."COL" from t`
  的 `parse → render → parse` 闭合；表名不再被一起引用
- [x] 2.25 红/绿 G19：`WHERE ID = 5`、`INSERT INTO t (ID) VALUES (5)` 可路由；规则查找大小写不敏感
- [x] 2.26 红/绿 G20：`from users u where u.id = 5` 的路由为 `Single`（路由层传入限定符集合）
- [x] 2.27 红/绿 G21：以 `\` 结尾与含 `\'` 的 MySQL 字符串参数生成可闭合字面量
- [x] 2.28 红/绿 G22：`select * from app.t where id = 1001` 下推 SQL 不含 `app.`，目标为 db1
- [x] 2.29 红/绿 G24：同库 3 行 INSERT 中第 3 行失败 → 前 2 行回滚（`rowCount` 与物理库状态一致）；
  跨库分组时按组回滚并返回 `DB_ERROR`（列出已提交库）
- [x] 2.30 G25 **记录不修**：文档 §9.4 写明「全局表写在事务内走独立连接、各自提交」；首次发生时 WARN；
  新增用例固定该行为（`begin` 后写全局表 → 物理库为独立连接、`rollback` 不撤销）
  （单测 globalWriteInsideTransactionUsesIndependentConnections + e2e「global write survives rollback」）

## 3. P2 测试完整性（12 个工作流）

- [x] 3.1 T01 `f_dbm` 单测：`IdGenerator` 两个默认方法各抛 `IdGeneratorException` 且 `message` 含生成器名；
  `PartitionAlgorithm` 实现的稳定性用测试替身证明（不要求库提供默认实现）
- [x] 3.2 T02 清理无效测试：删/改 `nullShortCircuit`（改为断言各 `T` 的 `shortCircuitOf` 结果而非计时）、
  `dbd_test.cj` 占位用例改为重导出断言、`encodeParameterUnsupportedTypeThrows` 改名并真正覆盖
  `types.cj:454`（用一个不实现 `ToData` 的类型探针）
- [x] 3.3 T03 类型矩阵：`encodeParameter` 覆盖 §8 全部标量 + 字节 + 集合；`readData` 覆盖全部
  `SqlReadType`；`QueryResultImpl.get<T>` 覆盖 16 个具体类型 + `Rune`
- [x] 3.4 T04 并发：`InFlight.leave` 唤醒阻塞中的 `await`（`true`）；`SessionRegistry.of` 并发同 buffer 只建一个会话；
  `PartitionCache` 并发 `put` 后 `count()` 与落盘键数一致；两个请求同时执行互不阻塞
- [x] 3.5 T05 优雅停止：`closeAll` 释放游标与 pin；`closeAndAwait` 有借用 + 1 ms → `false`；
  `Zero`/`Max` → `IllegalArgumentException`；顺序用例（先关会话再关池）
- [x] 3.6 T06 列类型归一：mockdb 只报 `int4` / `TINYINT(1)` / `bytea`，断言 RESP 首包为
  `Int32` / `Bool` / `Array<Byte>`；`columnsOf` 被改成透传时用例必须失败
- [x] 3.7 T07 自定义扩展 e2e：构建真实 `.so`（实现 `PartitionAlgorithm` + `IdGenerator`）放入 `custom/`，
  断言落点与 ID 类型；同名 `hash` 启动失败；扩展只实现一种 ID 能力可用
- [x] 3.8 T08 启动自检负例全表：按 §11 每行一条（含 `checkDuration` / `unavailableChecked` /
  `shutdownTimeout` / `substr start,length<0` / 内置名冲突 / 全局表逻辑库 / sequence 表）；
  另加进程级用例：坏配置启动 → 退出码 1 且端口未监听
- [x] 3.9 T09 连接归还断言：`maxSize=1` 下「关游标后继续查询」「returning 后继续查询」「DDL 失败后继续查询」
  「广播部分失败后继续查询」均成功（泄漏即超时）
- [x] 3.10 T10 `f_dbd` 公开行为缺口：`parameterColumnInfos` 为空（按设计固定）、`close()` 后 `query/update` →
  `CURSOR_STATE`、`update()` 载荷不符 → `PROTOCOL`、`update_timeout` 生效、`setSqlDbType` 的 `case _` →
  `CONVERSION` 与 `SqlBlob`/`SqlClob`、未 `begin` 的 `save/rollback(name)/release` → `TX_STATE`、
  `requestBlock` 解不出字节 → `CONVERSION`、`runeOf` 多字符/空串 → `CONVERSION`、`read(空 buffer)` → 0、
  `DbdOptions.copy()` 隔离
- [x] 3.11 T11 DbdUrl 矩阵：ASCII + 中文 + `%40`/`%3A`/`%2F`/`%FF` + IPv6 + 缺端口 + 空库 + 往返
- [x] 3.12 T12 流列/流参数矩阵：跨 3 块顺序读、短块非 EOF、行切换失效、`fetch_rows=7`、
  1 MiB 参数、NULL 流、标量读 `CONVERSION`

## 4. 文档、验收与提交

- [x] 4.1 `fdbm/doc/详细设计.md`：§3.1（逻辑库/默认库/sequenceDatabase）、§3.5（normalize 优先级、并发）、
  §5（池异常映射）、§6.2（维度与广播范围）、§7（UUID、生成器能力）、§8.1/§8.2（字面量白名单、精度、
  派生表形状、引用符、大小写、别名、限定符）、§9.1–§9.6、§10.1/§10.3/§10.4、§11（自检全表）
- [x] 4.2 `f_dbd/doc/详细设计.md`：§3.6/§3.9/§3.10（`-1` 探测、整读、NULL）、§5.1（字节下标、解码）、
  §5.2（注册名与不退出）、§5.5（流参数）、§6.4（关闭/超时判定）
- [x] 4.3 `f_dbm/README{,_en}.md`：能力协商（只实现一种合法）、内置名不可覆盖、异常类型；
  新建 `f_dbm/doc/` 说明目录时同步 `cjpm.toml` 的 `include`
- [x] 4.4 `fdbm/doc/开发计划.md` / `f_dbd/doc/开发计划.md`：勾掉对应交付项，补本次新增验收项
- [x] 4.5 三个 README 的驱动名、逻辑库、SHOW、流列、NULL 口径与代码一致
- [x] 4.6 全量验收：三模块 `cjpm test`、`[e2e]` 两后端、`f_orm` 回归、`cjpm build` 无新增 warning

  - 结果：`f_dbm` 5/5、`fdbm` 244/244、`f_dbd` 208/208；`cjpm build` 无新增 warning（三模块各有基线 warning）。
  - e2e：PostgreSQL `126+28+13`、MySQL `124+28+10`，全部 `failures=0`。
  - `f_orm` 64 例中 1 例 `QueryResultWrapTest.testEveryReaderBranchAndAlias` 报 `bytea → Array<UInt8>` 类型不匹配；
    `f_orm` 本次零改动（`git status` 干净），该失败在基线提交即存在，按约束不修，记录为已知问题。
- [x] 4.7 按缺陷族分批 `git commit`（D01…D12 / P1 分组 / P2 分组），最后 `CHANGELOG` 汇总已知变更

## 5. 一般项处置索引（51 条逐条可追溯）

完整的 51 行逐条处置表见 `design.md` 附录 A（序号与 `todo.md` 一般条目顺序一一对应）。归纳：

| 处置 | 条目数 | 去向 |
| --- | --- | --- |
| 修复（P1 缺陷族） | 33 | G01–G29（其中 G03 吸收 3 条、G07 吸收 2 条、G16 吸收 2 条、G18 吸收 2 条） |
| 并入 P0 族 | 8 | D03×5、D09×2、D12×1 |
| 补测试（P2） | 9 | T01、T10、T02×2、T03、T06、T05、T04、T09 |
| 记录不修 | 1 | G25（R5G5）：无 2PC，文档化 + WARN + 用例固定（任务 2.30） |

任一 P1 任务被裁剪时，必须在 PR 说明中引用附录 A 的行号并改写「处置」列，不得静默跳过。
