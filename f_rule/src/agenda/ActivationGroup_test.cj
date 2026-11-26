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
package fountain::f_rule.agenda

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.Pattern
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.{DefaultConflictResolver, Rule}

/**
 * 激活组（`doc/11-assembly.md` §4.4，用例 AS-13/AS-14）。
 *
 * 同组激活只执行 salience 最高的一个，执行后其余同组激活失效；组是议程的通用能力，
 * 与决策表无耦合。`activationGroup` 不参与激活相等键——组只影响调度，不影响身份。
 */
@Test
class ActivationGroup_test {
    private func order(amount: Int64): Fact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func bindingsOf(id: Int64): Bindings {
        let handles = HashMap<String, FactHandle>()
        let facts = HashMap<String, Fact>()
        handles["o"] = FactHandle("orders", id, "Order")
        facts["o"] = order(300)
        Bindings.of(handles, facts)
    }

    private func rule(id: String, salience: Int64, group!: ?String = None): Rule {
        let builder = Rule.builder(id)
            .salience(salience)
            .facts("orders")
            .addPattern(Pattern("Order", "o"))
        match (group) {
            case Some(name) => builder.activationGroup(name)
            case None => ()
        }
        builder.build()
    }

    private func agenda(runner: ActionRunner): Agenda {
        Agenda(DefaultConflictResolver(), runner: runner)
    }

    /** AS-13：同组两条激活只执行 salience 高的那条，其余同组激活随首个执行失效。 */
    @TestCase
    public func sameGroupExecutesOnlyHighestSalience(): Unit {
        let runner = RecordingRunner()
        let target = agenda(runner)
        target.add(Activation(rule("R1", 10, group: Some("pricing")), bindingsOf(1)))
        target.add(Activation(rule("R2", 5, group: Some("pricing")), bindingsOf(2)))

        @Assert(target.fire(), 1)
        @Assert(runner.order(), ["R1"])
        @Assert(target.size(), 0)
    }

    /** 不同组互不影响，各自执行最高的一条。 */
    @TestCase
    public func differentGroupsDoNotInterfere(): Unit {
        let runner = RecordingRunner()
        let target = agenda(runner)
        target.add(Activation(rule("R1", 10, group: Some("g1")), bindingsOf(1)))
        target.add(Activation(rule("R2", 5, group: Some("g1")), bindingsOf(2)))
        target.add(Activation(rule("R3", 7, group: Some("g2")), bindingsOf(3)))
        target.add(Activation(rule("R4", 1, group: Some("g2")), bindingsOf(4)))

        @Assert(target.fire(), 2)
        @Assert(runner.order(), ["R1", "R3"])
        @Assert(target.size(), 0)
    }

    /** AS-14：不设组的规则执行数与改动前一致（全部执行）。 */
    @TestCase
    public func ungroupedRulesKeepExistingBehavior(): Unit {
        let runner = RecordingRunner()
        let target = agenda(runner)
        target.add(Activation(rule("R1", 10), bindingsOf(1)))
        target.add(Activation(rule("R2", 5), bindingsOf(2)))
        target.add(Activation(rule("R3", 0), bindingsOf(3)))

        @Assert(target.fire(), 3)
        @Assert(runner.order(), ["R1", "R2", "R3"])
    }

    /** 组名不参与相等键：同空间、同规则 id、同绑定仍是同一激活。 */
    @TestCase
    public func activationGroupIsNotPartOfEquality(): Unit {
        let shared = bindingsOf(1)
        let left = Activation(rule("R1", 10, group: Some("g1")), shared)
        let right = Activation(rule("R1", 10, group: Some("g2")), shared)

        @Expect(left == right, true)
        @Assert(left.activationGroup.getOrThrow(), "g1")
        @Assert(right.activationGroup.getOrThrow(), "g2")
        @Expect(Activation(rule("R1", 10), shared).activationGroup.isNone(), true)
    }
}
