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
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, Fact}
import fountain::f_rule.rule.{Rule, RuleSet}

/** 构建订单规则集：一条匹配 `amount > 200` 的规则。 */
func engineRuleSet(): RuleSet {
    let rule = Rule.builder("R1")
        .salience(100)
        .facts("orders")
        .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
        .then({ ctx => ctx.set("discount", 0.85) })
        .build()
    RuleSetBuilder("engine")
        .version("v1")
        .factSpace("orders")
        .registerDynamicType("orders", "Order", ["amount"])
        .rule(rule)
        .build()
}

func engineFact(amount: Int64): Fact {
    let fact = DynamicFact("Order")
    fact.set("amount", amount)
    fact
}

/**
 * 引擎生命周期（`doc/08-api.md` §8、`doc/10-roadmap.md` M3）。
 *
 * 覆盖：`session(id)` 复用、`release` 释放、关闭后拒绝执行、Invalid 规则集不可建引擎。
 */
@Test
class RuleEngine_test {
    /** 同一 id 返回同一会话，事实视图共享。 */
    @TestCase
    public func sessionIsReusedById(): Unit {
        let engine = RuleEngine(engineRuleSet())
        let first = engine.session("s1")
        let second = engine.session("s1")

        var same = false
        match ((first as Object, second as Object)) {
            case (Some(a), Some(b)) => same = refEq(a, b)
            case _ => ()
        }
        @Expect(same, true)

        let _ = first.assert("orders", engineFact(300))
        @Assert(second.factsOf("orders").size(), 1)
    }

    /** `release` 释放会话；同 id 再取是新会话，事实为空。 */
    @TestCase
    public func releaseDropsSessionState(): Unit {
        let engine = RuleEngine(engineRuleSet())
        let session = engine.session("s1")
        let _ = session.assert("orders", engineFact(300))

        @Expect(engine.release("s1"), true)
        @Expect(engine.release("s1"), false)

        let fresh = engine.session("s1")
        @Assert(fresh.factsOf("orders").size(), 0)
    }

    /** 关闭后 `session` 与 `fire` 都拒绝执行。 */
    @TestCase
    public func closeRejectsFurtherUse(): Unit {
        let engine = RuleEngine(engineRuleSet())
        let session = engine.session("s1")
        let _ = session.assert("orders", engineFact(300))
        engine.close()

        var fireCode = RuleErrorCode.ILLEGAL_STATE
        try {
            let _ = session.fire()
        } catch (e: RuleException) {
            fireCode = e.code
        }
        @Expect(fireCode, RuleErrorCode.CLOSED)

        var sessionCode = RuleErrorCode.ILLEGAL_STATE
        try {
            let _ = engine.session("s2")
        } catch (e: RuleException) {
            sessionCode = e.code
        }
        @Expect(sessionCode, RuleErrorCode.CLOSED)
    }

    /** 校验失败的规则集不能构造引擎。 */
    @TestCase
    public func invalidRuleSetCannotBuildEngine(): Unit {
        let ruleSet = RuleSetBuilder("bad")
            .factSpace("orders")
            .registerDynamicType("orders", "Order", ["amount"])
            .rule(Rule.builder("R1")
                .facts("orders")
                .addPattern(Pattern("Order", "o").constrain("missing", Operator.Eq, 1))
                .build())
            .buildOrInvalid()
        @Expect(ruleSet.isValid(), false)

        var code = RuleErrorCode.CLOSED
        try {
            let _ = RuleEngine(ruleSet)
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.ILLEGAL_STATE)
    }
}
