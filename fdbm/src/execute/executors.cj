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
import std.database.sql.*
import std.unicode.UnicodeStringExtension
import fountain::f_data.{Data, DataReal, DataString}
import fountain::f_dbd.common.{ColumnInfoImpl, DbdErrorCode, SqlTypes, UpdateResultPayload}
import fountain::f_log.LoggerFactory
import fountain::fdbm.config.{BootScriptWriter, IdMakerConfig}
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.idmaker.IdMakers
import fountain::fdbm.resources.NodeAccessor
import fountain::fdbm.route.*
import fountain::fdbm.sql.*
import fountain::f_dbm.{IdGenerator, PartitionAlgorithm}

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
    match (session.pinned) {
        case Some(pinned) => (pinned.connection, false)
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
    let targets = if (!databases.isEmpty()) { databases } else { resources.databases() }
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

    public init(resources: NodeAccessor, router: PartitionRouter, globals: GlobalTableRouter) {
        this.resources = resources
        this.router = router
        this.globals = globals
    }

    public func execute(session: DbdSession, statement: SelectStatement): ExecutionOutcome {
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return emptyOutcome(session, statement)
        }
        let databases = if (plan.kind == RouteKind.Broadcast) {
            // 全局表读任意副本即可（设计 §9.4），避免同一行被多副本重复返回
            if (globalOnly(statement, session.database) && !plan.databases.isEmpty()) {
                [plan.databases[0]]
            } else {
                plan.databases
            }
        } else if (plan.kind == RouteKind.Unroutable) {
            allDatabases(resources)
        } else {
            plan.databases
        }
        if (databases.isEmpty()) {
            return ExecutionOutcome(cursor: Some(QueryCursor([], [])), columns: [])
        }
        let sql = SqlRenderer.render(statement)
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

    private func emptyOutcome(session: DbdSession, statement: SelectStatement): ExecutionOutcome {
        let databases = allDatabases(resources)
        if (databases.isEmpty()) {
            return ExecutionOutcome(cursor: Some(QueryCursor([], [])), columns: [])
        }
        let sql = SqlRenderer.render(statement)
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
            let sql = SqlRenderer.render(statement)
            return ExecutionOutcome(update: Some(broadcastWrite(resources,
                globals.physicalDatabases(logical), sql)))
        }
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return ExecutionOutcome(update: Some(UpdateResultPayload(0, 0)))
        }
        if (plan.kind == RouteKind.Unroutable) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'update/delete requires a partition key condition')
        }
        let sql = SqlRenderer.render(statement)
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
            let sql = SqlRenderer.render(statement)
            return ExecutionOutcome(update: Some(broadcastWrite(resources,
                globals.physicalDatabases(logical), sql)))
        }
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return ExecutionOutcome(update: Some(UpdateResultPayload(0, 0)))
        }
        if (plan.kind == RouteKind.Unroutable) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'update/delete requires a partition key condition')
        }
        let rule = router.rule(logical, statement.table.name)
        let keys = match (rule) {
            case Some(found) => queryKeys(session, statement, found, plan.databases)
            case None => ArrayList<String>() // 未分库表：无缓存可失效
        }
        let sql = SqlRenderer.render(statement)
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
        rule: PartitionRule, databases: Array<String>): ArrayList<String> {
        let select = SelectStatement(false,
            [SelectItem(ColumnExpression(None, rule.column), None)],
            [statement.table], [], statement.condition, [], None, None)
        let sql = SqlRenderer.render(select)
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
        var rowCount: Int64 = 0
        var lastInsertId: Int64 = 0
        if (!statement.values.isEmpty()) {
            for (row in statement.values) {
                let single = fillAndRoute(session, statement, row, None)
                let result = executeSingle(session, single)
                rowCount += result.rowCount
                lastInsertId = result.lastInsertId
            }
        } else {
            let single = fillAndRoute(session, statement, [], statement.setPairs)
            let result = executeSingle(session, single)
            rowCount = result.rowCount
            lastInsertId = result.lastInsertId
        }
        ExecutionOutcome(update: Some(UpdateResultPayload(rowCount, lastInsertId)))
    }

    /**
     * `insert into t (...) select ...`：先**物化**全部行再关闭游标，然后逐行 INSERT。
     *
     * 不能边读游标边插入：游标持有物理连接，`maxSize` 默认 1 时同一池里再借一条会自锁。
     * 列清单必须显式给出（否则无法把结果列映射到目标列）；流列不做物化 → `UNSUPPORTED_SQL`。
     */
    private func insertFromSelect(session: DbdSession, statement: InsertStatement,
        query: SelectStatement): ExecutionOutcome {
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
        var rowCount: Int64 = 0
        var lastInsertId: Int64 = 0
        for (row in rows) {
            let single = fillAndRoute(session, statement, row, None)
            let result = executeSingle(session, single)
            rowCount += result.rowCount
            lastInsertId = result.lastInsertId
        }
        ExecutionOutcome(update: Some(UpdateResultPayload(rowCount, lastInsertId)))
    }

    private func fillAndRoute(session: DbdSession, statement: InsertStatement,
        row: Array<SqlExpression>, setPairs: ?Array<(String, SqlExpression)>): InsertStatement {
        let logical = DmlExecutor.logicalOf(statement.table, session.database)
        let rule = router.rule(logical, statement.table.name)
        let columns = ArrayList<String>()
        for (column in statement.columns) {
            columns.add(column)
        }
        let values = ArrayList<SqlExpression>()
        for (value in row) {
            values.add(value)
        }
        let pairs = ArrayList<(String, SqlExpression)>()
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
                    !columns.contains(found.column)
                } else if (hasPairs) {
                    var has = false
                    for ((column, _) in pairs) {
                        if (column == found.column) {
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
                    if (!columns.isEmpty()) {
                        columns.add(found.column)
                        values.add(literal)
                    } else if (hasPairs) {
                        pairs.add((found.column, literal))
                    }
                }
            case None => ()
        }
        let pairArray = if (hasPairs) { pairs.toArray() } else { Array<(String, SqlExpression)>() }
        InsertStatement(statement.table, columns.toArray(), [values.toArray()], pairArray, None)
    }

    private func idLiteral(generator: IdGenerator, algorithm: PartitionAlgorithm): Data {
        let name = algorithm.name
        if (name == 'step' || name == 'snowflake' || name == 'sequence') {
            return DataReal(generator.nextIntId())
        }
        DataString(generator.nextStringId())
    }

    private func executeSingle(session: DbdSession, statement: InsertStatement): UpdateResultPayload {
        let logical = DmlExecutor.logicalOf(statement.table, session.database)
        if (globals.isGlobal(logical, statement.table.name)) {
            let sql = SqlRenderer.render(statement)
            return broadcastWrite(resources, globals.physicalDatabases(logical), sql)
        }
        let plan = router.route(statement, session.database)
        if (plan.kind == RouteKind.Empty) {
            return UpdateResultPayload(0, 0)
        }
        if (plan.kind != RouteKind.Single && plan.kind != RouteKind.Multi) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED, 'insert cannot determine a target database')
        }
        let sql = SqlRenderer.render(statement)
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
}

/** SHOW：databases 用内存结果；tables 按驱动方言下推（设计 §9.5）。 */
protected class ShowExecutor {
    private let resources: NodeAccessor

    public init(resources: NodeAccessor) {
        this.resources = resources
    }

    public func execute(session: DbdSession, statement: ShowStatement): ExecutionOutcome {
        match (statement.showKind) {
            case ShowKind.Databases =>
                let concrete = [ColumnInfoImpl('Database', 'String', 0, 0, false, 0)]
                let infos = ArrayList<ColumnInfo>()
                for (info in concrete) {
                    infos.add(info)
                }
                let names = sortedNames(resources.databases())
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
                if (!resources.contains(database)) {
                    throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                        'unknown database \'${database}\'')
                }
                let sql = tablesSql(resources.driver(database), statement.like)
                let connection = resources.selectRead(database)
                let prepared = connection.prepareStatement(sql)
                let result = prepared.query()
                let infos = tableColumns(QueryCursor.columnsOf(result))
                let segment = CursorSegment(prepared, result, connection)
                ExecutionOutcome(cursor: Some(QueryCursor([segment], infos)), columns: infos)
        }
    }

    private static func tablesSql(driver: String, like: ?String): String {
        let pattern = match (like) {
            case Some(value) => Some(SqlRenderer.literal(DataString(value)))
            case None => None<String>
        }
        let name = driver.toLower()
        if (name == 'mysql' || name == 'mariadb') {
            return match (pattern) {
                case Some(value) => 'show tables like ${value}'
                case None => 'show tables'
            }
        }
        if (name == 'postgres' || name == 'postgresql' || name == 'pgsql' || name == 'opengauss') {
            let base = "select table_name from information_schema.tables where table_schema='public'"
            return match (pattern) {
                case Some(value) => '${base} and table_name like ${value}'
                case None => base
            }
        }
        throw FdbmException(DbdErrorCode.UNSUPPORTED_SQL,
            'show tables is not supported by driver \'${driver}\'')
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

    public init(resources: NodeAccessor, globals: GlobalTableRouter) {
        this.resources = resources
        this.globals = globals
    }

    /** DDL 广播到当前逻辑库的全部物理库；部分失败 → `DB_ERROR` 并列出成功/失败库。 */
    public func execute(session: DbdSession, statement: DdlStatement): ExecutionOutcome {
        let configured = globals.physicalDatabases(session.database)
        let databases = if (!configured.isEmpty()) { configured } else { resources.databases() }
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

    public init(resources: NodeAccessor) {
        this.resources = resources
    }

    public func execute(session: DbdSession, statement: SessionCtlStatement): ExecutionOutcome {
        match (statement.verb) {
            case SessionCtlVerb.Begin =>
                if (session.pinned.isSome()) {
                    throw FdbmException(DbdErrorCode.TX_STATE, 'the transaction has already begun')
                }
                let connection = resources.selectWrite(session.database)
                let pinned = PinnedConnection(connection)
                pinned.transactionOpen = true
                session.pinned = Some(pinned)
                let result = executeUpdate(connection, statement.sql)
                ExecutionOutcome(update: Some(UpdateResultPayload(result.rowCount, 0)))
            case SessionCtlVerb.Commit | SessionCtlVerb.Rollback =>
                match (session.pinned) {
                    case Some(pinned) =>
                        try {
                            let result = executeUpdate(pinned.connection, statement.sql)
                            ExecutionOutcome(update: Some(UpdateResultPayload(result.rowCount, 0)))
                        } finally {
                            pinned.close()
                            session.pinned = None
                        }
                    case None => throw FdbmException(DbdErrorCode.TX_STATE,
                        'cannot ${statement.sql}: the transaction has not begun')
                }
            case _ =>
                match (session.pinned) {
                    case Some(pinned) =>
                        let result = executeUpdate(pinned.connection, statement.sql)
                        ExecutionOutcome(update: Some(UpdateResultPayload(result.rowCount, 0)))
                    case None => throw FdbmException(DbdErrorCode.TX_STATE,
                        'cannot ${statement.sql}: the transaction has not begun')
                }
        }
    }
}
