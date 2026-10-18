# PostgreSQL 真库联调（f_dbd ↔ fdbm）

把 `fdbm` 接到真实 PostgreSQL 上，用 `f_dbd` 作为客户端跑完整链路，覆盖协议、路由、
事务、全局表、序列、SHOW/EXPORT、缓存与优雅停止。

## 前置

- 融合侧已启动 PostgreSQL（默认 `127.0.0.1:5432`），并能以 `postgres` 超级用户免密登录；
- 已 source 仓颉 1.3 envsetup（`cjpm` / `cjc` 在 PATH，`CANGJIE_STDX_DYNAMIC_PATH` 已设置）；
- 中心仓可访问，能解析 `postgres_driver = "0.1.0"`。

`run.sh` 会自动创建测试角色与四个物理库（`db0`…`db3`），不需要手工准备。

## 运行

```bash
bash fdbm/test/postgres_e2e/run.sh
```

可用环境变量覆盖：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FDBM_E2E_PGHOST` / `FDBM_E2E_PGPORT` | `127.0.0.1` / `5432` | PostgreSQL 地址 |
| `FDBM_E2E_PGADMIN` | `postgres` | 建库/建角色的管理员 |
| `FDBM_E2E_DB_USER` / `FDBM_E2E_DB_READ_USER` | `fdbm_rw` / `fdbm_ro` | 写/读节点账号（用于验证读写分离） |
| `FDBM_E2E_DB_PASSWORD` | `fdbm_pw` | 两个账号的密码 |
| `FDBM_E2E_WORK` | `/tmp/fdbm-postgres-e2e` | 临时目录（日志、缓存、安装产物） |

## 覆盖范围

| 范围 | 用例 |
| --- | --- |
| fdbm 路由 | step（点查/多库范围/单侧范围/空区间）、hash、substr、未分库表 Single、读写分离（读走 `fdbm_ro`） |
| 全局表 | INSERT/UPDATE/DELETE 广播到 4 个物理库、读只取一个副本、逐库副本核对 |
| DDL | `create/drop table` 广播到全部物理库（逐库 `to_regclass` 核对） |
| ID | `sequence` 生成器（`fountain_sequence`，键 `<logical>.<table>`） |
| 写路径 | 参数绑定、多行 INSERT、INSERT…SELECT 物化、UPDATE/DELETE 累加 rowCount、DELETE 三步（删后不可见） |
| 事务 | BEGIN/COMMIT/ROLLBACK、SAVEPOINT 回滚、无事务 COMMIT 报 `TX_STATE` |
| 查询 | `show databases`、`show tables`（PostgreSQL 方言）、`get`/`getOrNull`、NULL、空结果 |
| 其它 | EXPORT 落盘与白名单、错误码（SQL_SYNTAX/DB_ERROR/ROUTE_FAILED/CURSOR_STATE）、缓存落盘、SIGTERM 优雅停止、重启探针 |
| f_dbd | 驱动/连接元数据、结果集独占（二次 query → `CURSOR_STATE`）、提前 close 后继续查询、MultiD 双 fdbm 路由 |
| f_orm | **f_orm 零改动**：`dbd_driverName=postgres` 让 f_dbd 以方言名注册，`orm_drivers=postgres` 选中 `PostgresDialect`；DDL/CRUD/参数绑定/方言 `limit ? offset ?` 全链路 |

客户端共 96 条断言；`run.sh` 额外做逐库 SQL 核对（分片分布、全局表副本、`octet_length`、缓存文件、EXPORT 内容）。

## 已知边界

- **二进制参数/结果不能跨 `DataAny` 线缆**：`Array<Byte>` 会编码成 `DataCollection`，经协议解码后退化为 `_`，因此 `set<Array<Byte>>` 与二进制列读取不在本联调覆盖内；大字段用 SQL 字面量写入，`run.sh` 用 `octet_length` 核对存储。协议层修复需扩展 `f_data` 的线缆编解码，属于后续变更。
- 读写分离用同一 PostgreSQL 实例上的两个账号（`fdbm_rw` 只写、`fdbm_ro` 只读）验证，不是物理双机。
- f_orm 的 ORM 层已覆盖；`fdemo` 完整应用（控制器/MVC/静态资源）未在本脚本内启动。
- 应用侧必须先设置 `dbd_driverName=<后端方言>`（脚本已设置）；未设置时 f_dbd 记录 ERROR 并退出。
- SQL 方言的解析/改写只在 fdbm 内做，f_dbd 不感知物理库。
