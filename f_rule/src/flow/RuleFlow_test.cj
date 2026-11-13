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
package fountain::f_rule.flow

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_egraph.base.{EventType, ImmediateFlow}
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.rule.Rule

/**
 * 一条规则一个 Flow（`doc/06-flow-orchestration.md` §2，P-01/P-02）。
 *
 * `category` 只编码 `<ruleSetId>/<ruleId>`，不编码空间；`tag` 跟随规则集版本。
 */
@Test
class RuleFlow_test {
    private func rule(): Rule {
        Rule.builder("R1")
            .facts("orders")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
            .then({ ctx => ctx.set("discount", 0.85) })
            .build()
    }

    /** category/tag/toString 命名正确。 */
    @TestCase
    public func namesFollowRuleAndVersion(): Unit {
        let built = RuleFlow.build("pricing-ruleflow", rule(), "v1", acceptableEvent: "order.created")
        @Expect(built.ruleId, "R1")
        @Expect(built.flow.toString(), "pricing-ruleflow/R1-v1")
    }

    /** 不显式给上游事件时，用规则 id 作为开始事件。 */
    @TestCase
    public func defaultsStartToRuleId(): Unit {
        let built = RuleFlow.build("pricing-ruleflow-default", rule(), "v1")
        let end = built.flow.start("ignored").get().get()
        @Expect(end.eventType, EventType.End)
    }

    /** 父流程嵌入子流程：建立依赖，旧 tag 的移除保护依赖于此（P-02 的接线部分）。 */
    @TestCase
    public func parentCanEmbedRuleFlow(): Unit {
        let sub = RuleFlow.build("embed-sub", rule(), "v1", acceptableEvent: "go")
        let parent = ImmediateFlow(category: "embed-parent", tag: "v1")
        parent.registerStart("go")
        parent.registerTaskByImmediateFlow(eventName: "go", subCategory: "embed-sub/R1", subTag: "v1")
        @Expect(sub.flow.dependencied.contains(parent.toString()), true)
        sub.flow.dependencied.clear()
        parent.remove()
    }

    /** 可独立启动，结束事件保留信封 session。 */
    @TestCase
    public func startsIndependentlyAndKeepsEnvelope(): Unit {
        let built = RuleFlow.build("pricing-ruleflow-start", rule(), "v1", acceptableEvent: "order.created")
        let envelope = RuleEnvelope(session: "s1", ruleSetId: "pricing-ruleflow-start", payload: "payload")
        let end = built.flow.start(envelope).get().get()
        @Expect(end.eventType, EventType.End)
        let returned = RuleEnvelope.from(end)
        @Expect(returned.session, "s1")
        @Expect(returned.unwrap() as String, "payload")
    }
}
