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
import fountain::fprobe.supervisor.{NodeSource, NodeStateStore, PollLoop}

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
}
