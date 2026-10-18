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

## 配置

```bash
# 后端物理库是 PostgreSQL（fdbm 的 fdbm_db_driver_* = postgres）
export dbd_driverName=postgres
```

- 必需。fdbm 是代理、自身没有方言；f_orm 按驱动名选择 SQL 方言，因此应用项目必须把驱动名
  配置成**后端物理库的方言名**（`postgres` / `mysql` / ...）。
- 未配置或为空：驱动加载时记录 ERROR（说明正确做法）并结束进程。
- 只影响应用侧注册名；SQL 方言的解析/改写仍只在 fdbm 内完成，URL scheme 仍是 `fdbm://`。

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

## 异常

对外只抛 `fountain::f_dbd.exception.DbdException`（`<: SqlException`），`code` 为细粒度错误码：
`CONFIG` / `IO` / `TIMEOUT` / `PROTOCOL` / `CURSOR_STATE` / `CONVERSION` / `DB_ERROR` / `INTERNAL` 等。
`SqlException` 的 `get` 失败会映射成 `CONVERSION` 并保留 `cause`。

## 测试

```bash
cjpm test
```

协议/驱动层用进程内 `f_net.Server<DataAny>` 桩；结果集与流用桩发送器，不起网络。
性能前置实验见 `src/common/dispatch_perf_test.cj`（`get<T>` 分派选型结论在
`doc/详细设计.md` §10.1）。
