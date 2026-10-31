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
import fountain::f_egraph.base.{Event, EventType, TaskEvent}

/**
 * `JoinTask` 的多对一汇合（`doc/06-flow-orchestration.md` §4，P-06~P-09）。
 *
 * 状态按 [RuleEnvelope] 的 session 隔离；同一分支重复到达幂等；到齐后立即清态。
 */
@Test
class JoinTask_test {
    private func event(session: String, name: String): TaskEvent {
        TaskEvent(category: "join", tag: "v1", name: name,
            data: RuleEnvelope(session: session, ruleSetId: "pricing", payload: name),
            session: "event-session-${name}")
    }

    private func join(): JoinTask {
        JoinTask(name: "join", branches: ["a", "b"], output: "out")
    }

    private func isOutput(e: Event): Bool {
        e.eventType == EventType.Task && e.name == "out"
    }

    /** 收齐只发一次，随后状态清空（P-06）。 */
    @TestCase
    public func emitsOutputOnceWhenComplete(): Unit {
        let task = join()
        let first = task.exec(event("s1", "a"))
        @Expect(first.eventType, EventType.Dummy)
        @Expect(task.size(), 1)
        let second = task.exec(event("s1", "b"))
        @Expect(isOutput(second), true)
        @Expect(task.size(), 0)
        @Expect(RuleEnvelope.from(second).session, "s1")
    }

    /** 缺一路不发 output（P-07）。 */
    @TestCase
    public func holdsOutputUntilAllArrive(): Unit {
        let task = join()
        let first = task.exec(event("s1", "a"))
        @Expect(first.eventType, EventType.Dummy)
        @Expect(task.size(), 1)
    }

    /** 同一分支重复到达幂等，不推进计数（P-08）。 */
    @TestCase
    public func duplicateBranchIsIdempotent(): Unit {
        let task = join()
        @Expect(task.exec(event("s1", "a")).eventType, EventType.Dummy)
        @Expect(task.exec(event("s1", "a")).eventType, EventType.Dummy)
        @Expect(task.size(), 1)
        @Expect(isOutput(task.exec(event("s1", "b"))), true)
    }

    /** 并发两个 session 交错不串扰（P-09）。 */
    @TestCase
    public func sessionsDoNotInterfere(): Unit {
        let task = join()
        @Expect(task.exec(event("s1", "a")).eventType, EventType.Dummy)
        @Expect(task.exec(event("s2", "b")).eventType, EventType.Dummy)
        let s2 = task.exec(event("s2", "a"))
        @Expect(isOutput(s2), true)
        @Expect(RuleEnvelope.from(s2).session, "s2")
        let s1 = task.exec(event("s1", "b"))
        @Expect(isOutput(s1), true)
        @Expect(RuleEnvelope.from(s1).session, "s1")
        @Expect(task.size(), 0)
    }

    /** 到齐清态后允许同一 session 发起下一轮。 */
    @TestCase
    public func canStartNextRoundAfterCompletion(): Unit {
        let task = join()
        let _ = task.exec(event("s1", "a"))
        @Expect(isOutput(task.exec(event("s1", "b"))), true)
        @Expect(task.exec(event("s1", "a")).eventType, EventType.Dummy)
        @Expect(isOutput(task.exec(event("s1", "b"))), true)
    }

    /** 未在 branches 中的事件不污染状态。 */
    @TestCase
    public func unknownBranchIsIgnored(): Unit {
        let task = join()
        @Expect(task.exec(event("s1", "x")).eventType, EventType.Dummy)
        @Expect(task.size(), 0)
    }
}
