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
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffSession
import fountain::f_jit.test.diff.InterpRunner
import fountain::f_jit.test.diff.NativeRunner
import fountain::f_jit.test.diff.assertTripleEqual

/**
 * 一元 `!` 的三引擎语义对拍（fix-jit-unary-not §4.2 / N1.1 / N1.5）。
 *
 * 每条用例断言两件事，缺一不可（design D3）：
 * 1. **解释器结果 = 绝对值**——只做引擎间对拍会掩盖「三引擎一致地错」；
 * 2. `Interp × 原生后端` 四元组逐位一致（`result` / `errCode` / `site` / `report`）。
 *
 * 红态指纹：修复前 AArch64 的 `NOT_B` 编成 `EOR X9,X0,#1`，而 `x0` 在无 helper
 * 函数体里恒为 ctx（非零指针），故 `!(n < 50)` 在 `n = 49` 上返回 `ctx|1`
 * ——一个巨大的十进制数，而解释器是 `0`。
 */
@Test
public class UnaryNotDiff_test {
    /** 报障用例：`!(n < 50)`，`n = 49`（design §4.2 首行）。 */
    @TestCase
    public func reportedCase(): Unit {
        let src = '{ n: Int64 => !(n < 50) }'
        UnaryNotDiff_test.check('N/not-lt-49', src, [49], '0')
    }

    /** 边界：48 / 49 / 50 / 51 → `0 / 0 / 1 / 1`。 */
    @TestCase
    public func comparisonBoundary(): Unit {
        let src = '{ n: Int64 => !(n < 50) }'
        UnaryNotDiff_test.check('N/not-lt-48', src, [48], '0')
        UnaryNotDiff_test.check('N/not-lt-49', src, [49], '0')
        UnaryNotDiff_test.check('N/not-lt-50', src, [50], '1')
        UnaryNotDiff_test.check('N/not-lt-51', src, [51], '1')
    }

    /** 极值：`Int64.Min / Int64.Max` → `0 / 1`（64 位比较不得截断）。 */
    @TestCase
    public func comparisonExtremes(): Unit {
        let src = '{ n: Int64 => !(n < 50) }'
        UnaryNotDiff_test.check('N/not-lt-min', src, [Int64.Min], '0')
        UnaryNotDiff_test.check('N/not-lt-max', src, [Int64.Max], '1')
    }

    /**
     * 比较族：`!(<=)` / `!(==)` / `!(!=)` 取反后都为 `0`（真值域只有 0/1）。
     *
     * `!(!=)` 的入参取 4 而非 5：`5 != 5` 为假，取反得 `1`（design §4.2 表的期望与入参
     * 有一处算术笔误，按「比较为真 → 取反为 0」的口径把入参改成使比较成立的值）。
     */
    @TestCase
    public func comparisonFamily(): Unit {
        UnaryNotDiff_test.check('N/not-le', '{ n: Int64 => !(n <= 50) }', [50], '0')
        UnaryNotDiff_test.check('N/not-eq', '{ n: Int64 => !(n == 5) }', [5], '0')
        UnaryNotDiff_test.check('N/not-ne', '{ n: Int64 => !(n != 5) }', [4], '0')
    }

    /** 布尔实参：`{ b: Bool => !b }` → `true / false` 取反为 `0 / 1`。 */
    @TestCase
    public func booleanArgument(): Unit {
        let src = '{ b: Bool => !b }'
        UnaryNotDiff_test.check('N/not-true', src, [true], '0')
        UnaryNotDiff_test.check('N/not-false', src, [false], '1')
    }

    /** 双重取反：`!!(n < 50)` 在 49 上回到 `1`（两次 `NOT_B` 可叠加）。 */
    @TestCase
    public func doubleNegation(): Unit {
        UnaryNotDiff_test.check('N/not-not-lt', '{ n: Int64 => !!(n < 50) }', [49], '1')
    }

    /** 逻辑组合：`!(a && b)` / `!(a || b)` 与 `&&`/`||` 真值取反一致。 */
    @TestCase
    public func logicalCombination(): Unit {
        let a = '{ a: Bool, b: Bool => !(a && b) }'
        UnaryNotDiff_test.check('N/not-and-tt', a, [true, true], '0')
        UnaryNotDiff_test.check('N/not-and-tf', a, [true, false], '1')
        let o = '{ a: Bool, b: Bool => !(a || b) }'
        UnaryNotDiff_test.check('N/not-or-tt', o, [true, true], '0')
        UnaryNotDiff_test.check('N/not-or-tf', o, [true, false], '0')
        UnaryNotDiff_test.check('N/not-or-ff', o, [false, false], '1')
    }

    /**
     * 正则取反（`Lowerer` 为 `!~` 追加的那条 `NOT_B`）：`"abc"` → `0`、`"x"` → `1`。
     *
     * 实参走源码内字面量：`DiffCase.args` 的 cell 装箱只认 `Int64 / Float64 / Bool`
     * （`RealRunners.cells`），String 会被填成 0（空指针），故不能按 `{ s: String => ... }` 传参。
     */
    @TestCase
    public func regexNotMatch(): Unit {
        UnaryNotDiff_test.check('N/not-re-hit', '{ => /abc/ !~ "abc" }', Array<Any>(), '0')
        UnaryNotDiff_test.check('N/not-re-miss', '{ => /abc/ !~ "x" }', Array<Any>(), '1')
    }

    /** 无 `!` 对照：`n < 50` 在 49 / 50 上仍为 `1 / 0`（修复不得改变比较语义）。 */
    @TestCase
    public func noNotControl(): Unit {
        let src = '{ n: Int64 => n < 50 }'
        UnaryNotDiff_test.check('N/lt-49', src, [49], '1')
        UnaryNotDiff_test.check('N/lt-50', src, [50], '0')
    }

    /**
     * 非 Bool 操作数（N1.5 / design §3.3 D3）：`!` 对 `Int64` 取位反。
     *
     * `!2 = -3`、`!-1 = 0`、`!0 = -1`，极值按位互补；三引擎必须逐位一致。
     * 修复前：解释器得 `0`，两个后端得 `3`（`x ^ 1`），三引擎分歧。
     */
    @TestCase
    public func bitwiseNotOnInt64(): Unit {
        let src = '{ n: Int64 => !n }'
        UnaryNotDiff_test.check('N/bnot-2', src, [2], '-3')
        UnaryNotDiff_test.check('N/bnot-neg1', src, [-1], '0')
        UnaryNotDiff_test.check('N/bnot-0', src, [0], '-1')
        UnaryNotDiff_test.check('N/bnot-max', src, [Int64.Max], '-9223372036854775808')
        UnaryNotDiff_test.check('N/bnot-min', src, [Int64.Min], '9223372036854775807')
    }

    private static func check(id: String, src: String, args: Array<Any>,
        expected: String): Unit {
        // 差分基线是 IEEE 语义：显式关闭严格浮点（与 DiffExec_test 同口径）
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            strictFp: false).compile(src)
        let session = DiffSession([InterpRunner(), NativeRunner()])
        let outs = session.runAll(DiffCase(id, cu.raw, args))
        if (outs.size < 2) {
            @Fail('${id}: 可用引擎只有 ${outs.size} 个，无法构成差分对拍')
            return
        }
        // 1. 解释器绝对值锚定：判据在「值对不对」，不在「引擎们是否一致」
        if (outs[0].result != expected) {
            @Fail('${id}: 解释器绝对值不符 —— 期望 ${expected}，实得 ${outs[0].result}；' +
                '原生后端实得 ${outs[1].result}')
            return
        }
        // 2. 三引擎逐位一致（不一致会带出 `result: a != b` 这类维度级信息）
        assertTripleEqual(id, outs)
        @Assert(session.ran() >= 1, true)
    }
}
