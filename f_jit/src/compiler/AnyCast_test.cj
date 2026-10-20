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
package fountain::f_jit.compiler

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.test.TCase
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffOutcome
import fountain::f_jit.test.diff.InterpRunner
/**
 * M3 R3.3–R3.4：`is` / `as` 的降低与禁止面（m3 §3）。
 *
 * 口径：
 * - **执行**用例走解释器（`InterpRunner`）——v3 产物的三引擎对拍属 R6；
 * - **静态路径**用例断言产物里**没有** helper（上行/同型是零动作）；
 * - **禁止面**用例只编译，断言抛出的诊断类别。
 */
@Test
public class AnyCast_test {

    // ------------------------------------------------------------------
    // `is`：运行期（左值 15）与静态（左值非 15）
    // ------------------------------------------------------------------

    /** `a is Int64` 命中 / 未命中：H79 交 1 / 0。 */
    @TestCase
    public func isHitsAndMisses(): Unit {
        @Assert(AnyCast_test.resultOf('{ => let a: Any = 7\n a is Int64 }'), '1')
        @Assert(AnyCast_test.resultOf('{ => let a: Any = 7\n a is String }'), '0')
        @Assert(TCase.hit('T38/is-hit-miss',
            AnyCast_test.resultOf('{ => let a: Any = 7\n a is Int64 }') == '1'), true)
    }

    /** `is` 可直接作条件（结果类型 Bool，无转换开销）。 */
    @TestCase
    public func isWorksAsCondition(): Unit {
        let src = '{ => let a: Any = 7\n var r = 2\n if (a is Int64) { r = 1 }\n r }'
        @Assert(AnyCast_test.resultOf(src), '1')
    }

    /** 左值非 15：静态恒真，**不发射 helper**（产物零 H79）。 */
    @TestCase
    public func staticIsNeedsNoHelper(): Unit {
        let unit = AnyCast_test.compileM3('{ s: String => s is String }')
        let d = CodeDump.dump(LowererM2_test.entryBytes(unit))
        @Assert(d.contains('CALL_HELPER 79'), false)
        @Assert(AnyCast_test.resultOf('{ s: String => s is String }', ['abc']), '1')
        @Assert(TCase.hit('T38/is-static-no-helper', !d.contains('CALL_HELPER 79')), true)
    }

    /** `is` 的操作数仍需参与自由变量捕获（闭包里 `x is T` 不能丢捕获）。 */
    @TestCase
    public func isOperandIsCaptured(): Unit {
        @Assert(AnyCast_test.resultOf('{ x: Int64 => let f = { => x is Int64 }\n f() }', [5]), '1')
    }

    // ------------------------------------------------------------------
    // `as`：运行期拆箱与失败 22
    // ------------------------------------------------------------------

    /** 值型往返：`(a as Int64) + 1` 可继续参与算术（「先 as 后算」）。 */
    @TestCase
    public func asRoundTripsValueType(): Unit {
        @Assert(AnyCast_test.resultOf('{ => let a: Any = 42\n (a as Int64) + 1 }'), '43')
        @Assert(TCase.hit('T38/as-value-roundtrip',
            AnyCast_test.resultOf('{ => let a: Any = 42\n (a as Int64) + 1 }') == '43'), true)
    }

    /** 引用型：取回同一对象（不拷贝）。 */
    @TestCase
    public func asReturnsReference(): Unit {
        @Assert(AnyCast_test.resultOf('{ => let a: Any = "hi"\n a as String }'), 'hi')
    }

    /** 未命中：错误码 **22**（不是 7/8），且带调用点。 */
    @TestCase
    public func asMismatchIs22(): Unit {
        let out = AnyCast_test.run('{ => let a: Any = "s"\n (a as Int64) + 1 }')
        @Assert(out.errCode, ErrCode.ANY_CAST)
        @Assert(out.site >= 0, true)
        @Assert(TCase.hit('T38/as-mismatch-22', out.errCode == ErrCode.ANY_CAST), true)
    }

    /** 「先 is 后 as」：未命中分支不取值，命中分支零失败。 */
    @TestCase
    public func isThenAsPattern(): Unit {
        let src = '{ => let a: Any = "s"\n var r = 0\n if (a is Int64) { r = a as Int64 }\n r }'
        @Assert(AnyCast_test.resultOf(src), '0')
    }

    /** 容器元素读回：`GET_IDX` 结果是 15 型表达式，`as` 拆箱后参与运算。 */
    @TestCase
    public func asOnContainerElement(): Unit {
        let out = AnyCast_test.run('{ => let l: List<Any> = [1, 2]\n (l[1] as Int64) + 1 }')
        @Assert(out.errCode, 0)
        @Assert(out.result, '3')
        @Assert(TCase.hit('T39/as-container-element', out.result == '3'), true)
    }

    /** 左值非 15 的同型 `as`：零动作、零 helper（产物断言）。 */
    @TestCase
    public func staticCastNeedsNoHelper(): Unit {
        let unit = AnyCast_test.compileM3('{ s: String => s as String }')
        let d = CodeDump.dump(LowererM2_test.entryBytes(unit))
        @Assert(d.contains('CALL_HELPER 80'), false)
        @Assert(TCase.hit('T38/as-static-no-helper', !d.contains('CALL_HELPER 80')), true)
    }

    // ------------------------------------------------------------------
    // 目标类型校验（不可转集）
    // ------------------------------------------------------------------

    /** `as Closure`：12 不开放（m3 §12-1）→ 编译错误。 */
    @TestCase
    public func rejectsClosureTarget(): Unit {
        @Assert(AnyCast_test.errKind('{ a: Any => a as Closure }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errKind('{ a: Any => a is Closure }'), DiagKind.TYPE_MISMATCH)
    }

    /** `as Any`：盒不套盒 → 编译错误。 */
    @TestCase
    public func rejectsAnyTarget(): Unit {
        @Assert(AnyCast_test.errKind('{ a: Any => a as Any }'), DiagKind.TYPE_MISMATCH)
    }

    /** `as T ?? V` 在 Any 上不支持：显式报错，指向「先 is 后 as」。 */
    @TestCase
    public func rejectsFallbackOnAny(): Unit {
        @Assert(AnyCast_test.errKind('{ a: Any => a as Int64 ?? 0 }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errText('{ a: Any => a as Int64 ?? 0 }').contains('先 is 后 as'), true)
    }

    /** 静态不相容：`String is Int64` → 编译错误（不是运行期恒假）。 */
    @TestCase
    public func rejectsIncompatibleStaticIs(): Unit {
        @Assert(AnyCast_test.errKind('{ s: String => s is Int64 }'), DiagKind.TYPE_MISMATCH)
    }

    // ------------------------------------------------------------------
    // R3.4 禁止面：15 型上的运算 / 比较 / 等值 / 调用 / 下标
    // ------------------------------------------------------------------

    /** 盒上算不动：算术、等值、比较、一元、逻辑一律编译错误。 */
    @TestCase
    public func rejectsAnyOperators(): Unit {
        @Assert(AnyCast_test.errKind('{ a: Any => a + 1 }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errKind('{ a: Any => a == a }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errKind('{ a: Any => a < 1 }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errKind('{ a: Any => -a }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errKind('{ a: Any => !a }'), DiagKind.TYPE_MISMATCH)
        @Assert(TCase.hit('T38/any-operators-rejected', true), true)
    }

    /** 盒上访问不了：成员读 / 成员写 / 方法调用 / 下标读一律编译错误。 */
    @TestCase
    public func rejectsAnyMemberAccess(): Unit {
        @Assert(AnyCast_test.errKind('{ a: Any => a.foo }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errKind('{ a: Any => a.foo = 1 }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errKind('{ a: Any => a.foo() }'), DiagKind.TYPE_MISMATCH)
        @Assert(AnyCast_test.errKind('{ a: Any => a[0] }'), DiagKind.TYPE_MISMATCH)
        @Assert(TCase.hit('T38/any-member-rejected', true), true)
    }

    /** 诊断消息提示「先 as」——禁止面不是静默失败。 */
    @TestCase
    public func rejectedAnySuggestsCast(): Unit {
        @Assert(AnyCast_test.errText('{ a: Any => a + 1 }').contains('先 `as`'), true)
        @Assert(AnyCast_test.errText('{ a: Any => a.foo() }').contains('先 `as`'), true)
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static func compileM3(src: String): LoadedUnit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        FbcReader.load(sc.compile(src).raw)
    }

    private static func run(src: String): DiffOutcome {
        AnyCast_test.run(src, Array<Any>())
    }

    private static func run(src: String, args: Array<Any>): DiffOutcome {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        InterpRunner().run(DiffCase('T38/any-cast', sc.compile(src).raw, args))
    }

    private static func resultOf(src: String): String {
        AnyCast_test.run(src).result
    }

    private static func resultOf(src: String, args: Array<Any>): String {
        AnyCast_test.run(src, args).result
    }

    private static func errKind(src: String): String {
        var got = ''
        try {
            let _ = AnyCast_test.compileM3(src)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func errText(src: String): String {
        var got = ''
        try {
            let _ = AnyCast_test.compileM3(src)
        } catch (e: SourceCompileException) {
            got = e.message
        }
        got
    }
}
