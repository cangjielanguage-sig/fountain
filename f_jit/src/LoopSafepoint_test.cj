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

import std.time.{DateTime, MonoTime}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.{CallContext, DummyDiagnosticsSink, InterruptedException}
import fountain::f_jit.runtime.RuntimeEnv

/**
 * 回边安全点**按需发射**（`optimize-loop-safepoint`）。
 *
 * 实现把「每回边无条件 `interrupt_poll`」改为「仅当本次调用带 deadline 时才调」。
 * 本套用例锁两件事：
 *
 * 1. 无期限调用不因跳过 poll 而改变行为（正常跑完、不设错误码）；
 * 2. **有期限调用仍必须被中断** —— 「按需」不等于「永不」，这条是改错时的第一道红灯
 *    （与本文件外的 `AnyBridgeCall_test.p0_6_deadlineInterruptsLoop` 互补）。
 */
@Test
public class LoopSafepoint_test {
    private static func loopUnit(): JitFunction {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        CompileCache.reset()
        c.compile('{ n: Int64 => var i = 0\n while (i < n) { i = i + 1 }\n i }')
    }

    /** 无期限：长循环正常跑完（回边安全点对无期限调用是空操作）。 */
    @TestCase
    public func unboundedLoopRunsToCompletion(): Unit {
        RuntimeEnv.clearDeadline()
        let f = LoopSafepoint_test.loopUnit()
        let n = Int64(200000)
        @Assert(f.call<Int64>([n]), n)
        // 显式空 context（deadline = None）走同一条 create 路径。
        @Assert(f.call<Int64>([n], CallContext()), n)
        @Assert(RuntimeEnv.deadlineNanos, -1)
    }

    /**
     * 有期限且已过期：紧循环必须在**回边**被中断。
     *
     * 轮数取 1e7：正常实现第一轮回边就 −2（毫秒级返回）；若实现误把「带期限」也跳过 poll，
     * 本用例会在约 7 秒后返回 n 并断言失败 —— 变异验证能快速拿到红灯。
     */
    @TestCase
    public func boundedLoopStillInterrupts(): Unit {
        let f = LoopSafepoint_test.loopUnit()
        var interrupted = false
        try {
            let _ = f.call<Int64>([Int64(10000000)], CallContext(deadline: Some(DateTime.UnixEpoch)))
        } catch (_: InterruptedException) {
            interrupted = true
        }
        RuntimeEnv.clearDeadline()
        @Assert(interrupted, true)
    }

    /** 软观测：每轮成本（best-of-3）。**不设硬门槛**，避免共享 VM 高负载造成假失败。 */
    @TestCase
    public func loopPerIterCost(): Unit {
        let f = LoopSafepoint_test.loopUnit()
        let n = Int64(2000000)
        @Assert(f.call<Int64>([Int64(1000)]), 1000)
        var best = Int64.Max
        var r = 0
        while (r < 3) {
            let t0 = MonoTime.now()
            // 断言返回值：确认循环真跑完，不是被优化成闭式结果。
            @Assert(f.call<Int64>([n]), n)
            let d = (MonoTime.now() - t0).toNanoseconds()
            if (d < best) {
                best = d
            }
            r = r + 1
        }
        println('LOOP-SAFEPOINT perIterNs=' + (best / n).toString() +
            ' jitBacked=' + (if (f.isJitBacked()) { 1 } else { 0 }).toString())
        @Assert(true, true)
    }
}
