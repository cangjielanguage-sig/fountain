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
package fountain::f_jit.runtime

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `HostFault` 的**线程本地**语义（`optimize-call-path-phase1` P1.1）。
 *
 * 第一条用例在旧的全局表实现上必红：A 线程记录后，B 线程以同一 ctx 查询会读到 Some。
 * ctx 由调用线程创建/记录/释放，线程本地化不改变任何同线程行为。
 */
@Test
public class HostFaultTls_test {

    /** A 线程的 cause 对 B 线程不可见。 */
    @TestCase
    public func causeIsInvisibleAcrossThreads(): Unit {
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        try {
            HostFault.record(ctx, Exception('boom-on-a'))
            @Assert(HostFault.causeOf(ctx).isSome(), true)
            let f = spawn {
                var seen = 0
                if (HostFault.causeOf(ctx).isSome()) {
                    seen = 1
                }
                if (HostFault.exceptionOf(ctx).isSome()) {
                    seen = seen + 10
                }
                seen
            }
            @Assert(f.get(), 0)
            // A 线程自己的记录仍在
            @Assert(HostFault.causeOf(ctx).isSome(), true)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 两线程并发记录：各自只看到自己的 cause。 */
    @TestCase
    public func concurrentFaultsDoNotMix(): Unit {
        let f1 = spawn {
            let c = JitContext.create(hwBase: 0, hwCap: 0, fnId: 1, dbgBase: 0)
            try {
                HostFault.record(c, Exception('left'))
                var bad = 0
                match (HostFault.causeOf(c)) {
                    case Some(t) => if (!t.contains('left')) { bad = 1 }
                    case None => bad = 2
                }
                bad
            } finally {
                JitContext.free(c)
            }
        }
        let f2 = spawn {
            let c = JitContext.create(hwBase: 0, hwCap: 0, fnId: 2, dbgBase: 0)
            try {
                HostFault.record(c, Exception('right'))
                var bad = 0
                match (HostFault.causeOf(c)) {
                    case Some(t) => if (!t.contains('right')) { bad = 1 }
                    case None => bad = 2
                }
                bad
            } finally {
                JitContext.free(c)
            }
        }
        @Assert(f1.get(), 0)
        @Assert(f2.get(), 0)
    }

    /** `free` 后同一地址不再有旧 cause。 */
    @TestCase
    public func freeClearsFault(): Unit {
        let c = JitContext.create(hwBase: 0, hwCap: 0, fnId: 3, dbgBase: 0)
        HostFault.record(c, Exception('gone'))
        JitContext.free(c)
        @Assert(HostFault.causeOf(c).isNone(), true)
    }
}
