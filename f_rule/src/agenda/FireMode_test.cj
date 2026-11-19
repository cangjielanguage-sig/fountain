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
 * 执行模式（`doc/05-agenda-conflict-resolution.md` §5，A-05~A-07）。
 *
 * 动作里重新入队同一个激活，模拟"条件在执行后仍成立、网络重新产生激活"。
 */
@Test
class FireMode_test {
    private func order(amount: Int64): Fact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func activation(id: String): Activation {
        let handles = HashMap<String, FactHandle>()
        let facts = HashMap<String, Fact>()
        handles["o"] = FactHandle("orders", 1, "Order")
        facts["o"] = order(300)
        let rule = Rule.builder(id)
            .facts("orders")
            .addPattern(Pattern("Order", "o"))
            .build()
        Activation(rule, Bindings.of(handles, facts))
    }

    /** A-05：Refract 模式下同一激活执行后失效，再次 `fire` 不重复执行。 */
    @TestCase
    public func refractFiresEachActivationOnce(): Unit {
        let runner = RecordingRunner()
        let target = Agenda(DefaultConflictResolver(), mode: FireMode.Refract, runner: runner)
        target.add(activation("R1"))

        @Assert(target.fire(), 1)
        @Assert(target.fire(), 0)
        @Assert(runner.order().size, 1)
    }

    /** A-06：NoLoop 在同一 `fire` 内不重复执行同一绑定，跨 `fire` 可再执行。 */
    @TestCase
    public func noLoopDeduplicatesWithinOneFireAndResetsAfter(): Unit {
        let raiser = RequeueRunner()
        let target = Agenda(DefaultConflictResolver(), mode: FireMode.NoLoop, runner: raiser)
        let item = activation("R1")
        raiser.target = Some(target)
        target.add(item)

        @Assert(target.fire(), 1)
        @Assert(raiser.count, 1)

        // 已执行集合在 fire 结束清空：重新入队后可再次执行
        raiser.enabled = false
        target.add(item)
        @Assert(target.fire(), 1)
        @Assert(raiser.count, 2)
    }

    /** A-07：Loop + limit 执行次数等于 limit，不抛死循环。 */
    @TestCase
    public func loopStopsAtLimit(): Unit {
        let raiser = RequeueRunner()
        let target = Agenda(DefaultConflictResolver(), mode: FireMode.Loop, runner: raiser)
        let item = activation("R1")
        raiser.target = Some(target)
        target.add(item)

        @Assert(target.fire(limit: 5), 5)
        @Assert(raiser.count, 5)
    }
}

/** 每次执行后把同一激活重新入队的执行器。 */
class RequeueRunner <: ActionRunner {
    public var target: ?Agenda = None
    public var enabled: Bool = true
    public var count: Int64 = 0

    RequeueRunner() {}

    public func run(activation: Activation): HashMap<String, Any> {
        count += 1
        if (enabled) {
            match (target) {
                case Some(agenda) => agenda.add(activation)
                case None => ()
            }
        }
        HashMap<String, Any>()
    }
}
