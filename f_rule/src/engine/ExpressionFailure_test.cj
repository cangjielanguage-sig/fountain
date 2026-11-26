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
package fountain::f_rule.engine

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.*
import fountain::f_jit.macros.*
import fountain::f_rule.condition.{EvalFailureKind, JoinConstraint, Operator, Pattern}
import fountain::f_rule.fact.{DynamicFact, FactSchema, FieldType, TypedFact}
import fountain::f_rule.rule.{ActionContext, Rule, RuleSet, RuleSetBuilder}
import fountain::f_rule.runtime.RuleRuntime

/** 求值失败用例的宿主类。 */
@JitBind
public class FailureOrder {
    public var amount: Int64
    public var level: Int64

    public init(amount: Int64, level: Int64) {
        this.amount = amount
        this.level = level
    }
}

func failureOrderSchema(): FactSchema<FailureOrder> {
    FactSchema<FailureOrder>("FailureOrder")
        .field("amount", FieldType.Number) { o => o.amount }
        .field("level", FieldType.Number) { o => o.level }
}

func failureRuleSet(script: String, then: (ActionContext) -> Unit): RuleSet {
    let compiler = Compiler()
    compiler.registerType<FailureOrder>()
    RuleRuntime.initCompiler(compiler)
    let rule = Rule.builder("R1")
        .addPattern(Pattern.any("FailureOrder", "o"))
        .script(script)
        .then(then)
        .build()
    RuleSetBuilder("failure")
        .version("v1")
        .registerFact(failureOrderSchema())
        .rule(rule)
        .build()
}

func hitThen(ctx: ActionContext): Unit {
    ctx.set("hit", true)
}

/**
 * 求值失败的运行期语义（`doc/03-condition-expression.md` §6.2）。
 *
 * 异常/超时一律视为 `Unknown`，不产生激活、不穿透事件循环；连续失败达到阈值后
 * 在**规则集级**禁用规则，成功一次即清零。
 */
@Test
class ExpressionFailure_test {
    /** 除零这类运行期异常不得穿透，规则不激活且失败计数 +1。 */
    @TestCase
    public func divisionByZeroIsUnknownAndCounted(): Unit {
        let engine = RuleEngine(failureRuleSet(
            "{ o: FailureOrder => 100 / (o.level - o.level) > 0 }", hitThen))
        let session = engine.session("s1")
        let _ = session.assert(TypedFact(FailureOrder(500, 3), failureOrderSchema()))

        let outputs = session.fire()
        @Expect(outputs.contains("hit"), false)
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 1)
        @Expect(engine.ruleSet.ruleDisabled("R1"), false)
    }

    /** 「连续」指成功一次即清零，而不是累计失败次数。 */
    @TestCase
    public func successResetsConsecutiveFailureCount(): Unit {
        let engine = RuleEngine(failureRuleSet(
            "{ o: FailureOrder => 100 / (o.level - 3) > 0 }", hitThen))
        let session = engine.session("s1")

        // level = 3：除零，失败 1 次
        let _ = session.assert(TypedFact(FailureOrder(500, 3), failureOrderSchema()))
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 1)

        // level = 5：成功求值（结果 true），计数清零
        let _ = session.assert(TypedFact(FailureOrder(500, 5), failureOrderSchema()))
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 0)

        // 再失败一次，计数从 0 重新开始
        let _ = session.assert(TypedFact(FailureOrder(500, 3), failureOrderSchema()))
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 1)
    }

    /** 100 次连续失败后禁用；计数与禁用位按 `(ruleSetId, ruleId)` 跨会话共享。 */
    @TestCase
    public func disablesAfterHundredFailuresAcrossSessions(): Unit {
        let engine = RuleEngine(failureRuleSet(
            "{ o: FailureOrder => 100 / (o.level - o.level) > 0 }", hitThen))
        let first = engine.session("s1")
        let second = engine.session("s2")

        var i = 0
        while (i < 50) {
            let _ = first.assert(TypedFact(FailureOrder(500, 3), failureOrderSchema()))
            i += 1
        }
        while (i < 100) {
            let _ = second.assert(TypedFact(FailureOrder(500, 3), failureOrderSchema()))
            i += 1
        }

        @Assert(engine.ruleSet.ruleFailureCount("R1"), 100)
        @Expect(engine.ruleSet.ruleDisabled("R1"), true)

        // 禁用后即使脚本本可成功也不再求值：计数保持 100、不产生激活。
        let third = engine.session("s3")
        let _ = third.assert(TypedFact(FailureOrder(500, 5), failureOrderSchema()))
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 100)
        @Expect(third.fire().contains("hit"), false)
    }

    /** `EngineOptions.expressionTimeout` 约束单次求值；超时按 Unknown 处理。 */
    @TestCase
    public func timeoutIsUnknownAndCounted(): Unit {
        let options = EngineOptions(expressionTimeout: Duration.millisecond * 2)
        let engine = RuleEngine(failureRuleSet(
            "{ o: FailureOrder => var i = 0\n while (i < o.amount) { i = i + 1 }\n true }",
            hitThen), options)
        let session = engine.session("s1")
        let _ = session.assert(TypedFact(FailureOrder(1_000_000_000, 3), failureOrderSchema()))

        let outputs = session.fire()
        @Expect(outputs.contains("hit"), false)
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 1)
    }

    /** 动态事实字段类型未知：首次运行期类型不符按 TYPE_MISMATCH 记失败，共用同一计数器。 */
    @TestCase
    public func dynamicFactTypeMismatchSharesFailureState(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern.any("DynOrder", "d"))
            .script("d.amount > 200")
            .then(hitThen)
            .build()
        let ruleSet = RuleSetBuilder("dynamic")
            .version("v1")
            .registerDynamicType("DynOrder", ["amount"])
            .rule(rule)
            .build()
        let engine = RuleEngine(ruleSet)
        let session = engine.session("s1")
        let fact = DynamicFact("DynOrder")
        fact.set("amount", "abc")
        let _ = session.assert(fact)

        @Expect(session.fire().contains("hit"), false)
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 1)
        match (engine.ruleSet.lastFailureKind("R1")) {
            case Some(kind) => @Expect(kind, EvalFailureKind.TypeMismatch)
            case None => @Fail("应当记录 TYPE_MISMATCH")
        }
    }

    /** 动态事实脚本走解释器：构建期不因 `DynamicFact.get(): ?Any` 被 f_jit 拒绝。 */
    @TestCase
    public func dynamicFactScriptBuildsUnderJitPreferred(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern.any("DynOrder", "d"))
            .script("{ d: DynOrder => d.amount > 200 }")
            .then(hitThen)
            .build()
        let ruleSet = RuleSetBuilder("dynamic")
            .version("v1")
            .registerDynamicType("DynOrder", ["amount"])
            .rule(rule)
            .build()
        @Expect(ruleSet.isValid(), true)
    }

    /** 动态事实的单事实约束类型不符：不得穿透 assert，按 TYPE_MISMATCH 计数。 */
    @TestCase
    public func dynamicConstraintTypeMismatchDoesNotEscape(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern.any("DynOrder", "d").constrain("amount", Operator.Gt, 200))
            .then(hitThen)
            .build()
        let ruleSet = RuleSetBuilder("dynamic")
            .version("v1")
            .registerDynamicType("DynOrder", ["amount"])
            .rule(rule)
            .build()
        let engine = RuleEngine(ruleSet)
        let session = engine.session("s1")
        let fact = DynamicFact("DynOrder")
        fact.set("amount", "abc")

        // 异常不得从 session.assert 透出（RuleTask 调用点会把它带进事件循环）。
        let _ = session.assert(fact)
        @Expect(session.fire().contains("hit"), false)
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 1)
        match (engine.ruleSet.lastFailureKind("R1")) {
            case Some(kind) => @Expect(kind, EvalFailureKind.TypeMismatch)
            case None => @Fail("应当记录 TYPE_MISMATCH")
        }
    }

    /** 动态事实的 join 类型不符：同样不得穿透，并与单事实约束共用计数器。 */
    @TestCase
    public func dynamicJoinTypeMismatchDoesNotEscape(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern.any("DynA", "a"))
            .addPattern(Pattern.any("DynB", "b"))
            .join(JoinConstraint("a", "amount", Operator.Gt, "b", "amount"))
            .then(hitThen)
            .build()
        let ruleSet = RuleSetBuilder("dynamic")
            .version("v1")
            .registerDynamicType("DynA", ["amount"])
            .registerDynamicType("DynB", ["amount"])
            .rule(rule)
            .build()
        let engine = RuleEngine(ruleSet)
        let session = engine.session("s1")
        let left = DynamicFact("DynA")
        left.set("amount", "abc")
        let right = DynamicFact("DynB")
        right.set("amount", 100)

        let _ = session.assert(left)
        let _ = session.assert(right)
        @Expect(session.fire().contains("hit"), false)
        @Assert(engine.ruleSet.ruleFailureCount("R1"), 1)
        match (engine.ruleSet.lastFailureKind("R1")) {
            case Some(kind) => @Expect(kind, EvalFailureKind.TypeMismatch)
            case None => @Fail("应当记录 TYPE_MISMATCH")
        }
    }
}
