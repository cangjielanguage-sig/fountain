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

/** 事件谱系：`Event` 与七个子类的字段、相等性与 `toString`。 */
@Test
class Event_test {
    /** 基类字段与默认 `session`。 */
    @TestCase
    public func baseEventCarriesFields(): Unit {
        let e = Event(eventType: EventType.Task, category: "c", tag: "t", name: "n")
        @Assert(e.eventType, EventType.Task)
        @Assert(e.category, "c")
        @Assert(e.tag, "t")
        @Assert(e.name, "n")
        @Expect(e.session.size > 0, true)
        @Assert(e.toString(), "Event(eventType: Task, category: c, tag: t, name: n)")
    }

    /** 相等性与哈希只由 `eventType`/`category`/`tag`/`name` 决定。 */
    @TestCase
    public func equalityIgnoresSessionAndData(): Unit {
        let a = Event(eventType: EventType.Task, category: "c", tag: "t", name: "n", session: "s1")
        let b = Event(eventType: EventType.Task, category: "c", tag: "t", name: "n", session: "s2")
        let c = Event(eventType: EventType.Task, category: "c", tag: "t", name: "other", session: "s1")
        @Expect(a == b, true)
        @Assert(a.hashCode(), b.hashCode())
        @Expect(a == c, false)
    }

    /** `DataEvent.tryGet` 命中与未命中两个分支。 */
    @TestCase
    public func dataEventTryGet(): Unit {
        let e = DataEvent(eventType: EventType.Task, category: "c", tag: "t", name: "n", data: "payload")
        @Assert(e.tryGet<String>(), Some("payload"))
        @Assert(e.tryGet<Int64>(), None<Int64>)
    }

    /** 开始事件保留自定义事件名，类型为 `Start`。 */
    @TestCase
    public func startEventKeepsName(): Unit {
        let e = StartEvent(category: "c", tag: "t", name: "created", data: 1)
        @Assert(e.eventType, EventType.Start)
        @Assert(e.name, "created")
        @Assert(e.tryGet<Int64>(), Some(1))
    }

    /** 结束事件的名称固定为 `End`，与 `EndExecutor` 的登记名一致。 */
    @TestCase
    public func endEventUsesFixedName(): Unit {
        let e = EndEvent(category: "c", tag: "t", data: "done")
        @Assert(e.eventType, EventType.End)
        @Assert(e.name, EventType.End.toString())
        @Assert(e.name, "End")
    }

    /** 任务事件携带名称与载荷。 */
    @TestCase
    public func taskEventCarriesNameAndData(): Unit {
        let e = TaskEvent(category: "c", tag: "t", name: "validated", data: "v")
        @Assert(e.eventType, EventType.Task)
        @Assert(e.name, "validated")
        @Assert(e.tryGet<String>(), Some("v"))
    }

    /** 错误事件的两个构造器：消息载荷与异常载荷。 */
    @TestCase
    public func errorEventSupportsMessageAndException(): Unit {
        let byMessage = ErrorEvent(category: "c", tag: "t", message: "boom")
        @Assert(byMessage.eventType, EventType.Error)
        @Assert(byMessage.name, "Error")
        @Assert(byMessage.tryGet<String>(), Some("boom"))

        let cause = GraphException("inner")
        let byException = ErrorEvent(category: "c", tag: "t", error: cause)
        @Expect(byException.tryGet<GraphException>().isSome(), true)
        @Assert(byException.tryGet<GraphException>().getOrThrow().message, "inner")
    }

    /** 多事件的载荷是子事件序列。 */
    @TestCase
    public func multiEventCarriesChildren(): Unit {
        let child = TaskEvent(category: "c", tag: "t", name: "a", data: "1")
        let e = MultiEvent(category: "c", tag: "t", name: EventType.Multi.toString(), events: [child])
        @Assert(e.eventType, EventType.Multi)
        @Assert(e.name, "Multi")
        let children = e.tryGet<Array<Event>>()
        @Assert(children.isSome(), true)
        @Assert(children.getOrThrow().size, 1)
        @Expect(children.getOrThrow()[0] == child, true)
    }

    /** `DummyEvent.instance` 是单例，字段全空。 */
    @TestCase
    public func dummyEventIsSingleton(): Unit {
        let a = DummyEvent.instance
        let b = DummyEvent.instance
        @Expect(a == b, true)
        @Assert(a.eventType, EventType.Dummy)
        @Assert(a.category, "")
        @Assert(a.tag, "")
        @Assert(a.name, "")
        @Assert(a.session, "")
    }
}
