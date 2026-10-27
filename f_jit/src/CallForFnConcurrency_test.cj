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

/**
 * A6.1（P2-4）：`callForFn` 全流程串行化。
 *
 * `lastEscaped` 是单元级字段：旧实现在 `callMtx` **之外**读取它，两个线程会交换提升组
 * （一侧 `close` 提前释放另一侧的捕获）；且读后不清，跨调用残留（把上一次的组当成这次的）。
 */
@Test
public class CallForFnConcurrency_test {

    /** 取完即清：`callForFn` 返回后单元上不再挂提升组。 */
    @TestCase
    public func p2_4_lastClosureGroupIsCleared(): Unit {
        let unit = CallForFnConcurrency_test.unit()
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w.call<Int64>([41]), 42)
        @Assert(unit.lastPromotionGroup().isNone(), true)
        w.unload()
    }

    /** 两线程各自 `callForFn` + 调用 + `close`：结果互不串、无提前释放。 */
    @TestCase
    public func p2_4_callForFnSerialized(): Unit {
        let unit = CallForFnConcurrency_test.unit()
        let futures = ArrayList<Future<Unit>>()
        var t = 0
        while (t < 2) {
            let base = Int64(t * 100)
            futures.add(spawn {
                var i = 0
                while (i < 20) {
                    let w = unit.callForFn<(Int64) -> Int64>([])
                    @Assert(w.call<Int64>([base + i]), base + i + 1)
                    w.unload()
                    i = i + 1
                }
            })
            t = t + 1
        }
        for (f in futures) {
            f.get()
        }
    }

    private static func unit(): JitFunction {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        CompileCache.reset()
        c.compile('{ => let f = { x: Int64 => x + 1 }\n f }')
    }
}
