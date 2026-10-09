# f_dbpool

数据库连接池模块：用 `fountain::f_pool.Pool` 池化 `std.database.sql` 的连接，对上层暴露 `Datasource` / `Resource`。

本模块从 `fountain::f_orm.wrap` 迁出（`DatabasePool` / `PooledConnection`），只依赖 `f_pool`、`f_log`、`f_exception`，**不读任何配置项**：池参数与连接串一律由调用方给出。`f_orm` 依赖本模块，并在 `f_orm/src/wrap/DatabasePool.cj` 重导出 `fountain::f_dbpool.DatabasePool`。

## 包结构

| 包 | 内容 |
| --- | --- |
| `fountain::f_dbpool` | `DatabasePool`、`PooledConnection`（包内，不导出）、`ORMException`、`ConnectionException` |

## `DatabasePool`

```cj
package fountain::f_dbpool

public class DatabasePool <: Resource & Datasource {
    // 1) 池参数显式给出，有效性校验用 checker
    public init(ds: Datasource,
                initSize!: Int64 = 0, minSize!: Int64 = 0, maxSize!: Int64 = 10,
                checkOnCreation!: Bool = false, checkOnBorrowing!: Bool = true, checkOnReturning!: Bool = true,
                connectionLife!: Duration = Duration.hour, idleTimeout!: Duration = Duration.Zero,
                checkInterval!: Duration = Duration.minute * 5, connectTimeout!: Duration = Duration.Max,
                maxWaiting!: Duration = Duration.second * 30,
                checker!: (Connection) -> Bool)

    // 2) 同上，但有效性校验用 SQL
    public init(ds: Datasource, ..., maxWaiting!: Duration = Duration.second * 30,
                checkSql!: String = "select 1")

    // 3) 驱动 + 连接串：driver.open(url, options) 建出 Datasource 后交给上面的构造器
    public init(driver: Driver, url: String, options!: Array<(String, String)> = [],
                ..., checkSql!: String = "select 1")

    public func getConnection(timeout!: Duration = connectTimeout): Option<Connection>
    public func connect(): Connection
    public func isClosed(): Bool
    public func close(): Unit
    public func setOption(key: String, value: String): Unit
}
```

行为要点：

- `getConnection(timeout!)`：池已关闭时抛 `ConnectionException('database pool is closed')`；池耗尽时按 `timeout` 等待（`Duration.Max` 时以池初始化参数 `maxWaiting` 为上限），取不到返回 `None`。
- `connect()`：`getConnection()` 取不到时抛 `ConnectionException()`。
- `close()` 幂等：先关 `Datasource`，再关池（池内连接由 `Pool` 的销毁回调逐个关闭）。
- 借出的是 `PooledConnection`（`Connection` 实现），它的 `close()` 即归还；重复归还抛 `ConnectionException('The database connection was returned multiple times.')`。
- `checkSql` 以 `select`（忽略大小写）开头时走 `query()` 取 `next()`，否则走 `update()` 取 `rowCount > 0`；**短于 6 个字符**时抛 `ORMException`（不可能是合法语句）。
- `connectionLife` / `idleTimeout` / `checkInterval` 由 `Pool` 负责：超过 `connectionLife` 的连接在借出校验时被判为无效并重建；`<= Duration.Zero` 或 `Duration.Max` 的 `checkInterval` 表示不启用巡检。

## 与 `f_orm` 的关系

- `fountain::f_orm.wrap.DatabasePool` 是**重导出**，与 `fountain::f_dbpool.DatabasePool` 是同一个类型。
- 原 `init(driver: Driver, ds: Datasource)`（12 个参数取自 `ORMConfig` 的 `orm_databasePool*` 配置项）已删除：`f_orm` 的 `NamedDatasource` 自己读 `ORMConfig` 后调用上面的构造器 2，其它调用方按同样办法显式传参。
- 原 `init(driver: Driver, options!)` 改为构造器 3，`url` 显式传入（不再从 `ORMConfig.getUrl` 取）。
- 本模块的 `ORMException` / `ConnectionException` 是从 `fountain::f_orm.exception` 同名类**复制**过来的独立声明（f_orm 保留自己的那份）：两者都继承 `f_exception.BaseException`，但彼此没有继承关系。捕获连接池抛出的异常要用 `fountain::f_dbpool` 下的类型。

## 测试

`cjpm test`（`f_dbpool/src/DatabasePool_test.cj` 冒烟用例 + `PooledConnection_test.cj` 的 `ORM-L8` 重复归还用例），测试依赖 `fountain::f_mockdb` 提供的 mock 驱动与 `MockConnection`。
