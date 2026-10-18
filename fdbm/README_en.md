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
| `fountain::fdbm.sql` | Lexer/parser, AST, parameter binding, partition-key extraction, rendering |
| `fountain::fdbm.resources` | `NodeAccessor` and physical pools (one per `<host:port> + database`) |
| `fountain::fdbm.route` | Seven partition algorithms, five-state routing, routing cache, global tables |
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
