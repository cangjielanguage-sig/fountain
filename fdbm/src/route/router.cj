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
    private let reason_: String

    public init(kind: RouteKind, databases!: Array<String> = [], reason!: String = '') {
        this.kind_ = kind
        this.databases_ = databases
        this.reason_ = reason
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

    public static func unroutable(reason!: String = ''): RoutePlan {
        RoutePlan(RouteKind.Unroutable, reason: reason)
    }

    /** `Unroutable` 的补充说明（G27：列出不同维度/物理库集合）。 */
    public prop reason: String {
        get() {
            reason_
        }
    }
}

/** 一条分库规则（`fdbm_partition__<table>` 的解析结果）。 */
protected class PartitionRule {
    public let database: String
    public let table: String
    public let column: String
    public let algorithm: PartitionAlgorithm
    /** 该规则的分片空间（物理库集合）；空表示未知（用例构造的规则）。 */
    public let databases: Array<String>

    public init(database: String, table: String, column: String, algorithm: PartitionAlgorithm,
        databases!: Array<String> = []) {
        this.database = database
        this.table = table
        this.column = column
        this.algorithm = algorithm
        this.databases = databases
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
            indexed['${rule.database}.${rule.table}'.toAsciiLower()] = rule
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
            let reason = dimensionReason(constraints)
            let first = constraints[0][1]
            if (first.size != 1) {
                return RoutePlan.unroutable(reason: reason)
            }
            for ((_, databases) in constraints) {
                if (databases.size != 1 || databases[0] != first[0]) {
                    return RoutePlan.unroutable(reason: reason)
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
        rules.get('${database}.${table}'.toAsciiLower())
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
        rules.get('${database}.${table}'.toAsciiLower()).isSome()
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
            case s: SelectStatement => selectConstraint(rule, s)
            case s: UpdateStatement => expressionConstraint(rule, s, s.condition)
            case s: DeleteStatement => expressionConstraint(rule, s, s.condition)
            case _ => None<Array<String>>
        }
    }

    /**
     * SELECT 的分区约束（设计 D5）：派生表沿内层查询计算，与直接执行内层一致。
     *
     * 形状校验保证派生表最多一个且没有外层条件，因此递归进入内层不会有歧义。
     */
    private func selectConstraint(rule: PartitionRule, statement: SelectStatement): ?Array<String> {
        for (table in statement.from) {
            match (table.derived) {
                case Some(inner) => return selectConstraint(rule, inner)
                case None => ()
            }
        }
        expressionConstraint(rule, statement, statement.condition)
    }

    private func expressionConstraint(rule: PartitionRule, statement: SqlStatement,
        condition: ?SqlExpression): ?Array<String> {
        let qualifiers = qualifiersOf(statement, rule)
        let equals = PartitionKeyExtractor.extract(condition, Some(rule.table), rule.column,
            qualifiers: qualifiers)
        let ranges = PartitionKeyExtractor.extractRange(condition, Some(rule.table), rule.column,
            qualifiers: qualifiers)
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
                if (asciiEquals(statement.columns[i].name, rule.column)) {
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
                if (asciiEquals(column.name, rule.column)) {
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

    /** 规则的表名 + 语句里该表的别名（G20：别名限定的分库键也要能抽取）。 */
    private static func qualifiersOf(statement: SqlStatement, rule: PartitionRule): Array<String> {
        let names = ArrayList<String>()
        names.add(rule.table)
        for (table in statement.tables) {
            if (!asciiEquals(table.name, rule.table)) {
                continue
            }
            match (table.alias) {
                case Some(alias) =>
                    if (!names.contains(alias)) {
                        names.add(alias)
                    }
                case None => ()
            }
        }
        names.toArray()
    }

    /** 同一分库维度：列名、算法与**分片空间（物理库集合）**都相同（G27）。 */
    private static func allSameDimension(constraints: ArrayList<(PartitionRule, Array<String>)>): Bool {
        let first = constraints[0][0]
        for ((rule, _) in constraints) {
            if (rule.column != first.column || rule.algorithm.name != first.algorithm.name) {
                return false
            }
            if (!rule.databases.isEmpty() && !first.databases.isEmpty() &&
                !sameSet(rule.databases, first.databases)) {
                return false
            }
        }
        true
    }

    private static func sameSet(left: Array<String>, right: Array<String>): Bool {
        if (left.size != right.size) {
            return false
        }
        for (value in left) {
            if (!right.contains(value)) {
                return false
            }
        }
        true
    }

    /** 不同维度时的错误说明：列出两张表的逻辑库/物理库集合（G27）。 */
    private static func dimensionReason(
        constraints: ArrayList<(PartitionRule, Array<String>)>): String {
        let first = constraints[0][0]
        let left = if (first.databases.isEmpty()) { 'unknown' } else { '[' + joinNames(first.databases) + ']' }
        for ((rule, _) in constraints) {
            if (rule.column != first.column || rule.algorithm.name != first.algorithm.name ||
                (!rule.databases.isEmpty() && !first.databases.isEmpty() &&
                !sameSet(rule.databases, first.databases))) {
                let right = if (rule.databases.isEmpty()) { 'unknown' } else {
                    '[' + joinNames(rule.databases) + ']'
                }
                return 'tables ${first.table} ${left} and ${rule.table} ${right} use different ' +
                    'partition dimensions'
            }
        }
        ''
    }

    private static func joinNames(values: Array<String>): String {
        let builder = StringBuilder()
        var index: Int64 = 0
        for (value in values) {
            if (index > 0) {
                builder.append(',')
            }
            builder.append(value)
            index += 1
        }
        builder.toString()
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
