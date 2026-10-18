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
import fountain::f_data.{Data, DataBool, DataNone, DataReal, DataString}

/**
 * AST → SQL（设计 §8.2）：只做**方言无关**的原样重建，供下推与 `parse → render → parse` 往返。
 *
 * 二元/IN/NOT 一律加括号，渲染结果可能与原文不同，但语义等价、可再次解析。
 */
protected struct SqlRenderer {
    public static func render(statement: SqlStatement): String {
        match (statement) {
            case s: SelectStatement => renderSelect(s)
            case s: InsertStatement => renderInsert(s)
            case s: UpdateStatement => renderUpdate(s)
            case s: DeleteStatement => renderDelete(s)
            case s: ShowStatement => renderShow(s)
            case s: DdlStatement => s.sql
            case s: ExportStatement => 'export ${s.key}=${quoteText(s.value)}'
            case s: SessionCtlStatement => s.sql
            case _ => ''
        }
    }

    private static func renderSelect(statement: SelectStatement): String {
        let builder = StringBuilder()
        builder.append('select ')
        if (statement.distinct) {
            builder.append('distinct ')
        }
        var i: Int64 = 0
        while (i < statement.columns.size) {
            if (i > 0) {
                builder.append(', ')
            }
            let item = statement.columns[i]
            builder.append(renderExpression(item.expression))
            match (item.alias) {
                case Some(alias) => builder.append(' as ${alias}')
                case None => ()
            }
            i += 1
        }
        if (!statement.from.isEmpty()) {
            builder.append(' from ')
            i = 0
            while (i < statement.from.size) {
                if (i > 0) {
                    builder.append(', ')
                }
                builder.append(renderTable(statement.from[i]))
                i += 1
            }
            for (join in statement.joins) {
                builder.append(' ')
                match (join.joinType) {
                    case JoinType.Inner => builder.append('inner join ')
                    case JoinType.Left => builder.append('left join ')
                    case JoinType.Right => builder.append('right join ')
                }
                builder.append(renderTable(join.table))
                match (join.on) {
                    case Some(on) => builder.append(' on ${renderExpression(on)}')
                    case None => ()
                }
            }
        }
        match (statement.condition) {
            case Some(condition) => builder.append(' where ${renderExpression(condition)}')
            case None => ()
        }
        if (!statement.orderBy.isEmpty()) {
            builder.append(' order by ')
            i = 0
            while (i < statement.orderBy.size) {
                if (i > 0) {
                    builder.append(', ')
                }
                builder.append(renderExpression(statement.orderBy[i][0]))
                builder.append(if (statement.orderBy[i][1]) { ' asc' } else { ' desc' })
                i += 1
            }
        }
        match (statement.limit) {
            case Some(limit) => builder.append(' limit ${limit}')
            case None => ()
        }
        match (statement.offset) {
            case Some(offset) => builder.append(' offset ${offset}')
            case None => ()
        }
        builder.toString()
    }

    private static func renderInsert(statement: InsertStatement): String {
        let builder = StringBuilder()
        builder.append('insert into ${renderTable(statement.table)}')
        if (!statement.columns.isEmpty()) {
            builder.append(' (')
            var i: Int64 = 0
            while (i < statement.columns.size) {
                if (i > 0) {
                    builder.append(', ')
                }
                builder.append(statement.columns[i])
                i += 1
            }
            builder.append(')')
        }
        if (!statement.values.isEmpty()) {
            builder.append(' values ')
            var r: Int64 = 0
            while (r < statement.values.size) {
                if (r > 0) {
                    builder.append(', ')
                }
                builder.append('(')
                let row = statement.values[r]
                var c: Int64 = 0
                while (c < row.size) {
                    if (c > 0) {
                        builder.append(', ')
                    }
                    builder.append(renderExpression(row[c]))
                    c += 1
                }
                builder.append(')')
                r += 1
            }
        } else if (!statement.setPairs.isEmpty()) {
            builder.append(' set ')
            var i: Int64 = 0
            while (i < statement.setPairs.size) {
                if (i > 0) {
                    builder.append(', ')
                }
                builder.append('${statement.setPairs[i][0]} = ${renderExpression(statement.setPairs[i][1])}')
                i += 1
            }
        } else {
            match (statement.fromSelect) {
                case Some(select) => builder.append(' ${renderSelect(select)}')
                case None => ()
            }
        }
        builder.toString()
    }

    private static func renderUpdate(statement: UpdateStatement): String {
        let builder = StringBuilder()
        builder.append('update ${renderTable(statement.table)}')
        for (join in statement.joins) {
            builder.append(' ')
            match (join.joinType) {
                case JoinType.Inner => builder.append('inner join ')
                case JoinType.Left => builder.append('left join ')
                case JoinType.Right => builder.append('right join ')
            }
            builder.append(renderTable(join.table))
            match (join.on) {
                case Some(on) => builder.append(' on ${renderExpression(on)}')
                case None => ()
            }
        }
        builder.append(' set ')
        var i: Int64 = 0
        while (i < statement.assignments.size) {
            if (i > 0) {
                builder.append(', ')
            }
            let (column, value) = statement.assignments[i]
            builder.append('${renderExpression(column)} = ${renderExpression(value)}')
            i += 1
        }
        match (statement.condition) {
            case Some(condition) => builder.append(' where ${renderExpression(condition)}')
            case None => ()
        }
        builder.toString()
    }

    private static func renderDelete(statement: DeleteStatement): String {
        let builder = StringBuilder()
        builder.append('delete from ${renderTable(statement.table)}')
        for (join in statement.joins) {
            builder.append(' ')
            match (join.joinType) {
                case JoinType.Inner => builder.append('inner join ')
                case JoinType.Left => builder.append('left join ')
                case JoinType.Right => builder.append('right join ')
            }
            builder.append(renderTable(join.table))
            match (join.on) {
                case Some(on) => builder.append(' on ${renderExpression(on)}')
                case None => ()
            }
        }
        match (statement.condition) {
            case Some(condition) => builder.append(' where ${renderExpression(condition)}')
            case None => ()
        }
        builder.toString()
    }

    private static func renderShow(statement: ShowStatement): String {
        match (statement.showKind) {
            case ShowKind.Databases => 'show databases'
            case ShowKind.Tables =>
                let builder = StringBuilder('show tables')
                match (statement.database) {
                    case Some(database) => builder.append(' ${database}')
                    case None => ()
                }
                match (statement.like) {
                    case Some(pattern) => builder.append(' like ${quoteText(pattern)}')
                    case None => ()
                }
                builder.toString()
        }
    }

    static func renderTable(table: TableRef): String {
        let name = match (table.database) {
            case Some(database) => '${database}.${table.name}'
            case None => table.name
        }
        match (table.alias) {
            case Some(alias) => '${name} ${alias}'
            case None => name
        }
    }

    static func renderExpression(expression: SqlExpression): String {
        match (expression) {
            case c: ColumnExpression =>
                match (c.table) {
                    case Some(table) => '${table}.${c.column}'
                    case None => c.column
                }
            case l: LiteralExpression => literal(l.data)
            case p: ParameterExpression => '?'
            case b: BinaryExpression => '(${renderExpression(b.left)} ${b.op} ${renderExpression(b.right)})'
            case i: InExpression =>
                let builder = StringBuilder('(${renderExpression(i.operand)} ')
                if (i.negated) {
                    builder.append('not ')
                }
                builder.append('in (')
                var index: Int64 = 0
                while (index < i.values.size) {
                    if (index > 0) {
                        builder.append(', ')
                    }
                    builder.append(renderExpression(i.values[index]))
                    index += 1
                }
                builder.append('))')
                builder.toString()
            case n: NotExpression => '(not ${renderExpression(n.operand)})'
            case f: FunctionExpression =>
                let builder = StringBuilder('${f.name}(')
                var index: Int64 = 0
                while (index < f.args.size) {
                    if (index > 0) {
                        builder.append(', ')
                    }
                    builder.append(renderExpression(f.args[index]))
                    index += 1
                }
                builder.append(')')
                builder.toString()
            case _: StarExpression => '*'
            case _ => ''
        }
    }

    public static func literal(data: Data): String {
        match (data) {
            case s: DataString => quoteText(s.data)
            case d: DataReal => d.data.toString()
            case b: DataBool => b.data.toString()
            case _: DataNone => 'null'
            case other => other.toString()
        }
    }

    private static func quoteText(value: String): String {
        "'${value.replace('\'', '\'\'')}'"
    }
}
