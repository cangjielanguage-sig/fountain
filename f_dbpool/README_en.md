# f_dbpool

Database connection pool module: pools `std.database.sql` connections with `fountain::f_pool.Pool`, and exposes `Datasource` / `Resource` to callers.

It was moved out of `fountain::f_orm.wrap` (`DatabasePool` / `PooledConnection`). It only depends on `f_base`, `f_log` and `f_pool`, and **reads no configuration**: pool options and the connection URL always come from the caller. `f_orm` depends on this module and re-exports `fountain::f_dbpool.DatabasePool` in `f_orm/src/wrap/DatabasePool.cj`.

## Package layout

| Package | Contents |
| --- | --- |
| `fountain::f_dbpool` | `DatabasePool`, `PooledConnection` (package-internal, not exported), `ConnectionException` |

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
    public func closeAndAwait(timeout!: Duration): Bool
    public func setOption(key: String, value: String): Unit
}
```

Behavior notes:

- `getConnection(timeout!)`: throws `ConnectionException('database pool is closed')` when the pool is closed; when the pool is exhausted it waits for `timeout` (`Duration.Max` is capped by the pool's `maxWaiting`) and returns `None` if nothing is available.
- `connect()`: throws `ConnectionException()` when `getConnection()` returns `None`.
- `close()` is idempotent: it closes the pool first, then the `Datasource`, without waiting for active background creation or checking callbacks.
- `closeAndAwait(timeout!)` closes the pool, waits for its background tasks within one total timeout, then closes the `Datasource`. The timeout must be positive and finite; otherwise it throws `IllegalArgumentException`. A timeout returns `false` and leaves the datasource open; the caller may wait again. A `true` result means the tasks have ended and the datasource has closed. Datasource close errors propagate and can be retried. Finish borrowed connections before calling this method: it does not cancel arbitrary application work or callbacks. After a timeout, do not switch to the non-waiting `close()` if that ordering guarantee is still required.
- Borrowed connections are `PooledConnection` (a `Connection` implementation); its `close()` returns the connection to the pool, and returning the same connection twice throws `ConnectionException('The database connection was returned multiple times.')`.
- `checkSql` starting with `select` (case-insensitive) is executed via `query()` and `next()`; otherwise via `update()` with `rowCount > 0`. A statement **shorter than 6 characters** throws `ConnectionException` (it cannot be a valid statement).
- `connectionLife` / `idleTimeout` / `checkInterval` are handled by `Pool`: a connection older than `connectionLife` is treated as invalid on the borrow check and recreated; `idleTimeout <= Duration.Zero` disables idle expiration while allowing health checks to continue; a `checkInterval` of `<= Duration.Zero` or `Duration.Max` disables the inspection thread.

## Exceptions

This module defines only `ConnectionException` (`<: fountain::f_base.BaseException`, with the four `message` / `caused` constructors), thrown for a closed pool, unavailable connection, double return or invalid `checkSql`. An invalid `closeAndAwait` timeout throws the standard `IllegalArgumentException`; datasource close errors propagate unchanged. **There is no `ORMException` here** — to catch this module's exception root, use `f_base.BaseException`.

Note that it is a **separate declaration** from `fountain::f_orm.exception.ConnectionException` (f_orm keeps its own, still under `ORMException`): to catch exceptions thrown by the pool, use `fountain::f_dbpool.ConnectionException`.

## Relationship with `f_orm`

- `fountain::f_orm.wrap.DatabasePool` is a **re-export**; it is the very same type as `fountain::f_dbpool.DatabasePool`.
- The former `init(driver: Driver, ds: Datasource)` (whose 12 arguments came from the `orm_databasePool*` configuration read by `ORMConfig`) has been removed: `f_orm`'s `NamedDatasource` reads `ORMConfig` itself and calls constructor 2 above; other callers pass the values explicitly the same way.
- The former `init(driver: Driver, options!)` became constructor 3, with an explicit `url` (no longer taken from `ORMConfig.getUrl`).

## Tests

Run `cjpm test` in this module's directory. `DatabasePool_test.cj` covers borrowing and returning, `PooledConnection_test.cj` covers double returns, and `DatabasePoolTermination_test.cj` uses a barrier and fake datasource to verify timeout, repeated waiting and resource close order. Tests depend on `fountain::f_mockdb` for the mock driver and `MockConnection`; no real database is needed.
