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

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.Pattern
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.{DefaultConflictResolver, Rule}

/** 记录执行顺序的动作执行器。 */
class RecordingRunner <: ActionRunner {
    private let executed: ArrayList<String>

    RecordingRunner() {
        this.executed = ArrayList<String>()
    }

    public func run(activation: Activation): HashMap<String, Any> {
        executed.add(activation.ruleId)
        HashMap<String, Any>()
    }

    public func order(): Array<String> {
        executed.toArray()
    }
}

/**
 * 议程（`doc/05-agenda-conflict-resolution.md` §3）。
 *
 * 覆盖：入队去重、惰性堆跳过失效激活、`fire` 返回值、空议程、`snapshot` 顺序（A-08/A-09 前提）。
 */
@Test
class Agenda_test {
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

    private func rule(id: String, salience: Int64): Rule {
        Rule.builder(id)
            .salience(salience)
            .facts("orders")
            .addPattern(Pattern("Order", "o"))
            .build()
    }

    private func activation(id: String, salience: Int64, factId: Int64): Activation {
        Activation(rule(id, salience), bindingsOf(factId))
    }

    private func agenda(runner: ActionRunner): Agenda {
        Agenda(DefaultConflictResolver(), runner: runner)
    }

    /** 同一激活重复入队只保留一个。 */
    @TestCase
    public func addDeduplicatesSameActivation(): Unit {
        let target = agenda(RecordingRunner())
        let item = activation("R1", 0, 1)
        target.add(item)
        target.add(item)

        @Assert(target.size(), 1)
        @Assert(target.snapshot().size, 1)
    }

    /** 失效激活被跳过，且不计入 fire 返回值。 */
    @TestCase
    public func fireSkipsInvalidActivation(): Unit {
        let runner = RecordingRunner()
        let target = agenda(runner)
        let first = activation("R1", 100, 1)
        let second = activation("R2", 0, 2)
        target.add(first)
        target.add(second)
        target.remove(first)

        @Assert(target.fire(), 1)
        let order = runner.order()
        @Assert(order.size, 1)
        @Assert(order[0], "R2")
        @Assert(target.size(), 0)
    }

    /** `fire` 返回执行的激活数。 */
    @TestCase
    public func fireReturnsExecutedCount(): Unit {
        let runner = RecordingRunner()
        let target = agenda(runner)
        target.add(activation("R1", 100, 1))
        target.add(activation("R2", 0, 2))

        @Assert(target.fire(), 2)
        @Assert(runner.order().size, 2)
        @Assert(target.size(), 0)
    }

    /** 空议程返回 0，不抛错。 */
    @TestCase
    public func emptyAgendaFiresZero(): Unit {
        let target = agenda(RecordingRunner())
        @Assert(target.fire(), 0)
    }

    /** `snapshot` 按冲突消解顺序给出待执行激活，不改变队列。 */
    @TestCase
    public func snapshotFollowsPriorityOrder(): Unit {
        let target = agenda(RecordingRunner())
        target.add(activation("low", 0, 1))
        target.add(activation("high", 100, 2))
        target.add(activation("mid", 50, 3))

        let items = target.snapshot()
        @Assert(items.size, 3)
        @Assert(items[0].ruleId, "high")
        @Assert(items[1].ruleId, "mid")
        @Assert(items[2].ruleId, "low")
        @Assert(target.size(), 3)
    }

    /** `clear` 清空队列与去重索引。 */
    @TestCase
    public func clearDropsEverything(): Unit {
        let target = agenda(RecordingRunner())
        target.add(activation("R1", 0, 1))
        target.clear()

        @Assert(target.size(), 0)
        @Assert(target.fire(), 0)
    }
}
