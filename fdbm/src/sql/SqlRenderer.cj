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

import std.reflect.TypeInfo
import fountain::f_base.toHex
import fountain::f_data.*
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException

/**
 * AST → SQL（设计 §8.2 / D3）：按目标方言重建语句，供下推与 `parse → render → parse` 往返。
 *
 * - 原文带引用符的标识符按方言重写（PostgreSQL `"..."` / MySQL `` `...` ``）；
 * - 未引用的标识符保持裸名（与历史行为一致，避免把普通 SQL 全量改写）；
 * - 二元/IN/NOT 一律加括号，渲染结果可能与原文不同，但语义等价、可再次解析。
 */
protected struct SqlRenderer {
    public static func render(statement: SqlStatement, dialect!: SqlDialect = SqlDialect.Unknown): String {
        match (statement) {
            case s: SelectStatement => renderSelect(s, dialect)
            case s: InsertStatement => renderInsert(s, dialect)
            case s: UpdateStatement => renderUpdate(s, dialect)
            case s: DeleteStatement => renderDelete(s, dialect)
            case s: ShowStatement => renderShow(s, dialect)
            case s: DdlStatement => s.sql
            case s: ExportStatement => 'export ${s.key}=${quoteText(s.value, dialect)}'
            case s: SessionCtlStatement => s.sql
            case _ => ''
        }
    }

    private static func renderSelect(statement: SelectStatement, dialect: SqlDialect): String {
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
            builder.append(renderExpression(item.expression, dialect))
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
                builder.append(renderTable(statement.from[i], dialect))
                i += 1
            }
            for (join in statement.joins) {
                builder.append(' ')
                match (join.joinType) {
                    case JoinType.Inner => builder.append('inner join ')
                    case JoinType.Left => builder.append('left join ')
                    case JoinType.Right => builder.append('right join ')
                }
                builder.append(renderTable(join.table, dialect))
                match (join.on) {
                    case Some(on) => builder.append(' on ${renderExpression(on, dialect)}')
                    case None => ()
                }
            }
        }
        match (statement.condition) {
            case Some(condition) => builder.append(' where ${renderExpression(condition, dialect)}')
            case None => ()
        }
        if (!statement.orderBy.isEmpty()) {
            builder.append(' order by ')
            i = 0
            while (i < statement.orderBy.size) {
                if (i > 0) {
                    builder.append(', ')
                }
                builder.append(renderExpression(statement.orderBy[i][0], dialect))
                builder.append(if (statement.orderBy[i][1]) { ' asc' } else { ' desc' })
                i += 1
            }
        }
        match (statement.limit) {
            case Some(limit) => builder.append(' limit ${renderExpression(limit, dialect)}')
            case None => ()
        }
        match (statement.offset) {
            case Some(offset) => builder.append(' offset ${renderExpression(offset, dialect)}')
            case None => ()
        }
        builder.toString()
    }

    private static func renderInsert(statement: InsertStatement, dialect: SqlDialect): String {
        let builder = StringBuilder()
        builder.append('insert into ${renderTable(statement.table, dialect)}')
        if (!statement.columns.isEmpty()) {
            builder.append(' (')
            var i: Int64 = 0
            while (i < statement.columns.size) {
                if (i > 0) {
                    builder.append(', ')
                }
                builder.append(renderIdentifier(statement.columns[i], dialect))
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
                    builder.append(renderExpression(row[c], dialect))
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
                builder.append('${renderIdentifier(statement.setPairs[i][0], dialect)} = ')
                builder.append(renderExpression(statement.setPairs[i][1], dialect))
                i += 1
            }
        } else {
            match (statement.fromSelect) {
                case Some(select) => builder.append(' ${renderSelect(select, dialect)}')
                case None => ()
            }
        }
        if (!statement.returning.isEmpty()) {
            builder.append(' returning ')
            var i: Int64 = 0
            while (i < statement.returning.size) {
                if (i > 0) {
                    builder.append(', ')
                }
                builder.append(renderIdentifier(statement.returning[i], dialect))
                i += 1
            }
        }
        builder.toString()
    }

    private static func renderUpdate(statement: UpdateStatement, dialect: SqlDialect): String {
        let builder = StringBuilder()
        builder.append('update ${renderTable(statement.table, dialect)}')
        for (join in statement.joins) {
            builder.append(' ')
            match (join.joinType) {
                case JoinType.Inner => builder.append('inner join ')
                case JoinType.Left => builder.append('left join ')
                case JoinType.Right => builder.append('right join ')
            }
            builder.append(renderTable(join.table, dialect))
            match (join.on) {
                case Some(on) => builder.append(' on ${renderExpression(on, dialect)}')
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
            builder.append('${renderExpression(column, dialect)} = ')
            builder.append(renderExpression(value, dialect))
            i += 1
        }
        match (statement.condition) {
            case Some(condition) => builder.append(' where ${renderExpression(condition, dialect)}')
            case None => ()
        }
        builder.toString()
    }

    private static func renderDelete(statement: DeleteStatement, dialect: SqlDialect): String {
        let builder = StringBuilder()
        builder.append('delete from ${renderTable(statement.table, dialect)}')
        for (join in statement.joins) {
            builder.append(' ')
            match (join.joinType) {
                case JoinType.Inner => builder.append('inner join ')
                case JoinType.Left => builder.append('left join ')
                case JoinType.Right => builder.append('right join ')
            }
            builder.append(renderTable(join.table, dialect))
            match (join.on) {
                case Some(on) => builder.append(' on ${renderExpression(on, dialect)}')
                case None => ()
            }
        }
        match (statement.condition) {
            case Some(condition) => builder.append(' where ${renderExpression(condition, dialect)}')
            case None => ()
        }
        builder.toString()
    }

    private static func renderShow(statement: ShowStatement, dialect: SqlDialect): String {
        match (statement.showKind) {
            case ShowKind.Databases => 'show databases'
            case ShowKind.Tables =>
                let builder = StringBuilder('show tables')
                match (statement.database) {
                    case Some(database) => builder.append(' ${database}')
                    case None => ()
                }
                match (statement.like) {
                    case Some(pattern) => builder.append(' like ${quoteText(pattern, dialect)}')
                    case None => ()
                }
                builder.toString()
        }
    }

    static func renderTable(table: TableRef, dialect: SqlDialect): String {
        match (table.derived) {
            case Some(inner) =>
                let alias = match (table.alias) {
                    case Some(value) => value
                    case None => ''
                }
                return '(${renderSelect(inner, dialect)}) as ${alias}'
            case None => ()
        }
        let name = if (table.quoted) {
            SqlDialects.quoteIdentifier(table.name, dialect)
        } else {
            table.name
        }
        let qualified = match (table.database) {
            case Some(database) => '${database}.${name}'
            case None => name
        }
        match (table.alias) {
            case Some(alias) => '${qualified} ${alias}'
            case None => qualified
        }
    }

    static func renderIdentifier(identifier: Identifier, dialect: SqlDialect): String {
        if (identifier.quoted) {
            SqlDialects.quoteIdentifier(identifier.name, dialect)
        } else {
            identifier.name
        }
    }

    static func renderExpression(expression: SqlExpression, dialect: SqlDialect): String {
        match (expression) {
            case c: ColumnExpression =>
                let column = if (c.quoted) {
                    SqlDialects.quoteIdentifier(c.column, dialect)
                } else {
                    c.column
                }
                match (c.table) {
                    case Some(table) =>
                        let prefix = if (c.quoted) {
                            SqlDialects.quoteIdentifier(table, dialect)
                        } else {
                            table
                        }
                        '${prefix}.${column}'
                    case None => column
                }
            case l: LiteralExpression => literal(l.data, dialect: dialect)
            case h: HexLiteralExpression =>
                match (dialect) {
                    case SqlDialect.MySql => "X'${h.hex}'"
                    case _ => "'\\x${h.hex}'"
                }
            case p: ParameterExpression => '?'
            case b: BinaryExpression =>
                '(${renderExpression(b.left, dialect)} ${b.op} ${renderExpression(b.right, dialect)})'
            case i: InExpression =>
                let builder = StringBuilder('(${renderExpression(i.operand, dialect)} ')
                if (i.negated) {
                    builder.append('not ')
                }
                builder.append('in (')
                var index: Int64 = 0
                while (index < i.values.size) {
                    if (index > 0) {
                        builder.append(', ')
                    }
                    builder.append(renderExpression(i.values[index], dialect))
                    index += 1
                }
                builder.append('))')
                builder.toString()
            case n: NotExpression => '(not ${renderExpression(n.operand, dialect)})'
            case f: FunctionExpression =>
                let builder = StringBuilder('${f.name}(')
                var index: Int64 = 0
                while (index < f.args.size) {
                    if (index > 0) {
                        builder.append(', ')
                    }
                    builder.append(renderExpression(f.args[index], dialect))
                    index += 1
                }
                builder.append(')')
                builder.toString()
            case _: CountExpression => 'count(*)'
            case _: StarExpression => '*'
            case _ => ''
        }
    }

    /** 单参重载：等价于 `dialect = Unknown`（未知方言只翻倍单引号）。 */
    public static func literal(data: Data): String {
        literal(data, dialect: SqlDialect.Unknown)
    }

    /**
     * 参数值 → SQL 字面量（**类型白名单**，D06）。
     *
     * 只接受 `String` / `Real` / `Bool` / `None` / `DateTime` / 字节序列；其它类型 fail-closed
     * （`CONVERSION`），绝不再用 `toString()` 拼出非法 SQL。
     */
    public static func literal(data: Data, dialect!: SqlDialect): String {
        match (data) {
            case s: DataString => quoteText(s.data, dialect)
            case d: DataReal => d.data.toString()
            case b: DataBool => b.data.toString()
            case _: DataNone => 'null'
            case t: DataDateTime => quoteText(dateTimeText(t.data), dialect)
            case bytes: DataCollection<Array<Byte>, Byte> => byteLiteral(bytes.data, dialect)
            case other => throw FdbmException(DbdErrorCode.CONVERSION,
                'parameter value of type ${TypeInfo.of(other)} cannot be rendered as a SQL literal')
        }
    }

    /** 该值能否安全表示为 SQL 字面量（`ParameterBinder` 在渲染前用同一判定）。 */
    public static func isLiteral(data: Data): Bool {
        match (data) {
            case _: DataString => true
            case _: DataReal => true
            case _: DataBool => true
            case _: DataNone => true
            case _: DataDateTime => true
            case _: DataCollection<Array<Byte>, Byte> => true
            case _ => false
        }
    }

    /** `yyyy-MM-dd HH:mm:ss[.fffffffff]`（本地时区，不做时区转换）。 */
    private static func dateTimeText(value: DateTime): String {
        let base = value.format('yyyy-MM-dd HH:mm:ss')
        let nanos = value.nanosecond
        if (nanos == 0) {
            return base
        }
        var text = nanos.toString()
        while (text.size < 9) {
            text = '0${text}'
        }
        while (text.endsWith('0')) {
            text = text[0..text.size - 1]
        }
        '${base}.${text}'
    }

    private static func byteLiteral(bytes: Array<Byte>, dialect: SqlDialect): String {
        let hex = StringBuilder()
        for (byte in bytes) {
            hex.append(toHex(byte))
        }
        if (dialect == SqlDialect.MySql) {
            "X'${hex}'"
        } else {
            "'\\x${hex}'"
        }
    }

    /**
     * 字符串字面量：MySQL 族先转义反斜杠（`\` → `\\`）再翻倍单引号（G21）；其它方言只翻倍单引号。
     */
    private static func quoteText(value: String, dialect: SqlDialect): String {
        let builder = StringBuilder()
        for (ch in value.toRuneArray()) {
            if (ch == r'\\' && dialect == SqlDialect.MySql) {
                builder.append("\\\\")
            } else if (ch == r'\'') {
                builder.append("''")
            } else {
                builder.append(ch)
            }
        }
        "'${builder.toString()}'"
    }
}
