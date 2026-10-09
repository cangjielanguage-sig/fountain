/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::f_dbpool

public import std.database.sql.*
import std.collection.Map
import std.sync.{AtomicBool, AtomicUInt64}
import std.time.MonoTime
import std.unicode.UnicodeStringExtension
import fountain::f_log.impl.LoggerFactory
import fountain::f_pool.Pool

/**
 * 数据库连接池：用 `fountain::f_pool.Pool` 池化 `Datasource` 的连接，实现 `Datasource` / `Resource`。
 *
 * 本类从 `fountain::f_orm.wrap` 迁移到 `fountain::f_dbpool`（f_orm 只重导出），因此不再读
 * `ORMConfig` 的 `orm_*` 配置项：池参数一律由调用方显式给出（原 `init(driver: Driver, ds: Datasource)`
 * 已删除，改用 `init(ds, ...)` 构造；原 `init(driver, options!)` 改为显式传 `url`）。
 */
public class DatabasePool <: Resource & Datasource {
    private static let logger = LoggerFactory.getLogger<DatabasePool>()

    private let ds: Datasource
    private let pool: Pool<PooledConnection>
    private var connectTimeout: Duration

    public init(
        ds: Datasource,
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        connectionLife!: Duration = Duration.hour,
        idleTimeout!: Duration = Duration.Zero,
        checkInterval!: Duration = Duration.minute * 5,
        connectTimeout!: Duration = Duration.Max,
        /** 池耗尽且 `get(timeout: Duration.Max)` 时的等待上限（池初始化参数）；`Duration.Max` = 真无限等待。 */
        maxWaiting!: Duration = Duration.second * 30,
        checker!: (Connection) -> Bool
    ) {
        this.ds = ds
        this.connectTimeout = connectTimeout
        this.pool = Pool<PooledConnection>(
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            idleTimeout: idleTimeout,
            checkInterval: checkInterval,
            maxWaiting: maxWaiting,
            creator:  {=> PooledConnection(ds.connect())},
            checker: {
                c => try {
                    if(connectionLife > Duration.Zero && let conn: PooledConnection <- c && MonoTime.now() - conn.birth >= connectionLife) {
                        false
                    } else {
                        !c.isDestroied() && checker(c)
                    }
                } catch (e: Exception) {
                    logger.error("database check failed", e)
                    false
                }
            },
            destroier: {
                c => try {
                    if (!c.isDestroied()) {
                        c.destroy()
                    }
                } catch (e: Exception) {
                    logger.warn('to destroy connection in DatabasePool failed', e)
                }
            }
        )
    }
    public init(
        ds: Datasource,
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        connectionLife!: Duration = Duration.hour,
        idleTimeout!: Duration = Duration.Zero,
        checkInterval!: Duration = Duration.minute * 5,
        connectTimeout!: Duration = Duration.Max,
        maxWaiting!: Duration = Duration.second * 30,
        checkSql!: String = "select 1"
    ) {
        this(ds,
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            connectionLife: connectionLife,
            idleTimeout: idleTimeout,
            checkInterval: checkInterval,
            connectTimeout: connectTimeout,
            maxWaiting: maxWaiting,
            checker: {
                c => if (checkSql.size < 6) {
                    // bug-orm.md §3.1 ORM-C4：短于 6 个字符的 checkSql 不可能是合法语句——原实现直接做
                    // `checkSql[0..6]`，会在借连接校验时抛 IndexOutOfBoundsException；改为显式抛 ConnectionException
                    // （f_dbpool 不引入 ORMException，本模块的异常只有 ConnectionException 一种）。
                    throw ConnectionException('checkSql is too short to be a valid statement: [${checkSql}]')
                } else if (checkSql[0..6].toLower() == "select") {
                    try (stmt = c.prepareStatement(checkSql)) {
                        try (r = stmt.query()) {
                            return r.next()
                        }
                    }
                    false
                } else {
                    try (stmt = c.prepareStatement(checkSql)) {
                        return stmt.update().rowCount > 0
                    }
                    false
                }
            }
        )
    }
    /**
     * 用驱动 + 连接串建池：`driver.open(url, options)` 得到 `Datasource` 后交给 `init(ds, ...)`。
     *
     * 迁移到 f_dbpool 前这里的 `url` 取自 f_orm 的 `ORMConfig.getUrl`；f_dbpool 不依赖 f_orm，
     * 改为调用方显式传入连接串。
     */
    public init(
        driver: Driver,
        url: String,
        options!: Array<(String, String)> = [],
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        connectionLife!: Duration = Duration.hour,
        idleTimeout!: Duration = Duration.Zero,
        checkInterval!: Duration = Duration.minute * 5,
        connectTimeout!: Duration = Duration.Max,
        maxWaiting!: Duration = Duration.second * 30,
        checkSql!: String = "select 1"
    ) {
        this(open(driver, url, options), 
             initSize: initSize,
             minSize: minSize,
             maxSize: maxSize,
             checkOnCreation: checkOnCreation,
             checkOnBorrowing: checkOnBorrowing,
             checkOnReturning: checkOnReturning,
             connectionLife: connectionLife,
             idleTimeout: idleTimeout,
             checkInterval: checkInterval,
             connectTimeout: connectTimeout,
             maxWaiting: maxWaiting,
             checkSql: checkSql)
    }
    private static func open(driver: Driver, url: String, options: Array<(String, String)>){
        return driver.open(url, options)
    }
    public func isClosed(): Bool {
        pool.isClosed()
    }
    public func close(): Unit {
        if (!isClosed()) {
            this.ds.close()
            pool.close()
        }
    }

    public func getConnection(timeout!: Duration = connectTimeout): Option<Connection> {
        if (isClosed()) {
            throw ConnectionException('database pool is closed')
        }
        pool.get(timeout: timeout)?.activate(pool.giveBack)
    }
    public func setOption(key: String, value: String): Unit {
        this.ds.setOption(key, value)
    }
    public func connect(): Connection {
        getConnection().getOrThrow{ConnectionException()}
    }
}

class PooledConnection <: Connection {
    private static let logger = LoggerFactory.getLogger<PooledConnection>()
    private static let serialGen = AtomicUInt64(1)
    private let serial = serialGen.fetchAdd(1)
    let birth = MonoTime.now()
    PooledConnection(private let connection: Connection) {}

    private var returnFn = {c: PooledConnection => ()}

    private var assigned = false
    // bug-orm.md §3.2 ORM-L8：`true` = 未借出/已归还。借出时在 `activate` 里 store(false)，`close()` 用 CAS 幂等。
    // 池侧没有身份去重（`SyncDeque` 只对「重复归还」告警、不拦），所以重复归还要在这一步就挡住：
    // 否则池里会出现两个指向同一连接的节点，两个借用者可能同时拿到同一条连接。
    private let returned = AtomicBool(true)

    public func isClosed(): Bool {
        !assigned
    }
    public func close(): Unit {
        // bug-orm.md §3.2 ORM-L8：CAS 失败 = 这条连接已经被归还过（或从未借出）
        if (!returned.compareAndSwap(false, true)) {
            throw ConnectionException('The database connection was returned multiple times.')
        }
        assigned = false
        logger.debug {"database Connection ${serial} is returning"}
        returnFn(this)
        logger.debug {"database Connection ${serial} is returned"}
    }
    func activate(returnFn: (PooledConnection) -> Unit): Connection {
        // 借出即复位「已归还」标记（close 的 CAS 依赖它）；放在 activate 里而不是调用方，
        // 是为了让"借出"只有一个入口，也不用到 DatabasePool 去碰这里的 private 成员
        returned.store(false)
        assigned = true
        this.returnFn = returnFn
        logger.debug {"database Connection ${serial} is assigned"}
        this
    }
    func isDestroied(): Bool {
        connection.isClosed()
    }
    func destroy(): Unit {
        logger.debug {"database Connection ${serial} is closing"}
        if (!(assigned || connection.isClosed())) {
            connection.close()
            logger.debug {"database Connection ${serial} is closed"}
        } else {
            logger.debug {"database Connection ${serial} cannot close"}
        }
    }

    /**
     * 通过传入的 sql 语句，返回一个预执行的 Statement 对象实例
     * 参数 sql - 预执行的 sql 语句
     * 返回值 Statement - 一个可以执行 sql 语句的实例对象
     */
    public func prepareStatement(sql: String): Statement {
        logger.debug {"database Connection ${serial} is preparing a statement"}
        let stmt = connection.prepareStatement(sql)
        logger.debug {"database Connection ${serial} a statement is prepared"}
        stmt
    }

    /**
     * 接口 Statement ，sql 语句预执行接口，它绑定了一个 Connection , 继承该接口的 class、interface、
     * struct 也需要遵守该接口中函数的入参及返回值定义。
     * 开始事务
     */
    public func createTransaction(): Transaction {
        logger.debug {"database Connection ${serial} a transaction is beginning"}
        let tx = connection.createTransaction()
        logger.debug {"database Connection ${serial} a transaction began"}
        tx
    }
    public prop state: ConnectionState {
        get() {
            connection.state
        }
    }
    public func getMetaData(): Map<String, String> {
        connection.getMetaData()
    }
}
