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
import fountain::f_rule.rule.{Rule, RuleSetBuilder}
import fountain::f_rule.engine.RuleEngine
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * `RuleSetFlow` 编排门面（`doc/06-flow-orchestration.md` §2、§7，P-13/P-14）。
 *
 * 不同空间的规则可以扇出；同空间扇出会并发改写同一批事实，构建期直接拒绝。
 */
@Test
class SameSpaceFanout_test {
    private func rule(id: String, space: String, typeTag: String, field: String): Rule {
        Rule.builder(id)
            .facts(space)
            .addPattern(Pattern(typeTag, "o").constrain(field, Operator.Gt, 0))
            .then({ ctx => ctx.set("ok", true) })
            .build()
    }

    private func engineTwoSpaces(id: String): RuleEngine {
        let ruleSet = RuleSetBuilder(id)
            .version("v1")
            .factSpace("orders")
            .factSpace("users")
            .registerDynamicType("orders", "Order", ["amount"])
            .registerDynamicType("users", "User", ["level"])
            .rule(rule("R1", "orders", "Order", "amount"))
            .rule(rule("R3", "users", "User", "level"))
            .build()
        RuleEngine(ruleSet)
    }

    private func engineSameSpace(id: String): RuleEngine {
        let ruleSet = RuleSetBuilder(id)
            .version("v1")
            .factSpace("orders")
            .registerDynamicType("orders", "Order", ["amount"])
            .rule(rule("R1", "orders", "Order", "amount"))
            .rule(rule("R2", "orders", "Order", "amount"))
            .build()
        RuleEngine(ruleSet)
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

    /** 不同空间的两条分支可以扇出并汇合（P-13）。 */
    @TestCase
    public func differentSpacesPass(): Unit {
        let id = "rsf-different-spaces"
        let built = RuleSetFlow.build(engineTwoSpaces(id))
            .start("order.created")
            .fanout("order.created", [
                ("order.priced.check", "${id}/R1"),
                ("user.level.check", "${id}/R3")
            ])
            .join(["order.bulk.done", "user.level.done"], "order.priced")
            .end()
        @Expect(built.flow.toString(), "${id}-v1")
    }

    /** 两个分支落在同一空间 → `SAME_SPACE_FANOUT`（P-14）。 */
    @TestCase
    public func sameSpaceFanoutIsRejected(): Unit {
        let id = "rsf-same-space"
        let code = codeOf({ =>
            let _ = RuleSetFlow.build(engineSameSpace(id))
                .start("order.created")
                .fanout("order.created", [
                    ("order.a.check", "${id}/R1"),
                    ("order.b.check", "${id}/R2")
                ])
        })
        @Expect(code, RuleErrorCode.SAME_SPACE_FANOUT)
    }

    /** 扇出后不汇合直接 end → `FANOUT_WITHOUT_JOIN`（P-05 的编排入口）。 */
    @TestCase
    public func fanoutWithoutJoinIsRejectedAtEnd(): Unit {
        let id = "rsf-without-join"
        let code = codeOf({ =>
            let _ = RuleSetFlow.build(engineTwoSpaces(id))
                .start("order.created")
                .fanout("order.created", [
                    ("order.priced.check", "${id}/R1"),
                    ("user.level.check", "${id}/R3")
                ])
                .end()
        })
        @Expect(code, RuleErrorCode.FANOUT_WITHOUT_JOIN)
    }
}
