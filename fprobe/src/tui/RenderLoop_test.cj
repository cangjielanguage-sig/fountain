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
package fountain::fprobe.tui

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.collect.SystemClock
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot}
import fountain::fprobe.supervisor.{NodeSource, NodeState, NodeStateStore, NodeStatus, PollLoop}

/** 计数用的假节点源；每次 collect 只返回一个最小快照。 */
class CountingSource <: NodeSource {
    public let calls = AtomicInt64(0)

    public prop name: String {
        get() {
            "node-a"
        }
    }

    public func collect(): ProbeSnapshot {
        calls.fetchAdd(1)
        ProbeSnapshot("node-a", "h", 0, [ProbeAgentData("cpu", "h", "{}", 0, "")])
    }
}

/** 渲染耗时可控的假 painter，用来观察拉取线程是否被拖慢。 */
class SlowPainter <: Painter {
    private let delayMs: Int64
    public let drawCount = AtomicInt64(0)

    init(delayMs: Int64) {
        this.delayMs = delayMs
    }

    public func start(): Unit {}

    public func draw(_: RenderPlan): Unit {
        drawCount.fetchAdd(1)
        sleep(Duration.millisecond * delayMs)
    }

    public func restore(): Unit {}

    public func viewportHeight(): Int64 {
        24
    }
}


/** 记录最后一帧的假 painter；视口高度由用例指定。 */
class CapturingPainter <: Painter {
    private let height: Int64
    public var lastPlan: ?RenderPlan = None<RenderPlan>

    init(height: Int64) {
        this.height = height
    }

    public func start(): Unit {}

    public func draw(plan: RenderPlan): Unit {
        lastPlan = Some(plan)
    }

    public func restore(): Unit {}

    public func viewportHeight(): Int64 {
        height
    }
}

/** 12.6：渲染慢不拖慢拉取。假 painter 每帧睡 200ms，拉取仍按 50ms 周期推进。 */
@Test
public class RenderLoop_test {
    @TestCase
    public func slowRenderingDoesNotThrottlePolling(): Unit {
        let clock = SystemClock()
        let source = CountingSource()
        let store = NodeStateStore()
        let poll = PollLoop([source], store, clock, 50, 2, {_ => ()}, {_ => ()})
        let view = ViewModel.empty().withNodes(["node-a"])
        let painter = SlowPainter(200)
        let render = RenderLoop(store, {=> view}, FixedHistory(60), painter, 200, clock, {=> []})

        let pollThread = spawn {=> poll.run()}
        let renderThread = spawn {=> render.run()}
        sleep(Duration.millisecond * 1000)
        poll.stop()
        render.stop()
        pollThread.get()
        renderThread.get()

        // 1000ms / 50ms 约 20 个 tick；若渲染与拉取同线程，只会有约 5 个。
        @Assert(poll.tickCount() >= 10)
        @Assert(painter.drawCount.load() >= 1)
    }

    /** 视口高度进入 RenderPlan：24 行画出 13 行图表，12 行回退为 0。 */
    @TestCase
    public func passesViewportHeightToPlan(): Unit {
        let store = NodeStateStore()
        let dataJson = '{"usagePercent":10.0,"iowaitPercent":0.0,"load1":0.1,"load5":0.2,"load15":0.3,"cores":4}'
        let snapshot = ProbeSnapshot("node-a", "h", 1,
            [ProbeAgentData("cpu", "h", dataJson, 1, "")])
        store.update(NodeState("node-a", NodeStatus.ONLINE, 0, Some(snapshot), "", 1))
        let view = ViewModel(["node-a"], 0, 0, 0)

        let tall = CapturingPainter(24)
        RenderLoop(store, {=> view}, EmptyHistorySource(), tall, 200, SystemClock(), {=> []}).renderOnce()
        @Assert(tall.lastPlan.getOrThrow().chartHeight, 13)

        let short = CapturingPainter(12)
        RenderLoop(store, {=> view}, EmptyHistorySource(), short, 200, SystemClock(), {=> []}).renderOnce()
        @Assert(short.lastPlan.getOrThrow().chartHeight, 0)
    }
}
