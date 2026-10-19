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

`boot.sh`（随模块交付）支持：

```bash
./boot.sh start     # nohup 启动并等待端口就绪
./boot.sh status    # pid 存活 + 端口检查
./boot.sh stop      # 只发 SIGTERM（优雅停止）
./boot.sh restart
```

进程收到 `SIGTERM` 后按顺序：停止接受新连接 → 等在途请求（`fdbm_shutdownTimeout`）→ 关闭全部
会话与游标（归还借用连接）→ 逐池 `closeAndAwait` → 关闭分库缓存 → 退出码 0。
`test/lifecycle_test.sh` 覆盖 start/status/stop 与优雅停止标记。

## 配置

全部配置经 `f_config.Config`（环境变量 / `Config.set`）读取，主要分组：

| 分组 | 键 |
| --- | --- |
| 服务与进程 | `fdbm_port`、`fdbm_bootScript`、`fdbm_driverDir`、`fdbm_customDir`、`fdbm_checkDuration`、`fdbm_unavailableChecked`、`fdbm_sessionSweepInterval`、`fdbm_shutdownTimeout` |
| 节点与凭据 | `fdbm_db`（`name@host:port;...`）、`fdbm_db_driver_<node>`、`fdbm_db_database_<node>`、`fdbm_db_username_<node>`、`fdbm_db_password_<node>` |
| 逻辑库 | `fdbm_db_logicalDatabase_<logical>` |
| 连接池 | `fdbm_databasePool*` |
| 负载均衡 | `fdbm_loadbalance`、`fdbm_loadbalance_weight_<node>[__<db>]` |
| 分库/全局表 | `fdbm_partition__<table>`、`fdbm_partition_substr__<table>`、`fdbm_partition_step`、`fdbm_global__<table>` |
| ID 生成 | `fdbm_idmaker`、`fdbm_sequenceDatabase` |
| 分库缓存 | `fdbm_cache`、`fdbm_cache_expire`、`fdbm_cache_size`、`fdbm_cachePath` |

启动时先做完整自检（驱动唯一性、扩展加载与重名、跨项引用、算法/生成器参数、超时取值），
任一失败在**接受连接之前**报错退出；`boot.sh` 整理失败只记日志，不阻塞启动。

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
