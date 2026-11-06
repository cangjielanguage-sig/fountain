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
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.{DefaultConflictResolver, Rule}

/** 可切换失败行为的执行器：第 N 次执行抛异常，或执行中重入 `fire`。 */
class FailingRunner <: ActionRunner {
    public var agenda: ?Agenda = None
    public var failAt: Int64 = -1
    public var reentrant: Bool = false
    public var count: Int64 = 0

    FailingRunner() {}

    public func run(activation: Activation): HashMap<String, Any> {
        count += 1
        if (reentrant) {
            match (agenda) {
                case Some(target) => let _ = target.fire()
                case None => ()
            }
        }
        if (count == failAt) {
            throw Exception("boom")
        }
        let outputs = HashMap<String, Any>()
        outputs[activation.ruleId] = count
        outputs
    }
}

/**
 * 异常语义（`doc/05-agenda-conflict-resolution.md` §6、§8，A-09/A-10）。
 *
 * 覆盖：重入抛 `REENTRANT_FIRE`、动作异常包装为 `ACTION_FAILED` 且保留 `caused`、
 * 已执行动作不回滚。
 */
@Test
class FireError_test {
    private func activation(id: String, factId: Int64): Activation {
        let fact = DynamicFact("Order")
        fact.set("amount", factId)
        let handles = HashMap<String, FactHandle>()
        let facts = HashMap<String, Fact>()
        handles["o"] = FactHandle("orders", factId, "Order")
        facts["o"] = fact
        let rule = Rule.builder(id)
            .facts("orders")
            .addPattern(Pattern("Order", "o"))
            .build()
        Activation(rule, Bindings.of(handles, facts))
    }

    /** A-09：动作内部重入 `fire` 抛 `REENTRANT_FIRE`，外层终止。 */
    @TestCase
    public func reentrantFireIsRejected(): Unit {
        let runner = FailingRunner()
        let target = Agenda(DefaultConflictResolver(), runner: runner)
        runner.agenda = Some(target)
        runner.reentrant = true
        target.add(activation("R1", 1))

        var code = RuleErrorCode.CLOSED
        try {
            let _ = target.fire()
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.REENTRANT_FIRE)
        // 外层 fire 结束后重入保护必须复位
        runner.reentrant = false
        runner.count = 0
        let fresh = Agenda(DefaultConflictResolver(), runner: runner)
        fresh.add(activation("R2", 2))
        @Assert(fresh.fire(), 1)
    }

    /** A-10：动作异常包装为 `ACTION_FAILED`，`caused` 保留原异常。 */
    @TestCase
    public func actionFailureKeepsCause(): Unit {
        let runner = FailingRunner()
        runner.failAt = 2
        let target = Agenda(DefaultConflictResolver(), runner: runner)
        target.add(activation("R1", 1))
        target.add(activation("R2", 2))

        var code = RuleErrorCode.CLOSED
        var cause = ""
        try {
            let _ = target.fire()
        } catch (e: RuleException) {
            code = e.code
            match (e.causedBy) {
                case Some(original) => cause = original.message
                case None => ()
            }
        }
        @Expect(code, RuleErrorCode.ACTION_FAILED)
        @Assert(cause, "boom")
    }

    /** A-10：已执行的动作不回滚，`lastFired` 保留前两条记录。 */
    @TestCase
    public func executedActionsAreNotRolledBack(): Unit {
        let runner = FailingRunner()
        runner.failAt = 3
        let target = Agenda(DefaultConflictResolver(), runner: runner)
        target.add(activation("R1", 1))
        target.add(activation("R2", 2))
        target.add(activation("R3", 3))

        try {
            let _ = target.fire()
        } catch (e: RuleException) {
            let _ = e
        }
        let fired = target.lastFired()
        @Assert(fired.size, 2)
        @Assert(fired[0].ruleId, "R1")
        @Assert(fired[1].ruleId, "R2")
    }
}
