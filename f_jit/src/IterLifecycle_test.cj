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
package fountain::f_jit

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ErrCode
import fountain::f_jit.bytecode.ConstMapKey
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.HelperFail
import fountain::f_jit.runtime.IterTable

/**
 * A5.2（P2-2a）：迭代器表是**调用级**资源——桥在 `finally` 收尾清空。
 *
 * 断言方式是「桥外先开一个游标，再跑一次无关调用」：调用结束游标必须失效（99），
 * 否则跨调用的陈旧游标会读到下一次调用的 Map（旧实现从不清空）。
 */
@Test
public class IterLifecycle_test {

    @TestCase
    public func p2_2_bridgeClearsIterTableAtCallEnd(): Unit {
        HandleTable.resetForTest()
        IterTable.clearAll()
        let m = HashMap<ConstMapKey, Any>()
        m.add(ConstMapKey('k', 's:k'), Int64(1))
        let h = HandleTable.pin(m)
        let cur = IterTable.open(h, 0u8)
        @Assert(IterTable.liveCount(), 1)
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        CompileCache.reset()
        let f = c.compile('{ => 1 }')
        @Assert(f.call<Int64>([]), 1)
        @Assert(IterTable.liveCount(), 0)
        var code = 0
        try {
            let _ = IterTable.next(cur)
        } catch (e: HelperFail) {
            code = e.code
        }
        @Assert(code, ErrCode.HELPER_PANIC)
    }
}
