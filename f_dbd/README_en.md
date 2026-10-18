# f_dbd

A `std.database.sql` driver that sends SQL and parameters to the [fdbm](../fdbm)
middleware and pulls result rows on demand. It does **not** depend on any physical
database driver: applications use it like any other driver (`DriverManager` name is
the `dbd_driverName` setting; `multidbd` for the multi-node variant).

## Packages

| Package | Contents |
| --- | --- |
| `fountain::f_dbd.common` | Wire payloads, column info, `SqlTypes`, `QueryResultImpl`, `DbdInputStream`, `DbdException` |
| `fountain::f_dbd.exception` | Re-export of `DbdException` (`public import`) |
| `fountain::f_dbd.driver` | Single-node driver: `DbdDriver` / `DbdDatasource` / `DbdConnection` / `DbdStatement` / `DbdTransaction` |
| `fountain::f_dbd.multid` | Multi-node load-balanced driver (`multidbm://` / `multidbd://`) |

## Usage

```cangjie
import std.database.sql.*
import fountain::f_dbd.driver.*

main() {
    let driver = dbdDriver()                                  // name = dbd_driverName
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

URL format: `fdbm://user:password@host:port/database` (default port `8112`,
database required, credentials percent-encoded). Multi-node form:
`multidbm://user1:pwd1@h1:p1,user2:pwd2@h2:p2/database`.

## Configuration

```bash
# the backend physical database is PostgreSQL (fdbm's fdbm_db_driver_* = postgres)
export dbd_driverName=postgres
```

- Required. fdbm is a proxy without a dialect of its own; f_orm selects the SQL dialect
  by driver name, so the application must set the name to the **backend dialect**
  (`postgres` / `mysql` / ...).
- Missing or empty: the driver logs an ERROR with the correct usage and exits the process.
- It only affects the client-side registration name; SQL dialect handling stays inside
  fdbm, and the URL scheme remains `fdbm://`.

## Protocol contract (mirrors fdbm)

- **No prefetch**: a query response carries column metadata only
  (`QueryResultServerPayload`). Every client `next()` — including the first — sends
  `NEXT_ROW`, and the server advances the physical cursor once.
- **No client-side row cache**: each `get` / `getOrNull` sends a column request; the
  server answers from its per-row cell buffer. The client only caches open stream
  handles.
- **Close = `UNSUBSCRIBE(qid)` → `ACK`**: there is no `CLOSE_CURSOR` sentinel.
  `qid` is `Message.id.toString()` of the query response; a miss still returns `ACK`
  (idempotent).
- **Type profile B**: only Cangjie type names appear on the wire (`String`, `Int64`,
  `Decimal`, `DateTime`, `Array<Byte>`, …). NULL is represented as `None` from
  `getOrNull`; `get` on NULL throws `CONVERSION`.
- **Streams**: a column is a stream only when the physical driver reports
  `InputStream` / `std.io.InputStream`. One handle per row/column; chunks follow
  `fetch_rows`, and an empty chunk means EOF.

## Errors

Only `fountain::f_dbd.exception.DbdException` (`<: SqlException`) escapes the driver.
Its `code` is the fine-grained `DbdErrorCode`: `CONFIG` / `IO` / `TIMEOUT` /
`PROTOCOL` / `CURSOR_STATE` / `CONVERSION` / `DB_ERROR` / `INTERNAL`, etc.

## Tests

```bash
cjpm test
```

Protocol/driver tests use an in-process `f_net.Server<DataAny>` stub; result-set and
stream tests use stub senders, no network. The `get<T>` dispatch micro-benchmark lives
in `src/common/dispatch_perf_test.cj` (see `doc/详细设计.md` §10.1).
