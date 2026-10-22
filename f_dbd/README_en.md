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

## API

`import fountain::f_dbd.*` exposes the following entry points (root package re-exports):

| API | Signature | Notes |
| --- | --- | --- |
| Single-node driver | `func dbdDriver(): DbdDriver` | Registration name = `dbd_driverName`; throws `DbdException(CONFIG)` when unset/empty |
| Multi-node driver | `func multiDDriver(): MultiD` | Registered as `multidbd` (package-level `static init` on first use) |
| Open a datasource | `Driver.open(connectionString: String, opts: Array<(String, String)>): Datasource` | Parses the URL and builds a datasource |
| Datasource (single) | `DbdDatasource(url: String, opts!: Array<(String, String)> = [])` | `connect()` / `setOption()` / `close()` / `isClosed()` |
| Datasource (multi) | `MultiDatasource(url: String, opts!: Array<(String, String)> = [])` | One `f_dbpool` pool per node |
| URL parsing | `DbdUrl.parse(url) -> DbdUrl` (`user`/`password`/`host`/`port`/`database`) | `fdbm://user:pass@host:port/database`, default port 8112 |
| Multi-node URL parsing | `MultiDUrl.parse(url) -> MultiDUrl` (`nodes: Array<DbdUrl>` / `database`) | `multidbm://user:pass@h:p,user:pass@h:p/database` |
| Version | `func fdBDVersion(): String` | Module version |
| Exception | `class DbdException <: SqlException` (`code: DbdErrorCode`, `cause: ?Exception`) | The only exception type thrown |

All other objects (`Connection` / `Statement` / `QueryResult` / `UpdateResult` /
`Transaction` / `InputStream` / `ColumnInfo` / `Datasource` / `Driver`) come from
`std.database.sql`. `QueryResultImpl` and `DbdInputStream` are public but constructed by
the driver; applications never create them directly.

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

## Settings

### Required application setting

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `dbd_driverName` | none | **yes** | The **registration name**, which must be the backend dialect name (`postgres` / `mysql` / ...). fdbm is a proxy without a dialect of its own, while f_orm selects the SQL dialect by driver name |

- Missing or empty: package initialization logs INFO and skips registration — the process keeps
  running; `dbdDriver()` / `DbdDriver()` throw `DbdException(CONFIG)` when used.
- The registration name is always `dbd_driverName`; `fdbm` is kept only as a compatibility alias
  (registered when free).
- It only affects the client-side registration name; SQL dialect handling stays inside fdbm,
  and the URL scheme remains `fdbm://`.

### Connection options (`opts` / `Datasource.setOption`)

| Option | Default | Effect |
| --- | --- | --- |
| `username` / `password` | credentials from the URL | Override the URL credentials (all nodes for multi-node URLs) |
| `connectionTimeout` | no initial PING | Round-trip timeout of the first PING after connecting (ms) |
| `queryTimeout` / `updateTimeout` | driver default cap 6 hours | Per-request timeout for queries / updates (ms) |
| `fetchRows` | driver default chunk | Stream-column chunk size; `0` uses the default chunk |

Unknown options are logged at DEBUG and ignored; invalid timeout values are logged at WARN
and ignored.

### Multi-node client settings (`multidbm_*`)

Read through `f_config.Config` (environment variables or `Config.set`); defaults:

| Key | Default | Notes |
| --- | --- | --- |
| `multidbm_loadbalance` | `random` | `random` / `roundrobin`, optionally weighted (e.g. `random,1,2,3`; a numeric first segment is treated as a weight list and the algorithm falls back to `random`) |
| `multidbm_databasePoolInitSize` | `1` | Initial connections per node pool |
| `multidbm_databasePoolMinSize` | `1` | Minimum connections |
| `multidbm_databasePoolMaxSize` | `1` | Maximum connections |
| `multidbm_databasePoolCheckOnCreation` | `false` | Validate connections when the pool is created |
| `multidbm_databasePoolCheckOnBorrowing` | `true` | Validate on borrow |
| `multidbm_databasePoolCheckOnReturning` | `false` | Validate on return |
| `multidbm_databasePoolIdleTimeout` | `0` (seconds, never) | Idle timeout |
| `multidbm_databasePoolConnectionLife` | `86400` (seconds) | Maximum connection lifetime |
| `multidbm_databasePoolCheckInterval` | `300` (seconds) | Background check interval |
| `multidbm_databasePoolConnectTimeout` | `50` (ms) | Borrow timeout |
| `multidbm_databasePoolMaxWaiting` | `30000` (ms, `0` = wait forever) | Maximum wait when a pool is exhausted |
| `multidbm_databasePoolCheckSql` | `select 1` | Validation SQL |

Units: `IdleTimeout` / `ConnectionLife` / `CheckInterval` are **seconds**;
`ConnectTimeout` / `MaxWaiting` are **milliseconds**.

## Multi-node driver

`fountain::f_dbd.multid` provides `MultiD` (registered as `multidbd`), which load-balances
across multiple fdbm nodes on the client side:

- URL: `multidbm://user1:pwd1@h1:p1,user2:pwd2@h2:p2/database`; `multidbd://` is also
  accepted. Per-node credentials support `%XX` encoding, and `opts` `username` / `password`
  override all nodes.
- Node order = URL order = weight order; weights come from `multidbm_loadbalance`.
- One `f_dbpool.DatabasePool` per node, configured by the `multidbm_databasePool*` keys above.
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
- **NULL and empty BLOB**: the first open sends `CELL(index, -1)` as a NULL probe;
  SQL NULL makes `getOrNull<InputStream>` return `None` (and `get` throw `CONVERSION`),
  while an empty BLOB returns `Some(empty stream)`.
- **Stream columns are stream-only**: scalar targets such as `get<Array<Byte>>` /
  `get<String>` throw `CONVERSION` without sending a request.
- **Root package**: `import fountain::f_dbd.*` re-exports error codes, exceptions, `DbdUrl`,
  `dbdDriver`, `MultiDUrl`, ...; `fdBDVersion()` returns the module version.

## Errors

Only `fountain::f_dbd.exception.DbdException` (`<: SqlException`) escapes the driver.
Its `code` is the fine-grained `DbdErrorCode`: `CONFIG` / `IO` / `TIMEOUT` /
`PROTOCOL` / `CURSOR_STATE` / `CONVERSION` / `DB_ERROR` / `INTERNAL`, etc.
A failing `get` maps to `CONVERSION` and keeps the original `cause`.

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
