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
import fountain::f_orm.exception.*

/**
 * 迭代器必须把结果集的所有权握在手里（bug.md §1.5 / ORM-C1）。
 *
 * 修复前的失败形态：`iterator`/`singleIterator` 在 `execute<T>` 的 `finally` 里就把结果集关了，
 * 方法一返回 `next()` 就再也读不到行；非事务路径还会连带归还 Statement 与 Connection。
 *
 * 修复后：返回时可逐行读；读尽或 `close()` 时释放结果集——不在事务中时一并关闭
 * Statement 与 Connection，在事务中只关结果集（其余留给事务结束后的 `SqlExecutor.close()`）。
 */
@Test
public class QueryResultIteratorTest {
    /** 夹具：每次执行产出 3 行 Int64（列名 v），按「执行时清空 + 重新写入」的口径 */
    private func setupRows(): Unit {
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            let rows = MOCKDB.getQueryResultRows()
            rows.clear()
            MOCKDB.addQueryResultRow([Int64(1)])
            MOCKDB.addQueryResultRow([Int64(2)])
            MOCKDB.addQueryResultRow([Int64(3)])
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlBigInt')
        }
    }

    /** 非事务：返回后可逐行读；读尽自动关闭，并随之关闭 Statement 与 Connection */
    @TestCase
    public func testIteratorReadsRowsAfterReturnAndClosesOnExhaustion(): Unit {
        setupRows()
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)

        let it = ex.setSql('select v from t_iter1 order by v').singleIterator<Int64>()
        @Assert(false, it.isClosed())
        @Assert(false, ex.isClosed())
        @Assert(Some(1), it.next())
        @Assert(Some(2), it.next())
        @Assert(Some(3), it.next())
        @Assert(None, it.next())
        @Assert(true, it.isClosed())
        // 非事务：读尽即收尾，Statement 与 Connection 已关闭
        @Assert(true, ex.isClosed())
        // 关闭后继续 next() 保持 None，不再读到底层
        @Assert(None, it.next())
    }

    /** 事务中：close() 关结果集与语句，但不动连接，同一事务里可以继续执行 SQL */
    @TestCase
    public func testIteratorCloseInTransactionKeepsConnection(): Unit {
        setupRows()
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)

        let second = ex.execute {e: SqlExecutor =>
            let it = e.setSql('select v from t_iter2 order by v').singleIterator<Int64>()
            @Assert(false, it.isClosed())
            @Assert(Some(1), it.next())
            it.close()
            @Assert(true, it.isClosed())
            // 事务中只关结果集：连接还活着
            @Assert(false, e.isClosed())
            // 结果集释放后，同一事务里可以继续查询
            let v = e.setSql('select v from t_iter2_second order by v').first<Int64>()
            (v, true)
        }

        @Assert(Some(1), second)
        // 事务结束后的 close() 才归还 Statement/Connection
        @Assert(true, ex.isClosed())
    }

    /** 未关闭的迭代器持活结果集：同一 executor 上再查询必须被拒绝（保护结果集与连接） */
    @TestCase
    public func testActiveIteratorBlocksNextQuery(): Unit {
        setupRows()
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)

        let it = ex.setSql('select v from t_iter3 order by v').singleIterator<Int64>()
        var blocked = false
        try {
            ex.setSql('select v from t_iter3_other order by v').first<Int64>()
        } catch (_: ORMException) {
            blocked = true
        }
        @Assert(true, blocked)

        // 关闭后恢复可用（非事务：executor 随之归还连接，下一条查询会重新取连接）
        it.close()
        @Assert(Some(1), ex.setSql('select v from t_iter3_second order by v').first<Int64>())
    }

    /** 实现 Resource：可放进 try-with-resources，离开作用域自动关闭 */
    @TestCase
    public func testIteratorWorksWithTryWithResources(): Unit {
        setupRows()
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)

        var first: ?Int64 = None<Int64>
        try (it = ex.setSql('select v from t_iter4 order by v').singleIterator<Int64>()) {
            @Assert(false, it.isClosed())
            first = it.next()
        }
        @Assert(Some(1), first)
        // 离开作用域时自动 close()：非事务下 Statement 与 Connection 一并收尾
        @Assert(true, ex.isClosed())
    }

    /** column 重载必须按列名取值（修复前无论传什么都读第 0 列） */
    @TestCase
    public func testSingleIteratorByColumn(): Unit {
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            let rows = MOCKDB.getQueryResultRows()
            rows.clear()
            MOCKDB.addQueryResultRow([Int64(7), 'bob'])
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'SqlBigInt')
            MOCKDB.addQueryResultColumnInfo(name: 'name', nullable: false, typeName: 'SqlVarchar')
        }
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)

        // 第 0 列是 id（7），第 1 列才是 name（bob）：按列名取必须拿到 bob
        let it = ex.setSql('select id, name from t_iter5').singleIterator<String>('name')
        @Assert(Some('bob'), it.next())
        @Assert(None, it.next())
    }
}
