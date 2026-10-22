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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.test.ReflectAdmin
import fountain::f_jit.test.ReflectUser

/**
 * `E as T` / `E as T ?? V`（M2.3）。
 *
 * 语义分两层：
 * - **编译期能定的**：`E` 已是 `T` 或子类 ⇒ 直接取 `E`（零动作）；与 `T` 不相容 ⇒ 编译期报错；
 * - **编译期定不了的**（下转型、左面类名未跟踪）⇒ 运行期查 `$as$<T>`：`as T` 失败报 7
 *   （`BAD_CAST`），`as T ?? V` 失败取 `V`（`V` 只在失败时求值）。
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

    /** 子类 → 父类：静态可判，编译通过、运行期零动作。 */
    @TestCase
    public func subclassUpcastIsAllowed(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ a: ReflectAdmin => a as ReflectUser ?? a }')
        let got = f.call<ReflectUser>([ReflectAdmin('root')])
        @Assert(got.name, 'root')
    }

    /** 下转型：运行期命中 ⇒ 原对象（不是兜底）。 */
    @TestCase
    public func downcastSucceedsWhenRuntimeTypeMatches(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ u: ReflectUser => u as ReflectAdmin ?? ReflectAdmin("fallback") }')
        let got = f.call<ReflectUser>([ReflectAdmin('root')])
        @Assert(got.name, 'root')
    }

    /** 下转型：运行期不命中 ⇒ 取兜底值。 */
    @TestCase
    public func downcastFallsBackOnMismatch(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ u: ReflectUser => u as ReflectAdmin ?? ReflectAdmin("fallback") }')
        let got = f.call<ReflectUser>([ReflectUser('bob', 1)])
        @Assert(got.name, 'fallback')
    }

    /** 裸 `as`：命中返回原值；不命中以 **7 BAD_CAST** 失败（不是 21）。 */
    @TestCase
    public func bareCastFailsWithBadCast(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ u: ReflectUser => u as ReflectAdmin }')
        let ok = f.call<ReflectUser>([ReflectAdmin('root')])
        @Assert(ok.name, 'root')
        var code: Int64 = -1
        try {
            let _ = f.call<ReflectUser>([ReflectUser('bob', 1)])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.BAD_CAST)
    }

    /**
     * 左面类名未跟踪（静态函数返回 14）⇒ 走运行期判定：命中成功。
     *
     * `parse(s)` 是反射注册的自动包装函数，前端拿不到它的返回类名——只知道「是某个 14」；
     * `$as$ReflectUser` 按运行期对象判定。
     */
    @TestCase
    public func unknownClassNameUsesRuntimeCheck(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ s: String => let u = parse(s) as ReflectUser ?? ReflectUser("d", 0)\n' +
            ' u.name }')
        @Assert(f.call<String>(['ann']), 'ann')
    }

    /** 不相容（Int64 对 String）→ 编译期错误，与运行期无关。 */
    @TestCase
    public func incompatibleTypesAreRejected(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c, '{ x: Int64 => x as String ?? "d" }'), true)
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

    /** 静态命中路线上兜底**不求值**：`x / 0` 若被执行会以运行期错误终止，实际返回 `x`。 */
    @TestCase
    public func fallbackIsNotEvaluatedOnStaticHit(): Unit {
        let c = CastOr_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: Int64 => x as Int64 ?? (x / 0) }')
        @Assert(f.call<Int64>([7]), 7)
    }

    /** 兜底仍被完整降级 ⇒ 未定义名字照样编译失败。 */
    @TestCase
    public func fallbackIsStillTypeChecked(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c, '{ x: Int64 => x as Int64 ?? nope }'), true)
    }

    /** 左面是 `null`（`LocalType.NONE`）而目标是类 → 不是 14，编译期拒绝。 */
    @TestCase
    public func nullOperandIsRejected(): Unit {
        let c = CastOr_test.compiler()
        @Assert(CastOr_test.expectCompileFailure(c,
            '{ u: ReflectUser => null as ReflectUser ?? u }'), true)
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
