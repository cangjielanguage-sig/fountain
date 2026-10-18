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
import fountain::f_data.{DataAny, DataReal, DataString}
import fountain::f_dbd.common.DbdErrorCode

/** 引用标识符（设计 D3）：`"..."` 与 `` `...` `` 都是标识符，单引号仍是字符串。 */
@Test
public class QuotedIdentifierTest {

    @TestCase
    public func doubleQuotesAreQuotedIdentifiers(): Unit {
        let statement = parseAs<SelectStatement>('select * from "t" where "name" = \'x\'')
        @Assert(statement.from[0].name, 't')
        @Assert(statement.from[0].quoted, true)
        match (statement.condition.getOrThrow()) {
            case b: BinaryExpression =>
                match (b.left) {
                    case c: ColumnExpression =>
                        @Assert(c.column, 'name')
                        @Assert(c.quoted, true)
                    case _ => @Assert(false, true)
                }
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func backticksAreQuotedIdentifiers(): Unit {
        let statement = parseAs<SelectStatement>('select * from `t` where `id` = 1')
        @Assert(statement.from[0].quoted, true)
    }

    @TestCase
    public func quotedKeywordsAreNotKeywords(): Unit {
        // `"count"` 是列名，不是聚合函数
        let statement = parseAs<SelectStatement>('select "count" from t')
        match (statement.columns[0].expression) {
            case c: ColumnExpression => @Assert(c.column, 'count')
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func singleQuotesRemainStrings(): Unit {
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

    @TestCase
    public func unterminatedQuotesAreSyntaxErrors(): Unit {
        @Assert(parseCode('select * from "t') == DbdErrorCode.SQL_SYNTAX, true)
        @Assert(parseCode('select * from `t') == DbdErrorCode.SQL_SYNTAX, true)
    }
}

/** AST（设计 D3/D4）：Identifier 按裸名相等、派生表递归展开、count(*) 形状。 */
@Test
public class SqlAstTest {

    @TestCase
    public func identifierEqualityIgnoresQuoting(): Unit {
        @Assert(Identifier('id') == Identifier('id', quoted: true), true)
        @Assert(Identifier('id') == Identifier('other'), false)
        @Assert(Identifier('id').equalsName('id'), true)
    }

    @TestCase
    public func derivedTableExpandsToInnerTables(): Unit {
        let statement = parseAs<SelectStatement>(
            'select count(*) from (select 1 from t where id = 7) as c')
        @Assert(statement.from.size, 1)
        @Assert(statement.from[0].derived.isSome(), true)
        @Assert(statement.tables.size, 1)
        @Assert(statement.tables[0].name, 't')
    }

    @TestCase
    public func countExpressionIsRecognized(): Unit {
        let statement = parseAs<SelectStatement>('select count(*) from t')
        @Assert(statement.columns[0].expression is CountExpression, true)
    }
}

/** `INSERT ... RETURNING`（设计 D1/D6）。 */
@Test
public class InsertReturningTest {

    @TestCase
    public func parsesReturningColumnsInOrder(): Unit {
        let values = parseAs<InsertStatement>(
            "insert into t (name) values ('a') returning id, name")
        @Assert(values.returning.size, 2)
        @Assert(values.returning[0].name, 'id')
        @Assert(values.returning[1].name, 'name')

        let quoted = parseAs<InsertStatement>('insert into t set name = 1 returning "id"')
        @Assert(quoted.returning[0].name, 'id')
        @Assert(quoted.returning[0].quoted, true)
    }

    @TestCase
    public func rejectsUnsupportedReturningShapes(): Unit {
        @Assert(parseCode('insert into t (a) values (1) returning *') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('insert into t (a) values (1) returning count(*)') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('insert into t (a) values (1) returning id + 1') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('insert into t (a) select a from s returning id') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
    }
}

/** `count(*)` 与派生表（设计 D4）。 */
@Test
public class CountAndDerivedTableTest {

    @TestCase
    public func parsesDerivedTableWithAndWithoutAs(): Unit {
        let withAs = parseAs<SelectStatement>(
            'select count(*) from (select 1 from t where id = ?) as c')
        @Assert(withAs.from[0].alias.getOrThrow(), 'c')

        let withoutAs = parseAs<SelectStatement>(
            'select * from (select * from t where id = 7) p limit 1 offset 2')
        @Assert(withoutAs.from[0].alias.getOrThrow(), 'p')
        @Assert(withoutAs.limit.isSome(), true)
        @Assert(withoutAs.offset.isSome(), true)
    }

    @TestCase
    public func countOnlyConstraints(): Unit {
        @Assert(SqlParser.parse('select count(*) from t', 'db0') is SelectStatement, true)
        @Assert(parseCode('select count(*)') == DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select count(*) from t limit 1') == DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select count(*) from t order by id') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select count(*), id from t') == DbdErrorCode.UNSUPPORTED_SQL, true)
    }

    @TestCase
    public func rejectsMalformedDerivedTables(): Unit {
        @Assert(parseCode('select * from (select * from t)') == DbdErrorCode.SQL_SYNTAX, true)
        @Assert(parseCode('select * from (t) as c') == DbdErrorCode.SQL_SYNTAX, true)
    }

    @TestCase
    public func rejectsOuterShapesOnDerivedTables(): Unit {
        @Assert(parseCode('select * from (select * from t) as c where id = 1') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select * from (select * from t) as c order by id') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select distinct * from (select * from t) as c') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select * from (select * from t) as c join u on c.id = u.id') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
        @Assert(parseCode('select count(*) from (select * from t) as c limit 1') ==
            DbdErrorCode.UNSUPPORTED_SQL, true)
    }
}

/** 参数绑定递归进入派生表（设计 D4/D5）。 */
@Test
public class DerivedTableBinderTest {

    @TestCase
    public func bindsInnerConditionThenOuterPaging(): Unit {
        let statement = SqlParser.parse(
            'select * from (select id from t where id = ?) as p limit ? offset ?', 'db0')
        let bound = ParameterBinder.bind(statement, [
            DataAny(DataReal(7)), DataAny(DataReal(10)), DataAny(DataReal(20))
        ])
        let sql = SqlRenderer.render(bound)
        @Assert(sql.contains('id = 7'), true)
        @Assert(sql.contains('limit 10 offset 20'), true)
        @Assert(sql.contains('?'), false)
    }

    @TestCase
    public func countsInnerParameters(): Unit {
        let statement = SqlParser.parse(
            'select count(*) from (select 1 from t where id = ?) as c', 'db0')
        @Assert(binderCode(statement, []) == DbdErrorCode.PROTOCOL, true)
        @Assert(binderCode(statement, [DataAny(DataReal(1)), DataAny(DataReal(2))]) ==
            DbdErrorCode.PROTOCOL, true)
        let bound = ParameterBinder.bind(statement, [DataAny(DataReal(1))])
        @Assert(bound is SelectStatement, true)
    }
}

/** 方言判定与引用重写（设计 D2/D3）。 */
@Test
public class SqlDialectTest {

    @TestCase
    public func mapsDriverNamesToFamilies(): Unit {
        for (name in ['postgres', 'postgresql', 'pgsql', 'opengauss', 'postgres_driver']) {
            @Assert(SqlDialects.ofDriver(name) == SqlDialect.Postgres, true)
        }
        for (name in ['mysql', 'mariadb', 'mysqlclient', 'MySQL_Driver']) {
            @Assert(SqlDialects.ofDriver(name) == SqlDialect.MySql, true)
        }
        @Assert(SqlDialects.ofDriver('mockdb') == SqlDialect.Unknown, true)
        @Assert(SqlDialects.ofDriver('oracle') == SqlDialect.Unknown, true)
    }

    @TestCase
    public func quotesByIdentifierFamily(): Unit {
        @Assert(SqlDialects.quoteIdentifier('t', SqlDialect.Postgres), '"t"')
        @Assert(SqlDialects.quoteIdentifier('t', SqlDialect.MySql), '`t`')
        @Assert(SqlDialects.quoteIdentifier('t', SqlDialect.Unknown), '"t"')
        @Assert(SqlDialects.quoteIdentifier('a"b', SqlDialect.Postgres), '"a""b"')
        @Assert(SqlDialects.quoteIdentifier('a`b', SqlDialect.MySql), '`a``b`')
    }

    @TestCase
    public func rendererRewritesQuotedUpdateByIdentifierFamily(): Unit {
        let statement = SqlParser.parse('update "t" set "name" = 1 where "id" = 2', 'db0')
        @Assert(SqlRenderer.render(statement, dialect: SqlDialect.Postgres),
            'update "t" set "name" = 1 where ("id" = 2)')
        @Assert(SqlRenderer.render(statement, dialect: SqlDialect.MySql),
            'update `t` set `name` = 1 where (`id` = 2)')
        @Assert(SqlRenderer.render(statement),
            'update "t" set "name" = 1 where ("id" = 2)')
    }

    @TestCase
    public func rendererKeepsBareIdentifiersBare(): Unit {
        let statement = SqlParser.parse('select id from t where id = 1', 'db0')
        @Assert(SqlRenderer.render(statement, dialect: SqlDialect.MySql),
            'select id from t where (id = 1)')
    }

    @TestCase
    public func rendersCountAndDerivedTables(): Unit {
        let count = SqlParser.parse(
            'select count(*) from (select 1 from t where id = 7) as c', 'db0')
        @Assert(SqlRenderer.render(count),
            'select count(*) from (select 1 from t where (id = 7)) as c')
        let insert = SqlParser.parse('insert into t (a) values (1) returning id', 'db0')
        @Assert(SqlRenderer.render(insert, dialect: SqlDialect.Postgres),
            'insert into t (a) values (1) returning id')
    }
}
