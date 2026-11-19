# f_dbpool

数据库连接池模块：用 `fountain::f_pool.Pool` 池化 `std.database.sql` 的连接，对上层暴露 `Datasource` / `Resource`。

本模块从 `fountain::f_orm.wrap` 迁出（`DatabasePool` / `PooledConnection`），只依赖 `f_base`、`f_log`、`f_pool`，**不读任何配置项**：池参数与连接串一律由调用方给出。`f_orm` 依赖本模块，并在 `f_orm/src/wrap/DatabasePool.cj` 重导出 `fountain::f_dbpool.DatabasePool`。

## 包结构

| 包 | 内容 |
| --- | --- |
| `fountain::f_dbpool` | `DatabasePool`、`PooledConnection`（包内，不导出）、`ConnectionException` |

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
    public func closeAndAwait(timeout!: Duration): Bool
    public func setOption(key: String, value: String): Unit
}
```

行为要点：

- `getConnection(timeout!)`：池已关闭时抛 `ConnectionException('database pool is closed')`；池耗尽时按 `timeout` 等待（`Duration.Max` 时以池初始化参数 `maxWaiting` 为上限），取不到返回 `None`。
- `connect()`：`getConnection()` 取不到时抛 `ConnectionException()`。
- `close()` 幂等：先关闭池，再关闭 `Datasource`；不等待仍在运行的后台创建／校验回调。
- `closeAndAwait(timeout!)`：关闭池，在一个总期限内等待后台任务实际结束，随后关闭 `Datasource`。`timeout` 必须有限且大于零，否则抛 `IllegalArgumentException`；超时返回 `false`，保留底层数据源，之后可再次调用等待。返回 `true` 表示后台任务已结束且数据源已关闭；数据源关闭失败会传播异常，后续调用可重试。调用者须先结束借用中的连接，不能把此方法当成取消任意业务或回调的能力；超时后若仍需等待保证，不应改调不等待的 `close()`。
- 借出的是 `PooledConnection`（`Connection` 实现），它的 `close()` 即归还；重复归还抛 `ConnectionException('The database connection was returned multiple times.')`。
- `checkSql` 以 `select`（忽略大小写）开头时走 `query()` 取 `next()`，否则走 `update()` 取 `rowCount > 0`；**短于 6 个字符**时抛 `ConnectionException`（不可能是合法语句）。
- `connectionLife` / `idleTimeout` / `checkInterval` 由 `Pool` 负责：超过 `connectionLife` 的连接在借出校验时被判为无效并重建；`idleTimeout <= Duration.Zero` 关闭按闲置时间回收，健康检查仍可运行；`<= Duration.Zero` 或 `Duration.Max` 的 `checkInterval` 表示不启用巡检。

## 异常

本模块只定义 `ConnectionException`（`<: fountain::f_base.BaseException`，带 `message` / `caused` 的四种构造）：池已关闭、取不到连接、重复归还、`checkSql` 非法时抛它。`closeAndAwait` 的非法期限抛标准库 `IllegalArgumentException`，底层数据源关闭异常原样传播。**不定义 `ORMException`**——按本模块异常根捕获时用 `f_base.BaseException`。

注意它与 `fountain::f_orm.exception.ConnectionException` 是**两个独立声明**（f_orm 保留自己那份，仍挂在 `ORMException` 下）：捕获连接池抛出的异常要用 `fountain::f_dbpool.ConnectionException`。

## 与 `f_orm` 的关系

- `fountain::f_orm.wrap.DatabasePool` 是**重导出**，与 `fountain::f_dbpool.DatabasePool` 是同一个类型。
- 原 `init(driver: Driver, ds: Datasource)`（12 个参数取自 `ORMConfig` 的 `orm_databasePool*` 配置项）已删除：`f_orm` 的 `NamedDatasource` 自己读 `ORMConfig` 后调用上面的构造器 2，其它调用方按同样办法显式传参。
- 原 `init(driver: Driver, options!)` 改为构造器 3，`url` 显式传入（不再从 `ORMConfig.getUrl` 取）。

## 测试

在本模块目录执行 `cjpm test`。`DatabasePool_test.cj` 覆盖借还连接，`PooledConnection_test.cj` 覆盖重复归还，`DatabasePoolTermination_test.cj` 使用屏障和假数据源验证关闭超时、再次等待及资源关闭顺序；测试依赖 `fountain::f_mockdb` 提供的 mock 驱动与 `MockConnection`，无需真实数据库。

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- `DatabasePool`：`leased`（prop）
