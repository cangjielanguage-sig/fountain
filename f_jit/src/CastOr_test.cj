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
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.test.ReflectAdmin
import fountain::f_jit.test.ReflectUser

/**
 * M2.2 语义：`E as T ?? F` 是**编译期**收窄。
 *
 * - `E` 的静态类型可推断为 `T` 或其子类 ⇒ 表达式取 `E`（向上转，运行期零动作）；
 * - 否则编译期报错（不相容 / 下转型 / 无法静态判定——见 `Lowerer.lowerCastOr`）；
 * - `F` 永不求值，但仍被完整降级（因此照样做类型检查）。`fallbackIsNotEvaluated`
 *   与 `fallbackIsStillTypeChecked` 各钉一面。
 */
@Test
public class CastOr_test {

    private static func compiler(): Compiler {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<ReflectUser>()
        c.registerType<ReflectAdmin>()
        c
    }

    /** 同类：表达式就是原值，字段照常可读。 */
    @TestCase
    public func sameClassKeepsValue(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ u: ReflectUser => let v = u as ReflectUser ?? u\n v.name }')
        @Assert(f.call<String>([ReflectUser('bob', 1)]), 'bob')
    }

    /**
     * 子类 → 父类：允许（`parents` 链来自注册期快照，编译期即可判）。
     *
     * 收窄后**不在 JIT 内读父类字段**：GAP-03——反射 `getValue` 只接受精确类实例，
     * 拿 `ReflectAdmin` 走 `ReflectUser` 的反射 getter 会抛。这里只验证表达式本身，
     * 由宿主侧读字段断言（JIT 只负责把对象原样交回）。
     */
    @TestCase
    public func subclassUpcastIsAllowed(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ a: ReflectAdmin => a as ReflectUser ?? a }')
        let got = f.call<ReflectUser>([ReflectAdmin('root')])
        @Assert(got.name, 'root')
    }

    /** 不相容（Int64 对 String）→ 编译期错误。 */
    @TestCase
    public func incompatibleTypesAreRejected(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c, '{ x: Int64 => x as String ?? "d" }'), true)
    }

    /** 下转型（父类 → 子类）→ 编译期错误：运行期类判定不在 M2.2 范围内。 */
    @TestCase
    public func downcastIsRejected(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c, '{ u: ReflectUser => u as ReflectAdmin ?? u }'), true)
    }

    /** 兜底必须是 T 或子类：`Int64` 位置给 `String` → 编译期错误。 */
    @TestCase
    public func fallbackMustMatchTarget(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c, '{ x: Int64 => x as Int64 ?? "s" }'), true)
    }

    /** 类目标同理：`ReflectUser` 位置给 `Int64` → 编译期错误。 */
    @TestCase
    public func classFallbackMustBeClass(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c, '{ u: ReflectUser => u as ReflectUser ?? 0 }'), true)
    }

    /**
     * 兜底**不求值**：`x / 0` 若被执行会以运行期错误终止，实际返回 `x`。
     *
     * 这条同时证明发射形态是「E → JMP 越过 F → F（不可达）」而不是「E, F 都算」。
     */
    @TestCase
    public func fallbackIsNotEvaluated(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: Int64 => x as Int64 ?? (x / 0) }')
        @Assert(f.call<Int64>([7]), 7)
    }

    /** 兜底虽不可达，仍要走完整降级 ⇒ 未定义名字照样编译失败。 */
    @TestCase
    public func fallbackIsStillTypeChecked(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c, '{ x: Int64 => x as Int64 ?? nope }'), true)
    }

    /** 左面是 `null`（`LocalType.NONE`）→ 无类型信息，编译期拒绝。 */
    @TestCase
    public func nullOperandIsRejected(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c,
            '{ u: ReflectUser => null as ReflectUser ?? u }'), true)
    }

    /**
     * 左面是返回 14 的**静态函数调用**：前端没有按名查返回类名的接口 ⇒ 类名未跟踪 ⇒ 拒绝。
     * （`parse(s): ReflectUser` 是反射注册的自动包装函数。）
     */
    @TestCase
    public func unknownReturnClassNameIsRejected(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c,
            '{ s: String => parse(s) as ReflectUser ?? ReflectUser("d", 0) }'), true)
    }

    /**
     * 缓存键只含源码指纹（不含注册表与成败），失败的编译也会进缓存
     * （`failureOf`）——每个反例前后都要 `reset`，否则会污染同源码的后续编译。
     */
    private static func expectCompileFailure(c: Compiler, src: String): Bool {
        try {
            CompileCache.reset()
            let _ = c.compile(src)
            CompileCache.reset()
            false
        } catch (_: Exception) {
            CompileCache.reset()
            true
        }
    }
}
