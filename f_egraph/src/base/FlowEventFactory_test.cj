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

/** `FlowEventFactory`：脚本面的事件出口，载荷收敛为 `String`（`design.md` §7.2）。 */
@Test
class FlowEventFactory_test {
    /** `flowTaskEvent` 产出带载荷的任务事件。 */
    @TestCase
    public func flowTaskEventBuildsTaskEvent(): Unit {
        let event = FlowEventFactory.flowTaskEvent("order", "v1", "validated", "payload")
        @Assert(event.eventType, EventType.Task)
        @Assert(event.category, "order")
        @Assert(event.tag, "v1")
        @Assert(event.name, "validated")
        @Assert(FlowEventFactory.flowDataOf(event), "payload")
    }

    /** `flowEndEvent` 产出结束事件。 */
    @TestCase
    public func flowEndEventBuildsEndEvent(): Unit {
        let event = FlowEventFactory.flowEndEvent("order", "v1", "done")
        @Assert(event.eventType, EventType.End)
        @Assert(event.category, "order")
        @Assert(event.tag, "v1")
        @Assert(event.name, EventType.End.toString())
        @Assert(FlowEventFactory.flowDataOf(event), "done")
    }

    /** `flowErrorEvent` 产出错误事件，载荷是错误消息。 */
    @TestCase
    public func flowErrorEventBuildsErrorEvent(): Unit {
        let event = FlowEventFactory.flowErrorEvent("order", "v1", "boom")
        @Assert(event.eventType, EventType.Error)
        @Assert(event.name, EventType.Error.toString())
        @Assert(FlowEventFactory.flowDataOf(event), "boom")
    }

    /** `flowDummyEvent` 返回 `DummyEvent` 单例。 */
    @TestCase
    public func flowDummyEventReturnsSingleton(): Unit {
        let event = FlowEventFactory.flowDummyEvent()
        @Assert(event.eventType, EventType.Dummy)
        @Assert(event is DummyEvent, true)
    }

    /** `flowDataOf`：非 `String` 载荷返回空串。 */
    @TestCase
    public func flowDataOfRejectsNonStringPayload(): Unit {
        let event = TaskEvent(category: "order", tag: "v1", name: "n", data: 42)
        @Assert(FlowEventFactory.flowDataOf(event), "")
    }

    /** `flowDataOf`：非 `DataEvent` 返回空串。 */
    @TestCase
    public func flowDataOfRejectsNonDataEvent(): Unit {
        let event: Event = Event(eventType: EventType.Task, category: "order", tag: "v1", name: "n")
        @Assert(FlowEventFactory.flowDataOf(event), "")
    }
}
