# mockdb
`fountain::f_mockdb` is a database driver mocking tool.
---

## Import

```cj
import fountain::f_mockdb.*
```


## Usage

```cj
import fountain::f_mockdb.*
private let _ = {=>
    MOCKDB.clear()//Clear the fixtures once at the beginning of each test case (rows, column info, toThrowOn* flags, metadata, lastInsertId, rowCount); execution is left untouched
    MOCKDB.execution = {sql: String, args: ArrayList<Any> =>
        //Add the various mock results here; you can inspect the sql and args parameters and call the functions below to decide what to fill into mockdb
        let row: Array<Any> = [...]
        MOCKDB.addQueryResultRow(row)//Add one query result row; the order of the array elements is the column order of the select clause
        MOCKDB.addQueryResultColumnInfo(//Add the column info of the select clause
            name: 'column_name',//Current column name
            nullable: false,//Whether the current column allows null
            typeName: 'SqlVarchar'//Type name of the current column; see the sql.database.sql documentation for column type names. For fountain::f_orm, typeName can be either SqlDataType or a Cangjie type name
        )
        let rows: ArrayList<Array<Any>> = MOCKDB.getQueryResultRows()//Get the rows of this execution
        let columnInfos: Array<ColumnInfo> = MOCKDB.queryResultColumnInfos//Get the column info of the select clause
        MOCKDB.lastInsertId = 1//Set the ID of the last inserted row, 0 by default. public static mut prop lastInsertId: Int64
        MOCKDB.rowCount = 1//Set the number of rows affected by insert/update/delete, 0 by default. public static mut prop rowCount: Int64
        MOCKDB.toThrowOnExecuting = false//Whether to throw when executing the current SQL, false by default; when set to true the fixture is not executed and MockDbException is thrown directly. public static mut prop toThrowOnExecuting: Bool
        MOCKDB.metadata = {=>//Set the metadata of the database connection Connection, an empty HashMap<String, String> by default; Connection.getMetaData() returns a copy
            let map = HashMap<String, String>()
            ....
            map
        }()//public static mut prop metadata: Map<String, String>
    }
}()
```

## Ordering and conventions

- **One execution, one result set**: `MockStatement.query()` / `update()` first clear the rows and column info of the previous run, then run `execution`, and hand a **snapshot** of the result to `QueryResult`. Write rows/column info **inside** `execution` (writing them outside is cleared away); therefore several queries in the same thread (including inside a transaction) never mix data.
- **Parameter slots**: the parameters of `set` / `setNull` are cleared when that execution ends ⇒ when the same `Statement` is reused, the parameters must be bound again before every execution; a negative parameter index, or one **≥ the number of `?` placeholders in the SQL** (the upper bound follows the real driver, to avoid huge index values expanding into an enormous number of placeholders), throws `SqlException`. **Parameter value convention: if `args[i]` is `None<Any>` it is treated as SQL NULL** —— both unbound positions (holes filled in by `set`) and values written by `setNull` are `None<Any>`; mock does not distinguish the two and does not validate that all parameters were set (a real driver reports an error at execution time); to assert an "explicit NULL" in a fixture, just check `args[i].isNone()`.
- **Result set contract**: `getOrNull<T>` returns `None` only when "the column is SQL NULL"; it throws `SqlException` when the row is not ready (no `next()`) or the column index is out of bounds; it also throws `SqlException` when the column value type does not match `T`. `get<T>` = `getOrNull` + `getOrThrow`, and throws `NoneValueException` on a real NULL.
- **Column info**: `displaySize` of `MockColumnInfo` returns `Int64.Max`, and `length` / `scale` return `0` (the std contract values for "unlimited / column size not applicable / no decimals").
- **Close semantics**: after `close()`, `isClosed()` is `true` and `Connection.state` is `Closed` (closing again is idempotent); **closing a connection no longer clears the fixtures**; manage fixtures explicitly with `MOCKDB.clear()`.
- **Output switch**: internal mock actions (`open`, `setOption`, the transaction steps, `EMPTY_EXECUTION` when no fixture is set) produce **no output** by default; set `MOCKDB.verbose = true` when investigating "why is my fixture not taking effect".
- **Public members of `MOCKDB`**: `clear()` (clear all fixtures), `clearQueryResult()` (clear only rows and column info), `verbose`, `currentThreadId`, `execution`, `addQueryResultRow`, `addQueryResultColumnInfo`, `getQueryResultRows`, `queryResultColumnInfos`, `metadata`, `lastInsertId`, `rowCount`, and the `toThrowOn*` family.
- **Transactions**: `MockTransaction` has a minimal state machine —— `commit` / `rollback` / `save` / `release` without `begin()`, a repeated `begin()`, and `commit` / `rollback` after the transaction has ended all throw `SqlException`. Failures are still simulated with `toThrowOnBeginning` / `toThrowOnCommitting` / `toThrowOnReleasing(sp)` / `toThrowOnRollbacking` / `toThrowOnRollbackingSavePoint(sp)` / `toThrowOnSavingSavePoint(sp)` (read/write in pairs), and the thrown `MockDbException` carries the failing step (including the SQL text or the savepoint name).
- **Driver entry arguments**: `MockDriver.open(connectionString, opts)` records the connection string in `MockDatasource.connectionString`, and `setOption` accumulates into `MockDatasource.options` (reads return a copy) ⇒ test cases can assert that the arguments really reached the driver.

## Public types

| Type | Description |
|---|---|
| `MOCKDB` | Static facade; the fixtures (rows, column info, lastInsertId/rowCount, toThrowOn*, metadata) are isolated per thread |
| `MockDriver <: Driver` | Registers a driver named `mockdb`, with `version` `1.0.0` and `preferredPooling` `false` |
| `MockDatasource <: Datasource` | Carrier of the connection string and options |
| `MockConnection <: Connection` | `state` toggles between `Connected`/`Closed`; `createTransaction()`, `getMetaData()`, `prepareStatement(sql)` |
| `MockStatement <: Statement` | `set<T>`/`setNull`/`query()`/`update()`; `query(params)`/`update(params)` are unsupported |
| `MockTransaction <: Transaction` | `accessMode`/`deferrableMode`/`isoLevel` + `begin`/`commit`/`rollback`/`save`/`release` |
| `MockQueryResult <: QueryResult` | `columnInfos`, `next()`, `get<T>(index)`, `getOrNull<T>(index)` |
| `MockUpdateResult <: UpdateResult` | Public constructor `MockUpdateResult(lastInsertId, rowCount)`; snapshotted at construction |
| `MockColumnInfo <: ColumnInfo` | Public constructor `MockColumnInfo(name, nullable, typeName)`; `displaySize` is `Int64.Max`, `length`/`scale` are `0` |
| `MockDbException <: Exception` | Failures signalled by mock itself |

In addition, `public import std.database.sql.*` re-exports the std types `Driver`/`Connection`/`Statement`/`QueryResult`/`UpdateResult`/`ColumnInfo`/`SqlDbType`/`SqlException`/`DriverManager`/`TransactionAccessMode` and so on.
