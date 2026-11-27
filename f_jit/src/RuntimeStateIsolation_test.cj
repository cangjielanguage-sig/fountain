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
import std.time.MonoTime
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.HostFault
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.RuntimeEnv

/**
 * 运行期线程私有状态的隔离护栏（`optimize-runtime-tls`）。
 *
 * 合并成单个 `RuntimeState` 之前/之后都必须绿：deadline、窗口栈、异常旁路三者
 * 都只能被本线程观察到，且嵌套调用按栈式恢复。
 */
@Test
public class RuntimeStateIsolation_test {

    private static func spin(ms: Int64): Unit {
        let t0 = MonoTime.now()
        while ((MonoTime.now() - t0).toMilliseconds() < ms) {}
    }

    /** 4 线程各写各的 deadline，互不串味。 */
    @TestCase
    public func deadlineIsThreadPrivate(): Unit {
        let n = 4
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < n) {
            let idx = t
            fs.add(spawn {
                RuntimeEnv.setDeadline(1000 + Int64(idx))
                RuntimeStateIsolation_test.spin(20)
                RuntimeEnv.deadlineNanos
            })
            t = t + 1
        }
        var i = 0
        for (f in fs) {
            @Assert(f.get(), 1000 + Int64(i))
            i = i + 1
        }
        RuntimeEnv.clearDeadline()
    }

    /** 4 线程各开各的窗口（容量带线程号），reset 逐层回到各自的外层/环境窗口。 */
    @TestCase
    public func windowIsThreadPrivate(): Unit {
        let n = 4
        let envCap = HandleTable.initialCapacity
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < n) {
            let idx = t
            fs.add(spawn {
                let want = 64 + Int64(idx)
                HandleTable.openWindow(want)
                let outer = HandleTable.windowCapOf()
                HandleTable.openWindow(want + 100)
                let inner = HandleTable.windowCapOf()
                HandleTable.resetWindow(-1)
                let back = HandleTable.windowCapOf()
                HandleTable.resetWindow(-1)
                let env = HandleTable.windowCapOf()
                var bad: Int64 = 0
                if (outer != want) { bad = bad + 1 }
                if (inner != want + 100) { bad = bad + 2 }
                if (back != want) { bad = bad + 4 }
                if (env != envCap) { bad = bad + 8 }
                bad
            })
            t = t + 1
        }
        var i = 0
        for (f in fs) {
            @Assert(f.get(), 0)
            i = i + 1
        }
    }

    /** 4 线程各记录各的异常 cause，互不可见；free 只清自己的。 */
    @TestCase
    public func faultIsThreadPrivate(): Unit {
        let n = 4
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < n) {
            let idx = t
            fs.add(spawn {
                let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
                var bad: Int64 = 0
                try {
                    HostFault.record(ctx, Exception('fault-${idx}'))
                    match (HostFault.causeOf(ctx)) {
                        case Some(s) => if (!s.contains('fault-${idx}')) { bad = bad + 1 }
                        case None => bad = bad + 2
                    }
                } finally {
                    JitContext.free(ctx)
                }
                match (HostFault.causeOf(ctx)) {
                    case Some(_) => bad = bad + 4
                    case None => ()
                }
                bad
            })
            t = t + 1
        }
        var i = 0
        for (f in fs) {
            @Assert(f.get(), 0)
            i = i + 1
        }
    }
}
