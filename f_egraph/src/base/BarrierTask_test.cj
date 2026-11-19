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
package fountain::f_egraph.base

import std.unittest.*
import std.unittest.testmacro.*

/** `BarrierKey` 与 `BarrierTask<G>`。 */
@Test
class BarrierTask_test {
    private static func category(prefix: String): String {
        "${prefix}-${UUID.random().toHexString()}"
    }

    /** `BarrierKey` 的字段、相等性与哈希。 */
    @TestCase
    public func barrierKeyComparesAllFields(): Unit {
        let a = BarrierKey("c", "t", "e", "s")
        let b = BarrierKey("c", "t", "e", "s")
        let c = BarrierKey("c", "t", "e", "other")
        @Assert(a.category, "c")
        @Assert(a.tag, "t")
        @Assert(a.eventName, "e")
        @Assert(a.session, "s")
        @Expect(a == b, true)
        @Assert(a.hashCode(), b.hashCode())
        @Expect(a == c, false)
    }

    /** 任务契约属性来自构造参数。 */
    @TestCase
    public func barrierTaskExposesContract(): Unit {
        let task = BarrierTask<EndExecutorGetter>(
            name: "barrier",
            events: [("created", "ready", 2), ("paid", "closed", 3)],
            producing: ["ready", "closed"])
        @Assert(task.name, "barrier")
        @Assert(task.acceptableEvents, ["created", "paid"])
        @Assert(task.producingEvents, ["ready", "closed"])
    }

    /** 达到阈值时经 `flow.emit` 发出聚合事件（阈值 1 可单事件触发）。 */
    @TestCase
    public func barrierTaskEmitsWhenThresholdReached(): Unit {
        AsyncFlow.initDispatcher()
        let c = BarrierTask_test.category("barrier-emit")
        let flow = AsyncFlow(category: c, tag: "v1")
        flow.registerStart("created")
        flow.registerEnd()
        let barrier = BarrierTask<AsyncEndExecutorGetter>(
            name: "barrier", events: [("created", "ready", 1)], producing: ["ready"])
        flow.registerTask(barrier)
        flow.registerTask("ready") { e =>
            EndEvent(category: e.category, tag: e.tag, data: "aggregated")
        }
        let end = flow.start("go").tryGet(timeout: Duration.second)
        @Expect(end.isSome(), true)
        @Assert(FlowEventFactory.flowDataOf(end.getOrThrow().get()), "aggregated")
        flow.remove()
    }

    /** 未达阈值只返回 `DummyEvent`，不发射（`flow` 未注入时 `emit` 被短路）。 */
    @TestCase
    public func barrierTaskAccumulatesBelowThreshold(): Unit {
        let task = BarrierTask<EndExecutorGetter>(
            name: "barrier", events: [("created", "ready", 2)], producing: ["ready"])
        let e = TaskEvent(category: "c", tag: "t", name: "created", data: "1", session: "s")
        @Expect(task.exec(e) == DummyEvent.instance, true)
        @Expect(task.exec(e) == DummyEvent.instance, true)
    }

    /** 非 `DataEvent` 载荷 → `GraphException`。 */
    @TestCase
    public func barrierTaskRejectsNonDataEvent(): Unit {
        let task = BarrierTask<EndExecutorGetter>(
            name: "barrier", events: [("created", "ready", 2)], producing: ["ready"])
        var message = ""
        try {
            task.exec(Event(eventType: EventType.Task, category: "c", tag: "t", name: "created"))
        } catch (e: GraphException) {
            message = e.message
        }
        @Expect(message.contains("DataEvent"), true)
    }
}
