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
import fountain::f_jit.base.PredefinedFunction

/**
 * 并发编译**不同**源码的回归用例（`optimize-compile-path` C0）。
 *
 * 旧实现里 `A64Emitter.auditMemBases` 是进程级 `ArrayList`：多线程同时编译时
 * `add` 会越界（实测 `IndexOutOfBoundsException`），且 `resetAuditMemBases` 会把别人的审计项清掉。
 * 本用例锁住「4 线程并发编译各自的源码，结果正确且不崩」。
 */
@Test
public class CompileConcurrency_test {
    /** 注册若干函数，让每次编译发射的指令更多（更容易暴露共享审计表的竞态）。 */
    private static func fill(c: Compiler, count: Int64): Unit {
        var i = 0
        while (i < count) {
            c.registerFunction(PredefinedFunction('concurrency.fn.${i}', [1], 1, { _ => 1 }))
            i = i + 1
        }
    }

    @TestCase
    public func concurrentCompilesStayIsolated(): Unit {
        CompileCache.reset()
        let shared = Compiler(CompileOptions(DummyDiagnosticsSink()))
        CompileConcurrency_test.fill(shared, 200)
        let n = Int64(10)
        let bad = AtomicInt64(0)
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            let base = Int64(t * 1000)
            fs.add(spawn {
                var k = 0
                while (k < n) {
                    let seed = base + k
                    let src = '{ n: Int64 => n * ${seed} + 1 }'
                    let f = shared.compile(src)
                    if (f.call<Int64>([Int64(2)]) != 2 * seed + 1) {
                        let _ = bad.fetchAdd(1)
                    }
                    k = k + 1
                }
                n
            })
            t = t + 1
        }
        for (f in fs) {
            @Assert(f.get(), n)
        }
        @Assert(bad.load(), 0)
        CompileCache.reset()
    }
}
