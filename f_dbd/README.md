# f_dbd

`std.database.sql` 驱动实现：把 SQL 与参数发给 [fdbm](../fdbm) 中间件，把结果集按需拉回。
本模块**不依赖任何物理数据库驱动**，应用侧把它当普通驱动用即可（`DriverManager` 名为配置项
`dbd_driverName`，多节点版本为 `multidbd`）。

## 包结构

| 包 | 内容 |
| --- | --- |
| `fountain::f_dbd.common` | 线上载荷、列信息、`SqlTypes`、`QueryResultImpl`、`DbdInputStream`、`DbdException` |
| `fountain::f_dbd.exception` | `DbdException` 的重导出（`public import`） |
| `fountain::f_dbd.driver` | 单节点驱动：`DbdDriver` / `DbdDatasource` / `DbdConnection` / `DbdStatement` / `DbdTransaction` |
| `fountain::f_dbd.multid` | 多节点负载均衡驱动（`multidbm://` / `multidbd://`） |

## 用法

```cangjie
import std.database.sql.*
import fountain::f_dbd.driver.*

main() {
    let driver = dbdDriver()                                  // 注册名 = dbd_driverName
    let datasource = driver.open("fdbm://user:pwd@127.0.0.1:8112/order", [])
    let connection = datasource.connect()
    let statement = connection.prepareStatement("select id, name from t where id = ?")
    statement.set<Int64>(0, 1)
    let result = statement.query()
    while (result.next()) {
        println(result.get<Int64>(0))
        println(result.getOrNull<String>(1) ?? "")
    }
    result.close()
    connection.close()
}
```

URL 形如 `fdbm://user:password@host:port/database`；端口缺省 `8112`，`database` 必填，凭据支持
`%XX` 编码。`multidbm://user1:pwd1@h1:p1,user2:pwd2@h2:p2/database` 为多节点形态。

驱动本身不解析 SQL：支持的 SQL 子集、方言（PostgreSQL / MySQL 家族）、`INSERT ... RETURNING`、
`count(*)` 等能力都由 fdbm 决定，见 [fdbm README 的 SQL 能力](../fdbm/README.md#sql-能力)。

## 配置

```bash
# 后端物理库是 PostgreSQL（fdbm 的 fdbm_db_driver_* = postgres）
export dbd_driverName=postgres
```

- 必需。fdbm 是代理、自身没有方言；f_orm 按驱动名选择 SQL 方言，因此应用项目必须把驱动名
  配置成**后端物理库的方言名**（`postgres` / `mysql` / ...）。
- 未配置或为空：包初始化只记 INFO 并跳过注册，**不结束进程**；`dbdDriver()` / `DbdDriver()` 在取用时抛 `DbdException(CONFIG)`。
  注册名以 `dbd_driverName` 为准，`fdbm` 仅作为兼容别名保留（名字未被占用时注册）。
- 只影响应用侧注册名；SQL 方言的解析/改写仍只在 fdbm 内完成，URL scheme 仍是 `fdbm://`。

## 连接选项

`Driver.open` 的 `opts` 与 `Datasource.setOption` 支持 `std.database.sql` 的标准选项：

| 选项 | 作用 |
| --- | --- |
| `username` / `password` | 覆盖 URL 中的凭据 |
| `connectionTimeout` | 建立 TCP 后首个 PING 的往返超时（毫秒） |
| `queryTimeout` / `updateTimeout` | 每次查询 / 更新请求的超时（毫秒） |
| `fetchRows` | 流列分块大小；`0` 取默认块大小 |

未识别的选项只记 DEBUG 并忽略；非法超时值记 WARN 并忽略。查询/更新超时未设置时使用驱动
默认上限（6 小时）；`connectionTimeout` 未设置时不执行建链后的首个 PING。

## 多节点驱动

`fountain::f_dbd.multid` 提供 `MultiD`（注册名 `multidbd`），在客户端侧对多个 fdbm 节点做
负载均衡：

- URL 形如 `multidbm://user1:pwd1@h1:p1,user2:pwd2@h2:p2/database`，也接受 `multidbd://`；
  各节点凭据支持 `%XX` 编码，`opts` 的 `username` / `password` 可统一覆盖。
- `multidbm_loadbalance`：`random` / `roundrobin`，可带权重（如 `random,1,2,3`；首段为纯数字时
  按权重列表处理、算法取 `random`）。
- 每个节点一个 `f_dbpool.DatabasePool`，参数为 `multidbm_databasePool*`：
  `InitSize` / `MinSize` / `MaxSize` / `CheckOnCreation` / `CheckOnBorrowing` / `CheckOnReturning` /
  `IdleTimeout` / `ConnectionLife` / `CheckInterval` / `ConnectTimeout` / `MaxWaiting` / `CheckSql`。
  时间项单位：`IdleTimeout` / `ConnectionLife` / `CheckInterval` 为秒，`ConnectTimeout` /
  `MaxWaiting` 为毫秒；`MaxWaiting=0` 表示真无限等待。
- `MultiD.preferredPooling = false`：数据源内部已按节点池化，上层不要再套一层。
- 入口：单节点 `dbdDriver()`，多节点 `multiDDriver()`。

## 协议口径（与 fdbm 一一对应）

- **查询不预读**：查询响应只有列信息（`QueryResultServerPayload`）；客户端的**每次** `next()`
  （含第一次）都发 `NEXT_ROW`，由服务端执行一次物理 `next()`。
- **列读不缓存**：每次 `get` / `getOrNull` 都发一次列读请求；服务端用"当前行缓冲"应答，
  同一行的重复读取退化为服务端内存查表。客户端只缓存**已打开的流句柄**。
- **关闭走 `UNSUBSCRIBE(qid)` → `ACK`**：不存在 `CLOSE_CURSOR` 负索引哨兵。
  `qid` 取自查询响应 `Message.id.toString()`；服务端未命中时也回 `ACK`（幂等）。
- **类型口径 B**：线上只出现仓颉类型名（`String` / `Int64` / `Decimal` / `DateTime` /
  `Array<Byte>` …），NULL 只有 `getOrNull` 返回 `None`，`get` 遇到 NULL 抛 `CONVERSION`。
- **流列**：仅当物理驱动自报 `InputStream` / `std.io.InputStream` 时才是流；同一行同一列只打开
  一个句柄，按 `fetch_rows` 分块读，空块表示 EOF。
- **NULL 与空 BLOB**：首次打开流列发送 `CELL(index, -1)` 探测；SQL NULL →
  `getOrNull<InputStream>` 返回 `None`、`get` 抛 `CONVERSION`，空 BLOB 返回 `Some(空流)`。
- **流列只按流读**：`get<Array<Byte>>` / `get<String>` 等标量目标直接抛 `CONVERSION`，不发列读请求。
- **根包重导出**：`import fountain::f_dbd.*` 即可取到错误码、异常、`DbdUrl`、`dbdDriver`、`MultiDUrl` 等；
  `fdBDVersion()` 返回模块版本。

## 异常

对外只抛 `fountain::f_dbd.exception.DbdException`（`<: SqlException`），`code` 为细粒度错误码：
`CONFIG` / `IO` / `TIMEOUT` / `PROTOCOL` / `CURSOR_STATE` / `CONVERSION` / `DB_ERROR` / `INTERNAL` 等。
`SqlException` 的 `get` 失败会映射成 `CONVERSION` 并保留 `cause`。

## 测试

```bash
cjpm test
```

协议/驱动层用进程内 `f_net.Server<DataAny>` 桩；结果集与流用桩发送器，不起网络。
真库联调由 `fdbm/test/e2e` 驱动（PostgreSQL / MySQL 8.0），覆盖本驱动到 fdbm 再到物理库的
完整链路：`bash fdbm/test/e2e/run.sh postgres|mysql`，环境与断言见
[`fdbm/test/e2e/README.md`](../fdbm/test/e2e/README.md)。
性能前置实验见 `src/common/dispatch_perf_test.cj`（`get<T>` 分派选型结论在
`doc/详细设计.md` §10.1）。
