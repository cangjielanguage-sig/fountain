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
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.runtime.HandleTable

/**
 * 并行吞吐观测（`feat-f-jit-parallel-call` P6.2）。
 *
 * **本用例不设吞吐门槛**：构建机是共享的融合 VM（7 核、常驻负载 3+），时序断言必然假失败。
 * 它只负责打印 `PAR-BENCH` 数据（1/2/4/8 线程的实际加速比）并断言结果/句柄账目正确；
 * 达标结论人工写入 `verify.md`。
 */
@Test
public class ParallelThroughput_test {

    private static func now(): Int64 {
        DateTime.nowUTC().toUnixTimeStamp().toNanoseconds()
    }

    private static func spinUnit(): JitFunction {
        CompileCache.reset()
        Compiler(CompileOptions(DummyDiagnosticsSink())).compile(
            '{ n: Int64 => var i = 0\n var s = 0\n while (i < n) { s = s + 1\n i = i + 1 }\n s }')
    }

    @TestCase
    public func printParallelScaling(): Unit {
        let f = ParallelThroughput_test.spinUnit()
        let n = Int64(2000000)
        @Assert(f.call<Int64>([n]), n)
        // T0 观测：若为 0，说明基线跑的是解释器，S2/S4/S8 不能代表机器码并行度。
        println('PAR-BENCH jitBacked=' + (if (f.isJitBacked()) { 1 } else { 0 }).toString())
        let baseLive = HandleTable.liveCount()

        let t0 = ParallelThroughput_test.now()
        @Assert(f.call<Int64>([n]), n)
        let singleNs = ParallelThroughput_test.now() - t0

        let counts = [2, 4, 8]
        for (k in counts) {
            let t1 = ParallelThroughput_test.now()
            let futures = ArrayList<Future<Int64>>()
            var t = 0
            while (t < k) {
                futures.add(spawn {
                    f.call<Int64>([n])
                })
                t = t + 1
            }
            var bad = 0
            for (x in futures) {
                if (x.get() != n) {
                    bad = bad + 1
                }
            }
            let wallNs = ParallelThroughput_test.now() - t1
            @Assert(bad, 0)
            let speedX100 = if (wallNs > 0) {
                singleNs * k * 100 / wallNs
            } else {
                0
            }
            println('PAR-BENCH threads=' + k.toString() + ' single=' + (singleNs / 1000).toString() +
                'us wall=' + (wallNs / 1000).toString() + 'us speedupX100=' + speedX100.toString())
        }
        @Assert(HandleTable.liveCount(), baseLive)
    }
}
