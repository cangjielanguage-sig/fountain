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

The driver does not parse SQL: the supported SQL subset, dialect (PostgreSQL / MySQL
families), `INSERT ... RETURNING` and `count(*)` behavior are all decided by fdbm.
See [fdbm's SQL capabilities](../fdbm/README_en.md#sql-capabilities).

## Configuration

```bash
# the backend physical database is PostgreSQL (fdbm's fdbm_db_driver_* = postgres)
export dbd_driverName=postgres
```

- Required. fdbm is a proxy without a dialect of its own; f_orm selects the SQL dialect
  by driver name, so the application must set the name to the **backend dialect**
  (`postgres` / `mysql` / ...).
- Missing or empty: package initialization logs INFO and skips registration — the process keeps
  running; `dbdDriver()` / `DbdDriver()` throw `DbdException(CONFIG)` when used. The registration
  name is always `dbd_driverName`; `fdbm` is kept only as a compatibility alias (registered when free).
- It only affects the client-side registration name; SQL dialect handling stays inside
  fdbm, and the URL scheme remains `fdbm://`.

## Connection options

`opts` passed to `Driver.open` and `Datasource.setOption` accept the standard
`std.database.sql` options:

| Option | Effect |
| --- | --- |
| `username` / `password` | Override the credentials in the URL |
| `connectionTimeout` | Round-trip timeout of the first PING after the TCP connection is established (ms) |
| `queryTimeout` / `updateTimeout` | Per-request timeout for queries / updates (ms) |
| `fetchRows` | Stream-column chunk size; `0` uses the default chunk |

Unknown options are logged at DEBUG and ignored; invalid timeout values are logged at
WARN and ignored. Without a query/update timeout the driver uses its default upper bound
(6 hours); without `connectionTimeout` it does not perform the initial PING after connecting.

## Multi-node driver

`fountain::f_dbd.multid` provides `MultiD` (registered as `multidbd`), which load-balances
across multiple fdbm nodes on the client side:

- URL: `multidbm://user1:pwd1@h1:p1,user2:pwd2@h2:p2/database`; `multidbd://` is also
  accepted. Per-node credentials support `%XX` encoding, and `opts` `username` / `password`
  override all nodes.
- `multidbm_loadbalance`: `random` / `roundrobin`, optionally with weights (for example
  `random,1,2,3`; when the first segment is numeric it is treated as a weight list and the
  algorithm defaults to `random`).
- One `f_dbpool.DatabasePool` per node, configured by `multidbm_databasePool*`:
  `InitSize` / `MinSize` / `MaxSize` / `CheckOnCreation` / `CheckOnBorrowing` /
  `CheckOnReturning` / `IdleTimeout` / `ConnectionLife` / `CheckInterval` /
  `ConnectTimeout` / `MaxWaiting` / `CheckSql`.
  Units: `IdleTimeout` / `ConnectionLife` / `CheckInterval` are seconds;
  `ConnectTimeout` / `MaxWaiting` are milliseconds; `MaxWaiting=0` means a true infinite wait.
- `MultiD.preferredPooling = false`: the datasource already pools per node; do not wrap it
  in another pool.
- Entry points: `dbdDriver()` for single-node, `multiDDriver()` for multi-node.

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

- **Stream columns**: the first open sends `CELL(index, -1)` as a NULL probe; SQL NULL makes
  `getOrNull<InputStream>` return `None` (and `get` throw `CONVERSION`), while an empty BLOB returns
  `Some(empty stream)`. Scalar reads (`get<Array<Byte>>`/`get<String>`) on a stream column throw
  `CONVERSION` without sending a request.
- **Root package**: `import fountain::f_dbd.*` re-exports error codes, exceptions, `DbdUrl`,
  `dbdDriver`, `MultiDUrl`, ...; `fdBDVersion()` returns the module version. An unconfigured
  `dbd_driverName` no longer exits the process; `dbdDriver()` throws `CONFIG` when used.

## Tests

```bash
cjpm test
```

Protocol/driver tests use an in-process `f_net.Server<DataAny>` stub; result-set and
stream tests use stub senders, no network. Real-database integration is driven by
`fdbm/test/e2e` (PostgreSQL / MySQL 8.0) and covers this driver through fdbm to the
physical database: `bash fdbm/test/e2e/run.sh postgres|mysql`. See
[`fdbm/test/e2e/README.md`](../fdbm/test/e2e/README.md) for setup and assertions.
The `get<T>` dispatch micro-benchmark lives in `src/common/dispatch_perf_test.cj`
(see `doc/详细设计.md` §10.1).
