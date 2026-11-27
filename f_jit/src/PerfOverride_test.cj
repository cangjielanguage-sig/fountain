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

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.JitBindings
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.test.ReflectUser
import fountain::f_jit.test.TCase

/**
 * `registerType<T>(overrides:)` 的**端到端**收益（M2.1）。
 *
 * 与 `PerfAdapter_test` 的分工：那一条测的是「裸闭包替换」这一层（`apply` vs 手写 adapter，
 * 36×）；本用例测用户真正看到的那条链——`greet.call` → 预定义槽位 → `impl`，
 * 两臂只差 `impl` 的实现，其余完全相同。
 *
 * **为什么用 `bump`（Int64）而不是 `greet`（String）作被测方法**：反射臂走
 * `InstanceFunctionInfo.apply` 在 String 参数/返回上必现 SIGSEGV（GAP-13），
 * 跑不到 3000 次；值型参数不触发，端到端的固定开销（参数打包 / MCC / TypeInfo 查找）
 * 两臂等价，比值仍具代表性。String 路径的收益见 `PerfAdapter_test`（9797 → 270 ns）。
 */
@Test
public class PerfOverride_test {
    /** 与反射版 `bump(Int64): Unit` 同签名，体是类型化闭包（宏将展开成的形态）。 */
    private static func bumpOverride(): PublicMethod {
        PublicMethod(name: 'bump', bind: PredefinedFunction('ReflectUser.bump',
            [LocalType.HOST_OBJECT, LocalType.I64], LocalType.UNIT,
            { args =>
                match (args[0]) {
                    case u: ReflectUser =>
                        match (args[1]) {
                            case n: Int64 => u.bump(n)
                            case _ => ()
                        }
                    case _ => ()
                }
            }))
    }

    /** 跑一轮固定次数调用，返回总纳秒。用**单调时钟**，避免墙上时钟被 NTP 调整影响。 */
    private static func measure(f: JitFunction, u: ReflectUser, rounds: Int64): Int64 {
        let t0 = MonoTime.now()
        var i = 0
        while (i < rounds) {
            let _ = f.call<Int64>([u])
            i = i + 1
        }
        (MonoTime.now() - t0).toNanoseconds()
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

    @TestCase
    public func overrideBeatsReflectionEndToEnd(): Unit {
        let src = '{ u: ReflectUser => u.bump(1)\n 0 }'
        // 基线臂：同一 lambda 但不调任何宿主方法，用来扣掉「call 固定开销 + 解释器跑空壳」。
        let baseSrc = '{ u: ReflectUser => 0 }'
        let rounds: Int64 = 6000

        // 缓存键只含源码指纹，不含注册表 ⇒ 两臂必须各自 reset，否则第二臂会拿到
        // 第一臂的产物（slot 映射不同，测的就不是同一件事了）。
        let plain = Compiler(CompileOptions(DummyDiagnosticsSink()))
        plain.registerType<ReflectUser>()
        CompileCache.reset()
        let fBase = plain.compile(baseSrc)
        CompileCache.reset()
        let fRef = plain.compile(src)

        let tuned = Compiler(CompileOptions(DummyDiagnosticsSink()))
        tuned.registerType<ReflectUser>(bindings: JitBindings(methods: [PerfOverride_test.bumpOverride()]))
        CompileCache.reset()
        let fOv = tuned.compile(src)

        let u = ReflectUser('bob', 0)
        var i = 0
        while (i < 200) {
            let _ = fBase.call<Int64>([u])
            let _ = fRef.call<Int64>([u])
            let _ = fOv.call<Int64>([u])
            i = i + 1
        }

        // **同轮配对、3 轮取中位数**：净成本 = 两臂相减（~3 µs 从 ~9 µs 里减出来），单轮噪声会被放大。
        // 「每臂独立取最小」会把不同轮次的偶然极小值拼在一起 —— 实测出现过比值 0.82 > 0.80 的假失败。
        // 每轮配对算比值再取中位数：单轮异常被中位数吸收，真实退化（三轮都 ~1.0）仍会红。
        var q1: Int64 = 0
        var q2: Int64 = 0
        var q3: Int64 = 0
        var round = 0
        while (round < 3) {
            let b = PerfOverride_test.measure(fBase, u, rounds)
            let r = PerfOverride_test.measure(fRef, u, rounds)
            let o = PerfOverride_test.measure(fOv, u, rounds)
            let rc = if (r > b) {
                r - b
            } else {
                1
            }
            let oc = if (o > b) {
                o - b
            } else {
                1
            }
            let q = oc * 1000 / rc
            println('PERF-OVERRIDE round' + (round + 1).toString() + ' base=' +
                (b / rounds).toString() + 'ns 反射=' + (r / rounds).toString() + 'ns 覆盖=' +
                (o / rounds).toString() + 'ns 净成本 反射=' + (rc / rounds).toString() +
                'ns 覆盖=' + (oc / rounds).toString() + 'ns 比值X1000=' + q.toString())
            if (round == 0) {
                q1 = q
            } else if (round == 1) {
                q2 = q
            } else {
                q3 = q
            }
            round = round + 1
        }
        let median = PerfOverride_test.median3(q1, q2, q3)

        // 门禁：覆盖后**净成本**必须低于反射净成本的 4/5（比值中位数 < 800，即至少快 1.25×）。
        // 为何门槛这么低：`JitFunction.call<T>` 每次调用有 8–17 μs 的固定开销（逐项探针见
        // doc/perf-m2.md：localTypeOf 只占 0.1–0.2 μs，大头在 JitExecutor.invoke 与收尾），
        // 把方法调用那几微秒压在下面。本条只拦「覆盖退化成反射」，不表达端到端加速比。
        println('PERF-OVERRIDE medianRatioX1000=' + median.toString())
        if (median >= 800) {
            @Fail('PERF-OVERRIDE 净成本未达标 medianRatioX1000=' + median.toString())
        }
        @Assert(TCase.hit('T32/override-beats-reflect', median < 800), true)
    }
}
