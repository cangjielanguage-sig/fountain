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
package fountain::f_rule.rule

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.*
import fountain::f_rule.exception.*

/**
 * `RuleBuilder` 的装配契约（`doc/08-api.md` §4）。
 *
 * 注意公开 API 的两处改名（仓颉关键字）：文档的 `when` → [RuleBuilder.addPattern]，
 * `where` → [RuleBuilder.script]。
 */
@Test
class RuleBuilder_test {
    private func codeOf(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    /** 缺省值：salience=0、空间 default（隐式）、无模式。 */
    @TestCase
    public func defaultsAreStable(): Unit {
        let builder = Rule.builder("R1")
        var caught = RuleErrorCode.CLOSED
        try {
            let _ = builder.build()
        } catch (e: RuleException) {
            caught = e.code
        }
        @Expect(caught, RuleErrorCode.EMPTY_PATTERN)
    }

    /** 全部装配方法都能落到模型上。 */
    @TestCase
    public func assemblesAllParts(): Unit {
        let fired = ArrayList<Int64>()
        let rule = Rule.builder("R1")
            .salience(100)
            .facts("orders")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
            .join(JoinConstraint("o", "amount", Operator.Gt, "u", "amount"))
            .script("o.amount > 200")
            .then({ _ => fired.add(1) })
            .build()

        @Assert(rule.id, "R1")
        @Assert(rule.salience, 100)
        @Assert(rule.factSpace, "orders")
        @Expect(rule.explicitSpace, true)
        @Assert(rule.patterns.size, 1)
        @Assert(rule.joins.size, 1)
        @Assert(rule.scripts.size, 1)
        @Assert(rule.scripts[0], "o.amount > 200")
        @Assert(rule.actions.size, 1)
    }

    /** 未调用 `facts` 时归入 default，且标记为隐式空间。 */
    @TestCase
    public func implicitSpaceIsDefault(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern.any("Order", "o"))
            .build()
        @Assert(rule.factSpace, "default")
        @Expect(rule.explicitSpace, false)
    }

    /** 无模式规则抛 `EMPTY_PATTERN`。 */
    @TestCase
    public func emptyPatternRejected(): Unit {
        @Expect(codeOf({ => let _ = Rule.builder("R1").build() }), RuleErrorCode.EMPTY_PATTERN)
    }

    /** 绑定名重复抛 `ILLEGAL_STATE`。 */
    @TestCase
    public func duplicateBindingRejected(): Unit {
        @Expect(duplicateBindingCode(), RuleErrorCode.ILLEGAL_STATE)
    }

    private func duplicateBindingCode(): RuleErrorCode {
        try {
            let _ = Rule.builder("R1")
                .addPattern(Pattern("Order", "o"))
                .addPattern(Pattern("Order", "o"))
                .build()
        } catch (e: RuleException) {
            return e.code
        }
        RuleErrorCode.CLOSED
    }
}

/** RuleBuilder 测试宿主类。 */
public class RuleOrder {
    public var id: String
    public var amount: Int64

    public init(id: String, amount: Int64) {
        this.id = id
        this.amount = amount
    }
}
