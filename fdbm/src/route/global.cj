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
package fountain::fdbm.route

import std.collection.{ArrayList, HashMap, HashSet}

/** 全局表规则（设计 §6.4）：数据在每个物理库各有一副副本。 */
protected class GlobalTableRule {
    public let database: String
    public let table: String

    public init(database: String, table: String) {
        this.database = database
        this.table = table
    }
}

protected class GlobalTableRouter {
    private let keys: HashSet<String>
    private let byDatabase = HashMap<String, ArrayList<String>>()
    private let logicalDatabases: HashMap<String, Array<String>>

    /**
     * @param logicalDatabases 逻辑库 → 物理库列表（`FdbmSettings.logicalDatabases`）。
     *        全局表写广播与"未分库表选一个库"都靠它定位物理库。
     */
    public init(rules: Array<GlobalTableRule>,
        logicalDatabases!: HashMap<String, Array<String>> = HashMap<String, Array<String>>()) {
        let keys = HashSet<String>()
        for (rule in rules) {
            keys.add('${rule.database}.${rule.table}')
            let list = match (byDatabase.get(rule.database)) {
                case Some(existing) => existing
                case None =>
                    let created = ArrayList<String>()
                    byDatabase[rule.database] = created
                    created
            }
            list.add(rule.table)
        }
        this.keys = keys
        this.logicalDatabases = logicalDatabases
    }

    /** 逻辑库包含的物理库；未配置映射时返回空数组（调用方自行回退）。 */
    public func physicalDatabases(logical: String): Array<String> {
        match (logicalDatabases.get(logical)) {
            case Some(value) => value
            case None => Array<String>()
        }
    }

    public func isGlobal(database: String, table: String): Bool {
        keys.contains('${database}.${table}')
    }

    public func tables(database: String): Array<String> {
        match (byDatabase.get(database)) {
            case Some(list) => list.toArray()
            case None => Array<String>()
        }
    }
}
