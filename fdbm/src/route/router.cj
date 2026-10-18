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
import std.convert.*
import fountain::f_dbm.PartitionAlgorithm
import fountain::fdbm.sql.*

/** 路由结果形态（设计 §6.2）。 */
protected enum RouteKind <: Equatable<RouteKind> {
    | Single | Multi | Broadcast | Empty | Unroutable

    public operator func ==(other: RouteKind): Bool {
        index() == other.index()
    }

    func index(): Int64 {
        match (this) {
            case Single => 0
            case Multi => 1
            case Broadcast => 2
            case Empty => 3
            case Unroutable => 4
        }
    }
}

protected class RoutePlan {
    private let kind_: RouteKind
    private let databases_: Array<String>

    public init(kind: RouteKind, databases!: Array<String> = []) {
        this.kind_ = kind
        this.databases_ = databases
    }

    public prop kind: RouteKind {
        get() {
            kind_
        }
    }

    public prop databases: Array<String> {
        get() {
            databases_
        }
    }

    public static func single(database: String): RoutePlan {
        RoutePlan(RouteKind.Single, databases: [database])
    }

    public static func multi(databases: Array<String>): RoutePlan {
        RoutePlan(RouteKind.Multi, databases: databases)
    }

    public static func broadcast(databases: Array<String>): RoutePlan {
        RoutePlan(RouteKind.Broadcast, databases: databases)
    }

    public static func empty(): RoutePlan {
        RoutePlan(RouteKind.Empty)
    }

    public static func unroutable(): RoutePlan {
        RoutePlan(RouteKind.Unroutable)
    }
}

/** 一条分库规则（`fdbm_partition__<table>` 的解析结果）。 */
protected class PartitionRule {
    public let database: String
    public let table: String
    public let column: String
    public let algorithm: PartitionAlgorithm

    public init(database: String, table: String, column: String, algorithm: PartitionAlgorithm) {
        this.database = database
        this.table = table
        this.column = column
        this.algorithm = algorithm
    }
}

/**
 * 语句级路由器（设计 §6.2）。
 *
 * 只负责"算出候选物理库"，不借连接、不执行 SQL；执行器根据 `RouteKind` 决定广播/报错/空结果。
 */
protected class PartitionRouter {
    private let rules: HashMap<String, PartitionRule>
    private let cache: ?PartitionCache
    private let known: HashSet<String>
    private let knownOrder: Array<String>
    private let globalTables: GlobalTableRouter

    public init(rules: Array<PartitionRule>, cache: ?PartitionCache,
        custom: HashMap<String, PartitionAlgorithm>, knownDatabases!: Array<String> = [],
        globalTables!: GlobalTableRouter = GlobalTableRouter([])) {
        let indexed = HashMap<String, PartitionRule>()
        for (rule in rules) {
            indexed['${rule.database}.${rule.table}'] = rule
        }
        this.rules = indexed
        this.cache = cache
        let known = HashSet<String>()
        for (database in knownDatabases) {
            known.add(database)
        }
        this.known = known
        this.knownOrder = knownDatabases
        this.globalTables = globalTables
    }

    /** 语句级路由：等值/IN/范围（仅 step）→ Single/Multi；全局表 → Broadcast；未分库表 → Single。 */
    public func route(statement: SqlStatement, currentDatabase: String): RoutePlan {
        let constraints = ArrayList<(PartitionRule, Array<String>)>()
        var hasPartitionedTable = false
        var hasNonGlobalTable = false
        for (table in statement.tables) {
            let logical = match (table.database) {
                case Some(database) => database
                case None => currentDatabase
            }
            if (globalTables.isGlobal(logical, table.name)) {
                continue
            }
            hasNonGlobalTable = true
            match (rule(logical, table.name)) {
                case Some(found) =>
                    hasPartitionedTable = true
                    match (constraintOf(found, statement)) {
                        case Some(databases) => constraints.add((found, databases))
                        case None => return RoutePlan.unroutable()
                    }
                case None => () // 未分库表不参与约束
            }
        }
        if (constraints.isEmpty()) {
            if (hasPartitionedTable) {
                return RoutePlan.unroutable()
            }
            let logical = logicalOf(statement, currentDatabase)
            let physicals = globalTables.physicalDatabases(logical)
            if (!hasNonGlobalTable) {
                // 全部是全局表：写广播到逻辑库全部物理库；读由执行器取任一副本
                if (!physicals.isEmpty()) {
                    return RoutePlan.broadcast(physicals)
                }
                return RoutePlan.unroutable()
            }
            // 全部未分库（或未分库 + 全局表）：任选一个物理库
            if (!physicals.isEmpty()) {
                return RoutePlan.single(physicals[0])
            }
            if (!knownOrder.isEmpty()) {
                return RoutePlan.single(knownOrder[0])
            }
            return RoutePlan.unroutable()
        }
        // 同一分库维度取交集；不同维度要求各表都收敛到同一个库
        let sameDimension = constraints.size == 1 || allSameDimension(constraints)
        if (!sameDimension) {
            let first = constraints[0][1]
            if (first.size != 1) {
                return RoutePlan.unroutable()
            }
            for ((_, databases) in constraints) {
                if (databases.size != 1 || databases[0] != first[0]) {
                    return RoutePlan.unroutable()
                }
            }
            return RoutePlan.single(first[0])
        }
        var intersection = constraints[0][1]
        var index: Int64 = 1
        while (index < constraints.size) {
            intersection = intersect(intersection, constraints[index][1])
            index += 1
        }
        if (intersection.isEmpty()) {
            return RoutePlan.empty()
        }
        if (intersection.size == 1) {
            return RoutePlan.single(intersection[0])
        }
        RoutePlan.multi(intersection)
    }

    /** 值级路由：缓存 → 算法 → 回写；缓存指向不存在的物理库时删除并重算。 */
    public func routeByValue(rule: PartitionRule, value: String): String {
        match (cache) {
            case Some(store) =>
                match (store.get(rule.database, rule.table, rule.column, value)) {
                    case Some(physical) =>
                        if (known.isEmpty() || known.contains(physical)) {
                            return physical
                        }
                        store.remove(rule.database, rule.table, rule.column, value)
                    case None => ()
                }
            case None => ()
        }
        let physical = match (Int64.tryParse(value)) {
            case Some(parsed) =>
                if (parsed.toString() == value) {
                    rule.algorithm.partition<Int64>(parsed)
                } else {
                    rule.algorithm.partition<String>(value)
                }
            case None => rule.algorithm.partition<String>(value)
        }
        match (cache) {
            case Some(store) => store.put(rule.database, rule.table, rule.column, value, physical)
            case None => ()
        }
        physical
    }

    public func rule(database: String, table: String): ?PartitionRule {
        rules.get('${database}.${table}')
    }

    /** 删除缓存条目（DELETE 三步顺序的第三步）。 */
    public func invalidate(rule: PartitionRule, value: String): Unit {
        match (cache) {
            case Some(store) => store.remove(rule.database, rule.table, rule.column, value)
            case None => ()
        }
    }

    /** 语句归属的逻辑库：首个表引用显式库优先，否则用会话当前库。 */
    private static func logicalOf(statement: SqlStatement, currentDatabase: String): String {
        for (table in statement.tables) {
            match (table.database) {
                case Some(database) => return database
                case None => return currentDatabase
            }
        }
        currentDatabase
    }

    public func isPartitioned(database: String, table: String): Bool {
        rules.get('${database}.${table}').isSome()
    }

    public func close(): Unit {
        match (cache) {
            case Some(store) => store.close()
            case None => ()
        }
    }

    // ==================== 约束计算 ====================

    private func constraintOf(rule: PartitionRule, statement: SqlStatement): ?Array<String> {
        match (statement) {
            case s: InsertStatement => insertConstraint(rule, s)
            case s: SelectStatement => expressionConstraint(rule, s.condition)
            case s: UpdateStatement => expressionConstraint(rule, s.condition)
            case s: DeleteStatement => expressionConstraint(rule, s.condition)
            case _ => None<Array<String>>
        }
    }

    private func expressionConstraint(rule: PartitionRule,
        condition: ?SqlExpression): ?Array<String> {
        let equals = PartitionKeyExtractor.extract(condition, Some(rule.table), rule.column)
        let ranges = PartitionKeyExtractor.extractRange(condition, Some(rule.table), rule.column)
        if (equals.isEmpty() && ranges.isNone()) {
            return None<Array<String>>
        }
        var rangeDatabases: ?Array<String> = None
        match (ranges) {
            case Some(range) =>
                match (rule.algorithm) {
                    case step: StepPartition =>
                        let expanded = step.partitionRange(range.lo, range.loInclusive,
                            range.hi, range.hiInclusive)
                        if (expanded.isEmpty()) {
                            return Some(Array<String>())
                        }
                        rangeDatabases = Some(expanded)
                    case _ =>
                        if (equals.isEmpty()) {
                            return None<Array<String>>
                        }
                }
            case None => ()
        }
        let mapped = ArrayList<String>()
        for (value in equals) {
            let physical = routeByValue(rule, value)
            if (!mapped.contains(physical)) {
                mapped.add(physical)
            }
        }
        match (rangeDatabases) {
            case Some(databases) =>
                if (mapped.isEmpty()) {
                    return Some(databases)
                }
                let filtered = ArrayList<String>()
                for (database in mapped) {
                    if (databases.contains(database)) {
                        filtered.add(database)
                    }
                }
                return Some(filtered.toArray())
            case None => Some(mapped.toArray())
        }
    }

    private func insertConstraint(rule: PartitionRule, statement: InsertStatement): ?Array<String> {
        let values = ArrayList<String>()
        if (!statement.columns.isEmpty()) {
            var index: Int64 = -1
            var i: Int64 = 0
            while (i < statement.columns.size) {
                if (statement.columns[i] == rule.column) {
                    index = i
                    break
                }
                i += 1
            }
            if (index < 0) {
                return None<Array<String>>
            }
            for (row in statement.values) {
                if (index >= row.size) {
                    return None<Array<String>>
                }
                match (PartitionKeyExtractor.literalString(row[index])) {
                    case Some(text) => values.add(text)
                    case None => return None<Array<String>>
                }
            }
        } else {
            var found = false
            for ((column, value) in statement.setPairs) {
                if (column == rule.column) {
                    found = true
                    match (PartitionKeyExtractor.literalString(value)) {
                        case Some(text) => values.add(text)
                        case None => return None<Array<String>>
                    }
                }
            }
            if (!found) {
                return None<Array<String>>
            }
        }
        if (values.isEmpty()) {
            return None<Array<String>>
        }
        let databases = ArrayList<String>()
        for (value in values) {
            let physical = routeByValue(rule, value)
            if (!databases.contains(physical)) {
                databases.add(physical)
            }
        }
        databases.toArray()
    }

    /** 同一分库维度：列名与算法（含分片空间）都相同。 */
    private static func allSameDimension(constraints: ArrayList<(PartitionRule, Array<String>)>): Bool {
        let first = constraints[0][0]
        for ((rule, _) in constraints) {
            if (rule.column != first.column || rule.algorithm.name != first.algorithm.name) {
                return false
            }
        }
        true
    }

    private static func intersect(left: Array<String>, right: Array<String>): Array<String> {
        let result = ArrayList<String>()
        for (value in left) {
            if (right.contains(value) && !result.contains(value)) {
                result.add(value)
            }
        }
        result.toArray()
    }
}
