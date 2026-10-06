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
package fountain::f_orm.base

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.database.sql.*
import fountain::f_mockdb.*

/** 未实现 `ToString`、也不是 `InputStream` 的值：`argInSql` 下绑定不了 */
private class OpaqueValue {}

/** 未实现 `ToString`、但可绑定的值（借 `InputStream` 这一条绑定通道） */
private class ProbeStream <: InputStream {
    public func read(buffer: Array<Byte>): Int64 {
        0
    }
}

/** 记录「实际发给驱动的 SQL」与「实际绑定的参数」 */
private class Captured {
    var sql = ''
    let args = ArrayList<Any>()
}

/**
 * `argInSql` 的调用口径（bug.md §2.8 / ORM-C5 —— 判定为设计目的、非缺陷）。
 *
 * 钉住 README §11.5 写明、调用时实际会发生的行为：
 * ① 不开 `argInSql`：值一律参数化（`?` + 绑定参数）；
 * ② 开 `argInSql`：满足 `ToString` 的值原样拼进 SQL（不转义、不加引号、不绑定）；
 * ③ 开 `argInSql` 但不是 `ToString`：仍走绑定——可绑定的（`InputStream`）拼 `?` 并绑定，
 *    其它类型在拼 SQL 阶段就抛 `SqlException: Unsupported data type`；
 * ④ `IN` 按元素逐个判定，同一列表里可内联与绑定混用；
 * ⑤ `ChooseCondition` 的 `()` 值只写片段、不写值。
 */
@Test
public class ArgInSqlTest {
    /** 装夹具 → 执行 → 取回 SQL 与绑定参数（借 `MOCKDB.execution` 观察真实入参） */
    private func run(fn: (SqlExecutor) -> Unit): Captured {
        let captured = Captured()
        MOCKDB.clear()
        MOCKDB.execution = {sql: String, args: ArrayList<Any> =>
            captured.sql = sql
            captured.args.clear()
            for (a in args) {
                captured.args.add(a)
            }
        }
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        fn(ex)
        captured
    }

    /** ① 默认路径：值走 `?` 并绑定原值 */
    @TestCase
    public func testDefaultPathBindsValueAsParameter(): Unit {
        let captured = run {ex =>
            let cond = MeetCondition(true, 'name =', ex)
            ex.setSql('update t set v = 1 where ${cond.value('bob').done()}').update
            ()
        }
        @Assert(true, captured.sql.contains('name = ?'))
        @Assert(1, captured.args.size)
        match (captured.args[0]) {
            case x: String => @Assert('bob', x)
            case _ => @Assert(false)
        }
    }

    /** ② `argInSql` + `ToString`：原样拼接（字符串不加引号、数字按 `toString()` 出数字），不绑定 */
    @TestCase
    public func testArgInSqlInlinesToStringValues(): Unit {
        let captured = run {ex =>
            let name = MeetCondition(true, 'name =', ex).argInSql
            let id = MeetCondition(true, 'id =', ex).argInSql
            ex.setSql('update t set v = 1 where ${name.value('bob').done()} and ${id.value(Int64(7)).done()}').update
            ()
        }
        @Assert(true, captured.sql.contains('name = bob'))
        @Assert(true, captured.sql.contains('id = 7'))
        @Assert(0, captured.args.size)
    }

    /** ③-1 `argInSql` + 非 `ToString` 但可绑定（`InputStream`）：仍是 `?` + 绑定参数 */
    @TestCase
    public func testArgInSqlBindsInputStreamValue(): Unit {
        let captured = run {ex =>
            let cond = MeetCondition(true, 'data =', ex).argInSql
            ex.setSql('update t set v = 1 where ${cond.value(ProbeStream()).done()}').update
            ()
        }
        @Assert(true, captured.sql.contains('data = ?'))
        @Assert(1, captured.args.size)
    }

    /** ③-2 `argInSql` + 非 `ToString` 且不可绑定：拼 SQL 阶段抛 `SqlException: Unsupported data type` */
    @TestCase
    public func testArgInSqlThrowsForUnsupportedNonToStringValue(): Unit {
        var caught = false
        try {
            run {ex =>
                let cond = MeetCondition(true, 'name =', ex).argInSql
                ex.setSql('update t set v = 1 where ${cond.value(OpaqueValue()).done()}').update
                ()
            }
            ()
        } catch (_: SqlException) {
            caught = true
        }
        @Assert(true, caught)
    }

    /** ④ `IN` 逐元素判定：`ToString` 元素内联、可绑定的非 `ToString` 元素绑定，可混在同一个列表里 */
    @TestCase
    public func testArgInSqlInListMixesInlineAndBoundElements(): Unit {
        let captured = run {ex =>
            let cond = MeetCondition(true, '', ex).argInSql
            let values: Array<Any> = [Int64(1), ProbeStream()]
            ex.setSql('update t set v = 1 where id in ${cond.IN(values)}').update
            ()
        }
        @Assert(true, captured.sql.contains('in (1,?)'))
        @Assert(1, captured.args.size)
    }

    /** ⑤ `LoopCondition.argInSql` 同样按元素内联 */
    @TestCase
    public func testLoopArgInSqlInlinesElements(): Unit {
        let captured = run {ex =>
            let inSql = Condition.loop<Array<Int64>, Int64>([Int64(1), Int64(2)], ex)
                .wrap('(', ')')
                .delimiter(',')
                .partial {v, i => v}
                .argInSql
                .done()
            ex.setSql('update t set v = 1 where id in ${inSql}').update
            ()
        }
        @Assert(true, captured.sql.contains('( 1 , 2 )'))
        @Assert(0, captured.args.size)
    }

    /** ⑤ `ChooseCondition.argInSql`：命中分支的 `ToString` 值内联；`()` 值只写片段 */
    @TestCase
    public func testChooseArgInSqlInlinesValueAndUnitBranch(): Unit {
        let captured = run {ex =>
            // partial / otherwise 的实参先落到带类型的变量上：直接写字面 lambda 会在
            // () -> (String, Any) / () -> String / () -> Any 三个重载之间产生歧义
            let value42: () -> Any = {=> Int64(42)}
            let unitPartial: () -> String = {=> '1 = 1'}
            let hit = ChooseCondition(ex).argInSql
                .condition {true}
                .partial(value42)
                .otherwise(unitPartial)
                .done()
            let miss = ChooseCondition(ex).argInSql
                .condition {false}
                .partial(value42)
                .otherwise(unitPartial)
                .done()
            ex.setSql('update t set v = ${hit} where ${miss}').update
            ()
        }
        @Assert(true, captured.sql.contains('42'))
        @Assert(true, captured.sql.contains('1 = 1'))
        @Assert(0, captured.args.size)
    }
}
