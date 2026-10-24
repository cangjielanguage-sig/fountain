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

/** 测试用可变计数器（任务体在宿主闭包里执行，用锁保证可见性）。 */
class TestCounter {
    private let mtx = Mutex()
    private let values = HashMap<String, Int64>()

    func increase(name: String): Unit {
        synchronized(mtx) {
            values[name] = (values.get(name) ?? 0) + 1
        }
    }

    func of(name: String): Int64 {
        synchronized(mtx) {
            values.get(name) ?? 0
        }
    }

    func clear(): Unit {
        synchronized(mtx) {
            values.clear()
        }
    }
}

/** 测试用任务实现（0.6 阶段 `ClosureTask` 尚未实现）。 */
class TestTask <: Task {
    private let name_: String
    private let acceptable_: Array<String>
    private let producing_: Array<String>
    private let body_: (Event) -> Event

    init(name: String, acceptableEvents: Array<String>, body: (Event) -> Event) {
        name_ = name
        acceptable_ = acceptableEvents
        producing_ = [EventType.End.toString()]
        body_ = body
    }

    public prop name: String {
        get() {
            name_
        }
    }

    public prop acceptableEvents: Array<String> {
        get() {
            acceptable_
        }
    }

    public prop producingEvents: Array<String> {
        get() {
            producing_
        }
    }

    public func exec(e: Event): Event {
        body_(e)
    }
}

@Test
class Flow_test {
    private static func category(prefix: String): String {
        "${prefix}-${UUID.random().toHexString()}"
    }

    /**
     * 需求见 `design.md` D9：`ImmediateFlow` 构造期注册 Multi 任务时不得走业务任务校验。
     */
    @TestCase
    public func newImmediateFlowCanBeConstructed(): Unit {
        let c = Flow_test.category("ctor")
        let flow = ImmediateFlow(category: c, tag: "v1")
        @Assert(flow.category, c)
        @Assert(flow.tag, "v1")
        flow.remove()
    }

    /** `AsyncFlow` 在宿主初始化 dispatcher 后同样可构造。 */
    @TestCase
    public func newAsyncFlowCanBeConstructedAfterInitDispatcher(): Unit {
        AsyncFlow.initDispatcher()
        let c = Flow_test.category("ctor-async")
        let flow = AsyncFlow(category: c, tag: "v1")
        @Assert(flow.category, c)
        @Assert(flow.tag, "v1")
    }

    /** Multi 任务应把 `MultiEvent` 的子事件各扇出一次（`specs/f-egraph-flow-script`）。 */
    @TestCase
    public func multiEventFansOutToEachExecutor(): Unit {
        let c = Flow_test.category("fanout")
        let flow = ImmediateFlow(category: c, tag: "v1")
        let counter = TestCounter()
        flow.registerStart("created")
        flow.registerEnd()
        flow.registerTask("created") { _ =>
            MultiEvent(category: c, tag: "v1", name: EventType.Multi.toString(), events:
                [TaskEvent(category: c, tag: "v1", name: "a", data: "1"), TaskEvent(category: c, tag: "v1", name: "b", data: "2")])
        }
        flow.registerTask("a") { _ =>
            counter.increase("a")
            DummyEvent.instance
        }
        // `ImmediateDispatcher.dispatch` 只在遇到 `EndExecutor` 时返回，故末态子任务产出结束事件。
        flow.registerTask("b") { _ =>
            counter.increase("b")
            EndEvent(category: c, tag: "v1", data: "2")
        }
        flow.start("go")
        @Assert(counter.of("a"), 1)
        @Assert(counter.of("b"), 1)
        flow.remove()
    }

    /** 构造期的 Multi 注册不得放宽业务首任务约束。 */
    @TestCase
    public func firstBusinessTaskMustAcceptStartEvent(): Unit {
        let c = Flow_test.category("first-task")
        let flow = ImmediateFlow(category: c, tag: "v1")
        flow.registerStart("created")
        var message = ""
        try {
            flow.registerTask(TestTask("t", ["other"], { _ => DummyEvent.instance }))
        } catch (e: GraphException) {
            message = e.message
        }
        @Assert(message.contains("First TaskExecutor name must be same as StartExecutor name"), true)
        flow.remove()
    }

    /** 同一 `(category, tag)` 二次构造不得重复登记 Multi 任务。 */
    @TestCase
    public func repeatedConstructionDoesNotRegisterMultiTwice(): Unit {
        let c = Flow_test.category("repeat")
        let counter = TestCounter()
        let flow = ImmediateFlow(category: c, tag: "v1")
        flow.registerStart("created")
        flow.registerEnd()
        flow.registerTask("created") { _ =>
            MultiEvent(category: c, tag: "v1", name: EventType.Multi.toString(), events: [TaskEvent(category: c, tag: "v1", name: "only", data: "x")])
        }
        flow.registerTask("only") { _ =>
            counter.increase("only")
            EndEvent(category: c, tag: "v1", data: "x")
        }
        let _ = ImmediateFlow(category: c, tag: "v1")
        flow.start("go")
        @Assert(counter.of("only"), 1)
        flow.remove()
    }

    /**
     * `design.md` D11 回归：本地显式 `registerStart` 后，`start` 仍按本地名启动，
     * 不因新增的「回退读取共享开始事件名」改变既有路径。
     */
    @TestCase
    public func localRegisterStartStillDrivesStart(): Unit {
        let c = Flow_test.category("local-start")
        let flow = ImmediateFlow(category: c, tag: "v1")
        flow.registerStart("local-start")
        flow.registerEnd()
        flow.registerTask("local-start") { _ =>
            EndEvent(category: c, tag: "v1", data: "local")
        }
        @Assert(FlowEventFactory.flowDataOf(flow.start("go").get().get()), "local")
        flow.remove()
    }

    /** 异步流程同样保留本地 `registerStart` 路径（D11 回归）。 */
    @TestCase
    public func localRegisterStartStillDrivesAsyncStart(): Unit {
        AsyncFlow.initDispatcher()
        let c = Flow_test.category("local-start-async")
        let flow = AsyncFlow(category: c, tag: "v1")
        flow.registerStart("local-start")
        flow.registerEnd()
        flow.registerTask("local-start") { _ =>
            EndEvent(category: c, tag: "v1", data: "local")
        }
        @Assert(FlowEventFactory.flowDataOf(flow.start("go").get().get()), "local")
        flow.remove()
    }

    /** `AsyncFlow` 的 `(category, tag)` 二次构造同样不得重复登记 Multi 任务（D9 缺陷 3）。 */
    @TestCase
    public func asyncRepeatedConstructionDoesNotRegisterMultiTwice(): Unit {
        AsyncFlow.initDispatcher()
        let c = Flow_test.category("repeat-async")
        let counter = TestCounter()
        let flow = AsyncFlow(category: c, tag: "v1")
        flow.registerStart("created")
        flow.registerEnd()
        flow.registerTask("created") { _ =>
            MultiEvent(category: c, tag: "v1", name: EventType.Multi.toString(),
                events: [TaskEvent(category: c, tag: "v1", name: "only", data: "x")])
        }
        flow.registerTask("only") { _ =>
            counter.increase("only")
            EndEvent(category: c, tag: "v1", data: "x")
        }
        let _ = AsyncFlow(category: c, tag: "v1")
        flow.start("go").tryGet(timeout: Duration.second)
        @Assert(counter.of("only"), 1)
        flow.remove()
    }

    /** `emit` 把事件投入队列，随后的 `start` 会先处理它。 */
    @TestCase
    public func emitEnqueuesEvent(): Unit {
        let c = Flow_test.category("emit")
        let flow = ImmediateFlow(category: c, tag: "v1")
        flow.registerStart("created")
        flow.registerEnd()
        flow.emit(eventType: EventType.End, name: EventType.End.toString(), data: "emitted")
        let end = flow.start("go").get().get()
        @Assert(end.eventType, EventType.End)
        @Assert(FlowEventFactory.flowDataOf(end), "emitted")
        flow.remove()
    }

    /** 子流程注册把父流程记入 `dependencied`，`canBeRemoved` 据此拒绝删除。 */
    @TestCase
    public func registerTaskByImmediateFlowRegistersDependency(): Unit {
        let parentCategory = Flow_test.category("parent")
        let subCategory = Flow_test.category("sub")
        let parent = ImmediateFlow(category: parentCategory, tag: "v1")
        let sub = ImmediateFlow(category: subCategory, tag: "v1")
        parent.registerStart("created")
        sub.registerStart("created")
        sub.registerEnd()
        sub.registerTask("created") { _ => EndEvent(category: subCategory, tag: "v1", data: "sub") }
        parent.registerTaskByImmediateFlow(eventName: "created", subCategory: subCategory, subTag: "v1")
        @Expect(sub.dependencied.contains(parent.toString()), true)

        var message = ""
        try {
            sub.canBeRemoved()
        } catch (e: GraphException) {
            message = e.message
        }
        @Expect(message.contains("dependencied by"), true)
        sub.dependencied.clear()
        parent.remove()
        sub.remove()
    }

    /** 异步子流程注册同样建立依赖关系。 */
    @TestCase
    public func registerTaskByAsyncFlowRegistersDependency(): Unit {
        AsyncFlow.initDispatcher()
        let parentCategory = Flow_test.category("parent-async")
        let subCategory = Flow_test.category("sub-async")
        let parent = ImmediateFlow(category: parentCategory, tag: "v1")
        let sub = AsyncFlow(category: subCategory, tag: "v1")
        parent.registerStart("created")
        sub.registerStart("created")
        sub.registerEnd()
        sub.registerTask("created") { _ => EndEvent(category: subCategory, tag: "v1", data: "sub") }
        parent.registerTaskByAsyncFlow(eventName: "created", subCategory: subCategory, subTag: "v1")
        @Expect(sub.dependencied.contains(parent.toString()), true)
        sub.dependencied.clear()
        parent.remove()
        sub.remove()
    }

    /** 流程相等性、哈希与字符串表示按 `category + tag` 判定（含跨类型比较）。 */
    @TestCase
    public func equalityUsesCategoryAndTag(): Unit {
        AsyncFlow.initDispatcher()
        let c = Flow_test.category("equality")
        let a = ImmediateFlow(category: c, tag: "v1")
        let b = ImmediateFlow(category: c, tag: "v1")
        let other = ImmediateFlow(category: c, tag: "v2")
        let asyncA = AsyncFlow(category: c, tag: "v1")
        @Expect(a == b, true)
        @Assert(a.hashCode(), b.hashCode())
        @Expect(a == other, false)
        @Expect(a == asyncA, true)
        @Expect(asyncA == a, true)
        @Assert(a.toString(), "${c}-v1")
        @Assert(asyncA.toString(), "${c}-v1")
        a.remove()
        asyncA.remove()
    }

    /** 任务体内 `flow.emit` 发出的事件按 `category`/`tag` 路由到已注册执行器。 */
    @TestCase
    public func emitFromTaskRoutesToExecutor(): Unit {
        let c = Flow_test.category("emit-task")
        let flow = ImmediateFlow(category: c, tag: "v1")
        flow.registerStart("created")
        flow.registerEnd()
        flow.registerTask("created") { _ =>
            flow.emit(eventType: EventType.Task, name: "validated", data: "yes")
            DummyEvent.instance
        }
        flow.registerTask("validated") { _ => EndEvent(category: c, tag: "v1", data: "ok") }
        @Assert(FlowEventFactory.flowDataOf(flow.start("go").get().get()), "ok")
        flow.remove()
    }

    /** `AsyncFlow.removeExceptCurrentTag` 删除同 category 的旧 tag。 */
    @TestCase
    public func asyncRemoveExceptCurrentTagDropsOldTag(): Unit {
        AsyncFlow.initDispatcher()
        let c = Flow_test.category("async-cleanup")
        let old = AsyncFlow(category: c, tag: "v1")
        old.registerStart("created")
        old.registerEnd()
        old.registerTask("created") { _ => EndEvent(category: c, tag: "v1", data: "old") }
        let fresh = AsyncFlow(category: c, tag: "v2")
        fresh.registerStart("created")
        fresh.registerEnd()
        fresh.registerTask("created") { _ => EndEvent(category: c, tag: "v2", data: "new") }

        fresh.removeExceptCurrentTag()

        @Expect(old.start("go").tryGet(timeout: Duration.millisecond * 200).isNone(), true)
        @Assert(FlowEventFactory.flowDataOf(fresh.start("go").tryGet(timeout: Duration.second)
            .getOrThrow().get()), "new")
        fresh.remove()
    }
}
