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

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_egraph.base.{DataEvent, DummyEvent, EndEvent, Event, EventType, ImmediateFlow, MultiEvent, TaskEvent}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, FactBase, FieldType, FactSpace}

/** 闭包不能捕获可变局部变量，用可变对象承载计数。 */
class FlowCounter {
    public var value: Int64 = 0
}

/**
 * `ResolveTask` 的一对多扇出（`doc/06-flow-orchestration.md` §3，P-03/P-04/P-12）。
 *
 * 子事件载荷一律是 [RuleEnvelope]，session 取父事件信封，不靠 `Event.session`。
 */
@Test
class ResolveTask_test {
    private func parent(): TaskEvent {
        TaskEvent(category: "fanout", tag: "v1", name: "in",
            data: RuleEnvelope(session: "s1", ruleSetId: "pricing", payload: "raw", traceId: "t1"),
            session: "event-session")
    }

    private func children(result: Event): ArrayList<Event> {
        let out = ArrayList<Event>()
        if (let multi: MultiEvent <- result) {
            if (let events: Iterable<Event> <- multi.data) {
                for (event in events) {
                    out.add(event)
                }
            }
        }
        out
    }

    /** 返回 MultiEvent，名字必须是 `EventType.Multi.toString()`。 */
    @TestCase
    public func returnsMultiEvent(): Unit {
        let task = ResolveTask(name: "split", acceptable: ["in"], producing: ["a", "b"], plan: { _ => [("a", 1), ("b", 2)] })
        let result = task.exec(parent())
        @Expect(result.name, EventType.Multi.toString())
        @Expect(result.eventType, EventType.Multi)
        @Expect(children(result).size, 2)
    }

    /** 子事件载荷是信封，session 与父一致（即使 Event.session 被随机化）。 */
    @TestCase
    public func childrenCarryParentEnvelope(): Unit {
        let task = ResolveTask(name: "split", acceptable: ["in"], producing: ["a", "b"], plan: { _ => [("a", 1), ("b", 2)] })
        let result = task.exec(parent())
        for (event in children(result)) {
            let envelope = RuleEnvelope.from(event)
            @Expect(envelope.session, "s1")
            @Expect(envelope.ruleSetId, "pricing")
            @Expect(envelope.traceId, "t1")
            @Expect(event.session, "s1")
        }
    }

    /** plan 返回空列表抛 `EMPTY_FANOUT`。 */
    @TestCase
    public func emptyPlanIsRejected(): Unit {
        let task = ResolveTask(name: "split", acceptable: ["in"], producing: ["a"], plan: { _ => Array<(String, Any)>() })
        var caught = RuleErrorCode.CLOSED
        try {
            let _ = task.exec(parent())
        } catch (e: RuleException) {
            caught = e.code
        }
        @Expect(caught, RuleErrorCode.EMPTY_FANOUT)
    }

    /** plan 抛异常包装为 `ACTION_FAILED`，原因链保留。 */
    @TestCase
    public func planFailureIsWrapped(): Unit {
        let cause = Exception("boom")
        let task = ResolveTask(name: "split", acceptable: ["in"], producing: ["a"], plan: { _ => throw cause })
        var caught = RuleErrorCode.CLOSED
        var caused: ?Exception = None
        try {
            let _ = task.exec(parent())
        } catch (e: RuleException) {
            caught = e.code
            caused = e.causedBy
        }
        @Expect(caught, RuleErrorCode.ACTION_FAILED)
        @Expect(caused.isSome(), true)
    }

    /**
     * 扇出后两个分支改同一空间事实：执行顺序由队列决定，且重复运行结果一致（P-15）。
     *
     * 这也是 `RuleSetFlow` 拒绝同空间扇出的原因——这里用裸 `ResolveTask` 显式锁定
     * "顺序可复现"仅对固定队列顺序成立，不代表业务上可以依赖。
     */
    @TestCase
    public func sameSpaceBranchesFollowQueueOrder(): Unit {
        let first = runSameSpaceFanout("fanout-order-first")
        let second = runSameSpaceFanout("fanout-order-second")
        @Expect(first.size, 2)
        @Expect(first[0], "a")
        @Expect(first[1], "b")
        @Expect(second.size, 2)
        @Expect(second[0], "a")
        @Expect(second[1], "b")
    }

    private func writeTask(category: String, base: FactBase, name: String): (Event) -> Event {
        { e =>
            let fact = DynamicFact("Marker")
            fact.set("name", name)
            let _ = base.assert(fact)
            TaskEvent(category: category, tag: "v1", name: "done", data: name)
        }
    }

    private func runSameSpaceFanout(category: String): Array<String> {
        let space = FactSpace("same-space-${category}")
        let _ = space.registerDynamic("Marker", [("name", FieldType.Text)])
        let base = FactBase(space, "s1")
        let flow = ImmediateFlow(category: category, tag: "v1")
        flow.registerStart("go")
        flow.registerTask(ResolveTask(
            name: "split", acceptable: ["go"], producing: ["a", "b"],
            plan: { _ => [("a", "a"), ("b", "b")] }
        ))
        flow.registerTask("a", writeTask(category, base, "a"))
        flow.registerTask("b", writeTask(category, base, "b"))
        let arrived = FlowCounter()
        flow.registerTask("done") { e =>
            arrived.value += 1
            if (arrived.value == 2) {
                EndEvent(category: category, tag: "v1", data: "done")
            } else {
                DummyEvent.instance
            }
        }
        flow.registerEnd()
        let _ = flow.start("go").get().get()

        let names = ArrayList<String>()
        for (handle in base.scan("Marker")) {
            match (base.get(handle)) {
                case Some(fact) => names.add((fact.get("name").getOrThrow() as String).getOrThrow())
                case None => ()
            }
        }
        names.toArray()
    }

    /** 真实 Flow 中两路/三路扇出都到达下游执行器（P-03/P-04）。 */
    @TestCase
    public func allBranchesReachDownstream(): Unit {
        let category = "resolve-flow-branches"
        let flow = ImmediateFlow(category: category, tag: "v1")
        flow.registerStart("in")
        let hits = HashMap<String, Int64>()
        let three = ResolveTask(name: "split", acceptable: ["in"], producing: ["a", "b", "c"],
            plan: { _ => [("a", 1), ("b", 2), ("c", 3)] })
        flow.registerTask(three)
        for (name in ["a", "b", "c"]) {
            flow.registerTask(name) { e =>
                let prev = match (hits.get(name)) {
                    case Some(value) => value
                    case None => 0
                }
                hits[name] = prev + 1
                TaskEvent(category: e.category, tag: e.tag, name: "count", data: name)
            }
        }
        let arrived = FlowCounter()
        flow.registerTask("count") { e =>
            arrived.value += 1
            if (arrived.value == 3) {
                EndEvent(category: e.category, tag: e.tag, data: "done")
            } else {
                DummyEvent.instance
            }
        }
        flow.registerEnd()
        let end = flow.start("go").get().get()
        @Expect(end.eventType, EventType.End)
        @Expect(hits.get("a").getOrThrow(), 1)
        @Expect(hits.get("b").getOrThrow(), 1)
        @Expect(hits.get("c").getOrThrow(), 1)
    }
}
