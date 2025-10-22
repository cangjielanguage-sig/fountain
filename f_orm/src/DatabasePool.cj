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
package f_orm

public import std.database.sql.*
import std.collection.Map
import std.sync.AtomicUInt64
import std.unicode.UnicodeStringExtension
import f_log.LoggerFactory
import f_pool.Pool

public class DatabasePool <: Resource & Datasource {
    private static let logger = LoggerFactory.getLogger<DatabasePool>()

    private let driver: Driver
    private let pool: Pool<PooledConnection>

    public init(
        driver!: Driver,
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        connectionLife!: Duration = Duration.hour,
        checkInterval!: Duration = Duration.minute * 5,
        creator!: () -> Connection,
        checker!: (Connection) -> Bool
    ) {
        this.driver = driver
        this.pool = Pool<PooledConnection>(
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            elementLife: connectionLife,
            checkInterval: checkInterval,
            creator: {=> PooledConnection(creator())},
            checker: {
                c => try {
                    return !c.isDestroied() && checker(c)
                } catch (e: Exception) {
                    logger.error("database check failed", e)
                    false
                }
            },
            destroier: {c => c.destroy()}
        )
    }
    public init(
        driver!: Driver,
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        connectionLife!: Duration = Duration.hour,
        checkInterval!: Duration = Duration.minute * 5,
        creator!: () -> Connection,
        checkSql!: String = "select 1"
    ) {
        this(
            driver: driver,
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            connectionLife: connectionLife,
            checkInterval: checkInterval,
            creator: creator,
            checker: {
                c => if (checkSql[0..6].toLower().startsWith("select")) {
                    c.prepareStatement(checkSql).query().next()
                } else {
                    c.prepareStatement(checkSql).update().rowCount > 0
                }
            }
        )
    }
    public static func byConfig(driver: Driver, creator: () -> Connection) {
        DatabasePool(
            driver: driver,
            initSize: ORMConfig.getPoolInitSize(driverName: driver.name),
            minSize: ORMConfig.getPoolMinSize(driverName: driver.name),
            maxSize: ORMConfig.getPoolMaxSize(driverName: driver.name),
            checkOnCreation: ORMConfig.getCheckOnCreation(driverName: driver.name),
            checkOnBorrowing: ORMConfig.getCheckOnBorrowing(driverName: driver.name),
            checkOnReturning: ORMConfig.getCheckOnReturning(driverName: driver.name),
            connectionLife: ORMConfig.getConnectionLife(driverName: driver.name),
            checkInterval: ORMConfig.getPoolCheckInterval(driverName: driver.name),
            creator: creator,
            checkSql: ORMConfig.getPoolCheckSql(driverName: driver.name)
        )
    }

    public func isClosed(): Bool {
        let poolClosed = pool.isClosed()
        if (!poolClosed) {
            pool.close()
        }
        poolClosed
    }
    public func close(): Unit {
        if (!isClosed()) {
            pool.close()
        }
    }

    public func getConnection(timeout!: Duration = Duration.Max): Option<Connection> {
        if (isClosed()) {
            return None<Connection>
        }
        pool.borrow(timeout: timeout)?.activate(pool.giveBack)
    }
    public func setOption(key: String, value: String): Unit {}
    public func connect(): Connection {
        getConnection() ?? NoneConnection.instance
    }
}

class PooledConnection <: Connection {
    private static let logger = LoggerFactory.getLogger<PooledConnection>()
    private static let serialGen = AtomicUInt64(1)
    private let serial = serialGen.fetchAdd(1)
    PooledConnection(private let connection: Connection) {}

    private var returnFn = {c: PooledConnection => ()}

    private var assigned = false

    public func isClosed(): Bool {
        !assigned
    }
    public func close(): Unit {
        assigned = false
        if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} is returning")
        }
        returnFn(this)
        if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} is returned")
        }
    }
    func activate(returnFn: (PooledConnection) -> Unit): Connection {
        assigned = true
        this.returnFn = returnFn
        if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} is assigned")
        }
        this
    }
    func isDestroied(): Bool {
        connection.isClosed()
    }
    func destroy(): Unit {
        if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} is closing")
        }
        if (!(assigned || connection.isClosed())) {
            connection.close()
            if (logger.debugEnabled) {
                logger.debug("database Connection ${serial} is closed")
            }
        } else if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} cannot close")
        }
    }

    /**
     * 通过传入的 sql 语句，返回一个预执行的 Statement 对象实例
     * 参数 sql - 预执行的 sql 语句
     * 返回值 Statement - 一个可以执行 sql 语句的实例对象
     */
    public func prepareStatement(sql: String): Statement {
        if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} is preparing a statement")
        }
        let stmt = connection.prepareStatement(sql)
        if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} a statement is prepared")
        }
        stmt
    }

    /**
       接口 Statement ，sql 语句预执行接口，它绑定了一个 Connection , 继承该接口的 class、interface、
       struct 也需要遵守该接口中函数的入参及返回值定义。
     * 开始事务
     */
    public func createTransaction(): Transaction {
        if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} a transaction is beginning")
        }
        let tx = connection.createTransaction()
        if (logger.debugEnabled) {
            logger.debug("database Connection ${serial} a transaction began")
        }
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
