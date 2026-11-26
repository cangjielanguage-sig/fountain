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
package fountain::f_rule.condition

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.Compiler
import fountain::f_rule.fact.*

/**
 * `JitExpression` 的后端选择（`usesJit`）。
 *
 * 背景：f_jit 的 AArch64 `NOT_B` 曾把 `EOR X9,X9,#1` 错编码成 `EOR X9,X0,#1`，
 * 导致任何一元 `!` 恒真。修复（`fix-jit-unary-not`）合入后，f_rule 侧原先
 * 「含一元 `!` 一律降级解释器」的绕过应被移除；本用例锁定该行为，防止降级被
 * 无声保留（保留不会出错，但会让这类条件永久失去 JIT 性能）。
 */
@Test
class JitExpressionMode_test {
    private func compiler(): Compiler {
        let c = Compiler()
        c.registerType<JitOrder>()
        c
    }

    /** 对照：普通比较必须走 JIT。 */
    @TestCase
    public func plainComparisonUsesJit(): Unit {
        let expr = JitExpression.of("{ o: JitOrder => o.amount > 200 }", compiler())
        @Assert(expr.usesJit)
    }

    /** f_jit 修复后，含一元 `!` 的条件必须重新走 JIT。 */
    @TestCase
    public func unaryNotUsesJit(): Unit {
        let expr = JitExpression.of("{ o: JitOrder => !(o.amount < 50) }", compiler())
        @Assert(expr.usesJit)
    }

    /** 一元 `!` 走 JIT 后结果必须与语义一致（n = 49 → false）。 */
    @TestCase
    public func unaryNotSemanticsUnderJit(): Unit {
        let expr = JitExpression.of("{ o: JitOrder => !(o.amount < 50) }", compiler())
        let bindings = HashMap<String, Fact>()
        bindings["o"] = TypedFact(JitOrder("D", 49, 1, "normal"), jitOrderSchema())
        @Assert(!expr.eval(bindings))
    }

    /** 动态事实仍必须走解释器（与一元 `!` 的降级是两回事）。 */
    @TestCase
    public func dynamicFactStaysInterpreted(): Unit {
        let expr = JitExpression.ofExpression("amount > 200", [("o", "")], compiler())
        @Assert(!expr.usesJit)
    }

    /** 强制解释器模式必须 `usesJit == false`。 */
    @TestCase
    public func forcedInterpretedIsNotJit(): Unit {
        let expr = JitExpression.interpreted("o.amount > 200", ["o"])
        @Assert(!expr.usesJit)
    }
}
