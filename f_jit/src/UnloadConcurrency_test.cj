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
import fountain::f_jit.base.ErrCode

/**
 * 并行调用中的单元生命周期（`feat-f-jit-parallel-call` P5.2）。
 *
 * `close(timeout)` 的契约：先拒绝新调用（19），再等**所有线程**的在飞调用排空；
 * 超时则回退到可用态（不是半个终态）。
 */
@Test
public class UnloadConcurrency_test {

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    private static func spinUnit(): JitFunction {
        CompileCache.reset()
        UnloadConcurrency_test.compiler().compile(
            '{ n: Int64 => var i = 0\n while (i < n) { i = i + 1 }\n i }')
    }

    /** 4 线程在飞时 `close`：等待排空并返回 true；期间新调用一律 19。 */
    @TestCase
    public func closeDrainsInFlightCallsAndRejectsNewOnes(): Unit {
        let f = UnloadConcurrency_test.spinUnit()
        let n = Int64(3000000)
        @Assert(f.call<Int64>([Int64(1000)]), 1000)
        let started = AtomicInt64(0)
        let futures = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            futures.add(spawn {
                let _ = started.fetchAdd(1)
                try {
                    let r = f.call<Int64>([n])
                    if (r == n) { 0 } else { 1 }
                } catch (e: JitException) {
                    if (e.code == ErrCode.CALL_CONTRACT) { 2 } else { 3 }
                }
            })
            t = t + 1
        }
        while (started.load() < 4) {}
        sleep(Duration.millisecond * 2)
        @Assert(f.close(10000), true)
        var code: Int64 = 0
        try {
            let _ = f.call<Int64>([Int64(1)])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
        var ok = 0
        var rejected = 0
        for (x in futures) {
            let v = x.get()
            @Assert(v == 0 || v == 2, true)
            if (v == 0) {
                ok = ok + 1
            }
            if (v == 2) {
                rejected = rejected + 1
            }
        }
        @Assert(ok + rejected, 4)
    }

    /** `close(0)` 在飞时超时 ⇒ 返回 false、单元回退可用态，随后调用正常。 */
    @TestCase
    public func closeTimeoutFallsBackToUsableUnit(): Unit {
        let f = UnloadConcurrency_test.spinUnit()
        let started = AtomicInt64(0)
        let w = spawn {
            let _ = started.fetchAdd(1)
            try {
                let _ = f.call<Int64>([Int64(20000000)])
            } catch (_: Exception) {
                ()
            }
            0
        }
        while (started.load() < 1) {}
        sleep(Duration.millisecond * 1)
        @Assert(f.close(0), false)
        @Assert(f.isClosed(), false)
        @Assert(w.get(), 0)
        @Assert(f.call<Int64>([Int64(5)]), 5)
        @Assert(f.close(0), true)
    }
}
