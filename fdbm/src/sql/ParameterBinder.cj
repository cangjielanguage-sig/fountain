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
import fountain::f_data.DataAny
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException

/**
 * 把 `?` 替换为字面量（设计 §8.2）：路由与下推都只看绑定后的语句。
 *
 * 参数个数必须与占位符个数**完全一致**（多一个少一个都 `PROTOCOL`），顺序按出现先后。
 */
protected struct ParameterBinder {
    public static func bind(statement: SqlStatement, params: Array<DataAny>): SqlStatement {
        let context = BindContext(params)
        let result = context.bindStatement(statement)
        if (context.used != params.size) {
            throw FdbmException(DbdErrorCode.PROTOCOL,
                'parameter count mismatch: sql expects ${context.used}, got ${params.size}')
        }
        result
    }
}

class BindContext {
    private let params: Array<DataAny>
    var used: Int64 = 0

    init(params: Array<DataAny>) {
        this.params = params
    }

    func bindStatement(statement: SqlStatement): SqlStatement {
        match (statement) {
            case s: SelectStatement =>
                let columns = ArrayList<SelectItem>()
                for (item in s.columns) {
                    columns.add(SelectItem(bindExpression(item.expression), item.alias))
                }
                let joins = ArrayList<JoinClause>()
                for (join in s.joins) {
                    joins.add(JoinClause(join.joinType, join.table,
                        bindOptional(join.on)))
                }
                let orderBy = ArrayList<(SqlExpression, Bool)>()
                for ((expression, asc) in s.orderBy) {
                    orderBy.add((bindExpression(expression), asc))
                }
                SelectStatement(s.distinct, columns.toArray(), s.from, joins.toArray(),
                    bindOptional(s.condition), orderBy.toArray(), bindOptional(s.limit),
                    bindOptional(s.offset))
            case s: InsertStatement =>
                let rows = ArrayList<Array<SqlExpression>>()
                for (row in s.values) {
                    let bound = ArrayList<SqlExpression>()
                    for (value in row) {
                        bound.add(bindExpression(value))
                    }
                    rows.add(bound.toArray())
                }
                let setPairs = ArrayList<(String, SqlExpression)>()
                for ((column, value) in s.setPairs) {
                    setPairs.add((column, bindExpression(value)))
                }
                InsertStatement(s.table, s.columns, rows.toArray(), setPairs.toArray(),
                    match (s.fromSelect) {
                        case Some(select) => Some(bindSelect(select))
                        case None => None<SelectStatement>
                    })
            case s: UpdateStatement =>
                let assignments = ArrayList<(ColumnExpression, SqlExpression)>()
                for ((column, value) in s.assignments) {
                    assignments.add((column, bindExpression(value)))
                }
                let joins = ArrayList<JoinClause>()
                for (join in s.joins) {
                    joins.add(JoinClause(join.joinType, join.table, bindOptional(join.on)))
                }
                UpdateStatement(s.table, joins.toArray(), assignments.toArray(),
                    bindOptional(s.condition))
            case s: DeleteStatement =>
                let joins = ArrayList<JoinClause>()
                for (join in s.joins) {
                    joins.add(JoinClause(join.joinType, join.table, bindOptional(join.on)))
                }
                DeleteStatement(s.table, joins.toArray(), bindOptional(s.condition))
            case other => other
        }
    }

    private func bindSelect(select: SelectStatement): SelectStatement {
        match (bindStatement(select)) {
            case s: SelectStatement => s
            case _ => select
        }
    }

    private func bindOptional(expression: ?SqlExpression): ?SqlExpression {
        match (expression) {
            case Some(value) => Some(bindExpression(value))
            case None => None<SqlExpression>
        }
    }

    func bindExpression(expression: SqlExpression): SqlExpression {
        match (expression) {
            case p: ParameterExpression =>
                if (p.index >= params.size) {
                    throw FdbmException(DbdErrorCode.PROTOCOL,
                        'missing value for parameter ${p.index}')
                }
                used += 1
                LiteralExpression(params[p.index].data)
            case b: BinaryExpression =>
                BinaryExpression(b.op, bindExpression(b.left), bindExpression(b.right))
            case i: InExpression =>
                let values = ArrayList<SqlExpression>()
                for (value in i.values) {
                    values.add(bindExpression(value))
                }
                InExpression(bindExpression(i.operand), values.toArray(), negated: i.negated)
            case n: NotExpression =>
                NotExpression(bindExpression(n.operand))
            case f: FunctionExpression =>
                let args = ArrayList<SqlExpression>()
                for (arg in f.args) {
                    args.add(bindExpression(arg))
                }
                FunctionExpression(f.name, args.toArray())
            case other => other
        }
    }
}
