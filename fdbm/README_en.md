# fdbm

Database middleware shipped as an executable module. Applications see one logical
database; inside, fdbm provides **shard routing, read/write splitting, global-table
broadcasting, ID generation and a routing cache**. Clients connect through the
[f_dbd](../f_dbd) driver; physical database drivers are loaded from a deployment
`driver/` directory (exactly one).

## Packages

| Package | Contents |
| --- | --- |
| `fountain::fdbm.config` | Config parsing, startup self-check, `boot.sh` managed-block writer (`BootScriptWriter`) |
| `fountain::fdbm.exception` | `FdbmException` (carries a `DbdErrorCode`) |
| `fountain::fdbm.sql` | Lexer/parser, AST, parameter binding, partition-key extraction, dialect detection and rendering |
| `fountain::fdbm.resources` | `NodeAccessor` and physical pools (one per `<host:port> + database`) |
| `fountain::fdbm.route` | Partition algorithms (`step` / `hash` / `std` / `crc16` / `crc32` / `crc64` / `murmur` / `substr`), five-state routing, routing cache, global tables |
| `fountain::fdbm.idmaker` | `uuid` / `snowflake` / `sequence` generators |
| `fountain::fdbm.execute` | Sessions, server cursors, statement executors, dispatcher |
| `fountain::fdbm.server` | Protocol handler, session registry, driver/custom loaders, lifecycle |

## Build & deploy

```bash
cjpm build          # artifact: target/release/bin/main
cjpm install        # installs $HOME/.cjpm/bin/fdbm and $HOME/.cjpm/libs/fdbm
```

Add the library directory to the loader path (non-interactive environments do not
source `envsetup`):

```bash
export LD_LIBRARY_PATH="$HOME/.cjpm/libs/fdbm:$LD_LIBRARY_PATH"   # PATH on Windows, DYLD_FALLBACK_LIBRARY_PATH on macOS
fdbm                                                              # no subcommands: starts listening on fdbm_port (8112)
```

Deployment layout:

- `driver/`: exactly one physical driver library; its registered name must equal
  `fdbm_db_driver_<node>` for every node, otherwise startup fails with `NO_DRIVER`.
  The integration fixtures use `postgres_driver` (registered as `postgres`) and
  `mysql_driver` (registered as `mysql`; MariaDB reuses that name).
- `custom/`: custom `PartitionAlgorithm` / `IdGenerator` libraries (absent directory
  means no extensions).
- `boot.sh`: configuration plus process management; `export k=v` is persisted into its
  managed block.

`boot.sh` (shipped with the module):

```bash
./boot.sh start     # nohup start, waits for the port
./boot.sh status    # pid liveness + port check
./boot.sh stop      # SIGTERM only (graceful)
./boot.sh restart
```

On `SIGTERM` fdbm stops accepting connections, waits for in-flight requests up to
`fdbm_shutdownTimeout`, closes every session/cursor (returning borrowed connections),
then closes each pool via `closeAndAwait`, closes the routing cache and exits with
code 0. `test/lifecycle_test.sh` covers start/status/stop and the graceful marker.

## Configuration

All settings are read through `f_config.Config` (environment variables / `Config.set`):

| Group | Keys |
| --- | --- |
| Service/process | `fdbm_port`, `fdbm_bootScript`, `fdbm_driverDir`, `fdbm_customDir`, `fdbm_checkDuration`, `fdbm_unavailableChecked`, `fdbm_sessionSweepInterval`, `fdbm_shutdownTimeout` |
| Nodes/credentials | `fdbm_db` (`name@host:port;...`), `fdbm_db_driver_<node>`, `fdbm_db_database_<node>`, `fdbm_db_username_<node>`, `fdbm_db_password_<node>` |
| Logical databases | `fdbm_db_logicalDatabase_<logical>` |
| Pool | `fdbm_databasePool*` |
| Load balancing | `fdbm_loadbalance`, `fdbm_loadbalance_weight_<node>[__<db>]` |
| Sharding/global tables | `fdbm_partition__<table>`, `fdbm_partition_substr__<table>`, `fdbm_partition_step`, `fdbm_global__<table>` |
| ID generation | `fdbm_idmaker`, `fdbm_sequenceDatabase` |
| Routing cache | `fdbm_cache`, `fdbm_cache_expire`, `fdbm_cache_size`, `fdbm_cachePath` |

Startup validates everything before accepting connections (driver uniqueness, custom
extension loading and name clashes, cross references, algorithm/generator parameters,
timeouts). A failed `boot.sh` normalization is logged and does not block startup.

## SQL capabilities

fdbm parses and rewrites a SQL subset. The dialect comes from the physical driver name:
names containing `postgres` / `pgsql` / `opengauss` use the PostgreSQL family, names
containing `mysql` / `mariadb` use the MySQL family, and anything else follows the SQL
standard (double-quoted identifiers).

| Statement | Support |
| --- | --- |
| `SELECT` | Column list / `*` / `DISTINCT` / multiple tables / `[INNER\|LEFT\|RIGHT] JOIN ... ON` / `WHERE` (comparisons, `AND`/`OR`/`NOT`, `IN`, `LIKE`, parentheses) / `ORDER BY` / `LIMIT` / `OFFSET` / `?`; `count(*)`; restricted derived tables `FROM (<select>) [AS] alias` |
| `INSERT` | Multi-row `VALUES` / `SET` / `INSERT ... SELECT` (split into SELECT + row-by-row INSERT) / `RETURNING <columns>` (PostgreSQL family and single-target routing only) |
| `UPDATE` | Single-table or JOIN updates; no partition-key condition → `ROUTE_FAILED` |
| `DELETE` | First selects the partition keys of affected rows, then deletes per database and accumulates `rowCount`; no partition-key condition is rejected (no all-shard delete) |
| `SHOW` | `SHOW DATABASES`; `SHOW TABLES [<logical>] [LIKE '...']` (dialect-specific query, column name normalized to `table_name`) |
| DDL | `CREATE TABLE` / `ALTER TABLE` are passed through verbatim to every physical database of the logical database (DDL is not parsed) |
| Others | `EXPORT <key>=<value>` updates config and persists it to `boot.sh`; `BEGIN` / `COMMIT` / `ROLLBACK` / `SAVEPOINT` are forwarded to the pinned physical connection |

Behaviors added or clarified on this branch:

- **`INSERT ... RETURNING`**: available on the PostgreSQL family with single-target routing.
  The returned column must be an integer; the first column of the first row becomes
  `lastInsertId`, and a multi-row `VALUES` uses the last row. Non-PostgreSQL family →
  `UNSUPPORTED_SQL`; broadcast writes or `Multi` routing → `ROUTE_FAILED`;
  `returning *` / expressions / `insert ... select ... returning` → `UNSUPPORTED_SQL`.
- **`count(*)`**: `Single` is pushed down as-is; `Multi` / broadcast / `Unroutable` execute
  per database and sum the counts; `Empty` returns `0` without borrowing a connection;
  an all-global-table query reads a single replica. Under a transaction pin that targets
  multiple physical databases → `ROUTE_FAILED`.
- **Derived-table pagination**: the outer query only allows one derived table plus a column
  list / a single `count(*)` and optional `LIMIT`/`OFFSET`. With `LIMIT`/`OFFSET` and more
  than one target database → `ROUTE_FAILED` (no cross-shard pagination).
- **Parameterized pagination**: `LIMIT ?` / `OFFSET ?` participate in routing and rendering
  after parameter binding.
- **Hex literals**: `X'...'` is pushed through verbatim on MySQL and rendered as bytea
  `'\x...'` on PostgreSQL.
- **Identifier quoting**: only quoted identifiers are rewritten (PostgreSQL `"..."`,
  MySQL `` `...` ``); unquoted names stay as written.
- **Global-table writes**: INSERT / UPDATE / DELETE are broadcast to every physical database
  of the logical database; reads use one replica.
- **Partial DDL failure**: when a DDL statement is broadcast and one database fails, the
  already-executed branches are not rolled back automatically; the error names the failed
  database.

Unsupported: aggregates other than `count(*)`, `count(<expression>)`, other function calls,
subqueries other than derived tables, `UNION`, `GROUP BY`, `HAVING`, stored procedures, etc.
They all raise `UNSUPPORTED_SQL` with the statement position. `count(*)` without `FROM`, or
combined with `LIMIT`/`OFFSET`/`DISTINCT`/`ORDER BY`, and a derived table whose outer query
has `WHERE` / JOIN / `ORDER BY` / `DISTINCT` / `GROUP BY`, also raise `UNSUPPORTED_SQL`.

## Protocol contract

The server side of the [f_dbd](../f_dbd) contract:

- `CONSUME(SqlPayload)` → `RESP(QueryResultServerPayload | UpdateResultPayload)`.
- Queries **never prefetch**: the first packet carries column metadata only; every
  `NEXT_ROW` advances the physical cursor once and rebuilds the per-row cell buffer.
- Column reads are served from that buffer (stream handles are cached and opened once
  per row/column); `bufSize <= 0` uses the default chunk size.
- Close is `UNSUBSCRIBE(QueryResultClosePayload(qid))` → `ACK`. A wrong qid, a missing
  cursor or an already-closed cursor still gets an idempotent `ACK`; a hit performs
  "clear buffer → drain → close → return connection → ACK", and still ACKs on failure.
- A session is a TCP connection; there is no disconnect callback, so stale sessions are
  reclaimed by the `fdbm_sessionSweepInterval` sweep.
- Every request gets a response: `FdbmException` → `ERROR(DbdErrorPayload)`;
  `SqlException` → `DB_ERROR` with `sqlState` propagated.

## Tests

```bash
cjpm test
```

- Protocol tests use a real loopback `Server<DataAny>` + `Client<DataAny>`.
- Executor/routing tests use `f_mockdb` as the physical database and assert pushed SQL,
  parameters and broadcast counts.
- `src/server/Integration_test.cj` drives DDL/CRUD/transactions/stream columns/SHOW and
  the close handshake through the real f_dbd client.
- `test/lifecycle_test.sh` validates the real process lifecycle and SIGTERM shutdown
  (requires `cjpm build` and `cjpm install` first).

Real-database integration covers the full `f_dbd ↔ fdbm ↔ PostgreSQL / MySQL 8.0` path:

```bash
bash fdbm/test/e2e/run.sh postgres
bash fdbm/test/e2e/run.sh mysql
```

`test/postgres_e2e/run.sh` and `test/mysql_e2e/run.sh` are compatibility entry points.
Environment variables, backend matrix, coverage (routing, global tables, DDL, sequences,
transactions, SHOW/EXPORT, cache, `RETURNING`/`count(*)`/derived-table pagination, f_orm
entity operations, etc.) and known limits live in
[`test/e2e/README.md`](test/e2e/README.md).
