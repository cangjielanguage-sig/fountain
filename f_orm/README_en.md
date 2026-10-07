# fountain::f_orm API reference

> This document is compiled from the current source of the `f_orm` module (`f_orm/cjpm.toml`: package name `f_orm`, version `1.3.6`, output type
> `dynamic`) and describes the exposed types, function signatures and usage.
> Dependent packages: `f_app`, `f_aspect`, `f_base`, `f_bean`, `f_cache`, `f_collection`, `f_config`, `f_data`, `f_exception`, `f_log`, `f_macros`,
> `f_pool`, `f_regex`, `f_util`, `cangjie_tpc::charset4cj`, `std.database.sql`, `std.reflect`, `std.convert`.

## Contents

1. [Module overview and package structure](#1-module-overview-and-package-structure)
2. [Quick start](#2-quick-start)
3. [Configuration reference](#3-configuration-reference)
4. [`ORM`: the registration and initialization entry point](#4-orm-the-registration-and-initialization-entry-point)
5. [`SqlExecutor`: the SQL executor](#5-sqlexecutor-the-sql-executor)
6. [`RootDAO`: generic DAO capabilities](#6-rootdao-generic-dao-capabilities)
7. [`SqlPartial`: the object-oriented CRUD entry point](#7-sqlpartial-the-object-oriented-crud-entry-point)
8. [`SqlDSL`: template SQL](#8-sqldsl-template-sql)
9. [DSL clauses: `IntoClause` / `UpdateClause` / `FromClause`](#9-dsl-clauses-intoclause--updateclause--fromclause)
10. [Logical expressions and column objects](#10-logical-expressions-and-column-objects)
11. [Condition builders](#11-condition-builders)
12. [Pagination](#12-pagination)
13. [Result mapping](#13-result-mapping)
14. [Transactions](#14-transactions)
15. [Macros](#15-macros)
16. [Table schema metadata and migro](#16-table-schema-metadata-and-migro)
17. [Exception hierarchy](#17-exception-hierarchy)
18. [Sensitive information](#18-sensitive-information)
19. [Appendix](#19-appendix)

---

## 1. Module overview and package structure

`f_orm` is an ORM layer for the Cangjie `std.database.sql`; its core design:

* **A DAO is an interface**: a business DAO is declared as an interface that only needs to extend `RootDAO`; adding the `@DAO` macro gives the
  interface all the capabilities of `SqlExecutor` (the interface itself does not need an implementation, but default implementations must be
  provided for the interface functions).
* **A PO is a mapping**: for data objects (POs) the `@QueryMappersGenerator` / `@ORMField` macros generate the column mapping (`queryMappers()`)
  and automatically complete the "data row → object" filling.
* **Parameter safety**: SQL parameters are uniformly bound as `?` placeholders through `arg(...)` / `add(...)`, avoiding injection by concatenation.
* **Transactions and connections are kept within a thread**: `SqlExecutor` is cached in a `ThreadLocal` by driver name, so several database
  accesses of one transaction within the same thread share the same connection.

### Package structure

| Package | Contents |
| --- | --- |
| `fountain::f_orm` | Module entry point, `public import fountain::f_orm.base.*`; the `base` package re-exports `std.convert`, `std.database.sql`, `std.reflect`, `f_base.ExitCallbacks`, `f_bean`, `f_exception.{BaseException, UnreachableException}`, `f_orm.wrap`, `f_orm.exception` |
| `fountain::f_orm.base` | Core: `ORM`, `SqlExecutor`, `RootDAO`, `SqlPartial`, `SqlDSL`, the DSL clauses, logical expressions, condition builders, `QueryMappers`, `Pagination`, `DirtyTag`, transaction hooks, etc. |
| `fountain::f_orm.wrap` | Wrapper layer: `ORMConfig`, `NamedDatasource`, `DatabasePool`, `SqlArg`/`SqlArgs`, `QueryResultWrap`, `StatementWrap`, `TransactionWrap`, `Propagation`, `DataType`, etc. |
| `fountain::f_orm.macros` | Macros: `@DAO`, `@ORMField`, `@QueryMappersGenerator`, `@TransactionalService`, `@EmbedSensitive` |
| `fountain::f_orm.exception` | `ORMException`, `SqlArgException`, `NoIdException`, `TransactionException`, `MandatoryTransactionException`, `NeverTransactionException`, etc. |
| `fountain::f_orm.migro` | Table schema comparison and DDL generation (`SchemaFinder`, `SchemaFinderMediator`, `MysqlSchema`, `PostgresSchema`, `SubCommand`) |

---

## 2. Quick start

### 2.1 Configuration (environment variables)

All configuration of `f_orm` comes from environment variables (see [section 3](#3-configuration-reference)):

```bash
export orm_drivers=postgres                 # Comma-separated list of driver names
export orm_defaultDriver=postgres           # May be omitted; when omitted the first driver is the default
export postgres_orm_connectionUrl=$POSTGRES # <driver name>_orm_connectionUrl specifies the connection URL
```

### 2.2 Initialization

Call `ORM.initialize()` in the application initialization file:

```cangjie
import fountain::f_orm.*

ORM.initialize()   // Equivalent to register() + registerTransactionHooks<TransactionHook>()
//A dedicated initialization module is best
```

> When the `f_app` application framework is used there is no need to call it by hand: the built-in `ORMInitializer` of `f_orm`
> (see [19.4](#194-other-utility-types)) is registered with `InitializerCollection`, and `ORM.initialize()` is executed automatically at
> application startup.

### 2.3 Defining a PO

```cangjie
import fountain::f_orm.*
import fountain::f_orm.macros.*

@QueryMappersGenerator
public class UserPO {
    @ORMField['id']            // Specifies the column name; without @ORMField the member name is by default converted into an all-lowercase underscore-separated string as the column name
    public var id: Int64 = 0
    @ORMField['username']
    public var username: String = ''
    @ORMField['password']
    public var password: String = ''
}
```

### 2.4 Defining a DAO

A DAO is declared as an **interface** extending `RootDAO`, and the `@DAO` macro generates the implementation. Inside the interface body
`executor` can be used directly:

```cangjie
@DAO
public interface UserDAO <: RootDAO {
    func findUser(id: Int64): UserPO {
        executor.FROM<UserPO>().WHERE(UserPO.tableColumns().id.eq(id)).first<UserPO>().getOrThrow()
    }

    func register(username: String, password: String): Int64 {
        let user = UserPO()
        user.username = username
        user.password = password
        executor.INSERT_INTO<UserPO>(user)          // Returns the auto-increment primary key
    }

    func changePassword(username: String, password: String): Int64 {
        let map = HashMap<Column, Any>()            // The key may be a column object, a column name or a member name
        map[UserPO.tableColumns().password] = password
        map[UserPO.tableColumns().username] = username
        executor.UPDATE<UserPO>(map)                // The primary key column is used as the WHERE condition
        /*
        //This also works
        let columns = UserPO.tableColumns()
        executor.UPDATE<UserPO>([(columns.password, password), (columns.username, username)])
        */
    }

    func pageUsers(userLike: String): Pagination<UserPO> {
        executor.FROM<UserPO>()
            .WHERE(meet(userLike.size > 0) { UserPO.tableColumns().username.LIKE('%${userLike}%') })
            .ORDER_BY(UserPO.tableColumns().id.ASC())
            .page<UserPO>(100, page: 1)
    }

    func deleteUser(id: Int64): Int64 {
        executor.setSql('delete from user_info where id = ${arg(id)}').delete
        // This also works: executor.FROM<UserPO>().deleteById(id)
    }
}
```


### 2.5 Calling

After expansion, `@DAO` generates `extend SqlExecutor <: UserDAO {}`, that is, **the `SqlExecutor` within the thread is itself the DAO
implementation** (the function bodies in the interface are the DAO method implementations). There are therefore two ways to obtain a DAO:

```cangjie
// ① In a Service: the Service interface extends RootService, so executor() is used directly
public interface UserService <: RootService {
    func queryUser(id: Int64): UserPO
}

@TransactionalService
public class UserServiceImpl <: UserService {
    public func queryUser(id: Int64): UserPO {
        executor().findUser(id)          // The SqlExecutor returned by executor() can be used directly as a UserDAO
    }
}

// ② Obtain the DAO explicitly
let dao: UserDAO = ORM.executor()        // Or dao<UserDAO>() (which needs a RootService context)
let user = dao.findUser(1)
```

> Within the same thread `ORM.executor()` returns the same executor, so all DAO calls within a transaction share the same connection.

---

## 3. Configuration reference

All configuration is provided as **environment variables** and read by `fountain::f_orm.wrap.ORMConfig`. The naming conventions:

* Global configuration: `orm_<key>`;
* **Per-driver override**: `<driverName>_orm_<key>`, which takes precedence over the global configuration (`getConf` looks up
  `<driverName>_<key>` first and falls back to the global `key`);
* `orm_option_<key>=<value>` (**singular** `option`): collected as driver initialization options (`getAllOptions()` / `getOption(key)`),
  typically `orm_option_username`, `orm_option_password`.

### 3.1 Drivers and connections

| Environment variable | Type / default | Description |
| --- | --- | --- |
| `orm_drivers` | Comma-separated list | The list of driver names to initialize; `ORM.register()` registers `NamedDatasource`s in bulk according to it |
| `orm_defaultDriver` | `String`, default `''` | The default driver name; used by `ORM.connection()` / `ORM.executor()` when they are called without arguments. When unset it falls back to the **first** driver of the `orm_drivers` list, and if that is still empty it is `''`. `ORMConfig.isDefaultDriver(...)` uses the same rule |
| `orm_connectionUrl` / `<driver>_orm_connectionUrl` | `String` | Connection string; `ORMException` is thrown when it is missing |
| `orm_option_<key>` | `key=value` | Driver initialization parameters (**singular** `option`; read by `getOption` / `getUsername` / `getPassword`) |
| `orm_useCache` | `Bool`, default `true` | Whether to cache SQL execution results (cached by SQL + parameters). When it is unset at driver level it falls back to the global setting, and if that is unset too it is `true`; note that `ORMConfig.getUseCache()` itself returns `None` when unset and the `true` fallback happens in `SqlExecutor` (`useCache = getUseCache(...) ?? true`) |
| `orm_noPool` | `Bool`, default `false` | `true` means no connection pool is used |
| `orm_useStdPool` | `Bool`, default `true` | `true` uses the standard library `PooledDatasource`; `false` uses `DatabasePool` |
| `orm_useThirdPartyPool` | `Bool`, default `false` | `true` means a third-party connection pool is used: `f_orm` creates no connection pool and `ORM.register(datasource, default: false)` must be called yourself |
| `orm_indexStartsWithZero` | `Bool`, default `true` | `true` → `getIndexStartsWith()` returns 0 (column indices start at 0), otherwise it returns 1 |

> When `mockdb` is configured, `ORM.register()` registers only the `mockdb` datasource and does not initialize the other drivers.
> When `orm_useThirdPartyPool=true`, do not configure `orm_noPool` / `orm_databasePool*` / `orm_stdPool*`; the connection pool is created and
> registered entirely by the business code.

### 3.2 Transaction defaults

| Environment variable | Type / default | Description |
| --- | --- | --- |
| `orm_transactionPropagation` | `Propagation`, default `Required` | Default propagation behavior |
| `orm_transactionLevel` | `?TransactionIsoLevel`, default `None` | Isolation level |
| `orm_transactionAccessMode` | `?TransactionAccessMode`, default `None` | Read/write mode |
| `orm_transactionDeferrableMode` | `?TransactionDeferrableMode`, default `None` | Deferrable mode |
| `orm_transactionNoRollbackFor` | `?String` | Names of exception classes that trigger a **commit** (no rollback); several separated by `\|` |
| `orm_transactionRollbackFor` | `?String` | Names of exception classes that trigger a rollback; several separated by `\|` |
| `orm_transactionIncluding` | Regex | Functions included by the transaction aspect (`transactionable(funcName)`) |
| `orm_transactionExcluding` | Regex | Functions excluded by the transaction aspect |
| `orm_transactionalFuncExecution` | `\|`-separated signature patterns | Functions that need the transaction aspect weaved in, such as `*::*..*ServiceImpl.del*(**): *` |

**Propagation behaviors** (upper case, `_` / `-` / camel case are all accepted): `Required`, `Supports`, `Mandatory`, `RequiresNew`
(`requires_new`, `REQUIRES-NEW`, `requiresNew`), `Never`, `NotSupported` (`not_supported`, `NOT-SUPPORTED`…), `Nested`. An illegal value throws
`IllegalArgumentException`.

**Isolation levels**: `Default` / `Unspecified`, `ReadCommitted`, `ReadUncommitted`, `RepeatableRead`, `Snapshot`, `Serializable`, `Linearizable`, `Chaos`.

**Read/write modes**: `Default` / `Unspecified`, `ReadWrite`, `ReadOnly`.

**Deferrable**: `Default` / `Unspecified`, `Deferrable`, `NotDeferrable`.

### 3.3 `DatabasePool` (the fountain connection pool)

| Environment variable | Default | Unit / description |
| --- | --- | --- |
| `orm_databasePoolInitSize` | `10` | Initial number of connections |
| `orm_databasePoolMinSize` | `10` | Minimum number of connections |
| `orm_databasePoolMaxSize` | `10` | Maximum number of connections |
| `orm_databasePoolCheckInterval` | `300` | Seconds, connection validity check period |
| `orm_databasePoolConnectTimeout` | `50` | **Milliseconds**, timeout for obtaining a connection from the pool |
| `orm_databasePoolIdleTimeout` | `0` | Seconds; `0` means idle connections never expire |
| `orm_databasePoolConnectionLife` | `3600` | Seconds, connection lifetime |
| `orm_databasePoolCheckOnCreation` | `false` | Whether to validate when a connection is created |
| `orm_databasePoolCheckOnBorrowing` | `true` | Whether to validate when a connection is borrowed |
| `orm_databasePoolCheckOnReturning` | `false` | Whether to validate when a connection is returned |
| `orm_databasePoolCheckSql` | `select 1` | Validation SQL |

### 3.4 Standard library connection pool (`std.datasource.sql.PooledDatasource`)

| Environment variable | Default | Unit / description |
| --- | --- | --- |
| `orm_stdPoolMaxSize` | `None` | Maximum number of connections |
| `orm_stdPoolMaxIdleSize` | `None` | Maximum number of idle connections |
| `orm_stdPoolIdleTimeout` | `None` | Seconds, connection idle time |
| `orm_pooledDatasourceMaxLifeTime` (that is `stdPoolMaxLifeTime`) | `None` | Seconds, connection lifetime |
| `orm_stdPoolConnectionTimeout` | `None` | **Microseconds**, connection acquisition timeout |
| `orm_stdPoolKeepaliveTime` | `None` | Seconds, connection keep-alive check period |

### 3.5 `ORMConfig` static API

```cangjie
package fountain::f_orm.wrap:

public class ORMConfig {
    public static const mockdb = 'mockdb'
    // public static const values with the same names as the environment variables: defaultDriver = 'orm_defaultDriver', drivers = 'orm_drivers',
    // connectionUrl, useCache, noPool, useStdPool, useThirdPartyPool, databasePool*, stdPool*,
    // transaction*, transactionalFuncExecution, indexStartsWithZero, sm4*, ormOption = 'orm_option_'

    // Refresh and converters
    public static func refresh(fn: () -> Unit): Unit
    public static func registerConverter<D, T>(name: String, converter: (D) -> T)
    public static func getConverter<D, T>(name: String): (D) -> T

    // Raw configuration reads
    public static func getConf(driverName!: String = String.empty, key!: String): ?String
    public static func getAllConfigs(driverName!: String = String.empty): Map<String, String>
    public static func getAllOptions(driverName!: String = String.empty): Array<(String, String)>

    // Drivers
    public static func getDefaultDriver(): String        // orm_defaultDriver ?? first driver of orm_drivers ?? ''
    public static func isDefaultDriver(driver: String)   // Whether the driver name is the default driver
    public static func isDefaultDriver(driver: Driver)   // Equivalent to the above, using driver.name
    public static func getDriverNames(): Iterator<String>
    public static func getDrivers(): Iterator<Driver>
    public static func getUrl(driverName!: String = String.empty): String

    // Sensitive information (written into sensitiveMap at compile time by @EmbedSensitive, read at runtime; see section 18)
    public static func genKey(driverName: String, suffix: String): String          // '<driverName>_<suffix>'
    public static func registerSensitive(key: String, value: Array<Byte>): Unit
    public static func getOption(option: String, driverName!: String = String.empty): ?String
    public static func getUsername(driverName!: String = String.empty): ?String
    public static func getPassword(driverName!: String = String.empty): ?String

    // Connection pool switches
    public static func getUseCache(driverName!: String = String.empty): ?Bool
    public static func getNoPool(driverName!: String = String.empty)
    public static func getUseStdPool(driverName!: String = String.empty): Bool
    public static func getUseThirdPartyPool(driverName: String)

    // The fountain connection pool
    public static func getPoolInitSize(driverName!: String = String.empty): Int64
    public static func getPoolMinSize(driverName!: String = String.empty): Int64
    public static func getPoolMaxSize(driverName!: String = String.empty): Int64
    public static func getCheckOnCreation(driverName!: String = String.empty): Bool
    public static func getCheckOnBorrowing(driverName!: String = String.empty): Bool
    public static func getCheckOnReturning(driverName!: String = String.empty): Bool
    public static func getIdleTimeout(driverName!: String = String.empty): Duration
    public static func getConnectionLife(driverName!: String = String.empty): Duration
    public static func getPoolCheckInterval(driverName!: String = String.empty): Duration
    public static func getConnectTimeout(driverName!: String = String.empty): Duration
    public static func getPoolCheckSql(driverName!: String = String.empty, default!: String = 'select 1'): String

    // Transactions
    public static func transactionable(funcName: String): Bool
    public static func getTransactionPropagation(driverName!: String = String.empty): Propagation
    public static func getTransactionLevel(driverName!: String = String.empty): ?TransactionIsoLevel
    public static func getTransactionAccessMode(driverName!: String = String.empty): ?TransactionAccessMode
    public static func getTransactionDeferrableMode(driverName!: String = String.empty): ?TransactionDeferrableMode
    public static func getTransactionNoRollbackFor(driverName!: String = String.empty): ?String
    public static func getTransactionRollbackFor(driverName!: String = String.empty): ?String

    // Standard library connection pool
    public static func getStdPoolIdleTimeout(driverName!: String = String.empty): ?Duration
    public static func getStdPoolMaxLifeTime(driverName!: String = String.empty): ?Duration
    public static func getStdPoolConnectionTimeout(driverName!: String = String.empty): ?Duration
    public static func getStdPoolKeepaliveTime(driverName!: String = String.empty): ?Duration
    public static func getStdPoolMaxSize(driverName!: String = String.empty): ?Int32
    public static func getStdPoolMaxIdleSize(driverName!: String = String.empty): ?Int32

    public static func getIndexStartsWith(driverName!: String = String.empty): Int64
}
```

---

## 4. `ORM`: the registration and initialization entry point

`public class ORM` is the global facade; internally it keeps datasources by driver name in a
`ConcurrentHashMap<String, NamedDatasource>`.

```cangjie
public class ORM {
    // Initialization / registration
    public static func initialize()                                          // register() + registerTransactionHooks<TransactionHook>()
    public static func register()                                            // Registers in bulk according to orm_drivers / orm_defaultDriver; only the default driver is set as ORM.default
    // The default value of default! is uniformly ORMConfig.isDefaultDriver(<driver name>): the driver is set as ORM.default only when it is the default driver
    public static func register(datasource: NamedDatasource, default!: Bool = ORMConfig.isDefaultDriver(datasource.driverName)): Unit
    public static func register(creator: DatasourceCreator, default!: Bool = ORMConfig.isDefaultDriver(creator.driverName)): Unit
    public static func register(driver: Driver, default!: Bool = ORMConfig.isDefaultDriver(driver)): Unit
    public static func register(driver: Driver, opts: Array<(String, String)>, default!: Bool = ORMConfig.isDefaultDriver(driver)): Unit
    public static func register(driver: Driver, url: String, default!: Bool = ORMConfig.isDefaultDriver(driver)): Unit
    public static func register(driver: Driver, url: String, opts: Array<(String, String)>, default!: Bool = ORMConfig.isDefaultDriver(driver)): Unit
    public static func register(driver: String, default!: Bool = ORMConfig.isDefaultDriver(driver)): Unit
    public static func register(driver: String, opts: Array<(String, String)>, default!: Bool = ORMConfig.isDefaultDriver(driver))
    public static func register(driver: String, url: String, default!: Bool = ORMConfig.isDefaultDriver(driver))
    public static func register(driver: String, url: String, opts: Array<(String, String)>, default!: Bool = ORMConfig.isDefaultDriver(driver))
    public static func getDriver(driver: String): Driver                     // Equivalent to ORMConfig.getDriver; throws ORMException when it is not registered
    public static func deregister(name: String): Unit
    public static func deregisterAndReplaceDefault(newDefault: String): Unit
    public static func close()                                               // Already registered as a process exit callback (ExitCallbacks)

    // Connections and executors
    public static func connection(): Connection
    public static func connection(name: String): Connection
    public static func executor(): SqlExecutor
    public static func executor(driverName: String): SqlExecutor

    // Transaction hooks
    public static func registerTransactionHook<T>(hook: T): Unit where T <: TransactionHook
    public static func registerTransactionHooks<T>(): Unit where T <: TransactionHook   // Registers in bulk from lookupList<T>()

    public static prop databasesNames: Array<String>
}
```

Behavior:

* `register(driver, ...)` skips an **already registered driver of the same name**: `register(driver, opts)` returns **silently**, while
  `register(driver)`, `register(driver, url)` and `register(driver, url, opts)` print a `warn` log
  (`driver <name> has been registered`). Registering an already existing `NamedDatasource` again simply `close()`s the new datasource.
* Details of `register()` (the bulk registration without arguments): when `orm_drivers` contains `mockdb`, **only `mockdb` is registered and it
  returns directly**; drivers with `orm_useThirdPartyPool=true` are skipped (the business registers them itself); `default` is judged as
  `default.isEmpty() || driver.name == default`.
* The default value of the `default` argument is an **expression** `ORMConfig.isDefaultDriver(<driver name>)`, that is, a driver becomes the
  default datasource (`ORM.default`) only when it happens to be the default driver; passing `default: true` / `default: false` explicitly
  overrides this. The default datasource is used by the no-argument overloads of `ORM.connection()` / `ORM.executor()`; when it is not
  specified, `ORMException("default datasource is not specified")` is thrown.
* `deregister(name)`: only when the name is in the internal datasource table does it also call `DriverManager.deregister(name)` and close the
  datasource; clearing the default datasource (when `name == default`) happens unconditionally.
* The actual behavior of `deregisterAndReplaceDefault(newDefault)` is to **deregister the current default datasource** (`deregister(default)`,
  unrelated to `newDefault`) and then set the default driver name to `newDefault`.
* Passing an **empty string** to `connection(name)` / `executor(driverName)` is equivalent to using the default datasource (the default driver
  branch is taken internally).
* `register(driver: String, ...)` calls `ORM.getDriver` → `ORMConfig.getDriver` → `DriverManager.getDriver(...)` internally; when the driver is
  not registered it throws `ORMException('database driver ${driverName} does not initialize')`.
* `register(creator: DatasourceCreator, ...)` first calls `creator.create()` to obtain a `NamedDatasource` and then registers it; the
  `creator.driverName` used to compute the default value of `default` is provided by the implementation (see [19.2](#192-advanced-types-of-the-wrap-layer)).
* `databasesNames` comes from `DriverManager.drivers()` (the drivers registered in the process) and is not the key set of the internal datasource
  table of `ORM`.

---

## 5. `SqlExecutor`: the SQL executor

```cangjie
public class SqlExecutor <: Resource & RootDAO {
    public prop executor: SqlExecutor       // Returns this, to make chained writing inside a DAO easier
    public prop isReadOnly: Bool            // Whether the current SQL starts with select; the current implementation only sets false for non-select and has no branch setting true, so it is always false
    public prop update: Int64               // Executes UPDATE and returns the number of affected rows
    public prop delete: Int64               // Executes DELETE and returns the number of affected rows
    public prop insert: Int64               // Executes INSERT and returns the lastInsertId
}
```

**Singleton per thread**: `SqlExecutor` is cached in a `ThreadLocal<HashMap<String, SqlExecutor>>`, separated by driver name, and obtained
through `ORM.executor()`. On acquisition the connection state is checked: `Closed` is reset directly to `NoneConnection`, and `Broken` is closed
and then reset.

The key of the result cache is `public class SqlCacheKey <: Hashable & Equatable<SqlCacheKey> & ToString`
(`init(sql: String, args: SqlArgs)`; `hashCode` / `==` / `toString` are based on the SQL and the arguments).

**Execution model**:

* Outside a transaction, `close()` is called and the connection is released as soon as the execution finishes; inside a transaction the final
  handling is done uniformly at the end of the transaction.
* The result cache is **enabled by default** (`useCache = ORMConfig.getUseCache(driverName) ?? true`); the result of a read operation is cached by
  `SqlCacheKey(sql, args)`; a write operation (the update / insert / delete paths) sets `clearCache` first and empties the whole cache once the
  execution finishes. When a cache hit has a type that does not match the current call,
  `ORMException("type of cached data with key '<sql> | <args>' does not match")` is thrown.
* After every execution a `debug` log is recorded (driver name, SQL, arguments, elapsed time), and the SQL is then cleared; whether the
  arguments are cleared depends on `clearArgsAfterExec` (`setSql` defaults to `true`, while `page` / `singlePage` use `false` to reuse the
  arguments). When the SQL is empty this log is not written.
* **Concurrency is not allowed** on the same `SqlExecutor`: executing again while the result of the previous query is still open throws
  `ORMException("cannot execute SQL while a previous query result is still active")`.

### 5.1 Setting the SQL and binding arguments

```cangjie
public func setSql(sql: String, clearArgsAfterExec!: Bool = true): SqlExecutor
public operator func ()(sql: String): SqlExecutor      // executor('select 1')

public func add<T>(arg: T): SqlExecutor where T <: ToString
public func addNull(): SqlExecutor

public func add(arg: Bool)      public func add(arg: ?Bool)
public func add(arg: Int8)      public func add(arg: ?Int8)
public func add(arg: UInt8)     public func add(arg: ?UInt8)
public func add(arg: Int16)     public func add(arg: ?Int16)
public func add(arg: UInt16)    public func add(arg: ?UInt16)
public func add(arg: Int32)     public func add(arg: ?Int32)
public func add(arg: UInt32)    public func add(arg: ?UInt32)
public func add(arg: Int64)     public func add(arg: ?Int64)
public func add(arg: UInt64)    public func add(arg: ?UInt64)
public func add(arg: Float16)   public func add(arg: ?Float16)
public func add(arg: Float32)   public func add(arg: ?Float32)
public func add(arg: Float64)   public func add(arg: ?Float64)
public func add(arg: BigInt)    public func add(arg: ?BigInt)
public func add(arg: Decimal)   public func add(arg: ?Decimal)
public func add(arg: Rune)      public func add(arg: ?Rune)
public func add(arg: String)    public func add(arg: ?String)
public func add(arg: Duration)  public func add(arg: ?Duration)
public func add(arg: DateTime)  public func add(arg: ?DateTime)
public func add(arg: InputStream)      public func add(arg: ?InputStream)
public func add(arg: Array<Byte>)      public func add(arg: ?Array<Byte>)

public func add(arg: Any)              // Dispatches at runtime by ToString / InputStream; other types throw SqlException
protected func add(all!: SqlExecutor)  // Merges the arguments of another executor
```

Notes:

* The `?T` overloads of the various types are equivalent to `addNull()` when the value is `None`, that is, they bind SQL `NULL`.
* The generic `add<T>(arg: T) where T <: ToString` does type matching first (covering every type in the table above except `InputStream` /
  `?InputStream`), and falls back to `add(arg.toString())` when nothing matches; therefore `InputStream` can only go through the explicit
  overload `add(arg: InputStream)`.
* Arguments are written into the `PreparedStatement` through `SqlArgs`; `clearArgsAfterExec: false` allows the same batch of arguments to be
  reused across several executions (which is what `page` / `singlePage` do internally).
* The parameter index base is decided by `orm_indexStartsWithZero` (starting at 0 by default, otherwise at 1): `StatementWrap.set(index)` adds
  that base internally.

### 5.2 Queries

**Single-column mapping** (the first column of the result set, or a given column index/name):

```cangjie
public func singleFirst<T>(): Option<T>                 // First row, first column
public func singleFirst<T>(index: Int64): Option<T>     // Given column index
public func singleFirst<T>(column: String): Option<T>   // Given column name

public func singleList<T>(): ArrayList<T>
public func singleList<T>(index: Int64): ArrayList<T>
public func singleList<T>(column: String): ArrayList<T>

public func singleIterator<T>(): SingleColumnIterator<T>
public func singleIterator<T>(index: Int64): SingleColumnIterator<T>
public func singleIterator<T>(column: String): SingleColumnIterator<T>
```

**Object mapping** (relies on `QueryMappers`):

```cangjie
public func first<T>(mappers: QueryMappers<T>): Option<T>    // First row
public func first<T>(): Option<T> where T <: QueryMappersInit<T>
public func list<T>(mappers: QueryMappers<T>): ArrayList<T>  // All rows
public func list<T>(): ArrayList<T> where T <: QueryMappersInit<T>
public func iterator<T>(mappers: QueryMappers<T>): QueryResultIterator<T>
public func iterator<T>(): AbstractQueryResultIterator<T> where T <: QueryMappersInit<T>
public func one<T>(mappers: QueryMappers<T>): Option<T>      // Similar to first, used for grouped mappings
public func one<T>(): Option<T> where T <: QueryMappersInit<T>
```

**Untyped mapping** (returns a Map):

```cangjie
public func firstToMap(): Map<String, Any>              // First row → Map (returns EmptyMap when there is no result)
public func mapList(): ArrayList<HashMap<String, Any>>  // All rows → list of Maps
```

> When `T.isSimpleData()` is `true` (basic types and so on), `first<T>()` / `list<T>()` / `iterator<T>()` / `one<T>()` automatically degrade
> to the corresponding `singleXxx` versions.
> The static type returned by the three iterator entry points (`singleIterator<T>()` with its `index` / `column` overloads,
> `iterator<T>(mappers)` and `iterator<T>()`) is `Resource`: `try (it = ...)` closes it automatically, and `close()` may also be called
> explicitly; it is likewise closed automatically when `next()` is exhausted.

### 5.3 Update / delete / insert

```cangjie
executor.setSql('update user_info set username = ${arg(name)} where id = ${arg(id)}').update   // Int64 number of affected rows
executor.setSql('delete from user_info where id = ${arg(id)}').delete                          // Int64 number of affected rows
executor.setSql('insert into user_info(username) values(${arg(name)})').insert                 // Int64 lastInsertId
```

### 5.4 Generic execution entry points

```cangjie
// Simplified entry point: wraps the closure as (executor(exec), true) and delegates to the transaction template below,
// so a transaction is started with the default propagation behavior (that is, the version that does not return whether to commit also goes through a transaction)
public func execute<T>(executor: (SqlExecutor) -> T): T

// Transaction template: starts a transaction automatically and decides commit/rollback from the return value
public func execute<T>(
    propagation!: Propagation = ORMConfig.getTransactionPropagation(driverName: driverName),
    isoLevel!: ?TransactionIsoLevel = ORMConfig.getTransactionLevel(driverName: driverName),
    accessMode!: ?TransactionAccessMode = ORMConfig.getTransactionAccessMode(driverName: driverName),
    deferrableMode!: ?TransactionDeferrableMode = ORMConfig.getTransactionDeferrableMode(driverName: driverName),
    noRollbackFor!: ?String = ORMConfig.getTransactionNoRollbackFor(driverName: driverName),
    rollbackFor!: ?String = ORMConfig.getTransactionRollbackFor(driverName: driverName),
    executor!: (SqlExecutor) -> (T, Bool)      // Second return value: true → commit; false → throw ORMException and roll back
): T
```

Order of transaction hook calls:

| Scenario | Order |
| --- | --- |
| Normal commit (the closure returns `true`) | `beforeTx` → `beforeCommit` → `commit` → `afterCommit` → `afterComplete(Committed)` |
| Ordinary exception | `afterThrowing` → `beforeRollback` → `rollback` → `afterRollback` → `afterComplete(Rollback)` |
| The exception matches `noRollbackFor` | `afterThrowing` → `beforeCommit` → `noRollbackFor()` (commits internally) → `afterCommit` → `afterComplete(Committed)` → rethrow |
| The exception matches `rollbackFor` | `afterThrowing` → `beforeRollback` → `rollbackFor()` (rolls back internally) → `afterRollback` → `afterComplete(Rollback)` → rethrow |
| `rollbackFor` is configured but the exception **does not match** | Same as "the exception matches `noRollbackFor`": commit and then rethrow (no rollback) |

> When the closure returns `false` the thrown exception is a message-less `ORMException()`, which takes the "ordinary exception" path and rolls back.
> The argument of `beforeCommit(readOnly)` comes from `SqlExecutor.isReadOnly`, which is always `false` in the current implementation (see section 5).

### 5.5 Transaction control

```cangjie
// Create a transaction and start it according to the propagation behavior (Propagation decides whether to join an existing transaction,
// suspend, or create a new one)
public func newTxAndBegin(
    propagation!: Propagation = ORMConfig.getTransactionPropagation(driverName: driverName),
    isoLevel!: ?TransactionIsoLevel = ORMConfig.getTransactionLevel(driverName: driverName),
    accessMode!: ?TransactionAccessMode = ORMConfig.getTransactionAccessMode(driverName: driverName),
    deferrableMode!: ?TransactionDeferrableMode = ORMConfig.getTransactionDeferrableMode(driverName: driverName)
): SqlExecutor

public func commit(): Unit
public func rollback(): Unit
public func rollback(savepoint: String): Unit

public func noRollbackFor(e: Exception): Exception     // Commits immediately (without registering); on commit failure it returns a wrapper exception and tries to roll back, on success it returns the argument e
public func rollbackFor(e: Exception): Exception       // Rolls back immediately; on failure it returns a wrapper exception, on success it returns the argument e

public func callAndCommit<T>(callee: () -> T): T       // Requires a transaction to be started first (otherwise TransactionException("no transaction started") is thrown); executes callee and then commits; this function does not roll back and simply rethrows when callee throws
public func save(savepoint: String): Unit              // Creates a savepoint; silently does nothing when there is no transaction
public func release(savepoint: String): Unit           // Releases a savepoint; silently does nothing when there is no transaction

public func isClosed(): Bool
public func close(): Unit                              // Resource implementation; only really wraps up when "there is no transaction and the connection is not closed" (see below)
```

Semantics of `close()`: it really wraps up **only when the executor is not currently in a transaction (`tx.isNone()`) and the connection is not
closed** —— it clears `current` in the `ThreadLocal`, removes the driver from `currents`, empties the result cache, closes the statement and the
connection, replaces the connection with `NoneConnection` and calls `DirtyTag.clearAll()`. While in a transaction `close()` does nothing; the
wrap-up after a commit/rollback is done by the `finishTransaction` inside `commit()` / `rollback()` calling `close()` at the very end (except for
suspended connections).

---

## 6. `RootDAO`: generic DAO capabilities
**Be sure** that one DAO function executes only one SQL statement, or one paginated query (consisting of one count query and one list query),
otherwise an exception occurs
```cangjie
public interface RootDAO {
    public prop executor: SqlExecutor
}
```

Every DAO interface gets `executor` simply by extending it (the `@DAO` macro injects the implementation). `RootDAO` also provides the following
helper functions that **return `String`**, for assembling SQL fragments; they are all **ordinary interface methods (with default
implementations)**, so they can be called directly inside a DAO interface body.

### 6.1 Argument binding: `arg` / `argNull`

`arg(...)` binds one argument and returns the placeholder `'?'`; therefore, when it is written into "template SQL", string interpolation
`${arg(x)}` is used:

```cangjie
executor.setSql('delete from user_info where id = ${arg(id)}')
```

The supported types are basically the same as `SqlExecutor.add`, plus two overloads unique to `arg` (absent from `add`), `InputStream` and `Data`:

```cangjie
func arg(value: Bool): String      func arg(value: Int8): String     func arg(value: UInt8): String
func arg(value: Int16): String     func arg(value: UInt16): String   func arg(value: Int32): String
func arg(value: UInt32): String    func arg(value: Int64): String    func arg(value: UInt64): String
func arg(value: Float16): String   func arg(value: Float32): String  func arg(value: Float64): String
func arg(value: BigInt): String    func arg(value: Decimal): String  func arg(value: Rune): String
func arg(value: String): String    func arg(value: Duration): String func arg(value: DateTime): String
func arg(value: Array<Byte>): String
func arg(value: InputStream): String
func arg(value: ?T): String        // Option overloads for the various types; None → argNull()
func arg(value: Data): String      // Dispatches at runtime by DataBool / DataReal (bound via toString) / DataString / DataNone and so on; other Data throws SqlArgException
func arg(value: Any): String       // Runtime dispatch, covering the types above
func argNull(): String             // Binds NULL and returns '?'
```

**Collection expansion** (produces a placeholder list, suitable for `IN`; an empty collection returns the empty string `''`):

```cangjie
func arg<I, T>(values: I): String where I <: Iterable<T>                    // One-dimensional collection → ' (?,?,?)'
func arg<I1, I2, T>(values: I1): String where I1 <: Iterable<I2>, I2 <: Iterable<T>   // Two-dimensional collection → ' ((?,?),(?,?))'
```

### 6.2 Conditional fragments: `meet`

`meet` is the syntactic sugar for "concatenate only when the condition holds":

```cangjie
// 1) When the condition holds, execute f() to get the SQL fragment, otherwise return the empty string
func meet(condition: Bool, partial: () -> String): String
func meet(condition: Bool, partial: () -> LogicalExpr): LogicalExpr
func meet(condition: Bool, partial: () -> Array<LogicalExpr>): LogicalExpr

// 2) A group of (condition, fragment) pairs, judged one by one
func meet(pairs: Array<(() -> Bool, () -> LogicalExpr)>): LogicalExpr
func meet(pairs: Array<(() -> Bool, () -> Array<LogicalExpr>)>): LogicalExpr

// 3) Returns a MeetCondition builder that can be chained further
func meet(condition: Bool, partial: String): MeetCondition
func meet(condition: Bool, partial: String, value: Any): String
func meet(condition: Bool, partial: String, value: () -> Any): String
```

Example:

```cangjie
let expr = meet(name.size > 0) { 'username = ${arg(name)}' }
// name is empty → ''; otherwise → 'username = ?', which can be interpolated into the SQL directly
```

> Besides returning the fragment, `meet(condition, partial: () -> String)` has a **side effect**: when it hits, the fragment is appended to the
> `partials` of the current executor, which is why fragments accumulate inside `WHERE{}` / `SET{}` closures.

`MeetCondition` is described in [11.2](#112-meetcondition).

### 6.3 Condition builder entry points

```cangjie
prop choose: ChooseCondition                          // executor.choose
func loop<I, T>(values: I): LoopCondition<I, T> where I <: Iterable<T>
func WHERE(partial: () -> String): String
func WHERE(delimiter: String, partial: () -> String): String
func SET(partial: () -> String): String
func trim(prefix!: String, suffix!: String, partial!: () -> String): String
```

`WHERE` / `SET` / `trim` are used to concatenate clauses on demand (the prefix keyword is omitted automatically when the content is empty):

```cangjie
executor.setSql('update user_info ${SET { 'username = ${arg(name)}, password = ${arg(pwd)}' }} where id = ${arg(id)}')
executor.setSql('select * from user_info ${WHERE { 'id = ${arg(id)}' }}')
```

### 6.4 Logical and relational operators (the `String` versions)

These functions produce **SQL fragments that can be interpolated directly** (note that `IN` / `LIKE` / `BETWEEN` and so on only return the
operator part, and the left-hand value must be concatenated on the left yourself):

```cangjie
// Logical connections (return ' and ... ' / ' or ... ' / ' not ... ')
func AND(value: String): String                    func AND(partial: () -> String): String
func OR(value: String): String                     func OR(partial: () -> String): String
func NOT(value: String): String                    func NOT(partial: () -> String): String
func paren(partial: () -> String): String          // ' (...) '

// Relational operator fragments
func IN<I, T>(value: I): String where I <: Iterable<T>        // ' in (?,?,...) '
func NOT_IN<I, T>(value: I): String where I <: Iterable<T>    // ' not in (?,?,...) '
func LIKE(value: String): String                              // ' like ? '
func LIKE(value: () -> String): String
func NOT_LIKE(value: String): String                          // ' not like ? '
func NOT_LIKE(value: () -> String): String
func BETWEEN(one: Any, two: Any): String                      // ' between ? and ? '
func BETWEEN(one: () -> Any, two: () -> Any): String
func EXISTS(exists: () -> String): String                     // ' exists (...) '
func NOT_EXISTS(notExists: () -> String): String              // ' not exists (...) '
```

Example:

```cangjie
executor.setSql('select * from user_info where id ${IN(ids)}')
executor.setSql('select * from user_info where username ${LIKE('%${name}%')}')
executor.setSql('select * from user_info where id = ${arg(id)} ${AND {'status = ${arg(status)}'}}')
```

There are corresponding `LogicalExpr` versions (`AND` / `OR` / `NOT`, accepting `Array<LogicalExpr>` or `() -> Array<LogicalExpr>` /
`LogicalExpr`); see [section 10](#10-logical-expressions-and-column-objects).

---

## 7. `SqlPartial`: the object-oriented CRUD entry point

`public interface SqlPartial <: RootDAO` defines the ability to operate on the database in terms of "objects / columns". `SqlExecutor` implements
it (`extend SqlExecutor <: SqlPartial`), so calls such as `executor.INTO<T>(...)` are available.

Every type parameter `T` requires `T <: QueryMappersInit<T>`, that is, the PO must have its mapping generated by `@QueryMappersGenerator`
(see [15.2](#152-querymappersgenerator)).

### 7.1 Insert

```cangjie
// Builds an INSERT statement in a chainable way (ignore/include compare internally by "column name" against mapper.dataType.columnName)
func INTO<T>(
    ignoreColumns!: Array<String> = [],        // Column names to ignore
    includingColumns!: Array<String> = []      // Column names to insert only (mutually exclusive with ignoreColumns)
): IntoClause<T> where T <: QueryMappersInit<T>

// Inserts an object in one step and returns the auto-increment primary key (lastInsertId)
func INTO<T>(values: T, ignoreColumns!: Array<String> = []): Int64
    where T <: QueryMappersInit<T> & ObjectData<T>

// Same as above, but Column objects are used to specify the ignored columns
func INSERT_INTO<T>(ignoreColumns!: Array<Column> = [], includingColumns!: Array<Column> = []): IntoClause<T>
func INSERT_INTO<T>(values: T, ignoreColumns!: Array<Column> = []): Int64
```

Example:

```cangjie
let id = executor.INSERT_INTO<UserPO>(user, ignoreColumns: [UserPO.tableColumns().password])                       // Returns the new primary key; ignoreColumns may be omitted
let id2 = executor.INTO<UserPO>(user, ignoreColumns: ['password']) // Ignores the password field
executor.INTO<UserPO>().VALUES(user).INSERT(columns: ['username']).execute()   // See 9.1
```

### 7.2 Update

**(1) Direct Map update**: the `key` may be a column name, a member name or a `Column` object, and `value` is the new value.

```cangjie
// The primary key is used as the WHERE condition (values must contain the primary key entry, otherwise NoIdException is thrown)
func UPDATE<T>(values: Map<String, Any>): Int64
func UPDATE<T>(values: Map<Column, Any>): Int64
func UPDATE<T>(values: Array<(Column, Any)>): Int64

// Explicitly giving the primary key
func UPDATE<T, ID>(values: Map<String, Any>, id: ID): Int64
func UPDATE<T, ID>(values: Map<Column, Any>, id: ID): Int64
func UPDATE<T, ID>(values: Array<(Column, Any)>, id: ID): Int64
```

Exception messages (per the source code): empty `values` → `SqlArgException('no column to udpate')`; the PO has no primary key →
`NoIdException(<fully qualified PO name>)`; there is a primary key but no non-primary-key column matches →
`SqlArgException('no column to update')`.

```cangjie
let map = HashMap<Column, Any>()
map[UserPO.tableColumns().password] = pwd
map[UserPO.tableColumns().username] = name
executor.UPDATE<UserPO, Int64>(map, 1)          // where id = ?
map[UserPO.tableColumns().id] = 1
executor.UPDATE<UserPO>(map)                    // where username = ?
var values = [(UserPO.tableColumns().password, pwd), (UserPO.tableColumns().username, name)]
executor.UPDATE<UserPO, Int64>(values, 1)
values = [(UserPO.tableColumns().password, pwd), (UserPO.tableColumns().username, name), (UserPO.tableColumns().id, 1)]
executor.UPDATE<UserPO>(values)
```

**(2) Direct object update**: the primary key of the PO is used as the `WHERE` condition and the `SET` is generated from the column mapping.

```cangjie
func UPDATE<T>(values: T): Int64
func UPDATE<T>(values: T, dirty!: Bool): Int64
func UPDATE<T>(values: T, ignoredColumns!: Array<String>,  includingColumns!: Array<String>): Int64
func UPDATE<T>(values: T, ignoredColumns!: HashSet<String>, includingColumns!: HashSet<String>): Int64
func UPDATE<T>(values: T, ignoredColumns!: Array<Column>,   includingColumns!: Array<Column>): Int64
func UPDATE<T>(values: T, ignoredColumns!: HashSet<Column>, includingColumns!: HashSet<Column>): Int64
// All of the versions above also have a dirty!: Bool overload
    where T <: QueryMappersInit<T> & ObjectData<T>
```

* `ignoredColumns` and `includingColumns` **must not be given together**, and neither may be given together with `dirty: true`, otherwise
  `IllegalArgumentException` is thrown (with the messages `'ignoredColumns and includingColumns must not be specified both.'` and
  `'ignoreColumns includingColumns and true value for dirty must not be specified at the same time for update.'`).
* With `dirty: true` only the dirty fields recorded by `DirtyTag` are updated (a PO is marked automatically through the setter generated by
  `@ORMField`); when there is no dirty field it returns `0` directly without executing SQL; the set of dirty fields used this time is cleared in
  `finally`.
* When all columns are excluded (the `SET` part is empty) it returns `0` and executes no SQL.

**(3) Chainable construction**:

```cangjie
func UPDATE<T>(): UpdateClause<T>               // UPDATE table
func UPDATE<T>(AS!: String): UpdateClause<T>    // UPDATE table AS alias
```

### 7.3 Queries

```cangjie
func FROM<T>(): FromClause<T>                    // select ... from table
func FROM<T>(AS!: String): FromClause<T>         // select ... from table AS alias
```

**Case-insensitive prefix constraint**: the `page` family requires the SQL to start with `select` (followed by whitespace), otherwise
`ORMException('<sql> is not a select.')` is thrown.

```cangjie
// Pagination: count(*) is computed first for the total, then the limit/offset query runs as needed
func page<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R>
    where R <: QueryMappersInit<R> & DataFields<R>

// Pagination + single column mapping
func singlePage<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R>          // column defaults to 0
func singlePage<R>(sql: String, column: Int64, size: Int64, page!: Int64 = 1): Pagination<R>
    where R <: DataFields<R>

// Takes only the first row (limit 1 is added automatically)
func singleFirst<T>(sql: String): ?T                 // Equivalent to singleFirst<T>(sql, 0)
func singleFirst<T>(sql: String, column: Int64): ?T
func singleFirst<T>(sql: String, column: String): ?T
func first<T>(sql: String, mappers: QueryMappers<T>): Option<T>
func first<T>(sql: String): Option<T> where T <: QueryMappersInit<T>
func firstToMap(sql: String): Map<String, Any>       // First row → Map
```

The `count` query looks like `select count(*) from (<original SQL>) as __tmp___`, and the paginated query looks like
`select * from (<original SQL>) as __tmp___ <limit/offset>`. The `limit/offset` is generated by the dialect (`Dialect`), so the pagination syntax
differences between databases are hidden; the offset is fixed to `(page - 1) * size` and has nothing to do with `orm_indexStartsWithZero`
(that setting only affects the column/parameter index base, see [3.1](#31-drivers-and-connections)).

```cangjie
let p = executor.page<UserPO>('select * from user_info where age > ${arg(18)}', 20, page: 1)
p.rows    // Total number of records
p.pages   // Total number of pages
p.list    // The data of the current page, ArrayList<UserPO>
```

---

## 8. `SqlDSL`: template SQL

For the scenario "write the field names directly in the SQL and let the framework bind the parameters", avoiding hand-written `arg(...)`
interpolation.

```cangjie
public interface SqlDSL {
    // The interface declaration carries no default values; the default value true of clearArgsAfterExec is in the extension implementation below
    func setSqlFromMap(dsl: String, arg: Map<String, Any>, clearArgsAfterExec!: Bool): SqlExecutor
    func setSqlFromObject<T>(dsl: String, arg: T, clearArgsAfterExec!: Bool): SqlExecutor
        where T <: ObjectData<T>
}
```

`SqlExecutor` implements this interface (`extend SqlExecutor <: SqlDSL`, with the `clearArgsAfterExec` of both methods defaulting to `true`).

### 8.1 Syntax

| Form | Meaning |
| --- | --- |
| `:name` | Binds the field/key named `name` in `arg`, producing `?` |
| `:{a.b.c}` | Binds a **data path** (`DataPath`) and takes the nested value of the object |
| `:{name}` | Equivalent to `:name` |
| `?` | **Must not** be mixed with the template DSL; its appearance throws `IllegalArgumentException` |

* For `Map<String, Any>`: the `:{...}` path form is not supported (it throws `IllegalArgumentException`); the value may only be `ToData` (`Data`),
  `InputStream` or `None`, and any other type throws
  `IllegalArgumentException('... which key is ... in current Map<String, Any> is not supported yet.')`.
* For a PO (`ObjectData<T>`): the path form is allowed, and both `:{user.name}` and `:{$.user.name}` work.
* Value conversion rules: `None` → `NULL`; `Bool`/`DateTime`/`Duration`/`String`/`Array<Byte>` → an ordinary parameter; numbers → bound in string
  form; `Iterable<Data>` → expanded into several comma-separated `?` (convenient for `IN`); other types throw `IllegalArgumentException`.
* The compiled result is cached by the DSL text (`HeapCache`, at most 10000 entries, expiring after 1 day).

### 8.2 Example

```cangjie
let argMap = HashMap<String, Any>()
argMap['id'] = 1
executor.setSqlFromMap('delete from user_info where id = :id', argMap).delete
// Produces: delete from user_info where id = ?

executor.setSqlFromObject('update user_info set username = :username where id = :id', user)
```

When used with clauses, the DSL can be written directly inside the `SET` / `WHERE` closures:

```cangjie
executor.UPDATE<UserPO>()
    .SET(arg: userMap) { 'username = :username' }
    .WHERE(arg: userMap) { 'id = :id' }
    .execute()
```

---

## 9. DSL clauses: `IntoClause` / `UpdateClause` / `FromClause`

The three clause classes all extend `TableClause<T>` / `ExceptInsertClause<T>`, accumulate SQL fragments on top of a `StringGenerator`, and are
finally executed by concrete methods.

```cangjie
// Note: TableClause is not public and is sealed, so it cannot be referenced outside the package; it serves only as the base class of
// FromClause / UpdateClause / IntoClause
abstract sealed class TableClause<T> <: ToString where T <: QueryMappersInit<T> {
    public prop executor: SqlExecutor          // The associated executor
    public func toString(): String             // The SQL fragment accumulated so far
    prop tableName: String                     // T.tableName()
    prop idType: ?DataType                     // The data type of the primary key column of the PO (taken from the first mapper with isId)
    prop dialect: SqlDialect                   // The dialect resolved from driverName
}

public abstract class ExceptInsertClause<T> <: TableClause<T> where T <: QueryMappersInit<T> { /* see 9.1 */ }
```

`appendPartial(keyword, trim, partial)` uses `emptyLogicalExpr` (the regex `^[\s()]*$`) to decide whether the fragment is empty:
**when it is empty nothing is concatenated at all**, and only when it is non-empty is ` keyword fragment ` appended, so fragments may be
accumulated first and written in later.

### 9.1 Common capabilities (`ExceptInsertClause`)

**Multi-table joins** (the joined table name comes from the type parameter `T`):

```cangjie
public func INNER_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T>
public func LEFT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T>
public func RIGHT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T>
public func FULL_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T>
// All four also have ON!: LogicalExpr and ON!: () -> LogicalExpr overloads
```

When `ON` is empty (or `()`, `( )`) no `ON` clause is generated; the generated keywords are `' inner join '`, `' left outer join '`,
`' right outer join '` and `' full outer join '` respectively, and the `LogicalExpr` / closure version of `ON` is wrapped in one pair of
parentheses by `ParenExpr`.

**Conditions**:

```cangjie
public func WHERE(condition: () -> Unit): This          // Generates the where from the partials accumulated inside cond
public func WHERE(condition: String): This
public func WHERE(condition: LogicalExpr): This
public func WHERE(condition: () -> LogicalExpr): This
public func WHERE(arg: Map<String, Any>, condition: () -> String): This         // DSL template
public func WHERE<T>(arg: T, condition: () -> String): This where T <: ObjectData<T>

public func AND(condition: () -> Unit): This      public func AND(condition: String): This
public func OR(condition: () -> Unit): This       public func OR(condition: String): This
public func NOT(condition: () -> Unit): This      public func NOT(condition: String): This
public func PAREN(condition: () -> Unit): This    public func PAREN(condition: String): This
public func PAREN(op: CondRelOp, condition: () -> Unit): This
public func PAREN(op: CondRelOp, condition: String): This

public func ORDER_BY(order: Array<Column>): This
public func ORDER_BY(orderBy: () -> String): This
public func LIMIT(size: Int64, offset!: Int64 = 0): This       // Generates limit/offset through the dialect
```

> `WHERE` / `AND` / `OR` / `NOT` first trim any leftover `and` / `or` keyword at the start and end of the fragment with the regex
> `^(\s*and|or\s*)|(\s*and|or\s*)$` (case insensitive), and then hand it to `appendPartial` to test for emptiness before concatenating it into
> the SQL; the closure versions (`() -> Unit`) are usually used together with `executor.AND{...}` / `executor.OR{...}` and the like to accumulate
> fragments, while `PAREN` does not go through the trimming logic.
> Besides appending `limit ? offset ?`, `LIMIT(size, offset)` also `add`s the two arguments into the current executor in the order returned by
> the dialect.

Example:

```cangjie
executor.FROM<UserPO>()
    .LEFT_JOIN<DeptPO>(AS: 'd', ON: { UserPO.tableColumns().deptId.eq(DeptPO.tableColumns().id) })
    .WHERE { AND { [UserPO.tableColumns().status.eq(1)] } }
    .ORDER_BY(UserPO.tableColumns().id.ASC())
    .list<UserPO>()
```

### 9.2 `FromClause<T>` (query / delete)

```cangjie
// Query
public func first<T>(): ?T                                       // limit 1
public func first<T>(columns: String): ?T
public func first<T>(columns: Columns): ?T
public func first<T>(columns: Array<SqlExpr>): ?T                // The columns may be Column, COUNT()/SUM() and similar SqlFunc
public func singleFirst<T>(column: String): ?T
public func singleFirst<T>(column: SqlExpr): ?T
public func list<T>(): ArrayList<T>
public func list<T>(columns: String): ArrayList<T>
public func list<T>(columns: Columns): ArrayList<T>
public func list<T>(columns: Array<SqlExpr>): ArrayList<T>
public func singleList<T>(): ArrayList<T>                        // Takes the id column by default
public func singleList<T>(column: String): ArrayList<T>
public func singleList<T>(column: SqlExpr): ArrayList<T>
public func firstToMap(): Map<String, Any>
public func count(): Int64

// Pagination
public func page<R>(size: Int64, page!: Int64 = 1): Pagination<R>
public func page<R>(columns: String, size: Int64, page!: Int64 = 1): Pagination<R>
public func singlePage<R>(size: Int64, page!: Int64 = 1): Pagination<R>              // Takes the id column by default
public func singlePage<R>(column: String, size: Int64, page!: Int64 = 1): Pagination<R>

// By primary key
public func findById(id: Int64): ?T
public func findById(id: UInt64): ?T
public func findById(id: String): ?T
public func deleteById(id: Int64): ?T
public func deleteById(id: UInt64): ?T
public func deleteById(id: String): ?T

// Grouping
public func GROUP_BY(groupBy: () -> String): This
public func GROUP_BY(group: Array<Column>): This
public func HAVING(condition: () -> Unit): This
public func HAVING(condition: String): This
public func HAVING(logical: LogicalExpr): This
public func HAVING(arg: Map<String, Any>, condition: () -> String): This
public func HAVING<T>(arg: T, condition: () -> String): This where T <: ObjectData<T>

// Delete
public func DELETE(): Int64
public func DELETE(sql: String): Int64          // Produces 'delete <sql> <clauses>'
```

> In `findById` / `deleteById` / `count` the primary key column name is taken from `T.queryMappers().idName` and falls back to `'id'` when it is
> missing.
> `count()` produces `select count(*) from (select 1 <clauses>) as __tmp___`.
> The return value of `deleteById` is declared as `?T` (it actually executes the DELETE statement through `first<T>()`); for everyday use,
> `DELETE()` / `executor.delete` are recommended instead.

### 9.3 `UpdateClause<T>` (update)

```cangjie
public func SET(set: () -> String): This
public func SET(set: Array<LogicalExpr>): This
public func SET(set: () -> Array<LogicalExpr>): This
public func SET(arg: Map<String, Any>, condition: () -> String): This            // DSL template
public func SET<T>(arg: T, condition: () -> String): This where T <: ObjectData<T>

public func execute(): Int64                        // Executes the update and returns the number of affected rows
public func byId(id: Int64): Int64                  // Appends where <primary key>=? and executes
public func byId(id: UInt64): Int64
public func byId(id: String): Int64
```

Example:

```cangjie
executor.UPDATE<UserPO>()
    .SET { 'username = ${arg(name)}' }
    .byId(1)

executor.UPDATE<UserPO>()
    .SET([UserPO.tableColumns().username.eq('tom'), UserPO.tableColumns().status.eq(1)])
    .WHERE { UserPO.tableColumns().id.eq(1) |> {c => c.toString()} }
    .execute()
```

### 9.4 `IntoClause<T>` (insert)

```cangjie
public func VALUES(values: Array<Any>): This                              // Binds them one by one in column order
public func VALUES<D>(value: D): This where D <: ObjectData<D>            // Binds a PO directly
public func SELECT<T>(selectColumns: String): This where T <: QueryMappersInit<T>
public func SELECT<T>(selectColumns: String, fromClause: (FromClause<T>) -> Unit): This
                                                                          // insert into ... select ...
public func ON_DUPLICATE_KEY_UPDATE(columns: () -> String): This         // MySQL style
public func ON_CONFLICT(columns: Array<String>, DO_UPDATE_SET!: () -> String): This   // PostgreSQL style
public func execute()                                                     // Returns lastInsertId
```

* When both `ignoreColumns` and `includingColumns` are non-empty at construction, `ORMException("ignores and includes can't be used together")` is thrown.
* When the PO has a primary key column, the dialect's `lastInsertId` fragment is appended automatically after `VALUES` (such as MySQL's `; select last_insert_id()`).
* `VALUES<D>` converts numbers according to the field type (`DataReal` → the target column type); unsupported field types throw `SqlArgException`.

Example:

```cangjie
executor.INTO<UserPO>()
    .VALUES([1, 'tom', 'pwd'])
    .ON_DUPLICATE_KEY_UPDATE { 'username = values(username)' }
    .execute()

executor.INTO<UserPO>().VALUES(user).execute()
executor.INSERT_INTO<UserPO>().SELECT<UserPO>('id, username'){ from =>
    from.WHERE { UserPO.tableColumns().status.eq(1) }
}.execute()
```

---

## 10. Logical expressions and column objects

### 10.1 `Column` and `Columns`

`@QueryMappersGenerator` generates a column set class for the PO (extending `Columns`) and the static method `T.tableColumns()`:

```cangjie
public interface QueryMappersObject<T, C> <: QueryMappersInit<T>
    where C <: Columns, T <: QueryMappersObject<T, C> {
    static func tableColumns(): C
}

public abstract class Columns <: ToString & Iterable<Column> {
    public func tableAlias(alias: String): This       // Sets the table alias for all columns of this column set
}

// Base class of SQL expressions: columns (Column), aggregate functions (SqlFunc) and logical expressions (LogicalExpr) all extend it,
// so AS / ASC / DESC and the comparison methods eq / IN / LIKE and so on are available uniformly on all three
public abstract class SqlExpr <: ToString {
    public func AS(alias: String): This               // Alias (mutually exclusive with ASC/DESC)
    public func ASC(): This                           // Ascending
    public func DESC(): This                          // Descending

    // Comparison operators → LogicalExpr, inherited directly by the subclasses (Column / SqlFunc)
    public func eq(arg: Any): LogicalExpr
    public func neq(arg: Any): LogicalExpr
    public func lt(arg: Any): LogicalExpr
    public func gt(arg: Any): LogicalExpr
    public func lte(arg: Any): LogicalExpr
    public func gte(arg: Any): LogicalExpr
    public func LIKE(arg: Any): LogicalExpr
    public func NOT_LIKE(arg: Any): LogicalExpr
    public func IN<T>(arg: Collection<T>): LogicalExpr
    public func NOT_IN<T>(arg: Collection<T>): LogicalExpr
    public func IN<T, I>(arg: Collection<I>): LogicalExpr where I <: Collection<T>      // Two-dimensional collection
    public func NOT_IN<T, I>(arg: Collection<I>): LogicalExpr where I <: Collection<T>
    public func BETWEEN(one: Any, two: Any): LogicalExpr
    public func NOT_BETWEEN(one: Any, two: Any): LogicalExpr
    public func IS_NULL(): LogicalExpr
    public func IS_NOT_NULL(): LogicalExpr
}

public class Column <: SqlExpr & Hashable & Equatable<Column> {
    public Column(let name: String)                   // The column name is passed to the primary constructor
    // Note: name is not declared public (it defaults to internal); outside the package use toString() instead
    public func hashCode(): Int64
    public operator func ==(other: Column): Bool
    public func tableAlias(alias: String): This       // Table alias (there are also AS / ASC / DESC inherited from SqlExpr)
    public func toString(): String
}

// Aggregate function expression, returned by COUNT / SUM / AVG / MAX / MIN of RootDAO (see 10.5)
public class SqlFunc <: SqlExpr & Hashable & Equatable<SqlFunc> {
    // The constructor is internal; business code obtains instances through COUNT() and the like
    public func toString(): String                    // → ' fn(col) ' (the alias / ordering is attached after it)
}
```

> `Column.toString()` quotes the identifier through `SqlExecutor.involve(...)` (backticks or double quotes, depending on the dialect), so
> concatenations such as `'select * from t where ${col} = 1'` are safe; `Column('*')` is the special case that produces ` * ` or
> ` <table alias>.* ` without quotes.
> If both `AS(...)` and `ASC()/DESC()` are set, `toString()` throws
> `ORMException('column alias and column alias cannot be set at the same time')`.
> `Columns.tableAlias(alias)` only records the alias on the column set object; it really takes effect in the `toString()` of the generated class,
> which calls `.tableAlias(super.tableAlias_)` once for every `Column`, so the alias must be set before the columns are used.
> The parameter types of `first<T>(columns)` / `list<T>(columns)` / `singleFirst<T>(column)` / `singleList<T>(column)` are `Array<SqlExpr>` /
> `SqlExpr`, so both `Column` and `SqlFunc` (`COUNT()` etc.) can be passed directly.

### 10.2 The `CmpOp` / `RelationOp` enums

```cangjie
public enum CmpOp <: ToString {
    | EQ | NEQ | LT | LTE | GT | GTE
    | IN | NOT_IN | LIKE | NOT_LIKE
    | IS_NULL | IS_NOT_NULL | BETWEEN | NOT_BETWEEN
}   // toString() → " = ", " <> ", " < ", " <= ", " > ", " >= ", " IN ", " NOT IN ",
    //                " LIKE ", " NOT LIKE ", " IS NULL ", " IS NOT NULL ", " BETWEEN ", " NOT BETWEEN "

public enum RelationOp <: ToString { | AND | OR | NOT }   // toString() → " AND ", " OR ", " NOT "

// The connective enum used by the clause PAREN(op, ...), whose toString() is lower case:
public enum CondRelOp <: ToString { | AND | OR | NOT }    // toString() → "and", "or", "not"
```

### 10.3 The `LogicalExpr` family

```cangjie
public abstract class LogicalExpr <: SqlExpr & ToString {}   // An abstract class that also extends SqlExpr

public class EmptyExpr <: LogicalExpr                       // Empty expression: toString() → ''; AS/ASC/DESC and all comparison methods return itself
private struct ExprSqlExec <: RootDAO {}                    // Package-level helper type: renders literals via RootDAO.arg
public open class CmpExpr <: LogicalExpr                    // Single column comparison, such as `id = ?`; supports the AS / ASC / DESC suffixes
public class BetweenExpr <: CmpExpr                         // `col BETWEEN ? AND ?`
public class InExpr<T> <: LogicalExpr                       // `col IN (?, ...)`
public class In2Expr<I, T> <: LogicalExpr where I <: Collection<T>   // Two-dimensional IN
public class NullExpr <: CmpExpr                            // `col IS NULL` / `IS NOT NULL`
public class RelationExpr <: LogicalExpr & ToString         // AND / OR / NOT combination
public class ParenExpr <: LogicalExpr & ToString            // Parentheses
public class CommaExpr <: LogicalExpr & ToString            // Comma separated (used for multi-column SET assignment)
```

> `LogicalExpr` is now an abstract class extending `SqlExpr`, so aliases (`AS`), ordering (`ASC` / `DESC`) and the comparison methods
> `eq` / `IN` / `LIKE` and so on are equally available on logical expressions; `CmpExpr.toString()` appends the `AS` / `ASC|DESC` suffix.
> The constructors of the expression classes above are all internal; business code constructs them only through the comparison methods of
> `Column` / `SqlFunc`, through `RootDAO.AND/OR/NOT`, through `meet(...)` and through the `SET` / `WHERE` / `HAVING` of the clauses.
> When rendering, `InExpr` / `In2Expr` treat `Column` specially —— the unquoted column name is used directly
> (`case x: Column => ' ${x.name} ...'`), while other `SqlExpr`s go through `toString()`.
> `RelationExpr` skips empty expressions when concatenating; `NOT` accepts only one operand, otherwise
> `SqlArgException('NOT only support one expr')` is thrown; `ParenExpr` returns `''` directly for an empty expression.

### 10.4 The `LogicalExpr` versions of the logical operations of `RootDAO`

```cangjie
//The LogicalExpr returned by AND/OR/NOT when they take an Array or a LogicalExpr is NOT wrapped in parentheses
func AND(exprs: Array<LogicalExpr>): LogicalExpr
func OR(exprs: Array<LogicalExpr>): LogicalExpr
func NOT(exprs: LogicalExpr): LogicalExpr
//The LogicalExpr returned by AND/OR/NOT when they take a closure IS wrapped in parentheses automatically
func AND(exprs: () -> Array<LogicalExpr>): LogicalExpr
func OR(exprs: () -> Array<LogicalExpr>): LogicalExpr
func NOT(exprs: () -> LogicalExpr): LogicalExpr
//When the array has only one element it is as if AND/OR/NOT were not used
```

Example (from `fdemo`):

```cangjie
executor.FROM<UserPO>().WHERE(
    AND([ meet(username.size > 0){ UserPO.tableColumns().username.LIKE('%${username}%') },
          meet(password.size > 0){ UserPO.tableColumns().password.LIKE('%${password}%') } ]))
    .ORDER_BY([UserPO.tableColumns().id.ASC()])
    .page<UserPO>(100, page: 1)
```

### 10.5 Common functions
COUNT, SUM, AVG, MAX and MIN are supported; they are all instance members of RootDAO and can be called directly in a DAO interface that extends RootDAO.
The return type is `SqlFunc` (a subclass of `SqlExpr`), and `toString()` produces the standard function call form: `COUNT()` → `' count(*) '` and
`COUNT(column)` → `' count(<column name>) '`, so they can be passed directly as the query column argument of `first` / `list` / `singleFirst` / `singleList`:
```cj
func COUNT(): SqlFunc              // count(*)
func COUNT(column: Column): SqlFunc
func SUM(column: Column): SqlFunc
func AVG(column: Column): SqlFunc
func MAX(column: Column): SqlFunc
func MIN(column: Column): SqlFunc
```
```cangjie
// Example: count + sum
let total = executor.FROM<UserPO>().singleFirst<Int64>(COUNT())
let sumAge = executor.FROM<UserPO>().singleList<Int64>(SUM(UserPO.tableColumns().age))
```

---

## 11. Condition builders

The "concatenate on demand" capability inside the `SET{}` / `WHERE{}` closures is provided by three builders and the static class `Condition`.
All of them append the fragment to the partials of the current `SqlExecutor` on `done()` / `frag()`, and the fragment string can also be obtained
directly from the return value.

> Entry points for obtaining instances: the constructors of `MeetCondition` / `ChooseCondition` are `public` (they can also be obtained with
> `meet(condition, partial)` and `executor.choose` respectively); the constructor of `Condition` is `private` (used statically), and the
> constructor of `LoopCondition` is internal (obtained through `executor.loop(values)`). `Condition.delimiter` is an internal
> `mut static prop` (backed by a `ThreadLocal<String>`).

### 11.1 The `Condition` static utilities

```cangjie
public class Condition {   // Private constructor; used statically
    public static func loop<I, T>(values: I, executor: SqlExecutor): LoopCondition<I, T>
        where I <: Iterable<T>

    public static func SET(partial: () -> String): String        // Prefix ' SET ', with ',' as the delimiter
    public static func WHERE(partial: () -> String): String       // Prefix ' WHERE '
    public static func WHERE(delimiter: String, partial: () -> String): String
    public static func trim(prefix!: String = '', suffix!: String = '', partial!: () -> String): String
}
```

* `SET` / `WHERE` internally **set `Condition.delimiter`** (`SET` uses `,`; `WHERE` uses the value passed by the caller, which defaults to empty),
  so that a connective is inserted automatically between `meet(...).done()` fragments.
* `trim` trims the fragment with a regex (for example `SET` trims `,` and `WHERE` trims `and|or`).
* When the fragment is empty it returns an empty string, so the `''` keyword never appears in the SQL —— this is exactly how "concatenate on
  demand" is implemented.

### 11.2 `MeetCondition` (concatenate only when the condition holds)

```cangjie
public class MeetCondition {
    public prop argInSql: MeetCondition                       // The value is concatenated into the SQL directly (no escaping, no parameter binding) —— see 11.5, use with care
    public func value(value: Any): MeetCondition
    public func value(value: () -> Any): MeetCondition
    public func frag(frag: String): String                    // Concatenates '<partial> <frag> <delimiter>'
    public func frag(frag: () -> String): String
    public func done(): String                                // partial + the bound value (produces '?')
    public func BETWEEN(one: Any, two: Any): String
    public func NOT_BETWEEN(one: Any, two: Any): String
    public func IN<I, T>(itr: I): String where I <: Iterable<T>
    public func NOT_IN<I, T>(itr: I): String where I <: Iterable<T>
    public func EXISTS(fn: () -> String): String
    public func NOT_EXISTS(fn: () -> String): String
}
```

The entry point is `meet` of `RootDAO` (see [6.2](#62-conditional-fragments-meet)). A typical form:

```cangjie
executor.setSql(
    '''
    update `character`
     ${SET{
        '''
        ${meet(param.name.size > 0, '`name`=').value{param.name}.done()}
        ${meet(param.gender.isSome(), '`gender`=').value{param.gender.getOrThrow()}.done()}
        '''
     }}
     ${WHERE{
        '''
         `id` = ${arg(param.id)}
    and ${meet(param.originName.size > 0, '`name`=').value{param.originName}.done()}
        '''
     }}
    '''
).update
```

> In `SET{}` / `WHERE{}` the template fragments only need to be separated by newlines; `meet` returns an empty string when it does not hit, and
> `trim` removes the superfluous leading/trailing `and`/`,`.

### 11.3 `ChooseCondition` (choose one branch out of several)

Entry point: `executor.choose` (`RootDAO.choose`).

```cangjie
public class ChooseCondition {
    public prop argInSql: ChooseCondition                              // As above: the value is concatenated into the SQL directly —— see 11.5, use with care
    public func condition(condition: () -> Bool): ChooseCondition      // Starts a branch
    public func partial(partial: () -> (String, Any)): ChooseCondition // The fragment and value of the branch
    public func partial(partial: () -> String): ChooseCondition
    public func partial(partial: () -> Any): ChooseCondition           // Only a value; the fragment is empty
    public func otherwise(partial: () -> (String, Any)): ChooseCondition
    public func otherwise(partial: () -> String): ChooseCondition
    public func otherwise(partial: () -> Any): ChooseCondition
    public func done(): String
}
```

`condition` and `partial` must strictly come in pairs, otherwise `ORMException('condition and sql partial generation function arg not paring')`
is thrown. The first condition that hits returns immediately; when none hits, `otherwise` is used.

```cangjie
executor.choose
    .condition { name.size > 0 }.partial { ('username like', '%${name}%') }
    .condition { id > 0 }.partial { ('id =', id) }
    .otherwise { ('1 = 1', ()) }
    .done()
```

### 11.4 `LoopCondition` (concatenate while iterating a collection)

Entry point: `executor.loop(values)` (`RootDAO.loop`).

```cangjie
public class LoopCondition<I, T> where I <: Iterable<T> {
    public func wrap(left: String, right: String): LoopCondition<I, T>    // Wrap the whole thing (prefix and suffix)
    public func wrapLeft(left: String): LoopCondition<I, T>
    public func wrapRight(right: String): LoopCondition<I, T>
    public func trim(left: String, right: String): LoopCondition<I, T>    // Trim the beginning and the end
    public func trimLeft(left: String): LoopCondition<I, T>
    public func trimRight(right: String): LoopCondition<I, T>
    public func delimiter(d: String): LoopCondition<I, T>                 // Separator between elements
    public prop argInSql: LoopCondition<I, T>                             // As above: the value is concatenated into the SQL directly —— see 11.5, use with care
    public func condition(cond: (T, Int64) -> Bool): LoopCondition<I, T>   // Filters elements (the second argument is the index)
    public func partial(partial: (T, Int64) -> (String, Any)): LoopCondition<I, T>
    public func partial(partial: (T, Int64) -> Any): LoopCondition<I, T>
    public func done(): String
}
```

```cangjie
executor.setSql(
    'select * from user_info where id in ${executor.loop(ids).wrap('(', ')').delimiter(',').partial{v, i => v}.done()}'
)
```

### 11.5 `argInSql`: concatenating values into the SQL directly (use with care)

`MeetCondition` / `ChooseCondition` / `LoopCondition` share this switch: **once it is on, the value is no longer passed to the driver as a bound
parameter but is concatenated into the SQL text through `ToString`** —— no escaping, no quoting, no validation. This is deliberate, for controlled
content that "must be inlined into the SQL text" (fixed column names, expressions such as `now()`, keywords understood by the driver).

What actually happens on a call (dispatch by the type of the value):

| Case | What appears in the SQL | Are parameters bound |
|---|---|---|
| The value satisfies `ToString` (`String`, `Int64`, `DateTime`…) | The `toString()` of the value appears as is (`name = bob`, `id = 7`) | No (there is no `?` at that position) |
| The value does not satisfy `ToString` (a class instance not implementing `ToString`) | `?` | Goes through the binding channel: `InputStream` (including `?InputStream`) can be bound; **other types throw `SqlException: Unsupported data type` while the SQL is being assembled** |
| `ChooseCondition` and the value is `()` | Only the branch fragment appears, no value (this is the path taken when `otherwise` is given "a fragment only, no value"; without `argInSql` it would leave a superfluous `?` for that fragment) | No |

`IN` / `NOT_IN` decide **element by element**, so within one list some elements may be inlined and others bound (such as `in (1,?)`).

Consequences and boundaries:

* **Do not concatenate uncontrolled content any more**: the value is neither escaped nor validated, so handing user input to `argInSql` is the same as
  opening an injection hole in the SQL text; turn it on only when the content is fully controlled.
* **Strings must carry their own quotes**: `toString()` adds no quotes, so `value('bob')` produces `name = bob` (not `name = 'bob'`); when quotes are
  needed, write them yourself and escape them yourself.
* **Of the non-`ToString` values only `InputStream` can be bound**: the remaining types throw `SqlException: Unsupported data type` while the SQL is
  being assembled (the binding rules follow `SqlExecutor.add(Any)`: `ToString` → bound by runtime type / converted to text, `InputStream` → bound,
  others → error).
* **Do not pass `?` as a value**: a value containing `?` is taken as a placeholder by the driver, and both the number and the positions of the
  parameters become wrong.
* The default (without calling `argInSql`) is the safe parameterized path: the value goes through `?` + a bound parameter; all the other examples in
  this document follow that rule.

---

## 12. Pagination

```cangjie
public class Pagination<T> <: ObjectData<Pagination<T>> where T <: DataFields<T> {
    public let page: Int64        // Current page number (starting at 1)
    public let size: Int64        // Page size
    public let rows: Int64        // Total number of records
    public let pages: Int64       // Total number of pages = rows / size rounded up
    public let list: ArrayList<T> // The data of the current page

    public init(page!: Int64, size!: Int64, rows!: Int64, list!: ArrayList<T>)
    public init(page!: Int64, size!: Int64, rows!: Int64, list!: () -> ArrayList<T>)
    public init(page!: Int64, size!: Int64, rows!: Int64, list!: (Int64, Int64) -> ArrayList<T>)

    public func toData(): Data
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any
    public static func dataFields(): ObjectFields
}
```

* When `list!` is a closure the evaluation is **lazy**: `rows == 0` returns an empty list directly and executes no query.
* The `list!: (Int64, Int64) -> ArrayList<T>` version passes `(size, (page - 1) * size)`, that is, "page size + offset".
* `Pagination` can be used as a field type of a PO (it implements `ObjectData`) and supports conversion to and from `Data`
  (`toData()` / `tryFromData`).

Inside `page` / `singlePage` (`SqlPartial`, `FromClause`) the count query is executed first to obtain `rows`, and the paginated query is then
executed according to the `list` closure:

```cangjie
let p = executor.FROM<UserPO>()
    .WHERE(UserPO.tableColumns().state.eq(1))
    .ORDER_BY([UserPO.tableColumns().id.DESC()])
    .page<UserPO>(10, page: 2)
```

---

## 13. Result mapping

### 13.1 `QueryMappersInit` and simple types

```cangjie
public interface QueryMappersInit<T> where T <: QueryMappersInit<T> {
    static func tableName(): String
    static func isSimpleData(): Bool        // Simple types return true and take the single-column mapping path
    static func queryMappers(): QueryMappers<T>
}

public interface SimpleDataQueryMappersInit<T> <: QueryMappersInit<T> where T <: QueryMappersInit<T> {
    // isSimpleData() → true; tableName() → ''; queryMappers() → throws ORMException('not supported')
}

public interface QueryMappersObject<T, C> <: QueryMappersInit<T>
    where C <: Columns, T <: QueryMappersObject<T, C> {
    static func tableColumns(): C
}
```

The module already implements `SimpleDataQueryMappersInit` for the following types: `Int8`, `UInt8`, `Int16`, `UInt16`, `Int32`, `UInt32`,
`Int64`, `UInt64`, `Float16`, `Float32`, `Float64`, `Rune`, `String`, `Bool`, `Duration`, `DateTime`, `Decimal`, `BigInt`, `Array<T>`
(where `T` is also a `QueryMappersInit`).
In addition, `Option<T>` implements `QueryMappersInit<T>` (delegating `tableName` / `isSimpleData` / `queryMappers` to `T`) and is **not** in the
list of `SimpleDataQueryMappersInit` implementations above.

### 13.2 `QueryMappers<O>`

```cangjie
public class QueryMappers<O> {
    public QueryMappers(
        protected let mappers!: Array<QueryMapper<O>>,   // One mapper per column
        protected let creator!: () -> O                  // Instance creator
    )

    // Inheritance scenario: merges the mappers of the parent class O with the new mappers of the subclass
    public static func create<T>(mappers!: Array<QueryMapper<T>>, creator!: () -> T): ?QueryMappers<T>

    public func list(result: QueryResultWrap): ArrayList<O>
    public func groupedList<ID>(result: QueryResultWrap): ArrayList<O> where ID <: Hashable & Equatable<ID>
    public func iterator(result: QueryResultWrap, statement: Statement, executor: SqlExecutor): QueryResultIterator<O>
    public func one(result: QueryResultWrap): Option<O>

    protected prop idName: ?String       // Primary key column name (None when there is no primary key)
}
```

* At construction it counts `hasGroup` (whether a grouped mapper exists) and `idMapper` (the primary key mapper).
* When a grouped mapper exists, `groupedList` deduplicates and merges by primary key; rows with the same primary key are appended to the
  collection field (one-to-many association).
* `list` / `one` generate objects by `populate`-ing column by column through `func map(result)` (`map` and the `doMap` used by the iterator are
  internal members and cannot be called outside the package).

### 13.3 The `QueryMapper` family

```cangjie
public open class QueryMapper<O> {
    public QueryMapper(dataType!: DataType = UnknownDataType(true, '', ''), putter!: (O, Any) -> Unit)
    public func get<T>(result: QueryResultWrap): ?T
    public open func populate(result: QueryResultWrap, o: O): O
    protected prop columnName: String
    protected prop fieldName: String
    protected open prop isGrouped: Bool      // false by default
    protected open prop isId: Bool           // false by default
}

public open class FieldQueryMapper<T, O> <: QueryMapper<O> {
    public init(dataType!: DataType = UnknownDataType(true, '', ''), putter!: (O, T) -> Unit)
    // populate performs the ORMConverter.convert<T> conversion by column type; nullable columns use convertNullable
}

public class IdQueryMapper<ID, O> <: FieldQueryMapper<ID, O> where ID <: Hashable & Equatable<ID> {
    public init(dataType!: DataType = Int64DataType(false, 'id', 'id'), putter!: (O, ID) -> Unit)
    public func id(result: QueryResultWrap): ID      // Takes the primary key value
}
```

**Association mappings** (generated by the association syntax in `@ORMField`):

```cangjie
public class NestQueryMapper<T, O> <: QueryMapper<O>
    where O <: QueryMappersInit<O>, T <: QueryMappersInit<T> {
    public NestQueryMapper(nested!: QueryMappers<T>, nestPutter!: (O, T) -> Unit)   // One-to-one / many-to-one
}

public class NullableNestQueryMapper<T, O> <: QueryMapper<O> {
    public NullableNestQueryMapper(nested!: QueryMappers<T>, nestGetter!: (O) -> Option<T>, nestPutter!: (O, T) -> Unit)
}

public class GroupedQueryMapper<T, O> <: QueryMapper<O> {
    public GroupedQueryMapper(grouped!: QueryMappers<T>, groupedGetter!: (O) -> ArrayList<T>)  // One-to-many / many-to-many
}

public class GroupedSingleQueryMapper<T, O> <: QueryMapper<O> {
    public GroupedSingleQueryMapper(name!: String, groupedGetter!: (O) -> ArrayList<T>)  // Single column collection (such as a comma-joined list of ids)
}

public class NullableGroupedQueryMapper<T, O> <: QueryMapper<O> {
    public NullableGroupedQueryMapper(ignoreNone!: Bool = true, grouped!: QueryMappers<T>,
                                      groupedGetter!: (O) -> ArrayList<Option<T>>)
}
```

> `GroupedSingleQueryMapper` is for the scenario "a collection is held in one row and one column"; the value of that column (for example the
> several rows obtained by splitting `1,2,3`) is `convert<T>`-ed one by one and appended.

### 13.4 Iterators

```cangjie
public abstract class AbstractQueryResultIterator<T> <: Iterator<T> & Resource {
    public func isClosed(): Bool
    public func close(): Unit
}

public class QueryResultIterator<T> <: AbstractQueryResultIterator<T> {
    public func next(): ?T
}

public class SingleColumnIterator<T> <: AbstractQueryResultIterator<T> {
    public func next(): ?T
}
```

The constructors of all three are internal and they can only be created by the framework; an iterator holds the QueryResult, the Statement and the
executor of this query, and `next()` returns `Option<T>.None` and releases automatically when the result set is exhausted. The parent class
`AbstractQueryResultIterator` implements `Resource`, so `try (it = executor.iterator<UserPO>()) { ... }` closes automatically and `close()` may
also be called explicitly. The order of `close()` is **result set → statement → executor wrap-up**: outside a transaction `SqlExecutor.close()`
returns the connection as well, while inside a transaction it only resets the "active result set" flag and leaves the connection for the `close()`
after the transaction ends, so inside a transaction the same transaction can continue executing SQL after an iterator is closed.

> `SingleColumnIterator` takes the value by column name when `column` is non-empty, and else by `index` (0 by default).

### 13.5 Custom type conversion: `QueryMapperConverter`

When a PO field is neither a basic type nor in the `SimpleDataQueryMappersInit` list, a converter can be used to convert the column value into the
target type.

```cangjie
public abstract class QueryMapperConverter {
    public static func lookup(name: String): QueryMapperConverter    // Found by bean name / fully qualified class name, otherwise constructed by reflection
    public func convert<T>(data: Any): T where T <: DataFields<T>
}

public class QueryMapperJsonConverter <: QueryMapperConverter {}                  // JSON text / Array<Byte> / InputStream → T
public class QueryMapperWithTypeNameJsonConverter <: QueryMapperConverter {
    public static func toJson<T>(data: T): String where T <: DataFields<T>        // JSON carrying typeName
}
```

* `converter: '<name>'` in `@ORMField` is generated by the macro and handed to `QueryMapperConverter.lookup(name)` for resolution (`lookup`
  results are cached by name). The lookup order: ① `lookupOption<QueryMapperConverter>(name)` of f_bean (**by bean name**, that is, the converter
  must be a named `@Bean`); ② iterate `lookupList<QueryMapperConverter>()` and match the fully qualified type name;
  ③ construct by reflection with `ClassTypeInfo.get(name).construct([])`. When none of the three works,
  `ORMException('QueryMapperJsonConverter: <name> not found')` is thrown.
* A class name may also be given directly (such as `converter: 'fountain::f_orm.base.QueryMapperJsonConverter'`).
* `ORMConfig.registerConverter` / `getConverter` maintain **another** `converterMap` (for business code to use itself), and `lookup` does not
  consult it in the current source —— do not mix the two.
* The low-level type conversion is provided by `public struct ORMConverter` (`base/converter.cj`):

```cangjie
public static func convert<T>(value: Any): T
public static func convertNullable<T>(value: Any): ?T
```

---

### 13.6 `InputStream` (BLOB/CLOB): ownership, lifecycle and large objects

`InputStream` appears in only two places: **writing** (parameter binding) and **reading back** (taking a result value). The ownership differs
between the two:

**Writing: the stream belongs to the caller**

- Entry points: `SqlArgs.add(InputStream)`, `RootDAO.arg(value: InputStream)` / `arg(?InputStream)`.
- The ORM **only passes it on and does not close it** (`InputStreamSqlArg` in `wrap/SqlArg.cj`); the caller is responsible for closing it.
- Agreement: the stream must **stay alive until this SQL has really finished executing** —— drivers usually read it only at `execute` time, and
  closing it early leads to reading nothing or to an error.
- The reverse reminder: do not "helpfully add a `close()`" on the ORM side (`wrap/InputStreamOwnership_test.cj` marks that behavior as failing).

**Reading back: the stream comes from the driver, and the four current drivers all hand out an in-memory copy**

Measured (2026-10-06):

| Driver | What `get<InputStream>` gives |
|---|---|
| `mariadb-driver`, `opengauss-driver` | The row data is `copyTo`-ed into a `ByteBuffer` (an in-memory copy) |
| `mysqlclient-ffi` | BLOBs map to `Array<Byte>`; requesting a stream throws `data type error` |
| `pgsql-driver`, `postgres-driver` | `get<InputStream>` is not supported and `SqlException` is thrown directly |

⇒ The `InputStream` handed out by these drivers is **unrelated** to the result set lifecycle, so it can be put into a PO field, passed to
`toMap()` or held for a long time.

**Large objects (the real use of BLOB)**

The database allows 4GB-scale BLOBs, but "dumping the whole thing into an in-memory copy" cannot cope with that —— this is **a problem of the
driver implementation** and cannot be fixed on the ORM side. The current ways out:

1. **Do not put large objects in a BLOB column** (recommended): put them in object storage / a file system and store the key / sha256 in the database;
2. **Query in blocks on the server side**: take them block by block with `substring(col, off, len)` / `substr(col, off, len)`; memory is O(block
   size) at the price of several round trips;
3. Dump immediately after reading back (`copyTo` to a file/network): saves "two copies at the same time", but the peak is still the whole object,
   so it is ineffective for very large objects;
4. Switch to a driver/API that supports streaming large objects (PG `lo_*`; the internal `PgRowStream` of `postgres-driver` is currently not
   exposed).

The criterion: use BLOB only for "bounded objects" (the threshold is decided by the business); anything beyond that takes route 1 or 2.

**Result caching**

A result containing a stream is **not written to the result cache** (`SqlExecutor` decides by `QueryResultWrap.hadStream`): once a driver that
"hands out a truly streaming handle" is used, the cache would keep the stream until after the result set is closed, turning it into an invalid
value.

**Before adopting a third-party driver**: rerun the check in the table above —— the conclusion of this section depends on the measurement that
"the driver gives an in-memory copy".

## 14. Transactions

### 14.0 The sensitive-configuration masking macro `ORMEmbedSensitive`

`@ORMEmbedSensitive` (`src/ProtectedMacros/EmbedSensitive.cj`) is the ORM-specific form of `@EmbedSensitive` of `f_config`: it declares the ORM
connection string/user name/password and the prefix variants of each driver as sensitive configuration items in one go, so that they are treated as
sensitive configuration in output/logs.

### 14.1 Propagation behavior `Propagation`

```cangjie
public enum Propagation {
    | Required      // Reuses an already started outer transaction; otherwise starts a new transaction
    | Supports      // Reuses an already started outer transaction; otherwise no transaction is used
    | Mandatory     // Reuses an already started outer transaction; without one it throws MandatoryTransactionException
    | RequiresNew   // Without an outer transaction it reuses the connection and starts a transaction; with one it takes a new connection and starts a new transaction
    | Never         // No transaction is used; with an outer transaction it throws NeverTransactionException
    | NotSupported  // No transaction is used; with an outer transaction it takes a new connection to execute
    | Nested        // With an outer transaction it starts a nested transaction; otherwise no transaction is used either
}
```

> `RequiresNew` and `NotSupported` **create a new connection**; within the scope of these two propagation behaviors the decisions of the other
> propagation behaviors are still based on whether the outer connection has started a transaction.

### 14.2 The transaction template `execute`

```cangjie
executor.execute<Int64>(
    propagation: Propagation.Required,
    isoLevel: None,
    accessMode: None,
    deferrableMode: None,
    noRollbackFor: 'fountain::f_bean::BeanException',
    rollbackFor: ''
) { exec =>
    exec.setSql('...').update
    1    // The second return value is returned by the closure as (T, Bool): true commits, false throws and rolls back
}
```

Executor methods available in the callback (see [5.5](#55-transaction-control)): `commit()`, `rollback()`, `rollback(savepoint)`, `save(savepoint)`,
`release(savepoint)`, `callAndCommit{}`, `noRollbackFor(e)`, `rollbackFor(e)`.

### 14.3 The `@Transactional` annotation

```cangjie
@Annotation[target: [MemberFunction]]
public class Transactional {
    public const Transactional(
        public let driverName!: String = '',
        public let propagation!: ?Propagation = None,
        public let isoLevel!: ?TransactionIsoLevel = None,
        public let accessMode!: ?TransactionAccessMode = None,
        public let deferrableMode!: ?TransactionDeferrableMode = None,
        public let rollbackFor!: String = '',
        public let noRollbackFor!: String = ''
    )

    public func getPropagation(): Propagation                     // Unspecified → Required
    public func getIsoLevel(): ?TransactionIsoLevel               // Unspecified → the global ORMConfig setting
    public func getAccessMode(): ?TransactionAccessMode
    public func getDeferrableMode(): ?TransactionDeferrableMode
}
```

A function annotated with `@Transactional` has a transaction weaved into it by `TransactionAspect`:

```cangjie
@Transactional[propagation: Propagation.RequiresNew, rollbackFor: 'fountain::f_exception::BizException']
public func transfer(from: Int64, to: Int64, amount: Decimal): Unit { ... }
```

**Configuration-driven aspects**: besides the annotation, `orm_transactionalFuncExecution` (function signature patterns) together with
`orm_transactionIncluding` / `orm_transactionExcluding` (regexes) can make the aspect hit functions automatically, without adding an annotation to
each of them.

### 14.4 `TransactionHook` and the hook order

```cangjie
public interface TransactionHook {
    func beforeTx(): Unit {}
    func inTx(): Unit {}
    func beforeCommit(readOnly: Bool): Unit {}
    func afterCommit(): Unit {}
    func afterThrowing(e: Exception): Unit {}
    func beforeRollback(e: Exception): Unit {}
    func afterRollback(e: Exception): Unit {}
    func afterComplete(status: TransactionStatus): Unit {}
    prop order: Int64 { get() { Int64.Max } }        // Decides the hook execution order (ascending)
}
```

* Registration: `ORM.registerTransactionHook<MyHook>(MyHook())`, or `ORM.registerTransactionHooks<MyHook>()` (fetching beans in bulk from
  `lookupList<MyHook>()`).
* Hooks with the same `order` run in registration order (`TransactionHookWrap.compare` compares `order` first, then the registration ordinal).

**Transaction callback order**:

| Scenario | Order |
| --- | --- |
| Commit | `beforeTx` → `beforeCommit` → `commit` → `afterCommit` → `afterComplete(Committed)` |
| Exception | `afterThrowing` → `beforeRollback` → `rollback` → `afterRollback` → `afterComplete(Rollback)` |
| The exception matches `noRollbackFor` / `rollbackFor` is configured but the type does not match | `afterThrowing` → `beforeCommit` → commit → `afterCommit` → `afterComplete(Committed)` → rethrow |

> The complete branches (including a `rollbackFor` hit) are in [5.4](#54-generic-execution-entry-points).

```cangjie
public enum TransactionStatus <: Equatable<TransactionStatus> & ToString {
    | Unknown | Committed | Rollback
    public prop isUnknown: Bool
    public prop isCommitted: Bool
    public prop isRollback: Bool
}
```

### 14.5 `TransactionAspect`

```cangjie
@AspectRoute[FuncAnnotationRouteRule("fountain::f_orm.base.Transactional")
             | ConfigExecutionRouteRule(ORMConfig.transactionalFuncExecution)]
@BeanMeta
public class TransactionAspect <: Aspect {
    public func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any
}
```

Inside `proceed` the aspect parses the annotation and the configuration, takes `ORM.executor(driverName)` and calls `execute<Any>(...)` to wrap the
original method call. The class also registers itself with the `BeanFactory` through `private init()` + `static init()`, and does
`public import fountain::f_aspect.*` (re-exporting the aspect-related types along with it).

### 14.6 `RootService` (the base interface of the Service layer)
**Be sure** that every call of a DAO function starts from executor(), otherwise an exception occurs.
```cangjie
public interface RootService {
    func executor(name: String): SqlExecutor         // name is empty → use the default datasource
    func executor(): SqlExecutor
    func dao<T>(driver: String): T where T <: RootDAO     // Take the SqlExecutor and convert it into the DAO interface
    func dao<T>(): T where T <: RootDAO
}
```

`dao<T>()` relies on `SqlExecutor` being implicitly convertible into `T` (that is, the interface implementation generated by `@DAO`); on failure
it throws `ORMException('${TypeInfo.of<T>()} is not extended to SqlExecutor')`.

---

## 15. Macros

### 15.1 `@DAO`

**Purpose**: applied to an **interface**, it expands into "the original interface + `extend SqlExecutor <: <interface name> {}`".

```cangjie
@DAO
public interface UserDAO <: RootDAO {
    func findUser(id: Int64): UserPO {
        executor.FROM<UserPO>().WHERE(UserPO.tableColumns().id.eq(id)).first<UserPO>().getOrThrow()
    }
}
```

Key points:

* **The interface itself carries the implementation**: a DAO function must be given a body inside the interface (inherited by the `SqlExecutor`
  extension). There is therefore no "DAO implementation class"; `SqlExecutor` *is* the implementation.
* **The macro's actual validation consists of only one rule**: the input must be an interface declaration, otherwise an error is reported
  (`DAO.cj:92-113`). The following are usage conventions that the macro neither asserts nor warns about:
  * The interface should be `public`, **must not have generic parameters**, and should extend `RootDAO`;
  * Every DAO function must have a default implementation;
  * **One persistent object corresponds to one DAO interface**;
  * Within one module all DAO function names must be unique (because they all hang off `SqlExecutor`).
* Inside the interface `executor`, `arg(...)`, `meet(...)`, `choose`, `loop(...)` and the other `RootDAO` members can be used directly.
* Obtaining the DAO: the `SqlExecutor` returned by `executor()` (`RootService`) is the DAO; `ORM.executor() as UserDAO` also works.
* When a transaction is needed, add `@Transactional` to the DAO/Service method.

### 15.2 `@QueryMappersGenerator`

**Purpose**: generates the column mapping, the `QueryMappersInit` / `QueryMappersObject` implementations and the column set class for a PO
(class), and registers the class in the table metadata (for use by migro).

```cangjie
@QueryMappersGenerator[table: '"user_info"' dirty]
@DataAssist[fields tostring]        // @DataAssist must be written before @QueryMappersGenerator (it expands first)
public class UserPO {
    @ORMField[true 'id']            // Primary key, column name fixed to id
    private var id: Int64 = 0
    @ORMField['username']
    private var username: String = ''
    @ORMField[true LowerUnderScore] // Primary key; the column name is the member name converted to underscore (that is, user_name)
    private var userName: String = ''
}
```

**Generated items (which the business may call directly)**:

| Generated item | Description |
| --- | --- |
| `static func queryMappers(): QueryMappers<T>` | The mapper set of all columns; when there is a parent class the parent mappers are merged (`QueryMappers.create`) |
| `static func tableName(): String` | Table name |
| `static func isSimpleData(): Bool` | Returns `false` for a PO |
| `static func tableColumns(): C` | The column set object (see below); it also makes the PO extend `QueryMappersObject<T, C>` |
| Column set class | Named `<PO class name>__cOlUmns___` (`private init()` + a static singleton), generated in the package of the PO; it contains `toString()` (column names joined by commas), `iterator(): Iterator<Column>`, and one `Column` property per column |
| Table metadata registration | Generates `private let _ = TableMetas.register<T>()`, so that migro can discover the table (see section 16) |

> **The column set property names are the "column names", not the "member names"**: `@ORMField['user_name'] private var userName` corresponds to
> `tableColumns().user_name`.
> For a public instance member without `@ORMField`, the default is "not a primary key + the member name converted to a column name by
> `LowerUnderScore`".

**Macro attributes**:

| Attribute | Form | Effect |
| --- | --- | --- |
| Table name | `[user_info]` (when it is the only attribute) | Table name |
| Table name | `[table: 'user_info']` / `[table: user_info]` | Table name (a string or an identifier) |
| Naming strategy | `[table: LowerUnderScore]` | Class name → table name converted by the strategy |
| Table name prefix/suffix | `[tablePrefix: 't_' tableSuffix: '_tab']` | Concatenated to the table name |
| Class name prefix/suffix | `[classPrefix: 'F_' classSuffix: 'PO']` | Before the **class name** is converted into a table name by the naming strategy, the prefix and suffix are stripped from the class name (such as `F_UserPO` → `User`); unrelated to the column set class name (which is fixed to `<class name>__cOlUmns___`) |
| Dirty field tracking | `[dirty]` | Injects `DirtyTag.setDirtyField<T>(...)` into the setter (simple types / `?T` / `Option<T>` only), to be used with `UPDATE(values, dirty: true)` |
| Compatible form | `[table: xxx dirty]` | Table name and dirty given at the same time |

When no attribute (or only `dirty`) is written, the table name is the class name converted by `LowerUnderScore`; a member name without `@ORMField`
is likewise converted to a column name by `LowerUnderScore`.
An unrecognized attribute only reports a **WARNING** (`${attr.value} is illegal attr for @QueryMappersGenerator...`) and does not stop the compilation.

### 15.3 `@ORMField`

**Purpose**: applied to a PO member to declare the primary key, the column name and the converter. It **must be used together with
`@QueryMappersGenerator`**.

```cangjie
public macro ORMField(attrs: Tokens, input: Tokens): Tokens
```

**Attribute syntax** (every part is optional and the order is arbitrary):

| Form | Meaning |
| --- | --- |
| `true` / `id` | Marks it as the primary key |
| `false` | Not a primary key (equivalent to omitting it; the source decides by `attr.value.toAsciiLower() == 'true'`) |
| `'column_name'` / `"column_name"` | Fixed column name |
| `LowerUnderScore` | Converts the member name (camel case) into an underscore lower-case column name |
| `UpperUnderScore` | Converts it into an upper-case underscore column name |
| `Pascal` | Converts it into a Pascal-case column name |
| `Camel` | The column name is the member name |
| `column: <any form above>` | Explicitly specifies the column name |
| `converter: <beanName>` | Specifies the bean name or fully qualified type name of a `QueryMapperConverter` |

Examples: `@ORMField[true LowerUnderScore]`, `@ORMField[id column: 'user_name' converter: 'userNameConverter']`.

**The rewriting performed by the macro**: an annotated `var` is rewritten into `private var _name_` + `public mut prop name` (with the dirty mark
inserted into the setter as needed), so the way business code accesses it is unchanged. Constraints:

* It can only annotate a **`public var` member variable or a `public mut` property** (for other forms the macro reports
  `member of current type must be modified by `public var` or `public mut prop` which is annotated by ORMField`);
* The member must be a non-static instance member;
* The property name should use camel case (to work with strategies such as `LowerUnderScore`);
* An illegal attribute token throws `ORMException('unsupported TokenKind in attrs of @ORMField ...')` instead of warning.

> There is also the annotation class `ORMColumn` (`@Annotation[target: [MemberProperty, MemberVariable]]` with the fields `name!: String` and
> `id!: Bool`), which offers an equivalent way of declaring the column name/primary key.

### 15.4 `@TransactionalService`

```cangjie
// macros/TransactionalService.cj actually only re-exports (together with Pointcut):
public import fountain::f_aspect.macros.WeavedBean as TransactionalService
public import fountain::f_aspect.macros.Pointcut
```

**Purpose**: equivalent to `@WeavedBean`; it weaves the annotated Service class into the aspect chain (working with `TransactionAspect` and the
`orm_transactionalFuncExecution` configuration to weave in transactions, without writing `@Transactional` for each method). See `fdemo`:

```cangjie
@TransactionalService            // @Bean may be used instead when transaction control is not needed
public class UserServiceImpl <: UserService {
    public func register(username: String, password: String): Int64 {
        executor().register(username, password)     // executor() returns a SqlExecutor that can be used as a DAO directly
    }
}
```

## 16. Table schema metadata and migro

f_orm supports "deriving the database table schema from the PO definition": after adding the `@DatabaseSchema` / `@IndexSchema` / `@ColumnSchema`
annotations to a PO, `@QueryMappersGenerator` registers the table metadata in a global registry automatically; the `migro` submodule then compares
it with the current state of the database and generates (and optionally executes) DDL.

### 16.1 Table schema annotations

**`@DatabaseSchema`** — declared on the mapping class to mark the target database:

```cangjie
@Annotation[target: [Type]]
public class DatabaseSchema {
    public const DatabaseSchema(
        private let driver!: String = '',   // Driver name; when omitted it falls back to ORM.defaultDriver
        public let database!: String        // Target database name
    ){}
    public prop driverName: String          // Returns ORM.defaultDriver when driver is empty
}
```

Usage:

```cangjie
@DatabaseSchema[database: 'user_db']                        // Uses the default driver
@DatabaseSchema[driver: 'postgres' database: 'user_db']     // Specifies the driver
@QueryMappersGenerator[table: 'user_info']
@DataAssist[fields]
public class UserPO { ... }
```

> When `TableMeta.new<T>()` cannot find `@DatabaseSchema` it throws `TableMetaException`.

**`@IndexSchema`** — declared on the mapping class; several may be given (`findAllAnnotations`) to describe the expected indexes:

```cangjie
@Annotation[target: [Type]]
public class IndexSchema {
    public const IndexSchema(
        public let name!: String,      // Index name
        public let columns!: String,   // Column names, comma separated
        public let unique!: Bool       // Whether the index is unique
    ){}
}
```

**`@ColumnSchema`** — declared on a member property/member variable of the PO (used together with `@ORMField`):

```cangjie
@Annotation[target: [MemberProperty, MemberVariable]]
public class ColumnSchema {
    public const ColumnSchema(
        public let oldColumnName!: String = '',   // Old column name (used to generate rename statements)
        public let typeName!: String,             // Database type, such as 'varchar(100)'
        public let nullable!: Bool = false,
        public let default!: ?String = None,
        public let extra!: String = '',           // Such as 'auto_increment'
        public let comment!: String = ''
    ){}
}
```

> Only columns **carrying the `@ColumnSchema` annotation** enter `TableMeta.columns`; unannotated columns take no part in DDL generation.

Usage:

```cangjie
@QueryMappersGenerator[table: 'users']
@DataAssist[fields]
@DatabaseSchema[database: 'user_db']
public class UserPO {
    @ORMField[true 'id']
    @ColumnSchema[typeName: 'bigint' extra: 'auto_increment']
    private var id: Int64 = 0

    @ORMField['user_name']
    @ColumnSchema[typeName: 'varchar(100)']
    private var userName: String = ''
}
```

### 16.2 `TableMeta` / `ColumnMeta` / `IndexMeta`

```cangjie
public class TableMeta {
    public let driver: String
    public let database: String
    public let tableName: String
    public let columns: Array<ColumnMeta>
    public let indexes: Array<IndexMeta>

    public static func new<T>(): TableMeta where T <: QueryMappersInit<T>
}
```

The construction process of `new<T>()` (based on `std.reflect`):

1. Read `@DatabaseSchema` from the class (a missing one throws `TableMetaException`) to obtain `database` and `driver` (the `driverName` property,
   which falls back to `ORM.defaultDriver` when empty);
2. Take the table name from `T.tableName()`;
3. Traverse `T.queryMappers().mappers`, look up `@ColumnSchema` on the instance property/member variable by `fieldName` on the `TypeInfo`, build
   `ColumnMeta(schema, columnName)` on a hit and skip that column on a miss;
4. Build the index metadata array with `findAllAnnotations<IndexSchema>()`.

**`ColumnMeta`** (`@DataAssist[fields]`, implementing `Hashable & Equatable<ColumnMeta>`):

| Member | Type | Description |
| --- | --- | --- |
| `columnName` | `String` | Column name |
| `oldColumnName` | `String` | Old column name (for renaming) |
| `typeName` | `String` | Database type |
| `nullable` | `Bool` | Whether it is nullable |
| `default` | `?String` | Default value |
| `extra` | `String` | Additional attributes (such as `auto_increment`) |
| `comment` | `String` | Comment |

Constructors: `ColumnMeta()` (all defaults) / `ColumnMeta(schema: ColumnSchema, columnName: String)`.
`hashCode` and `==` are based on `columnName / typeName / nullable / default / extra` (**excluding** `oldColumnName` and `comment`).

**`IndexMeta`** (`@DataAssist[fields]`, implementing `Hashable & Equatable<IndexMeta>`):

| Member | Type | Description |
| --- | --- | --- |
| `name` | `String` | Index name |
| `columns` | `String` | Column names (comma separated) |
| `unique` | `Bool` | Whether it is unique |
| `def` | `String` | The index definition SQL (extracted by Postgres from `pg_indexes.indexdef`, for verbatim re-creation) |

Constructors: `IndexMeta()` / `IndexMeta(name: String, columns: String, unique: Bool)` / `IndexMeta(schema: IndexSchema)`.
`hashCode` and `==` are based on `name / columns / unique` (**excluding** `def`).

### 16.3 The `TableMetas` registry

```cangjie
public struct TableMetas {
    public static func register<T>(): Unit where T <: QueryMappersInit<T>
    public static func tableMetas(): Iterator<TableMeta>
    public static func clear(): Unit
}
```

| Method | Description |
| --- | --- |
| `register<T>()` | Builds `TableMeta.new<T>()` and registers it in an internal `ConcurrentHashMap` keyed by `TypeInfo`; a failure only writes a warn log and does not throw |
| `tableMetas()` | Iterates over all registered table metadata |
| `clear()` | Empties the registry |

> Normally there is no need to register by hand —— `@QueryMappersGenerator` already calls `register` on the PO initialization path, which is why
> migro can discover all tables.

### 16.4 The `SchemaFinder` interface and its built-in implementations

```cangjie
public interface SchemaFinder {
    prop driverName: String
    func listTables(database: String): Iterator<String>
    func findTableSchema(database: String, tableName: String): Iterator<ColumnMeta>
    func findIndexes(database: String, tableName: String): Iterator<IndexMeta>
    func generateCreateSql(tableName: String, columns: Iterator<ColumnMeta>): Iterator<String>
    func generateDropTableSql(tableName: String): String
    func generateAlterSql(tableName: String, new: Array<ColumnMeta>, current: Iterator<ColumnMeta>): Iterator<String>
    func generateIndexSql(tableName: String, new: Array<IndexMeta>, current: Iterator<IndexMeta>): Iterator<String>
}
```

| Method | Description |
| --- | --- |
| `listTables` | Lists all table names in the database (migro uses it to find "superfluous tables") |
| `findTableSchema` / `findIndexes` | Reads the existing columns/indexes of the database (querying system tables such as `information_schema`) |
| `generateCreateSql` | No table → generates the create-table statement (returns an iterator; the Postgres implementation also returns `SET DEFAULT` statements) |
| `generateDropTableSql` | Generates the drop-table statement |
| `generateAlterSql` | Table exists → compares the old and new columns and generates change statements (add/drop/change type/change nullability/change default/rename) |
| `generateIndexSql` | Compares the old and new indexes and generates change statements (add/drop index) |

Built-in implementation classes (all `@Bean`, discovered by `driverName` through `lookupList<SchemaFinder>()`):

| Implementation class | `driverName` |
| --- | --- |
| `MysqlSchemaFinder` | `mysql` |
| `MariaDBSchemaFinder` | `mariadb` |
| `PostgresSchemaFinder` | `postgres` |
| `OpenGaussSchemaFinder` | `opengauss` |

> `AbstractMysqlSchemaFinder` and `AbstractPostgresSchemaFinder` are public abstract base classes encapsulating the common parsing and SQL
> generation logic of the two dialects; a custom dialect can implement the `SchemaFinder` interface and annotate it with `@Bean`.

Key differences between the two implementations:

* **MySQL/MariaDB**: the column type is taken directly from `information_schema.columns.column_type` (such as `varchar(100)`); renaming a column
  generates `change <old> <new> ...`; indexes are `add index` / `add unique` / `drop index`.
* **Postgres/OpenGauss**: the type is assembled from `udt_name` plus length/precision; renaming a column generates `rename column ... to` and
  changing the type generates `alter column ... type`; for indexes `IndexMeta.def` (the original `indexdef`) is preferred for verbatim re-creation.

The decision logic of `generateAlterSql`:

* A newly defined column that is not in the database → `add column`;
* A column in the database that is not in the new definition → `drop column`;
* A column with the same name but different attributes → modify the type / nullability / default value;
* A non-empty `oldColumnName` that differs from the database → handled as a rename.

### 16.5 `SchemaFinderMediator` and the `dbmigro` subcommand

```cangjie
public struct SchemaFinderMediator {
    public init()                                   // lookupList<SchemaFinder>() indexed by driverName
    public func generate(cmdargs: Array<String>): Unit
}
```

The complete flow of `generate`:

1. `TableMetas.tableMetas()` is grouped by `driver`;
2. For every registered table: query the columns in the database → `generateCreateSql` when there is no table, `generateAlterSql` when there is;
   then query the indexes and run `generateIndexSql`;
3. Grouped **by driver**, `use <database of the first table of the group>;` is inserted before the first SQL of each group (within the same group,
   crossing databases does not insert another `use` for the second database);
4. For tables that "exist in the database but not in the definition" a `drop table` is generated (orphan table cleanup); these statements are
   appended to the same list as the DDL above;
5. All SQL is first printed to standard output;
6. The `-m` / `--mode` argument is parsed to decide the following action (**only the first `-m` / `--mode` hit is recognized**; the processing then
   ends).

| `-m` / `--mode` | Behavior |
| --- | --- |
| Omitted | Only prints the SQL; writes no file and executes nothing |
| `file` | Writes the SQL into `./migro.sql` in the current directory |
| `auto` | Executes them one by one with `ORM.executor(driver)` through `setSql(sql).update` |
| `dry` | Only prints (the same as omitting it) |
| `interactive` | After printing it asks `> 是否立即执行生成的SQL? [y/N]：`; typing `y`/`Y` executes, `n`/`N` ends, and any other input keeps waiting |

> Any value other than the above throws `Exception("Invalid migration mode ...")`. In an execution mode a failure of one SQL only prints the stack
> and does not stop the following statements. Note that the `drop table` generated in step 4 is in the same list, so it is likewise written or
> executed by `file` / `auto` / `interactive`.

The command line entry point (the `f_app` subcommand framework):

```cangjie
public struct MigroCommand <: SubCommand {
    static init() { SubCommandMediator.register(MigroCommand()) }   // Registered automatically when the module is loaded
    public prop command: String { get() { 'dbmigro' } }
    public func exec(args: Array<String>): Int64 { SchemaFinderMediator().generate(args); 0 }
}
```

Usage examples:

```bash
fboot dbmigro --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))'
fboot dbmigro --dylibPattern='...' -m file         # Generates ./migro.sql
fboot dbmigro --dylibPattern='...' -m interactive  # Executes after interactive confirmation
```

## 17. Exception hierarchy

All exceptions are defined in the `fountain::f_orm.exception` package (re-exported automatically by `fountain::f_orm`).

### 17.1 Inheritance

```
BaseException (fountain::f_exception)
├── ORMException (open)
│   ├── ConnectionException (open)          # Connection/connection pool
│   ├── DirtyFieldException                 # Dirty fields
│   ├── MockDBException                     # The mockdb driver
│   ├── NoIdException (open)                # Missing primary key
│   ├── TableMetaException                  # Table metadata
│   └── TransactionException (open)
│       ├── NoneTransactionException        # No transaction
│       ├── StartFailureTransactionException# Transaction creation failed
│       └── PropagationException (open)     # Propagation rules
│           ├── MandatoryTransactionException
│           └── NeverTransactionException
└── SqlArgException                         # Note: it extends BaseException directly
```

Every exception provides the same 4 constructors as `BaseException`:

```cangjie
init()
init(message: String)
init(caused: Exception)
init(message: String, caused: Exception)
```

### 17.2 Type descriptions and throwing scenarios

| Exception | Parent | Typical throwing scenario |
| --- | --- | --- |
| `ORMException` | `BaseException` (open) | Generic ORM errors, such as a column value that cannot be converted into the target type (`column index: n, column type: ..., column name: ..., requires: ...`), a string parse failure, calling a deprecated API, or a `QueryMappersInit` that does not implement `queryMappers` |
| `SqlArgException` | `BaseException` | SQL argument errors, such as `SqlArg` meeting an unsupported type, `UPDATE(values)` having no valid column, `BETWEEN`/`IN`/`IS_NULL` and similar logical expressions receiving an illegal operator, or a table data field type not matching the column type |
| `ConnectionException` | `ORMException` (open) | Connection-related errors, such as taking a connection from an already closed pool: `database pool is closed` |
| `NoIdException` | `ORMException` (open) | No primary key column is found during `UPDATE` (the primary key was not annotated with `@ORMField[true ...]`) |
| `TableMetaException` | `ORMException` | `TableMeta.new<T>()` fails to build, for example when the class lacks the `@DatabaseSchema` annotation |
| `DirtyFieldException` | `ORMException` | Errors related to dirty field tracking |
| `MockDBException` | `ORMException` | mockdb (the in-memory mock driver) errors, such as pointing the mock dialect at itself |
| `TransactionException` | `ORMException` (open) | Generic transaction errors (`DummyTransaction` throws it when `begin` is called in an unknown mode) |
| `PropagationException` | `TransactionException` (open) | Base class of transaction propagation rule errors |
| `MandatoryTransactionException` | `PropagationException` | The propagation level is `Mandatory` (a transaction is required) but there is no transaction |
| `NeverTransactionException` | `PropagationException` | The propagation level is `Never` (transactions forbidden) but a transaction is in progress |
| `StartFailureTransactionException` | `TransactionException` | Transaction creation failed (the `StartFailure` mode of `DummyTransaction`) |
| `NoneTransactionException` | `TransactionException` | An exception dedicated to the no-transaction scenario (for business code and the framework) |

> The three kinds of exception `Mandatory` / `Never` / `StartFailure` are thrown by `wrap/DummyTransaction.cj` when it performs the propagation
> rule check on the "no real transaction" placeholder transaction object (see [14. Transactions](#14-transactions)).


## 18. Sensitive information
The database connection URL, user name and password can read the relevant configuration items at compile time, be encrypted with SM4, and have the
encrypted byte array embedded into the build output.
At compile time the sensitive information is embedded into the build output with the following configuration.
When there is no encryption configuration item, the UTF8 byte array of the sensitive information is embedded into the build output.
When the build environment has no sensitive information configured, it must be configured in the runtime environment, otherwise database access
fails at runtime.

The sensitive information configuration items of the build environment and of the runtime environment are exactly the same.

> The actual read path of the current implementation: `ORMConfig.getConf` / `getUrl` / `getUsername` / `getPassword` only read `Config` (that is,
> the environment variables) and **do not read `sensitiveMap`**; the `getSensitive` formerly used to fetch values by embedded key was removed in
> commit `3c43de8f`. In other words, the connection URL / user name / password embedded in the build output are not used automatically at
> runtime, while the SM4 parameters (`sensitiveMap`) are used by `getSM4()`.

When a hexadecimal string is needed, use the command `fboot randhex 32`; 32 is the length of the hexadecimal string

### 18.1 Encryption configuration items
```bash
# These encryption configuration items are also embedded into the build output as sensitive information
export orm_sm4Operation='CBC' # CBC CFB CTR GCM OFB, CBC by default. ECB is marked as insecure by the documentation and is not supported
export orm_sm4Padding='PKCS7Padding' # PKCS7Padding NoPadding, PKCS7Padding by default
export sm4Key='1234567812345678' # 16 bytes, no default, given as a hexadecimal string of length 32; missing or of the wrong length throws IllegalArgumentException
export sm4Iv='1234567812345678' # No default, given as a hexadecimal string; CBC/OFB/CFB require 16 bytes and GCM requires 12 bytes; missing or of the wrong length throws IllegalArgumentException
export orm_sm4Aad='1234567812345678' # Additional authenticated data, an empty byte array by default, given as a hexadecimal string of length 32
export orm_sm4TagSize=16 # Int64, 16 by default
```

### 18.2 Sensitive information configuration items
```bash
# orm_drivers itself is not sensitive information, but it must be configured in both the build environment and the runtime environment, and must be identical.
export orm_drivers='postgres,mysql' # Comma-separated database driver names; no default.
export orm_connectionUrl='.....' # Database connection URL
export <driverName>_orm_connectionUrl='....' # With several datasources the configuration item may start with the driver name
export orm_option_username='...' # Database user name
export <driverName>_orm_option_username='...' # With several datasources the configuration item may start with the driver name
export orm_option_password='...' # Password
export <driverName>_orm_option_password='...' # With several datasources the configuration item may start with the driver name
```

Embedding rules (`macros/EmbedSensitive.cj`):

* It walks the drivers in `orm_drivers` one by one, and only a connection URL / user name / password whose **value is non-empty at compile time** is
  embedded;
* The registration key used when embedding is the **driver-name-prefixed form**: `<driver>_orm_connectionUrl`, `<driver>_orm_option_username`,
  `<driver>_orm_option_password` (generated by `ORMConfig.genKey`); the global name is not embedded as is;
* Only when at least one sensitive piece of information was really embedded are the SM4 operation / padding / key / iv / aad / tagSize written into
  `sensitiveMap` as well;
* At runtime `getConf` / `getUrl` / `getUsername` / `getPassword` currently only read `Config` (environment variables) and do not consult
  `sensitiveMap` (see the note at the beginning of this chapter and [19.6](#196-known-issues-and-review-records)).

## 19. Appendix

### 19.1 The SQL dialect `SqlDialect`

Database differences such as the pagination syntax, identifier quoting and `lastInsertId` are concentrated in the dialect class, which
`SqlExecutor` selects automatically by `driverName`.

```cangjie
public abstract class SqlDialect {
    public prop dialect: String
    public open func lastInsertId(id: String): String                            // '' by default
    public func lastInsertId(dataType: DataType): String
    public func lastInsertId<ID, O>(id: IdQueryMapper<ID, O>): String where ID <: Hashable & Equatable<ID>
    public open func limit(size: Int64, offset: Int64): (Int64, Int64, String)  // (size, offset, ' limit ? offset ?') by default
    public open prop startInvolver: String                                       // '"' by default
    public open prop endInvolver: String                                         // '"' by default
    public func involvedIdentifier(identifier: String): String                   // Quotes the identifier; one already starting with startInvolver is returned as is
}
```

The splitting rule of `involvedIdentifier`: it splits only at the **first** `.` (`a.b.c` → `"a"."b.c"`), quoting the first segment and the rest
separately.

`limit(size, offset)` returns the triple `(argument 1, argument 2, SQL fragment)` —— the argument order differs per database (MySQL takes size,
offset; Oracle takes offset, size), so the caller only has to `add` the arguments in the returned order.

Built-in implementations (all assembled conditionally from `orm_drivers` and discovered by `lookupList<SqlDialect>()`):

| Dialect class | `dialect` | Characteristics |
| --- | --- | --- |
| `MySqlDialect` (open) | `mysql` | Identifiers are quoted with `` ` `` |
| `MariaDBDialect` | `mariadb` | Extends `MySqlDialect` |
| `SqliteDialect` | `sqlite` | Default behavior |
| `PostgresDialect` (open) | `postgres` | `lastInsertId` generates ` returning <id>` |
| `OpenGaussDialect` | `opengauss` | Extends `PostgresDialect` |
| `OracleDialect` | `oracle` | `limit` → ` OFFSET ? ROWS FETCH NEXT ? ROWS ONLY` |
| `DB2Dialect` | `db2` | `limit` → ` OFFSET ? ROWS FETCH FIRST ? ROWS ONLY` |
| `MockdbDialect` | `mockdb` | A proxy dialect: the `mock` property gives the proxied dialect (`opengauss` by default) and `limit` / `startInvolver` / `endInvolver` are forwarded to it; setting it to itself throws `MockDBException` |

### 19.2 Advanced types of the `wrap` layer

| Type | Description | Key members |
| --- | --- | --- |
| `ORMConfig` | The configuration read entry point —— the parsing implementation of all the environment variables of section 3. | `getDrivers()`, `getDriverNames()`, `getDefaultDriver()` (`orm_defaultDriver` ?? the first of `orm_drivers` ?? `''`), `isDefaultDriver(driver: String / Driver)`, `getUrl(driverName)`, `getConf(driverName, key)`, the getters of the connection pool parameters (`getPoolMaxSize`, `getPoolCheckSql` and so on), `registerConverter` / `getConverter` (see [13. Result mapping](#13-result-mapping)), `transactionable(funcName)`, `getTransactionPropagation()`, `mockdb` |
| `NamedDatasource` | A named datasource (`<: Datasource & Resource`): it binds a `Datasource` to a driver name for use by `ORM.register`. | `init(driver)` / `init(driver, url)` / `init(driver, options)` / `init(driver, url, options)`, the primary constructor `NamedDatasource(optionSpecified, driverName, datasource)`, `driverName`, `connect()`, `setOption(key, value)`, `isClosed()`, `close()` |
| `DatasourceCreator` | The datasource factory interface: `ORM.register(creator)` calls it at registration time to create the `NamedDatasource`. | `create(): NamedDatasource`, `driverName: String` (used to decide the default value of `default`) |
| `DatabasePool` | The built-in connection pool (`<: Resource & Datasource`), driven by the `orm_databasePool*` family of environment variables. | `init(driver: Driver, ds: Datasource)` (every parameter taken from `ORMConfig`), `init(ds: Datasource, ..., checker!: (Connection) -> Bool)`, `init(ds: Datasource, ..., checkSql!: String = "select 1")`, `init(driver: Driver, options!: Array<(String, String)> = [], ..., checkSql!: String)` (calls `driver.open` directly), `getConnection(timeout!: Duration = connectTimeout): Option<Connection>` (throws `ConnectionException('database pool is closed')` when the pool is already closed), `isClosed()`, `close()` |
| `SqlArg` (abstract) | A single bound argument (`index` + `set(statement)`). | The factory `SqlArg.new<T>(index, value)`; each supported type has an implementation subclass; `hashCode` / `==` / `toString` |
| `SqlArgs` | The argument collection (`<: Hashable & Equatable<SqlArgs> & ToString`): the placeholder index increments automatically. | public: `init()`, the full-type `add(...)` overloads, `addNull()`, `toString()`, `hashCode` / `==`; protected: `clone()`, `set(statement)`, `clear()`, `add(all!: SqlArgs)` |
| `QueryResultWrap` | A wrapper around `std.database.sql.QueryResult`: it reads by column and casts safely, and is the foundation of result mapping. | `columnInfos`, `get<T>(...)` / `get<T>(columnName)` / `getOrNull<T>(...)` / `getOrNull<T>(columnName)`, `next()` / `next(values)`, `toMap()`, `close()`, etc. |
| `StatementWrap` | A `Statement` wrapper: it unifies the binding of `?` placeholder arguments and the execution. | `update()` / `query()` (both argument-less), `set` / `setNull` (adding the index base internally per `orm_indexStartsWithZero`), `parameterColumnInfos`, `setOption`, `isClosed()`, `close()`; **there is no `getConnection()`**, and the argument versions `update(params)` / `query(params)` throw `ORMException('current access is deprecated')` directly |
| `ConnectionWrap` | A `Connection` wrapper: it attaches a driver name to the connection; `prepareStatement` returns a `StatementWrap` and `createTransaction` returns a `TransactionWrap`. | The primary constructor `ConnectionWrap(driverName, connection)`, `driverName`, `state`, `getMetaData()`, `prepareStatement`, `createTransaction`, `isClosed()`, `close()` |
| `DummyTransaction` | A placeholder transaction for "no real transaction", used to perform the propagation rule check when no transaction has been started (`TransactionWrap.isDummy` checks whether it holds one). | The enum `DummyTransactionMode { Common, Mandatory, Never, StartFailure }`; `init(mode, ex)`; `begin()` throws `MandatoryTransactionException` / `NeverTransactionException` / `StartFailureTransactionException` according to the mode (`Common` with an exception throws `TransactionException`); `isoLevel` / `accessMode` / `deferrableMode` are mut props; `commit` / `rollback` / `save` / `release` are all empty implementations |
| `TransactionWrap` | A transaction wrapper: a dedicated connection is bound inside the transaction, and suspension and savepoints are supported. | `connection`, `suspend`, `wrapping`, `isDummy`, `begin()`, `commit()`, `rollback()`, `save(name)`, `rollback(savePointName)`, `release(name)`, `setIsoLevel(level)`, `setAccessMode(mode)`, `setDeferrableMode(mode)` |
| `Propagation` | The transaction propagation level enum (the propagation argument of `@Transactional`). | `Required`, `Supports`, `Mandatory`, `RequiresNew`, `NotSupported`, `Never`, `Nested` |
| `DataType` (abstract) | The column type description (constructor arguments `nullable` / `columnName` / `fieldName`), in one-to-one correspondence with `QueryMapper`: it reads the result column in a fixed type and also decides which parameter binding overload is used on insert/update. | `get(result): Any`; subclasses: `BoolDataType`, `Int8DataType`, `UInt8DataType`, `Int16DataType`, `UInt16DataType`, `Int32DataType`, `UInt32DataType`, `Int64DataType`, `UInt64DataType`, `Float16DataType`, `Float32DataType`, `Float64DataType`, `DecimalDataType`, `BigIntDataType`, `RuneDataType`, `StringDataType`, `ByteArrayDataType`, `DateTimeDataType`, `DurationDataType`, `InputStreamDataType`, `UnknownDataType` |

### 19.3 Types supported as SQL arguments

`arg(...)` (`SqlArg.new<T>`) and `add(...)` support the following types; any other type throws `SqlArgException`:

`Bool`, `Int8`, `UInt8`, `Int16`, `UInt16`, `Int32`, `UInt32`, `Int64`, `UInt64`, `Float16`, `Float32`, `Float64`, `Decimal`, `BigInt`, `Rune`,
`String`, `Duration`, `DateTime`, `Array<Byte>`, `InputStream`, and `None` (`addNull()`).

### 19.4 Other utility types

| Type | Description |
| --- | --- |
| `ExtendString` (the `String` extension) | Inside the SQL fragment assembly context it appends to the partials of the current executor: the `AND` / `OR` / `NOT` properties of a string append the corresponding keyword; `operator ()(sql: String)` and `operator ()(sql: () -> Unit)` append the fragment directly (going through `Partials.PAREN` internally) |
| `DirtyTag` | Dirty field tracking (the `UPDATE` with `dirty: true` depends on it): `setDirtyField<T>(field: String)` is called by the setter generated by `@ORMField`; `setBeforeDirty<T>` / `getDirtyFields<T>` / `clear<T>` / `clearAll` are `protected` and `clear(typeInfo)` is private, all for the framework's internal use |
| `ORMInitializer` | The `f_app` integration: it registers an `initializer` (name `fountain::f_orm`, dependency `fountain::f_bean`) so that `ORM.initialize()` runs automatically at application startup |
| `ORMColumn` | The column name/primary key annotation on a member (`name!: String = ''`, `id!: Bool = false`), offering declaration capabilities equivalent to `@ORMField` (see [15. Macros](#15-macros)) |

### 19.5 Related documents

* `f_orm/doc/优化方案.md`: the optimization plan (the former API excerpts split by topic have been deleted; the interfaces in this README and in
  `src/**` are authoritative).
* `f_orm/src/**/*.cj`: the source code is the most authoritative reference; behavior not covered by this document follows the source code.
* The example project `fdemo`: `fdemo/boot.sh` (configuration), `fdemo/user/src/dao/*DAO.cj` (DAO definitions),
  `fdemo/user/src/service/impl/UserServiceImpl.cj` (transactional service).
