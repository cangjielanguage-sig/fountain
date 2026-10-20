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

import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
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

    @TestCase
    public func overrideBeatsReflectionEndToEnd(): Unit {
        let src = '{ u: ReflectUser => u.bump(1)\n 0 }'
        // 基线臂：同一 lambda 但不调任何宿主方法，用来扣掉「call 固定开销 + 解释器跑空壳」。
        let baseSrc = '{ u: ReflectUser => 0 }'
        let rounds: Int64 = 3000

        // 缓存键只含源码指纹，不含注册表 ⇒ 两臂必须各自 reset，否则第二臂会拿到
        // 第一臂的产物（slot 映射不同，测的就不是同一件事了）。
        let plain = Compiler(CompileOptions(DummyDiagnosticsSink()))
        plain.registerType<ReflectUser>()
        CompileCache.reset()
        let fBase = plain.compile(baseSrc)
        CompileCache.reset()
        let fRef = plain.compile(src)

        let tuned = Compiler(CompileOptions(DummyDiagnosticsSink()))
        tuned.registerType<ReflectUser>(overrides: [PerfOverride_test.bumpOverride()])
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

        let t0 = DateTime.now()
        i = 0
        while (i < rounds) {
            let _ = fBase.call<Int64>([u])
            i = i + 1
        }
        let baseNs = (DateTime.now() - t0).toNanoseconds()

        let t1 = DateTime.now()
        i = 0
        while (i < rounds) {
            let _ = fRef.call<Int64>([u])
            i = i + 1
        }
        let refNs = (DateTime.now() - t1).toNanoseconds()

        let t2 = DateTime.now()
        i = 0
        while (i < rounds) {
            let _ = fOv.call<Int64>([u])
            i = i + 1
        }
        let ovNs = (DateTime.now() - t2).toNanoseconds()

        // 扣掉基线后才是「一次宿主方法调用」本身的成本
        let refCost = if (refNs > baseNs) {
            refNs - baseNs
        } else {
            1
        }
        let ovCost = if (ovNs > baseNs) {
            ovNs - baseNs
        } else {
            1
        }
        println('PERF-OVERRIDE base=' + (baseNs / rounds).toString() + 'ns 反射=' +
            (refNs / rounds).toString() + 'ns 覆盖=' + (ovNs / rounds).toString() +
            'ns 净成本 反射=' + (refCost / rounds).toString() + 'ns 覆盖=' +
            (ovCost / rounds).toString() + 'ns ratioX10=' + (refCost * 10 / ovCost).toString())

        // 门禁：覆盖后**净成本**必须低于反射净成本的 4/5（即至少快 1.25×）。
        // 为何门槛这么低：`JitFunction.call<T>` 每次调用有 8–17 μs 的固定开销（逐项探针见
        // doc/perf-m2.md：localTypeOf 只占 0.1–0.2 μs，大头在 JitExecutor.invoke 与收尾），
        // 把方法调用那几微秒压在下面。本条只拦「覆盖退化成反射」，不表达端到端加速比。
        if (ovCost * 5 >= refCost * 4) {
            @Fail('PERF-OVERRIDE 净成本未达标 ref=' + (refCost / rounds).toString() + 'ns ov=' +
                (ovCost / rounds).toString() + 'ns')
        }
        @Assert(TCase.hit('T32/override-beats-reflect', refCost * 4 > ovCost * 5), true)
    }
}
