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

import std.collection.ArrayList
import std.sync.{Mutex, AtomicInt64}
import std.unittest.*
import std.unittest.testmacro.*

/** 记录 `accept` 到的事件，供执行器用例断言。 */
class RecordingAccepter <: Accepter {
    private let mtx = Mutex()
    private let events_ = ArrayList<Event>()

    public func accept(event: Event): Unit {
        synchronized(mtx) {
            events_.add(event)
        }
    }

    func size(): Int64 {
        synchronized(mtx) {
            events_.size
        }
    }

    func at(index: Int64): Event {
        synchronized(mtx) {
            events_[index]
        }
    }
}

/** 执行器契约：`Accepter`/`Executor`/`ImmediateExecutor` 与七个具体执行器。 */
@Test
class Executor_test {
    private static func event(t: EventType, name: String): Event {
        Event(eventType: t, category: "c", tag: "t", name: name)
    }

    private static func category(prefix: String): String {
        "${prefix}-${UUID.random().toHexString()}"
    }

    /** `ImmediateExecutor.accept` 只接受与 `acceptable` 相等的事件。 */
    @TestCase
    public func immediateExecutorRejectsMismatchedEvent(): Unit {
        let end = EndExecutor(acceptingEvent: event(EventType.End, "End"))
        @Expect(end.acceptable == event(EventType.End, "End"), true)
        var message = ""
        try {
            end.accept(TaskEvent(category: "c", tag: "t", name: "other", data: "x"))
        } catch (e: GraphException) {
            message = e.message
        }
        @Expect(message.contains("current Executor accepts"), true)
    }

    /** `StartExecutor` 把开始事件转成同名的任务事件交给 `Accepter`。 */
    @TestCase
    public func startExecutorForwardsTaskEvent(): Unit {
        let accepter = RecordingAccepter()
        let start = StartExecutor(
            acceptingEvent: event(EventType.Start, "created"), accepter: accepter)
        start.accept(StartEvent(category: "c", tag: "t", name: "created", data: "go"))
        @Assert(accepter.size(), 1)
        let forwarded = accepter.at(0)
        @Assert(forwarded.eventType, EventType.Task)
        @Assert(forwarded.name, "created")
        @Assert((forwarded as DataEvent).getOrThrow().tryGet<String>(), Some("go"))
    }

    /** `StartExecutor` 收到相等但非 `DataEvent` 的事件时报类型错误。 */
    @TestCase
    public func startExecutorRequiresDataEvent(): Unit {
        let start = StartExecutor(
            acceptingEvent: event(EventType.Start, "created"), accepter: RecordingAccepter())
        var message = ""
        try {
            start.accept(event(EventType.Start, "created"))
        } catch (e: GraphException) {
            message = e.message
        }
        @Expect(message.contains("must be DataEvent"), true)
    }

    /** `EndExecutor` 保存并暴露结束事件。 */
    @TestCase
    public func endExecutorStoresEvent(): Unit {
        let end = EndExecutor(acceptingEvent: event(EventType.End, "End"))
        @Expect(end.tryGet().isNone(), true)
        let e = EndEvent(category: "c", tag: "t", data: "done")
        end.accept(e)
        @Expect(end.tryGet().getOrThrow() == e, true)
        @Expect(end.get() == e, true)
    }

    /** `ErrorExecutor` 按载荷类型构造异常：字符串、异常对象、其它值。 */
    @TestCase
    public func errorExecutorThrowsByPayloadType(): Unit {
        let error = ErrorExecutor(acceptingEvent: event(EventType.Error, "Error"))

        var byString = ""
        try {
            error.accept(ErrorEvent(category: "c", tag: "t", message: "boom"))
        } catch (e: GraphException) {
            byString = e.message
        }
        @Assert(byString, "boom")

        var caused = false
        try {
            error.accept(ErrorEvent(category: "c", tag: "t", error: GraphException("inner")))
        } catch (e: GraphException) {
            caused = e.causedBy.isSome() && e.causedBy.getOrThrow().message == "inner"
        }
        @Expect(caused, true)

        var byType = ""
        try {
            error.accept(DataEvent(eventType: EventType.Error, category: "c", tag: "t",
                name: "Error", data: 42))
        } catch (e: GraphException) {
            byType = e.message
        }
        @Expect(byType.contains("Int64"), true)

        var empty = false
        try {
            error.accept(event(EventType.Error, "Error"))
        } catch (e: GraphException) {
            empty = e.message.isEmpty()
        }
        @Expect(empty, true)
    }

    /** `TaskExecutor` 执行任务体并把结果交给 `Accepter`。 */
    @TestCase
    public func taskExecutorRunsTaskAndForwards(): Unit {
        let accepter = RecordingAccepter()
        let executor = TaskExecutor(acceptingEvent: event(EventType.Task, "created"),
            accepter: accepter, task: { e =>
                TaskEvent(category: e.category, tag: e.tag, name: "validated", data: "ok")
            })
        executor.accept(TaskEvent(category: "c", tag: "t", name: "created", data: "in"))
        @Assert(accepter.size(), 1)
        @Assert(accepter.at(0).name, "validated")
        @Assert(accepter.at(0).eventType, EventType.Task)
    }

    /** `AsyncTaskExecutor` 在独立线程执行任务，`acceptable` 与内层执行器一致。 */
    @TestCase
    public func asyncTaskExecutorRunsInBackground(): Unit {
        let accepter = RecordingAccepter()
        let counter = AtomicInt64(0)
        let executor = AsyncTaskExecutor(acceptingEvent: event(EventType.Task, "created"),
            accepter: accepter, task: { e =>
                counter.fetchAdd(1)
                DummyEvent.instance
            })
        @Expect(executor.acceptable == event(EventType.Task, "created"), true)
        executor.accept(TaskEvent(category: "c", tag: "t", name: "created", data: "in"))
        var waited = 0
        while (counter.load() == 0 && waited < 100) {
            sleep(Duration.millisecond * 10)
            waited++
        }
        @Assert(counter.load(), 1)
        @Assert(accepter.size(), 1)
        @Assert(accepter.at(0).eventType, EventType.Dummy)
    }

    /** 异步执行器同样校验事件（不匹配时抛 `GraphException`）。 */
    @TestCase
    public func asyncTaskExecutorRejectsMismatchedEvent(): Unit {
        let executor = AsyncTaskExecutor(acceptingEvent: event(EventType.Task, "created"),
            accepter: RecordingAccepter(), task: { _ => DummyEvent.instance })
        var failed = false
        try {
            executor.accept(TaskEvent(category: "c", tag: "t", name: "other", data: "x"))
        } catch (e: GraphException) {
            failed = true
        }
        @Expect(failed, true)
    }

    /** `TaskExecutor.newByImmediateFlow` 启动子流程并返回其结束事件。 */
    @TestCase
    public func taskExecutorByImmediateFlowStartsSubFlow(): Unit {
        let subCategory = Executor_test.category("sub-immediate")
        let sub = ImmediateFlow(category: subCategory, tag: "v1")
        sub.registerStart("created")
        sub.registerEnd()
        sub.registerTask("created") { _ => EndEvent(category: subCategory, tag: "v1", data: "sub") }

        let accepter = RecordingAccepter()
        let executor = TaskExecutor.newByImmediateFlow(
            acceptingEvent: event(EventType.Task, "created"), accepter: accepter,
            subCategory: subCategory, subTag: "v1")
        executor.accept(TaskEvent(category: "c", tag: "t", name: "created", data: "go"))
        @Assert(accepter.size(), 1)
        @Assert(accepter.at(0).eventType, EventType.End)
        @Assert(FlowEventFactory.flowDataOf(accepter.at(0)), "sub")
        sub.remove()
    }

    /** `TaskExecutor.newByAsyncFlow` 同样启动子流程并返回其结束事件。 */
    @TestCase
    public func taskExecutorByAsyncFlowStartsSubFlow(): Unit {
        AsyncFlow.initDispatcher()
        let subCategory = Executor_test.category("sub-async")
        let sub = AsyncFlow(category: subCategory, tag: "v1")
        sub.registerStart("created")
        sub.registerEnd()
        sub.registerTask("created") { _ => EndEvent(category: subCategory, tag: "v1", data: "sub") }

        let accepter = RecordingAccepter()
        let executor = TaskExecutor.newByAsyncFlow(
            acceptingEvent: event(EventType.Task, "created"), accepter: accepter,
            subCategory: subCategory, subTag: "v1")
        executor.accept(TaskEvent(category: "c", tag: "t", name: "created", data: "go"))
        @Assert(accepter.size(), 1)
        @Assert(accepter.at(0).eventType, EventType.End)
        @Assert(FlowEventFactory.flowDataOf(accepter.at(0)), "sub")
        sub.remove()
    }

    /** `ConcurrentEndExecutor` 在另一线程延迟 `execute`，主线程 `get()` 被唤醒。 */
    @TestCase
    public func concurrentEndExecutorWakesBlockedGetter(): Unit {
        let end = ConcurrentEndExecutor(acceptingEvent: event(EventType.End, "End"))
        let e = EndEvent(category: "c", tag: "t", data: "delayed")
        spawn {
            sleep(Duration.millisecond * 50)
            end.execute(e)
        }
        @Expect(end.get() == e, true)
    }

    /** `ConcurrentEndExecutor` 的 `execute`/`get`/`tryGet`/`get(timeout:)`。 */
    @TestCase
    public func concurrentEndExecutorExposesEvent(): Unit {
        let end = ConcurrentEndExecutor(acceptingEvent: event(EventType.End, "End"))
        @Expect(end.tryGet().isNone(), true)
        @Expect(end.get(timeout: Duration.millisecond * 20).isNone(), true)
        let e = EndEvent(category: "c", tag: "t", data: "done")
        end.execute(e)
        @Expect(end.tryGet().getOrThrow() == e, true)
        @Expect(end.get() == e, true)
        @Expect(end.get(timeout: Duration.millisecond * 20).getOrThrow() == e, true)
    }
}
