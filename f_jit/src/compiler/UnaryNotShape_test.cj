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

/**
 * 一元 `!` 的前端形状断言（fix-jit-unary-not §4.4 / N1.3）。
 *
 * 这一层是**结构断言**，只负责定位分层：形状红 ⇒ Parser/Lowerer；编码红 ⇒ 后端原语；
 * 只有语义红 ⇒ 后端语义 / 桥（design §4.5「假绿禁令」——结构断言不单独作为验收）。
 *
 * `!(n < 50)` 的前端本来就对（design §2.1 S1/S2），因此本组在修复前**应直接绿**；
 * 它若红，说明根因另有其处，必须回到 design §2 重新定位。
 */
@Test
public class UnaryNotShape_test {
    /**
     * S1：AST 顶层是 `Bang`，唯一子节点是 `<` 比较（不是 `(!n) < 50`）。
     *
     * `AstShape.exprOf` 的入参是**lambda 源**（内部走 `Parser.parseLambda`），
     * 故这里给 `{ n: Int64 => ... }`，形状文本取自尾表达式。
     */
    @TestCase
    public func astShapeOfReportedCase(): Unit {
        @Assert(AstShape.exprOf('{ n: Int64 => !(n < 50) }'), '(! (< var(n) lit(50)))')
    }

    /** S2：函数体为 `LOADL; PUSH_I64 50; LT_I; NOT_B; RET`，且 `NOT_B` 恰一条。 */
    @TestCase
    public func bytecodeShapeOfReportedCase(): Unit {
        let ops = UnaryNotShape_test.opsOf('{ n: Int64 => !(n < 50) }')
        @Assert(ops.contains('LOADL PUSH_I64 LT_I NOT_B RET'), true)
        @Assert(UnaryNotShape_test.countOf(ops, 'NOT_B'), 1)
        // 否证「比较被降成三态 CMP_I」：产物里必须是 LT_I
        @Assert(UnaryNotShape_test.countOf(ops, 'CMP_I'), 0)
    }

    /** `!~`：`Lowerer` 在 `REGEX_IS_MATCH` 之后追加恰一条 `NOT_B`。 */
    @TestCase
    public func bytecodeShapeOfRegexNegation(): Unit {
        let ops = UnaryNotShape_test.opsOf('{ => /abc/ !~ "x" }')
        @Assert(ops.contains('REGEX_IS_MATCH NOT_B RET'), true)
        @Assert(UnaryNotShape_test.countOf(ops, 'NOT_B'), 1)
    }

    /** 类型分派（N2.4 / D3）：`Int64` 操作数编译为 `BNOT_I`，且**不**发 `NOT_B`。 */
    @TestCase
    public func int64OperandLowersToBitNot(): Unit {
        let ops = UnaryNotShape_test.opsOf('{ n: Int64 => !n }')
        @Assert(ops.contains('BNOT_I RET'), true)
        @Assert(UnaryNotShape_test.countOf(ops, 'BNOT_I'), 1)
        @Assert(UnaryNotShape_test.countOf(ops, 'NOT_B'), 0)
    }

    /** 类型分派（N2.4 / D3）：`Bool` 操作数编译为 `NOT_B`，且**不**发 `BNOT_I`。 */
    @TestCase
    public func boolOperandLowersToLogicalNot(): Unit {
        let ops = UnaryNotShape_test.opsOf('{ b: Bool => !b }')
        @Assert(ops.contains('NOT_B RET'), true)
        @Assert(UnaryNotShape_test.countOf(ops, 'NOT_B'), 1)
        @Assert(UnaryNotShape_test.countOf(ops, 'BNOT_I'), 0)
    }

    /** 类型分派（N2.4 / D3）：其余类型在**编译期**报错，不得落到运行期各引擎各说各话。 */
    @TestCase
    public func nonBoolNonIntOperandIsRejected(): Unit {
        var caught = ''
        try {
            let _ = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
                strictFp: false).compile('{ s: String => !s }')
        } catch (e: SourceCompileException) {
            caught = e.message
        }
        @Assert(caught.contains('TYPE_MISMATCH') || caught.contains('只支持'), true)
    }

    private static func opsOf(src: String): String {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            strictFp: false).compile(src)
        CodeDump.ops(cu.raw)
    }

    /** 子串出现次数（`CodeDump.ops` 以空格分隔，`NOT_B` 不会与其它名字前缀冲突）。 */
    private static func countOf(s: String, pat: String): Int64 {
        let size = Int64(s.size)
        let psize = Int64(pat.size)
        var hits = 0
        var i = 0
        while (i + psize <= size) {
            if (s[i..i + psize] == pat) {
                hits = hits + 1
                i = i + psize
            } else {
                i = i + 1
            }
        }
        hits
    }
}
