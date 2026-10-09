# f_dbpool

Database connection pool module: pools `std.database.sql` connections with `fountain::f_pool.Pool`, and exposes `Datasource` / `Resource` to callers.

It was moved out of `fountain::f_orm.wrap` (`DatabasePool` / `PooledConnection`). It only depends on `f_pool`, `f_log` and `f_exception`, and **reads no configuration**: pool options and the connection URL always come from the caller. `f_orm` depends on this module and re-exports `fountain::f_dbpool.DatabasePool` in `f_orm/src/wrap/DatabasePool.cj`.

## Package layout

| Package | Contents |
| --- | --- |
| `fountain::f_dbpool` | `DatabasePool`, `PooledConnection` (package-internal, not exported), `ORMException`, `ConnectionException` |

## `DatabasePool`

```cj
package fountain::f_dbpool

public class DatabasePool <: Resource & Datasource {
    // 1) explicit pool options, validity checked by checker
    public init(ds: Datasource,
                initSize!: Int64 = 0, minSize!: Int64 = 0, maxSize!: Int64 = 10,
                checkOnCreation!: Bool = false, checkOnBorrowing!: Bool = true, checkOnReturning!: Bool = true,
                connectionLife!: Duration = Duration.hour, idleTimeout!: Duration = Duration.Zero,
                checkInterval!: Duration = Duration.minute * 5, connectTimeout!: Duration = Duration.Max,
                maxWaiting!: Duration = Duration.second * 30,
                checker!: (Connection) -> Bool)

    // 2) same, but validity is checked with a SQL statement
    public init(ds: Datasource, ..., maxWaiting!: Duration = Duration.second * 30,
                checkSql!: String = "select 1")

    // 3) driver + connection URL: build the Datasource via driver.open(url, options) first
    public init(driver: Driver, url: String, options!: Array<(String, String)> = [],
                ..., checkSql!: String = "select 1")

    public func getConnection(timeout!: Duration = connectTimeout): Option<Connection>
    public func connect(): Connection
    public func isClosed(): Bool
    public func close(): Unit
    public func setOption(key: String, value: String): Unit
}
```

Behavior notes:

- `getConnection(timeout!)`: throws `ConnectionException('database pool is closed')` when the pool is closed; when the pool is exhausted it waits for `timeout` (`Duration.Max` is capped by the pool's `maxWaiting`) and returns `None` if nothing is available.
- `connect()`: throws `ConnectionException()` when `getConnection()` returns `None`.
- `close()` is idempotent: it closes the `Datasource` first, then the pool (pooled connections are closed by `Pool`'s destroy callback one by one).
- Borrowed connections are `PooledConnection` (a `Connection` implementation); its `close()` returns the connection to the pool, and returning the same connection twice throws `ConnectionException('The database connection was returned multiple times.')`.
- `checkSql` starting with `select` (case-insensitive) is executed via `query()` and `next()`; otherwise via `update()` with `rowCount > 0`. A statement **shorter than 6 characters** throws `ORMException` (it cannot be a valid statement).
- `connectionLife` / `idleTimeout` / `checkInterval` are handled by `Pool`: a connection older than `connectionLife` is treated as invalid on the borrow check and recreated; a `checkInterval` of `<= Duration.Zero` or `Duration.Max` disables the inspection thread.

## Relationship with `f_orm`

- `fountain::f_orm.wrap.DatabasePool` is a **re-export**; it is the very same type as `fountain::f_dbpool.DatabasePool`.
- The former `init(driver: Driver, ds: Datasource)` (whose 12 arguments came from the `orm_databasePool*` configuration read by `ORMConfig`) has been removed: `f_orm`'s `NamedDatasource` reads `ORMConfig` itself and calls constructor 2 above; other callers pass the values explicitly the same way.
- The former `init(driver: Driver, options!)` became constructor 3, with an explicit `url` (no longer taken from `ORMConfig.getUrl`).
- `ORMException` / `ConnectionException` here are **copies** of the same-named classes in `fountain::f_orm.exception` (f_orm keeps its own): both extend `f_exception.BaseException`, but they have no inheritance relationship with each other. To catch exceptions thrown by the pool, use the types from `fountain::f_dbpool`.

## Tests

`cjpm test` (`f_dbpool/src/DatabasePool_test.cj` smoke test plus the `ORM-L8` double-return test in `PooledConnection_test.cj`). Tests depend on `fountain::f_mockdb` for the mock driver and `MockConnection`.
