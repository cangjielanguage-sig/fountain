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
import fountain::f_jit.*
import fountain::f_jit.macros.*
import fountain::f_rule.exception.*
import fountain::f_rule.fact.*

/** JIT 测试宿主类：字段必须 public 才能被反射注册。 */
@JitBind
public class JitOrder {
    public var id: String
    public var amount: Int64
    public var level: Int64
    public var name: String

    public init(id: String, amount: Int64, level: Int64, name: String) {
        this.id = id
        this.amount = amount
        this.level = level
        this.name = name
    }
}

/** JIT 测试 schema。 */
public func jitOrderSchema(): FactSchema<JitOrder> {
    FactSchema<JitOrder>("Order")
        .field("id", FieldType.Text, { o => o.id })
        .field("amount", FieldType.Number, { o => o.amount })
        .field("level", FieldType.Number, { o => o.level })
        .field("name", FieldType.Text, { o => o.name })
}

/**
 * `JitExpression` 的两种构造与降级契约（`doc/03-condition-expression.md` §6~§7）。
 *
 * 关键点：
 * 1. `of` 只接受完整 lambda；语法错误包装成 `SCRIPT_COMPILE`，不静默降级；
 * 2. `ofExpression` 按绑定名 + 宿主类型拼 lambda；
 * 3. 动态事实（`get(): ?Any`）无法进 JIT，整体走内置解释器并记一次 WARN；
 * 4. 脚本形参与模式绑定不齐时构建期抛 `SCRIPT_BINDING_MISSING`。
 */
@Test
class JitExpression_test {
    private func compiler(): Compiler {
        let c = Compiler()
        c.registerType<JitOrder>()
        c
    }

    private func bindings(order: JitOrder): HashMap<String, Fact> {
        let map = HashMap<String, Fact>()
        map["o"] = TypedFact(order, jitOrderSchema())
        map
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    /** 完整 lambda 直接编译并求值。 */
    @TestCase
    public func compilesFullLambda(): Unit {
        let expr = JitExpression.of(
            "{ o: JitOrder => o.amount > 200 && o.level >= 3 }",
            compiler()
        )
        @Assert(expr.parameters.size, 1)
        @Assert(expr.parameters[0], "o")
        @Expect(expr.eval(bindings(JitOrder("A", 500, 3, "vip"))), true)
        @Expect(expr.eval(bindings(JitOrder("B", 100, 3, "vip"))), false)
        @Expect(expr.eval(bindings(JitOrder("C", 500, 1, "vip"))), false)
    }

    /** 裸表达式按绑定类型拼 lambda 后编译。 */
    @TestCase
    public func wrapsBareExpressionWithBindings(): Unit {
        let expr = JitExpression.ofExpression(
            "o.amount > 200",
            [("o", "JitOrder")],
            compiler()
        )
        @Assert(expr.parameters[0], "o")
        @Expect(expr.eval(bindings(JitOrder("A", 500, 3, "vip"))), true)
        @Expect(expr.eval(bindings(JitOrder("B", 100, 3, "vip"))), false)
    }

    /** 语法错误抛 `SCRIPT_COMPILE`，且不产生可运行对象。 */
    @TestCase
    public func syntaxErrorIsNotSilentlyDowngraded(): Unit {
        @Expect(codeOf({ => let _ = JitExpression.of("{ o: JitOrder => o.amount > }", compiler()) }),
            RuleErrorCode.SCRIPT_COMPILE)
        @Expect(codeOf({ => let _ = JitExpression.of("o.amount > 200", compiler()) }),
            RuleErrorCode.SCRIPT_COMPILE)
    }

    /** 脚本形参在模式绑定中找不到 → `SCRIPT_BINDING_MISSING`。 */
    @TestCase
    public func missingParameterRejected(): Unit {
        let expr = JitExpression.of("{ o: JitOrder => o.amount > 200 }", compiler())
        @Expect(codeOf({ => expr.requireBindings(["u"]) }), RuleErrorCode.SCRIPT_BINDING_MISSING)
        expr.requireBindings(["o"])
    }

    /** 动态事实绑定整体走解释器，并记一次 WARN。 */
    @TestCase
    public func dynamicBindingFallsBackToInterpreter(): Unit {
        let before = JitExpression.interpretationWarningCount()
        let expr = JitExpression.ofExpression("amount > 200", [("f", "")], compiler())

        let facts = HashMap<String, Fact>()
        let dynamic = DynamicFact("Row")
        dynamic.set("amount", 500)
        facts["f"] = dynamic

        @Expect(expr.eval(facts), true)
        replaceWith(facts, 100)
        @Expect(expr.eval(facts), false)
        @Assert(JitExpression.interpretationWarningCount(), before + 1)
    }

    private func replaceWith(facts: HashMap<String, Fact>, amount: Int64): Unit {
        let dynamic = DynamicFact("Row")
        dynamic.set("amount", amount)
        facts["f"] = dynamic
    }

    /** 解释器语法错误同样抛 `SCRIPT_COMPILE`（不静默返回 false）。 */
    @TestCase
    public func interpreterSyntaxErrorIsReported(): Unit {
        @Expect(codeOf({ => let _ = JitExpression.interpreted("amount >", ["f"]) }),
            RuleErrorCode.SCRIPT_COMPILE)
        // 白名单之外的函数在构建期就拒绝
        @Expect(codeOf({ => let _ = JitExpression.interpreted("shell(f)", ["f"]) }),
            RuleErrorCode.SCRIPT_COMPILE)
    }

    /** 解释器可独立使用（决策表 `expr` 列与动态事实共用同一条路径）。 */
    @TestCase
    public func interpretedEvaluatesDirectly(): Unit {
        let expr = JitExpression.interpreted("amount > 200 && level >= 3", ["f"])
        let facts = HashMap<String, Fact>()
        let dynamic = DynamicFact("Row")
        dynamic.set("amount", 500)
        dynamic.set("level", 3)
        facts["f"] = dynamic
        @Expect(expr.eval(facts), true)

        replaceWith(facts, 100)
        @Expect(expr.eval(facts), false)
    }
}
