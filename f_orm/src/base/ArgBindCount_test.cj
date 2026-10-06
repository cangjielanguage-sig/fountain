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
import fountain::f_orm.wrap.*

/**
 * bug-orm.md `ORM-N1`（B：`arg<I,T>` 占位符整段预拼）的**绑定侧**护栏。
 *
 * 文本口径由 `ArgSqlText_test` 的字面量断言钉住；这里钉住另一面：**占位符个数必须等于绑定参数个数**。
 * B 的不变量是「每个元素恰好绑定 1 个参数、占位符由函数尾统一给一次」——
 * 若将来有人把 match 分支改成 `frag.append(arg(x))`（双重添加），文本会翻倍、绑定数不变；
 * 若某分支漏绑定，文本仍对、参数会少。两种都会在这条断言上暴露。
 */
@Test
public class ArgBindCountTest {
    @TestCase
    public func testPlaceholderCountMatchesBoundParams(): Unit {
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        let problems = ArrayList<String>()
        MOCKDB.clear()
        MOCKDB.execution = {sql: String, args: ArrayList<Any> =>
            // 数 `?`：按字节数（`String.split` 的 removeEmpty 语义不适合当计数器；这个写法在 f_mockdb 里已有先例）
            var placeholders = 0
            for (b in sql.toArray()) {
                if (b == b'?') {
                    placeholders++
                }
            }
            if (placeholders != args.size) {
                problems.add('sql 里 ${placeholders} 个 ?，但绑定了 ${args.size} 个参数: [${sql}]')
            }
            MOCKDB.addQueryResultColumnInfo(name: 'n', nullable: false, typeName: 'SqlBigInt')
            MOCKDB.addQueryResultRow([1])
        }
        let ids = ArrayList<Int64>()
        for (i in 0..7) {
            ids.add(Int64(i))
        }
        var thrown = ''
        try {
            ex.setSql('select 1 as n where 1 in${ex.arg<ArrayList<Int64>, Int64>(ids)}').first<Int64>()
        } catch (e: Exception) {
            thrown = e.message
        }
        ex.clearSql()
        let detail = if (problems.size > 0) {
            problems[0]
        } else {
            thrown
        }
        @Assert('', detail)
    }
}
