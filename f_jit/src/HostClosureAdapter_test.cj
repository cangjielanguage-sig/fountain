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

import std.unittest.*
import std.unittest.testmacro.*
import std.time.DateTime
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SignatureRegistry

/**
 * M2.2：宿主闭包调用的**类型化快速路径**。
 *
 * 现状（M2）：`CALL_HOST` → H63 → `FunctionTypeInfo.apply`（每次一次反射）。
 * 现在：`JitHost.registerSignature` 登记过同结构 adapter 时，H63 直接调它（静态类型调用），
 * 未登记则维持反射——行为不变。
 *
 * 约定：`SignatureRegistry` 是进程级单例，每个用例结束都要 `resetForTest()`，否则会串到别的用例。
 */
@Test
public class HostClosureAdapter_test {

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 哨兵 adapter：返回值里 +1000 ⇒ 只可能来自 adapter 路径。 */
    private static func registerSentinel(): Unit {
        let _ = JitHost.registerSignature<(Int64) -> Int64>(
            display: '(Int64) -> Int64',
            params: [LocalType.I64], paramNames: [''], ret: LocalType.I64, retName: '',
            adapter: { f, a =>
                if (let g: (Int64) -> Int64 <- f) {
                    let x = match (a[0]) {
                        case v: Int64 => v
                        case _ => -1
                    }
                    g(x) + 1000
                } else {
                    -1
                }
            })
    }

    /** 未登记 → 反射路径（现状），结果就是闭包自己的结果。 */
    @TestCase
    public func reflectionPathStaysWhenUnregistered(): Unit {
        SignatureRegistry.resetForTest()
        let c = HostClosureAdapter_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ g: (Int64) -> Int64, x: Int64 => g(x) }')
        let cb: (Int64) -> Int64 = { n => n * 2 }
        @Assert(f.call<Int64>([cb, 21]), 42)
    }

    /** 登记同结构 adapter → H63 走它（结果里带哨兵）。 */
    @TestCase
    public func typedAdapterIsUsedWhenRegistered(): Unit {
        SignatureRegistry.resetForTest()
        HostClosureAdapter_test.registerSentinel()
        let c = HostClosureAdapter_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ g: (Int64) -> Int64, x: Int64 => g(x) }')
        let cb: (Int64) -> Int64 = { n => n * 2 }
        @Assert(f.call<Int64>([cb, 21]), 1042)
        SignatureRegistry.resetForTest()
    }

    /** 签名结构不同（元数不同）→ 不命中，仍是反射路径。 */
    @TestCase
    public func differentArityDoesNotMatch(): Unit {
        SignatureRegistry.resetForTest()
        HostClosureAdapter_test.registerSentinel()
        let c = HostClosureAdapter_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ g: (Int64, Int64) -> Int64, x: Int64 => g(x, x) }')
        let cb: (Int64, Int64) -> Int64 = { a, b => a + b }
        @Assert(f.call<Int64>([cb, 5]), 10)
        SignatureRegistry.resetForTest()
    }

    /**
     * 性能：单元内 5 万次回调，比较「反射」与「adapter」两条路径。
     *
     * 只测**一次 JIT 调用内部**的多次回调——`call<T>` 自身 8–17 μs 的固定开销会淹没差异，
     * 那部分与本变更无关（见 `doc/perf-m2.md`）。门禁取 1.3×（实测约 2.6×，留噪声余量）。
     */
    @TestCase
    public func adapterBeatsReflectionInCallbackLoop(): Unit {
        SignatureRegistry.resetForTest()
        let c = HostClosureAdapter_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ g: (Int64) -> Int64, n: Int64 =>\n' +
            ' var i = 0\n var s = 0\n while (i < n) { s = s + g(i)\n i = i + 1 }\n s }')
        let cb: (Int64) -> Int64 = { n => n + 1 }
        let rounds: Int64 = 50000

        // 预热（含 JIT 编译）
        let _ = f.call<Int64>([cb, 1000])

        let t0 = DateTime.now()
        let r1 = f.call<Int64>([cb, rounds])
        let reflectiveNs = (DateTime.now() - t0).toNanoseconds()

        HostClosureAdapter_test.registerSentinel()
        let t1 = DateTime.now()
        let r2 = f.call<Int64>([cb, rounds])
        let typedNs = (DateTime.now() - t1).toNanoseconds()
        SignatureRegistry.resetForTest()

        // 哨兵 +1000/次：这里的期望值同时证明走的是 adapter 路径
        @Assert(r1, (rounds * (rounds - 1) / 2) + rounds)
        @Assert(r2, (rounds * (rounds - 1) / 2) + rounds + rounds * 1000)
        println('PERF-CLOSURE reflective=' + (reflectiveNs / rounds).toString() +
            'ns/call typed=' + (typedNs / rounds).toString() + 'ns/call ratioX100=' +
            (reflectiveNs * 100 / typedNs).toString())
        if (typedNs * 10 >= reflectiveNs * 13) {
            @Fail('Adapter 未带来预期收益：reflective=' + reflectiveNs.toString() +
                'ns typed=' + typedNs.toString() + 'ns（期望 ≥1.3×）')
        }
    }
}
