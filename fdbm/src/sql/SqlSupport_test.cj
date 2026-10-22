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
import fountain::f_data.{DataAny, DataDateTime, DataDuration, DataList, DataReal, DataString}
import fountain::f_data.base.*
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException
import std.time.DateTime

/** Step 3.3 `ParameterBinder`（设计 §8.2）：顺序替换与个数校验。 */
@Test
public class ParameterBinderTest {

    @TestCase
    public func replacesPlaceholdersInOrder(): Unit {
        let statement = SqlParser.parse('select * from t where id = ? and name = ?', 'db0')
        let bound = ParameterBinder.bind(statement,
            [DataAny(DataReal(7)), DataAny(DataString('a'))])
        let sql = SqlRenderer.render(bound)
        @Assert(sql.contains('7'), true)
        @Assert(sql.contains("'a'"), true)
        @Assert(sql.contains('?'), false)
    }

    @TestCase
    public func countMismatchIsProtocol(): Unit {
        let statement = SqlParser.parse('select * from t where id = ? and name = ?', 'db0')
        @Assert(binderCode(statement, [DataAny(DataReal(1))]) == DbdErrorCode.PROTOCOL, true)
        @Assert(binderCode(statement,
            [DataAny(DataReal(1)), DataAny(DataString('a')), DataAny(DataReal(2))]) ==
            DbdErrorCode.PROTOCOL, true)
    }

    @TestCase
    public func bindsLimitOffsetParameters(): Unit {
        // f_orm 的方言用 `limit ? offset ?`；fdbm 必须在绑定后还原为整数。
        let statement = SqlParser.parse('select id from t where id = ? limit ? offset ?', 'db0')
        let bound = ParameterBinder.bind(statement, [
            DataAny(DataReal(7)), DataAny(DataReal(10)), DataAny(DataReal(20))
        ])
        let sql = SqlRenderer.render(bound)
        @Assert(sql.contains('limit 10 offset 20'), true)
        @Assert(sql.contains('?'), false)
    }

    @TestCase
    public func bindsInsertValues(): Unit {
        let statement = SqlParser.parse('insert into t (id, name) values (?, ?), (?, ?)', 'db0')
        let bound = ParameterBinder.bind(statement, [
            DataAny(DataReal(1)), DataAny(DataString('a')),
            DataAny(DataReal(2)), DataAny(DataString('b'))
        ])
        let sql = SqlRenderer.render(bound)
        @Assert(sql.contains("values (1, 'a'), (2, 'b')"), true)
    }

    /** D06：白名单外的参数类型在绑定阶段失败，物理库不会收到语句。 */
    @TestCase
    public func rejectsNonLiteralParameterTypes(): Unit {
        let statement = SqlParser.parse('select * from t where c = ?', 'db0')
        @Assert(binderCode(statement, [DataAny(DataDuration(Duration.second))]) ==
            DbdErrorCode.CONVERSION, true)
        @Assert(binderCode(statement, [DataAny(DataList())]) == DbdErrorCode.CONVERSION, true)
    }

    /** D06：`DateTime` / 字节参数生成可解析的字面量。 */
    @TestCase
    public func rendersDateTimeAndBytesAsLiterals(): Unit {
        let moment = DateTime.parse('2026-10-21T06:49:00+08:00')
        let expected = moment.format('yyyy-MM-dd HH:mm:ss')
        let statement = SqlParser.parse('select * from t where c = ?', 'db0')
        let bound = ParameterBinder.bind(statement, [DataAny(DataDateTime(moment))])
        let sql = SqlRenderer.render(bound, dialect: SqlDialect.Postgres)
        @Assert(sql.contains("'${expected}'"), true)
        @Assert(sql.contains('T06:49'), false)

        let bytes = ParameterBinder.bind(statement, [DataAny([1u8, 2u8].toData())])
        let rendered = SqlRenderer.render(bytes, dialect: SqlDialect.Postgres)
        @Assert(rendered.contains("'\\x0102'"), true)
        let mysql = SqlRenderer.render(bytes, dialect: SqlDialect.MySql)
        @Assert(mysql.contains("X'0102'"), true)
    }

    /** G21：MySQL 族必须转义反斜杠，字面量才能闭合。 */
    @TestCase
    public func mysqlEscapesBackslashInStrings(): Unit {
        let statement = SqlParser.parse('select * from t where c = ?', 'db0')
        let bound = ParameterBinder.bind(statement, [DataAny(DataString("C:\\"))])
        @Assert(SqlRenderer.render(bound, dialect: SqlDialect.MySql).contains("'C:\\\\'"), true)
        @Assert(SqlRenderer.render(bound, dialect: SqlDialect.Postgres).contains("'C:\\'"), true)
    }
}

/** Step 3.4 `PartitionKeyExtractor`（设计 §8.2）：等值/IN 与范围。 */
@Test
public class PartitionKeyExtractorTest {

    @TestCase
    public func extractsEqualityAndIn(): Unit {
        let equality = conditionOf('select * from t where id = 7')
        let equals = PartitionKeyExtractor.extract(equality, Some('t'), 'id')
        @Assert(equals.size, 1)
        @Assert(equals[0], '7')

        let conjunction = conditionOf("select * from t where id = 7 and name = 'a'")
        let conjunctionValues = PartitionKeyExtractor.extract(conjunction, Some('t'), 'id')
        @Assert(conjunctionValues.size, 1)
        @Assert(conjunctionValues[0], '7')

        let inList = conditionOf('select * from t where id in (1, 2, 3)')
        @Assert(PartitionKeyExtractor.extract(inList, Some('t'), 'id').size, 3)

        let aliased = conditionOf('select * from t x where x.id = 9')
        let aliasedValues = PartitionKeyExtractor.extract(aliased, Some('x'), 'id')
        @Assert(aliasedValues.size, 1)
        @Assert(aliasedValues[0], '9')
        @Assert(PartitionKeyExtractor.extract(aliased, Some('t'), 'id').size, 0)
    }

    /** `OR` / `NOT` 保守地不抽取（交给路由器按 Unroutable）。 */
    @TestCase
    public func orAndNotAreNotExpanded(): Unit {
        let orCondition = conditionOf('select * from t where id = 1 or id = 2')
        @Assert(PartitionKeyExtractor.extract(orCondition, Some('t'), 'id').size, 0)
        let notCondition = conditionOf('select * from t where not id = 1')
        @Assert(PartitionKeyExtractor.extract(notCondition, Some('t'), 'id').size, 0)
    }

    @TestCase
    public func nonEqualityIsIgnored(): Unit {
        let condition = conditionOf('select * from t where id > 10')
        @Assert(PartitionKeyExtractor.extract(condition, Some('t'), 'id').size, 0)
    }

    @TestCase
    public func extractsRangeBounds(): Unit {
        let bounded = PartitionKeyExtractor.extractRange(
            conditionOf('select * from t where id >= 10 and id < 20'), Some('t'), 'id').getOrThrow()
        @Assert(bounded.lo.getOrThrow(), 10)
        @Assert(bounded.loInclusive, true)
        @Assert(bounded.hi.getOrThrow(), 19)
        @Assert(bounded.hiInclusive, true)

        let reversed = PartitionKeyExtractor.extractRange(
            conditionOf('select * from t where 20 > id'), Some('t'), 'id').getOrThrow()
        @Assert(reversed.hi.getOrThrow(), 19)
    }

    @TestCase
    public func betweenExpandsToRange(): Unit {
        let between = PartitionKeyExtractor.extractRange(
            conditionOf('select * from t where id between 3 and 8'), Some('t'), 'id').getOrThrow()
        @Assert(between.lo.getOrThrow(), 3)
        @Assert(between.hi.getOrThrow(), 8)
        @Assert(between.isEmpty(), false)
    }

    @TestCase
    public func intersectingRangesTakeTheTightest(): Unit {
        let range = PartitionKeyExtractor.extractRange(
            conditionOf('select * from t where id > 10 and id > 20 and id < 30 and id <= 25'),
            Some('t'), 'id').getOrThrow()
        @Assert(range.lo.getOrThrow(), 21)
        @Assert(range.hi.getOrThrow(), 25)
    }

    @TestCase
    public func contravariantRangesAreEmpty(): Unit {
        let range = PartitionKeyExtractor.extractRange(
            conditionOf('select * from t where id > 100 and id < 50'), Some('t'), 'id').getOrThrow()
        @Assert(range.isEmpty(), true)
    }

    @TestCase
    public func orAndNotRangesAreUndeterminable(): Unit {
        @Assert(PartitionKeyExtractor.extractRange(
            conditionOf('select * from t where id > 1 or id < 100'), Some('t'), 'id').isNone(), true)
        @Assert(PartitionKeyExtractor.extractRange(
            conditionOf('select * from t where not id > 1'), Some('t'), 'id').isNone(), true)
    }

    @TestCase
    public func nonIntegerLiteralIsUndeterminable(): Unit {
        @Assert(PartitionKeyExtractor.extractRange(
            conditionOf("select * from t where id > 'abc'"), Some('t'), 'id').isNone(), true)
    }

    /** 与本列无关的条件被忽略（可安全放宽，不会漏行）。 */
    @TestCase
    public func unrelatedConditionsAreIgnored(): Unit {
        let range = PartitionKeyExtractor.extractRange(
            conditionOf("select * from t where name = 'a' and id != 3 and id > 5"), Some('t'), 'id')
            .getOrThrow()
        @Assert(range.lo.getOrThrow(), 6)
    }
}

/** Step 3.5 `SqlRenderer`（设计 §8.2）：`parse → render → parse` 稳定。 */
@Test
public class SqlRendererTest {

    @TestCase
    public func roundTripsSupportedStatements(): Unit {
        let statements = [
            'select * from t',
            'select distinct a, b as c from db1.t x left join db1.u y on x.id = y.id where x.id = ? order by a desc limit 10 offset 2',
            'insert into t (a, b) values (1, \'x\'), (2, \'y\')',
            "insert into t set a = 1, b = 'x'",
            "insert into t (a) values (1) returning id",
            'select count(*) from (select 1 from t where id = 7) as c',
            'select * from (select id from t where id = 7) as p limit 10 offset 20',
            'update "t" set "name" = 1 where "id" = 2',
            'update t join u on t.id = u.id set t.a = 1 where t.id = 2',
            'delete from t where id = 3',
            'show databases',
            "show tables db1 like 'a%'",
            'create table if not exists db0.t (id int)',
            'export fdbm_port=9000'
        ]
        for (sql in statements) {
            let first = SqlRenderer.render(SqlParser.parse(sql, 'db0'))
            let second = SqlRenderer.render(SqlParser.parse(first, 'db0'))
            @Assert(second, first)
        }
    }

    @TestCase
    public func quotesStringLiterals(): Unit {
        let statement = SqlParser.parse("select * from t where name = 'a''b'", 'db0')
        let sql = SqlRenderer.render(statement)
        @Assert(sql.contains("'a''b'"), true)
        @Assert(SqlParser.parse(sql, 'db0') is SelectStatement, true)
    }
}

func conditionOf(sql: String): ?SqlExpression {
    match (SqlParser.parse(sql, 'db0')) {
        case statement: SelectStatement => statement.condition
        case _ => None<SqlExpression>
    }
}

func binderCode(statement: SqlStatement, params: Array<DataAny>): DbdErrorCode {
    try {
        ParameterBinder.bind(statement, params)
    } catch (e: FdbmException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}
