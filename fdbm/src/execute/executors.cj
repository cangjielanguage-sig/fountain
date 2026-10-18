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
import fountain::f_dbd.common.{ColumnInfoImpl, DbdErrorCode, UpdateResultPayload}
import fountain::fdbm.config.{BootScriptWriter, IdMakerConfig}
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.idmaker.IdMakers
import fountain::fdbm.resources.NodeAccessor
import fountain::fdbm.route.*
import fountain::fdbm.sql.*
import fountain::f_dbm.{IdGenerator, PartitionAlgorithm}

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
        let databases = if (plan.kind == RouteKind.Broadcast || plan.kind == RouteKind.Unroutable) {
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

/** UPDATE / DELETE：按计划逐库执行并累加 `rowCount`。 */
protected class DmlExecutor {
    private let resources: NodeAccessor
    private let router: PartitionRouter

    public init(resources: NodeAccessor, router: PartitionRouter) {
        this.resources = resources
        this.router = router
    }

    public func execute(session: DbdSession, statement: SqlStatement): ExecutionOutcome {
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
                let result = connection.prepareStatement(sql).update()
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
}

/** INSERT：逐行路由执行；缺分库列时由 ID 生成器补；`insert … select` 先物化再逐行插入。 */
protected class InsertExecutor {
    private let resources: NodeAccessor
    private let router: PartitionRouter
    private let selectExecutor: SelectExecutor
    private let idmaker: IdMakerConfig
    private let sequenceDatabase: String
    private let custom: HashMap<String, IdGenerator>

    public init(resources: NodeAccessor, router: PartitionRouter, selectExecutor: SelectExecutor,
        idmaker: IdMakerConfig, sequenceDatabase: String, custom: HashMap<String, IdGenerator>) {
        this.resources = resources
        this.router = router
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
        let rule = router.rule(session.database, statement.table.name)
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
                let result = connection.prepareStatement(sql).update()
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

    public init(resources: NodeAccessor) {
        this.resources = resources
    }

    public func execute(session: DbdSession, statement: DdlStatement): ExecutionOutcome {
        var rowCount: Int64 = 0
        for (database in resources.databases()) {
            let (connection, owns) = borrow(session, resources, database, write: true)
            try {
                rowCount += connection.prepareStatement(statement.sql).update().rowCount
            } finally {
                if (owns) {
                    connection.close()
                }
            }
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
                let result = connection.prepareStatement(statement.sql).update()
                ExecutionOutcome(update: Some(UpdateResultPayload(result.rowCount, 0)))
            case SessionCtlVerb.Commit | SessionCtlVerb.Rollback =>
                match (session.pinned) {
                    case Some(pinned) =>
                        try {
                            let result = pinned.connection.prepareStatement(statement.sql).update()
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
                        let result = pinned.connection.prepareStatement(statement.sql).update()
                        ExecutionOutcome(update: Some(UpdateResultPayload(result.rowCount, 0)))
                    case None => throw FdbmException(DbdErrorCode.TX_STATE,
                        'cannot ${statement.sql}: the transaction has not begun')
                }
        }
    }
}
