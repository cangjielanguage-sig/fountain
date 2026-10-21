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

import std.collection.{ArrayList, HashMap, HashSet}
import std.convert.*
import std.unicode.UnicodeStringExtension
import fountain::f_data.DataParsable
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException
import fountain::f_log.LoggerFactory

/**
 * 配置读取与启动自检（设计 §3.2 / §11）。
 *
 * 所有 `get*` 都直接从 `f_config.Config` 读；**键存在但值非法 → `FdbmException(CONFIG)`**
 * （含配置项名与原始值），键缺失才取默认值。这样启动期就能暴露写错的配置，而不是运行期才炸。
 */
protected struct FdbmConfig {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.config.FdbmConfig')

    static let BUILTIN_ALGORITHMS = ['hash', 'std', 'crc16', 'crc32', 'crc64', 'murmur', 'step', 'substr']
    static let SUBSTR_HASHES = ['std', 'hash', 'crc16', 'crc32', 'crc64', 'murmur']

    // ==================== 服务与进程 ====================

    static func getPort(source!: ConfigSource = EnvConfigSource()): UInt16 {
        match (source.get('fdbm_port')) {
            case Some(raw) =>
                match (UInt16.tryParse(raw.trimAscii())) {
                    case Some(value) =>
                        if (value == 0) {
                            throw configError('fdbm_port', raw, 'port must be in 1..65535')
                        }
                        value
                    case None => throw configError('fdbm_port', raw, 'not a UInt16')
                }
            case None => 8112
        }
    }

    /** `<node>@<host>:<port>;...`；每节点的驱动与物理库必填。 */
    static func getNodes(source!: ConfigSource = EnvConfigSource()): Array<DatabaseNodeConfig> {
        let raw = match (source.get('fdbm_db')) {
            case Some(value) => value
            case None => throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_db is required')
        }
        let nodes = ArrayList<DatabaseNodeConfig>()
        let names = HashSet<String>()
        for (part in raw.split(';')) {
            let item = part.trimAscii()
            if (item.isEmpty()) {
                continue
            }
            let at = match (item.indexOf('@')) {
                case Some(index) => index
                case None => throw FdbmException(DbdErrorCode.CONFIG,
                    'illegal fdbm_db item \'${item}\': expected <node>@<host>:<port>')
            }
            let name = item[0..at].trimAscii()
            let address = item[at + 1..item.size].trimAscii()
            if (name.isEmpty()) {
                throw FdbmException(DbdErrorCode.CONFIG, 'illegal fdbm_db item \'${item}\': node name is empty')
            }
            if (names.contains(name)) {
                throw FdbmException(DbdErrorCode.CONFIG, 'duplicated node name \'${name}\' in fdbm_db')
            }
            names.add(name)
            let (host, port) = parseAddress(address)
            let driverKey = 'fdbm_db_driver_${name}'
            let databaseKey = 'fdbm_db_database_${name}'
            let driver = requireString(source, driverKey)
            let databases = splitNonEmpty(requireString(source, databaseKey), databaseKey)
            let username = source.get('fdbm_db_username_${name}') ?? ''
            let password = source.get('fdbm_db_password_${name}') ?? ''
            nodes.add(DatabaseNodeConfig(name, host, port, driver, databases, username, password))
        }
        if (nodes.isEmpty()) {
            throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_db contains no node')
        }
        nodes.toArray()
    }

    static func getPool(source!: ConfigSource = EnvConfigSource()): PoolConfig {
        PoolConfig(
            initSize: intOf(source, 'fdbm_databasePoolInitSize', 1),
            minSize: intOf(source, 'fdbm_databasePoolMinSize', 1),
            maxSize: intOf(source, 'fdbm_databasePoolMaxSize', 1),
            checkOnCreation: boolOf(source, 'fdbm_databasePoolCheckOnCreation', false),
            checkOnBorrowing: boolOf(source, 'fdbm_databasePoolCheckOnBorrowing', true),
            checkOnReturning: boolOf(source, 'fdbm_databasePoolCheckOnReturning', false),
            idleTimeout: Duration.second * intOf(source, 'fdbm_databasePoolIdleTimeout', 0),
            connectionLife: Duration.second * intOf(source, 'fdbm_databasePoolConnectionLife', 86400),
            checkInterval: Duration.second * intOf(source, 'fdbm_databasePoolCheckInterval', 300),
            connectTimeout: Duration.millisecond * intOf(source, 'fdbm_databasePoolConnectTimeout', 50),
            maxWaiting: maxWaitingOf(source),
            checkSql: stringOf(source, 'fdbm_databasePoolCheckSql', 'select 1')
        )
    }

    /** 算法 + 节点级/库级权重（`fdbm_loadbalance_weight_<node>[__<db>]`）。 */
    static func getLoadBalance(source!: ConfigSource = EnvConfigSource()): LoadBalanceConfig {
        let algorithm = stringOf(source, 'fdbm_loadbalance', 'random').trimAscii().toLower()
        if (algorithm != 'random' && algorithm != 'roundrobin') {
            throw FdbmException(DbdErrorCode.CONFIG,
                'illegal fdbm_loadbalance \'${algorithm}\': expect random or roundrobin')
        }
        let weights = HashMap<String, NodeWeight>()
        for ((key, value) in source.all()) {
            if (!key.startsWith('fdbm_loadbalance_weight_')) {
                continue
            }
            let suffix = key.removePrefix('fdbm_loadbalance_weight_').trimAscii()
            if (suffix.isEmpty() || suffix.endsWith('_')) {
                throw configError(key, value, 'node name is missing before the weight spec')
            }
            if (weights.get(suffix).isSome()) {
                throw FdbmException(DbdErrorCode.CONFIG, 'duplicated weight config \'${key}\'')
            }
            weights[suffix] = parseWeight(key, value)
        }
        LoadBalanceConfig(algorithm: algorithm, weights: weights)
    }

    // ==================== 分库与全局表 ====================

    static func getPartitionStep(source!: ConfigSource = EnvConfigSource()): Int64 {
        let step = intOf(source, 'fdbm_partition_step', 10_000_000)
        if (step <= 0) {
            throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_partition_step must be positive')
        }
        step
    }

    /** 逻辑库 → 物理库（未配置的逻辑库包含全部物理库）。 */
    static func getLogicalDatabases(nodes: Array<DatabaseNodeConfig>,
        source!: ConfigSource = EnvConfigSource()): HashMap<String, Array<String>> {
        LogicalCatalog.of(nodes, [], source).toMap()
    }

    static func getPartitions(source!: ConfigSource = EnvConfigSource()): Array<PartitionRuleConfig> {
        for ((key, _) in source.all()) {
            if (key == 'fdbm_partition' || key == 'fountain_fdbm_partition') {
                throw FdbmException(DbdErrorCode.CONFIG,
                    'fdbm_partition has no table name: use fdbm_partition__<table>')
            }
        }
        let rules = HashMap<String, PartitionRuleConfig>()
        for ((key, value) in source.all()) {
            if (!key.startsWith('fdbm_partition__')) {
                continue
            }
            let table = key.removePrefix('fdbm_partition__').trimAscii()
            if (table.isEmpty()) {
                throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_partition__ has an empty table name')
            }
            if (rules.get(table).isSome()) {
                throw FdbmException(DbdErrorCode.CONFIG, 'duplicated partition rule for table \'${table}\'')
            }
            let parts = splitNonEmpty(value, key)
            if (parts.size != 3) {
                throw configError(key, value, 'expect <logical>,<algorithm>,<column>')
            }
            let algorithm = parts[1].toLower()
            let substrKey = 'fdbm_partition_substr__${table}'
            let substrRaw = source.get(substrKey)
            let substr = if (algorithm == 'substr') {
                match (substrRaw) {
                    case Some(spec) => parseSubstring(substrKey, spec)
                    case None => throw FdbmException(DbdErrorCode.CONFIG,
                        'table \'${table}\' uses substr but ${substrKey} is missing')
                }
            } else {
                if (substrRaw.isSome()) {
                    logger.warn('${substrKey} is ignored: table \'${table}\' uses ${algorithm}, not substr')
                }
                None<SubstringSpec>
            }
            rules[table] = PartitionRuleConfig(parts[0], table, algorithm, parts[2], substr: substr)
        }
        let result = ArrayList<PartitionRuleConfig>()
        for ((_, rule) in rules) {
            result.add(rule)
        }
        result.toArray()
    }

    static func getGlobalTables(source!: ConfigSource = EnvConfigSource()): Array<GlobalTableConfig> {
        let result = ArrayList<GlobalTableConfig>()
        for ((key, value) in source.all()) {
            if (!key.startsWith('fdbm_global__')) {
                continue
            }
            let table = key.removePrefix('fdbm_global__').trimAscii()
            if (table.isEmpty()) {
                throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_global__ has an empty table name')
            }
            let database = value.trimAscii()
            if (database.isEmpty()) {
                throw configError(key, value, 'logical database is empty')
            }
            result.add(GlobalTableConfig(database, table))
        }
        result.toArray()
    }

    // ==================== ID、缓存与路径 ====================

    static func getIdMaker(source!: ConfigSource = EnvConfigSource()): IdMakerConfig {
        let raw = stringOf(source, 'fdbm_idmaker', 'uuid,1')
        let parts = raw.split(',')
        let kind = parts[0].trimAscii().toLower()
        let arg = if (parts.size > 1) {
            Some(parts[1].trimAscii())
        } else {
            None<String>
        }
        if (kind == 'uuid') {
            let version = match (arg) {
                case Some(text) => text
                case None => '1'
            }
            match (Int64.tryParse(version)) {
                case Some(v) =>
                    if (v != 1 && v != 4 && v != 6 && v != 7) {
                        throw configError('fdbm_idmaker', raw, 'uuid version must be 1, 4, 6 or 7')
                    }
                case None => throw configError('fdbm_idmaker', raw, 'uuid version is not a number')
            }
            return IdMakerConfig(kind, arg: Some(version))
        }
        if (kind == 'snowflake') {
            if (let Some(text) <- arg) {
                match (Int64.tryParse(text)) {
                    case Some(serial) =>
                        if (serial < 0 || serial > 1023) {
                            throw configError('fdbm_idmaker', raw, 'snowflake node serial must be in 0..1023')
                        }
                    case None => throw configError('fdbm_idmaker', raw, 'snowflake node serial is not a number')
                }
            }
            return IdMakerConfig(kind, arg: arg)
        }
        if (kind == 'sequence') {
            return IdMakerConfig(kind, arg: arg)
        }
        throw configError('fdbm_idmaker', raw, 'expect uuid / snowflake / sequence')
    }

    static func getCache(source!: ConfigSource = EnvConfigSource()): CacheConfig {
        let enabled = boolOf(source, 'fdbm_cache', true)
        let expire = match (source.get('fdbm_cache_expire')) {
            case Some(raw) =>
                if (raw.trimAscii().isEmpty()) {
                    None<Duration>
                } else {
                    match (durationValue(source, 'fdbm_cache_expire')) {
                        case Some(value) => Some(value)
                        case None => throw configError('fdbm_cache_expire', raw, 'not a Duration')
                    }
                }
            case None => None<Duration>
        }
        let size = intOf(source, 'fdbm_cache_size', 0)
        if (size < 0) {
            throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_cache_size must not be negative')
        }
        CacheConfig(enabled, expire, size, stringOf(source, 'fdbm_cachePath', './cache'))
    }

    static func getDriverDir(source!: ConfigSource = EnvConfigSource()): String {
        stringOf(source, 'fdbm_driverDir', './driver')
    }

    static func getCustomDir(source!: ConfigSource = EnvConfigSource()): String {
        stringOf(source, 'fdbm_customDir', './custom')
    }

    static func getBootScript(source!: ConfigSource = EnvConfigSource()): String {
        stringOf(source, 'fdbm_bootScript', './boot.sh')
    }

    static func getSessionSweepInterval(source!: ConfigSource = EnvConfigSource()): Duration {
        durationOf(source, 'fdbm_sessionSweepInterval', Duration.second * 30, seconds: true)
    }

    static func getShutdownTimeout(source!: ConfigSource = EnvConfigSource()): Duration {
        let value = durationOf(source, 'fdbm_shutdownTimeout', Duration.second * 30, seconds: true)
        if (value <= Duration.Zero) {
            throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_shutdownTimeout must be positive')
        }
        value
    }

    static func getCheckDuration(source!: ConfigSource = EnvConfigSource()): Duration {
        let value = durationOf(source, 'fdbm_checkDuration', Duration.second * 30, seconds: true)
        if (value <= Duration.Zero) {
            throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_checkDuration must be positive')
        }
        value
    }

    static func getUnavailableChecked(source!: ConfigSource = EnvConfigSource()): Int64 {
        let value = intOf(source, 'fdbm_unavailableChecked', 3)
        if (value <= 0) {
            throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_unavailableChecked must be positive')
        }
        value
    }

    /**
     * `sequence` 的分配库：显式配置优先，接受**逻辑库名或物理库名**；逻辑名解析为其物理库排序首项，
     * 两者都不是 → `ID_GENERATOR`。未配置时取默认逻辑库的首个物理库（设计 §3.1 / D03）。
     */
    static func getSequenceDatabase(source!: ConfigSource = EnvConfigSource(),
        catalog!: LogicalCatalog): String {
        if (let Some(configured) <- source.get('fdbm_sequenceDatabase')) {
            let name = configured.trimAscii()
            if (!name.isEmpty()) {
                match (catalog.physicals(name)) {
                    case Some(physicals) => return smallest(physicals)
                    case None =>
                        if (catalog.allPhysicals().contains(name)) {
                            return name
                        }
                }
                throw FdbmException(DbdErrorCode.ID_GENERATOR,
                    'sequence database \'${name}\' is neither a logical nor a physical database')
            }
        }
        match (catalog.physicals(catalog.default())) {
            case Some(physicals) => smallest(physicals)
            case None => catalog.allPhysicals()[0]
        }
    }

    /** 排序后取首项（逻辑库的物理库列表按配置顺序保存，取号库要求确定性）。 */
    private static func smallest(physicals: Array<String>): String {
        var value = physicals[0]
        for (candidate in physicals) {
            if (candidate < value) {
                value = candidate
            }
        }
        value
    }

    // ==================== 启动自检 ====================

    /**
     * 跨项校验（设计 §11）：在 `CustomLoader` 之后调用，`customAlgorithms` / `customIdGenerators`
     * 是自定义扩展已注册的 `name`。
     */
    public static func validate(confs: FdbmSettings, customAlgorithms: Array<String>,
        customIdGenerators: Array<String>, source!: ConfigSource = EnvConfigSource()): Unit {
        validateNodes(confs)

        // 驱动唯一性（与 DriverLoader 的"目录里恰好一个驱动"互补）
        let driver = confs.nodes[0].driverName
        for (node in confs.nodes) {
            if (node.driverName != driver) {
                throw FdbmException(DbdErrorCode.NO_DRIVER,
                    'all nodes must use the same driver: ${confs.nodes[0].name}=${driver}, ' +
                    '${node.name}=${node.driverName}')
            }
        }

        let databases = allDatabases(confs.nodes)
        validateWeights(confs, databases, source)
        validatePartitions(confs, confs.catalog, customAlgorithms)
        validateGlobalTables(confs, confs.catalog)
        validateIdMaker(confs, databases, customIdGenerators, source)
        if (confs.shutdownTimeout <= Duration.Zero || confs.shutdownTimeout == Duration.Max) {
            throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_shutdownTimeout must be positive and finite')
        }
        if (confs.checkDuration <= Duration.Zero || confs.unavailableChecked <= 0) {
            throw FdbmException(DbdErrorCode.CONFIG,
                'fdbm_checkDuration and fdbm_unavailableChecked must be positive')
        }
        if (confs.sessionSweepInterval <= Duration.Zero || confs.sessionSweepInterval == Duration.Max) {
            throw FdbmException(DbdErrorCode.CONFIG,
                'fdbm_sessionSweepInterval must be positive and finite')
        }
    }

    private static func validateNodes(confs: FdbmSettings): Unit {
        let names = HashSet<String>()
        for (node in confs.nodes) {
            if (!names.add(node.name)) {
                throw FdbmException(DbdErrorCode.CONFIG, 'duplicated node name \'${node.name}\'')
            }
        }
    }

    private static func validateWeights(confs: FdbmSettings, databases: HashSet<String>,
        source: ConfigSource): Unit {
        let nodes = HashSet<String>()
        for (node in confs.nodes) {
            nodes.add(node.name)
        }
        for ((key, _) in source.all()) {
            if (!key.startsWith('fdbm_loadbalance_weight_')) {
                continue
            }
            let suffix = key.removePrefix('fdbm_loadbalance_weight_')
            let node = if (let Some(index) <- suffix.indexOf('__')) {
                suffix[0..index]
            } else {
                suffix
            }
            if (!nodes.contains(node)) {
                throw FdbmException(DbdErrorCode.CONFIG,
                    '${key} refers to unknown node \'${node}\'')
            }
            if (let Some(index) <- suffix.indexOf('__')) {
                let database = suffix[index + 2..suffix.size]
                if (!databases.contains(database)) {
                    throw FdbmException(DbdErrorCode.CONFIG,
                        '${key} refers to unknown database \'${database}\'')
                }
            }
        }
    }

    private static func validatePartitions(confs: FdbmSettings, catalog: LogicalCatalog,
        customAlgorithms: Array<String>): Unit {
        // 内置名不可覆盖（D09）：自定义扩展名与内置算法名冲突 → 启动失败
        for (name in customAlgorithms) {
            if (containsName(BUILTIN_ALGORITHMS, name)) {
                throw FdbmException(DbdErrorCode.PARTITION_CONFIG,
                    'custom partition algorithm \'${name}\' conflicts with a builtin algorithm; ' +
                    'a builtin implementation must not be overridden')
            }
        }
        let known = HashSet<String>()
        for (name in BUILTIN_ALGORITHMS) {
            known.add(name)
        }
        for (name in customAlgorithms) {
            known.add(name)
        }
        for (rule in confs.partitions) {
            if (!known.contains(rule.algorithm)) {
                throw FdbmException(DbdErrorCode.PARTITION_CONFIG,
                    'table \'${rule.table}\': unknown partition algorithm \'${rule.algorithm}\'')
            }
            if (!catalog.contains(rule.database)) {
                throw FdbmException(DbdErrorCode.PARTITION_CONFIG,
                    'table \'${rule.table}\' refers to unknown logical database \'${rule.database}\'')
            }
            if (rule.algorithm == 'substr') {
                match (rule.substr) {
                    case Some(spec) =>
                        if (spec.start < 0 || spec.length < 0) {
                            throw FdbmException(DbdErrorCode.CONFIG,
                                'table \'${rule.table}\': substr start/length must not be negative')
                        }
                        if (!isSubstrHash(spec.hash)) {
                            throw FdbmException(DbdErrorCode.CONFIG,
                                'table \'${rule.table}\': unknown substr hash \'${spec.hash}\'')
                        }
                    case None => throw FdbmException(DbdErrorCode.CONFIG,
                        'table \'${rule.table}\': substr parameters are missing')
                }
            }
        }
    }

    /** 全局表的逻辑库引用必须在 catalog 中（G08）。 */
    private static func validateGlobalTables(confs: FdbmSettings, catalog: LogicalCatalog): Unit {
        for (table in confs.globalTables) {
            if (!catalog.contains(table.database)) {
                throw FdbmException(DbdErrorCode.CONFIG,
                    'global table \'${table.table}\' refers to unknown logical database \'${table.database}\'')
            }
        }
    }

    private static func validateIdMaker(confs: FdbmSettings, databases: HashSet<String>,
        customIdGenerators: Array<String>, source: ConfigSource): Unit {
        // 内置名不可覆盖（D09）
        for (name in customIdGenerators) {
            if (name == 'uuid' || name == 'snowflake' || name == 'sequence') {
                throw FdbmException(DbdErrorCode.CONFIG,
                    'custom id generator \'${name}\' conflicts with a builtin generator; ' +
                    'a builtin implementation must not be overridden')
            }
        }
        let idmaker = confs.idmaker
        if (idmaker.kind == 'snowflake') {
            let serial = match (idmaker.arg) {
                case Some(text) => Int64.tryParse(text)
                case None =>
                    match (source.get('idMakerHostSerial')) {
                        case Some(text) => Int64.tryParse(text)
                        case None => None<Int64>
                    }
            }
            match (serial) {
                case Some(value) =>
                    if (value < 0 || value > 1023) {
                        throw FdbmException(DbdErrorCode.CONFIG, 'snowflake node serial must be in 0..1023')
                    }
                case None => throw FdbmException(DbdErrorCode.CONFIG,
                    'fdbm_idmaker=snowflake requires a node serial (fdbm_idmaker=snowflake,<0..1023> ' +
                    'or idMakerHostSerial)')
            }
            return
        }
        if (idmaker.kind == 'sequence') {
            if (!databases.contains(confs.sequenceDatabase)) {
                throw FdbmException(DbdErrorCode.ID_GENERATOR,
                    'sequence database \'${confs.sequenceDatabase}\' does not exist on any node')
            }
            return
        }
        if (idmaker.kind == 'uuid') {
            return
        }
        if (customIdGenerators.contains(idmaker.kind)) {
            return
        }
        throw FdbmException(DbdErrorCode.CONFIG, 'unknown id generator \'${idmaker.kind}\'')
    }

    private static func allDatabases(nodes: Array<DatabaseNodeConfig>): HashSet<String> {
        let databases = HashSet<String>()
        for (node in nodes) {
            for (database in node.databases) {
                databases.add(database)
            }
        }
        databases
    }

    private static func containsName(names: Array<String>, name: String): Bool {
        for (candidate in names) {
            if (candidate == name) {
                return true
            }
        }
        false
    }

    // ==================== 解析辅助 ====================

    private static func requireString(source: ConfigSource, key: String): String {
        match (source.get(key)) {
            case Some(value) =>
                if (value.trimAscii().isEmpty()) {
                    throw FdbmException(DbdErrorCode.CONFIG, '${key} must not be empty')
                }
                value.trimAscii()
            case None => throw FdbmException(DbdErrorCode.CONFIG, '${key} is required')
        }
    }

    private static func stringOf(source: ConfigSource, key: String, fallback: String): String {
        match (source.get(key)) {
            case Some(value) => if (value.trimAscii().isEmpty()) { fallback } else { value.trimAscii() }
            case None => fallback
        }
    }

    private static func intOf(source: ConfigSource, key: String, fallback: Int64): Int64 {
        match (source.get(key)) {
            case Some(raw) =>
                if (raw.trimAscii().isEmpty()) {
                    return fallback
                }
                match (Int64.tryParse(raw.trimAscii())) {
                    case Some(value) => value
                    case None => throw configError(key, raw, 'not an integer')
                }
            case None => fallback
        }
    }

    private static func boolOf(source: ConfigSource, key: String, fallback: Bool): Bool {
        match (source.get(key)) {
            case Some(raw) =>
                let text = raw.trimAscii().toLower()
                if (text.isEmpty()) {
                    fallback
                } else if (text == 'true' || text == '1') {
                    true
                } else if (text == 'false' || text == '0') {
                    false
                } else {
                    throw configError(key, raw, 'not a boolean')
                }
            case None => fallback
        }
    }

    /** 时长：优先按 `Duration` 文本解析（如 `30s`），也接受裸数字（`seconds` 决定单位）。 */
    private static func durationOf(source: ConfigSource, key: String, fallback: Duration, seconds!: Bool): Duration {
        match (source.get(key)) {
            case Some(raw) =>
                let text = raw.trimAscii()
                if (text.isEmpty()) {
                    return fallback
                }
                match (Duration.tryParse(text)) {
                    case Some(value) => value
                    case None =>
                        match (Int64.tryParse(text)) {
                            case Some(number) =>
                                if (seconds) {
                                    Duration.second * number
                                } else {
                                    Duration.millisecond * number
                                }
                            case None => throw configError(key, raw, 'not a Duration')
                        }
                }
            case None => fallback
        }
    }

    private static func durationValue(source: ConfigSource, key: String): ?Duration {
        match (source.get(key)) {
            case Some(raw) =>
                if (raw.trimAscii().isEmpty()) {
                    None<Duration>
                } else {
                    match (Duration.tryParse(raw.trimAscii())) {
                        case Some(value) => Some(value)
                        case None => throw configError(key, raw, 'not a Duration')
                    }
                }
            case None => None<Duration>
        }
    }

    private static func maxWaitingOf(source: ConfigSource): Duration {
        let ms = intOf(source, 'fdbm_databasePoolMaxWaiting', 30000)
        if (ms <= 0) {
            Duration.Max
        } else {
            Duration.millisecond * ms
        }
    }

    private static func parseAddress(address: String): (String, UInt16) {
        if (address.startsWith('[')) {
            let close = match (address.indexOf(']')) {
                case Some(index) => index
                case None => throw FdbmException(DbdErrorCode.CONFIG,
                    'illegal address \'${address}\': unbalanced \'[\'')
            }
            let host = address[0..close + 1]
            let tail = address[close + 1..address.size]
            if (!tail.startsWith(':')) {
                throw FdbmException(DbdErrorCode.CONFIG, 'illegal address \'${address}\': port is missing')
            }
            return (host, parsePort(tail[1..tail.size], address))
        }
        let colon = match (address.lastIndexOf(':')) {
            case Some(index) => index
            case None => throw FdbmException(DbdErrorCode.CONFIG,
                'illegal address \'${address}\': port is missing')
        }
        let host = address[0..colon].trimAscii()
        if (host.isEmpty()) {
            throw FdbmException(DbdErrorCode.CONFIG, 'illegal address \'${address}\': host is empty')
        }
        (host, parsePort(address[colon + 1..address.size], address))
    }

    private static func parsePort(text: String, address: String): UInt16 {
        match (UInt16.tryParse(text.trimAscii())) {
            case Some(port) =>
                if (port == 0) {
                    throw FdbmException(DbdErrorCode.CONFIG, 'illegal address \'${address}\': port must be 1..65535')
                }
                port
            case None => throw FdbmException(DbdErrorCode.CONFIG,
                'illegal address \'${address}\': port \'${text}\' is not a number')
        }
    }

    private static func parseWeight(key: String, value: String): NodeWeight {
        let slots = WeightSlots()
        var pending: ?String = None
        for (chunk in value.split(';')) {
            for (raw in chunk.split('/')) {
                let text = raw.trimAscii()
                if (text.isEmpty()) {
                    continue
                }
                let parts = splitWeightPair(text)
                if (parts.size == 2) {
                    let marker = parts[0].toLower()
                    let amount = weightNumber(key, value, parts[1])
                    assignWeight(slots, marker, amount, key, value)
                    pending = None
                } else if (parts.size == 1) {
                    let token = parts[0].toLower()
                    if (token == 'w' || token == 'r') {
                        pending = Some(token)
                    } else if (let Some(marker) <- pending) {
                        // `w,2;r;3` 这种写法：裸数字归给前一个标记
                        let amount = weightNumber(key, value, token)
                        assignWeight(slots, marker, amount, key, value)
                        pending = None
                    } else {
                        throw configError(key, value, 'expect w[,weight] and r[,weight] segments')
                    }
                } else {
                    throw configError(key, value, 'expect w[,weight] and r[,weight] segments')
                }
            }
        }
        NodeWeight(write: slots.write, read: slots.read)
    }

    /** 单个权重对按 `,` 或 `=` 切分（`w,1` / `r=2`）。 */
    private static func splitWeightPair(text: String): Array<String> {
        let separator = match (text.indexOf('=')) {
            case Some(_) => '='
            case None => ','
        }
        let parts = text.split(separator)
        let result = ArrayList<String>()
        for (part in parts) {
            let trimmed = part.trimAscii()
            if (!trimmed.isEmpty()) {
                result.add(trimmed)
            }
        }
        result.toArray()
    }

    private static func weightNumber(key: String, value: String, text: String): Int64 {
        let amount = match (Int64.tryParse(text)) {
            case Some(number) => number
            case None => throw configError(key, value, 'weight \'${text}\' is not a number')
        }
        if (amount < 0) {
            throw configError(key, value, 'weight must not be negative')
        }
        amount
    }

    private static func assignWeight(slots: WeightSlots, marker: String, amount: Int64,
        key: String, value: String): Unit {
        if (marker == 'w') {
            slots.write = amount
        } else if (marker == 'r') {
            slots.read = amount
        } else {
            throw configError(key, value, 'expect w[,weight] and r[,weight] segments')
        }
    }

    private static func parseSubstring(key: String, value: String): SubstringSpec {
        let parts = splitNonEmpty(value, key)
        if (parts.size != 3) {
            throw configError(key, value, 'expect <start>,<length>,<hash>')
        }
        let start = match (Int64.tryParse(parts[0])) {
            case Some(number) => number
            case None => throw configError(key, value, 'start is not a number')
        }
        let length = match (Int64.tryParse(parts[1])) {
            case Some(number) => number
            case None => throw configError(key, value, 'length is not a number')
        }
        let hash = parts[2].toLower()
        if (!isSubstrHash(hash)) {
            throw configError(key, value, 'unknown substring hash \'${parts[2]}\'')
        }
        SubstringSpec(start, length, hash)
    }

    private static func isSubstrHash(hash: String): Bool {
        for (candidate in SUBSTR_HASHES) {
            if (candidate == hash) {
                return true
            }
        }
        false
    }

    private static func splitNonEmpty(value: String, key: String): Array<String> {
        let result = ArrayList<String>()
        for (part in value.split(',')) {
            let text = part.trimAscii()
            if (!text.isEmpty()) {
                result.add(text)
            }
        }
        if (result.isEmpty()) {
            throw configError(key, value, 'value is empty')
        }
        result.toArray()
    }

    private static func configError(key: String, raw: String, reason: String): FdbmException {
        FdbmException(DbdErrorCode.CONFIG, 'illegal ${key} \'${raw}\': ${reason}')
    }
}


/** 权重解析的可变槽（Cangjie 没有引用参数，用一个小对象承接两个方向）。 */
class WeightSlots {
    var write: Int64 = 1
    var read: Int64 = 1
}
