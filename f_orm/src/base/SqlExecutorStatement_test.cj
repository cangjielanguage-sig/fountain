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
import fountain::f_orm.exception.*
import fountain::f_orm.wrap.*

/**
 * `SqlExecutor` 的语句级行为契约（bug-orm.md §3.1）。
 *
 * 1. `ORM-C4`：短于 6 个字符的 SQL 不是合法语句——必须显式报 `ORMException`，而不是抛切片越界的
 *    `IndexOutOfBoundsException`（`sql` 的前缀判断与 `DatabasePool` 的 `checkSql` 同属这一条）；
 * 2. `ORM-L6`：只缓存 SELECT 的结果——非 SELECT 语句即便走查询通道，也不读、不写结果缓存
 *    （用 mock 夹具的执行次数判定：两次相同非 SELECT ⇒ 执行两次；两次相同 SELECT ⇒ 只执行一次）。
 */
@Test
public class SqlExecutorStatement_test {
    @TestCase
    public func testShortSqlIsRejectedWithOrmException(): Unit {
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        var shortThrew = false
        try {
            ex.setSql('sel')
        } catch (e: ORMException) {
            shortThrew = true
        }
        var emptyThrew = false
        try {
            ex.setSql('')
        } catch (e: ORMException) {
            emptyThrew = true
        }
        var usable = false
        try {
            ex.setSql('select 1')
            usable = true
        } catch (e: Exception) {
            usable = false
        }
        ex.close()
        @Assert(true, shortThrew)
        @Assert(true, emptyThrew)
        @Assert(true, usable)
    }

    @TestCase
    public func testCacheOnlyCachesSelect(): Unit {
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        // 计数器用对象承载：闭包捕获可变局部变量时仓颉要求「直接调用」，不能存进字段
        let execs = ArrayList<Int64>()
        MOCKDB.execution = {_s: String, _args: ArrayList<Any> =>
            execs.add(1)
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlBigInt')
        }
        execs.clear()
        ex.setSql('pragma cache_probe').first<Int64>()
        ex.setSql('pragma cache_probe').first<Int64>()
        let nonSelectExecs = execs.size
        execs.clear()
        ex.setSql('select 1 as cache_probe').first<Int64>()
        ex.setSql('select 1 as cache_probe').first<Int64>()
        let selectExecs = execs.size
        ex.close()
        @Assert(2, nonSelectExecs)
        @Assert(1, selectExecs)
    }
}
