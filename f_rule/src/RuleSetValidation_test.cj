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
package fountain::f_rule

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.*
import fountain::f_rule.exception.*
import fountain::f_rule.fact.*
import fountain::f_rule.rule.*

/**
 * `RuleSet.build()` 的全量静态校验（`doc/02-fact-model.md` §8，用例 F-13/F-14）。
 *
 * 每个失败都必须在**构建期**暴露并带明确错误码；失败后规则集进入 `Invalid`，
 * 不能构造引擎（M3）。校验通过则冻结空间集合与类型描述。
 */
@Test
class RuleSetValidation_test {
    private func space(): String {
        "orders"
    }

    private func base(): RuleSetBuilder {
        RuleSetBuilder("pricing")
            .registerFact(space(), builderOrderSchema())
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

    private func buildCode(builder: RuleSetBuilder): RuleErrorCode {
        try {
            let _ = builder.build()
        } catch (e: RuleException) {
            return e.code
        }
        RuleErrorCode.CLOSED
    }

    /** F-13：同一规则的模式跨空间。 */
    @TestCase
    public func crossSpaceJoinRejected(): Unit {
        let rule = Rule.builder("R1")
            .facts(space())
            .addPattern(Pattern("Order", "o", space: "users"))
            .build()
        @Expect(buildCode(base().factSpace("users").rule(rule)), RuleErrorCode.CROSS_SPACE_JOIN)
    }

    /** F-14：规则引用未声明空间。 */
    @TestCase
    public func unknownFactSpaceRejected(): Unit {
        let rule = Rule.builder("R1")
            .facts("missing")
            .addPattern(Pattern.any("Order", "o"))
            .build()
        @Expect(buildCode(base().rule(rule)), RuleErrorCode.UNKNOWN_FACT_SPACE)
    }

    /** 没有任何空间（也没有规则）的规则集。 */
    @TestCase
    public func emptyFactSpaceSetRejected(): Unit {
        @Expect(buildCode(RuleSetBuilder("empty")), RuleErrorCode.EMPTY_FACT_SPACE_SET)
    }

    /** 模式引用未注册类型。 */
    @TestCase
    public func unknownTypeRejected(): Unit {
        let rule = Rule.builder("R1")
            .facts(space())
            .addPattern(Pattern.any("Missing", "o"))
            .build()
        @Expect(buildCode(base().rule(rule)), RuleErrorCode.UNKNOWN_TYPE)
    }

    /** 约束引用未声明字段。 */
    @TestCase
    public func unknownFieldRejected(): Unit {
        let rule = Rule.builder("R1")
            .facts(space())
            .addPattern(Pattern("Order", "o").constrain("nonexistent", Operator.Eq, 1))
            .build()
        @Expect(buildCode(base().rule(rule)), RuleErrorCode.UNKNOWN_FIELD)
    }

    /** 算子与静态字段类型不兼容：Number 上做 Matches。 */
    @TestCase
    public func typeMismatchRejected(): Unit {
        let rule = Rule.builder("R1")
            .facts(space())
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Matches, "^[0-9]+$"))
            .build()
        @Expect(buildCode(base().rule(rule)), RuleErrorCode.TYPE_MISMATCH)
    }

    /** join 引用不存在的绑定。 */
    @TestCase
    public func unknownJoinBindingRejected(): Unit {
        let rule = Rule.builder("R1")
            .facts(space())
            .addPattern(Pattern("Order", "o"))
            .join(JoinConstraint("o", "amount", Operator.Gt, "x", "amount"))
            .build()
        @Expect(buildCode(base().rule(rule)), RuleErrorCode.UNKNOWN_BINDING)
    }

    /** 失败后状态为 `Invalid`，且 `build()` 原样上抛校验错误码。 */
    @TestCase
    public func failedBuildLeavesInvalidState(): Unit {
        let builder = base().rule(Rule.builder("R1")
            .facts(space())
            .addPattern(Pattern.any("Missing", "o"))
            .build())
        let ruleSet = builder.buildOrInvalid()
        @Expect(ruleSet.status, RuleSetStatus.Invalid)
        @Expect(ruleSet.isValid(), false)
        @Expect(builder.lastError().getOrThrow().code, RuleErrorCode.UNKNOWN_TYPE)
        @Expect(buildCode(builder), RuleErrorCode.UNKNOWN_TYPE)
    }

    /** 校验通过后空间与类型描述冻结，运行期新增抛 `NETWORK_FROZEN`。 */
    @TestCase
    public func successfulBuildFreezesRegistry(): Unit {
        let ruleSet = base()
            .rule(Rule.builder("R1").facts(space()).addPattern(Pattern.any("Order", "o")).build())
            .build()
        @Expect(ruleSet.registry.frozen, true)
        @Expect(ruleSet.registry.get(space()).getOrThrow().frozen, true)
        @Expect(codeOf({ => let _ = ruleSet.registry.declare("late") }), RuleErrorCode.NETWORK_FROZEN)
    }

    /** 合法规则集：两模式 + join 通过校验。 */
    @TestCase
    public func validTwoPatternRulePasses(): Unit {
        let rule = Rule.builder("R1")
            .facts(space())
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Ge, 100))
            .addPattern(Pattern("Order", "u").constrain("amount", Operator.Ge, 100))
            .join(JoinConstraint("o", "amount", Operator.Gt, "u", "amount"))
            .build()
        let ruleSet = base().rule(rule).build()
        @Expect(ruleSet.isValid(), true)
        @Assert(ruleSet.rules.size, 1)
    }
}
