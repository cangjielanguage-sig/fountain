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
package fountain::fdbm.execute

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.database.sql.*
import std.unicode.UnicodeStringExtension
import fountain::f_data.{Data, DataReal, DataString}
import fountain::f_dbd.common.{ColumnInfoImpl, DbdErrorCode, SqlTypes, UpdateResultPayload}
import fountain::f_log.LoggerFactory
import fountain::fdbm.config.{BootScriptWriter, IdMakerConfig, LogicalCatalog}
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.idmaker.IdMakers
import fountain::fdbm.resources.NodeAccessor
import fountain::fdbm.route.*
import fountain::fdbm.sql.*
import fountain::f_dbm.{IdGenerator, IdGeneratorException, PartitionAlgorithm}

private let execLogger = LoggerFactory.getLogger('fountain::fdbm.execute')

/** 执行结果（设计 §9.2）：更新结果或游标二选一。 */
protected class ExecutionOutcome {
    private let update_: ?UpdateResultPayload
    private let cursor_: ?QueryCursor
    private let columns_: Array<ColumnInfoImpl>

    public init(update!: ?UpdateResultPayload = None, cursor!: ?QueryCursor = None,
        columns!: Array<ColumnInfoImpl> = []) {
        this.update_ = update
        this.cursor_ = cursor
        this.columns_ = columns
    }

    public prop update: ?UpdateResultPayload {
        get() {
            update_
        }
    }

    public prop cursor: ?QueryCursor {
        get() {
            cursor_
        }
    }

    public prop columns: Array<ColumnInfoImpl> {
        get() {
            columns_
        }
    }
}

/** 公共借还：pin 的连接优先，否则按读写方向从资源取。 */
func borrow(session: DbdSession, resources: NodeAccessor, database: String,
    write!: Bool = false): (Connection, Bool) {
    match (session.pinnedConnection()) {
        case Some(pinned) =>
            // 事务只作用于 begin 时 pin 的物理库：跨片语句必须拒绝，不能把 SQL 发到本片（W-1）
            if (pinned.database != database) {
                throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                    'statement targets physical database \'${database}\' but the transaction is pinned to ' +
                    '\'${pinned.database}\'')
            }
            (pinned.connection, false)
        case None =>
            let connection = if (write) {
                resources.selectWrite(database)
            } else {
                resources.selectRead(database)
            }
            (connection, true)
    }
}

func allDatabases(resources: NodeAccessor): Array<String> {
    resources.databases()
}

/**
 * 事务 pin 只对应一个物理库：需要访问多于一个物理库的语句必须拒绝（D04）。
 *
 * 拒绝而不是"在 pin 连接上重复执行"——后者会把同一 SQL 在同一库上执行 N 次并累加 rowCount。
 */
func ensurePinnedTargets(session: DbdSession, count: Int64, what: String): Unit {
    if (session.isPinned() && count > 1) {
        throw FdbmException(DbdErrorCode.ROUTE_FAILED,
            '${what} spanning ${count} physical databases is not allowed inside a transaction')
    }
}

/**
 * 目标库方言（设计 D2）：启动校验保证全节点同一驱动，取首个目标库即可。
 *
 * 没有目标库时返回 `Unknown`（引用标识符按 SQL 标准双引号渲染）。
 */
func dialectOf(resources: NodeAccessor, databases: Array<String>): SqlDialect {
    if (databases.isEmpty()) {
        return SqlDialect.Unknown
    }
    SqlDialects.ofDriver(resources.driver(databases[0]))
}

/** 物理库集合的确定性首项（按名称排序后的最小项）。 */
func smallestName(databases: Array<String>): String {
    var value = databases[0]
    for (candidate in databases) {
        if (candidate < value) {
            value = candidate
        }
    }
    value
}

/** G25：全局表写在事务内走独立连接、各自提交（无 2PC），首次发生时记 WARN。 */
func warnPinnedGlobalWrite(session: DbdSession): Unit {
    if (session.isPinned()) {
        execLogger.warn('global table write inside a transaction uses an independent connection and ' +
            'commits on its own; rollback will not undo it (see design §9.4)')
    }
}

/** `Unroutable` 的补充说明（G27：跨逻辑库/不同分片空间）。 */
func reasonSuffix(plan: RoutePlan): String {
    if (plan.reason.isEmpty()) {
        ''
    } else {
        ': ${plan.reason}'
    }
}

/** 驱动返回的单格值 → `Int64`（`lastInsertId` / `count(*)` 用）；不可转换时 `None`。 */
func int64Of(data: Data): ?Int64 {
    match (data) {
        case real: DataReal => Some(real.toInt64())
        case text: DataString => Int64.tryParse(text.data)
        case _ => None<Int64>
    }
}

/** 执行一条 UPDATE 并关闭语句句柄（避免真实驱动的句柄泄漏）。 */
func executeUpdate(connection: Connection, sql: String): UpdateResult {
    let statement = connection.prepareStatement(sql)
    try {
        let result = statement.update()
        statement.close()
        return result
    } catch (e: Exception) {
        try {
            statement.close()
        } catch (_: Exception) {
            ()
        }
        throw e
    }
}

/** 异常文本：`message` 为空时退回 `toString()`（部分驱动的 SqlException 只带 code）。 */
func detailOf(e: Exception): String {
    let message = e.message
    if (message.isEmpty()) {
        e.toString()
    } else {
        message
    }
}

/** 逗号拼接（错误信息用）。 */
func joinNames(names: ArrayList<String>): String {
    let text = StringBuilder()
    for (name in names) {
        if (text.size > 0) {
            text.append(', ')
        }
        text.append(name)
    }
    text.toString()
}

/**
 * 全局表写广播（设计 §9.4）：逐物理库、逐写节点执行；全部成功才成功。
 *
 * 部分成功 → `DB_ERROR` 并列出成功/失败库（无两阶段提交，列为限制）。
 * 广播写使用独立连接，不参与会话事务（"每库独立事务"）。
 */
func broadcastWrite(resources: NodeAccessor, databases: Array<String>,
    sql: String): UpdateResultPayload {
    // 广播范围必须由逻辑库解析得出；空集合说明目标逻辑库没有物理库（不得回退到全部署）
    if (databases.isEmpty()) {
        throw FdbmException(DbdErrorCode.ROUTE_FAILED, 'the target logical database has no physical database')
    }
    let targets = databases
    let succeeded = ArrayList<String>()
    let failed = ArrayList<String>()
    var rowCount: Int64 = 0
    var lastInsertId: Int64 = 0
    var firstError = ''
    for (database in targets) {
        var connections = Array<Connection>()
        try {
            connections = resources.selectAllWrite(database)
            for (connection in connections) {
                let result = executeUpdate(connection, sql)
                rowCount += result.rowCount
                lastInsertId = result.lastInsertId
            }
            succeeded.add(database)
        } catch (e: Exception) {
            failed.add(database)
            execLogger.warn('global table write failed on ${database}: ${detailOf(e)}')
            if (firstError.isEmpty()) {
                firstError = detailOf(e)
            }
        } finally {
            for (connection in connections) {
                try {
                    connection.close()
                } catch (_: Exception) {
                    ()
                }
            }
        }
    }
    if (!failed.isEmpty()) {
        throw FdbmException(DbdErrorCode.DB_ERROR,
            'global table write partially failed; success: [${joinNames(succeeded)}]; ' +
            'failed: [${joinNames(failed)}]: ${firstError}')
    }
    UpdateResultPayload(rowCount, lastInsertId)
}

/** SELECT（设计 §9.3）：Single/Multi/Broadcast 共用多段游标；Empty 只取列信息。 */
protected class SelectExecutor {
    private let resources: NodeAccessor
    private let router: PartitionRouter
    private let globals: GlobalTableRouter
    private let catalog: ?LogicalCatalog

    public init(resources: NodeAccessor, router: PartitionRouter, globals: GlobalTableRouter,
        catalog!: ?LogicalCatalog = None) {
        this.resources = resources
        this.router = router
        this.globals = globals
        this.catalog = catalog
    }

    public func execute(session: DbdSession, statement: SelectStatement): ExecutionOutcome {
        if (isCountOnly(statement)) {
            return executeCount(session, statement)
        }
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return emptyOutcome(session, statement)
        }
        let databases = targetDatabases(statement, plan, session)
        if (databases.isEmpty()) {
            return ExecutionOutcome(cursor: Some(QueryCursor([], [])), columns: [])
        }
        ensurePinnedTargets(session, databases.size, 'select')
        // 派生表 + 分页只在单目标下推；多库下发 limit/offset 会按分片截断（设计 D6）
        if (hasDerivedTable(statement) &&
            (statement.limit.isSome() || statement.offset.isSome()) && databases.size > 1) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'derived table paging cannot be pushed down to ${databases.size} physical databases')
        }
        let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialectOf(resources, databases))
        let segments = ArrayList<CursorSegment>()
        var infos: Array<ColumnInfoImpl> = []
        try {
            for (database in databases) {
                let segment = openSegment(session, database, sql)
                segments.add(segment)
            }
            infos = QueryCursor.columnsOf(segments[0].result)
        } catch (e: Exception) {
            for (segment in segments) {
                segment.close()
            }
            throw e
        }
        ExecutionOutcome(cursor: Some(QueryCursor(segments.toArray(), infos)), columns: infos)
    }

    /** 语句是否只引用全局表（读只需任一副本）。 */
    private func globalOnly(statement: SelectStatement, currentDatabase: String): Bool {
        if (statement.tables.isEmpty()) {
            return false
        }
        for (table in statement.tables) {
            let logical = match (table.database) {
                case Some(database) => database
                case None => currentDatabase
            }
            if (!globals.isGlobal(logical, table.name)) {
                return false
            }
        }
        true
    }

    /** 路由计划 → 实际下推的物理库（全局表读只取一份副本）。 */
    private func targetDatabases(statement: SelectStatement, plan: RoutePlan,
        session: DbdSession): Array<String> {
        if (plan.kind == RouteKind.Broadcast) {
            if (globalOnly(statement, session.database) && !plan.databases.isEmpty()) {
                return [plan.databases[0]]
            }
            return plan.databases
        }
        if (plan.kind == RouteKind.Unroutable) {
            return scopeOf(statement, session)
        }
        plan.databases
    }

    /**
     * `Unroutable` 广播范围：该语句所属**逻辑库**的物理库集合，绝不跨到别的逻辑库（D05）。
     * 未知逻辑库 → `ROUTE_FAILED`（收紧，登记为已知变更）。
     */
    private func scopeOf(statement: SelectStatement, session: DbdSession): Array<String> {
        let logical = if (statement.from.isEmpty()) {
            session.database
        } else {
            DmlExecutor.logicalOf(statement.from[0], session.database)
        }
        match (catalog) {
            case Some(value) =>
                match (value.physicals(logical)) {
                    case Some(databases) => databases
                    case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                        'unknown database \'${logical}\'')
                }
            case None => allDatabases(resources)
        }
    }

    /** `select count(*) ...`：逐库下推并求和，返回一行的内存结果（设计 D6）。 */
    private func executeCount(session: DbdSession, statement: SelectStatement): ExecutionOutcome {
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return countOutcome(0)
        }
        let databases = targetDatabases(statement, plan, session)
        if (databases.isEmpty()) {
            return countOutcome(0)
        }
        // 事务 pin 只对应一个物理库，跨库求和会得到不完整计数
        ensurePinnedTargets(session, databases.size, 'count(*)')
        let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialectOf(resources, databases))
        var total: Int64 = 0
        for (database in databases) {
            let (connection, owns) = borrow(session, resources, database)
            try {
                total += queryCount(connection, sql)
            } finally {
                if (owns) {
                    connection.close()
                }
            }
        }
        countOutcome(total)
    }

    private func queryCount(connection: Connection, sql: String): Int64 {
        let prepared = connection.prepareStatement(sql)
        var result: ?QueryResult = None
        try {
            let query = prepared.query()
            result = Some(query)
            if (!query.next()) {
                return 0
            }
            let cell = SqlTypes.readData(query, 0, query.columnInfos[0].typeName)
            match (int64Of(cell)) {
                case Some(value) => value
                case None => throw FdbmException(DbdErrorCode.CONVERSION,
                    'count(*) did not return an integer')
            }
        } finally {
            match (result) {
                case Some(query) =>
                    try {
                        query.close()
                    } catch (_: Exception) {
                        ()
                    }
                case None => ()
            }
            try {
                prepared.close()
            } catch (_: Exception) {
                ()
            }
        }
    }

    private func countOutcome(count: Int64): ExecutionOutcome {
        let infos = [ColumnInfoImpl('count', 'Int64', 0, 0, false, 0)]
        let columns = ArrayList<ColumnInfo>()
        for (info in infos) {
            columns.add(info)
        }
        let rows = ArrayList<Array<Data>>()
        rows.add([DataReal(count)])
        let result = MemoryQueryResult(columns.toArray(), rows.toArray())
        ExecutionOutcome(cursor: Some(QueryCursor([], infos, memory: Some(result))), columns: infos)
    }

    private static func isCountOnly(statement: SelectStatement): Bool {
        statement.columns.size == 1 && statement.columns[0].expression is CountExpression
    }

    private static func hasDerivedTable(statement: SelectStatement): Bool {
        for (table in statement.from) {
            if (table.derived.isSome()) {
                return true
            }
        }
        false
    }

    private func emptyOutcome(session: DbdSession, statement: SelectStatement): ExecutionOutcome {
        let databases = scopeOf(statement, session)
        if (databases.isEmpty()) {
            return ExecutionOutcome(cursor: Some(QueryCursor([], [])), columns: [])
        }
        let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialectOf(resources, databases))
        let segment = openSegment(session, databases[0], sql)
        let infos = QueryCursor.columnsOf(segment.result)
        segment.close()
        ExecutionOutcome(cursor: Some(QueryCursor([], infos, empty: true)), columns: infos)
    }

    private func openSegment(session: DbdSession, database: String, sql: String): CursorSegment {
        let (connection, owns) = borrow(session, resources, database)
        try {
            let statement = connection.prepareStatement(sql)
            try {
                let result = statement.query()
                CursorSegment(statement, result, connection, ownsConnection: owns)
            } catch (e: Exception) {
                statement.close()
                throw e
            }
        } catch (e: Exception) {
            if (owns) {
                try {
                    connection.close()
                } catch (_: Exception) {
                    ()
                }
            }
            throw e
        }
    }
}

/** UPDATE：全局表广播；分片表按计划逐库执行并累加 `rowCount`。 */
protected class DmlExecutor {
    private let resources: NodeAccessor
    private let router: PartitionRouter
    private let globals: GlobalTableRouter

    public init(resources: NodeAccessor, router: PartitionRouter, globals: GlobalTableRouter) {
        this.resources = resources
        this.router = router
        this.globals = globals
    }

    public func execute(session: DbdSession, statement: UpdateStatement): ExecutionOutcome {
        let logical = logicalOf(statement.table, session.database)
        if (globals.isGlobal(logical, statement.table.name)) {
            warnPinnedGlobalWrite(session)
            let targets = globals.physicalDatabases(logical)
            let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialectOf(resources, targets))
            return ExecutionOutcome(update: Some(broadcastWrite(resources, targets, sql)))
        }
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return ExecutionOutcome(update: Some(UpdateResultPayload(0, 0)))
        }
        if (plan.kind == RouteKind.Unroutable) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'update/delete requires a partition key condition' + reasonSuffix(plan))
        }
        ensurePinnedTargets(session, plan.databases.size, 'update')
        let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialectOf(resources, plan.databases))
        var rowCount: Int64 = 0
        var lastInsertId: Int64 = 0
        for (database in plan.databases) {
            let (connection, owns) = borrow(session, resources, database, write: true)
            try {
                let result = executeUpdate(connection, sql)
                rowCount += result.rowCount
                lastInsertId = result.lastInsertId
            } finally {
                if (owns) {
                    connection.close()
                }
            }
        }
        ExecutionOutcome(update: Some(UpdateResultPayload(rowCount, lastInsertId)))
    }

    static func logicalOf(table: TableRef, currentDatabase: String): String {
        match (table.database) {
            case Some(database) => database
            case None => currentDatabase
        }
    }
}

/**
 * DELETE（设计 §6.2/§9.3 的三步顺序）：
 * ① 先查受影响行的分库键；② 逐库删除并累加；③ 删除缓存条目。
 *
 * 全局表没有分库键，直接广播删除；未分库表跳过键查询与缓存。
 */
protected class DeleteExecutor {
    private let resources: NodeAccessor
    private let router: PartitionRouter
    private let globals: GlobalTableRouter

    public init(resources: NodeAccessor, router: PartitionRouter, globals: GlobalTableRouter) {
        this.resources = resources
        this.router = router
        this.globals = globals
    }

    public func execute(session: DbdSession, statement: DeleteStatement): ExecutionOutcome {
        let logical = DmlExecutor.logicalOf(statement.table, session.database)
        if (globals.isGlobal(logical, statement.table.name)) {
            warnPinnedGlobalWrite(session)
            let targets = globals.physicalDatabases(logical)
            let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialectOf(resources, targets))
            return ExecutionOutcome(update: Some(broadcastWrite(resources, targets, sql)))
        }
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return ExecutionOutcome(update: Some(UpdateResultPayload(0, 0)))
        }
        if (plan.kind == RouteKind.Unroutable) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'update/delete requires a partition key condition' + reasonSuffix(plan))
        }
        ensurePinnedTargets(session, plan.databases.size, 'delete')
        let dialect = dialectOf(resources, plan.databases)
        let rule = router.rule(logical, statement.table.name)
        let keys = match (rule) {
            case Some(found) => queryKeys(session, statement, found, plan.databases, dialect)
            case None => ArrayList<String>() // 未分库表：无缓存可失效
        }
        let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialect)
        var rowCount: Int64 = 0
        var lastInsertId: Int64 = 0
        for (database in plan.databases) {
            let (connection, owns) = borrow(session, resources, database, write: true)
            try {
                let result = executeUpdate(connection, sql)
                rowCount += result.rowCount
                lastInsertId = result.lastInsertId
            } finally {
                if (owns) {
                    connection.close()
                }
            }
        }
        match (rule) {
            case Some(found) =>
                for (value in keys) {
                    router.invalidate(found, value)
                }
            case None => ()
        }
        ExecutionOutcome(update: Some(UpdateResultPayload(rowCount, lastInsertId)))
    }

    /** 第一步：`select <column> from <table> where ...`，逐库取键并去重。 */
    private func queryKeys(session: DbdSession, statement: DeleteStatement,
        rule: PartitionRule, databases: Array<String>, dialect: SqlDialect): ArrayList<String> {
        let select = SelectStatement(false,
            [SelectItem(ColumnExpression(None, rule.column), None)],
            [statement.table], [], statement.condition, [], None, None)
        let sql = SqlRenderer.render(select, unqualified: true, dialect: dialect)
        let keys = ArrayList<String>()
        for (database in databases) {
            let (connection, owns) = borrow(session, resources, database)
            var result: ?QueryResult = None
            try {
                let prepared = connection.prepareStatement(sql)
                try {
                    let query = prepared.query()
                    result = Some(query)
                    let typeName = query.columnInfos[0].typeName
                    while (query.next()) {
                        let cell = SqlTypes.readData(query, 0, typeName)
                        match (PartitionKeyExtractor.literalString(LiteralExpression(cell))) {
                            case Some(value) =>
                                if (!keys.contains(value)) {
                                    keys.add(value)
                                }
                            case None => ()
                        }
                    }
                } finally {
                    try {
                        prepared.close()
                    } catch (_: Exception) {
                        ()
                    }
                }
            } finally {
                match (result) {
                    case Some(query) =>
                        try {
                            query.close()
                        } catch (_: Exception) {
                            ()
                        }
                    case None => ()
                }
                if (owns) {
                    connection.close()
                }
            }
        }
        keys
    }
}

/** INSERT：逐行路由执行；缺分库列时由 ID 生成器补；`insert … select` 先物化再逐行插入。 */
protected class InsertExecutor {
    private let resources: NodeAccessor
    private let router: PartitionRouter
    private let globals: GlobalTableRouter
    private let selectExecutor: SelectExecutor
    private let idmaker: IdMakerConfig
    private let sequenceDatabase: String
    private let custom: HashMap<String, IdGenerator>

    public init(resources: NodeAccessor, router: PartitionRouter, globals: GlobalTableRouter,
        selectExecutor: SelectExecutor, idmaker: IdMakerConfig, sequenceDatabase: String,
        custom: HashMap<String, IdGenerator>) {
        this.resources = resources
        this.router = router
        this.globals = globals
        this.selectExecutor = selectExecutor
        this.idmaker = idmaker
        this.sequenceDatabase = sequenceDatabase
        this.custom = custom
    }

    public func execute(session: DbdSession, statement: InsertStatement): ExecutionOutcome {
        match (statement.fromSelect) {
            case Some(query) => insertFromSelect(session, statement, query)
            case None => insertRows(session, statement)
        }
    }

    private func insertRows(session: DbdSession, statement: InsertStatement): ExecutionOutcome {
        let statements = ArrayList<InsertStatement>()
        if (!statement.values.isEmpty()) {
            for (row in statement.values) {
                statements.add(fillAndRoute(session, statement, row, None))
            }
        } else {
            statements.add(fillAndRoute(session, statement, [], statement.setPairs))
        }
        ExecutionOutcome(update: Some(executeAll(session, statements.toArray())))
    }

    /**
     * 同库多行在同一事务内执行；跨库按库分组、每组一个事务（G24）。
     *
     * - 会话已 pin：沿用 pin 连接逐行执行（事务由会话控制）；
     * - `returning`：沿用逐行路径（要求单目标）；
     * - 任一行无法判定为单目标：退回逐行（由 `executeSingle` 保持既有语义）；
     * - 组间失败：回滚当前组，回 `DB_ERROR` 并列出已提交库（无 2PC）。
     */
    private func executeAll(session: DbdSession, statements: Array<InsertStatement>): UpdateResultPayload {
        if (statements.isEmpty()) {
            return UpdateResultPayload(0, 0)
        }
        if (session.isPinned() || !statements[0].returning.isEmpty()) {
            return executeOneByOne(session, statements)
        }
        let groups = HashMap<String, ArrayList<InsertStatement>>()
        let order = ArrayList<String>()
        for (statement in statements) {
            let plan = router.route(statement, session.database)
            if (plan.kind == RouteKind.Empty) {
                continue
            }
            if (plan.kind != RouteKind.Single) {
                return executeOneByOne(session, statements)
            }
            let database = plan.databases[0]
            let group = match (groups.get(database)) {
                case Some(existing) => existing
                case None =>
                    let created = ArrayList<InsertStatement>()
                    groups[database] = created
                    order.add(database)
                    created
            }
            group.add(statement)
        }
        var rowCount: Int64 = 0
        var lastInsertId: Int64 = 0
        let committed = ArrayList<String>()
        for (database in order) {
            let group = groups[database]
            let connection = resources.selectWrite(database)
            var began = false
            try {
                executeUpdate(connection, 'begin')
                began = true
                for (statement in group) {
                    let sql = SqlRenderer.render(statement, unqualified: true,
                        dialect: dialectOf(resources, [database]))
                    let result = executeUpdate(connection, sql)
                    rowCount += result.rowCount
                    lastInsertId = result.lastInsertId
                }
                executeUpdate(connection, 'commit')
                committed.add(database)
            } catch (e: Exception) {
                if (began) {
                    try {
                        executeUpdate(connection, 'rollback')
                    } catch (_: Exception) {
                        ()
                    }
                }
                try {
                    connection.close()
                } catch (_: Exception) {
                    ()
                }
                throw FdbmException(DbdErrorCode.DB_ERROR,
                    'insert group on \'${database}\' failed; committed: [${joinNames(committed)}]: ' +
                    '${detailOf(e)}')
            }
            try {
                connection.close()
            } catch (_: Exception) {
                ()
            }
        }
        UpdateResultPayload(rowCount, lastInsertId)
    }

    private func executeOneByOne(session: DbdSession,
        statements: Array<InsertStatement>): UpdateResultPayload {
        var rowCount: Int64 = 0
        var lastInsertId: Int64 = 0
        for (statement in statements) {
            let result = executeSingle(session, statement)
            rowCount += result.rowCount
            lastInsertId = result.lastInsertId
        }
        UpdateResultPayload(rowCount, lastInsertId)
    }

    /**
     * `insert into t (...) select ...`：先**物化**全部行再关闭游标，然后逐行 INSERT。
     *
     * 不能边读游标边插入：游标持有物理连接，`maxSize` 默认 1 时同一池里再借一条会自锁。
     * 列清单必须显式给出（否则无法把结果列映射到目标列）；流列不做物化 → `UNSUPPORTED_SQL`。
     */
    private func insertFromSelect(session: DbdSession, statement: InsertStatement,
        query: SelectStatement): ExecutionOutcome {
        if (!statement.returning.isEmpty()) {
            throw FdbmException(DbdErrorCode.UNSUPPORTED_SQL,
                'insert ... select ... returning is not supported')
        }
        if (statement.columns.isEmpty()) {
            throw FdbmException(DbdErrorCode.UNSUPPORTED_SQL,
                'insert ... select requires an explicit column list')
        }
        let outcome = selectExecutor.execute(session, query)
        let cursor = match (outcome.cursor) {
            case Some(value) => value
            case None => throw FdbmException(DbdErrorCode.INTERNAL,
                'insert ... select returned no cursor')
        }
        let rows = ArrayList<Array<SqlExpression>>()
        try {
            for (info in cursor.columnInfos) {
                if (info.typeName == 'InputStream' || info.typeName == 'std.io.InputStream') {
                    throw FdbmException(DbdErrorCode.UNSUPPORTED_SQL,
                        'insert ... select cannot materialize stream column \'${info.name}\'')
                }
            }
            while (cursor.next()) {
                let cells = ArrayList<SqlExpression>()
                var index: Int64 = 0
                while (index < cursor.columnInfos.size) {
                    cells.add(LiteralExpression(cursor.cell(index, 0)))
                    index += 1
                }
                rows.add(cells.toArray())
            }
        } finally {
            cursor.close()
        }
        if (rows.isEmpty()) {
            return ExecutionOutcome(update: Some(UpdateResultPayload(0, 0)))
        }
        let statements = ArrayList<InsertStatement>()
        for (row in rows) {
            statements.add(fillAndRoute(session, statement, row, None))
        }
        ExecutionOutcome(update: Some(executeAll(session, statements.toArray())))
    }

    private func fillAndRoute(session: DbdSession, statement: InsertStatement,
        row: Array<SqlExpression>, setPairs: ?Array<(Identifier, SqlExpression)>): InsertStatement {
        let logical = DmlExecutor.logicalOf(statement.table, session.database)
        let rule = router.rule(logical, statement.table.name)
        let columns = ArrayList<Identifier>()
        for (column in statement.columns) {
            columns.add(column)
        }
        let values = ArrayList<SqlExpression>()
        for (value in row) {
            values.add(value)
        }
        let pairs = ArrayList<(Identifier, SqlExpression)>()
        var hasPairs = false
        match (setPairs) {
            case Some(existing) =>
                hasPairs = true
                for (pair in existing) {
                    pairs.add(pair)
                }
            case None => ()
        }
        match (rule) {
            case Some(found) =>
                let missing = if (!columns.isEmpty()) {
                    !hasColumn(columns, found.column)
                } else if (hasPairs) {
                    var has = false
                    for ((column, _) in pairs) {
                        if (column.name == found.column) {
                            has = true
                        }
                    }
                    !has
                } else {
                    true
                }
                if (missing) {
                    let generator = match (IdMakers.forTable(idmaker, resources, found.database,
                        found.table, custom, sequenceDatabase)) {
                        case Some(value) => value
                        case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                            'insert into \'${found.table}\' has no value for partition column ' +
                            '\'${found.column}\' and no usable id generator')
                    }
                    let literal: SqlExpression = LiteralExpression(idLiteral(generator, found.algorithm))
                    let identifier = Identifier(found.column)
                    if (!columns.isEmpty()) {
                        columns.add(identifier)
                        values.add(literal)
                    } else if (hasPairs) {
                        pairs.add((identifier, literal))
                    }
                }
            case None => ()
        }
        let pairArray = if (hasPairs) { pairs.toArray() } else { Array<(Identifier, SqlExpression)>() }
        // 重建语句必须显式带上 returning，否则绑定/逐行拆分后会被静默丢弃（设计 D6）
        InsertStatement(statement.table, columns.toArray(), [values.toArray()], pairArray, None,
            returning: statement.returning)
    }

    private static func hasColumn(columns: ArrayList<Identifier>, name: String): Bool {
        for (column in columns) {
            if (column.name == name) {
                return true
            }
        }
        false
    }

    /**
     * 生成器能力按**实际实现**协商（D11）：期望整型的算法先试 `nextIntId`，失败回退字符串；
     * 期望字符串的算法反之。两者都抛 `IdGeneratorException` → `ID_GENERATOR`（含生成器名）。
     */
    private func idLiteral(generator: IdGenerator, algorithm: PartitionAlgorithm): Data {
        let name = algorithm.name
        let wantsInt = name == 'step' || name == 'snowflake' || name == 'sequence'
        if (wantsInt) {
            match (tryIntId(generator)) {
                case Some(value) => return DataReal(value)
                case None => ()
            }
            match (tryStringId(generator)) {
                case Some(value) => return DataString(value)
                case None => ()
            }
        } else {
            match (tryStringId(generator)) {
                case Some(value) => return DataString(value)
                case None => ()
            }
            match (tryIntId(generator)) {
                case Some(value) => return DataReal(value)
                case None => ()
            }
        }
        throw FdbmException(DbdErrorCode.ID_GENERATOR,
            'id generator \'${generator.name}\' supports neither int nor string id')
    }

    private static func tryIntId(generator: IdGenerator): ?Int64 {
        try {
            Some(generator.nextIntId())
        } catch (_: IdGeneratorException) {
            None<Int64>
        }
    }

    private static func tryStringId(generator: IdGenerator): ?String {
        try {
            Some(generator.nextStringId())
        } catch (_: IdGeneratorException) {
            None<String>
        }
    }

    private func executeSingle(session: DbdSession, statement: InsertStatement): UpdateResultPayload {
        let logical = DmlExecutor.logicalOf(statement.table, session.database)
        let isGlobal = globals.isGlobal(logical, statement.table.name)
        if (!statement.returning.isEmpty()) {
            // 先判方言再判路由：MySQL 上即使目标是全局表也应报「不支持」
            let databases = resources.databases()
            if (dialectOf(resources, databases) != SqlDialect.Postgres) {
                let driver = if (databases.isEmpty()) { 'unknown' } else { resources.driver(databases[0]) }
                throw FdbmException(DbdErrorCode.UNSUPPORTED_SQL,
                    'returning is only supported by the PostgreSQL family (driver \'${driver}\')')
            }
            if (isGlobal) {
                throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                    'returning cannot be used with a global table write')
            }
        }
        if (isGlobal) {
            warnPinnedGlobalWrite(session)
            let targets = globals.physicalDatabases(logical)
            let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialectOf(resources, targets))
            return broadcastWrite(resources, targets, sql)
        }
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return UpdateResultPayload(0, 0)
        }
        if (plan.kind != RouteKind.Single && plan.kind != RouteKind.Multi) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED, 'insert cannot determine a target database')
        }
        if (!statement.returning.isEmpty() && plan.kind != RouteKind.Single) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'returning requires a single target database')
        }
        let sql = SqlRenderer.render(statement, unqualified: true, dialect: dialectOf(resources, plan.databases))
        if (!statement.returning.isEmpty()) {
            return executeReturning(session, sql, plan.databases[0])
        }
        var rowCount: Int64 = 0
        var lastInsertId: Int64 = 0
        for (database in plan.databases) {
            let (connection, owns) = borrow(session, resources, database, write: true)
            try {
                let result = executeUpdate(connection, sql)
                rowCount += result.rowCount
                lastInsertId = result.lastInsertId
            } finally {
                if (owns) {
                    connection.close()
                }
            }
        }
        UpdateResultPayload(rowCount, lastInsertId)
    }

    /** `insert ... returning`：走 query 通道，`lastInsertId` 取首行首列（设计 D6）。 */
    private func executeReturning(session: DbdSession, sql: String,
        database: String): UpdateResultPayload {
        let (connection, owns) = borrow(session, resources, database, write: true)
        var result: ?QueryResult = None
        try {
            let prepared = connection.prepareStatement(sql)
            try {
                let query = prepared.query()
                result = Some(query)
                var rowCount: Int64 = 0
                var lastInsertId: Int64 = 0
                while (query.next()) {
                    rowCount += 1
                    if (rowCount == 1) {
                        let cell = SqlTypes.readData(query, 0, query.columnInfos[0].typeName)
                        lastInsertId = match (int64Of(cell)) {
                            case Some(value) => value
                            case None => throw FdbmException(DbdErrorCode.CONVERSION,
                                'returning column is not an integer')
                        }
                    }
                }
                UpdateResultPayload(rowCount, lastInsertId)
            } finally {
                try {
                    prepared.close()
                } catch (_: Exception) {
                    ()
                }
            }
        } finally {
            match (result) {
                case Some(query) =>
                    try {
                        query.close()
                    } catch (_: Exception) {
                        ()
                    }
                case None => ()
            }
            if (owns) {
                connection.close()
            }
        }
    }
}

/** SHOW：databases 用逻辑库清单；tables 按驱动方言下推（设计 §9.5 / D03）。 */
protected class ShowExecutor {
    private let resources: NodeAccessor
    private let catalog: ?LogicalCatalog

    public init(resources: NodeAccessor, catalog!: ?LogicalCatalog = None) {
        this.resources = resources
        this.catalog = catalog
    }

    public func execute(session: DbdSession, statement: ShowStatement): ExecutionOutcome {
        match (statement.showKind) {
            case ShowKind.Databases =>
                let concrete = [ColumnInfoImpl('Database', 'String', 0, 0, false, 0)]
                let infos = ArrayList<ColumnInfo>()
                for (info in concrete) {
                    infos.add(info)
                }
                let names = match (catalog) {
                    case Some(value) => value.names()
                    case None => sortedNames(resources.databases())
                }
                let rows = ArrayList<Array<Data>>()
                for (database in names) {
                    rows.add([DataString(database)])
                }
                let result = MemoryQueryResult(infos.toArray(), rows.toArray())
                let cursor = QueryCursor([], concrete, memory: Some(result))
                ExecutionOutcome(cursor: Some(cursor), columns: concrete)
            case ShowKind.Tables =>
                let database = match (statement.database) {
                    case Some(value) => value
                    case None => session.database
                }
                let physical = match (catalog) {
                    case Some(value) =>
                        match (value.physicals(database)) {
                            case Some(databases) => databases[0]
                            case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                                'unknown database \'${database}\'')
                        }
                    case None =>
                        if (!resources.contains(database)) {
                            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                                'unknown database \'${database}\'')
                        }
                        database
                }
                let sql = tablesSql(resources.driver(physical), statement.like)
                // G23：任一步失败都要归还连接与语句句柄（否则 maxSize=1 时后续请求全部超时）
                let connection = resources.selectRead(physical)
                var prepared: ?Statement = None
                try {
                    let statement_ = connection.prepareStatement(sql)
                    prepared = Some(statement_)
                    let result = statement_.query()
                    let infos = tableColumns(QueryCursor.columnsOf(result))
                    let segment = CursorSegment(statement_, result, connection)
                    ExecutionOutcome(cursor: Some(QueryCursor([segment], infos)), columns: infos)
                } catch (e: Exception) {
                    match (prepared) {
                        case Some(statement_) =>
                            try {
                                statement_.close()
                            } catch (_: Exception) {}
                        case None => ()
                    }
                    try {
                        connection.close()
                    } catch (_: Exception) {}
                    throw e
                }
        }
    }

    private static func tablesSql(driver: String, like: ?String): String {
        let pattern = match (like) {
            case Some(value) => Some(SqlRenderer.literal(DataString(value)))
            case None => None<String>
        }
        match (SqlDialects.ofDriver(driver)) {
            case SqlDialect.MySql =>
                match (pattern) {
                    case Some(value) => 'show tables like ${value}'
                    case None => 'show tables'
                }
            case SqlDialect.Postgres =>
                let base = "select table_name from information_schema.tables where table_schema='public'"
                match (pattern) {
                    case Some(value) => '${base} and table_name like ${value}'
                    case None => base
                }
            case SqlDialect.Unknown =>
                throw FdbmException(DbdErrorCode.UNSUPPORTED_SQL,
                    'show tables is not supported by driver \'${driver}\'')
        }
    }

    /** 结果列名统一为 `table_name`（设计 §9.5）。 */
    private static func tableColumns(columns: Array<ColumnInfoImpl>): Array<ColumnInfoImpl> {
        let infos = ArrayList<ColumnInfoImpl>()
        var index: Int64 = 0
        for (info in columns) {
            let name = if (index == 0) { 'table_name' } else { info.name }
            infos.add(ColumnInfoImpl(name, info.typeName, info.length, info.scale, info.nullable,
                info.displaySize))
            index += 1
        }
        infos.toArray()
    }

    /** 按名称排序的副本（不改动 `NodeAccessor` 的内部数组）。 */
    static func sortedNames(source: Array<String>): Array<String> {
        let names = ArrayList<String>()
        for (name in source) {
            names.add(name)
        }
        var i: Int64 = 1
        while (i < names.size) {
            let current = names[i]
            var j = i - 1
            while (j >= 0 && names[j] > current) {
                names[j + 1] = names[j]
                j -= 1
            }
            names[j + 1] = current
            i += 1
        }
        names.toArray()
    }
}

/** `export k=v`：白名单校验 → 写入内存配置 → 分块落盘（设计 §3.5）。 */
protected class ExportExecutor {
    private let bootScript: ?BootScriptWriter

    public init(bootScript: ?BootScriptWriter) {
        this.bootScript = bootScript
    }

    public func execute(statement: ExportStatement): ExecutionOutcome {
        match (bootScript) {
            case Some(writer) =>
                writer.set(statement.key, statement.value)
                writer.flush()
                ExecutionOutcome(update: Some(UpdateResultPayload(0, 0)))
            case None => throw FdbmException(DbdErrorCode.CONFIG,
                'export requires a writable boot script')
        }
    }
}

/** DDL：广播到全部物理库，全部成功才算成功。 */
protected class DdlExecutor {
    private let resources: NodeAccessor
    private let globals: GlobalTableRouter
    private let catalog: ?LogicalCatalog

    public init(resources: NodeAccessor, globals: GlobalTableRouter,
        catalog!: ?LogicalCatalog = None) {
        this.resources = resources
        this.globals = globals
        this.catalog = catalog
    }

    /** DDL 广播到当前逻辑库的全部物理库；部分失败 → `DB_ERROR` 并列出成功/失败库。 */
    public func execute(session: DbdSession, statement: DdlStatement): ExecutionOutcome {
        // DDL 必须广播到逻辑库全部物理库，无法在单目标事务内完成（D04）
        if (session.isPinned()) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'ddl is not allowed inside a transaction: it must be broadcast to every physical database')
        }
        let configured = globals.physicalDatabases(session.database)
        let databases = if (!configured.isEmpty()) {
            configured
        } else {
            match (catalog) {
                case Some(value) =>
                    match (value.physicals(session.database)) {
                        case Some(found) => found
                        case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                            'unknown database \'${session.database}\'')
                    }
                case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                    'the target logical database has no physical database')
            }
        }
        let succeeded = ArrayList<String>()
        let failed = ArrayList<String>()
        var rowCount: Int64 = 0
        var firstError = ''
        for (database in databases) {
            var connection: ?Connection = None
            var owns = false
            try {
                let (found, owned) = borrow(session, resources, database, write: true)
                connection = Some(found)
                owns = owned
                rowCount += executeUpdate(found, statement.sql).rowCount
                succeeded.add(database)
            } catch (e: Exception) {
                failed.add(database)
                execLogger.warn('ddl failed on ${database}: ${detailOf(e)}')
                if (firstError.isEmpty()) {
                    firstError = detailOf(e)
                }
            } finally {
                if (owns) {
                    match (connection) {
                        case Some(found) => found.close()
                        case None => ()
                    }
                }
            }
        }
        if (!failed.isEmpty()) {
            throw FdbmException(DbdErrorCode.DB_ERROR,
                'ddl partially failed; success: [${joinNames(succeeded)}]; ' +
                'failed: [${joinNames(failed)}]: ${firstError}')
        }
        ExecutionOutcome(update: Some(UpdateResultPayload(rowCount, 0)))
    }
}

/** 会话控制：begin 时 pin 写连接；commit/rollback 后解 pin。 */
protected class SessionCtlExecutor {
    private let resources: NodeAccessor
    private let catalog: ?LogicalCatalog

    public init(resources: NodeAccessor, catalog!: ?LogicalCatalog = None) {
        this.resources = resources
        this.catalog = catalog
    }

    /**
     * 事务 pin 的物理目标：会话逻辑库的**首个物理库**（排序后首项，跨进程确定）。
     *
     * pin 只对应一个物理库（D04），因此必须先把逻辑名解析成物理名；未知逻辑库 → `ROUTE_FAILED`。
     */
    private func pinTarget(session: DbdSession): String {
        match (catalog) {
            case Some(value) =>
                match (value.physicals(session.database)) {
                    case Some(databases) => smallestName(databases)
                    case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                        'unknown database \'${session.database}\'')
                }
            case None =>
                if (!resources.contains(session.database)) {
                    throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                        'unknown database \'${session.database}\'')
                }
                session.database
        }
    }

    public func execute(session: DbdSession, statement: SessionCtlStatement): ExecutionOutcome {
        match (statement.verb) {
            case SessionCtlVerb.Begin =>
                if (session.isPinned()) {
                    throw FdbmException(DbdErrorCode.TX_STATE, 'the transaction has already begun')
                }
                let target = pinTarget(session)
                let connection = resources.selectWrite(target)
                // 先让物理库接受 begin，成功后才 pin（G26：失败的 begin 不得留下 pin）
                try {
                    let result = executeUpdate(connection, statement.sql)
                    let pinned = PinnedConnection(connection, target)
                    pinned.transactionOpen = true
                    session.pin(pinned)
                    ExecutionOutcome(update: Some(UpdateResultPayload(result.rowCount, 0)))
                } catch (e: Exception) {
                    try {
                        connection.close()
                    } catch (_: Exception) {
                        ()
                    }
                    throw e
                }
            case SessionCtlVerb.Commit | SessionCtlVerb.Rollback =>
                match (session.pinnedConnection()) {
                    case Some(pinned) =>
                        try {
                            let result = executeUpdate(pinned.connection, statement.sql)
                            ExecutionOutcome(update: Some(UpdateResultPayload(result.rowCount, 0)))
                        } finally {
                            // 先解 pin 再归还：close 失败也不会让会话卡在"已 pin"（G26）
                            match (session.unpin()) {
                                case Some(value) => value.close()
                                case None => pinned.close()
                            }
                        }
                    case None => throw FdbmException(DbdErrorCode.TX_STATE,
                        'cannot ${statement.sql}: the transaction has not begun')
                }
            case _ =>
                match (session.pinnedConnection()) {
                    case Some(pinned) =>
                        let result = executeUpdate(pinned.connection, statement.sql)
                        ExecutionOutcome(update: Some(UpdateResultPayload(result.rowCount, 0)))
                    case None => throw FdbmException(DbdErrorCode.TX_STATE,
                        'cannot ${statement.sql}: the transaction has not begun')
                }
        }
    }
}
