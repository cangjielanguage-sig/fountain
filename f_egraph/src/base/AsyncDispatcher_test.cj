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

/**
 * `Dispatcher` 契约的异步实现。
 *
 * 用例都从**同一线程**发起并等待，`AsyncDispatcher` 用线程 id 关联结束事件。
 */
@Test
class AsyncDispatcher_test {
    private static func dispatcher(): AsyncDispatcher {
        AsyncDispatcher(toThrowIfNoExecutor: true)
    }

    /** 开始 → 任务 → 结束，`tryGet(timeout:)` 拿到结束事件。 */
    @TestCase
    public func startRunsToEnd(): Unit {
        let d = dispatcher()
        d.registerStart(category: "c", tag: "t", eventName: "created")
        d.registerEnd(category: "c", tag: "t")
        d.registerTask(category: "c", tag: "t", eventName: "created") { e =>
            EndEvent(category: e.category, tag: e.tag, data: "done")
        }
        d.accept(StartEvent(category: "c", tag: "t", name: "created", data: "go"))
        d.dispatch()
        let end = d.tryGet(timeout: Duration.second)
        @Expect(end.isSome(), true)
        @Expect(end.getOrThrow().get().eventType == EventType.End, true)
    }

    /** 阻塞版 `get()` 同样可用。 */
    @TestCase
    public func blockingGetReturnsEnd(): Unit {
        let d = dispatcher()
        d.registerStart(category: "c", tag: "t", eventName: "created")
        d.registerEnd(category: "c", tag: "t")
        d.registerTask(category: "c", tag: "t", eventName: "created") { e =>
            EndEvent(category: e.category, tag: e.tag, data: "done")
        }
        d.accept(StartEvent(category: "c", tag: "t", name: "created", data: "go"))
        d.dispatch()
        @Expect(d.get().get().eventType == EventType.End, true)
    }

    /** 重复登记开始事件 → `GraphException`。 */
    @TestCase
    public func duplicateStartIsRejected(): Unit {
        let d = dispatcher()
        d.registerStart(category: "c", tag: "t", eventName: "created")
        var failed = false
        try {
            d.registerStart(category: "c", tag: "t", eventName: "created")
        } catch (e: GraphException) {
            failed = true
        }
        @Expect(failed, true)
    }

    /** 同一事件重复登记业务任务 → `GraphException`（spec §6.2 第 3 条）。 */
    @TestCase
    public func duplicateTaskIsRejected(): Unit {
        let d = dispatcher()
        d.registerTask(category: "c", tag: "t", eventName: "created") { e => e }
        var failed = false
        try {
            d.registerTask(category: "c", tag: "t", eventName: "created") { e => e }
        } catch (e: GraphException) {
            failed = true
        }
        @Expect(failed, true)
    }

    /** `registerMultiTask` 的接受事件是 `Multi`，能收到 `MultiEvent`（`design.md` D9）。 */
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
        let end = d.tryGet(timeout: Duration.second)
        @Expect(end.isSome(), true)
    }

    /** `startEventName` 的命中与未命中（`design.md` D11）。 */
    @TestCase
    public func startEventNameIsRecorded(): Unit {
        let d = dispatcher()
        @Expect(d.startEventName(category: "c", tag: "t").isNone(), true)
        d.registerStart(category: "c", tag: "t", eventName: "created")
        @Assert(d.startEventName(category: "c", tag: "t"), Some("created"))
        @Expect(d.startEventName(category: "c", tag: "other").isNone(), true)
    }

    /**
     * `removeIf` 删除执行器后，原先登记的事件不再可达。
     *
     * `toThrowIfNoExecutor = true` 时异常在 dispatch 线程内抛出，用例侧只断言「拿不到结束事件」。
     */
    @TestCase
    public func removeIfDropsExecutors(): Unit {
        let d = dispatcher()
        d.registerStart(category: "c", tag: "t", eventName: "created")
        d.registerEnd(category: "c", tag: "t")
        d.removeIf { e => e.tag == "t" }
        d.accept(StartEvent(category: "c", tag: "t", name: "created", data: "go"))
        d.dispatch()
        @Expect(d.tryGet(timeout: Duration.millisecond * 200).isNone(), true)
    }

    /** `toThrowIfNoExecutor = false` 时未知事件只记录告警，不抛异常。 */
    @TestCase
    public func missingExecutorCanBeTolerated(): Unit {
        let d = AsyncDispatcher(toThrowIfNoExecutor: false)
        d.accept(TaskEvent(category: "c", tag: "t", name: "nobody", data: "x"))
        d.dispatch()
        @Expect(d.tryGet(timeout: Duration.millisecond * 200).isNone(), true)
    }
}
