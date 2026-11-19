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
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.{Rule, RuleSet, RuleSetBuilder}

/** 两个空间的规则集：`orders` 与 `users` 各一条。 */
func sessionRuleSet(): RuleSet {
    let orderRule = Rule.builder("orders/R1")
        .salience(100)
        .facts("orders")
        .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
        .then({ ctx => ctx.set("discount", 0.85) })
        .build()
    let userRule = Rule.builder("users/R1")
        .salience(10)
        .facts("users")
        .addPattern(Pattern("User", "u").constrain("level", Operator.Eq, "vip"))
        .then({ ctx => ctx.set("level", "vip") })
        .build()
    RuleSetBuilder("session")
        .version("v1")
        .factSpace("orders")
        .factSpace("users")
        .registerDynamicType("orders", "Order", ["amount"])
        .registerDynamicType("users", "User", ["level"])
        .rule(orderRule)
        .rule(userRule)
        .build()
}

/** 动作里要用到断言后才产生的句柄：先建空盒子，动作执行时再读。 */
class HandleBox {
    public var handle: ?FactHandle = None
}

/**
 * 会话执行（`doc/08-api.md` §8、§10，`doc/10-roadmap.md` M3）。
 *
 * 覆盖：`fire` 输出合并、`fireDetailed` 行级结果、跨空间统一议程、
 * 撤销后激活失效、未声明空间报错。
 */
@Test
class RuleSession_test {
    private func order(amount: Int64): Fact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func user(level: String): Fact {
        let fact = DynamicFact("User")
        fact.set("level", level)
        fact
    }

    /** 命中规则后 `fire` 返回合并输出。 */
    @TestCase
    public func fireReturnsMergedOutputs(): Unit {
        let engine = RuleEngine(sessionRuleSet())
        let session = engine.session("s1")
        let _ = session.assert("orders", order(500))

        let outputs = session.fire()
        @Assert(outputs.size, 1)
        @Assert(outputs.get("discount").getOrThrow() as Float64, 0.85)
    }

    /** `fireDetailed` 给出逐条执行结果与输出。 */
    @TestCase
    public func fireDetailedReportsEachFiredRule(): Unit {
        let engine = RuleEngine(sessionRuleSet())
        let session = engine.session("s1")
        let _ = session.assert("orders", order(500))
        let _ = session.assert("users", user("vip"))

        let result = session.fireDetailed()
        @Assert(result.fired.size, 2)
        @Assert(result.fired[0].ruleId, "orders/R1")
        @Assert(result.fired[1].ruleId, "users/R1")
        @Assert(result.outputs.get("discount").getOrThrow() as Float64, 0.85)
        @Assert(result.outputs.get("level").getOrThrow() as String, "vip")

        // 之后的 `fire` 没有激活，输出为空
        let again = session.fire()
        @Assert(again.size, 0)
    }

    /** 撤销事实后对应激活失效，`fire` 不执行它。 */
    @TestCase
    public func retractInvalidatesPendingActivation(): Unit {
        let engine = RuleEngine(sessionRuleSet())
        let session = engine.session("s1")
        let handle = session.assert("orders", order(500))
        session.retract(handle)

        @Assert(session.fire().size, 0)
    }

    /** `assert` / `update` 走事实库并影响匹配。 */
    @TestCase
    public func updateReplacesFactAndRefires(): Unit {
        let engine = RuleEngine(sessionRuleSet())
        let session = engine.session("s1")
        let handle = session.assert("orders", order(100))
        @Assert(session.fire().size, 0)

        session.update(handle, order(900))
        @Assert(session.fireDetailed().fired.size, 1)
    }

    /** 未声明空间抛 `UNKNOWN_FACT_SPACE`。 */
    @TestCase
    public func undeclaredSpaceIsRejected(): Unit {
        let engine = RuleEngine(sessionRuleSet())
        let session = engine.session("s1")
        var code = RuleErrorCode.CLOSED
        try {
            let _ = session.factsOf("missing")
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.UNKNOWN_FACT_SPACE)
    }

    /** 缺省空间是 `default`，`assert(fact)` 写到这里。 */
    @TestCase
    public func defaultSpaceStoresBareAssert(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("GenFact", "g"))
            .then({ ctx => ctx.set("hit", true) })
            .build()
        let ruleSet = RuleSetBuilder("default-space")
            .registerDynamicType("default", "GenFact", ["amount"])
            .rule(rule)
            .build()
        let session = RuleEngine(ruleSet).session("s1")

        let fact = DynamicFact("GenFact")
        fact.set("amount", 1)
        let _ = session.assert(fact)
        @Assert(session.facts.size(), 1)
        @Assert(session.fireDetailed().fired.size, 1)
    }

    /** A-08：高优先级动作撤销了另一条激活依赖的事实，该激活被惰性堆跳过。 */
    @TestCase
    public func actionRetractInvalidatesOtherActivation(): Unit {
        let box = HandleBox()
        let cancelling = Rule.builder("cancel")
            .salience(100)
            .facts("orders")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 400))
            .then({ ctx =>
                match (box.handle) {
                    case Some(handle) => ctx.retract(handle)
                    case None => ()
                }
            })
            .build()
        let victim = Rule.builder("victim")
            .salience(0)
            .facts("orders")
            .addPattern(Pattern("Order", "v").constrain("amount", Operator.Lt, 400))
            .then({ ctx => ctx.set("victim", true) })
            .build()
        let ruleSet = RuleSetBuilder("a08")
            .factSpace("orders")
            .registerDynamicType("orders", "Order", ["amount"])
            .rule(cancelling)
            .rule(victim)
            .build()
        let session = RuleEngine(ruleSet).session("s1")
        let _ = session.assert("orders", order(500))
        box.handle = Some(session.assert("orders", order(100)))

        let result = session.fireDetailed()
        @Assert(result.fired.size, 1)
        @Assert(result.fired[0].ruleId, "cancel")
        @Expect(result.outputs.get("victim").isNone(), true)
        // 触发规则的事实仍在，被撤销的是另一条激活依赖的事实
        @Assert(session.factsOf("orders").size(), 1)
    }
}
