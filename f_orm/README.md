# fountain::f_orm API 参考

> 本文档基于 `f_orm` 模块当前源码整理，描述对外暴露的类型、函数签名与用法。
> 依赖包：`f_base`、`f_bean`、`f_collection`、`f_data`、`f_exception`、`f_log`、`f_cache`、`std.database.sql`、`std.reflect`。

## 目录

1. [模块概览与包结构](#1-模块概览与包结构)
2. [快速开始](#2-快速开始)
3. [配置项参考](#3-配置项参考)
4. [`ORM`：注册与初始化入口](#4-orm注册与初始化入口)
5. [`SqlExecutor`：SQL 执行器](#5-sqlexecutorsql-执行器)
6. [`RootDAO`：DAO 通用能力](#6-rootdaodao-通用能力)
7. [`SqlPartial`：面向对象的 CRUD 入口](#7-sqlpartial面向对象的-crud-入口)
8. [`SqlDSL`：模板 SQL](#8-sqldsl模板-sql)
9. [DSL 子句：`IntoClause` / `UpdateClause` / `FromClause`](#9-dsl-子句intoclause--updateclause--fromclause)
10. [逻辑表达式与列对象](#10-逻辑表达式与列对象)
11. [条件构造器](#11-条件构造器)
12. [分页 `Pagination`](#12-分页-pagination)
13. [结果映射](#13-结果映射)
14. [事务](#14-事务)
15. [宏](#15-宏)
16. [表结构元数据与 migro](#16-表结构元数据与-migro)
17. [异常体系](#17-异常体系)
18. [敏感信息](#18-敏感信息)
19. [附录](#18-附录)

---

## 1. 模块概览与包结构

`f_orm` 是面向仓颉 `std.database.sql` 的 ORM 层，核心设计：

* **DAO 即接口**：业务 DAO 声明为接口，只需继承 `RootDAO`，加上 `@DAO` 宏即可让接口拥有 `SqlExecutor` 的全部能力（接口本身不必写实现，但是需要为接口函数提供默认实现）。
* **PO 即映射**：数据对象（PO）用 `@QueryMappersGenerator` / `@ORMField` 宏生成列映射（`queryMappers()`），自动完成「数据行 → 对象」填充。
* **参数安全**：SQL 参数统一通过 `arg(...)` / `add(...)` 绑定为 `?` 占位符，避免拼接注入。
* **事务与连接在线程内维持**：`SqlExecutor` 按驱动名缓存在 `ThreadLocal` 中，同一线程内一次事务的多次数据库访问共用同一连接。

### 包结构

| 包 | 内容 |
| --- | --- |
| `fountain::f_orm` | 模块入口，`public import fountain::f_orm.base.*`；并重导出 `std.convert`、`std.database.sql`、`std.reflect`、`f_bean`、`f_orm.wrap`、`f_orm.exception` |
| `fountain::f_orm.base` | 核心：`ORM`、`SqlExecutor`、`RootDAO`、`SqlPartial`、`SqlDSL`、DSL 子句、逻辑表达式、条件构造器、`QueryMappers`、`Pagination`、`DirtyTag`、事务钩子等 |
| `fountain::f_orm.wrap` | 包装层：`ORMConfig`、`NamedDatasource`、`DatabasePool`、`SqlArg`/`SqlArgs`、`QueryResultWrap`、`StatementWrap`、`TransactionWrap`、`Propagation`、`DataType` 等 |
| `fountain::f_orm.macros` | 宏：`@DAO`、`@ORMField`、`@QueryMappersGenerator`、`@TransactionalService` |
| `fountain::f_orm.exception` | `ORMException`、`SqlArgException`、`NoIdException`、`TransactionException`、`MandatoryTransactionException`、`NeverTransactionException` 等 |
| `fountain::f_orm.migro` | 表结构比对与 DDL 生成（`SchemaFinder`、`SchemaFinderMediator`、`MysqlSchema`、`PostgresSchema`、`SubCommand`） |

---

## 2. 快速开始

### 2.1 配置（环境变量）

`f_orm` 的配置全部来自环境变量（见 [第 3 节](#3-配置项参考)）：

```bash
export orm_drivers=postgres                 # 逗号分隔的驱动名列表
export orm_defaultDriver=postgres           # 可省略；省略时以第一个驱动为默认
export postgres_orm_connectionUrl=$POSTGRES # <驱动名>_orm_connectionUrl 指定连接URL
```

### 2.2 初始化

在应用初始化文件中调用 `ORM.initialize()`：

```cangjie
import fountain::f_orm.*

ORM.initialize()   // 等价于 register() + registerTransactionHooks<TransactionHook>()
//最好有专门的初始化模块
```

> 使用 `f_app` 应用框架时无需手工调用：`f_orm` 内置的 `ORMInitializer`（见 [19.4](#184-其他实用类型)）已注册到 `InitializerCollection`，应用启动时会自动执行 `ORM.initialize()`。

### 2.3 定义 PO

```cangjie
import fountain::f_orm.*
import fountain::f_orm.macros.*

@QueryMappersGenerator
public class UserPO {
    @ORMField['id']            // 指定列名；不写 @ORMField 时默认把成员名转为下划线分隔的全小写字符串作为列名
    public var id: Int64 = 0
    @ORMField['username']
    public var username: String = ''
    @ORMField['password']
    public var password: String = ''
}
```

### 2.4 定义 DAO

DAO 声明为**接口**并继承 `RootDAO`，`@DAO` 宏负责生成实现。接口体内可直接使用 `executor`：

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
        executor.INSERT_INTO<UserPO>(user)          // 返回自增主键
    }

    func changePassword(username: String, password: String): Int64 {
        let map = HashMap<Column, Any>()            // key 可为列对象、列名或成员名
        map[UserPO.tableColumns().password] = password
        map[UserPO.tableColumns().username] = username
        executor.UPDATE<UserPO>(map)                // 主键列作为 WHERE 条件
        /*
        //这样也可以
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
        // 这样也可以：executor.FROM<UserPO>().deleteById(id)
    }
}
```

### 2.5 调用

`@DAO` 展开后会生成 `extend SqlExecutor <: UserDAO {}`，即**线程内的 `SqlExecutor` 本身就是 DAO 实现**（接口里的函数体就是 DAO 方法实现）。因此有两种取得 DAO 的方式：

```cangjie
// ① 在 Service 中：Service 接口继承 RootService，直接用 executor()
public interface UserService <: RootService {
    func queryUser(id: Int64): UserPO
}

@TransactionalService
public class UserServiceImpl <: UserService {
    public func queryUser(id: Int64): UserPO {
        executor().findUser(id)          // executor() 返回的 SqlExecutor 可直接当 UserDAO 用
    }
}

// ② 显式取 DAO
let dao: UserDAO = ORM.executor()        // 或 dao<UserDAO>()（需要 RootService 上下文）
let user = dao.findUser(1)
```

> 同一线程内 `ORM.executor()` 返回的是同一个执行器，因此事务范围内的所有 DAO 调用共用同一连接。

---

## 3. 配置项参考

配置全部以**环境变量**方式提供，由 `fountain::f_orm.wrap.ORMConfig` 读取。命名约定：

* 全局配置：`orm_<key>`；
* **按驱动覆盖**：`<driverName>_orm_<key>`，优先级高于全局配置（`getConf` 先查 `<driverName>_<key>`，查不到再回退全局 `key`）；
* `orm_options_<key>=<value>`：会被收集为驱动初始化 options（`getAllConfigTuples()`）。

### 3.1 驱动与连接

| 环境变量 | 类型 / 默认值 | 说明 |
| --- | --- | --- |
| `orm_drivers` | 逗号分隔列表 | 需要初始化的驱动名列表，`ORM.register()` 依据它批量注册 `NamedDatasource` |
| `orm_defaultDriver` | `String`，默认 `''` | 默认驱动名；`ORM.connection()` / `ORM.executor()` 无参时使用。未配置时回退为 `orm_drivers` 列表的**第一个**驱动，仍为空则 `''`。`ORMConfig.isDefaultDriver(...)` 也以此判定 |
| `orm_connectionUrl` / `<driver>_orm_connectionUrl` | `String` | 连接串；缺失时抛 `ORMException` |
| `orm_options_*` | `key=value` | 驱动初始化参数 |
| `orm_useCache` | `Bool`，默认 `true` | 是否缓存 SQL 执行结果（按 SQL + 参数缓存）。驱动级未配置时回退全局，仍未配置则取 `true` |
| `orm_noPool` | `Bool`，默认 `false` | `true` 表示不使用连接池 |
| `orm_useStdPool` | `Bool`，默认 `true` | `true` 使用标准库 `PooledDatasource`；`false` 使用 `DatabasePool` |
| `orm_useThirdPartyPool` | `Bool`，默认 `false` | `true` 表示使用第三方连接池：`f_orm` 不创建连接池，需自行 `ORM.register(datasource, default: false)` 注册 |
| `orm_indexStartsWithZero` | `Bool`，默认 `true` | `true` → `getIndexStartsWith()` 返回 0（列索引从 0 开始），否则返回 1 |

> 配置了 `mockdb` 时，`ORM.register()` 只注册 `mockdb` 一个数据源，不再初始化其它驱动。
> `orm_useThirdPartyPool=true` 时，不要配置 `orm_noPool` / `orm_databasePool*` / `orm_stdPool*`，连接池完全由业务代码创建并注册。

### 3.2 事务默认值

| 环境变量 | 类型 / 默认值 | 说明 |
| --- | --- | --- |
| `orm_transactionPropagation` | `Propagation`，默认 `Required` | 默认传播行为 |
| `orm_transactionLevel` | `?TransactionIsoLevel`，默认 `None` | 隔离级别 |
| `orm_transactionAccessMode` | `?TransactionAccessMode`，默认 `None` | 读写模式 |
| `orm_transactionDeferrableMode` | `?TransactionDeferrableMode`，默认 `None` | Deferrable 模式 |
| `orm_transactionNoRollbackFor` | `?String` | 命中即**提交**（不回滚）的异常类名，多个用 `\|` 分隔 |
| `orm_transactionRollbackFor` | `?String` | 命中即回滚的异常类名，多个用 `\|` 分隔 |
| `orm_transactionIncluding` | 正则 | 事务切面包含的函数（`transactionable(funcName)`） |
| `orm_transactionExcluding` | 正则 | 事务切面排除的函数 |
| `orm_transactionalFuncExecution` | `\|` 分隔的签名模式 | 需要织入事务切面的函数，如 `*::*..*ServiceImpl.del*(**): *` |

**传播行为**（大小写、`_` / `-` / 驼峰写法均可）：`Required`、`Supports`、`Mandatory`、`RequiresNew`（`requires_new`、`REQUIRES-NEW`、`requiresNew`）、`Never`、`NotSupported`（`not_supported`、`NOT-SUPPORTED`…）、`Nested`。非法值抛 `IllegalArgumentException`。

**隔离级别**：`Default` / `Unspecified`、`ReadCommitted`、`ReadUncommitted`、`RepeatableRead`、`Snapshot`、`Serializable`、`Linearizable`、`Chaos`。

**读写模式**：`Default` / `Unspecified`、`ReadWrite`、`ReadOnly`。

**Deferrable**：`Default` / `Unspecified`、`Deferrable`、`NotDeferrable`。

### 3.3 `DatabasePool`（fountain 连接池）

| 环境变量 | 默认值 | 单位 / 说明 |
| --- | --- | --- |
| `orm_databasePoolInitSize` | `10` | 初始连接数 |
| `orm_databasePoolMinSize` | `10` | 最小连接数 |
| `orm_databasePoolMaxSize` | `10` | 最大连接数 |
| `orm_databasePoolCheckInterval` | `300` | 秒，连接有效性检查周期 |
| `orm_databasePoolConnectTimeout` | `50` | **毫秒**，从池中获取连接的超时时间 |
| `orm_databasePoolIdleTimeout` | `0` | 秒，`0` 表示闲置不过期 |
| `orm_databasePoolConnectionLife` | `3600` | 秒，连接存活时间 |
| `orm_databasePoolCheckOnCreation` | `false` | 创建连接时是否校验 |
| `orm_databasePoolCheckOnBorrowing` | `true` | 借出时是否校验 |
| `orm_databasePoolCheckOnReturning` | `false` | 归还时是否校验 |
| `orm_databasePoolCheckSql` | `select 1` | 校验 SQL |

### 3.4 标准库连接池（`std.datasource.sql.PooledDatasource`）

| 环境变量 | 默认值 | 单位 / 说明 |
| --- | --- | --- |
| `orm_stdPoolMaxSize` | `None` | 最大连接数 |
| `orm_stdPoolMaxIdleSize` | `None` | 最大空闲连接数 |
| `orm_stdPoolIdleTimeout` | `None` | 秒，连接闲置时间 |
| `orm_pooledDatasourceMaxLifeTime`（即 `stdPoolMaxLifeTime`） | `None` | 秒，连接存活时间 |
| `orm_stdPoolConnectionTimeout` | `None` | **微秒**，连接获取超时 |
| `orm_stdPoolKeepaliveTime` | `None` | 秒，连接保活检查周期 |

### 3.5 `ORMConfig` 静态 API

```cangjie
package fountain::f_orm.wrap

public class ORMConfig {
    public static const mockdb = 'mockdb'

    // 刷新与转换器
    public static func refresh(fn: () -> Unit): Unit
    public static func registerConverter<D, T>(name: String, converter: (D) -> T)
    public static func getConverter<D, T>(name: String): (D) -> T

    // 原始配置读取
    public static func getConf(driverName!: String = String.empty, key!: String): ?String
    public static func getAllConfigs(driverName!: String = String.empty): Map<String, String>
    public static func getAllConfigTuples(driverName!: String = String.empty): Array<(String, String)>

    // 驱动
    public static func getDefaultDriver(): String        // orm_defaultDriver ?? orm_drivers 的首个驱动 ?? ''
    public static func isDefaultDriver(driver: String)   // 该驱动名是否为默认驱动
    public static func isDefaultDriver(driver: Driver)   // 等价于上者，取 driver.name
    public static func getDriverNames(): Iterator<String>
    public static func getDrivers(): Iterator<Driver>
    public static func getUrl(driverName!: String = String.empty): String

    // 连接池开关
    public static func getUseCache(driverName!: String = String.empty): ?Bool
    public static func getNoPool(driverName!: String = String.empty)
    public static func getUseStdPool(driverName!: String = String.empty): Bool
    public static func getUseThirdPartyPool(driverName: String)

    // fountain 连接池
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

    // 事务
    public static func transactionable(funcName: String): Bool
    public static func getTransactionPropagation(driverName!: String = String.empty): Propagation
    public static func getTransactionLevel(driverName!: String = String.empty): ?TransactionIsoLevel
    public static func getTransactionAccessMode(driverName!: String = String.empty): ?TransactionAccessMode
    public static func getTransactionDeferrableMode(driverName!: String = String.empty): ?TransactionDeferrableMode
    public static func getTransactionNoRollbackFor(driverName!: String = String.empty): ?String
    public static func getTransactionRollbackFor(driverName!: String = String.empty): ?String

    // 标准库连接池
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

## 4. `ORM`：注册与初始化入口

`public class ORM` 是全局门面，内部以 `ConcurrentHashMap<String, NamedDatasource>` 按驱动名保存数据源。

```cangjie
public class ORM {
    // 初始化 / 注册
    public static func initialize()                                          // register() + registerTransactionHooks<TransactionHook>()
    public static func register()                                            // 依据 orm_drivers / orm_defaultDriver 批量注册，仅默认驱动被设为 ORM.default
    // default! 的默认值统一为 ORMConfig.isDefaultDriver(<驱动名>)：仅当该驱动为默认驱动时才把它设为 ORM.default
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
    public static func deregister(name: String): Unit
    public static func deregisterAndReplaceDefault(newDefault: String): Unit
    public static func close()                                               // 已注册为进程退出回调（ExitCallbacks）

    // 连接与执行器
    public static func connection(): Connection
    public static func connection(name: String): Connection
    public static func executor(): SqlExecutor
    public static func executor(driverName: String): SqlExecutor

    // 事务钩子
    public static func registerTransactionHook<T>(hook: T): Unit where T <: TransactionHook
    public static func registerTransactionHooks<T>(): Unit where T <: TransactionHook   // 从 lookupList<T>() 批量注册

    public static prop databasesNames: Array<String>
}
```

行为说明：

* `register(driver, ...)` 对**已注册的同名驱动**会跳过并打印 `warn` 日志；重复注册 `NamedDatasource` 会直接 `close()` 新的数据源。
* `default` 参数的默认值是一个**表达式** `ORMConfig.isDefaultDriver(<驱动名>)`，即只有所注册的驱动恰为默认驱动时，它才会成为默认数据源（`ORM.default`）；显式传 `default: true` / `default: false` 可覆盖此行为。默认数据源供 `ORM.connection()` / `ORM.executor()` 无参重载使用；未指定时抛 `ORMException("default datasource is not specified")`。
* `deregister(name)` 会同时 `DriverManager.deregister(name)` 并关闭数据源；若注销的是默认数据源，默认值被清空。
* `register(driver: String, ...)` 内部通过 `DriverManager.getDriver(driverName)` 取驱动，未注册时抛 `ORMException('database driver ${driverName} does not initialize')`。
* `register(creator: DatasourceCreator, ...)` 先调用 `creator.create()` 得到 `NamedDatasource` 再注册；用于计算 `default` 默认值的 `creator.driverName` 由实现方提供（见 [19.2](#182-wrap-层进阶类型)）。

---

## 5. `SqlExecutor`：SQL 执行器

```cangjie
public class SqlExecutor <: Resource & RootDAO {
    public prop executor: SqlExecutor       // 返回 this，便于在 DAO 内链式书写
    public prop isReadOnly: Bool            // 当前 SQL 是否以 select 开头
    public prop update: Int64               // 执行 UPDATE，返回影响行数
    public prop delete: Int64               // 执行 DELETE，返回影响行数
    public prop insert: Int64               // 执行 INSERT，返回 lastInsertId
}
```

**线程内单例**：`SqlExecutor` 缓存在 `ThreadLocal<HashMap<String, SqlExecutor>>` 中，按驱动名区分，通过 `ORM.executor()` 获取。获取时会检查连接状态：`Closed` 直接重置为 `NoneConnection`，`Broken` 关闭后重置。

**执行模型**：

* `execute` 的两个关键行为：① 不在事务中时执行完即 `close()` 并释放连接；在事务中则由事务收尾统一处理。② 开启 `orm_useCache` 时，读操作结果会按 `SqlCacheKey(sql, args)` 缓存；写操作会清空缓存。
* 每次执行后会记录一条 `debug` 日志（驱动名、SQL、参数、耗时），随后清空 SQL 与参数。
* 同一 `SqlExecutor` 上**不允许并发**：上一次查询结果未关闭时再次执行会抛 `ORMException("cannot execute SQL while a previous query result is still active")`。

### 5.1 设置 SQL 与绑定参数

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

public func add(arg: Any)              // 运行期按 ToString / InputStream 分派，其它类型抛 SqlException
protected func add(all!: SqlExecutor)  // 合并另一个 executor 的参数
```

说明：

* 各类型的 `?T` 重载在值为 `None` 时等价于 `addNull()`，即绑定 SQL `NULL`。
* 泛型 `add<T>(arg: T) where T <: ToString` 会先做类型匹配（覆盖上表全部类型），未命中则退化为 `add(arg.toString())`。
* 参数通过 `SqlArgs` 写入 `PreparedStatement`；`clearArgsAfterExec: false` 可在多次执行间复用同一批参数（`page` / `singlePage` 内部即如此）。

### 5.2 查询

**单列映射**（结果集第一列或指定列/列名）：

```cangjie
public func singleFirst<T>(): Option<T>                 // 第一行第一列
public func singleFirst<T>(index: Int64): Option<T>     // 指定列下标
public func singleFirst<T>(column: String): Option<T>   // 指定列名

public func singleList<T>(): ArrayList<T>
public func singleList<T>(index: Int64): ArrayList<T>
public func singleList<T>(column: String): ArrayList<T>

public func singleIterator<T>(): Iterator<T>
public func singleIterator<T>(index: Int64): Iterator<T>
public func singleIterator<T>(column: String): Iterator<T>
```

**对象映射**（依赖 `QueryMappers`）：

```cangjie
public func first<T>(mappers: QueryMappers<T>): Option<T>    // 第一行
public func first<T>(): Option<T> where T <: QueryMappersInit<T>
public func list<T>(mappers: QueryMappers<T>): ArrayList<T>  // 全部行
public func list<T>(): ArrayList<T> where T <: QueryMappersInit<T>
public func iterator<T>(mappers: QueryMappers<T>): QueryResultIterator<T>
public func iterator<T>(): Iterator<T> where T <: QueryMappersInit<T>
public func one<T>(mappers: QueryMappers<T>): Option<T>      // 与 first 类似，用于 grouped 映射
public func one<T>(): Option<T> where T <: QueryMappersInit<T>
```

**无类型映射**（返回 Map）：

```cangjie
public func firstToMap(): Map<String, Any>              // 第一行 → Map（无结果返回 EmptyMap）
public func mapList(): ArrayList<HashMap<String, Any>>  // 全部行 → Map 列表
```

> `T.isSimpleData()` 为 `true` 时（基础类型等），`first<T>()` / `list<T>()` / `iterator<T>()` 自动退化为对应的 `singleXxx` 版本。

### 5.3 更新 / 删除 / 插入

```cangjie
executor.setSql('update user_info set username = ${arg(name)} where id = ${arg(id)}').update   // Int64 影响行数
executor.setSql('delete from user_info where id = ${arg(id)}').delete                          // Int64 影响行数
executor.setSql('insert into user_info(username) values(${arg(name)})').insert                 // Int64 lastInsertId
```

### 5.4 通用执行入口

```cangjie
// 在一个 SqlExecutor 作用域内执行（不自动开启事务）
public func execute<T>(executor: (SqlExecutor) -> T): T

// 事务模板：自动开启事务、按返回值决定提交/回滚
public func execute<T>(
    propagation!: Propagation = ORMConfig.getTransactionPropagation(driverName: driverName),
    isoLevel!: ?TransactionIsoLevel = ORMConfig.getTransactionLevel(driverName: driverName),
    accessMode!: ?TransactionAccessMode = ORMConfig.getTransactionAccessMode(driverName: driverName),
    deferrableMode!: ?TransactionDeferrableMode = ORMConfig.getTransactionDeferrableMode(driverName: driverName),
    noRollbackFor!: ?String = ORMConfig.getTransactionNoRollbackFor(driverName: driverName),
    rollbackFor!: ?String = ORMConfig.getTransactionRollbackFor(driverName: driverName),
    executor!: (SqlExecutor) -> (T, Bool)      // 第二个返回值：true → commit；false → 抛 ORMException 并回滚
): T
```

事务钩子调用顺序：`beforeTx` → `beforeCommit` → `commit` → `afterCommit` → `afterComplete`；
异常路径：`afterThrowing` → `beforeRollback` → `rollback` → `afterRollback` → `afterComplete`。

### 5.5 事务控制

```cangjie
// 新建事务并按传播行为开启（会依据 Propagation 决定加入已有事务 / 挂起 / 新建）
public func newTxAndBegin(
    propagation!: Propagation = ORMConfig.getTransactionPropagation(driverName: driverName),
    isoLevel!: ?TransactionIsoLevel = ORMConfig.getTransactionLevel(driverName: driverName),
    accessMode!: ?TransactionAccessMode = ORMConfig.getTransactionAccessMode(driverName: driverName),
    deferrableMode!: ?TransactionDeferrableMode = ORMConfig.getTransactionDeferrableMode(driverName: driverName)
): SqlExecutor

public func commit(): Unit
public func rollback(): Unit
public func rollback(savepoint: String): Unit

public func noRollbackFor(e: Exception): Exception     // 登记「不回滚」异常，返回入参 e 便于 `throw executor.noRollbackFor(e)`
public func rollbackFor(e: Exception): Exception       // 登记「需回滚」异常

public func callAndCommit<T>(callee: () -> T): T       // 执行 callee，成功则提交；异常则回滚并重抛
public func save(savepoint: String): Unit              // 创建保存点
public func release(savepoint: String): Unit           // 释放保存点

public func isClosed(): Bool
public func close(): Unit                              // Resource 实现；关闭连接并清理本线程缓存
```

`close()` 语义：若当前在嵌套/内层事务（`txDepth > 1`）则只递减深度；否则提交并关闭连接，同时把 `ThreadLocal` 中该驱动的执行器重置为 `NoneConnection`。

---

## 6. `RootDAO`：DAO 通用能力

```cangjie
public interface RootDAO {
    public prop executor: SqlExecutor
}
```

所有 DAO 接口继承它即可获得 `executor`（由 `@DAO` 宏注入实现）。`RootDAO` 同时提供以下 **`String` 返回值**的辅助函数，用于拼装 SQL 片段；它们全部是**普通接口方法（有默认实现）**，因此可以直接在 DAO 接口体中调用。

### 6.1 参数绑定：`arg` / `argNull`

`arg(...)` 绑定一个参数并返回占位符 `'?'`，因此需要写进为「模板 SQL」时使用字符串插值 `${arg(x)}`：

```cangjie
executor.setSql('delete from user_info where id = ${arg(id)}')
```

支持的类型与 `SqlExecutor.add` 完全一致：

```cangjie
func arg(value: Bool): String      func arg(value: Int8): String     func arg(value: UInt8): String
func arg(value: Int16): String     func arg(value: UInt16): String   func arg(value: Int32): String
func arg(value: UInt32): String    func arg(value: Int64): String    func arg(value: UInt64): String
func arg(value: Float16): String   func arg(value: Float32): String  func arg(value: Float64): String
func arg(value: BigInt): String    func arg(value: Decimal): String  func arg(value: Rune): String
func arg(value: String): String    func arg(value: Duration): String func arg(value: DateTime): String
func arg(value: Array<Byte>): String
func arg(value: ?T): String        // 各类型 Option 重载；None → argNull()
func arg(value: Any): String       // 运行期分派
func argNull(): String             // 绑定 NULL，返回 '?'
```

**集合展开**（生成 `(?, ?, ...)` 形式的占位符列表，适合 `IN` 使用）：

```cangjie
func arg<I, T>(values: I): String where I <: Iterable<T>                    // 一维集合
func arg<I1, I2, T>(values: I1): String where I1 <: Iterable<I2>, I2 <: Iterable<T>   // 二维集合
```

### 6.2 条件片段：`meet`

`meet` 是「条件满足才拼接」的语法糖：

```cangjie
// 1) 条件满足时执行 f() 得到 SQL 片段，否则返回空串
func meet(condition: Bool, partial: () -> String): String
func meet(condition: Bool, partial: () -> LogicalExpr): LogicalExpr
func meet(condition: Bool, partial: () -> Array<LogicalExpr>): LogicalExpr

// 2) 一组 (条件, 片段) 对，逐个判定
func meet(pairs: Array<(() -> Bool, () -> LogicalExpr)>): LogicalExpr
func meet(pairs: Array<(() -> Bool, () -> Array<LogicalExpr>)>): LogicalExpr

// 3) 返回可继续链式设置的 MeetCondition 构造器
func meet(condition: Bool, partial: String): MeetCondition
func meet(condition: Bool, partial: String, value: Any): String
func meet(condition: Bool, partial: String, value: () -> Any): String
```

示例：

```cangjie
let expr = meet(name.size > 0) { 'username = ${arg(name)}' }
// name 为空 → ''；否则 → 'username = ?'，可直接插值进 SQL
```

`MeetCondition` 见 [11.4](#114-meetcondition)。

### 6.3 条件构造器入口

```cangjie
prop choose: ChooseCondition                          // executor.choose
func loop<I, T>(values: I): LoopCondition<I, T> where I <: Iterable<T>
func WHERE(partial: () -> String): String
func WHERE(delimiter: String, partial: () -> String): String
func SET(partial: () -> String): String
func trim(prefix!: String, suffix!: String, partial!: () -> String): String
```

`WHERE` / `SET` / `trim` 用于按需拼接子句（空内容时自动省略前缀关键字）：

```cangjie
executor.setSql('update user_info ${SET { 'username = ${arg(name)}, password = ${arg(pwd)}' }} where id = ${arg(id)}')
executor.setSql('select * from user_info ${WHERE { 'id = ${arg(id)}' }}')
```

### 6.4 逻辑运算与关系运算（`String` 版本）

这些函数生成的是**可直接插值的 SQL 片段**（注意：`IN` / `LIKE` / `BETWEEN` 等只返回运算符部分，左值需自行拼在左侧）：

```cangjie
// 逻辑连接（返回 ' and ... ' / ' or ... ' / ' not ... '）
func AND(value: String): String                    func AND(partial: () -> String): String
func OR(value: String): String                     func OR(partial: () -> String): String
func NOT(value: String): String                    func NOT(partial: () -> String): String
func paren(partial: () -> String): String          // ' (...) '

// 关系运算片段
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

示例：

```cangjie
executor.setSql('select * from user_info where id ${IN(ids)}')
executor.setSql('select * from user_info where username ${LIKE('%${name}%')}')
executor.setSql('select * from user_info where id = ${arg(id)} ${AND {'status = ${arg(status)}'}}')
```

另有对应的 `LogicalExpr` 版本（`AND` / `OR` / `NOT`，接受 `Array<LogicalExpr>` 或 `() -> Array<LogicalExpr>` / `LogicalExpr`），见 [第 10 节](#10-逻辑表达式与列对象)。

---

## 7. `SqlPartial`：面向对象的 CRUD 入口

`public interface SqlPartial <: RootDAO` 定义了以「对象 / 列」为单位操作数据库的能力。`SqlExecutor` 实现了它（`extend SqlExecutor <: SqlPartial`），所以 `executor.INTO<T>(...)` 等调用都可用。

所有形参 `T` 都要求 `T <: QueryMappersInit<T>`，即 PO 必须由 `@QueryMappersGenerator` 生成映射（见 [15.2](#152-querymappersgenerator)）。

### 7.1 插入

```cangjie
// 链式构造 INSERT 语句
func INTO<T>(
    ignoreColumns!: Array<String> = [],        // 忽略的「成员名或列名」
    includingColumns!: Array<String> = []      // 只插入的「成员名或列名」（与 ignoreColumns 互斥）
): IntoClause<T> where T <: QueryMappersInit<T>

// 一步插入对象，返回自增主键（lastInsertId）
func INTO<T>(values: T, ignoreColumns!: Array<String> = []): Int64
    where T <: QueryMappersInit<T> & ObjectData<T>

// 同上，但用 Column 对象指定忽略列
func INSERT_INTO<T>(ignoreColumns!: Array<Column> = [], includingColumns!: Array<Column> = []): IntoClause<T>
func INSERT_INTO<T>(values: T, ignoreColumns!: Array<Column> = []): Int64
```

示例：

```cangjie
let id = executor.INSERT_INTO<UserPO>(user, ignoreColumns: [UserPO.tableColumns().password])                       // 返回新增主键，ignoreColumns可以没有
let id2 = executor.INTO<UserPO>(user, ignoreColumns: ['password']) // 忽略 password 字段
executor.INTO<UserPO>().VALUES(user).INSERT(columns: ['username']).execute()   // 见 9.1
```

### 7.2 更新

**（1）Map 直改**：`key` 可以是列名、成员名或 `Column` 对象，`value` 为新值。

```cangjie
// 主键作为 WHERE 条件（values 中必须包含主键键值对，否则抛 NoIdException）
func UPDATE<T>(values: Map<String, Any>): Int64
func UPDATE<T>(values: Map<Column, Any>): Int64
func UPDATE<T>(values: Array<(Column, Any)>): Int64

// 显式指定主键
func UPDATE<T, ID>(values: Map<String, Any>, id: ID): Int64
func UPDATE<T, ID>(values: Map<Column, Any>, id: ID): Int64
func UPDATE<T, ID>(values: Array<(Column, Any)>, id: ID): Int64
```

未匹配到任何列时抛 `NoIdException`（PO 无主键）或 `SqlArgException('no column to update')` / `SqlArgException('no column to udpate')`。

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

**（2）对象直改**：以 PO 主键作为 `WHERE` 条件，按列映射生成 `SET`。

```cangjie
func UPDATE<T>(values: T): Int64
func UPDATE<T>(values: T, dirty!: Bool): Int64
func UPDATE<T>(values: T, ignoredColumns!: Array<String>,  includingColumns!: Array<String>): Int64
func UPDATE<T>(values: T, ignoredColumns!: HashSet<String>, includingColumns!: HashSet<String>): Int64
func UPDATE<T>(values: T, ignoredColumns!: Array<Column>,   includingColumns!: Array<Column>): Int64
func UPDATE<T>(values: T, ignoredColumns!: HashSet<Column>, includingColumns!: HashSet<Column>): Int64
// 以上各版本均带 dirty!: Bool 重载
    where T <: QueryMappersInit<T> & ObjectData<T>
```

* `ignoredColumns` 与 `includingColumns` **不能同时指定**；与 `dirty: true` 也不能同时指定，否则抛 `IllegalArgumentException`。
* `dirty: true` 时只更新 `DirtyTag` 记录的脏字段（PO 通过 `@ORMField` 生成的 setter 自动打标）；无脏字段则直接返回 `0`，不执行 SQL。
* 全部列都被排除时返回 `0`。

**（3）链式构造**：

```cangjie
func UPDATE<T>(): UpdateClause<T>               // UPDATE table
func UPDATE<T>(AS!: String): UpdateClause<T>    // UPDATE table AS alias
```

### 7.3 查询

```cangjie
func FROM<T>(): FromClause<T>                    // select ... from table
func FROM<T>(AS!: String): FromClause<T>         // select ... from table AS alias
```

**忽略大小写的前缀约束**：`page` 系列要求 SQL 以 `select` 开头（后接空白），否则抛 `ORMException('<sql> is not a select.')`。

```cangjie
// 分页：先 count(*) 计算总数，再按需执行 limit/offset 查询
func page<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R>
    where R <: QueryMappersInit<R> & DataFields<R>

// 分页 + 单列映射
func singlePage<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R>          // column 默认为 0
func singlePage<R>(sql: String, column: Int64, size: Int64, page!: Int64 = 1): Pagination<R>
    where R <: DataFields<R>

// 只取第一行（自动加 limit 1）
func singleFirst<T>(sql: String): ?T                 // 等价于 singleFirst<T>(sql, 0)
func singleFirst<T>(sql: String, column: Int64): ?T
func singleFirst<T>(sql: String, column: String): ?T
func first<T>(sql: String, mappers: QueryMappers<T>): Option<T>
func first<T>(sql: String): Option<T> where T <: QueryMappersInit<T>
func firstToMap(sql: String): Map<String, Any>       // 第一行 → Map
```

`count` 查询的 SQL 形如 `select count(*) from (<原始SQL>) as __tmp___`；分页查询形如 `select * from (<原始SQL>) as __tmp___ <limit/offset>`。`limit/offset` 由方言（`Dialect`）生成，因此不同数据库的分页语法差异被屏蔽；`orm_indexStartsWithZero` 决定偏移量索引基数。

```cangjie
let p = executor.page<UserPO>('select * from user_info where age > ${arg(18)}', 20, page: 1)
p.rows    // 总记录数
p.pages   // 总页数
p.list    // 当前页数据 ArrayList<UserPO>
```

---

## 8. `SqlDSL`：模板 SQL

用于「SQL 里直接写字段名、由框架绑定参数」的场景，避免手写 `arg(...)` 插值。

```cangjie
public interface SqlDSL {
    func setSqlFromMap(dsl: String, arg: Map<String, Any>, clearArgsAfterExec!: Bool = true): SqlExecutor
    func setSqlFromObject<T>(dsl: String, arg: T, clearArgsAfterExec!: Bool = true): SqlExecutor
        where T <: ObjectData<T>
}
```

`SqlExecutor` 实现了该接口。

### 8.1 语法

| 写法 | 含义 |
| --- | --- |
| `:name` | 绑定 `arg` 中名为 `name` 的字段/键，生成 `?` |
| `:{a.b.c}` | 绑定**数据路径**（`DataPath`），取对象的嵌套值 |
| `:{name}` | 等价于 `:name` |
| `?` | **禁止**与模板 DSL 混用，出现会抛 `IllegalArgumentException` |

* 对 `Map<String, Any>`：`:{...}` 路径写法不支持（抛 `IllegalArgumentException`）；
* 对 PO（`ObjectData<T>`）：允许路径写法，`:{user.name}`、`:{$.user.name}` 均可。
* 值转换规则：`None` → `NULL`；`Bool`/`DateTime`/`Duration`/`String`/`Array<Byte>` → 普通参数；数值 → 以字符串形式绑定；集合 → 展开为逗号分隔的多个 `?`（便于 `IN` 使用）；其它类型抛 `IllegalArgumentException`。
* 编译结果按 DSL 文本缓存（`HeapCache`，上限 10000 条，1 天过期）。

### 8.2 示例

```cangjie
let argMap = HashMap<String, Any>()
argMap['id'] = 1
executor.setSqlFromMap('delete from user_info where id = :id', argMap).delete
// 生成：delete from user_info where id = ?

executor.setSqlFromObject('update user_info set username = :username where id = :id', user)
```

配合子句使用时，可在 `SET` / `WHERE` 的闭包中直接写 DSL：

```cangjie
executor.UPDATE<UserPO>()
    .SET(arg: userMap) { 'username = :username' }
    .WHERE(arg: userMap) { 'id = :id' }
    .execute()
```

---

## 9. DSL 子句：`IntoClause` / `UpdateClause` / `FromClause`

三个子句类共同继承 `TableClause<T>` / `ExceptInsertClause<T>`，基于 `StringGenerator` 累积 SQL 片段，最终由具体方法执行。

```cangjie
abstract sealed class TableClause<T> <: ToString where T <: QueryMappersInit<T> {
    public prop executor: SqlExecutor          // 关联的执行器
    public func toString(): String             // 当前累积的 SQL 片段
    prop tableName: String                     // T.tableName()
    prop idType: ?DataType                     // PO 主键列的数据类型
}

public abstract class ExceptInsertClause<T> <: TableClause<T> where T <: QueryMappersInit<T> { /* 见 9.1 */ }
```

### 9.1 公共能力（`ExceptInsertClause`）

**多表连接**（`JOIN` 的表名取自泛型参数 `T`）：

```cangjie
public func INNER_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T>
public func LEFT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T>
public func RIGHT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T>
public func FULL_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T>
// 以上四个均有 ON!: LogicalExpr 与 ON!: () -> LogicalExpr 重载
```

`ON` 为空（或 `()`）时不生成 `ON` 子句。

**条件**：

```cangjie
public func WHERE(condition: () -> Unit): This          // 用 cond 内累积的 partial 生成 where
public func WHERE(condition: String): This
public func WHERE(condition: LogicalExpr): This
public func WHERE(condition: () -> LogicalExpr): This
public func WHERE(arg: Map<String, Any>, condition: () -> String): This         // DSL 模板
public func WHERE<T>(arg: T, condition: () -> String): This where T <: ObjectData<T>

public func AND(condition: () -> Unit): This      public func AND(condition: String): This
public func OR(condition: () -> Unit): This       public func OR(condition: String): This
public func NOT(condition: () -> Unit): This      public func NOT(condition: String): This
public func PAREN(condition: () -> Unit): This    public func PAREN(condition: String): This
public func PAREN(op: CondRelOp, condition: () -> Unit): This
public func PAREN(op: CondRelOp, condition: String): This

public func ORDER_BY(order: Array<Column>): This
public func ORDER_BY(orderBy: () -> String): This
public func LIMIT(size: Int64, offset!: Int64 = 0): This       // 由方言生成 limit/offset
```

> `WHERE` / `AND` / `OR` / `NOT` 会自动裁剪首尾残留的 `and` / `or` 关键字；闭包版本（`() -> Unit`）内部一般配合 `executor.AND{...}` / `executor.OR{...}` 等累积片段。

示例：

```cangjie
executor.FROM<UserPO>()
    .LEFT_JOIN<DeptPO>(AS: 'd', ON: { UserPO.tableColumns().deptId.eq(DeptPO.tableColumns().id) })
    .WHERE { AND { [UserPO.tableColumns().status.eq(1)] } }
    .ORDER_BY(UserPO.tableColumns().id.ASC())
    .list<UserPO>()
```

### 9.2 `FromClause<T>`（查询 / 删除）

```cangjie
// 查询
public func first<T>(): ?T                                       // limit 1
public func first<T>(columns: String): ?T
public func first<T>(columns: Columns): ?T
public func first<T>(columns: Array<Column>): ?T
public func singleFirst<T>(column: String): ?T
public func singleFirst<T>(column: Column): ?T
public func list<T>(): ArrayList<T>
public func list<T>(columns: String): ArrayList<T>
public func list<T>(columns: Columns): ArrayList<T>
public func list<T>(columns: Array<Column>): ArrayList<T>
public func singleList<T>(): ArrayList<T>                        // 默认取 id 列
public func singleList<T>(column: String): ArrayList<T>
public func singleList<T>(column: Column): ArrayList<T>
public func firstToMap(): Map<String, Any>
public func count(): Int64

// 分页
public func page<R>(size: Int64, page!: Int64 = 1): Pagination<R>
public func page<R>(columns: String, size: Int64, page!: Int64 = 1): Pagination<R>
public func singlePage<R>(size: Int64, page!: Int64 = 1): Pagination<R>              // 默认取 id 列
public func singlePage<R>(column: String, size: Int64, page!: Int64 = 1): Pagination<R>

// 按主键
public func findById(id: Int64): ?T
public func findById(id: UInt64): ?T
public func findById(id: String): ?T
public func deleteById(id: Int64): ?T
public func deleteById(id: UInt64): ?T
public func deleteById(id: String): ?T

// 分组
public func GROUP_BY(groupBy: () -> String): This
public func GROUP_BY(group: Array<Column>): This
public func HAVING(condition: () -> Unit): This
public func HAVING(condition: String): This
public func HAVING(logical: LogicalExpr): This
public func HAVING(arg: Map<String, Any>, condition: () -> String): This
public func HAVING<T>(arg: T, condition: () -> String): This where T <: ObjectData<T>

// 删除
public func DELETE(): Int64
public func DELETE(sql: String): Int64          // 生成 'delete <sql> <子句>'
```

> `findById` / `deleteById` / `count` 中主键列名取 `T.queryMappers().idName`，缺失时回退 `'id'`。
> `count()` 生成 `select count(*) from (select 1 <子句>) as __tmp___`。
> `deleteById` 的返回值标注为 `?T`（实际由 `first<T>()` 执行 DELETE 语句），日常使用建议直接用 `DELETE()` / `executor.delete`。

### 9.3 `UpdateClause<T>`（更新）

```cangjie
public func SET(set: () -> String): This
public func SET(set: Array<LogicalExpr>): This
public func SET(set: () -> Array<LogicalExpr>): This
public func SET(arg: Map<String, Any>, condition: () -> String): This            // DSL 模板
public func SET<T>(arg: T, condition: () -> String): This where T <: ObjectData<T>

public func execute(): Int64                        // 执行 update，返回影响行数
public func byId(id: Int64): Int64                  // 追加 where <主键>=? 并执行
public func byId(id: UInt64): Int64
public func byId(id: String): Int64
```

示例：

```cangjie
executor.UPDATE<UserPO>()
    .SET { 'username = ${arg(name)}' }
    .byId(1)

executor.UPDATE<UserPO>()
    .SET([UserPO.tableColumns().username.eq('tom'), UserPO.tableColumns().status.eq(1)])
    .WHERE { UserPO.tableColumns().id.eq(1) |> {c => c.toString()} }
    .execute()
```

### 9.4 `IntoClause<T>`（插入）

```cangjie
public func VALUES(values: Array<Any>): This                              // 按列顺序逐个绑定
public func VALUES<D>(value: D): This where D <: ObjectData<D>            // 直接绑定 PO
public func SELECT<T>(selectColumns: String): This where T <: QueryMappersInit<T>
public func SELECT<T>(selectColumns: String, fromClause: (FromClause<T>) -> Unit): This
                                                                          // insert into ... select ...
public func ON_DUPLICATE_KEY_UPDATE(columns: () -> String): This         // MySQL 风格
public func ON_CONFLICT(columns: Array<String>, DO_UPDATE_SET!: () -> String): This   // PostgreSQL 风格
public func execute()                                                     // 返回 lastInsertId
```

* 构造时若 `ignoreColumns` 与 `includingColumns` 同时非空，抛 `ORMException("ignores and includes can't be used together")`。
* 若 PO 存在主键列，`VALUES` 后会自动追加方言的 `lastInsertId` 片段（如 MySQL 的 `; select last_insert_id()`）。
* `VALUES<D>` 会按字段类型做数值转换（`DataReal` → 目标列类型），不支持的字段类型抛 `SqlArgException`。

示例：

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

## 10. 逻辑表达式与列对象

### 10.1 `Column` 与 `Columns`

`@QueryMappersGenerator` 会为 PO 生成一个列集合类（继承 `Columns`）以及静态方法 `T.tableColumns()`：

```cangjie
public interface QueryMappersObject<T, C> <: QueryMappersInit<T>
    where C <: Columns, T <: QueryMappersObject<T, C> {
    static func tableColumns(): C
}

public abstract class Columns <: ToString & Iterable<Column> {
    public func tableAlias(alias: String): This       // 给该列集合下所有列设置表别名
}

public class Column <: ToString & Hashable & Equatable<Column> {
    public Column(let name: String)
    public prop name: String                          // 列名（构造参数公开）

    public func AS(alias: String): This               // 列别名（与 ASC/DESC 互斥）
    public func tableAlias(alias: String): This       // 表别名
    public func ASC(): This                           // 升序
    public func DESC(): This                          // 降序
    public func toString(): String

    // 比较运算 → LogicalExpr
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
    public func IN<T, I>(arg: Collection<I>): LogicalExpr where I <: Collection<T>      // 二维集合
    public func NOT_IN<T, I>(arg: Collection<I>): LogicalExpr where I <: Collection<T>
    public func BETWEEN(one: Any, two: Any): LogicalExpr
    public func NOT_BETWEEN(one: Any, two: Any): LogicalExpr
    public func IS_NULL(): LogicalExpr
    public func IS_NOT_NULL(): LogicalExpr
}
```

> `Column.toString()` 会通过 `SqlExecutor.involve(...)` 给标识符加引用符（反引号/双引号，随方言），因此 `'select * from t where ${col} = 1'` 这类拼接是安全的。
> 若同时设置了 `AS(...)` 与 `ASC()/DESC()`，`toString()` 会抛 `ORMException('column alias and column alias cannot be set at the same time')`。

### 10.2 `CmpOp` / `RelationOp` 枚举

```cangjie
public enum CmpOp <: ToString {
    | EQ | NEQ | LT | LTE | GT | GTE
    | IN | NOT_IN | LIKE | NOT_LIKE
    | IS_NULL | IS_NOT_NULL | BETWEEN | NOT_BETWEEN
}   // toString() → " = "、" <> "、" < "、" <= "、" > "、" >= "、" IN "、" NOT IN "、
    //                " LIKE "、" NOT LIKE "、" IS NULL "、" IS NOT NULL "、" BETWEEN "、" NOT BETWEEN "

public enum RelationOp <: ToString { | AND | OR | NOT }   // toString() → " AND "、" OR "、" NOT "
```

### 10.3 `LogicalExpr` 家族

```cangjie
public interface LogicalExpr <: ToString {}

public struct EmptyExpr <: LogicalExpr                     // toString() → ''
public open class CmpExpr <: RootDAO & LogicalExpr          // 单列比较，如 `id = ?`
public class BetweenExpr <: CmpExpr                         // `col BETWEEN ? AND ?`
public class InExpr<T> <: RootDAO & LogicalExpr             // `col IN (?, ...)`
public class In2Expr<I, T> <: RootDAO & LogicalExpr where I <: Collection<T>   // 二维 IN
public class NullExpr <: CmpExpr                            // `col IS NULL` / `IS NOT NULL`
public class RelationExpr <: LogicalExpr & ToString         // AND / OR / NOT 组合
public class ParenExpr <: LogicalExpr & ToString            // 括号
public class CommaExpr <: LogicalExpr & ToString            // 逗号分隔（用于 SET 多列赋值）
```

### 10.4 `RootDAO` 的 `LogicalExpr` 版本逻辑运算

```cangjie
//接收Array或LogicalExpr为参数的AND/OR/NOT返回的LogicalExpr不会被括号包含
func AND(exprs: Array<LogicalExpr>): LogicalExpr
func OR(exprs: Array<LogicalExpr>): LogicalExpr
func NOT(exprs: LogicalExpr): LogicalExpr
//接收闭包为参数的AND/OR/NOT返回的LogicalExpr会自动被括号包含
func AND(exprs: () -> Array<LogicalExpr>): LogicalExpr
func OR(exprs: () -> Array<LogicalExpr>): LogicalExpr
func NOT(exprs: () -> LogicalExpr): LogicalExpr
//数组只有一个元素时相当于不使用AND/OR/NOT
```

示例（来自 `fdemo`）：

```cangjie
executor.FROM<UserPO>().WHERE(
    AND([ meet(username.size > 0){ UserPO.tableColumns().username.LIKE('%${username}%') },
          meet(password.size > 0){ UserPO.tableColumns().password.LIKE('%${password}%') } ]))
    .ORDER_BY([UserPO.tableColumns().id.ASC()])
    .page<UserPO>(100, page: 1)
```

### 10.5 常用函数
现在支持COUNT、SUM、AVG、MAX、MIN，它们都是RootDAO的实例成员，可以直接在继承了RootDAO的DAO接口中调用。
```cj
func COUNT(): Column // COUNT(*)
func COUNT(column: Column): Column
func SUM(column: Column): Column
func AVG(column: Column): Column
func MAX(column: Column): Column
func MIN(column: Column): Column
```

---

## 11. 条件构造器

`SET{}` / `WHERE{}` 闭包内的「按需拼接」能力由三个构造器与 `Condition` 静态类提供。它们都会在 `done()` / `frag()` 时把片段追加到当前 `SqlExecutor` 的 partials 中；直接取返回值也能得到片段字符串。

### 11.1 `Condition` 静态工具

```cangjie
public class Condition {   // 私有构造，静态使用
    public static func loop<I, T>(values: I, executor: SqlExecutor): LoopCondition<I, T>
        where I <: Iterable<T>

    public static func SET(partial: () -> String): String        // 前缀 ' SET '，并以 ',' 作为分隔符
    public static func WHERE(partial: () -> String): String       // 前缀 ' WHERE '
    public static func WHERE(delimiter: String, partial: () -> String): String
    public static func trim(prefix!: String = '', suffix!: String = '', partial!: () -> String): String
}
```

* `SET` / `WHERE` 内部会**设置 `Condition.delimiter`**（`SET` 用 `,`，`WHERE` 用调用方传入值，默认空），从而让 `meet(...).done()` 之间自动补上连接词。
* `trim` 用正则裁掉片段首尾（如 `SET` 裁 `,`，`WHERE` 裁 `and|or`）。
* 片段为空时返回空串，因此 `''` 关键字不会出现在 SQL 中——这正是「按需拼接」的实现方式。

### 11.2 `MeetCondition`（条件成立才拼）

```cangjie
public class MeetCondition {
    public prop argInSql: MeetCondition                       // 值直接写进 SQL（不绑定参数），谨慎使用
    public func value(value: Any): MeetCondition
    public func value(value: () -> Any): MeetCondition
    public func frag(frag: String): String                    // 拼接 '<partial> <frag> <delimiter>'
    public func frag(frag: () -> String): String
    public func done(): String                                // partial + 绑定值（生成 '?'）
    public func BETWEEN(one: Any, two: Any): String
    public func NOT_BETWEEN(one: Any, two: Any): String
    public func IN<I, T>(itr: I): String where I <: Iterable<T>
    public func NOT_IN<I, T>(itr: I): String where I <: Iterable<T>
    public func EXISTS(fn: () -> String): String
    public func NOT_EXISTS(fn: () -> String): String
}
```

入口是 `RootDAO` 的 `meet`（见 [6.2](#62-条件片段meet)）。典型写法：

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

> `SET{}` / `WHERE{}` 中每一行模板片段之间用换行分隔即可；`meet` 未命中时返回空串，`trim` 会自动去掉多余的首尾 `and`/`,`。

### 11.3 `ChooseCondition`（多分支择一）

入口：`executor.choose`（`RootDAO.choose`）。

```cangjie
public class ChooseCondition {
    public prop argInSql: ChooseCondition
    public func condition(condition: () -> Bool): ChooseCondition      // 开始一个分支
    public func partial(partial: () -> (String, Any)): ChooseCondition // 分支的片段与值
    public func partial(partial: () -> String): ChooseCondition
    public func partial(partial: () -> Any): ChooseCondition           // 只有值，片段为空
    public func otherwise(partial: () -> (String, Any)): ChooseCondition
    public func otherwise(partial: () -> String): ChooseCondition
    public func otherwise(partial: () -> Any): ChooseCondition
    public func done(): String
}
```

`condition` 与 `partial` 必须严格成对，否则抛 `ORMException('condition and sql partial generation function arg not paring')`。命中第一个条件后即返回，都不命中则用 `otherwise`。

```cangjie
executor.choose
    .condition { name.size > 0 }.partial { ('username like', '%${name}%') }
    .condition { id > 0 }.partial { ('id =', id) }
    .otherwise { ('1 = 1', ()) }
    .done()
```

### 11.4 `LoopCondition`（遍历集合拼接）

入口：`executor.loop(values)`（`RootDAO.loop`）。

```cangjie
public class LoopCondition<I, T> where I <: Iterable<T> {
    public func wrap(left: String, right: String): LoopCondition<I, T>    // 整体包裹（前后缀）
    public func wrapLeft(left: String): LoopCondition<I, T>
    public func wrapRight(right: String): LoopCondition<I, T>
    public func trim(left: String, right: String): LoopCondition<I, T>    // 裁掉首尾
    public func trimLeft(left: String): LoopCondition<I, T>
    public func trimRight(right: String): LoopCondition<I, T>
    public func delimiter(d: String): LoopCondition<I, T>                 // 元素间连接符
    public prop argInSql: LoopCondition<I, T>
    public func condition(cond: (T, Int64) -> Bool): LoopCondition<I, T>   // 过滤元素（第二参为下标）
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

---

## 12. 分页 `Pagination`

```cangjie
public class Pagination<T> <: ObjectData<Pagination<T>> where T <: DataFields<T> {
    public let page: Int64        // 当前页码（从 1 开始）
    public let size: Int64        // 每页大小
    public let rows: Int64        // 总记录数
    public let pages: Int64       // 总页数 = rows / size 向上取整
    public let list: ArrayList<T> // 当前页数据

    public init(page!: Int64, size!: Int64, rows!: Int64, list!: ArrayList<T>)
    public init(page!: Int64, size!: Int64, rows!: Int64, list!: () -> ArrayList<T>)
    public init(page!: Int64, size!: Int64, rows!: Int64, list!: (Int64, Int64) -> ArrayList<T>)

    public func toData(): Data
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any
    public static func dataFields(): ObjectFields
}
```

* `list!` 为闭包时**惰性求值**：`rows == 0` 直接返回空列表，不会执行查询。
* `list!: (Int64, Int64) -> ArrayList<T>` 版本会传入 `(size, (page - 1) * size)`，即「每页大小 + 偏移量」。
* `Pagination` 可作为 PO 的字段类型（实现了 `ObjectData`），并支持与 `Data` 互转（`toData()` / `tryFromData`）。

`page` / `singlePage`（`SqlPartial`、`FromClause`）内部会先执行 count 查询得到 `rows`，再按 `list` 闭包执行分页查询：

```cangjie
let p = executor.FROM<UserPO>()
    .WHERE(UserPO.tableColumns().state.eq(1))
    .ORDER_BY([UserPO.tableColumns().id.DESC()])
    .page<UserPO>(10, page: 2)
```

---

## 13. 结果映射

### 13.1 `QueryMappersInit` 与简单类型

```cangjie
public interface QueryMappersInit<T> where T <: QueryMappersInit<T> {
    static func tableName(): String
    static func isSimpleData(): Bool        // 简单类型返回 true，走单列映射路径
    static func queryMappers(): QueryMappers<T>
}

public interface SimpleDataQueryMappersInit<T> <: QueryMappersInit<T> where T <: QueryMappersInit<T> {
    // isSimpleData() → true；tableName() → ''；queryMappers() → 抛 ORMException('not supported')
}

public interface QueryMappersObject<T, C> <: QueryMappersInit<T>
    where C <: Columns, T <: QueryMappersObject<T, C> {
    static func tableColumns(): C
}
```

模块已为下列类型实现了 `SimpleDataQueryMappersInit`：`Int8`、`UInt8`、`Int16`、`UInt16`、`Int32`、`UInt32`、`Int64`、`UInt64`、`Float16`、`Float32`、`Float64`、`Rune`、`String`、`Bool`、`Duration`、`DateTime`、`Decimal`、`BigInt`、`Array<T>`（`T` 亦为 `QueryMappersInit`）、以及 `Option<T>`。

### 13.2 `QueryMappers<O>`

```cangjie
public class QueryMappers<O> {
    public QueryMappers(
        protected let mappers!: Array<QueryMapper<O>>,   // 每个列一个 mapper
        protected let creator!: () -> O                  // 实例创建器
    )

    // 继承场景：把父类 O 的 mapper 与子类新增 mapper 合并
    public static func create<T>(mappers!: Array<QueryMapper<T>>, creator!: () -> T): ?QueryMappers<T>

    public func list(result: QueryResultWrap): ArrayList<O>
    public func groupedList<ID>(result: QueryResultWrap): ArrayList<O> where ID <: Hashable & Equatable<ID>
    public func iterator(result: QueryResultWrap): QueryResultIterator<O>
    public func one(result: QueryResultWrap): Option<O>

    protected prop idName: ?String       // 主键列名（无主键为 None）
}
```

* 构造时会统计 `hasGroup`（是否存在 grouped mapper）与 `idMapper`（主键 mapper）。
* `groupedList` 在存在 grouped mapper 时按主键去重合并，主键相同的行会追加进集合字段（一对多关联）。
* `list` / `one` 通过 `protected func map(result)` 逐列 `populate` 生成对象。

### 13.3 `QueryMapper` 家族

```cangjie
public open class QueryMapper<O> {
    public QueryMapper(dataType!: DataType = UnknownDataType(true, '', ''), putter!: (O, Any) -> Unit)
    public func get<T>(result: QueryResultWrap): ?T
    public open func populate(result: QueryResultWrap, o: O): O
    protected prop columnName: String
    protected prop fieldName: String
    protected open prop isGrouped: Bool      // 默认 false
    protected open prop isId: Bool           // 默认 false
}

public open class FieldQueryMapper<T, O> <: QueryMapper<O> {
    public init(dataType!: DataType = UnknownDataType(true, '', ''), putter!: (O, T) -> Unit)
    // populate 时会按列类型做 ORMConverter.convert<T> 转换；可空列用 convertNullable
}

public class IdQueryMapper<ID, O> <: FieldQueryMapper<ID, O> where ID <: Hashable & Equatable<ID> {
    public init(dataType!: DataType = Int64DataType(false, 'id', 'id'), putter!: (O, ID) -> Unit)
    public func id(result: QueryResultWrap): ID      // 取主键值
}
```

**关联映射**（由 `@ORMField` 中的关联语法生成）：

```cangjie
public class NestQueryMapper<T, O> <: QueryMapper<O>
    where O <: QueryMappersInit<O>, T <: QueryMappersInit<T> {
    public NestQueryMapper(nested!: QueryMappers<T>, nestPutter!: (O, T) -> Unit)   // 一对一 / 多对一
}

public class NullableNestQueryMapper<T, O> <: QueryMapper<O> {
    public NullableNestQueryMapper(nested!: QueryMappers<T>, nestGetter!: (O) -> Option<T>, nestPutter!: (O, T) -> Unit)
}

public class GroupedQueryMapper<T, O> <: QueryMapper<O> {
    public GroupedQueryMapper(grouped!: QueryMappers<T>, groupedGetter!: (O) -> ArrayList<T>)  // 一对多 / 多对多
}

public class GroupedSingleQueryMapper<T, O> <: QueryMapper<O> {
    public GroupedSingleQueryMapper(name!: String, groupedGetter!: (O) -> ArrayList<T>)  // 单列集合（如逗号拼接的 id 列表）
}

public class NullableGroupedQueryMapper<T, O> <: QueryMapper<O> {
    public NullableGroupedQueryMapper(ignoreNone!: Bool = true, grouped!: QueryMappers<T>,
                                      groupedGetter!: (O) -> ArrayList<Option<T>>)
}
```

> `GroupedSingleQueryMapper` 用于「一行一列里装着一个集合」的场景，把该列的值（如 `1,2,3` 拆分后的多行）逐个 `convert<T>` 后追加。

### 13.4 迭代器

```cangjie
public class QueryResultIterator<T> <: Iterator<T> & Resource {
    public func next(): ?T
    public func isClosed(): Bool
    public func close(): Unit
}

public class SingleColumnIterator<T> <: Iterator<T> & Resource {
    public func next(): ?T
    public func isClosed(): Bool
    public func close(): Unit
}
```

使用 `executor.iterator<T>()` / `executor.singleIterator<T>()` 得到的迭代器需要显式 `close()`，或在 `try (it = executor.iterator<UserPO>()) { ... }` 中由 `Resource` 自动关闭。

### 13.5 自定义类型转换：`QueryMapperConverter`

当 PO 字段不是基础类型、也不在 `SimpleDataQueryMappersInit` 列表中时，可用转换器把列值转换成目标类型。

```cangjie
public abstract class QueryMapperConverter {
    public static func lookup(name: String): QueryMapperConverter    // 按 bean 名 / 类全名查找，未找到则反射构造
    public func convert<T>(data: Any): T where T <: DataFields<T>
}

public class QueryMapperJsonConverter <: QueryMapperConverter {}                  // JSON 文本 / Array<Byte> / InputStream → T
public class QueryMapperWithTypeNameJsonConverter <: QueryMapperConverter {
    public static func toJson<T>(data: T): String where T <: DataFields<T>        // 带 typeName 的 JSON
}
```

* 通过 `ORMConfig.registerConverter<D, T>(name, converter)` 注册**具名转换器**（`f_data` 的 `@DataConverter` 机制），`@ORMField` 里用 `converter: '<name>'` 引用；
* 也可以直接给出类名（如 `converter: 'fountain::f_orm.base.QueryMapperJsonConverter'`），`lookup` 会先按 bean 名查找，再按全名匹配已注册的 bean，最后尝试反射 `construct([])`。

---

## 14. 事务

### 14.1 传播行为 `Propagation`

```cangjie
public enum Propagation {
    | Required      // 外层已开启事务则沿用；否则新建事务
    | Supports      // 外层已开启事务则沿用；否则不用事务
    | Mandatory     // 外层已开启事务则沿用；没有事务则抛 MandatoryTransactionException
    | RequiresNew   // 外层无事务则复用连接并开启事务；外层有事务则新取连接、开新事务
    | Never         // 不使用事务；外层有事务则抛 NeverTransactionException
    | NotSupported  // 不使用事务；外层有事务则新取连接执行
    | Nested        // 外层有事务则开内嵌事务；否则也不使用事务
}
```

> `RequiresNew` 与 `NotSupported` 会**新建连接**；在这两个传播行为的作用范围内，另外的传播行为判定仍以外层连接是否已开启事务为依据。

### 14.2 事务模板 `execute`

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
    1    // 第二个返回值由闭包返回 (T, Bool)：true 提交，false 抛异常并回滚
}
```

回调可用的执行器方法（见 [5.5](#55-事务控制)）：`commit()`、`rollback()`、`rollback(savepoint)`、`save(savepoint)`、`release(savepoint)`、`callAndCommit{}`、`noRollbackFor(e)`、`rollbackFor(e)`。

### 14.3 `@Transactional` 注解

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

    public func getPropagation(): Propagation                     // 未指定 → Required
    public func getIsoLevel(): ?TransactionIsoLevel               // 未指定 → ORMConfig 全局配置
    public func getAccessMode(): ?TransactionAccessMode
    public func getDeferrableMode(): ?TransactionDeferrableMode
}
```

被 `@Transactional` 标注的函数会由 `TransactionAspect` 织入事务：

```cangjie
@Transactional[propagation: Propagation.RequiresNew, rollbackFor: 'fountain::f_exception::BizException']
public func transfer(from: Int64, to: Int64, amount: Decimal): Unit { ... }
```

**配置驱动的切面**：除注解外，还可以通过 `orm_transactionalFuncExecution`（函数签名模式）配合 `orm_transactionIncluding` / `orm_transactionExcluding`（正则）让切面自动命中函数，无需逐个加注解。

### 14.4 `TransactionHook` 与钩子顺序

```cangjie
public interface TransactionHook {
    func beforeTx(): Unit {}
    func beforeCommit(readOnly: Bool): Unit {}
    func afterCommit(): Unit {}
    func afterThrowing(e: Exception): Unit {}
    func beforeRollback(e: Exception): Unit {}
    func afterRollback(e: Exception): Unit {}
    func afterComplete(status: TransactionStatus): Unit {}
    prop order: Int64 { get() { Int64.Max } }        // 决定钩子执行顺序（升序）
}
```

* 注册：`ORM.registerTransactionHook<MyHook>(MyHook())`，或 `ORM.registerTransactionHooks<MyHook>()`（从 `lookupList<MyHook>()` 批量取 bean）。
* 同 `order` 的钩子按注册先后执行（`TransactionHookWrap.compare` 先比 `order`，再比注册序号）。

**事务回调顺序**：

| 场景 | 顺序 |
| --- | --- |
| 提交 | `beforeTx` → `beforeCommit` → `commit` → `afterCommit` → `afterComplete(Committed)` |
| 异常 | `afterThrowing` → `beforeRollback` → `rollback` → `afterRollback` → `afterComplete(Rollback)` |

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

切面在 `proceed` 中解析注解与配置，取 `ORM.executor(driverName)` 后调用 `execute<Any>(...)` 包裹原方法调用。

### 14.6 `RootService`（Service 层基接口）

```cangjie
public interface RootService {
    func executor(name: String): SqlExecutor         // name 为空时取默认数据源
    func executor(): SqlExecutor
    func dao<T>(driver: String): T where T <: RootDAO     // 取 SqlExecutor 并转成 DAO 接口
    func dao<T>(): T where T <: RootDAO
}
```

`dao<T>()` 依赖 `SqlExecutor` 能隐式转为 `T`（即 `@DAO` 生成的接口实现），失败时抛 `ORMException('${TypeInfo.of<T>()} is not extended to SqlExecutor')`。

---

## 15. 宏

### 15.1 `@DAO`

**作用**：标注在**接口**上，展开为「原接口 + `extend SqlExecutor <: <接口名> {}`」。

```cangjie
@DAO
public interface UserDAO <: RootDAO {
    func findUser(id: Int64): UserPO {
        executor.FROM<UserPO>().WHERE(UserPO.tableColumns().id.eq(id)).first<UserPO>().getOrThrow()
    }
}
```

要点：

* **接口本身承载实现**：DAO 函数必须在接口里给出函数体（由 `SqlExecutor` 的扩展继承）。因此没有「DAO 实现类」，`SqlExecutor` 就是实现。
* 约束（宏会断言/告警）：
  * 接口必须是 `public`、**不能有泛型形参**，且必须继承 `RootDAO`；
  * 所有 DAO 函数必须有默认实现；
  * **一个持久化对象对应一个 DAO 接口**；
  * 同一模块内所有 DAO 的函数名不能重名（因为都挂在 `SqlExecutor` 上）。
* 接口内可直接使用 `executor`、`arg(...)`、`meet(...)`、`choose`、`loop(...)` 等 `RootDAO` 成员。
* 获取 DAO：`executor()`（`RootService`）返回的 `SqlExecutor` 即是 DAO；也可 `ORM.executor() as UserDAO`。
* 需要事务时给 DAO/Service 方法加 `@Transactional`。

### 15.2 `@QueryMappersGenerator`

**作用**：为 PO（class）生成列映射、`QueryMappersInit` / `QueryMappersObject` 实现、列集合类，并把该类注册进表元数据（供 migro 使用）。

```cangjie
@QueryMappersGenerator[table: '"user_info"' dirty]
@DataAssist[fields tostring]        // @DataAssist 需写在 @QueryMappersGenerator 之前（先展开）
public class UserPO {
    @ORMField[true 'id']            // 主键，列名固定为 id
    private var id: Int64 = 0
    @ORMField['username']
    private var username: String = ''
    @ORMField[true LowerUnderScore] // 主键，列名由成员名转下划线（即 user_name）
    private var userName: String = ''
}
```

**生成内容（业务可直接调用）**：

| 生成物 | 说明 |
| --- | --- |
| `static func queryMappers(): QueryMappers<T>` | 全列 mapper 集合；有父类时会合并父类 mapper（`QueryMappers.create`） |
| `static func tableName(): String` | 表名 |
| `static func isSimpleData(): Bool` | PO 返回 `false` |
| `static func tableColumns(): C` | 列集合对象（见下），并让 PO 继承 `QueryMappersObject<T, C>` |
| 列集合类 | 生成在 PO 所在包内，包含 `toString()`（列名逗号连接）、`iterator(): Iterator<Column>`，以及每个列一个 `Column` 属性 |

> **列集合属性名是「列名」而非「成员名」**：`@ORMField['user_name'] private var userName` 对应 `tableColumns().user_name`。
> 未使用 `@ORMField` 的 public 实例成员，默认「非主键 + 成员名按 `LowerUnderScore` 转列名」。

**宏属性**：

| 属性 | 形式 | 效果 |
| --- | --- | --- |
| 表名 | `[user_info]`（仅一个属性时） | 表名 |
| 表名 | `[table: 'user_info']` / `[table: user_info]` | 表名（字符串/标识符均可） |
| 命名策略 | `[table: LowerUnderScore]` | 类名 → 表名按策略转换 |
| 表名前缀/后缀 | `[tablePrefix: 't_' tableSuffix: '_tab']` | 拼接到表名 |
| 类名前后缀 | `[classPrefix: 'F_' classSuffix: 'PO']` | 生成列集合类名时剥离 |
| 脏字段追踪 | `[dirty]` | 为 setter 注入 `DirtyTag.setDirtyField<T>(...)`（仅简单类型 / `?T` / `Option<T>`），配合 `UPDATE(values, dirty: true)` |
| 兼容写法 | `[table: xxx dirty]` | 表名 + dirty 同时给出 |

未写任何属性时，表名/列名按类名/成员名的 `LowerUnderScore` 转换。

### 15.3 `@ORMField`

**作用**：标注在 PO 成员上，声明主键、列名与转换器。**必须与 `@QueryMappersGenerator` 配合使用**。

```cangjie
public macro ORMField(attrs: Tokens, input: Tokens): Tokens
```

**属性语法**（各部分可选、顺序任意）：

| 写法 | 含义 |
| --- | --- |
| `true` / `id` | 标记为主键 |
| `false` | 非主键（与省略等价） |
| `'column_name'` / `"column_name"` | 固定列名 |
| `LowerUnderScore` | 成员名（驼峰）转下划线小写列名 |
| `UpperUnderScore` | 转大写下划线列名 |
| `Pascal` | 转大驼峰列名 |
| `Camel` | 列名 = 成员名 |
| `column: <上述任意形式>` | 显式指定列名 |
| `converter: <beanName>` | 指定 `QueryMapperConverter` 的 bean 名或全限定类型名 |

示例：`@ORMField[true LowerUnderScore]`、`@ORMField[id column: 'user_name' converter: 'userNameConverter']`。

**宏的改写行为**：被标注的 `var` 会改写成 `private var _name_` + `public mut prop name`（setter 中按需插入脏标记），因此业务代码访问方式不变。约束：

* 只能标注**成员变量或 `mut` 属性**（`immutable` 属性无法映射）；
* 成员必须是非静态实例成员；
* 属性名建议使用驼峰命名法（配合 `LowerUnderScore` 等策略）。

> 另有注解类 `ORMColumn`（`@Annotation[target: [MemberProperty, MemberVariable]]`，字段 `name!: String`、`id!: Bool`）提供与列名/主键有关的等价声明能力。

### 15.4 `@TransactionalService`

```cangjie
// macros/TransactionalService.cj 实际只是再导出：
public import fountain::f_aspect.macros.WeavedBean as TransactionalService
```

**作用**：等价于 `@WeavedBean`，把被标注的 Service 类织入切面链（配合 `TransactionAspect` 与 `orm_transactionalFuncExecution` 配置实现事务织入，无需逐方法写 `@Transactional`）。见 `fdemo`：

```cangjie
@TransactionalService            // 不需要事务控制时可用 @Bean 修饰
public class UserServiceImpl <: UserService {
    public func register(username: String, password: String): Int64 {
        executor().register(username, password)     // executor() 返回 SqlExecutor，可直接当 DAO 用
    }
}
```

## 16. 表结构元数据与 migro

f_orm 支持「由 PO 定义反推数据库表结构」：给 PO 加上 `@DatabaseSchema` / `@IndexSchema` / `@ColumnSchema` 注解后，`@QueryMappersGenerator` 会把表元数据自动注册到全局注册表；`migro` 子模块据此比对数据库现状，生成（并可选执行）DDL。

### 16.1 表结构注解

**`@DatabaseSchema`** — 声明在映射类（class）上，标记目标库：

```cangjie
@Annotation[target: [Type]]
public class DatabaseSchema {
    public const DatabaseSchema(
        private let driver!: String = '',   // 驱动名；省略时回退到 ORM.defaultDriver
        public let database!: String        // 目标数据库名
    ){}
    public prop driverName: String          // 空 driver 时返回 ORM.defaultDriver
}
```

用法：

```cangjie
@DatabaseSchema[database: 'user_db']                        // 使用默认驱动
@DatabaseSchema[driver: 'postgres' database: 'user_db']     // 指定驱动
@QueryMappersGenerator[table: 'user_info']
@DataAssist[fields]
public class UserPO { ... }
```

> `TableMeta.new<T>()` 找不到 `@DatabaseSchema` 时抛 `TableMetaException`。

**`@IndexSchema`** — 声明在映射类上，可标注多个（`findAllAnnotations`），描述期望的索引：

```cangjie
@Annotation[target: [Type]]
public class IndexSchema {
    public const IndexSchema(
        public let name!: String,      // 索引名
        public let columns!: String,   // 列名，逗号分隔
        public let unique!: Bool       // 是否唯一索引
    ){}
}
```

**`@ColumnSchema`** — 声明在 PO 的成员属性/成员变量上（配合 `@ORMField` 使用）：

```cangjie
@Annotation[target: [MemberProperty, MemberVariable]]
public class ColumnSchema {
    public const ColumnSchema(
        public let oldColumnName!: String = '',   // 旧列名（生成重命名语句用）
        public let typeName!: String,             // 数据库类型，如 'varchar(100)'
        public let nullable!: Bool = false,
        public let default!: ?String = None,
        public let extra!: String = '',           // 如 'auto_increment'
        public let comment!: String = ''
    ){}
}
```

> 只有**带 `@ColumnSchema` 注解**的列才会进入 `TableMeta.columns`；未标注的列不参与 DDL 生成。

用法：

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

`new<T>()` 的构建过程（基于 `std.reflect`）：

1. 读取类上的 `@DatabaseSchema`（缺失抛 `TableMetaException`），得到 `database` 与 `driver`（`driverName` 属性，空则取 `ORM.defaultDriver`）；
2. `T.tableName()` 取表名；
3. 遍历 `T.queryMappers().mappers`，按 `fieldName` 在 `TypeInfo` 上查实例属性/成员变量上的 `@ColumnSchema`，命中则构建 `ColumnMeta(schema, columnName)`，未命中则跳过该列；
4. `findAllAnnotations<IndexSchema>()` 构建索引元数据数组。

**`ColumnMeta`**（`@DataAssist[fields]`，实现 `Hashable & Equatable<ColumnMeta>`）：

| 成员 | 类型 | 说明 |
| --- | --- | --- |
| `columnName` | `String` | 列名 |
| `oldColumnName` | `String` | 旧列名（重命名用） |
| `typeName` | `String` | 数据库类型 |
| `nullable` | `Bool` | 是否可空 |
| `default` | `?String` | 默认值 |
| `extra` | `String` | 附加属性（如 `auto_increment`） |
| `comment` | `String` | 注释 |

构造器：`ColumnMeta()`（全部默认）/ `ColumnMeta(schema: ColumnSchema, columnName: String)`。
`hashCode` 与 `==` 基于 `columnName / typeName / nullable / default / extra`（**不含** `oldColumnName` 与 `comment`）。

**`IndexMeta`**（`@DataAssist[fields]`，实现 `Hashable & Equatable<IndexMeta>`）：

| 成员 | 类型 | 说明 |
| --- | --- | --- |
| `name` | `String` | 索引名 |
| `columns` | `String` | 列名（逗号分隔） |
| `unique` | `Bool` | 是否唯一 |
| `def` | `String` | 索引定义 SQL（Postgres 从 `pg_indexes.indexdef` 提取，用于原样重建） |

构造器：`IndexMeta()` / `IndexMeta(name: String, columns: String, unique: Bool)` / `IndexMeta(schema: IndexSchema)`。
`hashCode` 与 `==` 基于 `name / columns / unique`（**不含** `def`）。

### 16.3 注册表 `TableMetas`

```cangjie
public struct TableMetas {
    public static func register<T>(): Unit where T <: QueryMappersInit<T>
    public static func tableMetas(): Iterator<TableMeta>
    public static func clear(): Unit
}
```

| 方法 | 说明 |
| --- | --- |
| `register<T>()` | 构建 `TableMeta.new<T>()` 并以 `TypeInfo` 为键登记到内部 `ConcurrentHashMap`；失败只打 warn 日志，不抛异常 |
| `tableMetas()` | 遍历已登记的全部表元数据 |
| `clear()` | 清空注册表 |

> 一般情况下无需手工注册——`@QueryMappersGenerator` 已在 PO 初始化路径中调用 `register`，这也是 migro 能发现所有表的原因。

### 16.4 `SchemaFinder` 接口与内置实现

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

| 方法 | 说明 |
| --- | --- |
| `listTables` | 列出库中所有表名（migro 用它找出「多余表」） |
| `findTableSchema` / `findIndexes` | 读取库中现有列/索引（查询 `information_schema` 等系统表） |
| `generateCreateSql` | 无表 → 生成建表语句（返回迭代器，Postgres 实现会额外返回 `SET DEFAULT` 语句） |
| `generateDropTableSql` | 生成删表语句 |
| `generateAlterSql` | 有表 → 对比新旧列生成变更语句（新增/删除/改类型/改可空/改默认/重命名） |
| `generateIndexSql` | 对比新旧索引生成变更语句（增删索引） |

内置实现类（均为 `@Bean`，通过 `lookupList<SchemaFinder>()` 按 `driverName` 发现）：

| 实现类 | `driverName` |
| --- | --- |
| `MysqlSchemaFinder` | `mysql` |
| `MariaDBSchemaFinder` | `mariadb` |
| `PostgresSchemaFinder` | `postgres` |
| `OpenGaussSchemaFinder` | `opengauss` |

> `AbstractMysqlSchemaFinder`、`AbstractPostgresSchemaFinder` 是公开的抽象基类，分别封装两种方言的通用解析与 SQL 生成逻辑；自定义方言可实现 `SchemaFinder` 接口并标注 `@Bean`。

两种实现的差异要点：

* **MySQL/MariaDB**：列类型直接取 `information_schema.columns.column_type`（如 `varchar(100)`）；改列名生成 `change <old> <new> ...`；索引为 `add index` / `add unique` / `drop index`。
* **Postgres/OpenGauss**：类型由 `udt_name` 拼接长度/精度得到；改列名生成 `rename column ... to`、改类型生成 `alter column ... type`；索引优先使用 `IndexMeta.def`（原 `indexdef`）原样重建。

`generateAlterSql` 的判定逻辑：

* 新定义列不在库中 → `add column`；
* 库中列不在新定义中 → `drop column`；
* 同名列属性不同 → 修改类型 / 可空 / 默认值；
* `oldColumnName` 非空且与库中不一致 → 按重命名处理。

### 16.5 `SchemaFinderMediator` 与 `dbmigro` 子命令

```cangjie
public struct SchemaFinderMediator {
    public init()                                   // lookupList<SchemaFinder>() 按 driverName 建索引
    public func generate(cmdargs: Array<String>): Unit
}
```

`generate` 的完整流程：

1. `TableMetas.tableMetas()` 按 `driver` 分组；
2. 对每个已注册表：查库中列 → 无表则 `generateCreateSql`，有表则 `generateAlterSql`；随后查库中索引 → `generateIndexSql`；
3. 每个数据库的首条 SQL 前插入 `use <database>;`；
4. 为「库中存在、但定义中没有」的表生成 `drop table`（孤儿表清理）；
5. 所有 SQL 首先打印到标准输出；
6. 解析 `-m` / `--mode` 参数决定后续动作。

| `-m` / `--mode` | 行为 |
| --- | --- |
| 省略 | 仅打印 SQL，不写文件不执行 |
| `file` | 把 SQL 写入当前目录 `./migro.sql` |
| `auto` | 通过 `ORM.executor(driver)` 逐条执行 |
| `dry` | 仅打印（与省略相同） |
| `interactive` | 打印后询问 `> 是否立即执行生成的SQL? [y/N]：`，输入 `y`/`Y` 执行 |

> 非上述取值会抛 `Exception("Invalid migration mode ...")`。执行模式下每条 SQL 失败只打印堆栈、不中断后续语句。

命令行入口（`f_app` 子命令框架）：

```cangjie
public struct MigroCommand <: SubCommand {
    static init() { SubCommandMediator.register(MigroCommand()) }   // 随模块加载自动注册
    public prop command: String { get() { 'dbmigro' } }
    public func exec(args: Array<String>): Int64 { SchemaFinderMediator().generate(args); 0 }
}
```

使用示例：

```bash
fboot dbmigro --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))'
fboot dbmigro --dylibPattern='...' -m file         # 生成 ./migro.sql
fboot dbmigro --dylibPattern='...' -m interactive  # 交互确认后执行
```

## 17. 异常体系

全部异常定义在 `fountain::f_orm.exception` 包（随 `fountain::f_orm` 自动重导出）。

### 17.1 继承关系

```
BaseException (fountain::f_exception)
├── ORMException (open)
│   ├── ConnectionException (open)          # 连接/连接池
│   ├── DirtyFieldException                 # 脏字段
│   ├── MockDBException                     # mockdb 驱动
│   ├── NoIdException (open)                # 缺少主键
│   ├── TableMetaException                  # 表元数据
│   └── TransactionException (open)
│       ├── NoneTransactionException        # 无事务
│       ├── StartFailureTransactionException# 事务创建失败
│       └── PropagationException (open)     # 传播规则
│           ├── MandatoryTransactionException
│           └── NeverTransactionException
└── SqlArgException                         # 注意：直接继承 BaseException
```

每个异常都提供与 `BaseException` 一致的 4 个构造器：

```cangjie
init()
init(message: String)
init(caused: Exception)
init(message: String, caused: Exception)
```

### 17.2 类型说明与抛出场景

| 异常 | 父类 | 典型抛出场景 |
| --- | --- | --- |
| `ORMException` | `BaseException`（open） | ORM 通用错误。如列值无法转换为目标类型（`column index: n, column type: ..., column name: ..., requires: ...`）、字符串解析失败、调用已废弃 API、`QueryMappersInit` 未实现 `queryMappers` 等 |
| `SqlArgException` | `BaseException` | SQL 参数错误。如 `SqlArg` 遇到不支持的类型、`UPDATE(values)` 无有效列、`BETWEEN`/`IN`/`IS_NULL` 等逻辑表达式传入非法运算符、表数据字段类型与列类型不匹配 |
| `ConnectionException` | `ORMException`（open） | 连接相关错误，如对已关闭的连接池取连接：`database pool is closed` |
| `NoIdException` | `ORMException`（open） | `UPDATE` 时找不到主键列（未用 `@ORMField[true ...]` 标注主键） |
| `TableMetaException` | `ORMException` | `TableMeta.new<T>()` 构建失败，如类上缺少 `@DatabaseSchema` 注解 |
| `DirtyFieldException` | `ORMException` | 脏字段追踪相关错误 |
| `MockDBException` | `ORMException` | mockdb（内存模拟驱动）错误，如将 mock 方言指向自身 |
| `TransactionException` | `ORMException`（open） | 事务通用错误（`DummyTransaction` 在未知模式下 `begin` 时抛出） |
| `PropagationException` | `TransactionException`（open） | 事务传播规则异常的基类 |
| `MandatoryTransactionException` | `PropagationException` | 传播级别为 `Mandatory`（必须有事务）但当前无事务 |
| `NeverTransactionException` | `PropagationException` | 传播级别为 `Never`（禁止事务）但当前处于事务中 |
| `StartFailureTransactionException` | `TransactionException` | 事务创建失败（`DummyTransaction` 的 `StartFailure` 模式） |
| `NoneTransactionException` | `TransactionException` | 无事务场景专用异常（供业务/框架使用） |

> `Mandatory` / `Never` / `StartFailure` 这三类异常由 `wrap/DummyTransaction.cj` 在「无真实事务」的占位事务对象上执行传播规则检查时抛出（见 [14. 事务](#14-事务)）。


## 18. 敏感信息
数据库连接URL、用户名、密码可以在编译期读取相关配置项，使用SM4加密并将加密后的字节数组内嵌到编译产物。
编译期，按照以下配置即可将敏感信息嵌入到编译产物中。
如果没有加密配置项，会将敏感信息的UTF8字节数组嵌入到编译产物。
如果编译环境没有配置敏感信息，就必须在运行环境配置它们，否则访问数据库时将出错。
启动进程时首先从加密配置集合获取敏感信息，如果获取不到，则从运行环境获取敏感信息配置项。

编译环境和运行环境的敏感信息配置项完全一致。

以下需要16进制串的情形可以使用命令：`fboot randhex 32`

### 18.1 加密配置项
```bash
# 这些加密配置项也会作为敏感信息嵌入编译产物
export orm_sm4Operation='CBC' # CBC CFB CTR GCM OFB，默认CBC。ECB被文档标记为不安全，没有给予支持
export orm_sm4Padding='PKCS7Padding' # PKCS7Padding NoPadding，默认是PKCS7Padding
export orm_sm4Key='1234567812345678' # 16字节，没有默认值，以长度为32的16进制字符串表示
export orm_sm4Iv='1234567812345678' # 16字节，默认是key翻转再取反，以长度为32的16进制字符串表示
export orm_sm4Aad='1234567812345678' # 附加认证数据，默认是空字节数组，以长度为32的16进制字符串表示
export orm_sm4TagSize=16 # Int64，默认16
```

### 18.2 敏感信息配置项
```bash
# orm_drivers这个配置项本身不是敏感信息，但是必须同时在编译环境和运行环境配置，且必须一致。
export orm_drivers='postgres,mysql' # 英文逗号分隔的数据库驱动名称，没有默认值。
export orm_connectionUrl='.....' # 数据库连接URL
export <driverName>_orm_connectionUrl='....' # 如果有多个数据源，配置项可以驱动名称开头
export orm_option_username='...' # 数据库用户名
export <driverName>_orm_option_username='...' # 如果有多个数据源，配置项可以驱动名称开头
export orm_option_password='...' # 密码
export <driverName>_orm_option_password='...' # 如果有多个数据源，配置项可以驱动名称开头
```

## 19. 附录

### 19.1 SQL 方言 `SqlDialect`

分页语法、标识符包裹、`lastInsertId` 等数据库差异集中在方言类中，`SqlExecutor` 按 `driverName` 自动选用。

```cangjie
public abstract class SqlDialect {
    public prop dialect: String
    public open func lastInsertId(id: String): String                            // 默认 ''
    public func lastInsertId(dataType: DataType): String
    public func lastInsertId<ID, O>(id: IdQueryMapper<ID, O>): String where ID <: Hashable & Equatable<ID>
    public open func limit(size: Int64, offset: Int64): (Int64, Int64, String)  // 默认 (size, offset, ' limit ? offset ?')
    public open prop startInvolver: String                                       // 默认 '"'
    public open prop endInvolver: String                                         // 默认 '"'
    public func involvedIdentifier(identifier: String): String                   // 包裹标识符；a.b 形式按段分别包裹
}
```

`limit(size, offset)` 返回三元组 `(参数1, 参数2, SQL 片段)`——各数据库的参数顺序不同（MySQL 是 size、offset；Oracle 是 offset、size），调用方按返回顺序 `add` 参数即可。

内置实现（均按 `orm_drivers` 条件装配，由 `lookupList<SqlDialect>()` 发现）：

| 方言类 | `dialect` | 特点 |
| --- | --- | --- |
| `MySqlDialect`（open） | `mysql` | 标识符用 `` ` `` 包裹 |
| `MariaDBDialect` | `mariadb` | 继承 `MySqlDialect` |
| `SqliteDialect` | `sqlite` | 默认行为 |
| `PostgresDialect`（open） | `postgres` | `lastInsertId` 生成 ` returning <id>` |
| `OpenGaussDialect` | `opengauss` | 继承 `PostgresDialect` |
| `OracleDialect` | `oracle` | `limit` → ` OFFSET ? ROWS FETCH NEXT ? ROWS ONLY` |
| `DB2Dialect` | `db2` | `limit` → ` OFFSET ? ROWS FETCH FIRST ? ROWS ONLY` |
| `MockdbDialect` | `mockdb` | 代理方言：`mock` 属性指定被代理的方言（默认 `opengauss`）；设置为自身时抛 `MockDBException` |

### 19.2 `wrap` 层进阶类型

| 类型 | 说明 | 关键成员 |
| --- | --- | --- |
| `ORMConfig` | 配置读取入口——第 3 节所有环境变量的解析实现。 | `getDrivers()`、`getDriverNames()`、`getDefaultDriver()`（`orm_defaultDriver` ?? `orm_drivers` 首个 ?? `''`）、`isDefaultDriver(driver: String / Driver)`、`getUrl(driverName)`、`getConf(driverName, key)`、连接池各参数 getter（`getPoolMaxSize`、`getPoolCheckSql` 等）、`registerConverter` / `getConverter`（见 [13. 结果映射](#13-结果映射)）、`transactionable(funcName)`、`getTransactionPropagation()`、`mockdb` |
| `NamedDatasource` | 具名数据源：将 `Datasource` 与驱动名绑定，供 `ORM.register` 使用。 | `init(driver)` / `init(driver, url)` / `init(driver, options)`、`driverName`、`connect()` |
| `DatasourceCreator` | 数据源工厂接口：`ORM.register(creator)` 在注册时调用它创建 `NamedDatasource`。 | `create(): NamedDatasource`、`driverName: String`（供 `default` 默认值判定） |
| `DatabasePool` | 内置连接池（`<: Resource & Datasource`），由 `orm_databasePool*` 系列环境变量驱动。 | `init(driver: Driver, creator: () -> Connection)`（参数取自 `ORMConfig`）、完整参数版 `init`（`maxSize`、`checkOnBorrowing`、`connectionLife`、`connectTimeout` 等）、`getConnection(timeout!)`、`isClosed()`、`close()` |
| `SqlArg`（抽象） | 单个绑定参数（`index` + `set(statement)`）。 | 工厂 `SqlArg.new<T>(index, value)`；每种支持类型对应一个实现子类；`hashCode` / `==` / `toString` |
| `SqlArgs` | 参数集合：占位符索引自增。 | `add(...)` 全类型重载、`addNull()`、`toString()` |
| `QueryResultWrap` | `std.database.sql.QueryResult` 的包装：按列读取并安全转型，是结果映射的底层。 | `get<T>(...)` / `getOrNull<T>(...)`、`next()`、`toMap()`、`close()` 等 |
| `StatementWrap` | `Statement` 包装：统一 `?` 占位符参数绑定与执行。 | `update()` / `query()`、`getConnection()`；参数版 `update(params)` / `query(params)` 已废弃 |
| `TransactionWrap` | 事务包装：事务内绑定独立连接，支持挂起与保存点。 | `connection`、`suspend`、`wrapping`、`isDummy`、`begin()`、`commit()`、`rollback()`、`save(name)`、`rollback(savePointName)`、`release(name)`、`setIsoLevel(level)`、`setAccessMode(mode)`、`setDeferrableMode(mode)` |
| `Propagation` | 事务传播级别枚举（`@Transactional` 传播参数）。 | `Required`、`Supports`、`Mandatory`、`RequiresNew`、`NotSupported`、`Never`、`Nested` |
| `DataType`（抽象） | 列类型描述（`nullable` / `columnName` / `fieldName`），与 `QueryMapper` 一一对应：定类型读取结果列，也决定 insert/update 时的参数绑定重载。 | `get(result): Any`；子类：`BoolDataType`、`Int8DataType`、`UInt8DataType`、`Int16DataType`、`UInt16DataType`、`Int32DataType`、`UInt32DataType`、`Int64DataType`、`UInt64DataType`、`Float16DataType`、`Float32DataType`、`Float64DataType`、`DecimalDataType`、`BigIntDataType`、`RuneDataType`、`StringDataType`、`ByteArrayDataType`、`DateTimeDataType`、`DurationDataType`、`InputStreamDataType`、`UnknownDataType` |

### 19.3 SQL 参数支持的类型

`arg(...)`（`SqlArg.new<T>`）与 `add(...)` 支持以下类型；其余类型抛 `SqlArgException`：

`Bool`、`Int8`、`UInt8`、`Int16`、`UInt16`、`Int32`、`UInt32`、`Int64`、`UInt64`、`Float16`、`Float32`、`Float64`、`Decimal`、`BigInt`、`Rune`、`String`、`Duration`、`DateTime`、`Array<Byte>`、`InputStream`，以及 `None`（`addNull()`）。

### 19.4 其他实用类型

| 类型 | 说明 |
| --- | --- |
| `ExtendString`（`String` 扩展） | 在 SQL 片段拼接上下文中向当前执行器的 partials 追加内容：字符串的 `AND` / `OR` / `NOT` 属性追加对应关键字；`'prefix'('and x = #{x}')` 形式的 `operator ()` 调用直接追加片段 |
| `DirtyTag` | 脏字段追踪（`dirty: true` 的 `UPDATE` 依赖它）：`setDirtyField<T>(field: String)` 由 `@ORMField` 生成的 setter 调用；其余（`setBeforeDirty` / `getDirtyFields` / `clear`）为 `protected`，供框架内部使用 |
| `ORMInitializer` | `f_app` 集成：注册 `initializer`（名称 `fountain::f_orm`，依赖 `fountain::f_bean`），应用启动时自动执行 `ORM.initialize()` |
| `ORMColumn` | 成员上的列名/主键注解（`name!: String = ''`、`id!: Bool = false`），与 `@ORMField` 提供等价的声明能力（见 [15. 宏](#15-宏)） |

### 19.5 相关文档

* `f_orm/README.md`：模块历史介绍（部分内容已滞后于当前 API）。
* `f_orm/src/**/*.cj`：源码即最权威的参考；本文档未覆盖的行为以源码为准。
* 示例工程 `fdemo`：`fdemo/boot.sh`（配置）、`fdemo/user/src/dao/*DAO.cj`（DAO 定义）、`fdemo/user/src/service/impl/UserServiceImpl.cj`（事务服务）。
