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
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException
import fountain::f_log.LoggerFactory

/**
 * 逻辑库命名空间（设计 §3.1，D03）。
 *
 * **物理库名不会被自动注册成逻辑库键**。装载规则：
 * 1. `fdbm_db_logicalDatabase_<logical>` 是唯一显式声明来源；
 * 2. 仅 `fdbm_partition__*` 引用但未显式配置的逻辑库 → 全部物理库（排序去重）；
 *    `fdbm_global__*` 不触发隐式展开，必须显式引用已存在的逻辑库（否则 CONFIG）；
 * 3. 仍为空时，以排序后的第一个物理库名作唯一命名空间并记 WARN（兼容旧部署）。
 *
 * `names()` / `default()` 都按名称排序，保证跨进程确定性。
 */
protected class LogicalCatalog {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.config.LogicalCatalog')

    private let mapping: HashMap<String, Array<String>>
    private let sortedNames: Array<String>
    private let physicalsAll: Array<String>
    private let defaultName: String

    private init(mapping: HashMap<String, Array<String>>, sortedNames: Array<String>,
        physicalsAll: Array<String>, defaultName: String) {
        this.mapping = mapping
        this.sortedNames = sortedNames
        this.physicalsAll = physicalsAll
        this.defaultName = defaultName
    }

    /** 由节点、分库规则与全局表装载（隐式展开见类注释）。 */
    public static func of(nodes: Array<DatabaseNodeConfig>, partitions: Array<PartitionRuleConfig>,
        source: ConfigSource): LogicalCatalog {
        let all = sortedPhysicals(nodes)
        let mapping = HashMap<String, Array<String>>()
        for ((key, value) in source.all()) {
            if (!key.startsWith('fdbm_db_logicalDatabase_')) {
                continue
            }
            let logical = key.removePrefix('fdbm_db_logicalDatabase_').trimAscii()
            if (logical.isEmpty()) {
                throw FdbmException(DbdErrorCode.CONFIG, 'fdbm_db_logicalDatabase_ has an empty logical name')
            }
            let physicals = dedup(splitValue(value, key))
            for (physical in physicals) {
                if (!all.contains(physical)) {
                    throw FdbmException(DbdErrorCode.CONFIG,
                        'logical database \'${logical}\' refers to unknown physical database \'${physical}\'')
                }
            }
            mapping[logical] = physicals
        }
        // 被分库规则引用但未显式配置的逻辑库：隐式包含全部物理库。
        // 全局表**不创建**命名空间（否则 `fdbm_global__dict='cfg'` 的 typo 无法在启动期发现，G08）；
        // 它只能引用显式配置或被分库规则建立的逻辑库，由 validateGlobalTables 校验。
        for (rule in partitions) {
            ensure(mapping, rule.database, all)
        }
        if (mapping.isEmpty()) {
            let name = all[0]
            logger.warn('no logical database is configured: using physical database \'${name}\' as the ' +
                'only logical namespace')
            mapping[name] = all
        }
        let names = sortedNamesOf(mapping)
        let defaultName = if (names.size == 1) {
            names[0]
        } else {
            logger.warn('multiple logical databases are configured: the session default database is ' +
                '\'${names[0]}\'; qualify tables as <logical>.<table> to target another one')
            names[0]
        }
        LogicalCatalog(mapping, names, all, defaultName)
    }

    /** 逻辑库名（排序，跨进程确定）。 */
    public func names(): Array<String> {
        sortedNames
    }

    /** 逻辑库 → 物理库；未知逻辑库 → `None`。 */
    public func physicals(name: String): ?Array<String> {
        match (mapping.get(name)) {
            case Some(value) => Some(value)
            case None => None<Array<String>>
        }
    }

    /** 会话默认逻辑库。 */
    public func default(): String {
        defaultName
    }

    /** 部署内全部物理库（排序去重）。 */
    public func allPhysicals(): Array<String> {
        physicalsAll
    }

    public func contains(name: String): Bool {
        mapping.get(name).isSome()
    }

    /** 兼容 `FdbmSettings.logicalDatabases` 的字段类型（内部由本类产出）。 */
    public func toMap(): HashMap<String, Array<String>> {
        let copy = HashMap<String, Array<String>>()
        for ((name, value) in mapping) {
            copy[name] = value
        }
        copy
    }

    private static func ensure(mapping: HashMap<String, Array<String>>, name: String,
        all: Array<String>): Unit {
        if (!mapping.contains(name)) {
            mapping[name] = all
        }
    }

    private static func splitValue(value: String, key: String): Array<String> {
        let result = ArrayList<String>()
        for (part in value.split(',')) {
            let text = part.trimAscii()
            if (!text.isEmpty()) {
                result.add(text)
            }
        }
        if (result.isEmpty()) {
            throw FdbmException(DbdErrorCode.CONFIG, 'illegal ${key} \'${value}\': value is empty')
        }
        result.toArray()
    }

    private static func dedup(values: Array<String>): Array<String> {
        let seen = HashSet<String>()
        let out = ArrayList<String>()
        for (value in values) {
            if (seen.add(value)) {
                out.add(value)
            }
        }
        out.toArray()
    }

    private static func sortedPhysicals(nodes: Array<DatabaseNodeConfig>): Array<String> {
        let seen = HashSet<String>()
        let out = ArrayList<String>()
        for (node in nodes) {
            for (database in node.databases) {
                if (seen.add(database)) {
                    out.add(database)
                }
            }
        }
        sortInPlace(out.toArray())
    }

    private static func sortedNamesOf(mapping: HashMap<String, Array<String>>): Array<String> {
        let out = ArrayList<String>()
        for ((name, _) in mapping) {
            out.add(name)
        }
        sortInPlace(out.toArray())
    }

    private static func sortInPlace(values: Array<String>): Array<String> {
        var i: Int64 = 1
        while (i < values.size) {
            let current = values[i]
            var j = i - 1
            while (j >= 0 && values[j] > current) {
                values[j + 1] = values[j]
                j -= 1
            }
            values[j + 1] = current
            i += 1
        }
        values
    }
}
