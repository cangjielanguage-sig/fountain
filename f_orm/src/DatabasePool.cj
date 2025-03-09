/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

public import std.database.sql.*
import std.sync.{AtomicUInt64, sleep}
import std.time.Duration
import std.unicode.UnicodeExtension
import log.LoggerFactory
import pool.Pool

public class DatabasePool <: Resource & Datasource {
    private static let logger = LoggerFactory.getLogger("fountain/pool.DatabasePool")

    private let driver: Driver
    private let pool: Pool<PooledConnection>

    public init(
        driver!: Driver,
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        checkDuration!: Duration = Duration.second,
        creationRetries!: Int64 = 1,
        creator!: () -> Connection,
        checker!: (Connection) -> Bool
    ) {
        this.driver = driver
        this.pool = Pool<PooledConnection>(
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            checkDuration: checkDuration,
            creationRetries: creationRetries,
            creator: { => PooledConnection(creator())},
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
        checkDuration!: Duration = Duration.second,
        creationRetries!: Int64 = 1,
        creator!: () -> Connection,
        checkSql!: String = "select 1"
    ) {
        this(
            driver: driver,
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            checkDuration: checkDuration,
            creationRetries: creationRetries,
            creator: creator,
            checker: {
                c => if (checkSql[0..6].toLower().startsWith("select")) {
                    let val = SqlInteger(0)
                    c.prepareStatement(checkSql).query([]).next([val])
                } else {
                    c.prepareStatement(checkSql).update([]).rowCount > 0
                }
            }
        )
    }
    public static func byConfig(driver: Driver, creator: () -> Connection) {
        let cfg = ORMConfig.instance
        DatabasePool(
            driver: driver,
            initSize: cfg.getPoolInitSize(driverName: driver.name),
            minSize: cfg.getPoolMinSize(driverName: driver.name),
            maxSize: cfg.getPoolMaxSize(driverName: driver.name),
            checkDuration: cfg.getPoolCheckPeriod(driverName: driver.name),
            creationRetries: cfg.getPoolCreationRetries(driverName: driver.name),
            creator: creator,
            checkSql: cfg.getPoolCheckSql(driverName: driver.name)
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
        pool.getObject(timeout: timeout)?.activate(pool.returnObject)
    }
    public func setOption(key: String, value: String): Unit {}
    public func connect(): Connection {
        getConnection() ?? NoneConnection.instance
    }
}

class PooledConnection <: Connection {
    private static let logger = LoggerFactory.getLogger("fountain/orm.PooledConnection")
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
