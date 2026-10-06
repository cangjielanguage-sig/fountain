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
import std.time.DateTime
import fountain::f_mockdb.*
import fountain::f_data.*
import fountain::f_orm.wrap.*

/**
 * `RootDAO.arg(value: Any)` 单值入口的两条护栏（bug-orm.md ORM-N3）。
 *
 * 1. 每个受支持类型（含 Data 包装值）都必须命中具体分支并返回 `'?'`——分支缺失会走兜底 `throw SqlArgException`，
 *    因此「不抛且为 `'?'`」即证明该类型的分支仍在；`Data` 分支被挪到末尾后，这一条同时是它的可达性护栏；
 * 2. 分派成本护栏（相对口径，抗机器负载）：`arg(Any=Int64)` 的每元素耗时不得超过类型化 `arg(Int64)` 的 10 倍
 *    +1µs 容差。修复前实测 12.1µs/元素 vs 45ns/元素（≈270×）⇒ 必被拦住；修复后两者都在百纳秒级（≈1.5×）⇒ 余量充足。
 *
 * `arg` 命中分支时会把参数绑进执行器（`arg(x)` 内部调 `executor.add`），故逐条之间 `clearSql()` 复位。
 */
@Test
public class ArgAnyBindingTest {
    @TestCase
    public func testEverySupportedTypeStillBinds(): Unit {
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        let bin: Array<Byte> = [UInt8(1), UInt8(2)]
        let nInt64: ?Int64 = None<Int64>
        let cases: Array<(String, Any)> = [
            ('bool', true),
            ('int8', Int8(1)),
            ('uint8', UInt8(1)),
            ('int16', Int16(1)),
            ('uint16', UInt16(1)),
            ('int32', Int32(1)),
            ('uint32', UInt32(1)),
            ('int64', Int64(1)),
            ('uint64', UInt64(1)),
            ('float32', Float32(1.5)),
            ('float64', 1.5),
            ('rune', r'a'),
            ('string', 'x'),
            ('duration', Duration.second),
            ('datetime', DateTime.now()),
            ('arraybyte', bin),
            ('dataString', DataString('x')),
            ('dataReal', DataReal(Int8(1))),
            ('nbool', Some(true)),
            ('nint64', Some(Int64(1))),
            ('nnull', nInt64)
        ]
        var bad = ''
        try {
            for ((tag, v) in cases) {
                ex.clearSql()
                let sql = ex.arg(v)
                if (sql != '?') {
                    bad += '${tag}(arg=${sql}) '
                }
            }
            @Assert('', bad)
        } finally {
            ex.close()
        }
    }

    @TestCase
    public func testArgAnyDispatchCostIsBounded(): Unit {
        ORM.register(DriverManager.getDriver(ORMConfig.mockdb).getOrThrow(), 'mockdb://', default: true)
        let ex = ORM.executor(ORMConfig.mockdb)
        let n: Int64 = 1000
        let v: Any = Int64(1)
        try {
            ex.clearSql()
            var t0 = DateTime.now()
            for (i in 0..n) {
                ex.arg(Int64(1))
            }
            let typed = (DateTime.now() - t0).toNanoseconds() / n
            ex.clearSql()
            t0 = DateTime.now()
            for (i in 0..n) {
                ex.arg(v)
            }
            let anyNs = (DateTime.now() - t0).toNanoseconds() / n
            println('ORM-N3 计时: arg(Int64)=${typed}ns/元素 arg(Any=Int64)=${anyNs}ns/元素')
            @Assert(true, anyNs <= typed * 10 + 1000)
        } finally {
            ex.close()
        }
    }
}
