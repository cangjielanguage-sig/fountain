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
import fountain::f_jit.base.LocalType
import fountain::f_jit.runtime.HostFieldTable
import fountain::f_jit.runtime.JitContext

/**
 * 调用路径优化的测量工具（`optimize-call-path-phase1` T0）。
 *
 * **非门槛**：只打印 `CP-BENCH …`，不做任何时序断言——构建机是共享 7 核 VM，
 * 时序断言必然假失败。数据由人工抄入 `doc/optimize-call-path.md` §6/§7。
 *
 * 场景：
 * - B1 短调用吞吐（`{ n => n + 1 }`）→ Q1/Q4/L1
 * - B2 宿主字段查找（直接调 `HostFieldTable.find`）→ F1/F4
 * - B3 分配型单元（列表构造）→ A4
 * - B4 `JitContext.create + free` → C1
 */
/** B2 的探针类（本包私有，避免依赖其它包的测试类型）。 */
private class CallPathProbe {
    var age: Int64 = 0
}

@Test
public class CallPathBench_test {

    private static func now(): Int64 {
        DateTime.nowUTC().toUnixTimeStamp().toNanoseconds()
    }

    private static func median3(a: Int64, b: Int64, c: Int64): Int64 {
        if ((a <= b && b <= c) || (c <= b && b <= a)) {
            b
        } else if ((b <= a && a <= c) || (c <= a && a <= b)) {
            a
        } else {
            c
        }
    }

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    private static func shortUnit(): JitFunction {
        CompileCache.reset()
        CallPathBench_test.compiler().compile('{ n: Int64 => n + 1 }')
    }

    private static func allocUnit(): JitFunction {
        CompileCache.reset()
        CallPathBench_test.compiler().compile(
            '{ n: Int64 => let xs = [n, n + 1, n + 2]\n xs[0] + xs[1] + xs[2] }')
    }

    /** B1：短调用吞吐。 */
    @TestCase
    public func benchShortCalls(): Unit {
        let f = CallPathBench_test.shortUnit()
        let n = Int64(150000)
        // 预热
        var w = 0
        while (w < 200) {
            let _ = f.call<Int64>([Int64(w)])
            w = w + 1
        }
        let t0 = CallPathBench_test.now()
        var i = 0
        while (i < n) {
            if (f.call<Int64>([Int64(i)]) != Int64(i) + 1) {
                @Fail('B1 result mismatch')
            }
            i = i + 1
        }
        let wall1 = CallPathBench_test.now() - t0
        let q1 = if (wall1 > 0) { n * 1000000000 / wall1 } else { 0 }
        let l1 = if (n > 0) { wall1 / n } else { 0 }
        println('CP-BENCH scene=B1 metric=Q1 value=' + q1.toString() + ' unit=calls/s')
        println('CP-BENCH scene=B1 metric=L1 value=' + l1.toString() + ' unit=ns/call')
        println('CP-BENCH scene=B1 metric=jitBacked value=' +
            (if (f.isJitBacked()) { 1 } else { 0 }).toString() + ' unit=bool')

        // 4 线程部分做 3 轮取中位数：共享 VM 上单轮 4 线程墙钟的离散度常 >10%。
        var walls = ArrayList<Int64>()
        var round = 0
        while (round < 3) {
            let t1 = CallPathBench_test.now()
            let futures = ArrayList<Future<Int64>>()
            var t = 0
            while (t < 4) {
                futures.add(spawn {
                    var k = 0
                    while (k < n) {
                        let _ = f.call<Int64>([Int64(k)])
                        k = k + 1
                    }
                    n
                })
                t = t + 1
            }
            for (x in futures) {
                @Assert(x.get(), n)
            }
            walls.add(CallPathBench_test.now() - t1)
            round = round + 1
        }
        let wall4 = CallPathBench_test.median3(walls[0], walls[1], walls[2])
        let q4 = if (wall4 > 0) { 4 * n * 1000000000 / wall4 } else { 0 }
        println('CP-BENCH scene=B1 metric=Q4 value=' + q4.toString() + ' unit=calls/s')
    }

    /** B2：宿主字段查找（H64/H65 的公共热路径）。 */
    @TestCase
    public func benchHostFieldFind(): Unit {
        HostFieldTable.resetForTest()
        let probe = CallPathProbe()
        probe.age = 7
        HostFieldTable.register(index: 7u16, `type`: LocalType.I64, mutable: true,
            accepts: { o => o is CallPathProbe },
            getter: { o => match (o) { case p: CallPathProbe => p.age; case _ => 0 } },
            setter: { o, v => match ((o, v)) {
                case (p: CallPathProbe, x: Int64) => p.age = x
                case _ => ()
            } })
        let n = Int64(600000)
        var w = 0
        while (w < 1000) {
            let _ = HostFieldTable.find(probe, 7u16)
            w = w + 1
        }
        let t0 = CallPathBench_test.now()
        var hits = 0
        var i = 0
        while (i < n) {
            match (HostFieldTable.find(probe, 7u16)) {
                case Some(_) => hits = hits + 1
                case None => ()
            }
            i = i + 1
        }
        let wall1 = CallPathBench_test.now() - t0
        let f1 = if (n > 0) { wall1 / n } else { 0 }
        println('CP-BENCH scene=B2 metric=F1 value=' + f1.toString() + ' unit=ns/op')
        println('CP-BENCH scene=B2 metric=hits value=' + hits.toString() + ' unit=count')

        let t1 = CallPathBench_test.now()
        let futures = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            futures.add(spawn {
                var k = 0
                while (k < n) {
                    let _ = HostFieldTable.find(probe, 7u16)
                    k = k + 1
                }
                n
            })
            t = t + 1
        }
        for (x in futures) {
            @Assert(x.get(), n)
        }
        let wall4 = CallPathBench_test.now() - t1
        let f4 = if (n > 0) { wall4 / (4 * n) } else { 0 }
        println('CP-BENCH scene=B2 metric=F4 value=' + f4.toString() + ' unit=ns/op')
        HostFieldTable.resetForTest()
    }

    /** B3：分配型单元（列表构造）的单线程 vs 4 线程。 */
    @TestCase
    public func benchAllocationHeavy(): Unit {
        let f = CallPathBench_test.allocUnit()
        println('CP-BENCH scene=B3 metric=jitBacked value=' +
            (if (f.isJitBacked()) { 1 } else { 0 }).toString() + ' unit=bool')
        let n = Int64(15000)
        @Assert(f.call<Int64>([Int64(1)]), 6)
        let t0 = CallPathBench_test.now()
        var i = 0
        while (i < n) {
            if (f.call<Int64>([Int64(i)]) != Int64(i) * 3 + 3) {
                @Fail('B3 result mismatch')
            }
            i = i + 1
        }
        let wall1 = CallPathBench_test.now() - t0
        var walls = ArrayList<Int64>()
        var round = 0
        while (round < 3) {
            let t1 = CallPathBench_test.now()
            let futures = ArrayList<Future<Int64>>()
            var t = 0
            while (t < 4) {
                let bias = Int64(t * 100000)
                futures.add(spawn {
                    var k = 0
                    while (k < n) {
                        let _ = f.call<Int64>([bias + Int64(k)])
                        k = k + 1
                    }
                    n
                })
                t = t + 1
            }
            for (x in futures) {
                @Assert(x.get(), n)
            }
            walls.add(CallPathBench_test.now() - t1)
            round = round + 1
        }
        let wall4 = CallPathBench_test.median3(walls[0], walls[1], walls[2])
        let a4x100 = if (wall4 > 0) { 4 * wall1 * 100 / wall4 } else { 0 }
        println('CP-BENCH scene=B3 metric=A4x100 value=' + a4x100.toString() + ' unit=speedupX100')
    }

    /** B4：`JitContext.create + free` 的单次成本（不经 JIT 调用）。 */
    @TestCase
    public func benchContextCreateFree(): Unit {
        let n = Int64(300000)
        var w = 0
        while (w < 1000) {
            let c = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
            JitContext.free(c)
            w = w + 1
        }
        let t0 = CallPathBench_test.now()
        var i = 0
        while (i < n) {
            let c = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
            JitContext.free(c)
            i = i + 1
        }
        let wall = CallPathBench_test.now() - t0
        let c1 = if (n > 0) { wall / n } else { 0 }
        println('CP-BENCH scene=B4 metric=C1 value=' + c1.toString() + ' unit=ns/op')
    }
}
