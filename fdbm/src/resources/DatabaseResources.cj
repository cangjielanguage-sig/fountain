/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::fdbm.resources

import std.collection.{ArrayList, HashMap}
import std.database.sql.{Connection, DriverManager}
import std.sync.AtomicBool
import fountain::f_concurrent.{Int64Weight, LoadBalance, LoadBalanceAlgo, RoundRobin}
import fountain::f_dbpool.DatabasePool
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.config.{DatabaseNodeConfig, LoadBalanceConfig, PoolConfig}
import fountain::fdbm.exception.FdbmException

/** 资源访问抽象（设计 §5）：执行器只依赖它，用例注入 `FakeNodeAccessor`。 */
protected interface NodeAccessor {
    func selectRead(database: String): Connection
    func selectWrite(database: String): Connection
    func selectAllWrite(database: String): Array<Connection>
    func databases(): Array<String>
    func contains(database: String): Bool
    func readNodes(database: String): Array<String>
    /** 承载该物理库的驱动名（`show tables` 的方言分支用，设计 §9.5）。 */
    func driver(database: String): String
}

/**
 * 物理库资源（设计 §5）：每个 `<host:port> + <物理库>` 一个池，按物理库名聚合读/写负载均衡。
 *
 * 同名物理库出现在多个节点 → 同一 `LoadBalance`（读写分离 + 负载均衡）；
 * 权重为 0 的节点不注册（累计权重会覆盖前一个桶）。
 */
protected class DatabaseResources <: NodeAccessor & Resource {
    private let readNodes_: HashMap<String, LoadBalance<Int64, Unit, Connection>>
    private let writeNodes_: HashMap<String, LoadBalance<Int64, Unit, Connection>>
    private let writePools: HashMap<String, Array<DatabasePool>>
    private let readPoolNames: HashMap<String, Array<String>>
    private let pools: Array<DatabasePool>
    private let names: Array<String>
    private let driverNames: HashMap<String, String>
    private let closed = AtomicBool(false)

    public init(nodes: Array<DatabaseNodeConfig>, poolConfig: PoolConfig,
        weights: LoadBalanceConfig) {
        let builtPools = ArrayList<DatabasePool>()
        let names = ArrayList<String>()
        let driverNames = HashMap<String, String>()
        let byDatabase = HashMap<String, ArrayList<(String, DatabasePool, Int64, Int64)>>()
        for (node in nodes) {
            for (database in node.databases) {
                let driver = match (DriverManager.getDriver(node.driverName)) {
                    case Some(found) => found
                    case None => throw FdbmException(DbdErrorCode.NO_DRIVER,
                        'driver \'${node.driverName}\' of node \'${node.name}\' is not registered')
                }
                let datasource = driver.open(node.url(database), [])
                let pool = DatabasePool(datasource,
                    initSize: poolConfig.initSize,
                    minSize: poolConfig.minSize,
                    maxSize: poolConfig.maxSize,
                    checkOnCreation: poolConfig.checkOnCreation,
                    checkOnBorrowing: poolConfig.checkOnBorrowing,
                    checkOnReturning: poolConfig.checkOnReturning,
                    connectionLife: poolConfig.connectionLife,
                    idleTimeout: poolConfig.idleTimeout,
                    checkInterval: poolConfig.checkInterval,
                    connectTimeout: poolConfig.connectTimeout,
                    maxWaiting: poolConfig.maxWaiting,
                    checkSql: poolConfig.checkSql)
                builtPools.add(pool)
                if (!names.contains(database)) {
                    names.add(database)
                }
                driverNames[database] = node.driverName
                let weight = weights.weight(node.name, database)
                let entries = match (byDatabase.get(database)) {
                    case Some(existing) => existing
                    case None =>
                        let created = ArrayList<(String, DatabasePool, Int64, Int64)>()
                        byDatabase[database] = created
                        created
                }
                entries.add((node.name, pool, weight.write, weight.read))
            }
        }
        this.pools = builtPools.toArray()
        this.names = names.toArray()
        this.driverNames = driverNames

        let readNodes = HashMap<String, LoadBalance<Int64, Unit, Connection>>()
        let writeNodes = HashMap<String, LoadBalance<Int64, Unit, Connection>>()
        let writePools = HashMap<String, Array<DatabasePool>>()
        let readPoolNames = HashMap<String, Array<String>>()
        for ((database, entries) in byDatabase) {
            var readTotal: Int64 = 0
            var writeTotal: Int64 = 0
            for ((_, _, write, read) in entries) {
                readTotal += read
                writeTotal += write
            }
            if (readTotal > 0) {
                let balance = LoadBalance<Int64, Unit, Connection>(0,
                    algorithmOf(weights.algorithm, readTotal))
                let poolNames = ArrayList<String>()
                for ((node, pool, ignoredWrite, read) in entries) {
                    if (read > 0) {
                        balance.add(read) {_ => pool.connect()}
                        poolNames.add('${node}/${database}')
                    }
                }
                readNodes[database] = balance
                readPoolNames[database] = poolNames.toArray()
            }
            if (writeTotal > 0) {
                let balance = LoadBalance<Int64, Unit, Connection>(0,
                    algorithmOf(weights.algorithm, writeTotal))
                let writable = ArrayList<DatabasePool>()
                for ((ignoredNode, pool, write, ignoredRead) in entries) {
                    if (write > 0) {
                        balance.add(write) {_ => pool.connect()}
                        writable.add(pool)
                    }
                }
                writeNodes[database] = balance
                writePools[database] = writable.toArray()
            }
        }
        this.readNodes_ = readNodes
        this.writeNodes_ = writeNodes
        this.writePools = writePools
        this.readPoolNames = readPoolNames
    }

    public func selectRead(database: String): Connection {
        ensureOpen()
        match (readNodes_.get(database)) {
            case Some(balance) => balance.call(())
            case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'physical database \'${database}\' has no read node')
        }
    }

    public func selectWrite(database: String): Connection {
        ensureOpen()
        match (writeNodes_.get(database)) {
            case Some(balance) => balance.call(())
            case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'physical database \'${database}\' has no write node')
        }
    }

    public func selectAllWrite(database: String): Array<Connection> {
        ensureOpen()
        let targets = match (writePools.get(database)) {
            case Some(value) => value
            case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'physical database \'${database}\' has no write node')
        }
        let connections = ArrayList<Connection>()
        try {
            for (pool in targets) {
                connections.add(pool.connect())
            }
        } catch (e: Exception) {
            for (connection in connections) {
                try {
                    connection.close()
                } catch (_: Exception) {
                    ()
                }
            }
            throw e
        }
        connections.toArray()
    }

    public func databases(): Array<String> {
        names
    }

    public func contains(database: String): Bool {
        names.contains(database)
    }

    public func readNodes(database: String): Array<String> {
        match (readPoolNames.get(database)) {
            case Some(value) => value
            case None => Array<String>()
        }
    }

    public func driver(database: String): String {
        match (driverNames.get(database)) {
            case Some(value) => value
            case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'unknown physical database \'${database}\'')
        }
    }

    public func close(): Unit {
        if (closed.swap(true)) {
            return
        }
        for (pool in pools) {
            try {
                pool.close()
            } catch (_: Exception) {
                ()
            }
        }
    }

    /** 优雅停止：逐池 `closeAndAwait`（调用方须先归还全部连接）。 */
    public func closeAndAwait(timeout!: Duration): Bool {
        if (closed.swap(true)) {
            return true
        }
        var all = true
        for (pool in pools) {
            try {
                if (!pool.closeAndAwait(timeout: timeout)) {
                    all = false
                }
            } catch (_: Exception) {
                all = false
            }
        }
        all
    }

    public func isClosed(): Bool {
        closed.load()
    }

    private func ensureOpen(): Unit {
        if (closed.load()) {
            throw FdbmException(DbdErrorCode.CONFIG, 'the database resources are closed')
        }
    }

    private static func algorithmOf(name: String, total: Int64): LoadBalanceAlgo<Int64> {
        if (name == 'roundrobin') {
            return RoundRobin<Int64>(1, 1, total)
        }
        Int64Weight(1, total)
    }
}
