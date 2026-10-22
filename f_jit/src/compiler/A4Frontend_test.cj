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
import fountain::f_base.UnsafeBytes
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffOutcome
import fountain::f_jit.test.diff.InterpRunner

/**
 * A4 前端逐条纠偏（P1-1 … P1-9）。
 *
 * 断言口径：**行为**（运行结果 / 诊断类别 / 产物里 helper 的个数与 hid）优先；
 * 只有「拒绝面」用编译期诊断。
 */
@Test
public class A4Frontend_test {

    // ------------------------------------------------------------------
    // P1-1 正则 flags
    // ------------------------------------------------------------------

    /** `/re/flags` 的 flags 必须随 Token 送出（旧实现恒 0，`i/m/u` 全丢）。 */
    @TestCase
    public func p1_1_regexFlagsSurviveLexing(): Unit {
        @Assert(A4Frontend_test.firstRegexFlags('/AbC/i'), 0x01u8)
        @Assert(A4Frontend_test.firstRegexFlags('/a/m'), 0x02u8)
        @Assert(A4Frontend_test.firstRegexFlags('/x/u'), 0x04u8)
        @Assert(A4Frontend_test.firstRegexFlags('/a/imu'), 0x07u8)
        @Assert(A4Frontend_test.firstRegexFlags('/a/'), 0x00u8)
    }

    /** `i` 在运行期生效；`m` 让 `^` 匹配行首。 */
    @TestCase
    public func p1_1_regexFlagsAffectMatching(): Unit {
        // 操作数序：`/re/ ~ s`（§11.9 冻结；H52 的形参是 (regex, string)）
        @Assert(A4Frontend_test.resultOf('{ => /AbC/i ~ "abc" }'), '1')
        @Assert(A4Frontend_test.resultOf('{ => /AbC/ ~ "abc" }'), '0')
        @Assert(A4Frontend_test.resultOf('{ => /^b/m ~ "a\\nb" }'), '1')
        @Assert(A4Frontend_test.resultOf('{ => /^b/ ~ "a\\nb" }'), '0')
    }

    // ------------------------------------------------------------------
    // P1-2 String 算术拒绝面（D6）
    // ------------------------------------------------------------------

    /** `- * / %` 对 String 一律编译错误；`+` 仍是拼接、`s * n` 仍是重复。 */
    @TestCase
    public func p1_2_stringArithmeticIsCompileError(): Unit {
        @Assert(A4Frontend_test.errKind('{ => "a" - "b" }'), DiagKind.TYPE_MISMATCH)
        @Assert(A4Frontend_test.errKind('{ => "a" * "b" }'), DiagKind.TYPE_MISMATCH)
        @Assert(A4Frontend_test.errKind('{ => "a" / "b" }'), DiagKind.TYPE_MISMATCH)
        @Assert(A4Frontend_test.errKind('{ => "a" % "b" }'), DiagKind.TYPE_MISMATCH)
        @Assert(A4Frontend_test.errKind('{ => "a" - 1 }'), DiagKind.TYPE_MISMATCH)
        let msg = A4Frontend_test.errText('{ => "a" - "b" }')
        @Assert(msg.contains('String'), true)
        @Assert(A4Frontend_test.resultOf('{ => "a" + "b" }'), 'ab')
        @Assert(A4Frontend_test.resultOf('{ => "ab" * 3 }'), 'ababab')
    }

    // ------------------------------------------------------------------
    // P1-3 尾递归实参
    // ------------------------------------------------------------------

    /** `recursive(b, a-1)` 的实参不得互相覆盖：结果必须与手写的状态转移一致。 */
    @TestCase
    public func p1_3_tailRecursionSwappedArgs(): Unit {
        // 必须走 `return` 语句：尾**表达式**不经过 `tryLowerTailRecursive`（那是自带递归调用，
        // 语义本来就对）；本缺陷位于「尾调用优化」的实参写槽序列。
        let src = '{ a: Int64, b: Int64 => if (a <= 0) { return b }\n' +
            ' return recursive(b, a - 1)\n 0 }'
        @Assert(A4Frontend_test.resultOf(src, [Int64(2), Int64(7)]), '5')
        @Assert(A4Frontend_test.resultOf(src, [Int64(4), Int64(3)]), '0')
    }

    // ------------------------------------------------------------------
    // P1-4 值用法 else if
    // ------------------------------------------------------------------

    /** 语句与值用法的 `else if` 链都能解析，语义与嵌套 if 等价。 */
    @TestCase
    public func p1_4_elseIfParses(): Unit {
        let stmt = '{ a: Int64 => var r = 0\n if (a == 1) { r = 1 } else if (a == 2) { r = 2 }' +
            ' else { r = 3 }\n r }'
        @Assert(A4Frontend_test.resultOf(stmt, [Int64(1)]), '1')
        @Assert(A4Frontend_test.resultOf(stmt, [Int64(2)]), '2')
        @Assert(A4Frontend_test.resultOf(stmt, [Int64(3)]), '3')
        let val = '{ a: Int64 => let x = if (a == 1) { 10 } else if (a == 2) { 20 } else { 30 }\n x }'
        @Assert(A4Frontend_test.resultOf(val, [Int64(1)]), '10')
        @Assert(A4Frontend_test.resultOf(val, [Int64(2)]), '20')
        @Assert(A4Frontend_test.resultOf(val, [Int64(9)]), '30')
    }

    // ------------------------------------------------------------------
    // P1-5 IIFE 静态返回类型
    // ------------------------------------------------------------------

    /**
     * `{ => "abc" }()` 的静态类型是 String：赋给 `s: String` 必须通过（旧实现按 I64 产出，
     * 在严格化后会以「期望 String，实际 Int64」拒绝；本用例用带注解的绑定断言类型）。
     */
    @TestCase
    public func p1_5_iifeUsesClosureReturnType(): Unit {
        @Assert(A4Frontend_test.resultOf('{ => let s: String = { => "abc" }()\n s }'), 'abc')
        @Assert(A4Frontend_test.resultOf('{ => let n: Int64 = { x: Int64 => x + 1 }(41)\n n }'), '42')
        @Assert(A4Frontend_test.resultOf('{ => let b: Bool = { => 1 < 2 }()\n b }'), '1')
    }

    // ------------------------------------------------------------------
    // P1-6 实例方法重载
    // ------------------------------------------------------------------

    /**
     * 同名 `f(Int64)` / `f(String)` 按**实参类型**选绑定（hid 由 slot 序确定：256 / 257）。
     *
     * 用字节码断言而不是运行时：本用例只验证**选择**，运行期分派由 M2 的方法表覆盖。
     */
    @TestCase
    public func p1_6_instanceOverloadByArgTypes(): Unit {
        let d1 = A4Frontend_test.dumpOverload('{ o: Ov, x: Int64 => o.f(x) }')
        @Assert(d1.contains('CALL_HELPER 256,2'), true)
        @Assert(d1.contains('CALL_HELPER 257,2'), false)
        let d2 = A4Frontend_test.dumpOverload('{ o: Ov, s: String => o.f(s) }')
        @Assert(d2.contains('CALL_HELPER 257,2'), true)
        @Assert(d2.contains('CALL_HELPER 256,2'), false)
        // 元数不同：一元重载
        let d3 = A4Frontend_test.dumpOverload('{ o: Ov => o.g() }')
        @Assert(d3.contains('CALL_HELPER 258,1'), true)
    }

    /** 多义 / 无匹配 / 元数不符都是编译错误，且消息带候选。 */
    @TestCase
    public func p1_6_overloadAmbiguityIsCompileError(): Unit {
        let amb = A4Frontend_test.errTextOverload('{ o: Ov, x: Int64 => o.h(x) }')
        @Assert(amb.contains('歧义'), true)
        @Assert(amb.contains('h('), true)
        let none = A4Frontend_test.errTextOverload('{ o: Ov, b: Bool => o.f(b) }')
        @Assert(none.contains('没有与实参类型匹配的重载'), true)
        let arity = A4Frontend_test.errTextOverload('{ o: Ov => o.f() }')
        @Assert(arity.contains('实参个数不符'), true)
    }

    // ------------------------------------------------------------------
    // P1-8 lowerExprAs 完备性
    // ------------------------------------------------------------------

    /** 无隐式转换的组合逐个编译错误；消息含「期望 → 实际」；合法面不误伤。 */
    @TestCase
    public func p1_8_lowerExprAsRejectsUnconvertible(): Unit {
        @Assert(A4Frontend_test.errKind('{ => let s: String = 1\n 0 }'), DiagKind.TYPE_MISMATCH)
        @Assert(A4Frontend_test.errKind('{ => let x: Int64 = "s"\n 0 }'), DiagKind.TYPE_MISMATCH)
        @Assert(A4Frontend_test.errKind('{ => let b: Bool = 1\n 0 }'), DiagKind.TYPE_MISMATCH)
        @Assert(A4Frontend_test.errKind('{ => let x: Int64 = { => 1 }\n 0 }'),
            DiagKind.TYPE_MISMATCH)
        let msg = A4Frontend_test.errText('{ => let s: String = 1\n 0 }')
        @Assert(msg.contains('期望 String'), true)
        @Assert(msg.contains('实际 Int64'), true)
        // 合法面：I64 → F64 与 JSON 上行仍通过
        @Assert(A4Frontend_test.resultOf('{ => let f: Float64 = 1\n 1 }'), '1')
        @Assert(A4Frontend_test.resultOf('{ => let v: JsonValue = `{"k":1}`\n 1 }'), '1')
    }

    // ------------------------------------------------------------------
    // P1-9 `List<Any>` 的三条装箱路径
    // ------------------------------------------------------------------

    /** 赋值与 IIFE 实参都要逐元素装箱；整体 Any 只装 1 个外层盒。 */
    @TestCase
    public func p1_9_listAnyBoxesOnAssignAndArg(): Unit {
        let assign = A4Frontend_test.dumpOf('{ => var l: List<Any> = []\n l = [1, 2]\n 0 }')
        @Assert(A4Frontend_test.countOf(assign, 'CALL_HELPER 78,2'), 2)
        let dIife = A4Frontend_test.dumpOf(
            '{ => let xs: List<Any> = { xs: List<Any> => xs }([1, "a"])\n 0 }')
        @Assert(A4Frontend_test.countOf(dIife, 'CALL_HELPER 78,2'), 2)
        let whole = A4Frontend_test.dumpOf('{ => let l: List<Int64> = [1, 2]\n let a: Any = l\n 0 }')
        @Assert(A4Frontend_test.countOf(whole, 'CALL_HELPER 78,2'), 1)
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static func compile(src: String): LoadedUnit {
        A4Frontend_test.compile(src, PredefinedSnapshot.empty(), ClassRegistrySnapshot.empty())
    }

    private static func compile(src: String, snap: PredefinedSnapshot,
        classes: ClassRegistrySnapshot): LoadedUnit {
        let sc = SourceCompiler(snap, DummyDiagnosticsSink(), verMajor: Version.M3_MAJOR,
            classes: classes)
        FbcReader.load(sc.compile(src).raw)
    }

    private static func dumpOf(src: String): String {
        CodeDump.dump(LowererM2_test.entryBytes(A4Frontend_test.compile(src)))
    }

    private static func run(src: String, args: Array<Any>): DiffOutcome {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        InterpRunner().run(DiffCase('A4/frontend', sc.compile(src).raw, args))
    }

    private static func resultOf(src: String): String {
        A4Frontend_test.run(src, Array<Any>()).result
    }

    private static func resultOf(src: String, args: Array<Any>): String {
        A4Frontend_test.run(src, args).result
    }

    private static func errKind(src: String): String {
        var got = ''
        try {
            let _ = A4Frontend_test.compile(src)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func errText(src: String): String {
        var got = ''
        try {
            let _ = A4Frontend_test.compile(src)
        } catch (e: SourceCompileException) {
            got = e.message
        }
        got
    }

    private static func firstRegexFlags(src: String): UInt8 {
        let ts = Lexer(src).tokenize()
        for (t in ts) {
            if (t.kind == TokenKind.RegexLit) {
                return t.flags
            }
        }
        0u8
    }

    /**
     * 重载夹具：`Ov` 有三个方法——
     * `f(Int64)`（slot 0 ⇒ hid 256）、`f(String)`（slot 1 ⇒ 257）、`g()`（slot 2 ⇒ 258）、
     * 以及两个同签名的 `h(Int64)`（slot 3/4）用于制造歧义。
     */
    private static func overloadFixtures(): (PredefinedSnapshot, ClassRegistrySnapshot) {
        let fi = PredefinedFunction('ov_f_i', [LocalType.HOST_OBJECT, LocalType.I64],
            LocalType.I64, { _ => 1 })
        let fs = PredefinedFunction('ov_f_s', [LocalType.HOST_OBJECT, LocalType.STRING],
            LocalType.I64, { _ => 2 })
        let g0 = PredefinedFunction('ov_g_0', [LocalType.HOST_OBJECT], LocalType.I64, { _ => 3 })
        let h1 = PredefinedFunction('ov_h_1', [LocalType.HOST_OBJECT, LocalType.I64],
            LocalType.I64, { _ => 4 })
        let h2 = PredefinedFunction('ov_h_2', [LocalType.HOST_OBJECT, LocalType.I64],
            LocalType.I64, { _ => 5 })
        let cls = ClassDescriptor(name: 'Ov', fields: [],
            methods: [PublicMethod(name: 'f', bind: fi), PublicMethod(name: 'f', bind: fs),
                PublicMethod(name: 'g', bind: g0), PublicMethod(name: 'h', bind: h1),
                PublicMethod(name: 'h', bind: h2)],
            ctors: [])
        let snap = PredefinedSnapshot(['ov_f_i', 'ov_f_s', 'ov_g_0', 'ov_h_1', 'ov_h_2'],
            [[LocalType.HOST_OBJECT, LocalType.I64], [LocalType.HOST_OBJECT, LocalType.STRING],
                [LocalType.HOST_OBJECT], [LocalType.HOST_OBJECT, LocalType.I64],
                [LocalType.HOST_OBJECT, LocalType.I64]],
            [LocalType.I64, LocalType.I64, LocalType.I64, LocalType.I64, LocalType.I64])
        (snap, ClassRegistrySnapshot([cls]))
    }

    private static func dumpOverload(src: String): String {
        let (snap, classes) = A4Frontend_test.overloadFixtures()
        CodeDump.dump(LowererM2_test.entryBytes(A4Frontend_test.compile(src, snap, classes)))
    }

    private static func errTextOverload(src: String): String {
        let (snap, classes) = A4Frontend_test.overloadFixtures()
        var got = ''
        try {
            let _ = A4Frontend_test.compile(src, snap, classes)
        } catch (e: SourceCompileException) {
            got = e.message
        }
        got
    }

    private static func countOf(text: String, pat: String): Int64 {
        let t = text.unsafeBytes()
        let p = pat.unsafeBytes()
        if (p.size == 0 || t.size < p.size) {
            return 0
        }
        var n: Int64 = 0
        var i: Int64 = 0
        while (i + p.size <= t.size) {
            var j: Int64 = 0
            var ok = true
            while (j < p.size) {
                if (t[i + j] != p[j]) {
                    ok = false
                    break
                }
                j = j + 1
            }
            if (ok) {
                n = n + 1
                i = i + p.size
            } else {
                i = i + 1
            }
        }
        n
    }
}
