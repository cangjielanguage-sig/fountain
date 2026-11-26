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

/** RuleSetBuilder 测试宿主类。 */
public class BuilderOrder {
    public var id: String
    public var amount: Int64

    public init(id: String, amount: Int64) {
        this.id = id
        this.amount = amount
    }
}

public func builderOrderSchema(): FactSchema<BuilderOrder> {
    FactSchema<BuilderOrder>("Order")
        .field("id", FieldType.Text, { o => o.id })
        .field("amount", FieldType.Number, { o => o.amount })
}

/**
 * `RuleSetBuilder` 的装配契约（`doc/08-api.md` §3，用例 F-15）。
 *
 * 空间自动声明、默认空间、表达式模式与冲突消解器都要能落到 `RuleSet` 上；
 * 重复规则 id 在装配时就拒绝。
 */
@Test
class RuleSetBuilder_test {
    private func orderRule(id: String): Rule {
        Rule.builder(id)
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 1))
            .build()
    }

    private func orderRuleIn(space: String, id: String): Rule {
        Rule.builder(id)
            .facts(space)
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 1))
            .build()
    }

    /** 基本装配：id/version/rules。 */
    @TestCase
    public func assemblesBasicFields(): Unit {
        let ruleSet = RuleSetBuilder("pricing")
            .version("v1")
            .registerFact("orders", builderOrderSchema())
            .rule(orderRuleIn("orders", "R1"))
            .build()

        @Assert(ruleSet.id, "pricing")
        @Assert(ruleSet.version, "v1")
        @Assert(ruleSet.rules.size, 1)
        @Expect(ruleSet.isValid(), true)
    }

    /** `registerFact(space, schema)` 自动声明空间，并按声明顺序登记。 */
    @TestCase
    public func registrationDeclaresSpace(): Unit {
        let ruleSet = RuleSetBuilder("pricing")
            .registerFact("orders", builderOrderSchema())
            .factSpace("users")
            .rule(orderRuleIn("orders", "R1"))
            .build()

        @Expect(ruleSet.registry.has("orders"), true)
        @Expect(ruleSet.registry.has("users"), true)
        @Assert(ruleSet.registry.ids(), ["orders", "users"])
        @Assert(ruleSet.registry.get("orders").getOrThrow().typeTags(), ["Order"])
    }

    /** 不写空间的注册落到 default。 */
    @TestCase
    public func defaultRegistration(): Unit {
        let ruleSet = RuleSetBuilder("pricing")
            .registerFact(builderOrderSchema())
            .rule(orderRule("R1"))
            .build()

        @Expect(ruleSet.registry.has("default"), true)
        @Expect(ruleSet.registry.get("default").getOrThrow().hasType("Order"), true)
    }

    /** 动态类型注册：字段类型统一为 Any。 */
    @TestCase
    public func registersDynamicType(): Unit {
        let ruleSet = RuleSetBuilder("pricing")
            .registerDynamicType("rows", "Row", ["amount", "code"])
            .rule(Rule.builder("R1")
                .facts("rows")
                .addPattern(Pattern.any("Row", "r"))
                .build())
            .build()

        let space = ruleSet.registry.get("rows").getOrThrow()
        @Expect(space.hasType("Row"), true)
        @Assert(space.fieldNames("Row"), ["amount", "code"])
        @Expect(space.fieldType("Row", "amount").getOrThrow(), FieldType.`Any`)
    }

    /** F-15：未声明空间的规则归入 default，与显式 `.facts("default")` 等价。 */
    @TestCase
    public func implicitDefaultSpace(): Unit {
        let ruleSet = RuleSetBuilder("pricing")
            .registerFact(builderOrderSchema())
            .rule(orderRule("R1"))
            .build()

        @Assert(ruleSet.rules[0].factSpace, "default")
        @Expect(ruleSet.registry.has("default"), true)
    }

    /** 表达式模式与冲突消解器被原样保存。 */
    @TestCase
    public func storesExpressionModeAndResolver(): Unit {
        let resolver = IdentityResolver()
        let ruleSet = RuleSetBuilder("pricing")
            .registerFact(builderOrderSchema())
            .rule(orderRule("R1"))
            .expressionMode(ExpressionMode.Interpreted)
            .conflictResolver(resolver)
            .build()

        @Expect(ruleSet.expressionMode, ExpressionMode.Interpreted)
        match ((ruleSet.conflictResolver as Object, resolver as Object)) {
            case (Some(stored), Some(expected)) => @Expect(refEq(stored, expected), true)
            case _ => @Expect("resolver cast", "Some")
        }
    }

    /** 重复规则 id 在装配期抛 `DUPLICATE_RULE`。 */
    @TestCase
    public func duplicateRuleIdRejected(): Unit {
        @Expect(duplicateCode(), RuleErrorCode.DUPLICATE_RULE)
    }

    private func duplicateCode(): RuleErrorCode {
        try {
            let _ = RuleSetBuilder("pricing")
                .registerFact(builderOrderSchema())
                .rule(orderRule("R1"))
                .rule(orderRule("R1"))
                .build()
        } catch (e: RuleException) {
            return e.code
        }
        RuleErrorCode.CLOSED
    }
}

/** 测试用恒等冲突消解器。 */
public class IdentityResolver <: ConflictResolver {
    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        let _ = left
        let _ = right
        Ordering.EQ
    }
}
