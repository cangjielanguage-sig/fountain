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

**逻辑库口径**：`fdbm_db_logicalDatabase_<logical>` 是逻辑库的唯一显式来源（物理库名不会被注册成逻辑库）；
被 `fdbm_partition__*` 引用但未显式配置的逻辑库隐式包含全部物理库。`SHOW DATABASES` 返回逻辑库名，
`SHOW TABLES [<logical>]` 按逻辑库解析物理库；会话默认库取排序首个逻辑库（多逻辑库部署用
`<logical>.<table>` 限定）。

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
