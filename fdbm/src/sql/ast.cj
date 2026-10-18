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

/** `[table.]column` */
protected class ColumnExpression <: SqlExpression {
    public let table: ?String
    public let column: String

    public init(table: ?String, column: String) {
        this.table = table
        this.column = column
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

/** 表引用：`database` 缺省时由解析器补当前库（`key()` 使用）。 */
protected class TableRef {
    public let database: ?String
    public let name: String
    public let alias: ?String
    private let current: String

    public init(database: ?String, name: String, alias: ?String, current: String) {
        this.database = database
        this.name = name
        this.alias = alias
        this.current = current
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
    public let limit: ?Int64
    public let offset: ?Int64

    public init(distinct: Bool, columns: Array<SelectItem>, from: Array<TableRef>,
        joins: Array<JoinClause>, condition: ?SqlExpression, orderBy: Array<(SqlExpression, Bool)>,
        limit: ?Int64, offset: ?Int64) {
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
                result.add(table)
            }
            for (join in joins) {
                result.add(join.table)
            }
            result.toArray()
        }
    }
}

protected class InsertStatement <: SqlStatement {
    public let table: TableRef
    public let columns: Array<String>
    public let values: Array<Array<SqlExpression>>
    public let setPairs: Array<(String, SqlExpression)>
    public let fromSelect: ?SelectStatement

    public init(table: TableRef, columns: Array<String>, values: Array<Array<SqlExpression>>,
        setPairs: Array<(String, SqlExpression)>, fromSelect: ?SelectStatement) {
        this.table = table
        this.columns = columns
        this.values = values
        this.setPairs = setPairs
        this.fromSelect = fromSelect
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
