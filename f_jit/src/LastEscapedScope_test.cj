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

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.runtime.HandleTable

/**
 * `lastEscaped` 的并发口径（H3）。
 *
 * 两个线程用普通 `call<JitClosureId>` 反复返回闭包（持续写单元级 `lastEscaped`），
 * 另两个线程同时用 `callForFn` 取包装并调用。`callForFn` 走本次调用私有的 `CallOut`，
 * 因此**不应**受对方写 `lastEscaped` 的影响：结果必须全部正确、关闭后句柄回基线。
 *
 * 这条用例不验证 `lastEscapedClosure()` 的返回值（并发下本就无确定含义，见其文档），
 * 只验证它不会污染 `callForFn` 这条生产路径。
 */
@Test
public class LastEscapedScope_test {
    @TestCase
    public func concurrentCallsDoNotDisturbCallForFn(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let unit = c.compile('{ => let base = 100\n { x: Int64 => x + base } }')
        let probe = unit.callForFn<(Int64) -> Int64>([])
        @Assert(probe.call<Int64>([Int64(1)]), 101)
        probe.close()
        let liveBase = HandleTable.liveCount()
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            let tid = Int64(t)
            fs.add(spawn {
                var bad = 0
                var i = 0
                if (tid % 2 == 0) {
                    // 制造争用：普通 call 返回闭包，每次写单元级 lastEscaped。
                    while (i < 40) {
                        let _ = unit.call<JitClosureId>([])
                        i = i + 1
                    }
                } else {
                    while (i < 40) {
                        let w = unit.callForFn<(Int64) -> Int64>([])
                        let n = tid * 1000 + Int64(i)
                        if (w.call<Int64>([n]) != n + 100) {
                            bad = bad + 1
                        }
                        w.close()
                        i = i + 1
                    }
                }
                bad
            })
            t = t + 1
        }
        var bad = 0
        for (x in fs) {
            bad = bad + x.get()
        }
        @Assert(bad, 0)
        // 普通 call 登记但未承接的提升组，由单元卸载兜底释放。
        @Assert(unit.close(5000), true)
        @Assert(HandleTable.liveCount(), liveBase)
    }
}
