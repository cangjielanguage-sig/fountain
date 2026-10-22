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

## Exposed interfaces

fdbm is a long-running service and exposes no library API. There are four entry points:

| Entry | Form | Notes |
| --- | --- | --- |
| Process | `fdbm` | **No subcommands**; starts listening on `fdbm_port` (default 8112). Exit code 0 = clean stop, 1 = startup self-check failed |
| Start/stop script | `./fdbm.sh start\|stop\|restart` | Shipped with the module; all settings live in the script (see below) |
| Config persistence | `./boot.sh` | `EXPORT <key>=<value>` writes settings back into its managed block |
| Protocol | `CONSUME` / `UNSUBSCRIBE` | See [Protocol contract](#protocol-contract); the client side is [f_dbd](../f_dbd) |

The SQL surface visible to applications (`SELECT`/`INSERT`/`UPDATE`/`DELETE`/`SHOW`/DDL/`EXPORT`/transactions)
is described in [SQL capabilities](#sql-capabilities).

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

### Start/stop script `fdbm.sh`

```bash
./fdbm.sh start     # setsid start (detached from the session), waits for the port; log fdbm.log, pid file fdbm.pid
./fdbm.sh stop      # SIGTERM only (graceful shutdown)
./fdbm.sh restart
```

All settings are `export`s at the top of the script. Only the **mandatory** ones are left
active (`fdbm_db` plus per-node `fdbm_db_driver_<node>` and `fdbm_db_database_<node>`);
every setting that has a default is commented out together with a comment stating its
default and meaning. Each setting has its own explanatory comment.

`boot.sh` (the other script shipped with the module; `EXPORT` statements maintain its
managed block) supports:

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

## Settings

All settings are read through `f_config.Config` (environment variables / `Config.set`).
The `Default` column is what happens when the key is absent; keys marked **yes** in
`Required` abort startup with `CONFIG` when missing.

### Service / process

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `fdbm_port` | `8112` | no | Listen port, 1..65535 |
| `fdbm_bootScript` | `./boot.sh` | no | Target script for `EXPORT` statements (managed block) |
| `fdbm_driverDir` | `./driver` | no | Physical driver directory; exactly one library |
| `fdbm_customDir` | `./custom` | no | Custom algorithm / ID generator directory; absent means none |
| `fdbm_checkDuration` | `30s` | no | TCP liveness check period. No heartbeat is read while a statement runs, so statements taking longer than about 3× this value are treated as dead links |
| `fdbm_unavailableChecked` | `3` | no | Consecutive failure threshold |
| `fdbm_sessionSweepInterval` | `30s` | no | Stale-session sweep period (f_net has no disconnect callback, so sessions/cursors/connections are reclaimed here) |
| `fdbm_shutdownTimeout` | `30s` | no | Upper bound for in-flight requests during graceful shutdown |

### Physical nodes and credentials

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `fdbm_db` | none | **yes** | Node list `<node>@<host>:<port>`, `;`-separated; duplicate names are rejected |
| `fdbm_db_driver_<node>` | none | **yes** | Physical driver registration name (`postgres` / `mysql` / ...) |
| `fdbm_db_database_<node>` | none | **yes** | Physical databases hosted by the node, comma-separated (one pool each) |
| `fdbm_db_username_<node>` | empty | no | Physical database user |
| `fdbm_db_password_<node>` | empty | no | Physical database password |

### Logical databases

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `fdbm_db_logicalDatabase_<logical>` | none | no | Logical database → physical database list (comma-separated); an unknown physical name aborts startup |

Semantics (matching `LogicalCatalog`):

- **Only explicitly declared names become logical databases**; physical database names
  are never registered implicitly.
- A logical database referenced by `fdbm_partition__<table>` but not declared explicitly
  implicitly contains **all** physical databases.
- Global tables do not create namespaces (so a typo in `fdbm_global__<table>` cannot
  silently create one).
- With no logical database declared, the first physical database (sorted) becomes the only
  logical database (WARN is logged).
- With several logical databases, the session default is the first sorted one and the others
  must be qualified as `<logical>.<table>` (WARN is logged).

### Connection pool (one per physical database)

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `fdbm_databasePoolInitSize` | `1` | no | Initial connections |
| `fdbm_databasePoolMinSize` | `1` | no | Minimum connections |
| `fdbm_databasePoolMaxSize` | `1` | no | Maximum connections (raise it for many concurrent long cursors/transactions) |
| `fdbm_databasePoolCheckOnCreation` | `false` | no | Validate connections when the pool is created |
| `fdbm_databasePoolCheckOnBorrowing` | `true` | no | Validate on borrow |
| `fdbm_databasePoolCheckOnReturning` | `false` | no | Validate on return |
| `fdbm_databasePoolIdleTimeout` | `0` (seconds, never) | no | Idle timeout |
| `fdbm_databasePoolConnectionLife` | `86400` (seconds) | no | Maximum connection lifetime |
| `fdbm_databasePoolCheckInterval` | `300` (seconds) | no | Background check interval |
| `fdbm_databasePoolConnectTimeout` | `50` (ms) | no | Borrow timeout |
| `fdbm_databasePoolMaxWaiting` | `30000` (ms, `0` = wait forever) | no | Maximum wait when the pool is exhausted |
| `fdbm_databasePoolCheckSql` | `select 1` | no | Validation SQL |

### Load balancing and read/write weights

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `fdbm_loadbalance` | `random` | no | `random` / `roundrobin`; anything else aborts startup |
| `fdbm_loadbalance_weight_<node>` | `w,1;r,1` | no | Read/write weights `w,<n>;r,<n>` (also accepts `w=<n>`, `;` or `/` separators); `0` excludes the node from that direction |
| `fdbm_loadbalance_weight_<node>__<db>` | inherited from the node | no | Per-database weights, taking precedence over node-level ones |

Read/write splitting is expressed with weights: primary `w,1;r,0`, replica `w,0;r,1`
means writes go to the primary only and reads go to replicas only.

### Sharding and global tables

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `fdbm_partition_step` | `10000000` | no | Step of the `step` algorithm; must be positive |
| `fdbm_partition__<table>` | none | no | `<logical>,<algorithm>,<partition-column>`; algorithms: `step` / `hash` / `std` / `crc16` / `crc32` / `crc64` / `murmur` / `substr` |
| `fdbm_partition_substr__<table>` | none | **required** when the algorithm is `substr` | `<start>,<length>,<hash>`; hash: `std` / `hash` / `crc16` / `crc32` / `crc64` / `murmur` |
| `fdbm_global__<table>` | none | no | Value is a logical database name; writes broadcast to every physical database, reads use one replica |

### ID generation

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `fdbm_idmaker` | `uuid,1` | no | `uuid[,1\|4\|6\|7]` / `snowflake[,0..1023]` / `sequence` / custom extension name |
| `fdbm_sequenceDatabase` | first physical database of the default logical database | no | Allocation database for `sequence`, either a logical or a physical name |

The `sequence` generator requires a `fountain_sequence(table_name, current_value, increment)`
table in the allocation database; startup self-check verifies it, and allocation runs as
"transaction + `select ... for update`".

### Routing cache

| Key | Default | Required | Notes |
| --- | --- | --- | --- |
| `fdbm_cache` | `true` | no | Enables the partition-key → physical database cache |
| `fdbm_cache_expire` | never | no | Expiry (`Duration`, e.g. `30s`); empty = never |
| `fdbm_cache_size` | `0` | no | Capacity limit, `0` = unlimited; beyond the limit no new keys are written (existing hits still work) |
| `fdbm_cachePath` | `./cache` | no | `f_store` directory |

Startup validates everything before accepting connections (driver uniqueness, custom
extension loading and name clashes, cross references, algorithm/generator parameters,
timeouts) and exits with `CONFIG` / `NO_DRIVER` / `PARTITION_CONFIG` / `ID_GENERATOR` on
failure. A failed `boot.sh` normalization is logged and does not block startup.

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
