## ADDED Requirements


### Requirement: 请求种类判别与必有回包（MUST）

本要求为强制要求（MUST）。

服务端用 `decodeStrict<SqlPayload>` → `decodeStrict<QueryResultColumnPayload>` 判别 `CONSUME` 载荷；`UNSUBSCRIBE` 由 `Command` 直接识别、载荷按 `decodeStrict<QueryResultClosePayload>` 解。任何分支都必须回包（`RESP` / `ACK` / `ERROR`）。

#### Scenario: 三类请求各自命中

- **GIVEN** 三种合法载荷的请求
- **WHEN** 到达服务端
- **THEN** 分别进入 SQL 执行、游标操作、关闭游标三条路径

#### Scenario: 非 CONSUME/UNSUBSCRIBE 与无法判别

- **GIVEN** 命令不是 `CONSUME` 或 `UNSUBSCRIBE` 的请求，或两种载荷都判别失败的请求
- **WHEN** 到达服务端
- **THEN** 回 `ERROR(PROTOCOL)`，并记录命令与载荷类型

#### Scenario: 异常不得穿透

- **GIVEN** 执行过程中抛出 `FdbmException` / `SqlException` / 任意其它异常
- **WHEN** 处理该请求
- **THEN** 回 `ERROR` 且 `DbdErrorPayload` 的 `code` 正确（`SqlException` 映射为 `DB_ERROR` 并透传 `sqlState`），连接保持可用

### Requirement: 查询不预读，首包只带列信息（MUST）

本要求为强制要求（MUST）。

执行 `query()` 后服务端**不预取任何行**；首包 `QueryResultServerPayload` 只含列信息，**不含** `hasData` 或任何行状态字段。

#### Scenario: 首包不含行状态

- **GIVEN** 一条返回 3 行的 `select`
- **WHEN** 服务端回包
- **THEN** 首包只有列信息，客户端无法从中得知是否有第一行

#### Scenario: 空结果集也正常回首包

- **GIVEN** 一条返回 0 行的 `select`
- **WHEN** 服务端回包
- **THEN** 首包列信息完整，客户端首次 `next()` 才得知无行

### Requirement: NEXT_ROW 每次都推进物理游标并重建当前行缓冲（MUST）

本要求为强制要求（MUST）。

每次 `NEXT_ROW` 请求（**包括第一次**）都执行一次物理 `result.next()`，并随即清空/重建该游标的当前行缓冲。

#### Scenario: 首次 NEXT_ROW 就有结果

- **GIVEN** 一个 3 行的结果集刚被创建
- **WHEN** 收到第 1 次 `NEXT_ROW`
- **THEN** 执行 1 次物理 `next()` 并回 `DataBool(true)`

#### Scenario: 行推进序列不跳行

- **GIVEN** 一个 2 行的结果集
- **WHEN** 连续发 3 次 `NEXT_ROW`
- **THEN** 依次回 `true`、`true`、`false`（物理 `next()` 恰好被调用 3 次）

#### Scenario: 耗尽后重复推进

- **GIVEN** 结果集已耗尽
- **WHEN** 再次发 `NEXT_ROW`
- **THEN** 回 `DataBool(false)`（不报错，不推进已耗尽的物理游标状态）

### Requirement: 列读从当前行缓冲应答（MUST）

本要求为强制要求（MUST）。

服务端为当前行维护单元格缓冲：**首次**请求某列时从物理结果集读一次并缓存；流列缓存的是 `InputStream` 句柄（不是数据），同一行同一列的后续块请求复用同一句柄。缓冲随 `NEXT_ROW` 推进与游标关闭而整表清空。

#### Scenario: 重复列读不重复读物理结果集

- **GIVEN** 当前行第 0 列已被读过一次
- **WHEN** 再次请求该列
- **THEN** 从缓冲应答，值与首次一致

#### Scenario: 流列句柄只打开一次

- **GIVEN** 某列是流列
- **WHEN** 对该列连续发起多块请求
- **THEN** 底层的 `get<InputStream>` 只被调用 **1 次**，各块字节按序返回

#### Scenario: 读尽后表征 EOF

- **GIVEN** 流已读到末尾
- **WHEN** 再发块请求
- **THEN** 返回空数组（客户端据此判 EOF；不得以"短块"判 EOF）

#### Scenario: 行推进后缓冲与句柄失效

- **GIVEN** 当前行已读过若干列（含一个流列）
- **WHEN** 收到 `NEXT_ROW` 推进到下一行
- **THEN** 整表清空；之后对该流列的新请求会**重新**打开一次句柄

#### Scenario: bufSize 缺省值

- **GIVEN** 块请求的 `bufSize <= 0`
- **WHEN** 处理块读取
- **THEN** 按 `DEFAULT_STREAM_CHUNK` 读取

### Requirement: 关闭游标走 UNSUBSCRIBE/ACK（MUST）

本要求为强制要求（MUST）。

关闭**不**使用 `QueryResultColumnPayload` 的负索引哨兵（不存在 `CLOSE_CURSOR`）。服务端按 `QueryResultClosePayload.qid` 匹配游标：不匹配即幂等 `ACK`；匹配则"清空缓冲 → 循环读尽物理结果集 → `close()` → 归还物理连接 → 回 `ACK`"，且**无论中途是否抛异常都要回 `ACK`**。

#### Scenario: qid 命中的关闭顺序

- **GIVEN** 会话上有一个 `qid` 匹配的游标
- **WHEN** 收到该 `UNSUBSCRIBE`
- **THEN** 依次完成清空缓冲、读尽物理结果集、关闭结果集、归还连接，最后回 `ACK`

#### Scenario: qid 不匹配的幂等 ACK

- **GIVEN** 会话上没有游标 / 游标已关闭 / `qid` 与当前游标不匹配
- **WHEN** 收到 `UNSUBSCRIBE`
- **THEN** 直接回 `ACK`，且**不关闭**当前其它游标

#### Scenario: 重复关闭

- **GIVEN** 同一 `qid` 的 `UNSUBSCRIBE` 已成功处理一次
- **WHEN** 再次收到同一请求
- **THEN** 仍回 `ACK`

#### Scenario: 关闭过程异常仍回 ACK

- **GIVEN** 读尽或关闭物理结果集时抛出异常
- **WHEN** 处理该 `UNSUBSCRIBE`
- **THEN** 异常只记日志，仍回 `ACK`（避免客户端卡在 `close()`）

#### Scenario: 关闭后列读被拒

- **GIVEN** 游标已被 `UNSUBSCRIBE` 关闭
- **WHEN** 再收到该会话的列读或 `NEXT_ROW`
- **THEN** 回 `ERROR(CURSOR_STATE)`

### Requirement: 无游标时的列读与推进报错（MUST）

本要求为强制要求（MUST）。

会话上没有打开游标时，`index >= 0` 的列读与 `NEXT_ROW` 一律回 `ERROR(CURSOR_STATE)`。

#### Scenario: 空会话上的列读

- **GIVEN** 一个从未执行过查询的会话
- **WHEN** 收到 `QueryResultColumnPayload(index = 0)`
- **THEN** 回 `ERROR(CURSOR_STATE)`

#### Scenario: 空会话上的推进

- **GIVEN** 同上会话
- **WHEN** 收到 `NEXT_ROW`
- **THEN** 回 `ERROR(CURSOR_STATE)`（而不是回 `DataBool(false)`）

### Requirement: 新语句先关旧游标（防御）（MUST）

本要求为强制要求（MUST）。

新的 `SqlPayload` 到达时先关闭会话上的旧游标再执行新语句。正常客户端流程不会出现这种情形（客户端侧已按连接级独占拦截），本条是服务端防御。

#### Scenario: 新查询顶掉旧游标

- **GIVEN** 会话上已有一个打开且未读完的游标
- **WHEN** 收到一条新的 `SqlPayload` 查询
- **THEN** 旧游标被关闭（缓冲清空、物理结果集关闭、连接归还），新游标可用

### Requirement: 多库结果集按段串联（MUST）

本要求为强制要求（MUST）。

广播（无分库条件的 `SELECT`）与范围路由命中多分片共用同一条路径：每个物理库一段 `CursorSegment`，按库序串成**一个** `QueryCursor`；行序 = 库序；`NEXT_ROW` 在当前段耗尽后切到下一段。

#### Scenario: 跨段推进不丢不重

- **GIVEN** 两库各 2 行的广播查询
- **WHEN** 连续发 5 次 `NEXT_ROW`
- **THEN** 序列为 `true,true,true,true,false`，行按库序排列

#### Scenario: 前段为空也能取到后段数据

- **GIVEN** A 段 0 行、B 段 2 行
- **WHEN** 连续推进
- **THEN** 仍能读到 B 段的 2 行（跨段预取不可用，故不存在 `hasData` 概念）

#### Scenario: 任一段打开失败整体失败

- **GIVEN** 多库查询中某库打不开
- **WHEN** 组装游标
- **THEN** 整个查询失败回 `ERROR`，已打开的段全部关闭（不做部分成功）

### Requirement: 列类型在线上只以仓颉类型名出现（MUST）

本要求为强制要求（MUST）。

fdbm 用 `SqlTypes.canonicalName` 把物理驱动的 `typeName` 归一为仓颉类型名后写入 `ColumnInfoImpl.tn`，列读时也以该名字作为 `typeName`。`InputStream` **只由驱动自报**产生；`bytea` / `*BLOB` 等方言大对象名一律归一为 `Array<Byte>` 整块读。

#### Scenario: 各方言拼写归一

- **GIVEN** 物理列分别报 `SqlVarchar` / `int4` / `TINYINT(1)` / `bytea` / `GEOMETRY`
- **WHEN** 构造列信息
- **THEN** `tn` 依次为 `String` / `Int32` / `Bool` / `Array<Byte>` / `String`（最后一个记 WARN 并含原始 `typeName`）

#### Scenario: 仓颉类型名原样通过

- **GIVEN** 物理列报 `Int64` / `std.io.InputStream`
- **WHEN** 归一
- **THEN** 原样返回，且只有后者按流处理

#### Scenario: 方言大对象不猜能力

- **GIVEN** 物理列报 `bytea` 或 `*BLOB`
- **WHEN** 归一
- **THEN** 得到 `Array<Byte>`（整块读），不归一成流

### Requirement: 分库算法与范围路由（MUST）

本要求为强制要求（MUST）。

fdbm 必须提供 `step` / `hash` / `crc16` / `crc32` / `crc64` / `murmur` / `substr` 七种内置算法。`step` 的有效数据域为 `[1, N*step]`，越界键必须 `ROUTE_FAILED`；`substr` 按 Unicode 码点取 `[start, start+length)`（`length=0` 到末尾），短于 `start+1` 的键必须 `ROUTE_FAILED`。范围条件（`>` / `>=` / `<` / `<=` / `BETWEEN`）只有 `step` 可计算：展开为连续分片集合（1 个 → `Single`、多个 → `Multi`、无解 → `Empty`）；其他算法 → `Unroutable`。等值与范围同时出现时，必须用范围过滤等值集合。

#### Scenario: step 范围命中多个分片

- **GIVEN** 3 个物理库、`step=1000` 的 `step` 分片表
- **WHEN** 执行 `WHERE id BETWEEN 1 AND 2500`
- **THEN** 路由为 `Multi`，库顺序为 `db0, db1, db2`

#### Scenario: 无解范围返回 Empty

- **GIVEN** 同上表
- **WHEN** 执行 `WHERE id > 100 AND id < 50`
- **THEN** 路由为 `Empty`；`UPDATE`/`DELETE` 直接返回 0，`SELECT` 仅借首库取列信息且结果必为 0 行

#### Scenario: substr 按码点子串哈希

- **GIVEN** 表配置 `substr`、`start=0,length=2,hash=crc32`，键为 `AB-123` 与 `AB-456`
- **WHEN** 路由
- **THEN** 两者都按 `crc32('AB')` 计算并落到同一物理库

#### Scenario: 非 step 算法不做范围路由

- **GIVEN** 一张 `hash` 分片表
- **WHEN** 条件为 `WHERE id > 10`
- **THEN** 路由为 `Unroutable`；`SELECT` 走广播，`UPDATE`/`DELETE` 报 `ROUTE_FAILED`

### Requirement: 自定义扩展发现（MUST）

本要求为强制要求（MUST）。

fdbm 必须扫描 `fdbm_customDir`（默认 `<工作目录>/custom`）下的动态库，先**全部** `PackageInfo.load`，再调用 `InitializerCollection.initialize()`，用两轮模式匹配收集 `PartitionAlgorithm` 与 `IdGenerator`。目录不存在 → 空扩展；任一库加载或任一 `Initializer.initialize()` 失败 → `CONFIG` 启动失败；自定义之间重名必须拒绝，与内置重名由启动校验拒绝。

#### Scenario: 全部加载后才初始化

- **GIVEN** custom 目录下两个扩展库，二者都在 `static init` 中注册
- **WHEN** `CustomLoader.load`
- **THEN** 两个库都完成加载后才调用一次 `InitializerCollection.initialize()`，两个扩展都可见

#### Scenario: 加载失败阻止启动

- **GIVEN** custom 目录下有一个损坏/不兼容的动态库
- **WHEN** 启动
- **THEN** 记 ERROR 并以 `CONFIG` 退出，不开始监听

#### Scenario: 重名拒绝

- **GIVEN** 两个自定义扩展声明同一个 `name`，或自定义 `name` 等于内置算法名
- **WHEN** 启动
- **THEN** 报 `PARTITION_CONFIG` / `CONFIG` 并退出，不允许覆盖内置实现

### Requirement: 会话、巡检与连接归还（MUST）

本要求为强制要求（MUST）。

会话 = TCP 连接（`SocketBuffer`）；一会话至多一个游标；无断连回调，靠周期巡检 `buffer.isClosed()` 回收（关闭游标、归还事务 pin 的连接）。连接借还粒度为语句级，游标与事务例外。

#### Scenario: 同连接同会话、异连接异会话

- **GIVEN** 两条连接
- **WHEN** 各自发起查询
- **THEN** 各自维护独立会话与游标，互不可见；同一连接的两次请求共用同一会话

#### Scenario: 断连会话被巡检回收

- **GIVEN** 一个持有游标与 pin 连接的会话，客户端断开
- **WHEN** 经过一个巡检周期
- **THEN** 游标关闭、pin 连接归还、会话从注册表移除

#### Scenario: 事务 pin 与解 pin

- **GIVEN** 会话执行 `begin`
- **WHEN** 后续执行任意语句
- **THEN** 全部走同一物理连接（read-your-writes）；`commit`/`rollback` 后解 pin 并归还

### Requirement: 启动自检失败即结束进程（MUST）

本要求为强制要求（MUST）。

驱动唯一性、自定义扩展加载与命名冲突、配置跨项引用完整性、算法/ID 生成器名合法性、`substr` 参数、`snowflake` 节点号、`sequence` 分配库、超时参数取值等（详细设计 §11 全表）任一失败，在**接受连接之前**报错退出。

#### Scenario: 自检清单逐条负例

- **GIVEN** 触发清单中某一项的配置或部署状态
- **WHEN** 启动进程
- **THEN** 以对应错误码记 ERROR 并退出，退出码非 0，不监听端口

#### Scenario: 脚本整理失败不阻塞启动

- **GIVEN** `boot.sh` 不可读/不可写或解析异常
- **WHEN** 启动到脚本整理一步
- **THEN** 记 ERROR/WARN 并继续启动（服务使用已加载配置）

### Requirement: 优雅停止的顺序（MUST）

本要求为强制要求（MUST）。

收到 SIGTERM 后依次：停止接受新连接 → 等待在途请求完成（超时记 WARN 后继续）→ 关闭全部会话（游标、pin 连接归还）→ 逐池 `closeAndAwait`（**必须在归还全部借用者之后**）→ 关闭路由缓存 → 退出码 0。

#### Scenario: 在途请求先完成

- **GIVEN** 一条正在执行的慢语句
- **WHEN** 发 SIGTERM
- **THEN** 该语句执行完并回包后才继续停止流程

#### Scenario: 归还先于关池

- **GIVEN** 有借用中的连接
- **WHEN** 执行优雅停止
- **THEN** 会话/游标关闭（归还借用者）发生在逐池 `closeAndAwait` 之前

#### Scenario: 幂等与退出码

- **GIVEN** 已停止的服务
- **WHEN** 再次调用 `stop()`，或观察进程退出码
- **THEN** 幂等无副作用，进程退出码为 0

### Requirement: 路由五态与写语句拒绝（MUST）

本要求为强制要求（MUST）。

路由给出 `Single` / `Multi` / `Broadcast` / `Empty` / `Unroutable`：`UPDATE`/`DELETE` 缺分库列条件或范围不可判定 → `Unroutable` → 报错（`ROUTE_FAILED`），**不广播、不猜测**；`SELECT` 无分库条件按广播合并；`Empty`（条件可证无解）时 `UPDATE`/`DELETE` 直接返回 0 且不借连接。

#### Scenario: 写语句缺分库条件被拒

- **GIVEN** 一条不带分库列条件的 `update`
- **WHEN** 执行
- **THEN** 回 `ERROR(ROUTE_FAILED)`，物理库未收到任何 SQL

#### Scenario: 无解条件不下推

- **GIVEN** 条件可证无解的 `delete`（如 `id > 100 and id < 50`）
- **WHEN** 执行
- **THEN** 返回 `rowCount = 0`，不借连接、不下推

#### Scenario: SELECT 广播合并

- **GIVEN** 无分库条件的 `select`
- **WHEN** 执行
- **THEN** 在逻辑库全部物理库上各查一次并合并为一个游标（行序 = 库序）

### Requirement: 全局表广播与分库缓存语义（MUST）

本要求为强制要求（MUST）。

全局表写操作广播到逻辑库全部物理库，全部成功才算成功（无 2PC，部分失败列出成功/失败库）；分库缓存只在"确认该值确实落在某物理库"时才写，缓存指向不存在的物理库时立即失效并重算，DELETE 先删库记录再删缓存。

#### Scenario: 全局表写广播

- **GIVEN** 一张全局表与一个含 2 个物理库的逻辑库
- **WHEN** 执行 INSERT
- **THEN** 两个物理库各收到一次下推；任一失败则回 `DB_ERROR` 并列出成功/失败库名

#### Scenario: 缓存指向不存在的库

- **GIVEN** 缓存中某键指向一个已不在配置里的物理库
- **WHEN** 路由查缓存
- **THEN** 删除该缓存条目并重算，返回存在的物理库

#### Scenario: DELETE 三步顺序

- **GIVEN** 一条带分库条件的 `delete`
- **WHEN** 执行
- **THEN** 顺序为"先查受影响行的分库键 → 再逐库删除并累加 → 最后删缓存"

### Requirement: SQL 子集与错误码（MUST）

本要求为强制要求（MUST）。

支持的子集见详细设计 §8.1；聚合函数、函数调用、子查询、`union`、`group by`、`having`、存储过程 → `UNSUPPORTED_SQL`；语法错误 → `SQL_SYNTAX`；两者错误信息都含语句位置。会话控制语句在完整解析之前被识别并分流。

#### Scenario: 不支持语法的错误码

- **GIVEN** 一条含 `group by` 或子查询的语句
- **WHEN** 解析
- **THEN** 抛 `UNSUPPORTED_SQL` 且错误文案含位置信息

#### Scenario: 语法错误与不支持可区分

- **GIVEN** 一条明显残缺的语句
- **WHEN** 解析
- **THEN** 抛 `SQL_SYNTAX`（与 `UNSUPPORTED_SQL` 区分）

#### Scenario: 会话控制语句快速分流

- **GIVEN** `begin` / `commit` / `savepoint s1` 等语句
- **WHEN** 进入处理
- **THEN** 由 `parseSessionCtl` 命中并分流，不进入 SQL 解析主路径

### Requirement: 配置解析、export 落盘与启动整理（MUST）

本要求为强制要求（MUST）。

全部配置经 `f_config.Config` 读取，默认值与 f_dbd 同口径（取需求示例值）；`export k=v` 只接受白名单键，写入内存配置并分块（`boot.sh` managed 区块）落盘；启动时对不规范脚本自动整理（`normalize()`），规范脚本不产生写回。

#### Scenario: export 落盘与立即生效

- **GIVEN** `export fdbm_port=9000`
- **WHEN** 执行并 `flush`
- **THEN** 当前进程读回为新值，且脚本 managed 区块含该键值（按功能分块、块内键排序、逐键注释）

#### Scenario: 非白名单键被拒

- **GIVEN** 一个不在白名单内的键
- **WHEN** 执行 `export`
- **THEN** 回 `ERROR(CONFIG)`，不调用 `Config.set`、不写脚本

#### Scenario: 整理幂等

- **GIVEN** 一份已是规范格式的脚本
- **WHEN** 再次启动并执行 `normalize()`
- **THEN** 返回"未写回"，文件内容逐字节不变

#### Scenario: 日志不泄露敏感值

- **GIVEN** 涉及 `fdbm_db_password_*` 的整理或落盘
- **WHEN** 查看日志
- **THEN** 只出现键名，不出现值

### Requirement: ID 生成只在缺分库列值时介入（MUST）

本要求为强制要求（MUST）。

`IdMakers.forTable` 是唯一入口：`uuid` / `snowflake` 忽略表维度，`sequence` 按 `(逻辑库, 表)` 构造、只在分配库取号；生成的 ID 回填到分库列后**再**参与路由。未配置分库列值且无可用生成器 → `ROUTE_FAILED`。

#### Scenario: 回填后再路由

- **GIVEN** 一条未提供分库列值的 INSERT 与一个 `uuid` 生成器
- **WHEN** 执行
- **THEN** 下推 SQL 中该列已被生成值回填，且路由使用的是该生成值

#### Scenario: sequence 只在分配库取号

- **GIVEN** `sequence` 生成器与多个物理库
- **WHEN** 连续取号
- **THEN** 取号 SQL 只出现在分配库，返回递增后的值（首次返回 `increment`）

#### Scenario: 生成器配置非法

- **GIVEN** `fdbm_idmaker` 值或参数非法（含 `snowflake` 节点号缺失/越界）
- **WHEN** 启动或构造生成器
- **THEN** 报 `CONFIG`，不把底层 `NoneValueException` 漏到运行期
