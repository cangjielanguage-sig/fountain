# fdbm

数据库中间件（可执行模块）：对应用暴露一个逻辑库，对内提供**分库路由、读写分离、全局表广播、
ID 生成、分库缓存**。应用侧通过 [f_dbd](../f_dbd) 驱动连接，物理数据库驱动只从部署目录的
`driver/` 加载（有且只有一个）。

## 包结构

| 包 | 内容 |
| --- | --- |
| `fountain::fdbm.config` | 配置解析与启动自检、`boot.sh` managed 区块读写（`BootScriptWriter`） |
| `fountain::fdbm.exception` | `FdbmException`（携带 `DbdErrorCode`） |
| `fountain::fdbm.sql` | SQL 词法/语法、AST、参数绑定、分库键提取、方言判定与渲染 |
| `fountain::fdbm.resources` | `NodeAccessor` 与物理连接池（每 `<host:port> + 库` 一个池） |
| `fountain::fdbm.route` | 分库算法（`step` / `hash` / `std` / `crc16` / `crc32` / `crc64` / `murmur` / `substr`）、五态路由、分库缓存、全局表 |
| `fountain::fdbm.idmaker` | `uuid` / `snowflake` / `sequence` 生成器 |
| `fountain::fdbm.execute` | 会话、服务端游标、各语句执行器、统一分发 |
| `fountain::fdbm.server` | 协议 handler、会话注册表、驱动/扩展加载、服务生命周期 |

## 对外接口

fdbm 是常驻服务，不提供库级 API；对外接口只有四类：

| 入口 | 形态 | 说明 |
| --- | --- | --- |
| 进程 | `fdbm` | **无子命令**，启动即监听 `fdbm_port`（默认 8112）；退出码 0=正常停止，1=启动自检失败 |
| 启停脚本 | `./fdbm.sh start\|stop\|restart` | 随模块交付；配置项全部写在脚本里（见下节） |
| 配置落盘 | `./boot.sh` | `EXPORT <key>=<value>` 语句把配置写回该脚本的 managed 区块 |
| 协议 | `CONSUME` / `UNSUBSCRIBE` | 见[协议口径](#协议口径)；客户端由 [f_dbd](../f_dbd) 实现 |

应用可见的 SQL 面（`SELECT`/`INSERT`/`UPDATE`/`DELETE`/`SHOW`/`DDL`/`EXPORT`/事务）见
[SQL 能力](#sql-能力)。

## 构建与部署

```bash
cjpm build          # 产物：target/release/bin/main
cjpm install        # 安装为 $HOME/.cjpm/bin/fdbm，库在 $HOME/.cjpm/libs/fdbm
```

运行前把库目录加入动态库搜索路径（非交互环境不会加载 `envsetup`）：

```bash
export LD_LIBRARY_PATH="$HOME/.cjpm/libs/fdbm:$LD_LIBRARY_PATH"   # Windows 用 PATH，macOS 用 DYLD_FALLBACK_LIBRARY_PATH
fdbm                                                              # 无子命令：启动即监听 fdbm_port（默认 8112）
```

部署目录约定：

- `driver/`：物理数据库驱动动态库，**恰好一个**，其注册名必须等于所有节点的
  `fdbm_db_driver_<node>`；否则启动报 `NO_DRIVER`。联调使用 `postgres_driver`
  （注册名 `postgres`）与 `mysql_driver`（注册名 `mysql`；MariaDB 复用该驱动名）。
- `custom/`：自定义 `PartitionAlgorithm` / `IdGenerator` 扩展库（目录不存在表示没有扩展）。
- `boot.sh`：配置与进程管理脚本；`export k=v` 会写回其 managed 区块。

### 启停脚本 `fdbm.sh`

```bash
./fdbm.sh start     # setsid 启动（脱离当前会话），等端口就绪后返回；日志 fdbm.log、pid 文件 fdbm.pid
./fdbm.sh stop      # 只发 SIGTERM（走优雅停止）
./fdbm.sh restart
```

配置项全部写在脚本开头的 `export` 区块里：**只保留不配置就无法启动的项**
（`fdbm_db`、每节点的 `fdbm_db_driver_<node>` 与 `fdbm_db_database_<node>`），
其余能取默认值的项一律注释掉，并在注释里写明默认值与语义，需要时取消注释即可。
每个配置项前都有说明注释。

`boot.sh`（模块自带的另一份脚本，由 `EXPORT` 语句生成/维护配置区块）支持：

```bash
./boot.sh start     # nohup 启动并等待端口就绪
./boot.sh status    # pid 存活 + 端口检查
./boot.sh stop      # 只发 SIGTERM（优雅停止）
./boot.sh restart
```

进程收到 `SIGTERM` 后按顺序：停止接受新连接 → 等在途请求（`fdbm_shutdownTimeout`）→ 关闭全部
会话与游标（归还借用连接）→ 逐池 `closeAndAwait` → 关闭分库缓存 → 退出码 0。
`test/lifecycle_test.sh` 覆盖 start/status/stop 与优雅停止标记。

## 配置项

全部配置经 `f_config.Config`（环境变量 / `Config.set`）读取。下表 `默认值` 一列的值即为
"不配置时的行为"；`必填` 列为"是"的项缺失会导致启动失败（`CONFIG`）。

### 服务与进程

| 键 | 默认值 | 必填 | 说明 |
| --- | --- | --- | --- |
| `fdbm_port` | `8112` | 否 | 监听端口，1..65535 |
| `fdbm_bootScript` | `./boot.sh` | 否 | `EXPORT` 语句落盘的目标脚本（写 managed 区块） |
| `fdbm_driverDir` | `./driver` | 否 | 物理驱动目录；目录里必须恰好一个动态库 |
| `fdbm_customDir` | `./custom` | 否 | 自定义算法/ID 生成器扩展目录；不存在表示无扩展 |
| `fdbm_checkDuration` | `30s` | 否 | TCP 有效性检查周期。语句执行期间读不到心跳，执行时长超过约 3 倍该值会被判死链断开 |
| `fdbm_unavailableChecked` | `3` | 否 | 连续检查失败次数阈值 |
| `fdbm_sessionSweepInterval` | `30s` | 否 | 断连会话巡检周期（f_net 无断连回调，靠巡检回收会话/游标/连接） |
| `fdbm_shutdownTimeout` | `30s` | 否 | 优雅停止等待在途请求的上限 |

### 物理节点与凭据

| 键 | 默认值 | 必填 | 说明 |
| --- | --- | --- | --- |
| `fdbm_db` | 无 | **是** | 节点清单 `<node>@<host>:<port>`，多个用 `;` 分隔；名字重复报错 |
| `fdbm_db_driver_<node>` | 无 | **是** | 该节点的物理驱动注册名（`postgres` / `mysql` / ...） |
| `fdbm_db_database_<node>` | 无 | **是** | 该节点承载的物理库，逗号分隔（每库一个连接池） |
| `fdbm_db_username_<node>` | 空 | 否 | 物理库用户名 |
| `fdbm_db_password_<node>` | 空 | 否 | 物理库密码 |

### 逻辑库

| 键 | 默认值 | 必填 | 说明 |
| --- | --- | --- | --- |
| `fdbm_db_logicalDatabase_<logical>` | 无 | 否 | 逻辑库 → 物理库列表（逗号分隔）；引用了不存在的物理库即启动失败 |

口径（与 `LogicalCatalog` 一致）：

- **只有显式声明的名字才是逻辑库**，物理库名不会自动成为逻辑库；
- 被 `fdbm_partition__<table>` 引用但未显式声明的逻辑库，隐式包含**全部**物理库；
- 全局表不创建逻辑库（避免 `fdbm_global__<table>` 的值拼错时启动才发现不了）；
- 一个逻辑库都没声明时，排序首个物理库成为唯一逻辑库（记 WARN）；
- 有多个逻辑库时，会话默认库取排序首个，其余需用 `<logical>.<table>` 限定（记 WARN）。

### 连接池（每物理库一个池）

| 键 | 默认值 | 必填 | 说明 |
| --- | --- | --- | --- |
| `fdbm_databasePoolInitSize` | `1` | 否 | 初始连接数 |
| `fdbm_databasePoolMinSize` | `1` | 否 | 最小连接数 |
| `fdbm_databasePoolMaxSize` | `1` | 否 | 最大连接数（并发长游标/长事务多时调大） |
| `fdbm_databasePoolCheckOnCreation` | `false` | 否 | 建池时检查连接有效性 |
| `fdbm_databasePoolCheckOnBorrowing` | `true` | 否 | 借出时检查 |
| `fdbm_databasePoolCheckOnReturning` | `false` | 否 | 归还时检查 |
| `fdbm_databasePoolIdleTimeout` | `0`（秒，不过期） | 否 | 空闲超时 |
| `fdbm_databasePoolConnectionLife` | `86400`（秒） | 否 | 连接最长存活时间 |
| `fdbm_databasePoolCheckInterval` | `300`（秒） | 否 | 后台检查间隔 |
| `fdbm_databasePoolConnectTimeout` | `50`（毫秒） | 否 | 取连接超时 |
| `fdbm_databasePoolMaxWaiting` | `30000`（毫秒，`0`=无限等待） | 否 | 池耗尽等待上限 |
| `fdbm_databasePoolCheckSql` | `select 1` | 否 | 有效性检查 SQL |

### 负载均衡与读写权重

| 键 | 默认值 | 必填 | 说明 |
| --- | --- | --- | --- |
| `fdbm_loadbalance` | `random` | 否 | `random` / `roundrobin`，其它值启动失败 |
| `fdbm_loadbalance_weight_<node>` | `w,1;r,1` | 否 | 读写权重 `w,<n>;r,<n>`（也接受 `w=<n>`、`;` 或 `/` 分段）；`0` 表示不参与该方向 |
| `fdbm_loadbalance_weight_<node>__<db>` | 继承节点级 | 否 | 库级权重，优先于节点级 |

读写分离靠权重实现：主库 `w,1;r,0`、从库 `w,0;r,1` 即"写只走主、读只走从"。

### 分库与全局表

| 键 | 默认值 | 必填 | 说明 |
| --- | --- | --- | --- |
| `fdbm_partition_step` | `10000000` | 否 | `step` 算法步长，必须为正 |
| `fdbm_partition__<table>` | 无 | 否 | `<逻辑库>,<算法>,<分库列>`；算法：`step` / `hash` / `std` / `crc16` / `crc32` / `crc64` / `murmur` / `substr` |
| `fdbm_partition_substr__<table>` | 无 | 算法为 `substr` 时**必须** | `<起始位置>,<长度>,<哈希>`；哈希：`std` / `hash` / `crc16` / `crc32` / `crc64` / `murmur` |
| `fdbm_global__<table>` | 无 | 否 | 值为逻辑库名；写入广播到该库全部物理库，读只取一份副本 |

### ID 生成

| 键 | 默认值 | 必填 | 说明 |
| --- | --- | --- | --- |
| `fdbm_idmaker` | `uuid,1` | 否 | `uuid[,1\|4\|6\|7]` / `snowflake[,0..1023]` / `sequence` / 自定义扩展名 |
| `fdbm_sequenceDatabase` | 默认逻辑库的首个物理库 | 否 | `sequence` 的分配库，可写逻辑库名或物理库名 |

`sequence` 生成器要求分配库里存在 `fountain_sequence(table_name, current_value, increment)` 表，
启动自检会检查；取号走"事务 + `select ... for update`"。

### 分库缓存

| 键 | 默认值 | 必填 | 说明 |
| --- | --- | --- | --- |
| `fdbm_cache` | `true` | 否 | 是否开启分库键 → 物理库的路由缓存 |
| `fdbm_cache_expire` | 不过期 | 否 | 过期时间（`Duration`，如 `30s`）；留空 = 永不过期 |
| `fdbm_cache_size` | `0` | 否 | 容量上限，`0` = 不限；超限后不再写入新键（既有键照常命中） |
| `fdbm_cachePath` | `./cache` | 否 | `f_store` 落地目录 |

启动时先做完整自检（驱动唯一性、扩展加载与重名、跨项引用、算法/生成器参数、超时取值），
任一失败在**接受连接之前**报错退出（`CONFIG` / `NO_DRIVER` / `PARTITION_CONFIG` / `ID_GENERATOR`）；
`boot.sh` 整理失败只记日志，不阻塞启动。

## SQL 能力

fdbm 解析并重写 SQL 子集，方言由物理驱动名决定：含 `postgres` / `pgsql` / `opengauss`
按 PostgreSQL 家族，含 `mysql` / `mariadb` 按 MySQL 家族，其它按 SQL 标准（双引号引用标识符）。

| 语句 | 支持要点 |
| --- | --- |
| `SELECT` | 列清单 / `*` / `DISTINCT` / 多表 / `[INNER\|LEFT\|RIGHT] JOIN ... ON` / `WHERE`（比较、`AND`/`OR`/`NOT`、`IN`、`LIKE`、括号）/ `ORDER BY` / `LIMIT` / `OFFSET` / `?`；`count(*)`；受限派生表 `FROM (<select>) [AS] alias` |
| `INSERT` | 多行 `VALUES` / `SET` / `INSERT ... SELECT`（拆成 SELECT + 逐行 INSERT）/ `RETURNING <列>`（仅 PostgreSQL 家族、单目标路由） |
| `UPDATE` | 单表或 JOIN 更新；无分库列条件 → `ROUTE_FAILED` |
| `DELETE` | 先按条件查出受影响行的分库键，再逐库删除并累加 `rowCount`；无分库列条件 → 拒绝（不做全分片删除） |
| `SHOW` | `SHOW DATABASES`；`SHOW TABLES [<logical>] [LIKE '...']`（按方言查询，列名统一为 `table_name`） |
| DDL | `CREATE TABLE` / `ALTER TABLE` 原样透传到逻辑库的全部物理库（不解析 DDL） |
| 其它 | `EXPORT <key>=<value>` 修改配置并落 `boot.sh`；`BEGIN` / `COMMIT` / `ROLLBACK` / `SAVEPOINT` 透传到会话 pin 住的物理连接 |

本期新增或明确的 SQL 行为：

- **`INSERT ... RETURNING`**：PostgreSQL 家族 + 单目标路由可用；返回列必须是整型，取首行首列作为
  `lastInsertId`，多行 `VALUES` 取最后一行。非 PostgreSQL 家族 → `UNSUPPORTED_SQL`；广播写或
  `Multi` 路由 → `ROUTE_FAILED`；`returning *` / 表达式 / `insert ... select ... returning` →
  `UNSUPPORTED_SQL`。
- **`count(*)`**：`Single` 按原语句下推；`Multi` / 广播 / `Unroutable` 逐库执行并求和；`Empty`
  直接返回 `0`；全全局表只读一份副本。事务 pin 下命中多个物理库 → `ROUTE_FAILED`。
- **派生表分页**：外层只允许「唯一派生表 + 列清单 / 唯一 `count(*)` + 可选 `LIMIT`/`OFFSET`」；
  带 `LIMIT`/`OFFSET` 且目标库多于一个 → `ROUTE_FAILED`（不做跨分片错页）。
- **参数化分页**：`LIMIT ?` / `OFFSET ?` 在参数绑定后参与路由与渲染。
- **十六进制字面量**：`X'...'` 在 MySQL 原样下推，在 PostgreSQL 渲染为 bytea 的 `'\x...'`。
- **标识符引用**：只重写带引用符的标识符（PostgreSQL `"..."`、MySQL `` `...` ``），裸名保持原样。
- **全局表写入**：INSERT / UPDATE / DELETE 广播到逻辑库的全部物理库；读只取一份副本。
- **DDL 部分失败**：广播到多个物理库时若某个库失败，已执行的分支不会自动回滚，错误信息给出失败库。

不支持：除 `count(*)` 外的聚合、`count(<表达式>)`、其它函数调用、派生表以外的子查询、`UNION`、
`GROUP BY`、`HAVING`、存储过程等，统一报 `UNSUPPORTED_SQL`（错误信息带语句位置）。
`count(*)` 无 `FROM` 或与 `LIMIT`/`OFFSET`/`DISTINCT`/`ORDER BY` 同用、派生表外层带
`WHERE` / JOIN / `ORDER BY` / `DISTINCT` / `GROUP BY`，同样报 `UNSUPPORTED_SQL`。

## 协议口径

与 [f_dbd](../f_dbd) 一致，这里是服务端实现：

- `CONSUME(SqlPayload)` → `RESP(QueryResultServerPayload | UpdateResultPayload)`；
- 查询**不预读**：首包只有列信息；每次 `NEXT_ROW` 执行一次物理 `next()` 并重建当前行缓冲；
- 列读从当前行缓冲应答（流列缓存句柄、每行每列只打开一次），`bufSize <= 0` 取默认块大小；
- 关闭走 `UNSUBSCRIBE(QueryResultClosePayload(qid))` → `ACK`：qid 不匹配 / 无游标 / 已关闭都
  幂等回 `ACK`，命中则"清空缓冲 → 读尽 → 关闭 → 归还连接 → ACK"，中途异常也回 `ACK`；
- 会话 = 一条 TCP，同一连接同一会话；无断连回调，靠 `fdbm_sessionSweepInterval` 巡检回收；
- 任何请求必有回包：`FdbmException` → `ERROR(DbdErrorPayload)`，`SqlException` → `DB_ERROR`
  并透传 `sqlState`。

## 测试

```bash
cjpm test
```

- 协议用例走真实回环 `Server<DataAny>` + `Client<DataAny>`；
- 执行器/路由用例以 `f_mockdb` 为物理库，断言下推 SQL、参数与广播次数；
- `src/server/Integration_test.cj` 用真实 f_dbd 客户端跑通建表/增删改查/事务/流列/SHOW/关闭握手；
- `test/lifecycle_test.sh` 校验真实进程的 `boot.sh` 生命周期与 SIGTERM 优雅停止（需先
  `cjpm build` 与 `cjpm install`）。

真库联调覆盖 `f_dbd ↔ fdbm ↔ PostgreSQL / MySQL 8.0` 的完整链路：

```bash
bash fdbm/test/e2e/run.sh postgres
bash fdbm/test/e2e/run.sh mysql
```

`test/postgres_e2e/run.sh`、`test/mysql_e2e/run.sh` 是兼容入口。环境变量、后端矩阵、
覆盖范围（路由、全局表、DDL、序列、事务、SHOW/EXPORT、缓存、`RETURNING`/`count(*)`/派生表分页、
f_orm 实体操作等）与已知边界见 [`test/e2e/README.md`](test/e2e/README.md)。
