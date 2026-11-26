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
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.NativeMem

/**
 * 并发调用同一个 `JitFunction` 的**语义回归网**（`test-f-jit-parallel-calls`）。
 *
 * P3 起 `call` 已去掉进程级调用锁，本套直接覆盖**真实并发**：一旦交错破坏结果、错误槽、
 * 句柄账目或包装生命周期，这里会立刻变红。
 *
 * **只钉语义，不钉时序**：并行度证据（重叠执行、deadline 线程隔离）属于并行化本身的验收，不在此处。
 */
@Test
public class ParallelCall_test {

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 4 线程 × 200 次同单元调用：每次返回值都正确，且单元由机器码执行。 */
    @TestCase
    public func sameUnitConcurrentCallsAreCorrect(): Unit {
        CompileCache.reset()
        let f = ParallelCall_test.compiler().compile('{ n: Int64 => n + 1 }')
        @Assert(f.isJitBacked(), true)
        let futures = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            let base = Int64(t * 1000)
            futures.add(spawn {
                var wrong = 0
                var i = 0
                while (i < 200) {
                    let arg = base + Int64(i)
                    if (f.call<Int64>([arg]) != arg + 1) {
                        wrong = wrong + 1
                    }
                    i = i + 1
                }
                wrong
            })
            t = t + 1
        }
        for (x in futures) {
            @Assert(x.get(), 0)
        }
    }

    /** 并发下错误码稳定：每个线程都得到 `DIV_ZERO`，不被别的线程的错误槽覆盖。 */
    @TestCase
    public func concurrentCallsKeepErrorCodes(): Unit {
        CompileCache.reset()
        let f = ParallelCall_test.compiler().compile('{ x: Int64 => 100 / x }')
        let futures = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            futures.add(spawn {
                var seen = 0
                var i = 0
                while (i < 50) {
                    try {
                        let _ = f.call<Int64>([Int64(0)])
                        seen = -1
                    } catch (e: JitException) {
                        if (e.code != ErrCode.DIV_ZERO) {
                            seen = -2
                        }
                    }
                    i = i + 1
                }
                seen
            })
            t = t + 1
        }
        for (x in futures) {
            @Assert(x.get(), 0)
        }
    }

    /** 分配型单元并发调用后，句柄表回到预热后的基线（窗口全部归还）。 */
    @TestCase
    public func concurrentCallsDoNotLeakHandles(): Unit {
        CompileCache.reset()
        let f = ParallelCall_test.compiler().compile(
            '{ n: Int64 => let xs = [n, n + 1, n + 2]\n xs[0] + xs[1] + xs[2] }')
        @Assert(f.call<Int64>([Int64(1)]), 6)
        let base = HandleTable.liveCount()
        let memBase = NativeMem.outstanding()
        let futures = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            let bias = Int64(t * 100)
            futures.add(spawn {
                var wrong = 0
                var i = 0
                while (i < 100) {
                    let n = bias + Int64(i)
                    if (f.call<Int64>([n]) != n * 3 + 3) {
                        wrong = wrong + 1
                    }
                    i = i + 1
                }
                wrong
            })
            t = t + 1
        }
        for (x in futures) {
            @Assert(x.get(), 0)
        }
        @Assert(HandleTable.liveCount(), base)
        // P1.5：每线程 ctx/转储的 malloc/free 配对，原子计数回到基线
        @Assert(NativeMem.outstanding(), memBase)
    }

    /** 不同单元同时调用互不干扰。 */
    @TestCase
    public func differentUnitsRunConcurrently(): Unit {
        CompileCache.reset()
        let c = ParallelCall_test.compiler()
        let inc = c.compile('{ n: Int64 => n + 1 }')
        let dbl = c.compile('{ n: Int64 => n * 2 }')
        let f1 = spawn {
            var wrong = 0
            var i = 0
            while (i < 200) {
                if (inc.call<Int64>([Int64(i)]) != Int64(i) + 1) {
                    wrong = wrong + 1
                }
                i = i + 1
            }
            wrong
        }
        let f2 = spawn {
            var wrong = 0
            var i = 0
            while (i < 200) {
                if (dbl.call<Int64>([Int64(i)]) != Int64(i) * 2) {
                    wrong = wrong + 1
                }
                i = i + 1
            }
            wrong
        }
        @Assert(f1.get(), 0)
        @Assert(f2.get(), 0)
    }

    /** A 线程创建的闭包包装，B/C 线程可调用；`close()` 后统一失效（19）。 */
    @TestCase
    public func wrapperCreatedOnOneThreadIsCallableFromOthers(): Unit {
        CompileCache.reset()
        let unit = ParallelCall_test.compiler().compile(
            '{ => let f = { x: Int64 => x + 1 }\n f }')
        let w = unit.callForFn<(Int64) -> Int64>([])
        let f1 = spawn { w.call<Int64>([Int64(1)]) }
        let f2 = spawn { w.call<Int64>([Int64(10)]) }
        @Assert(f1.get(), 2)
        @Assert(f2.get(), 11)
        // P4：释放也换一个线程（包装的创建/调用/释放分属三个线程）。
        let f3 = spawn { w.close() }
        f3.get()
        var code: Int64 = 0
        var site: Int64 = 0
        try {
            let _ = w.call<Int64>([Int64(3)])
        } catch (e: JitException) {
            code = e.code
            site = e.site
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
        @Assert(site, -1)
    }

    /** 卸载后并发调用全部 19（site=−1），不允许部分线程拿到旧单元。 */
    @TestCase
    public func closedUnitRejectsConcurrentCalls(): Unit {
        CompileCache.reset()
        let f = ParallelCall_test.compiler().compile('{ n: Int64 => n + 1 }')
        @Assert(f.close(0), true)
        let futures = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 2) {
            futures.add(spawn {
                var bad = 0
                try {
                    let _ = f.call<Int64>([Int64(1)])
                    bad = -1
                } catch (e: JitException) {
                    if (e.code != ErrCode.CALL_CONTRACT || e.site != -1) {
                        bad = -2
                    }
                }
                bad
            })
            t = t + 1
        }
        for (x in futures) {
            @Assert(x.get(), 0)
        }
    }
}
