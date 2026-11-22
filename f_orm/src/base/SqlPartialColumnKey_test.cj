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

import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.macros.*
import fountain::f_mockdb.*
import fountain::f_orm.macros.*
import fountain::f_orm.wrap.*

/** UPDATE 的 Column 键测试实体：`nick` 的列名与字段名不同，用来覆盖两种 key。 */
@DataAssist[fields]
@QueryMappersGenerator[table: orm_update_probe]
public class OrmUpdateProbe {
    @ORMField[id column: 'id']
    private var id: Int64 = 0
    @ORMField['name']
    private var name: String = ''
    @ORMField['age']
    private var age: Int64 = 0
    @ORMField['nick_name']
    private var nick: ?String = None
}

/** `Any` 没有 `toString` 成员：按 `ToString` 能力取文本。 */
private func anyText(a: Any): String {
    match (a) {
        case x: ToString => x.toString()
        case _ => ''
    }
}

/** 捕获一次 UPDATE 的 SQL 与绑定参数。 */
private class CapturedUpdate {
    let sqls = ArrayList<String>()
    let args = ArrayList<Any>()

    func lastSql(): String {
        if (this.sqls.size == 0) {
            ''
        } else {
            this.sqls[this.sqls.size - 1]
        }
    }

    func lastArgs(): ArrayList<Any> {
        let from = this.lastArgStart
        let out = ArrayList<Any>()
        for (i in from..this.args.size) {
            out.add(this.args[i])
        }
        out
    }

    var lastArgStart: Int64 = 0

    func text(): String {
        let parts = ArrayList<String>()
        for (a in this.lastArgs()) {
            parts.add(anyText(a))
        }
        parts.toString()
    }

    func resetWindow(): Unit {
        this.lastArgStart = this.args.size
    }
}


@Test
public class SqlPartialColumnKey_test {
    private func executor(captured: CapturedUpdate): SqlExecutor {
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        MOCKDB.clear()
        MOCKDB.execution = {sql: String, args: ArrayList<Any> =>
            captured.sqls.add(sql)
            for (a in args) {
                captured.args.add(a)
            }
        }
        ex
    }

    /** 捕获一次调用：SQL 文本与本次绑定参数。 */
    private func runOnce(ex: SqlExecutor, captured: CapturedUpdate, action: () -> Unit): (String, String) {
        captured.resetWindow()
        let before = captured.sqls.size
        action()
        if (captured.sqls.size <= before) {
            return ('', '')
        }
        (captured.lastSql(), captured.text())
    }

    @TestCase
    public func arrayOverloadMatchesMapOverload(): Unit {
        let captured = CapturedUpdate()
        let ex = this.executor(captured)

        let values: Array<(Column, Any)> = [
            (Column('name'), 'n'),
            (Column('age'), 1),
            (Column('id'), 7)
        ]
        let map = HashMap<String, Any>()
        map['name'] = 'n'
        map['age'] = 1
        map['id'] = 7

        let (arraySql, arrayArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe>(values) })
        let (mapSql, mapArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe>(map) })
        @Assert(mapSql, arraySql)
        @Assert(mapArgs, arrayArgs)
        @Assert(true, arraySql.contains('UPDATE'))
        @Assert(true, arraySql.contains('WHERE'))
    }

    @TestCase
    public func arrayOverloadWithIdUsesExplicitId(): Unit {
        let captured = CapturedUpdate()
        let ex = this.executor(captured)

        let values: Array<(Column, Any)> = [
            (Column('name'), 'n'),
            (Column('age'), 1),
            (Column('id'), 7)
        ]
        let map = HashMap<String, Any>()
        map['name'] = 'n'
        map['age'] = 1
        map['id'] = 7

        let (arraySql, arrayArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe, Int64>(values, 42) })
        let (mapSql, mapArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe, Int64>(map, 42) })
        @Assert(mapSql, arraySql)
        @Assert(mapArgs, arrayArgs)
        @Assert(true, arrayArgs.contains('42'))
    }

    @TestCase
    public func columnMapOverloadMatchesStringMap(): Unit {
        let captured = CapturedUpdate()
        let ex = this.executor(captured)

        let values = HashMap<Column, Any>()
        values[Column('name')] = 'n'
        values[Column('age')] = 1
        values[Column('id')] = 7
        let map = HashMap<String, Any>()
        map['name'] = 'n'
        map['age'] = 1
        map['id'] = 7

        let (columnSql, columnArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe>(values) })
        let (mapSql, mapArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe>(map) })
        @Assert(mapSql, columnSql)
        @Assert(mapArgs, columnArgs)
    }

    @TestCase
    public func columnMapOverloadWithIdMatches(): Unit {
        let captured = CapturedUpdate()
        let ex = this.executor(captured)

        let values = HashMap<Column, Any>()
        values[Column('name')] = 'n'
        values[Column('age')] = 1
        let map = HashMap<String, Any>()
        map['name'] = 'n'
        map['age'] = 1

        let (columnSql, columnArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe, Int64>(values, 9) })
        let (mapSql, mapArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe, Int64>(map, 9) })
        @Assert(mapSql, columnSql)
        @Assert(mapArgs, columnArgs)
        @Assert(true, columnArgs.contains('9'))
    }

    /** 字段名键与列名键命中同一列：`nick` 与 `nick_name` 产生相同 SQL。 */
    @TestCase
    public func fieldNameAndColumnNameBothResolve(): Unit {
        let captured = CapturedUpdate()
        let ex = this.executor(captured)

        let values: Array<(Column, Any)> = [
            (Column('nick'), 'n1'),
            (Column('id'), 7)
        ]
        let map = HashMap<String, Any>()
        map['nick_name'] = 'n1'
        map['id'] = 7

        let (fieldSql, fieldArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe>(values) })
        let (columnSql, columnArgs) = this.runOnce(ex, captured, {=> ex.UPDATE<OrmUpdateProbe>(map) })
        @Assert(columnSql, fieldSql)
        @Assert(columnArgs, fieldArgs)
    }
}
