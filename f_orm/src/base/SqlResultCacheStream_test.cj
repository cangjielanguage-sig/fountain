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

/** 最小流：本用例只关心"结果里有没有流"，不读内容 */
private class TinyStream <: InputStream {
    public func read(buffer: Array<Byte>): Int64 {
        0
    }
}

/**
 * bug-orm.md §3.2 `ORM-C6` 陷阱 1 的 B 方案护栏：**含流的结果不进结果缓存**。
 *
 * 理由：缓存会把值留到结果集关闭之后；一旦驱动交出的是"绑定结果集/句柄的流"，缓存里就是失效值。
 * 判据按"实际读出的单元格"置位（`QueryResultWrap.hadStream`），所以没读 BLOB 列的查询仍然正常命中缓存。
 */
@Test
public class SqlResultCacheStreamTest {
    @TestCase
    public func testResultWithStreamIsNotCached(): Unit {
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        let runs = ArrayList<Int64>()
        MOCKDB.clear()
        // 含流（BLOB 列，mapList 会经 toMap 读出 InputStream）
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            runs.add(1)
            MOCKDB.addQueryResultColumnInfo(name: 'b', nullable: true, typeName: 'SqlBlob')
            MOCKDB.addQueryResultRow([TinyStream()])
        }
        ex.clearSql()
        ex.setSql('select b as t_blob_cache_probe').mapList()
        ex.setSql('select b as t_blob_cache_probe').mapList()
        let streamRuns = runs.size
        // 对照：不含流的查询，第二次应命中缓存（只执行一次）
        runs.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            runs.add(1)
            MOCKDB.addQueryResultColumnInfo(name: 'n', nullable: false, typeName: 'SqlBigInt')
            MOCKDB.addQueryResultRow([1])
        }
        ex.clearSql()
        ex.setSql('select 1 as n where 1 = 1 and t_nostream_probe = 1').first<Int64>()
        ex.setSql('select 1 as n where 1 = 1 and t_nostream_probe = 1').first<Int64>()
        let plainRuns = runs.size
        ex.close()
        @Assert(2, streamRuns)
        @Assert(1, plainRuns)
    }
}
