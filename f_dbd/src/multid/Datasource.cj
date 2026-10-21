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
package fountain::f_dbd.multid

import std.collection.ArrayList
import std.database.sql.{Connection, Datasource}
import std.sync.AtomicBool
import fountain::f_concurrent.{Int64Weight, LoadBalance, LoadBalanceAlgo, RoundRobin}
import fountain::f_dbpool.{ConnectionException, DatabasePool}
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.driver.{DbdDatasource, DbdUrl}
import fountain::f_dbd.exception.DbdException

/**
 * 多节点数据源（设计 §6.4）：每个 `fdbm` 节点一个 `DatabasePool`，
 * 连接借用由 `LoadBalance` 按权重选择（轮询 / 随机）。
 *
 * `preferredPooling = false`：本类内部已经是连接池，上层不需要再套一层。
 */
public class MultiDatasource <: Datasource {
    private let nodes: Array<DbdUrl>
    private let datasources: Array<DbdDatasource>
    private let pools: Array<DatabasePool>
    private let loadbalance: LoadBalance<Int64, Unit, Connection>
    private let closed = AtomicBool(false)

    /**
     * @param url `multidbm://...` / `multidbd://...`
     * @param opts 统一覆盖各节点凭据与超时（在池创建前写入每个节点）
     */
    public init(url: String, opts!: Array<(String, String)> = []) {
        let parsed = MultiDUrl.parse(url)
        this.nodes = parsed.nodes
        let builtDatasources = ArrayList<DbdDatasource>()
        for (node in nodes) {
            let datasource = DbdDatasource(node, opts: opts)
            builtDatasources.add(datasource)
        }
        this.datasources = builtDatasources.toArray()

        // 先校验权重与算法：配置写错时不该先把池（及其后台线程）建出来再抛异常。
        let weights = effectiveWeights(nodes, url)
        var total: Int64 = 0
        for (weight in weights) {
            total += weight
        }
        let algorithm = algorithmOf(MultiDConfig.getLoadBalance(), total)

        let initSize = MultiDConfig.getInitSize()
        let minSize = MultiDConfig.getMinSize()
        let maxSize = MultiDConfig.getMaxSize()
        let checkOnCreation = MultiDConfig.getCheckOnCreation()
        let checkOnBorrowing = MultiDConfig.getCheckOnBorrowing()
        let checkOnReturning = MultiDConfig.getCheckOnReturning()
        let connectionLife = MultiDConfig.getConnectionLife()
        let idleTimeout = MultiDConfig.getIdleTimeout()
        let checkInterval = MultiDConfig.getCheckInterval()
        let connectTimeout = MultiDConfig.getConnectTimeout()
        let maxWaiting = MultiDConfig.getMaxWaiting()
        let checkSql = MultiDConfig.getCheckSql()
        let builtPools = ArrayList<DatabasePool>()
        for (datasource in datasources) {
            builtPools.add(DatabasePool(datasource,
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
                checkSql: checkSql))
        }
        this.pools = builtPools.toArray()

        let balance = LoadBalance<Int64, Unit, Connection>(0, algorithm)
        // 权重为 0 的节点不注册：累计权重会与前一节点相同，TreeMap 会把前一个覆盖掉。
        for (i in 0..weights.size) {
            if (weights[i] > 0) {
                let pool = pools[i]
                balance.add(weights[i]) {_ => pool.connect()}
            }
        }
        this.loadbalance = balance
    }

    /**
     * 借一条连接（由 `LoadBalance` 选节点）。
     *
     * - 本数据源已关闭 / 池已关闭 → `CONFIG`；
     * - 池耗尽等待超时（`ConnectionException` 的其它情形）→ `TIMEOUT`。
     */
    public func connect(): Connection {
        if (closed.load()) {
            throw DbdException(DbdErrorCode.CONFIG, 'the multid datasource is closed')
        }
        try {
            loadbalance.call(())
        } catch (e: ConnectionException) {
            // 只依据状态判定（G06）：消息文本可被本地化/改写，不得作为契约
            if (closed.load() || anyPoolClosed()) {
                throw DbdException(DbdErrorCode.CONFIG, 'a node pool is closed: ${e.message}', cause: e)
            }
            throw DbdException(DbdErrorCode.TIMEOUT, 'cannot borrow a connection from the node pool: ${e.message}',
                cause: e)
        }
    }

    /** 任一节点池已关闭（`MultiDatasource` 关闭后池也会被关闭）。 */
    private func anyPoolClosed(): Bool {
        for (pool in pools) {
            if (pool.isClosed()) {
                return true
            }
        }
        false
    }

    /** 转发到每个节点；对已建立的连接不生效（各自持有选项副本）。 */
    public func setOption(key: String, value: String): Unit {
        for (datasource in datasources) {
            datasource.setOption(key, value)
        }
    }

    /**
     * 幂等关闭全部节点池。
     *
     * **不等待**池内部任务（借用中的连接由应用持有）；需要确定性收尾时应用应先把连接全部归还，
     * 再对池调用 `closeAndAwait`。这里刻意不用 `closeAndAwait`，否则只会白等到超时。
     */
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

    public func isClosed(): Bool {
        closed.load()
    }

    /** 权重列表：未配置 → 等权；个数与节点数不符 / 全为 0 → `CONFIG`。 */
    private static func effectiveWeights(nodes: Array<DbdUrl>, url: String): Array<Int64> {
        let configured = MultiDConfig.getWeights()
        let weights = if (configured.isEmpty()) {
            Array<Int64>(nodes.size, repeat: 1)
        } else {
            configured
        }
        if (weights.size != nodes.size) {
            throw DbdException(DbdErrorCode.CONFIG,
                'illegal multid url \'${url}\': ${weights.size} weights for ${nodes.size} nodes')
        }
        var positive = false
        for (weight in weights) {
            if (weight < 0) {
                throw DbdException(DbdErrorCode.CONFIG,
                    'illegal multid url \'${url}\': negative weight ${weight}')
            }
            if (weight > 0) {
                positive = true
            }
        }
        if (!positive) {
            throw DbdException(DbdErrorCode.CONFIG,
                'illegal multid url \'${url}\': all node weights are zero')
        }
        weights
    }

    /** 算法名 → `LoadBalanceAlgo`；未知算法 → `CONFIG`。 */
    private static func algorithmOf(name: String, total: Int64): LoadBalanceAlgo<Int64> {
        if (name == 'roundrobin') {
            // min = 1：累计权重桶从 1 开始，`forward(1, inclusive)` 才能落在第一个桶内。
            return RoundRobin<Int64>(1, 1, total)
        }
        if (name == 'random') {
            return Int64Weight(1, total)
        }
        throw DbdException(DbdErrorCode.CONFIG,
            'illegal multidbm_loadbalance \'${name}\': expect random or roundrobin')
    }
}
