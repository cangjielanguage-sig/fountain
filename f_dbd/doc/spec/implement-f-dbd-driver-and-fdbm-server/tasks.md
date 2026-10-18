# 任务：实现 f_dbd 驱动与 fdbm 服务端（TDD）

> 每个任务都是「先写失败用例（红）→ 最小实现（绿）→ 重构」。用例位置与逐成员步骤分别见 `f_dbd/doc/开发计划.md` 与 `fdbm/doc/开发计划.md`；本文件只给**顺序、门禁与跨模块接线任务**。
> **DoD（每个任务）**：① 对应用例全绿；② `cjpm build` 无新增 warning；③ 详细设计中对应的"必须固化的不变量"有用例覆盖；④ 与文档出现偏差时同提交改文档；⑤ 提交前统一 LF。

## 1. 文档口径对齐（阻塞后续全部实现）

- [x] 1.1 改写 `fdbm/doc/详细设计.md` §9.1：删除 `QueryCursor.hasData` 与"构造即预取第一行"；游标规则改为"每次 `NEXT_ROW` 执行一次物理 `next()` 并重建/清空当前行缓冲"
- [x] 1.2 改写 `fdbm/doc/详细设计.md` §9.2：删除 `ExecutionOutcome.hasData`
- [x] 1.3 改写 `fdbm/doc/详细设计.md` §10.2 请求处理表：`CLOSE_CURSOR → DataNone` 改为 `UNSUBSCRIBE(QueryResultClosePayload) → ACK`（含 qid 幂等规则），并同步 §13 不变量 2
- [x] 1.4 检查 `fdbm/doc/详细设计.md` §12 取舍表与 §9.4/§9.6 中一切与预取/`hasData` 相关的措辞，统一到新口径
- [x] 1.5 改写 `fdbm/doc/开发计划.md` Step 7.1：删除"构造即预取第一行""跨段预取 `hasData`"，改为逐 `NEXT_ROW` 推进 + 当前行缓冲用例（含流列句柄只打开一次的计数断言）
- [x] 1.6 改写 `fdbm/doc/开发计划.md` Step 8.1：删除"首行预取契约"与 `CLOSE_CURSOR` 用例，改为 `UNSUBSCRIBE(qid) → ACK` 时序、qid 不匹配幂等 ACK、关闭后列读/推进回 `CURSOR_STATE`
- [x] 1.7 改写 `f_dbd/doc/开发计划.md` Step 1.3：`QueryResultServerPayload` 去掉 `hasData`（`init(columnInfos)` 单参）
- [x] 1.8 改写 `f_dbd/doc/开发计划.md` Step 1.4：删除 `CLOSE_CURSOR(-2)` 常量与 `closeCursor()` 工厂，改为 `QueryResultClosePayload` 相关用例
- [x] 1.9 改写 `f_dbd/doc/开发计划.md` Step 1.9：删除"首包 `hasData` 决定首次 `next()`"与"同列二次访问不发请求（行缓存）"，改为"首次 `next()` 即发 `NEXT_ROW`""重复 `get` 重复发包（服务端当前行缓冲应答）"；关闭用例改为 `close()` 发 `UNSUBSCRIBE`
- [x] 1.10 改写 `f_dbd/doc/开发计划.md` Step 3.5 / 3.7：请求序列断言去掉 `CLOSE_CURSOR(-2)`，改为 `UNSUBSCRIBE(qid) → ACK`；并补充"连接上有未关闭结果集时任何 SQL/事务方法被拒"的用例
- [x] 1.11 在 `fdbm/doc/详细设计.md` §9.1 增补"当前行缓冲"的口径说明（惰性填充、随行失效、流列缓存句柄），与 `design.md` D3 一致

## 2. `f_protocol`：带载荷的 UNSUBSCRIBE 构造器

- [x] 2.1 红：新增 `Message_unsubscribe_test.cj` —— 载荷保真、自动生成 `MessageID`、连续两次调用 id 不同
- [x] 2.2 红：既有 `unsubscribe(id)` / `unsubscribe(id, data!)` 行为不变的回归用例；三个重载共存无歧义
- [x] 2.3 绿：在 `f_protocol/src/default/Message.cj` 新增 `public static func unsubscribe<T>(data!: T): Message where T <: ToData { build<T>(UNSUBSCRIBE, data) }`
- [x] 2.4 全模块 `cjpm test` 全绿（既有 f_rpc 等调用方不受影响）

## 3. `f_dbd` 阶段 0：模块与包骨架

- [x] 3.1 红：`src/dbd_test.cj` 平凡用例（断言 `FountainVersion` 非空），证明 `cjpm test` 可跑
- [x] 3.2 绿：`src/dbd.cj`、`src/common/`、`src/exception/`、`src/driver/`、`src/multid/` 各放最小占位，`cjpm build` 通过
- [x] 3.3 确认 `f_dbd/cjpm.toml` 的 `[test-dependencies]` 已含 `f_mockdb`（当前已有；缺则补）

## 4. `f_dbd` 阶段 1：`fountain::f_dbd.common`

- [x] 4.1 Step 1.1 `SqlPayload`（含"params 必须 var"的往返回归用例）
- [x] 4.2 Step 1.2 `UpdateResultPayload`（键集合恰好 `{rc, liid}` 的 `@DataExclude` 回归）
- [x] 4.3 Step 1.3 `QueryResultServerPayload`（**仅列信息，无 `hasData`**）
- [x] 4.4 Step 1.4 `QueryResultColumnPayload` + 常量（`NEXT_ROW`、`DEFAULT_PORT`、`DEFAULT_STREAM_CHUNK`、`CELL_READ_FLAG` 位组合钉死）
- [x] 4.5 Step 1.5 `ColumnInfoImpl`（键集合恰好 `{nm, tn, len, scl, nl, ds}`）
- [x] 4.6 Step 1.6 `DbdErrorCode` / `DbdErrorPayload`
- [x] 4.7 Step 1.7 `decodeStrict<T>`（四类正例 + 交叉负例 + 越界仍命中且不抛 `OverflowException`）
- [x] 4.8 Step 1.8 `SqlTypes`（`readType` / `canonicalName` / `readData` / `readStream` / `readChunk` / `encodeParameter` / `decode` 全套，B 口径）
- [x] 4.9 §3.6.1 `QueryResultClosePayload`（`qid` 字段与往返）
- [x] 4.10 **【阻塞门禁】性能前置实验**：在 `src/common/*_perf_test.cj` 实测候选 A（`TypeInfo` + `isSubtypeOf`）与候选 B（`None<T>` + `match case _: ?X`），按 `f_dbd/doc/详细设计.md` §10.1 的用例矩阵/预热/计时/判定规则执行
- [x] 4.11 实验结论回写 `f_dbd/doc/详细设计.md` §3.10（实现口径）与 §10.1（结果表 + 日期），与代码同提交

  > 落地：`src/common/dispatch_perf_test.cj`（`GetDispatchPerfTest`）。结论：**候选 B 胜出**（38 个测量点全部优于 A，合计均值 1958 → 117 ns/次）；因 B 的精确匹配认不出 `InputStream` 的实现类，按 §10.1「不得仅凭速度选 B」补**接口子类型兜底**（仅在冷路径用一次 `TypeInfo.of<T>()`）。
- [x] 4.12 Step 1.9 `QueryResultImpl <: QueryResult`（桩发送器 + 桩 closer）：无预读、无缓存、终态、`CURSOR_STATE`、关闭握手、八条游标一致性规则

  > 落地：`src/common/result.cj` + `src/common/result_test.cj`（19 条）。两点实现偏差已按"与文档偏差同提交改文档"登记进 §3.10：① 流列句柄按列索引复用（同一行同一列返回同一 `DbdInputStream`）；② `get<InputStream>` 不发列读请求（首次 `read` 才发块请求）。

- [x] 4.13 Step 1.10 `DbdInputStream`（多块顺序、短块非 EOF、随行失效、`bufSize`）

  > 落地：同文件（9 条）。偏差已登记进 §3.11：收到空块后进入 EOF 终态，之后 `read` 返回 0 且不再发包。

## 5. `f_dbd` 阶段 2：`fountain::f_dbd.exception`

- [x] 5.1 红→绿：`DbdException` 实现体放 `src/common/DbdException.cj`（两个构造器、`code`/`cause` 属性）；`src/exception/` 只放 `public import fountain::f_dbd.common.DbdException` 重导出

  > 提前到 4.12 之前落地：`QueryResultImpl` / `DbdInputStream` 都要抛它，属于硬前置依赖。

- [x] 5.2 验收：`import fountain::f_dbd.exception.*` 与 `import fountain::f_dbd.common.*` 拿到同一类型；`let e: SqlException = DbdException(...)` 编译通过；`cjpm build` 无 `cyclic dependency`

## 6. `f_dbd` 阶段 3：`fountain::f_dbd.driver`（单节点）

- [x] 6.1 Step 3.1 `DbdUrl`（% 编码往返、缺省端口、非法 → `CONFIG`）
- [x] 6.2 Step 3.4 `DbdTransport`（`request` / `unsubscribe`、超时置 `Broken`、`ERROR` 映射、非预期命令 → `PROTOCOL`）
- [x] 6.3 Step 3.2 `DbdDriver`（`static init` 注册 `fdbm`、元数据）
- [x] 6.4 Step 3.3 `DbdDatasource`（`connect` 才建链、选项表、幂等 `close`）
- [x] 6.5 Step 3.5 `DbdConnection`（状态机、`prepareStatement`、`getMetaData` 不含密码、**连接级 `activeResult` 独占**）
- [x] 6.6 Step 3.6 `DbdStatement`（`set<T>` 运行时判定、空洞参数、`query` / `update`、执行前的结果集独占检查、deprecated 重载）
- [x] 6.7 Step 3.7 结果集接线（真实发送路径的请求序列断言：**无 `CLOSE_CURSOR`**，关闭为 `UNSUBSCRIBE(qid)`）
- [x] 6.8 Step 3.8 流列端到端（3 块分块读、行切换失效、`fetch_rows` 生效）
- [x] 6.9 Step 3.9 `DbdTransaction`（透传语句、状态错误、savepoint 名注入防护、与结果集互斥）

## 7. `f_dbd` 阶段 4：`fountain::f_dbd.multid`

- [x] 7.1 Step 4.1 `MultiDConfig`（14 个 `get*` 默认值与权重解析）
- [x] 7.2 Step 4.2 `MultiDUrl`（多节点解析、`multidbm://` 与 `multidbd://` 双 scheme）
- [x] 7.3 Step 4.3 `MultiD`（注册名 `multidbd`、`preferredPooling = false`）
- [x] 7.4 Step 4.4 `MultiDatasource`（每节点一池、权重分布、只有首节点有权重时全落首节点、池关闭/耗尽的错误码、不等待池内部任务）

## 8. `fdbm` 阶段 0：模块与包骨架

- [x] 8.1 **前置验证**：补 `[test-dependencies]`（`f_mockdb`），**实跑 `cjpm test` 确认 executable 模块可测**；不支持则改为"同模块动态子模块 + 薄 `main`"并把偏差登记进详细设计
- [x] 8.2 红→绿：`src/main_test.cj` 平凡用例；`main()` 直接 `FdbmServer(FdbmSettings.load()).start()`（无子命令），捕获 `FdbmException` → 记 ERROR 并 `return 1`
- [x] 8.3 验收：`cjpm build` 产出可执行文件；`cjpm install` 后命令行直接执行 `fdbm` 能启动到配置校验

  > 实测：`cjpm build` 的本地产物是 `target/release/bin/main`；`cjpm install` 按**模块名**安装为 `fdbm`（`install` 默认名取 package.name，无需 `--name`）。运行需 `LD_LIBRARY_PATH` 同时含安装的 `libs/fdbm`、SDK 运行时库与 `stdx` 动态库（见 §10.5）。

## 9. `fdbm` 阶段 1：`fountain::fdbm.config`

- [x] 9.1 Step 1.1 配置模型（`DatabaseNodeConfig.url`、`LoadBalanceConfig.weight`、权重容错、默认值）
- [x] 9.2 Step 1.2 `FdbmConfig` 各 `get*` + `validate`（设计 §11 启动自检清单逐条负例）
- [x] 9.3 Step 1.3 `BootScriptWriter`（分块/排序/逐键注释、转义、原子写与权限、幂等、`normalize()` 自动整理与"不补默认值"、失败不阻塞启动、日志不含敏感值）

  > 偏差：`std.fs.FileInfo` 只暴露可读/可写/可执行三组权限，无法复制完整 mode 位；`flush` 保留可执行位，其余位按新文件默认值。已登记进 `详细设计.md`。另：配置读取抽象出 `ConfigSource`，负例用例注入 `MapConfigSource`，避免污染全局 `Config`（无删除接口）。

## 10. `fdbm` 阶段 2：`fountain::fdbm.exception`

- [x] 10.1 红→绿：`FdbmException` 三个构造器与 `code` 属性（携带 `DbdErrorCode`）

## 11. `fdbm` 阶段 3：`fountain::fdbm.sql`

- [x] 11.1 Step 3.1 词法与 AST 基本类型
- [x] 11.2 Step 3.2 `SqlParser.parse`（SELECT/INSERT/UPDATE/DELETE/SHOW/DDL/EXPORT 表驱动 + `SQL_SYNTAX` 与 `UNSUPPORTED_SQL` 区分）
- [x] 11.3 Step 3.2 `parseSessionCtl`（会话控制快速识别，非会话语句返回 `None`）
- [x] 11.4 Step 3.3 `ParameterBinder.bind`（顺序替换、个数不符 → `PROTOCOL`）
- [x] 11.5 Step 3.4 `PartitionKeyExtractor.extract` / `extractRange`（等值/IN/范围；保守规则）
- [x] 11.6 Step 3.5 `SqlRenderer.render`（parse→render→parse 往返稳定）

## 12. `fdbm` 阶段 4：`fountain::fdbm.resources`

- [x] 12.1 Step 4.1 `NodeAccessor` 与 `FakeNodeAccessor`（记录下推 SQL/参数/池名/广播次数；`f_mockdb` 建真实池）
- [x] 12.2 Step 4.2 `DatabaseResources`（每 `<host:port + 库>` 一池、读写节点注册与权重选择、无节点 → `ROUTE_FAILED`、`closeAndAwait` 边界）

## 13. `fdbm` 阶段 5：`fountain::fdbm.route`

- [x] 13.1 Step 5.1 七种 `PartitionAlgorithm`（含 `StepPartition` 有效域越界拒绝、`SubstringPartition` 按码点切分与五种 hash、`PartitionAlgorithmFactory`）
- [x] 13.2 Step 5.2 `PartitionRouter`（五态、JOIN 收敛、范围路由仅 `step`、等值+范围交叉过滤）
- [x] 13.3 Step 5.3 `PartitionCache`（键/值格式、过期、容量上限停写、指向不存在库即失效）
- [x] 13.4 Step 5.4 `GlobalTableRouter`

## 14. `fdbm` 阶段 6：`fountain::fdbm.idmaker`

- [x] 14.1 `IdGenerator` 默认实现与 `IdGeneratorException`（接口在 `f_dbm`，用例在 f_dbm；fdbm 只测实现）
- [x] 14.2 `UuidIdGenerator` / `SnowflakeIdGenerator` / `SequenceIdGenerator`（含唯一性、并发、配置非法即报错、只在分配库取号）
- [x] 14.3 `IdMakers.forTable`（唯一入口；`uuid`/`snowflake` 忽略表维度，`sequence` 按 `(逻辑库, 表)` 隔离）

## 15. `fdbm` 阶段 7：`fountain::fdbm.execute`

- [x] 15.1 Step 7.1 `DbdSession` / `PinnedConnection` / `QueryCursor`：**无预读**（逐 `NEXT_ROW` 推进）、当前行缓冲（流句柄只打开 1 次）、多段串联（行序=库序、任一段打开失败整体失败）、`close()` 归还连接
- [x] 15.2 Step 7.1 游标 `qid`：创建游标时记录查询 CONSUME 的 `Message.id.toString()`，供 `UNSUBSCRIBE` 匹配
- [x] 15.3 Step 7.2 `ExecutorDispatcher.execute`（会话控制分流 → parse → bind → 分发）
- [x] 15.4 Step 7.3 `SelectExecutor`（路由五态、多段合并、**列类型归一回归**）
- [ ] 15.5 Step 7.3 `InsertExecutor`（多行按行路由、ID 回填后再路由、`insert…select` 拆解）
- [x] 15.6 Step 7.3 `UpdateExecutor`（`rowCount` 求和、缺分库条件不下推、缓存失效联动）
- [x] 15.7 Step 7.3 `DeleteExecutor`（查键 → 删除 → 删缓存的三步顺序）
- [ ] 15.8 Step 7.3 `ShowExecutor`（方言分支、未支持驱动 → `UNSUPPORTED_SQL`）
- [x] 15.9 Step 7.3 `DdlExecutor`（广播、部分失败列出成功/失败库）
- [ ] 15.10 Step 7.3 `ExportExecutor`（白名单校验、落盘、响应）
- [x] 15.11 Step 7.3 `SessionCtlExecutor`（pin/解 pin、read-your-writes、未 begin 的 `commit`/`rollback` → `TX_STATE`）

## 16. `fdbm` 阶段 8：`fountain::fdbm.server`

- [ ] 16.1 Step 8.1 `FdbmHandler.handle`（回环连接驱动）：三类请求判别、必有回包、无游标 → `CURSOR_STATE`、`UNSUBSCRIBE` 幂等 ACK、会话绑定
- [ ] 16.2 Step 8.2 `SessionRegistry`（同连接同会话、巡检回收）与 `InFlight`（计数、`await` 超时）
- [ ] 16.3 Step 8.3 `DriverLoader`（唯一驱动、驱动名一致性、`NO_DRIVER`）
- [ ] 16.4 `CustomLoader` 与 `CustomExtensions`（目录不存在=空、加载失败=`CONFIG`、内置/自定义 `name` 冲突拒绝、`initialize()` 先于资源创建）
- [ ] 16.5 Step 8.4 `FdbmServer`（启动顺序、`stop()` 顺序与幂等、自检负例退出码、`main()` 退出码）
- [ ] 16.6 优雅停止（SIGTERM）：仅 Linux/macOS 的脚本用例，校验退出码 0 与资源释放顺序

## 17. 集成、端到端与收尾

- [ ] 17.1 `fdbm` 阶段 9：`boot.sh`（配置区 + `start/status/stop/restart`）实跑
- [ ] 17.2 f_dbd ↔ fdbm 集成：起本地 fdbm（`f_mockdb` 驱动、两节点两库），用 f_dbd 跑建表/插入/分库查询/更新/删除/事务/流列/`show databases`/`show tables`/`export`
- [ ] 17.3 关闭握手端到端：`close()` 的 `UNSUBSCRIBE(qid) → ACK` 真实时序；断链场景下 `CURSOR_STATE` fail-fast
- [ ] 17.4 缓存与重启：缓存文件格式核对；重启后命中缓存（不重算）
- [ ] 17.5 `f_dbd` 阶段 5：f_orm 集成（`fdemo` 的 `orm_drivers` 指向 `fdbm`）、断链恢复
- [ ] 17.6 文档回填：新增/补齐 `f_dbd`、`fdbm`、`f_dbm` 的中英 README（至少 B 口径、关闭走 `UNSUBSCRIBE`、`fdbm` 的 `cjpm install` 部署方式与动态库搜索路径）
- [ ] 17.7 全量 `cjpm test` 与 `cjpm build` 无新增 warning；**不合并、不删除 `feature/dbware` 分支与工作树**（仓库有其他并行工作线），交付保持当前 worktree
