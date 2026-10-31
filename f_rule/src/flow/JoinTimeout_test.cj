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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_egraph.base.{Event, EventType, TaskEvent}

/** 测试用调度器：记录回调，由用例手动触发。 */
class FakeTimeoutScheduler <: JoinTimeoutScheduler {
    public var available_: Bool = true
    public var accept_: Bool = true
    public var scheduled: Int64 = 0
    private var action_: ?() -> Unit = None

    public func available(): Bool {
        available_
    }

    public func schedule(delay: Duration, action: () -> Unit): Bool {
        if (!accept_) {
            return false
        }
        scheduled += 1
        action_ = Some(action)
        true
    }

    public func fire(): Unit {
        match (action_) {
            case Some(fn) => fn()
            case None => ()
        }
    }
}

/** 收集超时事件。 */
class EventBox {
    public let events = ArrayList<Event>()
}

/**
 * `JoinTask` 超时（`doc/06-flow-orchestration.md` §4.2、§8）。
 *
 * 通过可注入的 [JoinTimeoutScheduler] 验证：未集齐发 `timeoutEvent`、未配置
 * `timeoutEvent` 发 `ErrorEvent`、调度不可用时退化为不超时、到齐后超时回调失效。
 */
@Test
class JoinTimeout_test {
    private func event(session: String, name: String): TaskEvent {
        TaskEvent(category: "join-timeout", tag: "v1", name: name,
            data: RuleEnvelope(session: session, ruleSetId: "pricing", payload: name),
            session: "event-session")
    }

    private func sink(box: EventBox): (Event) -> Unit {
        { e => box.events.add(e) }
    }

    /** 未集齐时超时，发配置的 `timeoutEvent` 并清态。 */
    @TestCase
    public func timeoutEmitsConfiguredEvent(): Unit {
        let scheduler = FakeTimeoutScheduler()
        let box = EventBox()
        let task = JoinTask(name: "join", branches: ["a", "b"], output: "out",
            timeout: Some(Duration.second), timeoutEvent: Some("timeout"),
            scheduler: Some(scheduler), timeoutSink: Some(sink(box)))
        @Expect(task.timeoutEnabled, true)
        @Expect(task.exec(event("s1", "a")).eventType, EventType.Dummy)
        @Expect(scheduler.scheduled, 1)

        scheduler.fire()
        @Expect(box.events.size, 1)
        @Expect(box.events[0].name, "timeout")
        @Expect(box.events[0].eventType, EventType.Task)
        @Expect(RuleEnvelope.from(box.events[0]).session, "s1")
        @Expect(task.size(), 0)
        @Expect(task.exec(event("s1", "b")).eventType, EventType.Dummy)
    }

    /** 未配置 `timeoutEvent` 时发 `ErrorEvent`。 */
    @TestCase
    public func timeoutWithoutEventEmitsError(): Unit {
        let scheduler = FakeTimeoutScheduler()
        let box = EventBox()
        let task = JoinTask(name: "join", branches: ["a", "b"], output: "out",
            timeout: Some(Duration.second), scheduler: Some(scheduler), timeoutSink: Some(sink(box)))
        let _ = task.exec(event("s1", "a"))
        scheduler.fire()
        @Expect(box.events.size, 1)
        @Expect(box.events[0].eventType, EventType.Error)
        @Expect(box.events[0].name, EventType.Error.toString())
    }

    /** 调度器不可用时构造期关闭超时。 */
    @TestCase
    public func unavailableSchedulerDisablesTimeout(): Unit {
        let scheduler = FakeTimeoutScheduler()
        scheduler.available_ = false
        let task = JoinTask(name: "join", branches: ["a", "b"], output: "out",
            timeout: Some(Duration.second), scheduler: Some(scheduler))
        @Expect(task.timeoutEnabled, false)
        let _ = task.exec(event("s1", "a"))
        @Expect(scheduler.scheduled, 0)
    }

    /** 调度失败（Ticktock 未初始化等）时退化为不超时，不丢状态。 */
    @TestCase
    public func scheduleFailureFallsBackWithoutTimeout(): Unit {
        let scheduler = FakeTimeoutScheduler()
        scheduler.accept_ = false
        let task = JoinTask(name: "join", branches: ["a", "b"], output: "out",
            timeout: Some(Duration.second), scheduler: Some(scheduler))
        @Expect(task.timeoutEnabled, true)
        let _ = task.exec(event("s1", "a"))
        @Expect(task.timeoutEnabled, false)
        @Expect(task.size(), 1)
    }

    /** 到齐后回调失效，不重复发事件。 */
    @TestCase
    public func timeoutAfterCompletionIsIgnored(): Unit {
        let scheduler = FakeTimeoutScheduler()
        let box = EventBox()
        let task = JoinTask(name: "join", branches: ["a", "b"], output: "out",
            timeout: Some(Duration.second), timeoutEvent: Some("timeout"),
            scheduler: Some(scheduler), timeoutSink: Some(sink(box)))
        let _ = task.exec(event("s1", "a"))
        let done = task.exec(event("s1", "b"))
        @Expect(done.name, "out")
        scheduler.fire()
        @Expect(box.events.size, 0)
    }

    /** 未配置 timeout 时不调度。 */
    @TestCase
    public func noTimeoutMeansNoScheduling(): Unit {
        let scheduler = FakeTimeoutScheduler()
        let task = JoinTask(name: "join", branches: ["a", "b"], output: "out",
            scheduler: Some(scheduler))
        @Expect(task.timeoutEnabled, false)
        let _ = task.exec(event("s1", "a"))
        @Expect(scheduler.scheduled, 0)
    }
}
