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
 * 批量参数/条件拼接的 SQL 文本口径（bug-orm.md ORM-N1 / N1a 的等价性护栏）。
 *
 * 期望值是**改动前构建的实测字面量**（含空格等细节，别凭直观手写）：append 合并、分隔符预拼、空片段跳过
 * 这类纯拼接优化必须保证文本逐字节不变。参数绑定顺序不受文本拼装顺序影响，但文本本身不许漂移。
 *
 * `arg*` 系列会把参数绑进执行器（`arg(x)` 内部调 `executor.add`），故每步之间 `clearSql()` 复位。
 */
@Test
public class ArgSqlTextTest {
    @TestCase
    public func testBatchSqlTextUnchanged(): Unit {
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        let ids = ArrayList<Int64>()
        for (i in 0..3) {
            ids.add(Int64(i))
        }
        let empty = ArrayList<Int64>()
        let withNull = ArrayList<?Int64>()
        withNull.add(Some(Int64(1)))
        withNull.add(None<Int64>)
        let mixed = ArrayList<Any>()
        mixed.add(Int64(1))
        mixed.add('x')
        mixed.add(true)
        let tuplePartial: (Int64, Int64) -> (String, Any) = {v, i => ('v${i} = ?', v)}
        // Any 版 partial：frag 恒为 ''（用来钉「空片段跳过」这条路径）。这里返回下标而不是元素，
        // 只是为了用掉 i 参数；本用例只钉 SQL 文本，绑定值由别的用例负责。
        let anyPartial: (Int64, Int64) -> Any = {v, i => i}
        var bad = ''

        func check(tag: String, expected: String, actual: String): Unit {
            if (actual != expected) {
                bad += '${tag}: 期望[${expected}] 实得[${actual}]; '
            }
        }
        ex.clearSql()
        check('arg3', ' (?,?,?)', ex.arg<ArrayList<Int64>, Int64>(ids))
        ex.clearSql()
        check('argEmpty', '', ex.arg<ArrayList<Int64>, Int64>(empty))
        ex.clearSql()
        check('argNull2', ' (?,?)', ex.arg<ArrayList<?Int64>, ?Int64>(withNull))
        ex.clearSql()
        check('argMixed3', ' (?,?,?)', ex.arg<ArrayList<Any>, Any>(mixed))
        ex.clearSql()
        check('IN3', 'c1  in (?,?,?)  ', ex.meet(true, 'c1').IN(ids))
        ex.clearSql()
        check('NOTIN3', 'c1  not in (?,?,?)  ', ex.meet(true, 'c1').NOT_IN(ids))
        ex.clearSql()
        check('loopAny', '   ? , ? , ?    ',
            Condition.loop<ArrayList<Int64>, Int64>(ids, ex).delimiter(',').partial(anyPartial).done())
        ex.clearSql()
        check('loopTuple', '   v0 = ?? , v1 = ?? , v2 = ??    ',
            Condition.loop<ArrayList<Int64>, Int64>(ids, ex).delimiter(',').partial(tuplePartial).done())
        ex.close()
        @Assert('', bad)
    }
}
