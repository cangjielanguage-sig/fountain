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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataString
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException

/** Step 3.1/3.2 词法与解析（设计 §8.2）：SELECT/INSERT/UPDATE/DELETE/SHOW/DDL/EXPORT 与错误码。 */
@Test
public class SqlParserTest {

    @TestCase
    public func selectWithEverything(): Unit {
        let statement = parseAs<SelectStatement>(
            'select distinct t.id, name as n from db1.users t left join db1.orders o on t.id = o.uid ' +
            'where t.id > ? and name like \'a%\' order by t.id desc limit 10 offset 5')
        @Assert(statement.distinct, true)
        @Assert(statement.columns.size, 2)
        @Assert(statement.columns[1].alias.getOrThrow(), 'n')
        @Assert(statement.from.size, 1)
        @Assert(statement.from[0].key(), 'db1.users')
        @Assert(statement.from[0].effectiveName(), 't')
        @Assert(statement.joins.size, 1)
        @Assert(statement.joins[0].joinType == JoinType.Left, true)
        @Assert(statement.condition.isSome(), true)
        @Assert(statement.orderBy.size, 1)
        match (statement.limit.getOrThrow()) {
            case l: LiteralExpression => @Assert(SqlRenderer.literal(l.data), '10')
            case _ => @Assert(false, true)
        }
        match (statement.offset.getOrThrow()) {
            case l: LiteralExpression => @Assert(SqlRenderer.literal(l.data), '5')
            case _ => @Assert(false, true)
        }
    }

    /** `*`、多表与不写 `from` 的查询。 */
    @TestCase
    public func selectStarAndMultiTable(): Unit {
        let star = parseAs<SelectStatement>('select * from a, b where a.id = b.id')
        @Assert(star.columns.size, 1)
        @Assert(star.columns[0].expression is StarExpression, true)
        @Assert(star.from.size, 2)
        @Assert(star.from[1].key(), 'db0.b')
    }

    /** `?` 的 index 按出现顺序；`between` 展开为 `and(gte, lte)`。 */
    @TestCase
    public func parametersAndBetween(): Unit {
        let statement = parseAs<SelectStatement>('select * from t where id between ? and ?')
        @Assert(statement.columns.size, 1)
        match (statement.condition.getOrThrow()) {
            case b: BinaryExpression =>
                @Assert(b.op == BinaryOp.And, true)
                match (b.left) {
                    case left: BinaryExpression =>
                        @Assert(left.op == BinaryOp.Gte, true)
                        match (left.right) {
                            case p: ParameterExpression => @Assert(p.index, 0)
                            case _ => @Assert(false, true)
                        }
                    case _ => @Assert(false, true)
                }
                match (b.right) {
                    case right: BinaryExpression =>
                        @Assert(right.op == BinaryOp.Lte, true)
                        match (right.right) {
                            case p: ParameterExpression => @Assert(p.index, 1)
                            case _ => @Assert(false, true)
                        }
                    case _ => @Assert(false, true)
                }
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func insertForms(): Unit {
        let values = parseAs<InsertStatement>(
            'insert into db0.t (id, name) values (1, \'a\'), (2, \'b\')')
        @Assert(values.columns.size, 2)
        @Assert(values.values.size, 2)
        @Assert(values.values[1][0] is LiteralExpression, true)

        let set = parseAs<InsertStatement>('insert into t set id = 1, name = \'a\'')
        @Assert(set.setPairs.size, 2)
        @Assert(set.setPairs[1][0].name, 'name')

        let fromSelect = parseAs<InsertStatement>('insert into t (id) select id from s')
        @Assert(fromSelect.fromSelect.isSome(), true)
        @Assert(fromSelect.fromSelect.getOrThrow().from[0].key(), 'db0.s')
    }

    @TestCase
    public func updateAndDelete(): Unit {
        let update = parseAs<UpdateStatement>(
            'update t join u on t.id = u.id set t.name = ?, u.age = 2 where t.id = 7')
        @Assert(update.joins.size, 1)
        @Assert(update.assignments.size, 2)
        @Assert(update.assignments[0][0].table.getOrThrow(), 't')
        @Assert(update.condition.isSome(), true)

        let delete = parseAs<DeleteStatement>('delete from t where id = ?')
        @Assert(delete.table.key(), 'db0.t')
        @Assert(delete.condition.isSome(), true)
    }

    @TestCase
    public func showForms(): Unit {
        let databases = parseAs<ShowStatement>('show databases')
        @Assert(databases.showKind == ShowKind.Databases, true)

        let tables = parseAs<ShowStatement>('show tables db1 like \'a%\'')
        @Assert(tables.showKind == ShowKind.Tables, true)
        @Assert(tables.database.getOrThrow(), 'db1')
        @Assert(tables.like.getOrThrow(), 'a%')

        let current = parseAs<ShowStatement>('show tables')
        @Assert(current.database.isNone(), true)
    }

    @TestCase
    public func ddlPassesThrough(): Unit {
        let create = parseAs<DdlStatement>('create table if not exists db0.t (id int)')
        @Assert(create.sql, 'create table if not exists db0.t (id int)')
        @Assert(create.tables[0].key(), 'db0.t')

        let alter = parseAs<DdlStatement>('alter table t add column age int')
        @Assert(alter.table.getOrThrow().name, 't')
    }

    @TestCase
    public func exportStatement(): Unit {
        let statement = parseAs<ExportStatement>('export fdbm_port=9000')
        @Assert(statement.key, 'fdbm_port')
        @Assert(statement.value, '9000')

        let quoted = parseAs<ExportStatement>("export fdbm_db='name0@h:1'")
        @Assert(quoted.value, 'name0@h:1')
    }

    @TestCase
    public func sessionControl(): Unit {
        @Assert(SqlParser.parseSessionCtl('begin').getOrThrow().verb == SessionCtlVerb.Begin, true)
        @Assert(SqlParser.parseSessionCtl('start transaction').getOrThrow().verb == SessionCtlVerb.Begin,
            true)
        @Assert(SqlParser.parseSessionCtl('commit;').getOrThrow().verb == SessionCtlVerb.Commit, true)
        @Assert(SqlParser.parseSessionCtl('rollback').getOrThrow().verb == SessionCtlVerb.Rollback, true)
        let toSavepoint = SqlParser.parseSessionCtl('rollback to savepoint sp1').getOrThrow()
        @Assert(toSavepoint.verb == SessionCtlVerb.RollbackTo, true)
        @Assert(toSavepoint.savepoint.getOrThrow(), 'sp1')
        @Assert(SqlParser.parseSessionCtl('savepoint sp1').getOrThrow().savepoint.getOrThrow(), 'sp1')
        @Assert(SqlParser.parseSessionCtl('release sp1').getOrThrow().verb == SessionCtlVerb.Release,
            true)
        @Assert(SqlParser.parseSessionCtl('select 1').isNone(), true)
        @Assert(SqlParser.parseSessionCtl('savepoint_x').isNone(), true)
    }

    /** `parse` 也能直接吃会话控制语句（Kind = SessionCtl）。 */
    @TestCase
    public func parseHandlesSessionControl(): Unit {
        let statement = SqlParser.parse('begin', 'db0')
        @Assert(statement is SessionCtlStatement, true)
    }

    @TestCase
    public func unsupportedStatements(): Unit {
        @Assert(parseCode('select count(1) from t') == DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select * from t group by id') == DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select * from a union select * from b') == DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('call proc()') == DbdErrorCode.UNSUPPORTED_SQL, true)
    }

    @TestCase
    public func syntaxErrors(): Unit {
        @Assert(parseCode('select * from') == DbdErrorCode.SQL_SYNTAX, true)
        @Assert(parseCode('insert into') == DbdErrorCode.SQL_SYNTAX, true)
        @Assert(parseCode('') == DbdErrorCode.SQL_SYNTAX, true)
        @Assert(parseCode('select * from t where') == DbdErrorCode.SQL_SYNTAX, true)
    }

    /** D08：派生表位于 JOIN 或 DML 的 JOIN 中 → `UNSUPPORTED_SQL`。 */
    @TestCase
    public func derivedTableInJoinIsUnsupported(): Unit {
        @Assert(parseCode('select * from u join (select * from t where id = 5) c on u.tid = c.id') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode("update t join (select * from u) x on t.id = x.id set t.name = 'a'") ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('delete from t join (select * from u) x on t.id = x.id') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
    }

    /** D08 回归：合法的 JOIN 不受形状校验影响。 */
    @TestCase
    public func legalJoinsStillParse(): Unit {
        parseAs<SelectStatement>('select * from a join b on a.id = b.id')
        parseAs<UpdateStatement>("update t join u on t.id = u.id set t.name = 'a'")
        parseAs<DeleteStatement>('delete from t join u on t.id = u.id')
    }

    /** D07：大整数与高精度小数按原文保留，不经 `Float64`。 */
    @TestCase
    public func numericLiteralsKeepFullPrecision(): Unit {
        let big = parseAs<InsertStatement>('insert into t (v) values (12345678901234567890)')
        @Assert(SqlRenderer.render(big).contains('12345678901234567890'), true)
        let fraction = parseAs<InsertStatement>('insert into t (v) values (123456789012345678.90)')
        @Assert(SqlRenderer.render(fraction).contains('123456789012345678.90'), true)
        let negative = parseAs<InsertStatement>('insert into t (v) values (-12345678901234567890)')
        @Assert(SqlRenderer.render(negative).contains('-12345678901234567890'), true)
    }

    @TestCase
    public func stringEscapes(): Unit {
        let statement = parseAs<SelectStatement>("select * from t where name = 'a''b'")
        match (statement.condition.getOrThrow()) {
            case b: BinaryExpression =>
                match (b.right) {
                    case l: LiteralExpression =>
                        match (l.data) {
                            case s: DataString => @Assert(s.data, "a'b")
                            case _ => @Assert(false, true)
                        }
                    case _ => @Assert(false, true)
                }
            case _ => @Assert(false, true)
        }
    }

    /** G17：WHERE/标量位置的非派生表子查询 → `UNSUPPORTED_SQL`（不是 SQL_SYNTAX）。 */
    @TestCase
    public func subqueriesAreUnsupported(): Unit {
        @Assert(parseCode('select * from t where id in (select id from u)') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select * from t where exists (select 1 from u)') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select (select 1) from t') == DbdErrorCode.UNSUPPORTED_SQL, true)
    }

    /** G18：引用的别名/库名在 parse → render → parse 中闭合，且各部分独立加引用符。 */
    @TestCase
    public func quotedAliasAndDatabaseRoundTrip(): Unit {
        for (sql in ['select id as "order" from "shop"."T" as "select"', 'select t."COL" from t']) {
            let first = SqlParser.parse(sql, 'db0')
            let rendered = SqlRenderer.render(first, dialect: SqlDialect.Postgres)
            let second = SqlParser.parse(rendered, 'db0')
            @Assert(SqlRenderer.render(second, dialect: SqlDialect.Postgres), rendered)
        }
        // 列名被引用不得把未引用的表名一起引用
        @Assert(SqlRenderer.render(SqlParser.parse('select t."COL" from t', 'db0'),
            dialect: SqlDialect.Postgres), 'select t."COL" from t')
    }

    /** G22：下推渲染去掉逻辑库限定符（由目标物理库定位）。 */
    @TestCase
    public func pushdownDropsLogicalQualifier(): Unit {
        let statement = SqlParser.parse('select * from app.t where id = 1001', 'app')
        let pushed = SqlRenderer.render(statement, unqualified: true, dialect: SqlDialect.Postgres)
        @Assert(pushed.contains('from t'), true)
        @Assert(pushed.contains('app.t'), false)
        // 非下推路径（SHOW/文档）保留逻辑库限定名
        @Assert(SqlRenderer.render(statement, dialect: SqlDialect.Postgres).contains('app.t'), true)
    }

}

func parseAs<T>(sql: String): T where T <: SqlStatement {
    match (SqlParser.parse(sql, 'db0')) {
        case value: T => value
        case _ => throw Exception('unexpected statement type for: ${sql}')
    }
}

func parseCode(sql: String): DbdErrorCode {
    try {
        SqlParser.parse(sql, 'db0')
    } catch (e: FdbmException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}
