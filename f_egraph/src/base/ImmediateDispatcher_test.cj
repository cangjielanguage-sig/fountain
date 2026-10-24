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

/** `Dispatcher` 契约的同步实现（`design.md` §5、D9、D11）。 */
@Test
class ImmediateDispatcher_test {
    private static func dispatcher(): ImmediateDispatcher {
        ImmediateDispatcher()
    }

    /** 开始 → 任务 → 结束的完整链路。 */
    @TestCase
    public func startRunsToEnd(): Unit {
        let d = dispatcher()
        d.registerStart(category: "c", tag: "t", eventName: "created")
        d.registerEnd(category: "c", tag: "t")
        d.registerTask(category: "c", tag: "t", eventName: "created") { e =>
            EndEvent(category: e.category, tag: e.tag, data: "done")
        }
        let returned = d.start(StartEvent(category: "c", tag: "t", name: "created", data: "go"))
        @Expect(returned.get().get().eventType == EventType.End, true)
        @Expect(d.tryGet().isSome(), true)
    }

    /**
     * 同一 `(category, tag)` 的**开始事件**重复登记 → `GraphException`。
     */
    @TestCase
    public func duplicateStartIsRejected(): Unit {
        let d = dispatcher()
        d.registerStart(category: "c", tag: "t", eventName: "created")
        var message = ""
        try {
            d.registerStart(category: "c", tag: "t", eventName: "created")
        } catch (e: GraphException) {
            message = e.message
        }
        @Expect(message.contains("has already been registered"), true)
    }

    /**
     * 同一事件重复登记**业务任务** → `GraphException`（spec `f-egraph-flow-script` §6.2 第 3 条）。
     */
    @TestCase
    public func duplicateTaskIsRejected(): Unit {
        let d = dispatcher()
        d.registerTask(category: "c", tag: "t", eventName: "created") { e => e }
        var message = ""
        try {
            d.registerTask(category: "c", tag: "t", eventName: "created") { e => e }
        } catch (e: GraphException) {
            message = e.message
        }
        @Expect(message.contains("has already been registered"), true)
    }

    /** 未登记的事件 → `GraphException`（见 `dispatch` 的兜底分支）。 */
    @TestCase
    public func unknownEventFailsDispatch(): Unit {
        let d = dispatcher()
        d.accept(TaskEvent(category: "c", tag: "t", name: "nobody", data: "x"))
        var message = ""
        try {
            d.dispatch()
        } catch (e: GraphException) {
            message = e.message
        }
        @Expect(message.contains("No executor found for event"), true)
    }

    /** 错误事件由 `ErrorExecutor` 转成异常上抛。 */
    @TestCase
    public func errorEventThrowsFromDispatch(): Unit {
        let d = dispatcher()
        d.registerError(category: "c", tag: "t")
        d.accept(ErrorEvent(category: "c", tag: "t", message: "boom"))
        var message = ""
        try {
            d.dispatch()
        } catch (e: GraphException) {
            message = e.message
        }
        @Assert(message, "boom")
    }

    /** `removeIf` 删除执行器后，原事件不再可达。 */
    @TestCase
    public func removeIfDropsExecutors(): Unit {
        let d = dispatcher()
        d.registerStart(category: "c", tag: "t", eventName: "created")
        d.registerEnd(category: "c", tag: "t")
        d.removeIf { e => e.tag == "t" }
        d.accept(StartEvent(category: "c", tag: "t", name: "created", data: "go"))
        var failed = false
        try {
            d.dispatch()
        } catch (e: GraphException) {
            failed = true
        }
        @Expect(failed, true)
    }

    /**
     * `registerMultiTask` 登记的接受事件是 `Multi`/`Multi`，能收到 `MultiEvent`；
     * 业务 `registerTask` 登记的是 `Task` 类型键，收不到（负向对照，`design.md` D9）。
     */
    @TestCase
    public func registerMultiTaskReceivesMultiEvent(): Unit {
        let d = dispatcher()
        d.registerEnd(category: "c", tag: "t")
        d.registerMultiTask(category: "c", tag: "t") { e =>
            EndEvent(category: e.category, tag: e.tag, data: "fanned")
        }
        d.accept(MultiEvent(category: "c", tag: "t", name: EventType.Multi.toString(),
            events: [TaskEvent(category: "c", tag: "t", name: "a", data: "1")]))
        d.dispatch()
        @Expect(d.tryGet().getOrThrow().get().eventType == EventType.End, true)

        let business = dispatcher()
        business.registerTask(category: "c2", tag: "t", eventName: EventType.Multi.toString()) { _ =>
            DummyEvent.instance
        }
        business.accept(MultiEvent(category: "c2", tag: "t", name: EventType.Multi.toString(),
            events: [TaskEvent(category: "c2", tag: "t", name: "a", data: "1")]))
        var failed = false
        try {
            business.dispatch()
        } catch (e: GraphException) {
            failed = true
        }
        @Expect(failed, true)
    }

    /** `startEventName` 的命中与未命中（`design.md` D11）。 */
    @TestCase
    public func startEventNameIsRecorded(): Unit {
        let d = dispatcher()
        @Expect(d.startEventName(category: "c", tag: "t").isNone(), true)
        d.registerStart(category: "c", tag: "t", eventName: "created")
        @Assert(d.startEventName(category: "c", tag: "t"), Some("created"))
        @Expect(d.startEventName(category: "c", tag: "other").isNone(), true)
        @Expect(d.startEventName(category: "other", tag: "t").isNone(), true)
    }
}
