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
 * 并发矩阵（`add-concurrency-matrix-tests`）：四类并行场景的语义护栏。
 *
 * 1. 并发编译**同一**源码：冷缓存只允许一次管线，所有线程拿到同一可调用单元；
 * 2. 并发编译**不同**源码：每个单元的机器码只能执行自己的语义（不串味）；
 * 3. 并发调用**同一个闭包**：捕获值只读共享、错误槽按线程隔离、包装路径可重入；
 * 4. 并发调用**不同闭包**：轮转交错，同名 user helper 在不同单元里各归各；
 * 5. 附加：编译与调用混合，新单元上线的同时老单元持续被调用。
 *
 * 每个用例都以**直接断言**判定（结果值、错误码、句柄账目），不依赖标签打点；
 * 变异验证（故意破坏去重 / helper 线程私有 / 错误槽隔离）见该变更的 verify.md。
 */
@Test
public class ConcurrencyMatrix_test {
    /** 并发度：构建机 7 核，6 线程足以制造真实交错且不把 CI 拖长。 */
    private static let THREADS: Int64 = 6

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /**
     * 同起点门：所有线程到齐再开跑。
     *
     * 自旋带上限：若调度异常（线程创建失败/机器极端过载），退化为「尽早开始」而不是挂死；
     * 并发度不足只会让竞态更难复现，不会制造假失败。
     */
    private static func gate(ready: AtomicInt64, n: Int64): Unit {
        let _ = ready.fetchAdd(1)
        var spins: Int64 = 0
        while (ready.load() < n && spins < 100000000) {
            spins = spins + 1
        }
    }

    /** 1) 并发编译**同一**源码：管线恰好执行一次，全部线程拿到同一个单元且都能调用。 */
    @TestCase
    public func concurrentCompileSameSource(): Unit {
        CompileCache.reset()
        let shared = ConcurrencyMatrix_test.compiler()
        let src = '{ n: Int64 => n * 3 + 7 }'
        let ready = AtomicInt64(0)
        let fs = ArrayList<Future<Int64>>()
        let firsts = ArrayList<JitFunction>()
        let mtx = Mutex()
        var t = 0
        while (t < ConcurrencyMatrix_test.THREADS) {
            let base = Int64(t * 10000)
            fs.add(spawn {
                ConcurrencyMatrix_test.gate(ready, ConcurrencyMatrix_test.THREADS)
                var bad = 0
                var first: ?JitFunction = None
                var i = 0
                while (i < 20) {
                    let f = shared.compile(src)
                    match (first) {
                        case Some(_) => ()
                        case None =>
                            first = Some(f)
                            synchronized(mtx) {
                                firsts.add(f)
                            }
                    }
                    let n = base + Int64(i)
                    if (f.call<Int64>([n]) != n * 3 + 7) {
                        bad = bad + 1
                    }
                    i = i + 1
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
        // 冷缓存下 6 线程 × 20 次同源编译：管线累计只应跑 1 次。
        @Assert(CompileCache.runs(), 1)
        // 去重的对象级证据：关掉任一实例，其余实例必须同时进入终态（同一个单元）。
        @Assert(firsts.size, ConcurrencyMatrix_test.THREADS)
        @Assert(firsts[0].close(0), true)
        @Assert(firsts[ConcurrencyMatrix_test.THREADS - 1].isClosed(), true)
    }

    /** 2) 并发编译**不同**源码：48 个单元各自执行自己的代码，键不冲突、结果不串。 */
    @TestCase
    public func concurrentCompileDifferentSources(): Unit {
        CompileCache.reset()
        let shared = ConcurrencyMatrix_test.compiler()
        let per = Int64(8)
        let ready = AtomicInt64(0)
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < ConcurrencyMatrix_test.THREADS) {
            let base = Int64(t * 1000)
            fs.add(spawn {
                ConcurrencyMatrix_test.gate(ready, ConcurrencyMatrix_test.THREADS)
                var bad = 0
                var k = 0
                while (k < per) {
                    let seed = base + Int64(k)
                    let f = shared.compile('{ n: Int64 => n * ${seed} + ${seed} }')
                    if (!f.isJitBacked()) {
                        bad = bad + 1
                    }
                    if (f.call<Int64>([Int64(2)]) != 2 * seed + seed) {
                        bad = bad + 1
                    }
                    k = k + 1
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
        // 每个源码键都唯一 ⇒ 48 次独立管线；若键派生塌缩，这里会偏小且上面必有错值。
        @Assert(CompileCache.runs(), ConcurrencyMatrix_test.THREADS * per)
    }

    /**
     * 3) 并发调用**同一个闭包**：一半线程走正常值（读捕获 `base`），一半线程触发除零。
     *
     * 捕获值只读共享 ⇒ 正常线程永远拿到 `x + 1000`；错误槽线程私有 ⇒ 除零线程拿到
     * `DIV_ZERO` 且不会污染正常线程；反之错误槽若共享，正常线程会读到别人的错误码。
     */
    @TestCase
    public func concurrentCallsOnSameClosure(): Unit {
        CompileCache.reset()
        let c = ConcurrencyMatrix_test.compiler()
        let unit = c.compile(
            '{ => let base = 1000\n { x: Int64 => if (x == 0) { 100 / x } else { x + base } } }')
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w.call<Int64>([Int64(1)]), 1001)
        let ready = AtomicInt64(0)
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < ConcurrencyMatrix_test.THREADS) {
            let tid = Int64(t)
            fs.add(spawn {
                ConcurrencyMatrix_test.gate(ready, ConcurrencyMatrix_test.THREADS)
                var bad = 0
                var i = 0
                while (i < 120) {
                    if (tid % 2 == 0) {
                        // 参数从 1 起：0 是错误路径的触发值，正常线程必须避开。
                        let n = tid * 100000 + Int64(i) + 1
                        if (w.call<Int64>([n]) != n + 1000) {
                            bad = bad + 1
                        }
                    } else {
                        var code: Int64 = 0
                        try {
                            let _ = w.call<Int64>([Int64(0)])
                        } catch (e: JitException) {
                            code = e.code
                        }
                        if (code != ErrCode.DIV_ZERO) {
                            bad = bad + 1
                        }
                    }
                    i = i + 1
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
        // 混合成败之后包装仍可用，且释放幂等。
        @Assert(w.call<Int64>([Int64(7)]), 1007)
        w.close()
        w.close()
    }

    /**
     * 4) 并发调用**不同闭包**：每线程轮转调用全部单元，同名 helper 各归各。
     *
     * 三个单元各自注册**同名** `hh`（同一 hid 0x0100）但实现不同：若 helper 活动表
     * 退化成进程级共享，交错调用必然把 `hh` 解析成别的单元的实现，结果立刻错。
     */
    @TestCase
    public func concurrentCallsOnDifferentClosures(): Unit {
        CompileCache.reset()
        let c0 = ConcurrencyMatrix_test.compiler()
        c0.registerFunction(PredefinedFunction('hh', [LocalType.I64], LocalType.I64,
            { _ => Int64(10) }))
        let u0 = c0.compile('{ n: Int64 => hh(n) + n }')
        let c1 = ConcurrencyMatrix_test.compiler()
        c1.registerFunction(PredefinedFunction('hh', [LocalType.I64], LocalType.I64,
            { _ => Int64(20) }))
        let u1 = c1.compile('{ n: Int64 => hh(n) * 2 }')
        let c2 = ConcurrencyMatrix_test.compiler()
        c2.registerFunction(PredefinedFunction('hh', [LocalType.I64], LocalType.I64,
            { _ => Int64(30) }))
        let u2 = c2.compile('{ n: Int64 => hh(n) - n }')
        @Assert(u0.call<Int64>([Int64(3)]), 13)
        @Assert(u1.call<Int64>([Int64(3)]), 40)
        @Assert(u2.call<Int64>([Int64(3)]), 27)
        let liveBase = HandleTable.liveCount()
        let ready = AtomicInt64(0)
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < ConcurrencyMatrix_test.THREADS) {
            let tid = Int64(t)
            fs.add(spawn {
                ConcurrencyMatrix_test.gate(ready, ConcurrencyMatrix_test.THREADS)
                var bad = 0
                var i = 0
                while (i < 100) {
                    let n = tid * 10000 + Int64(i)
                    if (u0.call<Int64>([n]) != n + 10) {
                        bad = bad + 1
                    }
                    if (u1.call<Int64>([n]) != 40) {
                        bad = bad + 1
                    }
                    if (u2.call<Int64>([n]) != 30 - n) {
                        bad = bad + 1
                    }
                    i = i + 1
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
        @Assert(HandleTable.liveCount(), liveBase)
    }

    /** 5) 附加：编译与调用混合——新单元持续上线，老单元同时被 4 个线程调用。 */
    @TestCase
    public func compileAndCallRunConcurrently(): Unit {
        CompileCache.reset()
        let shared = ConcurrencyMatrix_test.compiler()
        let steady = shared.compile('{ n: Int64 => n * 5 }')
        @Assert(steady.call<Int64>([Int64(2)]), 10)
        let ready = AtomicInt64(0)
        let callers = Int64(4)
        let total = callers + 1
        let fs = ArrayList<Future<Int64>>()
        fs.add(spawn {
            ConcurrencyMatrix_test.gate(ready, total)
            var bad = 0
            var k = 0
            while (k < 12) {
                let seed = Int64(k)
                let f = shared.compile('{ n: Int64 => n + ${seed} }')
                if (f.call<Int64>([Int64(3)]) != 3 + seed) {
                    bad = bad + 1
                }
                k = k + 1
            }
            bad
        })
        var t = 0
        while (t < callers) {
            let bias = Int64(t * 1000)
            fs.add(spawn {
                ConcurrencyMatrix_test.gate(ready, total)
                var bad = 0
                var i = 0
                while (i < 300) {
                    let n = bias + Int64(i)
                    if (steady.call<Int64>([n]) != n * 5) {
                        bad = bad + 1
                    }
                    i = i + 1
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
    }
}
