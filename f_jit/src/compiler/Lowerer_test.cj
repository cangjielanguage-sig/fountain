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
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.Interp
import fountain::f_jit.runtime.JitContext

/**
 * S3.10–S3.18 的降低验收面（plan-m1 §5）。
 *
 * 断言只经**产物 + 解释执行结果**：既覆盖「发射序列能跑出正确语义」，也不碰递归 AST 枚举
 * （design §4.3 实施注意）。逐任务对应关系写在每个用例的注释里。
 */
@Test
public class Lowerer_test {
    private static const DOLLAR: String = '$'

    /** S3.10：整型算术 / 位 / 移位 / `%`（仅 Int64）。 */
    @TestCase
    public func integerArithmeticAndBitOps(): Unit {
        @Assert(Lowerer_test.runInt('{ => 7 % 3 }', []), 1)
        @Assert(Lowerer_test.runInt('{ => 5 & 3 }', []), 1)
        @Assert(Lowerer_test.runInt('{ => 5 | 2 }', []), 7)
        @Assert(Lowerer_test.runInt('{ => 5 ^ 1 }', []), 4)
        @Assert(Lowerer_test.runInt('{ => 1 << 4 }', []), 16)
        @Assert(Lowerer_test.runInt('{ => -8 >> 1 }', []), -4)
        @Assert(Lowerer_test.runInt('{ => ~0 }', []), -1)
        // 取模只接受 (Int64, Int64)
        @Assert(Lowerer_test.compileKind('{ => 1.5 % 2.0 }'), DiagKind.TYPE_MISMATCH)
    }

    /** S3.11：小数字面值精确构造，混合算术按 Decimal。 */
    @TestCase
    public func decimalLiteralsAreExact(): Unit {
        @Assert(Lowerer_test.runInt('{ => 0.1 + 0.2 == 0.3 }', []), 1)
        @Assert(Lowerer_test.runInt('{ => 0.1 + 1 == 1.1 }', []), 1)
        @Assert(Lowerer_test.runInt('{ => 1.1 > 1.0 }', []), 1)
    }

    /** S3.11：显式数值转换 6 方向（窄化仅显式可达）。 */
    @TestCase
    public func explicitNumericCasts(): Unit {
        @Assert(Lowerer_test.runInt('{ => Int64(1.9) }', []), 1)
        @Assert(Lowerer_test.runInt('{ => -Int64(1.9) }', []), -1)
        @Assert(Lowerer_test.runInt('{ => Decimal(2.9) == 2.9 }', []), 1)
        @Assert(Lowerer_test.runInt('{ => Float64(1) == 1.0 }', []), 1)
        @Assert(Lowerer_test.runInt('{ => Float64(2.5) == 2.5 }', []), 1)
        @Assert(Lowerer_test.runInt('{ => Decimal(2.5) == 2.5 }', []), 1)
        // 非数值类型不允许任何方向
        @Assert(Lowerer_test.compileKind('{ => Int64(true) }'), DiagKind.TYPE_MISMATCH)
    }

    /** S3.12：混合 String 加法与插值共用 `TO_STR + STR_CAT`。 */
    @TestCase
    public func mixedStringAddition(): Unit {
        @Assert(Lowerer_test.runString('{ x: Int64 => "n=" + x }', [7]), 'n=7')
        @Assert(Lowerer_test.runString('{ x: Int64 => x + "!" }', [7]), '7!')
    }

    /**
     * S3.12 / §6：`TO_STR` 的 `t` 是文本化标签（0=I64 … 3=String 4=Decimal …），
     * **不是** `LocalType`（那里 3=Unit、4=String）。两套编号必须在降低期换算。
     */
    @TestCase
    public func toStrUsesTextualTagNamespace(): Unit {
        let d = Lowerer_test.DOLLAR
        @Assert(Lowerer_test.hasToStrTag('{ s: String => "v=' + d + '{s}" }', 'TO_STR 3'), true)
        @Assert(Lowerer_test.hasToStrTag('{ => "v=' + d + '{1}" }', 'TO_STR 0'), true)
        @Assert(Lowerer_test.hasToStrTag('{ => "v=' + d + '{1.5}" }', 'TO_STR 4'), true)
    }

    /** 非标签类型（Closure/容器/Unit）不得进入 `TO_STR`，编译期即拒绝。 */
    @TestCase
    public func untoStrAbleTypesAreRejectedAtCompileTime(): Unit {
        let d = Lowerer_test.DOLLAR
        @Assert(Lowerer_test.compileKind('{ => "v=' + d + '{ {=> 1} }" }'),
            DiagKind.TYPE_MISMATCH)
    }

    /**
     * S3.12：二元 `+` 的两个操作数都已入栈（`rt` 在栈顶、`lt` 在 [rsp+8]），
     * 非 String 侧必须就地转换，不能把 `TO_STR` 作用到栈顶的 String 上。
     */
    @TestCase
    public func stringConcatConvertsTheCorrectOperand(): Unit {
        @Assert(Lowerer_test.runString('{ => let s = "a"\n 7 + s }', []), '7a')
        @Assert(Lowerer_test.runString('{ => let s = "a"\n s + 7 }', []), 'a7')
        @Assert(Lowerer_test.runString('{ => let s = "a"\n let n = 7\n n + s }', []), '7a')
    }

    /** S3.13：Map / String 迭代、`where`、Range step 与闭区间。 */
    @TestCase
    public func loopFormsAndWhere(): Unit {
        @Assert(Lowerer_test.runInt(
            '{ => let m = {1: 10, 2: 20}\n var s = 0\n for ((k, v) in m) { s = s + k }\n s }', []), 3)
        @Assert(Lowerer_test.runInt('{ => var n = 0\n for (c in "abc") { n = n + 1 }\n n }', []), 3)
        @Assert(Lowerer_test.runInt(
            '{ => var s = 0\n for (i in 1..=5 where i % 2 == 0) { s = s + i }\n s }', []), 6)
        @Assert(Lowerer_test.runInt(
            '{ => var s = 0\n for (i in 1..=9 : 3) { s = s + i }\n s }', []), 12)
        @Assert(Lowerer_test.runInt(
            '{ => var s = 0\n for (i in 1..9 : 3) { s = s + i }\n s }', []), 12)
    }

    /** S3.14：多重赋值先读后写（交换）与 `_` 忽略位。 */
    @TestCase
    public func multiAssignReadsBeforeWrite(): Unit {
        @Assert(Lowerer_test.runInt(
            '{ => var a = 1\n var b = 2\n (a, b) = (b, a)\n a * 10 + b }', []), 21)
        @Assert(Lowerer_test.runInt(
            '{ => var a = 1\n var b = 2\n (_, b) = (a, 9)\n b }', []), 9)
    }

    /** S3.15：IIFE 与嵌套闭包捕获（捕获快照、`LOAD_CAP`）。 */
    @TestCase
    public func closuresIifeAndCapture(): Unit {
        @Assert(Lowerer_test.runInt('{ => {=> 42}() }', []), 42)
        @Assert(Lowerer_test.runInt(
            '{ a: Int64 => let f = { b: Int64 => let g = { c: Int64 => a + b + c }\n g(3) }\n f(2) }',
            [1]), 6)
    }

    /** S3.17：有上下文类型的空容器构造。 */
    @TestCase
    public func emptyContainersNeedContext(): Unit {
        @Assert(Lowerer_test.runInt(
            '{ => let l: List<Int64> = []\n var n = 0\n for (x in l) { n = n + 1 }\n n }', []), 0)
        @Assert(Lowerer_test.runInt(
            '{ => let m: Map<String, Int64> = {}\n m["k"] = 5\n m["k"] }', []), 5)
    }

    /** S3.18：区间字面值与正则操作符。 */
    @TestCase
    public func rangeAndRegexOperators(): Unit {
        @Assert(Lowerer_test.runInt(
            '{ => var s = 0\n for (i in 1..=3) { s = s + 1 }\n s }', []), 3)
        @Assert(Lowerer_test.runInt(
            '{ => var s = 0\n for (i in 1..3) { s = s + 1 }\n s }', []), 2)
        @Assert(Lowerer_test.runInt('{ => /b/ ~ "abc" }', []), 1)
        @Assert(Lowerer_test.runInt('{ => /z/ !~ "abc" }', []), 1)
    }

    /** S3.18：String 重复 ×n（含 n 位置窄化）与区间 step=0 拒绝。 */
    @TestCase
    public func stringRepeatAndNarrowing(): Unit {
        @Assert(Lowerer_test.runString('{ => "ab" * 3 }', []), 'ababab')
        @Assert(Lowerer_test.runString('{ => "ab" * 2.0 }', []), 'abab')
        @Assert(Lowerer_test.runString('{ => 2.0 * "ab" }', []), 'abab')
        @Assert(Lowerer_test.runString('{ => "ab" * Decimal(2) }', []), 'abab')
        @Assert(Lowerer_test.compileKind('{ => 1..=5 : 0 }'), DiagKind.TYPE_MISMATCH)
    }

    /** S3.18：正则替换三形（g / 第 n 个 / 越位返回原串）。 */
    @TestCase
    public func regexReplacementForms(): Unit {
        @Assert(Lowerer_test.runString('{ => /b//"abc"/"x"/g }', []), 'axc')
        @Assert(Lowerer_test.runString('{ => /b//"abc"/"x"/0 }', []), 'axc')
        @Assert(Lowerer_test.runString('{ => /b//"abc"/"x"/1 }', []), 'abc')
    }

    /** S3.21：目录 / 类型 / 站点 / 名字与编译期记录一致。 */
    @TestCase
    public func artifactTablesAreConsistent(): Unit {
        let unit = Lowerer_test.compile('{ n: Int64 =>\n let a = n / 0\n a }')
        @Assert(Int64(unit.dir.size) >= 1, true)
        @Assert(unit.types.size, Int64(unit.dir.size))
        @Assert(unit.site.size >= 1, true)
        var i = 0
        while (i < unit.site.size) {
            @Assert(Int64(unit.site.at(i).off) < Int64(unit.code.size), true)
            i = i + 1
        }
        @Assert(unit.name.size >= 1, true)
    }

    // ==================================================================
    // 工具
    // ==================================================================

    private static func compile(src: String): LoadedUnit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink())
        FbcReader.load(sc.compile(src).raw)
    }

    private static func compileKind(src: String): String {
        var got = ''
        try {
            let _ = Lowerer_test.compile(src)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func runInt(src: String, args: Array<Int64>): Int64 {
        let unit = Lowerer_test.compile(src)
        let interp = Interp(unit)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let r = interp.run(unit.header.entryFn, args, ctx)
        JitContext.free(ctx)
        r
    }

    /** 产物文本是否含某条助记符（`TO_STR 3` 这类带操作数的断言）。 */
    private static func hasToStrTag(src: String, want: String): Bool {
        let unit = Lowerer_test.compile(src)
        CodeDump.dump(unit.code).contains(want)
    }

    private static func runString(src: String, args: Array<Int64>): String {
        let unit = Lowerer_test.compile(src)
        let interp = Interp(unit)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let r = interp.run(unit.header.entryFn, args, ctx)
        let ok = ctx.errCode == 0
        JitContext.free(ctx)
        if (!ok) {
            return '#err'
        }
        HandleTable.fetchString(r)
    }
}
