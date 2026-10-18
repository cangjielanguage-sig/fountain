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
package fountain::fdbm.sql

import std.collection.ArrayList
import fountain::f_data.Data

/** 语句种类（设计 §8.2）。 */
protected enum SqlKind {
    | Select | Insert | Update | Delete | Show | Ddl | Export | SessionCtl
}

/** 二元运算符。 */
protected enum BinaryOp <: Equatable<BinaryOp> & ToString {
    | And | Or | Eq | Neq | Lt | Lte | Gt | Gte | Like | Add | Sub | Mul | Div

    public operator func ==(other: BinaryOp): Bool {
        index() == other.index()
    }

    func index(): Int64 {
        match (this) {
            case And => 0
            case Or => 1
            case Eq => 2
            case Neq => 3
            case Lt => 4
            case Lte => 5
            case Gt => 6
            case Gte => 7
            case Like => 8
            case Add => 9
            case Sub => 10
            case Mul => 11
            case Div => 12
        }
    }

    public func toString(): String {
        match (this) {
            case And => 'and'
            case Or => 'or'
            case Eq => '='
            case Neq => '<>'
            case Lt => '<'
            case Lte => '<='
            case Gt => '>'
            case Gte => '>='
            case Like => 'like'
            case Add => '+'
            case Sub => '-'
            case Mul => '*'
            case Div => '/'
        }
    }
}

/** 表达式基接口。 */
protected interface SqlExpression {}

/** 标识符（列名 / 表名）：保留「原文是否带引用符」，渲染时按目标方言重写。 */
protected class Identifier <: Equatable<Identifier> {
    public let name: String
    public let quoted: Bool

    public init(name: String, quoted!: Bool = false) {
        this.name = name
        this.quoted = quoted
    }

    /** 相等按裸名比较（引用符不参与，避免 `"id"` 与 `id` 被当成两列）。 */
    public operator func ==(other: Identifier): Bool {
        name == other.name
    }

    public func equalsName(name: String): Bool {
        this.name == name
    }
}

/** `[table.]column` */
protected class ColumnExpression <: SqlExpression {
    public let table: ?String
    public let column: String
    /** 表名 / 列名在原文里是否带引用符。 */
    public let quoted: Bool

    public init(table: ?String, column: String, quoted!: Bool = false) {
        this.table = table
        this.column = column
        this.quoted = quoted
    }
}

/** 字面量（数字 / 字符串 / NULL / 布尔）。 */
protected class LiteralExpression <: SqlExpression {
    public let data: Data

    public init(data: Data) {
        this.data = data
    }
}

/** `?` 占位符（index 从 0 起，按出现顺序）。 */
protected class ParameterExpression <: SqlExpression {
    public let index: Int64

    public init(index: Int64) {
        this.index = index
    }
}

/** 二元表达式（`and` / `or` / 比较 / 算术）。 */
protected class BinaryExpression <: SqlExpression {
    public let op: BinaryOp
    public let left: SqlExpression
    public let right: SqlExpression

    public init(op: BinaryOp, left: SqlExpression, right: SqlExpression) {
        this.op = op
        this.left = left
        this.right = right
    }
}

/** `[not] in (...)` */
protected class InExpression <: SqlExpression {
    public let operand: SqlExpression
    public let values: Array<SqlExpression>
    public let negated: Bool

    public init(operand: SqlExpression, values: Array<SqlExpression>, negated!: Bool = false) {
        this.operand = operand
        this.values = values
        this.negated = negated
    }
}

/** 函数调用：仅用于识别后报 `UNSUPPORTED_SQL`（本期不支持函数）。 */
protected class FunctionExpression <: SqlExpression {
    public let name: String
    public let args: Array<SqlExpression>

    public init(name: String, args: Array<SqlExpression>) {
        this.name = name
        this.args = args
    }
}

/** `not <expr>`：路由层对 NOT 一律保守（无法判定时按 Unroutable）。 */
protected class NotExpression <: SqlExpression {
    public let operand: SqlExpression

    public init(operand: SqlExpression) {
        this.operand = operand
    }
}

/** `*`（select 列清单 / count(*) 的实参）。 */
protected class StarExpression <: SqlExpression {
    public init() {}
}

/** `count(*)`（f_orm 分页的唯一聚合；其它聚合仍不支持）。 */
protected class CountExpression <: SqlExpression {
    public init() {}
}

/** 表引用：`database` 缺省时由解析器补当前库（`key()` 使用）。 */
protected class TableRef {
    public let database: ?String
    public let name: String
    public let alias: ?String
    /** 表名是否带引用符。 */
    public let quoted: Bool
    /** `from ( <select> ) [as] alias` 的内层查询；普通表为 `None`。 */
    public let derived: ?SelectStatement
    private let current: String

    public init(database: ?String, name: String, alias: ?String, current: String,
        quoted!: Bool = false, derived!: ?SelectStatement = None) {
        this.database = database
        this.name = name
        this.alias = alias
        this.current = current
        this.quoted = quoted
        this.derived = derived
    }

    /** `'<database>.<name>'`（补全当前库后）；别名不参与。 */
    public func key(): String {
        let db = match (database) {
            case Some(value) => value
            case None => current
        }
        '${db}.${name}'
    }

    public func effectiveName(): String {
        match (alias) {
            case Some(value) => value
            case None => name
        }
    }

    /** 语句话术里的真实表集合：派生表递归展开为内层查询的表引用。 */
    public func collectTables(): Array<TableRef> {
        match (derived) {
            case Some(inner) => inner.tables
            case None => [this]
        }
    }

    /** 派生表替换内层查询（参数绑定后重建 AST 用）。 */
    public func withDerived(inner: SelectStatement): TableRef {
        TableRef(database, name, alias, current, quoted: quoted, derived: Some(inner))
    }
}

/** JOIN 子句。 */
protected enum JoinType <: Equatable<JoinType> {
    | Inner | Left | Right

    public operator func ==(other: JoinType): Bool {
        index() == other.index()
    }

    func index(): Int64 {
        match (this) {
            case Inner => 0
            case Left => 1
            case Right => 2
        }
    }
}

protected class JoinClause {
    public let joinType: JoinType
    public let table: TableRef
    public let on: ?SqlExpression

    public init(joinType: JoinType, table: TableRef, on: ?SqlExpression) {
        this.joinType = joinType
        this.table = table
        this.on = on
    }
}

/** SELECT 列项。 */
protected class SelectItem {
    public let expression: SqlExpression
    public let alias: ?String

    public init(expression: SqlExpression, alias: ?String) {
        this.expression = expression
        this.alias = alias
    }
}

/** 语句基接口。 */
protected interface SqlStatement {
    prop kind: SqlKind
    prop tables: Array<TableRef>
}

protected class SelectStatement <: SqlStatement {
    public let distinct: Bool
    public let columns: Array<SelectItem>
    public let from: Array<TableRef>
    public let joins: Array<JoinClause>
    public let condition: ?SqlExpression
    public let orderBy: Array<(SqlExpression, Bool)>   // (expr, asc)
    /** `limit` / `offset`：整数或 `?` 参数（绑定后为整数字面量）。 */
    public let limit: ?SqlExpression
    public let offset: ?SqlExpression

    public init(distinct: Bool, columns: Array<SelectItem>, from: Array<TableRef>,
        joins: Array<JoinClause>, condition: ?SqlExpression, orderBy: Array<(SqlExpression, Bool)>,
        limit: ?SqlExpression, offset: ?SqlExpression) {
        this.distinct = distinct
        this.columns = columns
        this.from = from
        this.joins = joins
        this.condition = condition
        this.orderBy = orderBy
        this.limit = limit
        this.offset = offset
    }

    public prop kind: SqlKind {
        get() {
            SqlKind.Select
        }
    }

    public prop tables: Array<TableRef> {
        get() {
            let result = ArrayList<TableRef>()
            for (table in from) {
                for (expanded in table.collectTables()) {
                    result.add(expanded)
                }
            }
            for (join in joins) {
                for (expanded in join.table.collectTables()) {
                    result.add(expanded)
                }
            }
            result.toArray()
        }
    }
}

protected class InsertStatement <: SqlStatement {
    public let table: TableRef
    public let columns: Array<Identifier>
    public let values: Array<Array<SqlExpression>>
    public let setPairs: Array<(Identifier, SqlExpression)>
    public let fromSelect: ?SelectStatement
    /** `returning <列>[, <列>...]`（仅 PostgreSQL 家族、单目标路由可执行）。 */
    public let returning: Array<Identifier>

    public init(table: TableRef, columns: Array<Identifier>, values: Array<Array<SqlExpression>>,
        setPairs: Array<(Identifier, SqlExpression)>, fromSelect: ?SelectStatement,
        returning!: Array<Identifier> = []) {
        this.table = table
        this.columns = columns
        this.values = values
        this.setPairs = setPairs
        this.fromSelect = fromSelect
        this.returning = returning
    }

    public prop kind: SqlKind {
        get() {
            SqlKind.Insert
        }
    }

    public prop tables: Array<TableRef> {
        get() {
            [table]
        }
    }
}

protected class UpdateStatement <: SqlStatement {
    public let table: TableRef
    public let joins: Array<JoinClause>
    public let assignments: Array<(ColumnExpression, SqlExpression)>
    public let condition: ?SqlExpression

    public init(table: TableRef, joins: Array<JoinClause>,
        assignments: Array<(ColumnExpression, SqlExpression)>, condition: ?SqlExpression) {
        this.table = table
        this.joins = joins
        this.assignments = assignments
        this.condition = condition
    }

    public prop kind: SqlKind {
        get() {
            SqlKind.Update
        }
    }

    public prop tables: Array<TableRef> {
        get() {
            let result = ArrayList<TableRef>()
            result.add(table)
            for (join in joins) {
                result.add(join.table)
            }
            result.toArray()
        }
    }
}

protected class DeleteStatement <: SqlStatement {
    public let table: TableRef
    public let joins: Array<JoinClause>
    public let condition: ?SqlExpression

    public init(table: TableRef, joins: Array<JoinClause>, condition: ?SqlExpression) {
        this.table = table
        this.joins = joins
        this.condition = condition
    }

    public prop kind: SqlKind {
        get() {
            SqlKind.Delete
        }
    }

    public prop tables: Array<TableRef> {
        get() {
            let result = ArrayList<TableRef>()
            result.add(table)
            for (join in joins) {
                result.add(join.table)
            }
            result.toArray()
        }
    }
}

protected enum ShowKind <: Equatable<ShowKind> {
    | Databases | Tables

    public operator func ==(other: ShowKind): Bool {
        index() == other.index()
    }

    func index(): Int64 {
        match (this) {
            case Databases => 0
            case Tables => 1
        }
    }
}

protected class ShowStatement <: SqlStatement {
    public let showKind: ShowKind
    public let database: ?String
    public let like: ?String

    public init(showKind: ShowKind, database: ?String, like: ?String) {
        this.showKind = showKind
        this.database = database
        this.like = like
    }

    public prop kind: SqlKind {
        get() {
            SqlKind.Show
        }
    }

    public prop tables: Array<TableRef> {
        get() {
            Array<TableRef>()
        }
    }
}

protected class DdlStatement <: SqlStatement {
    public let sql: String
    public let table: ?TableRef

    public init(sql: String, table: ?TableRef) {
        this.sql = sql
        this.table = table
    }

    public prop kind: SqlKind {
        get() {
            SqlKind.Ddl
        }
    }

    public prop tables: Array<TableRef> {
        get() {
            match (table) {
                case Some(value) => [value]
                case None => Array<TableRef>()
            }
        }
    }
}

protected class ExportStatement <: SqlStatement {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        this.key = key
        this.value = value
    }

    public prop kind: SqlKind {
        get() {
            SqlKind.Export
        }
    }

    public prop tables: Array<TableRef> {
        get() {
            Array<TableRef>()
        }
    }
}

protected enum SessionCtlVerb <: Equatable<SessionCtlVerb> {
    | Begin | Commit | Rollback | Savepoint | RollbackTo | Release

    public operator func ==(other: SessionCtlVerb): Bool {
        index() == other.index()
    }

    func index(): Int64 {
        match (this) {
            case Begin => 0
            case Commit => 1
            case Rollback => 2
            case Savepoint => 3
            case RollbackTo => 4
            case Release => 5
        }
    }
}

protected class SessionCtlStatement <: SqlStatement {
    public let verb: SessionCtlVerb
    public let savepoint: ?String
    public let sql: String

    public init(verb: SessionCtlVerb, savepoint: ?String, sql: String) {
        this.verb = verb
        this.savepoint = savepoint
        this.sql = sql
    }

    public prop kind: SqlKind {
        get() {
            SqlKind.SessionCtl
        }
    }

    public prop tables: Array<TableRef> {
        get() {
            Array<TableRef>()
        }
    }
}
