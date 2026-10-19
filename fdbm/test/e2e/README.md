# 真库联调（f_dbd ↔ fdbm ↔ PostgreSQL / MySQL）

把 `fdbm` 接到真实数据库上，用 `f_dbd` 作为客户端跑完整链路，覆盖协议、路由、事务、
全局表、序列、SHOW/EXPORT、缓存、优雅停止，以及 `f_orm` 的实体插入 / `count()` / `page()` /
`UPDATE` / `DELETE`。

同一套夹具支持两个后端，后端差异只落在 `backends/*.sh` 与客户端的少量 DDL/字面量分支。

## 前置

- 已启动 PostgreSQL（默认 `127.0.0.1:5432`），并能以 `postgres` 超级用户免密登录；
- 已启动 MySQL 8.0（默认 `127.0.0.1:3306`），管理员默认 `root`、空密码；
- 已 source 仓颉 1.3 envsetup（`cjpm` / `cjc` 在 PATH，`CANGJIE_STDX_DYNAMIC_PATH` 已设置）；
- 中心仓可访问，能解析 `postgres_driver = "0.1.0"` / `mysql_driver = "0.1.0"`。

`run.sh` 会自动创建测试账号与四个物理库（`db0`…`db3`），不需要手工准备。

## 运行

```bash
# PostgreSQL（兼容入口）
bash fdbm/test/postgres_e2e/run.sh

# MySQL（默认 127.0.0.1:3306）
bash fdbm/test/mysql_e2e/run.sh

# 统一入口
bash fdbm/test/e2e/run.sh postgres
bash fdbm/test/e2e/run.sh mysql
```

可用环境变量覆盖：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FDBM_E2E_PGHOST` / `FDBM_E2E_PGPORT` | `127.0.0.1` / `5432` | PostgreSQL 地址 |
| `FDBM_E2E_PGADMIN` | `postgres` | 建库/建角色的管理员 |
| `FDBM_E2E_MYSQL_HOST` / `FDBM_E2E_MYSQL_PORT` | `127.0.0.1` / `3306` | MySQL 地址 |
| `FDBM_E2E_MYSQL_ADMIN` / `FDBM_E2E_MYSQL_ADMIN_PASSWORD` | `root` / 空 | MySQL 管理员 |
| `FDBM_E2E_MYSQL_BIN` | `mysql`（不在 PATH 时回落到 `/tmp/mysql-local/root/usr/bin/mysql`） | MySQL 客户端路径 |
| `FDBM_E2E_DB_USER` / `FDBM_E2E_DB_READ_USER` | `fdbm_rw` / `fdbm_ro` | 写/读节点账号（用于验证读写分离） |
| `FDBM_E2E_DB_PASSWORD` | `fdbm_pw` | 两个账号的密码 |
| `FDBM_E2E_WORK` | `$TMPDIR/fdbm-<backend>-e2e` | 临时目录（日志、缓存、安装产物） |
| `FDBM_E2E_BUILD_JOBS` | `4` | `cjpm` 并行度（共享机器内存紧张时调小到 1） |
| `FDBM_E2E_SKIP_BUILD` | `0` | `1` = 复用 `$FDBM_E2E_WORK/install` 里的 fdbm，跳过编译 |

`/tmp` 若是小容量 tmpfs，脚本默认把 `TMPDIR` 指到 `/var/tmp`，避免 LTO 临时文件把 `/tmp` 撑满。

## 驱动实测

| 驱动 | 注册名 | URL | 说明 |
| --- | --- | --- | --- |
| `postgres_driver` | `postgres` | `postgres://...` | PostgreSQL 家族 |
| `mysql_driver` | `mysql` | `mysql://...` | MariaDB 也复用该驱动名 |

`fdbm` 通过 `fdbm_db_driver_name*` 选择物理驱动；`f_orm` 侧用 `dbd_driverName=<backend>` +
`orm_drivers=<backend>` 选中对应方言（`f_orm` / `f_dbd` 零改动）。

## 覆盖范围

| 范围 | 用例 |
| --- | --- |
| fdbm 路由 | step（点查/多库范围/单侧范围/空区间）、hash、substr、未分库表 Single、读写分离（读走 `fdbm_ro`） |
| 全局表 | INSERT/UPDATE/DELETE 广播到 4 个物理库、读只取一个副本、逐库副本核对 |
| DDL | `create/drop table` 广播到全部物理库（PostgreSQL `to_regclass` / MySQL `information_schema` 逐库核对） |
| ID | `sequence` 生成器（`fountain_sequence`，键 `<logical>.<table>`） |
| 写路径 | 参数绑定、多行 INSERT、INSERT…SELECT 物化、UPDATE/DELETE 累加 rowCount、DELETE 三步（删后不可见）、大字段（`bytea` / `longblob`） |
| 事务 | BEGIN/COMMIT/ROLLBACK、SAVEPOINT 回滚、无事务 COMMIT 报 `TX_STATE` |
| 查询 | `show databases`、`show tables`（按方言，列名统一 `table_name`）、`get`/`getOrNull`、NULL、空结果 |
| 新增 SQL 子集 | `INSERT ... RETURNING`（PostgreSQL 成功 / MySQL `UNSUPPORTED_SQL`）、单分片 `count(*)`、多分片 `count(*)` 求和、空路由 `0`、全局表只数一份、单分片派生表分页、多分片分页 `ROUTE_FAILED` |
| 其它 | EXPORT 落盘与白名单、错误码（SQL_SYNTAX/DB_ERROR/ROUTE_FAILED/CURSOR_STATE）、缓存落盘、SIGTERM 优雅停止、重启探针 |
| f_dbd | 驱动/连接元数据、结果集独占（二次 query → `CURSOR_STATE`）、提前 close 后继续查询、MultiD 双 fdbm 路由 |
| f_orm | DDL/CRUD/参数绑定/方言 `limit ? offset ?`；实体 `INSERT_INTO`（PostgreSQL 走 `returning id`）、`count()`、`page(2, page: 2)`、`UPDATE<T, ID>`、`WHERE(...).DELETE()` |

断言数（`checks=..., failures=0`）：

| 后端 | 联调客户端 | f_orm 客户端 | 重启探针 |
| --- | --- | --- | --- |
| PostgreSQL | 108 | 28 | 2 |
| MySQL | 106 | 28 | 2 |

`run.sh` 额外做逐库 SQL 核对（分片分布、全局表副本、`octet_length` / `length`、缓存文件、EXPORT 内容）。

## 已知边界

- **二进制参数/结果不能跨 `DataAny` 线缆**：`Array<Byte>` 会编码成 `DataCollection`，经协议解码后退化为 `_`，因此 `set<Array<Byte>>` 与二进制列读取不在本联调覆盖内；大字段用 SQL 字面量写入（PostgreSQL `'\x..'`、MySQL `X'..'`），`run.sh` 用 `octet_length` / `length` 核对存储。协议层修复需扩展 `f_data` 的线缆编解码，属于后续变更。
- **多分片分页被拒绝**：派生表 + `limit/offset` 命中多个物理库时回 `ROUTE_FAILED`，不做跨分片错页；单分片/未分库/全局表照常。
- **事务内多分片 `count(*)` 被拒绝**：pin 连接只对应一个物理库，跨库求和会得到不完整计数。
- 读写分离用同一实例上的两个账号（`fdbm_rw` 只写、`fdbm_ro` 只读）验证，不是物理双机。
- MySQL 账号统一使用 `mysql_native_password`（8.0 仍可用；8.4 默认关闭该插件，需要另行调整）。
- `MariaDB` 按 MySQL 家族、`openGauss` 按 PostgreSQL 家族处理；未单独搭环境验证。
- f_orm 的 ORM 层已覆盖；`fdemo` 完整应用（控制器/MVC/静态资源）未在本脚本内启动。
- 应用侧必须先设置 `dbd_driverName=<后端方言>`；未设置时 f_dbd 记录 ERROR 并退出。
- SQL 方言的解析/改写只在 fdbm 内做，f_dbd 不感知物理库；双引号是引用标识符，字符串一律用单引号。
