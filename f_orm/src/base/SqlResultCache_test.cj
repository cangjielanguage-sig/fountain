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
 * 结果缓存必须按「SQL 文本 + 参数」区分（bug.md §1.1 / ORM-1）。
 *
 * 前提（设计如此，不是缺陷）：同一线程复用同一个 SqlExecutor；事务内连接与结果缓存都跨查询存活，
 * 非事务路径每执行完一个 DAO 函数就归还连接并清空 Sql/参数（`close()` 里带 `tx.isNone()` 守卫地清缓存）。
 * 因此验证「缓存命中/误命中」必须把两次查询放在同一个 `execute { e => (..., true) }` 事务作用域内。
 *
 * 每个用例用各自的 SQL 文本：executor 与缓存按线程复用，用例之间若共用 SQL 文本会互相污染。
 */
@Test
public class SqlResultCacheTest {
    /**
     * mock 行为：把第一个绑定参数原样作为查询结果返回。
     *
     * 结果行每轮先清空——MOCKDB 的结果行是累积的（`getQueryResultRows()` 返回活列表），
     * 且必须走 `addQueryResultRow`：内部列表尚未创建时，直接往 `getQueryResultRows()` 的返回值里
     * add 只会加到临时空表上，`MockQueryResult` 会取到空行集（表现为取值恒为 None）。
     */
    private func setupMockEchoArg(): Unit {
        MOCKDB.execution = {_: String, args: ArrayList<Any> =>
            let rows = MOCKDB.getQueryResultRows()
            rows.clear()
            MOCKDB.addQueryResultRow([args[0]])
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlBigInt')
        }
    }

    /**
     * 同一 executor 上、同一 SQL 文本、**不同参数**的两次查询不得互相命中缓存。
     *
     * 修复前的失败形态：两次查询共用 executor 的同一个 SqlArgs 实例（第一次执行后原地清空、第二次再填充），
     * 两个 SqlCacheKey 因 `SqlArgs.==` 的 refEq 短路而相等，第二次查询直接命中第一次的缓存结果。
     */
    @TestCase
    public func testSameSqlDifferentArgsMustNotHitCache(): Unit {
        setupMockEchoArg()
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)

        // 参数用显式 Int64 变量：整数字面量在 SqlExecutor 的多个 add 重载间有歧义
        let p1: Int64 = 1
        let p2: Int64 = 2
        let values = ex.execute {e: SqlExecutor =>
            let first = e.setSql('select ? as case1').add(p1).first<Int64>()
            let second = e.setSql('select ? as case1').add(p2).first<Int64>()
            ([first, second], true)
        }

        @Assert(Some(1), values[0])
        @Assert(Some(2), values[1])
        ex.close()
    }

    /**
     * 同一参数重复查询必须命中缓存（保证修复没有把缓存修成「永不命中」）。
     *
     * 用计数器记 mock 调用次数：命中缓存时第二次查询不会再落到 mock（计数应为 1）。
     * 这里用 `Box<Int64>` 捕获，Cangjie 不允许闭包直接捕获可变局部 var。
     */
    @TestCase
    public func testSameSqlSameArgsStillHitsCache(): Unit {
        let p: Int64 = 7
        let fires = Box<Int64>(0)
        MOCKDB.execution = {_: String, args: ArrayList<Any> =>
            fires.value++
            let rows = MOCKDB.getQueryResultRows()
            rows.clear()
            MOCKDB.addQueryResultRow([args[0]])
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlBigInt')
        }
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)

        let values = ex.execute {e: SqlExecutor =>
            let first = e.setSql('select ? as case2').add(p).first<Int64>()
            let second = e.setSql('select ? as case2').add(p).first<Int64>()
            ([first, second], true)
        }

        @Assert(Some(7), values[0])
        @Assert(Some(7), values[1])
        @Assert(1, fires.value)
        ex.close()
    }

    /**
     * 缓存键必须只由「SQL 文本 + 参数内容」决定：两个内容相同的 SqlArgs 实例，
     * 其 SqlCacheKey 必须相等、哈希必须相同（否则换实例的修复会让缓存永不命中）。
     */
    @TestCase
    public func testCacheKeyMustDependOnArgsContent(): Unit {
        let p: Int64 = 7
        let a1 = SqlArgs()
        a1.add(p)
        let a2 = SqlArgs()
        a2.add(p)
        let key1 = SqlCacheKey('select ? as content', a1)
        let key2 = SqlCacheKey('select ? as content', a2)
        @Assert(a1.hashCode(), a2.hashCode())
        @Assert(key1.hashCode(), key2.hashCode())
        @Assert(true, key1 == key2)
    }
}
