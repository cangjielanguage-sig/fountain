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
package fountain::fdbm.config

import std.collection.HashMap

/**
 * 启动配置的聚合根（设计 §3）。
 *
 * `load()` 只解析、不校验跨项约束：跨项校验要等 `CustomLoader` 收集完自定义算法/ID 生成器之后，
 * 由 [FdbmConfig.validate] 执行（见 §10.1 的启动顺序）。
 */
protected class FdbmSettings {
    public let port: UInt16
    public let nodes: Array<DatabaseNodeConfig>
    public let pool: PoolConfig
    public let loadBalance: LoadBalanceConfig
    public let partitions: Array<PartitionRuleConfig>
    public let partitionStep: Int64
    public let globalTables: Array<GlobalTableConfig>
    public let logicalDatabases: HashMap<String, Array<String>>
    public let defaultDatabase: String
    public let idmaker: IdMakerConfig
    public let cache: CacheConfig
    public let driverDir: String
    public let customDir: String
    public let bootScript: String
    public let sessionSweepInterval: Duration
    public let shutdownTimeout: Duration
    public let checkDuration: Duration
    public let unavailableChecked: Int64
    public let sequenceDatabase: String

    private init(port: UInt16, nodes: Array<DatabaseNodeConfig>, pool: PoolConfig,
        loadBalance: LoadBalanceConfig, partitions: Array<PartitionRuleConfig>, partitionStep: Int64,
        globalTables: Array<GlobalTableConfig>, logicalDatabases: HashMap<String, Array<String>>,
        defaultDatabase: String, idmaker: IdMakerConfig, cache: CacheConfig,
        driverDir: String, customDir: String, bootScript: String, sessionSweepInterval: Duration,
        shutdownTimeout: Duration, checkDuration: Duration, unavailableChecked: Int64,
        sequenceDatabase: String) {
        this.port = port
        this.nodes = nodes
        this.pool = pool
        this.loadBalance = loadBalance
        this.partitions = partitions
        this.partitionStep = partitionStep
        this.globalTables = globalTables
        this.logicalDatabases = logicalDatabases
        this.defaultDatabase = defaultDatabase
        this.idmaker = idmaker
        this.cache = cache
        this.driverDir = driverDir
        this.customDir = customDir
        this.bootScript = bootScript
        this.sessionSweepInterval = sessionSweepInterval
        this.shutdownTimeout = shutdownTimeout
        this.checkDuration = checkDuration
        this.unavailableChecked = unavailableChecked
        this.sequenceDatabase = sequenceDatabase
    }

    /** 读取并解析全部配置；任何单项非法都抛 `FdbmException(CONFIG)`（含配置项名与原始值）。 */
    public static func load(source!: ConfigSource = EnvConfigSource()): FdbmSettings {
        let nodes = FdbmConfig.getNodes(source: source)
        let logicals = FdbmConfig.getLogicalDatabases(nodes, source: source)
        FdbmSettings(
            FdbmConfig.getPort(source: source),
            nodes,
            FdbmConfig.getPool(source: source),
            FdbmConfig.getLoadBalance(source: source),
            FdbmConfig.getPartitions(source: source),
            FdbmConfig.getPartitionStep(source: source),
            FdbmConfig.getGlobalTables(source: source),
            logicals,
            defaultDatabaseOf(nodes, logicals),
            FdbmConfig.getIdMaker(source: source),
            FdbmConfig.getCache(source: source),
            FdbmConfig.getDriverDir(source: source),
            FdbmConfig.getCustomDir(source: source),
            FdbmConfig.getBootScript(source: source),
            FdbmConfig.getSessionSweepInterval(source: source),
            FdbmConfig.getShutdownTimeout(source: source),
            FdbmConfig.getCheckDuration(source: source),
            FdbmConfig.getUnavailableChecked(source: source),
            FdbmConfig.getSequenceDatabase(source: source, nodes: Some(nodes))
        )
    }

    /**
     * 会话的默认逻辑库。
     *
     * 协议目前没有"连接时声明 database"的报文（f_dbd 只把 database 放在 URL 里做元信息），
     * 因此在只有一个逻辑库时取它；多逻辑库时取第一个节点的第一个物理库。
     * 该偏差登记在 `详细设计.md` §9.1。
     */
    private static func defaultDatabaseOf(nodes: Array<DatabaseNodeConfig>,
        logicals: HashMap<String, Array<String>>): String {
        if (logicals.size == 1) {
            for ((name, _) in logicals) {
                return name
            }
        }
        nodes[0].databases[0]
    }
}
