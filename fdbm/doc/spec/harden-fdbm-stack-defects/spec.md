## MODIFIED Requirements

### Requirement: 列类型在线上只以仓颉类型名出现（MUST）

本要求为强制要求（MUST）。

fdbm 用 `SqlTypes.canonicalName` 把物理驱动的 `typeName` 归一为仓颉类型名后写入 `ColumnInfoImpl.tn`，列读时也以该名字作为 `typeName`。`InputStream` **只由驱动自报**产生；`bytea` / `*BLOB` 等方言大对象名一律归一为 `Array<Byte>` 整块读。

归一必须发生在**响应装包之前**：`fdbm/src/execute/cursor.cj` 的 `QueryCursor.columnsOf` 是唯一归一口，`SHOW` / `count(*)` / `returning` 等内存结果也必须给仓颉类型名。用例必须让物理驱动只报方言拼写（`int4` / `TINYINT(1)` / `bytea` / `GEOMETRY`），断言线上 `tn` 已归一；把 `columnsOf` 改成透传时用例必须失败。

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

#### Scenario: 归一接到 RESP 首包

- **GIVEN** 物理驱动只报方言名（`int4` / `TINYINT(1)` / `bytea`）
- **WHEN** 执行查询并观察首包
- **THEN** 客户端收到的 `typeName` 已是 `Int32` / `Bool` / `Array<Byte>`

### Requirement: 自定义扩展发现（MUST）

本要求为强制要求（MUST）。

fdbm 必须扫描 `fdbm_customDir`（默认 `<工作目录>/custom`）下的动态库，先**全部** `PackageInfo.load`，再调用 `InitializerCollection.initialize()`，用两轮模式匹配收集 `PartitionAlgorithm` 与 `IdGenerator`。目录不存在 → 空扩展；任一库加载或任一 `Initializer.initialize()` 失败 → `CONFIG` 启动失败；自定义之间重名必须拒绝。

**与内置重名必须拒绝且不得覆盖**：自定义 `PartitionAlgorithm.name` ∈ {`step`,`hash`,`std`,`crc16`,`crc32`,`crc64`,`murmur`,`substr`} → `PARTITION_CONFIG`；自定义 `IdGenerator.name` ∈ {`uuid`,`snowflake`,`sequence`} → `CONFIG`。该校验发生在**接受连接之前**，因此运行期的工厂查找顺序（自定义优先）不再承担覆盖语义。

#### Scenario: 全部加载后才初始化

- **GIVEN** custom 目录下两个扩展库，二者都在 `static init` 中注册
- **WHEN** `CustomLoader.load`
- **THEN** 两个库都完成加载后才调用一次 `InitializerCollection.initialize()`，两个扩展都可见

#### Scenario: 加载失败阻止启动

- **GIVEN** custom 目录下有一个损坏/不兼容的动态库
- **WHEN** 启动
- **THEN** 记 ERROR 并以 `CONFIG` 退出，不开始监听

#### Scenario: 重名拒绝

- **GIVEN** 两个自定义扩展声明同一个 `name`，或自定义 `name` 等于内置算法/生成器名
- **WHEN** 启动
- **THEN** 报 `PARTITION_CONFIG` / `CONFIG` 并退出，不允许覆盖内置实现

#### Scenario: 非冲突自定义名正常生效

- **GIVEN** 自定义算法 `myhash`、自定义生成器 `mygen`
- **WHEN** 配置引用它们并启动
- **THEN** 启动成功，`hash` / `uuid` 仍解析为内置实现

### Requirement: 会话、巡检与连接归还（MUST）

本要求为强制要求（MUST）。

会话 = TCP 连接（`SocketBuffer`）；一会话至多一个游标；无断连回调，靠周期巡检 `buffer.isClosed()` 回收（关闭游标、归还事务 pin 的连接）。连接借还粒度为语句级，游标与事务例外。

会话的 `cursor` / `pinned` 属于**跨线程共享状态**（f_net 执行器、巡检定时器、关停信号）：读写必须在会话内互斥，且会话必须有「已关闭」标志。巡检/关停先原子摘除再关闭；已摘除或已关闭的会话**不得**再接受新游标（立即关闭新游标并回包 `CURSOR_STATE`）。同一游标只能被关闭一次。

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

#### Scenario: 巡检与在途请求并发

- **GIVEN** 一条请求正在执行查询，同时巡检判定连接已断开
- **WHEN** 两者并发
- **THEN** 游标只关闭一次、连接只归还一次；请求收到 `CURSOR_STATE` 而不是写回已摘除的会话

#### Scenario: 关闭后拒绝新游标

- **GIVEN** 会话已被 `closeAll` 关闭
- **WHEN** 一个已受理的请求返回游标
- **THEN** 新游标立即关闭，会话不持有它

### Requirement: 启动自检失败即结束进程（MUST）

本要求为强制要求（MUST）。

驱动唯一性、自定义扩展加载与命名冲突（含与内置重名）、配置跨项引用完整性（分库规则、**全局表**、`sequenceDatabase`）、算法/ID 生成器名合法性、`substr` 参数（含负数）、`snowflake` 节点号、`sequence` 分配库**及其 `fountain_sequence` 表存在性**、超时参数取值（`shutdownTimeout` / `checkDuration` / `unavailableChecked` / `sessionSweepInterval` 均为正且有限）等（详细设计 §11 全表）任一失败，在**接受连接之前**报错退出，退出码非 0。

`sequenceDatabase` 接受逻辑库名或物理库名：逻辑名解析为其物理库集合的排序首项；两者都不是 → `ID_GENERATOR`。

#### Scenario: 自检清单逐条负例

- **GIVEN** 触发清单中某一项的配置或部署状态
- **WHEN** 启动进程
- **THEN** 以对应错误码记 ERROR 并退出，退出码非 0，不监听端口

#### Scenario: sequence 表缺失

- **GIVEN** `fdbm_idmaker=sequence`，分配库存在但无 `fountain_sequence` 表
- **WHEN** 启动
- **THEN** 报 `ID_GENERATOR` 并退出，不监听端口

#### Scenario: 全局表引用未知逻辑库

- **GIVEN** `fdbm_global__dict='cfg'`，而 `cfg` 既非逻辑库也无法隐式展开
- **WHEN** 启动
- **THEN** 报 `CONFIG` 并退出

#### Scenario: 脚本整理失败不阻塞启动

- **GIVEN** `boot.sh` 不可读/不可写或解析异常
- **WHEN** 启动到脚本整理一步
- **THEN** 记 ERROR/WARN 并继续启动（服务使用已加载配置）

### Requirement: 优雅停止的顺序（MUST）

本要求为强制要求（MUST）。

收到 SIGTERM 后依次：停止接受新连接 → 等待在途请求完成（超时记 WARN 后继续）→ 关闭全部会话（游标、pin 连接归还）→ 逐池 `closeAndAwait`（**必须在归还全部借用者之后**）→ 关闭路由缓存 → 退出码 0。

每一步的失败都必须可见：`closeAndAwait` 返回 `false`、单池关闭抛异常、缓存关闭失败都要记 WARN（含对象名）；监听循环异常在未停止时应使进程以非 0 退出。

#### Scenario: 在途请求先完成

- **GIVEN** 一条正在执行的慢语句
- **WHEN** 发 SIGTERM
- **THEN** 该语句执行完并回包后才继续停止流程

#### Scenario: 归还先于关池

- **GIVEN** 有借用中的连接
- **WHEN** 执行优雅停止
- **THEN** 会话/游标关闭（归还借用者）发生在逐池 `closeAndAwait` 之前

#### Scenario: 超时可观测

- **GIVEN** 有连接未归还且 `shutdownTimeout` 到期
- **WHEN** 停止
- **THEN** `closeAndAwait` 返回 `false`，日志含 WARN 与池名，停止流程继续

#### Scenario: 幂等与退出码

- **GIVEN** 已停止的服务
- **WHEN** 再次调用 `stop()`，或观察进程退出码
- **THEN** 幂等无副作用，进程退出码为 0

#### Scenario: 监听失败不以 0 退出

- **GIVEN** 端口被占用或监听循环抛异常且服务尚未停止
- **WHEN** 启动
- **THEN** 进程退出码为 1，日志含 ERROR

### Requirement: 路由五态与写语句拒绝（MUST）

本要求为强制要求（MUST）。

路由给出 `Single` / `Multi` / `Broadcast` / `Empty` / `Unroutable`：`UPDATE`/`DELETE` 缺分库列条件或范围不可判定 → `Unroutable` → 报错（`ROUTE_FAILED`），**不广播、不猜测**；`SELECT` 无分库条件按广播合并，但广播范围**必须**限定在该语句所属逻辑库的物理库集合内；`Empty`（条件可证无解）时 `UPDATE`/`DELETE` 直接返回 0 且不借连接。

路由的标识符匹配口径：分库列名与表名按 ASCII 大小写不敏感比较（保留原始拼写用于下推）；分库键抽取接受「裸列名、`<表名>.列`、`<别名>.列`」三种限定形式。

「同一分库维度」必须同时比较列名、算法名与两张表解析后的物理库集合：集合不同 → `Unroutable`，错误信息列出两张表的库名。

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
- **THEN** 在**该逻辑库**全部物理库上各查一次并合并为一个游标（行序 = 库序），不触达其它逻辑库

#### Scenario: 大小写与别名

- **GIVEN** `where ID = 5`、`from users u where u.id = 5`
- **WHEN** 路由
- **THEN** 均能抽到分库键并得到 `Single`（不退化广播、不报 `ROUTE_FAILED`）

#### Scenario: 跨逻辑库同维度

- **GIVEN** 两张表列名与算法名相同，但属于分片空间不同的两个逻辑库
- **WHEN** JOIN 路由
- **THEN** 返回 `Unroutable`，错误信息含两张表的物理库名（不返回空结果集）

### Requirement: 全局表广播与分库缓存语义（MUST）

本要求为强制要求（MUST）。

全局表写操作广播到**该逻辑库**全部物理库，全部成功才算成功（无 2PC，部分失败列出成功/失败库）；分库缓存只在"确认该值确实落在某物理库"时才写，缓存指向不存在的物理库时立即失效并重算，DELETE 先删库记录再删缓存。

缓存关闭后必须报错而不是静默降级：`get` / `put` / `remove` 在关闭后抛 `FdbmException(CACHE)`。

已知限制（不修）：会话处于事务 pin 时，全局表写仍使用独立连接并各自提交，`rollback` 不会撤销这些写。该行为必须在文档中写明，首次发生时记 WARN，并由用例固定。

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

#### Scenario: 缓存关闭后报错

- **GIVEN** `PartitionCache` 已 `close()`
- **WHEN** `get` / `put` / `remove`
- **THEN** 抛 `FdbmException(CACHE)`，不静默返回未命中

#### Scenario: 事务内写全局表

- **GIVEN** 会话已 `begin` 且有全局表
- **WHEN** 执行 INSERT/UPDATE/DELETE
- **THEN** 写走独立连接、各自提交；日志有 WARN；`rollback` 后这些写仍存在（文档登记的限制）

### Requirement: SQL 子集与错误码（MUST）

本要求为强制要求（MUST）。

支持的子集：`SELECT`（列清单 / `*` / `distinct` / 多表 / JOIN / WHERE / ORDER BY / LIMIT / OFFSET / `?`，外加 `count(*)` 与派生表）、`INSERT`（`values` / `set` / `select`，外加 `returning`）、`UPDATE`、`DELETE`、`SHOW`、DDL、`EXPORT`、会话控制（详细边界见 `fdbm/doc/详细设计.md` §8.1）。除 `count(*)` 外的聚合函数、函数调用、派生表以外的子查询（含 `IN (select ...)`、`EXISTS (select ...)`、标量子查询）、`union`、`group by`、`having`、存储过程 → `UNSUPPORTED_SQL`；语法错误 → `SQL_SYNTAX`；两类错误信息都必须含语句位置。

派生表形状校验必须覆盖**所有表引用位置**：`select` 的 `from` 与 `joins`、`update`/`delete` 的 `joins`。派生表只能作为唯一 `from` 项，外层不得带 `where`/JOIN/`order by`/`distinct`/`group by`；`update`/`delete` 的 JOIN 中出现派生表一律 `UNSUPPORTED_SQL`。

数值字面量必须保真：整数优先 `Int64`，超出范围按原文交给 `Decimal`；不得经 `Float64` 中转。

参数绑定到 SQL 字面量必须走类型白名单（见「参数值到 SQL 字面量的类型白名单」），不支持的类型在绑定阶段报 `CONVERSION`，不得渲染成裸文本。

#### Scenario: 不支持语法的错误码

- **GIVEN** 一条含 `group by`、`sum(...)`、`count(<表达式>)` 或派生表以外子查询的语句
- **WHEN** 解析
- **THEN** 抛 `UNSUPPORTED_SQL`，错误文案含位置信息

#### Scenario: 语法错误与不支持可区分

- **GIVEN** 一条明显残缺的语句，或派生表缺少别名
- **WHEN** 解析
- **THEN** 抛 `SQL_SYNTAX`（与 `UNSUPPORTED_SQL` 区分）

#### Scenario: 新增子集可解析

- **GIVEN** `insert ... returning <列>`、`select count(*) from (<select>) as a`、`select * from (<select>) as a limit ? offset ?`
- **WHEN** 解析并绑定参数
- **THEN** 均得到可执行语句，不再报 `UNSUPPORTED_SQL`

#### Scenario: 会话控制语句快速分流

- **GIVEN** `begin` / `commit` / `savepoint s1` 等语句
- **WHEN** 进入处理
- **THEN** 由 `parseSessionCtl` 命中并分流，不进入 SQL 解析主路径

#### Scenario: 派生表位于 JOIN 或 DML

- **GIVEN** `select ... from u join (select ...) c on ...`、`update t join (select ...) x on ... set ...`、
  `delete from t join (select ...) x on ...`
- **WHEN** 解析
- **THEN** 均 `UNSUPPORTED_SQL`，物理库不会收到这些语句

#### Scenario: WHERE 子查询

- **GIVEN** `where id in (select ...)`、`where exists (select ...)`、`select (select ...)`
- **WHEN** 解析
- **THEN** `UNSUPPORTED_SQL`（不是 `SQL_SYNTAX`）

#### Scenario: 大数与高精度小数

- **GIVEN** `values (12345678901234567890)` 与 `values (123456789012345678.90)`
- **WHEN** 解析并下推
- **THEN** 下推 SQL 的数值字符串与原文数值一致，无 `Float64` 舍入

### Requirement: 配置解析、export 落盘与启动整理（MUST）

本要求为强制要求（MUST）。

全部配置经 `f_config.Config` 读取，默认值与 f_dbd 同口径（取需求示例值）；`export k=v` 只接受白名单键，写入内存配置并分块（`boot.sh` managed 区块）落盘；启动时对不规范脚本自动整理（`normalize()`），规范脚本不产生写回。

整理优先级：同一键同时出现在 managed 区块内外时，**区块内优先**，并记 WARN；区块外的同名行在整理后不再保留（其值被忽略）。`export` 的 `set`/`flush`/`normalize` 必须线程安全（服务端在多连接并发下执行），临时文件必须唯一，避免并发 `rename` 竞争。

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

#### Scenario: 区块内优先

- **GIVEN** managed 区块内 `fdbm_port=9000`，区块外另有 `export fdbm_port=9100`
- **WHEN** `normalize()`
- **THEN** 结果保留 9000，记 WARN，区块外的该行被移除

#### Scenario: 并发 export

- **GIVEN** 两条连接同时 `export` 不同键
- **WHEN** 两者并发 `flush`
- **THEN** 最终脚本同时含两个键，无 `CONFIG`/ENOENT/内容截断

### Requirement: ID 生成只在缺分库列值时介入（MUST）

本要求为强制要求（MUST）。

`IdMakers.forTable` 是唯一入口：`uuid` / `snowflake` 忽略表维度，`sequence` 按 `(逻辑库, 表)` 构造、只在分配库取号；生成的 ID 回填到分库列后**再**参与路由。未配置分库列值且无可用生成器 → `ROUTE_FAILED`。

生成器能力按**实际实现**协商：期望整型的算法（`step`/`snowflake`/`sequence`）先调 `nextIntId`，期望字符串的算法先调 `nextStringId`；抛 `IdGeneratorException` 时尝试另一方法，两者都失败 → `ID_GENERATOR`。`IdGeneratorException` 无论在哪一层抛出，都必须映射为 `ID_GENERATOR`，不得落到 `INTERNAL`。

`uuid` v1/v6 必须写入真实时间戳与序列（`timestampNanos != 0`，同进程内单调不减），并使用内存序列生成器；不得每次生成创建临时目录/文件。

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

#### Scenario: 只实现一种 ID 能力

- **GIVEN** 自定义生成器只实现 `nextStringId`，表使用 `step` 分片
- **WHEN** 执行缺分库列值的 INSERT
- **THEN** 使用字符串 ID 成功写入（不返回 `INTERNAL`）

#### Scenario: 两种能力都不支持

- **GIVEN** 生成器两个方法都抛 `IdGeneratorException`
- **WHEN** 执行缺分库列值的 INSERT
- **THEN** 回 `ID_GENERATOR`，错误信息含生成器名

#### Scenario: uuid 时间戳非零

- **GIVEN** `fdbm_idmaker=uuid,1` 与 `uuid,6`
- **WHEN** 连续生成 ID
- **THEN** `timestampNanos` 非零且单调不减；`/tmp` 目录项数不增长

### Requirement: 方言识别与引用标识符重写（MUST）

本要求为强制要求（MUST）。

fdbm 必须把物理驱动名归一为一个方言族，并在**下推渲染**时按该方言族重写引用标识符：

- `postgres` / `postgresql` / `pgsql` / `opengauss` → PostgreSQL 族，引用符为 `"..."`；
- `mysql` / `mariadb` / 其它以 `mysql` 开头的驱动名 → MySQL 族，引用符为 `` `...` ``；
- 其它驱动名 → 未知方言：不带引用符的标识符原样输出，引用过的标识符按 SQL 标准的双引号输出；需要方言分支的能力（`returning`、`show tables`）报 `UNSUPPORTED_SQL`。

词法必须把 `"..."` 与 `` `...` `` 识别为**引用标识符**（单引号仍为字符串），AST 必须**按部分**保留「是否引用」：表名、库限定名、别名、列名、列限定名各自独立；渲染时按目标方言重新加引用符，且只给原本引用的部分加。`parse → render → parse` 必须对引用别名与引用库名闭合。

标识符比较（分库列、表名、规则查找）按 ASCII 大小写不敏感；原始拼写只用于下推。

字符串字面量按方言转义：MySQL 族必须转义反斜杠（`\` → `\\`）与单引号（`'` → `''`）；其它方言只翻倍单引号。

**逻辑库限定符**（`<logical>.<table>`）只用于选择逻辑库：下推渲染时去掉该限定符，由目标连接的默认物理库定位表；不得把逻辑库名原样发给物理库。

#### Scenario: PostgreSQL 引用重写

- **GIVEN** 输入 `update "t" set "name" = 1 where "id" = 2`，目标驱动为 `postgres`
- **WHEN** 渲染并下推
- **THEN** 输出保留双引号；解析器可再次解析该输出

#### Scenario: MySQL 引用重写

- **GIVEN** 输入 `update `t` set `name` = 1 where `id` = 2`，目标驱动为 `mysql`
- **WHEN** 渲染并下推
- **THEN** 输出保留反引号；解析器可再次解析该输出

#### Scenario: 引用别名与库名往返

- **GIVEN** `select id as "order" from "shop"."T" as "select"` 与 `select t."COL" from t`
- **WHEN** `parse → render → parse`
- **THEN** 两次解析结果一致；表名不因列名被引用而被一起引用

#### Scenario: MySQL 反斜杠

- **GIVEN** 参数值以 `\` 结尾或含 `\'`
- **WHEN** 在 MySQL 族下渲染字面量
- **THEN** 字面量可正确闭合，物理库能解析

#### Scenario: 逻辑库限定名不下推

- **GIVEN** 逻辑库 `app` 映射物理库 `db0,db1`，语句 `select * from app.t where id = 1001`
- **WHEN** 下推到 `db1`
- **THEN** SQL 中的表引用为 `t`（不含 `app.`），读取的是 `db1` 的 `t`

#### Scenario: MariaDB / openGauss 按族处理

- **GIVEN** 驱动名为 `mariadb` 或 `opengauss`
- **WHEN** 判定方言并执行 `show tables` / `returning`
- **THEN** 分别按 MySQL / PostgreSQL 族处理，不报「未支持的驱动」

#### Scenario: 未知方言不猜能力

- **GIVEN** 驱动名不在两个族内
- **WHEN** 执行 `show tables` 或带 `returning` 的插入
- **THEN** 回 `UNSUPPORTED_SQL`，错误信息含原始驱动名

## ADDED Requirements

### Requirement: 逻辑库与物理库命名空间隔离（MUST）

本要求为强制要求（MUST）。

- `fdbm_db_logicalDatabase_<logical>` 是逻辑库的**唯一**声明来源；物理库名**不得**被自动注册成逻辑库键。
- 未显式配置但被 `fdbm_partition__*` / `fdbm_global__*` 引用的逻辑库，隐式映射到**全部物理库**（排序去重）。
- 若以上都没有，且只有一个物理库 → 以该物理库名作为唯一逻辑命名空间（记 WARN）；多个物理库 → 取排序首项作命名空间并记 WARN。
- 会话默认库必须取自逻辑命名空间：只有一个 → 它；多个 → 排序首项并记 WARN。协议没有「连接时声明 database」，多逻辑库部署必须用 `<logical>.<table>` 限定（偏差登记于 §9.1）。
- `SHOW DATABASES` 返回逻辑库名列表；`SHOW TABLES [<logical>]` 接受逻辑库名，按该逻辑库解析物理库后内省；未知 → `ROUTE_FAILED`。
- `fdbm_sequenceDatabase` 接受逻辑库名或物理库名，逻辑名解析为其物理库排序首项。

#### Scenario: 只配逻辑库时不出现物理键

- **GIVEN** `fdbm_db_logicalDatabase_app='db0,db1,db2,db3'`
- **WHEN** 读取配置
- **THEN** 逻辑库集合恰为 `['app']`，默认库为 `app`

#### Scenario: 未配置逻辑库隐式展开

- **GIVEN** 仅 `fdbm_partition__orders='order,hash,id'`
- **WHEN** 启动
- **THEN** 启动成功，`order` 映射全部物理库，规则可用

#### Scenario: 默认库路由命中

- **GIVEN** 逻辑库 `app`（物理 `db0..db3`）与 `fdbm_partition__orders='app,step,id'`
- **WHEN** 执行未限定表名的 `insert into orders ...`
- **THEN** 按 `('app','orders')` 命中规则，写入对应物理库（不再整体落到 `db0`）

#### Scenario: SHOW 口径

- **GIVEN** 上述部署
- **WHEN** `show databases` / `show tables app`
- **THEN** 前者只列 `app`；后者返回 `app` 物理库中的表

#### Scenario: sequence 分配库

- **GIVEN** `fdbm_sequenceDatabase='app'`
- **WHEN** 启动
- **THEN** 取号库解析为 `app` 的排序首个物理库

### Requirement: 事务 pin 的目标唯一性（MUST）

本要求为强制要求（MUST）。

会话存在事务 pin 时，任何需要访问**多于一个物理库**的语句必须拒绝（`ROUTE_FAILED`），不得在同一 pin 连接上重复执行：

- `SELECT` 的 `Multi` 路由与 `Unroutable` 广播；
- `count(*)` 跨库求和（既有行为保留）；
- `UPDATE` / `DELETE` 的 `Multi` 路由与 DELETE 的取键查询；
- DDL 广播。

`Single` 路由与 `Empty` 路由不受影响。错误信息必须给出目标库数量与语句种类。

#### Scenario: 多片 UPDATE 在事务内被拒

- **GIVEN** `begin` 后执行 `update t set name='x' where id in (1, 10000001)`（命中两片）
- **WHEN** 执行
- **THEN** 回 `ROUTE_FAILED`；物理库只收到 `begin`/`commit`，`rowCount` 不被累加

#### Scenario: 事务内 DDL 被拒

- **GIVEN** 事务已开始
- **WHEN** 执行 `create table ...`
- **THEN** 回 `ROUTE_FAILED`，不向任何物理库下发

#### Scenario: 单目标不受影响

- **GIVEN** 事务已开始且语句命中一片
- **WHEN** 执行任意 DML
- **THEN** 正常在 pin 连接上执行

### Requirement: 连接池异常到错误码的映射（MUST）

本要求为强制要求（MUST）。

`DatabaseResources` 的借连接路径必须把 `f_dbpool.ConnectionException` 映射为 `FdbmException(TIMEOUT)`（池耗尽/等待超时/连接不可用），把「资源已关闭」映射为 `CONFIG`。不得让 `ConnectionException` 冒泡到协议层退化为 `INTERNAL`。

#### Scenario: 池耗尽

- **GIVEN** `maxSize = 1` 且唯一连接被占用
- **WHEN** 另一请求借连接且等待超时
- **THEN** 客户端收到 `TIMEOUT`（不是 `INTERNAL`）

#### Scenario: 资源关闭后借连接

- **GIVEN** `DatabaseResources` 已关闭
- **WHEN** 借连接
- **THEN** 回 `CONFIG`

### Requirement: 启动失败的资源释放（MUST）

本要求为强制要求（MUST）。

`FdbmServer` 构造与其依赖的资源构造失败时，必须按逆序释放**已经创建**的对象（连接池、缓存 `f_store`、后台任务）；`DatabaseResources` 在建池循环中途抛异常时必须关闭已建池后再抛出。不得依赖进程退出兜底（支持进程内嵌与重试用例）。

#### Scenario: 驱动缺失不留半初始化资源

- **GIVEN** 缓存已创建、某个节点驱动未注册
- **WHEN** 构造
- **THEN** 抛 `NO_DRIVER`，且缓存的 `f_store` 已关闭（可用「同路径可再次打开」证明）

#### Scenario: 建池中途失败

- **GIVEN** 两个节点，第二个节点不可连
- **WHEN** `DatabaseResources` 构造
- **THEN** 第一个节点的池已关闭后再抛出

### Requirement: 会话状态的并发安全（MUST）

本要求为强制要求（MUST）。

`DbdSession` 的游标与 pin 连接必须通过会话内互斥访问；提供「安装游标（会话已关闭则立即关闭新游标）」「原子摘除游标」「设置/摘除 pin」「关闭会话」四个原子操作。巡检、关停与请求处理不得并发关闭同一游标或重复归还同一连接。

#### Scenario: 并发归还只发生一次

- **GIVEN** 巡检与请求完成同时触发游标关闭
- **WHEN** 并发执行
- **THEN** 底层游标 `close()` 只被调用一次，连接只归还一次（用计数桩断言）

### Requirement: 游标异常后的行状态复位（MUST）

本要求为强制要求（MUST）。

`QueryCursor.next()` 在物理结果集 `next()` 抛异常时，必须先复位「当前行有效」标志与行/流缓冲，再抛出。异常之后对该游标的 `cell()` 必须报 `CURSOR_STATE`，**不得**返回上一行的缓存值。

#### Scenario: 推进失败后不返回旧行

- **GIVEN** 已读到第 1 行，物理结果集在第 2 行抛异常
- **WHEN** `NEXT_ROW` 处理失败后客户端继续读列
- **THEN** 回 `CURSOR_STATE`，不返回第 1 行数据

### Requirement: 参数值到 SQL 字面量的类型白名单（MUST）

本要求为强制要求（MUST）。

绑定参数写入 SQL 前必须做类型校验，只允许可安全表示为字面量的类型：

- `DataString`：按方言转义（MySQL 族转义反斜杠与单引号，其它翻倍单引号）；
- `DataReal`：按十进制原文输出；
- `DataBool` / `DataNone`：`true`/`false`、`null`；
- `DataDateTime`：加引号的 `yyyy-MM-dd HH:mm:ss[.fffffffff]`（本地时区，不做时区转换）；
- 字节序列（`Array<Byte>` / `DataCollection<Array<UInt8>, UInt8>`）：MySQL 族 `X'<hex>'`、其它 `'\x<hex>'`；
- 其它类型（`Duration`、`DataUnit`、`DataList`、`DataMap`、`DataObject` 等）→ `FdbmException(CONVERSION)`，错误信息含参数序号与类型名。

渲染器不得再用 `toString()` 拼字面量；遇到白名单外类型必须 fail-closed（`CONVERSION`）。

#### Scenario: 非法参数类型在绑定期失败

- **GIVEN** 一个 `Duration` 或 `DataList` 参数
- **WHEN** 执行 `select * from t where c = ?`
- **THEN** 回 `CONVERSION`，物理库未收到任何语句

#### Scenario: 时间与字节字面量合法

- **GIVEN** `DateTime` 与字节参数
- **WHEN** 下推
- **THEN** 生成的 SQL 可被物理库解析并按原值回读

### Requirement: 数值字面量的精度保真（MUST）

本要求为强制要求（MUST）。

解析数值字面量时：能放进 `Int64` → 整数；否则按**原文**构造 `DataReal(String)`（`Decimal`），不得先转 `Float64`。`Decimal` 不接受时才回退 `Float64`（记 WARN），仍失败 → `SQL_SYNTAX`。

#### Scenario: 超长整数

- **GIVEN** `insert into t values (12345678901234567890)`
- **WHEN** 解析并下推
- **THEN** 下推文本为 `12345678901234567890`（不变成 `12345678901234567000`）

#### Scenario: 高精度小数

- **GIVEN** `values (123456789012345678.90)`
- **WHEN** 解析并下推
- **THEN** 小数部分 `.90` 不丢

### Requirement: 多行 INSERT 的同库事务（MUST）

本要求为强制要求（MUST）。

多行 `INSERT ... VALUES` 与 `INSERT ... SELECT` 的回填插入：同一目标物理库的多行必须在**同一事务**内执行（全部成功或全部回滚）；跨库时按库分组，每组一个事务，组间失败返回 `DB_ERROR` 并列出已提交库（无 2PC，文档登记）。会话已 pin 时沿用 pin 连接，不再另开事务。

#### Scenario: 同库第三行失败

- **GIVEN** 三行插入同一物理库，第三行违反约束
- **WHEN** 执行
- **THEN** 回 `DB_ERROR`，前两行未落库（`select count(*)` 为 0）

#### Scenario: 跨库分组

- **GIVEN** 三行分别命中 `db0`、`db1`、`db0`
- **WHEN** 执行
- **THEN** `db0` 的两行在同一事务内；失败时按组回滚，错误信息列出已提交库
