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
package fountain::fprobe.supervisor

import std.collection.ArrayList
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}
import fountain::fprobe.collect.FakeClock
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot}

/** 按脚本返回成功/失败的假传输；每 tick 只被调用一次。 */
class ScriptedSource <: NodeSource {
    private let nodeName: String
    private let script: Array<Bool>
    private let clock: FakeClock
    private var index: Int64 = 0
    public let calls = AtomicInt64(0)

    init(name: String, script: Array<Bool>, clock: FakeClock) {
        this.nodeName = name
        this.script = script
        this.clock = clock
    }

    public prop name: String {
        get() {
            nodeName
        }
    }

    public func collect(): ProbeSnapshot {
        calls.fetchAdd(1)
        let current = index
        index += 1
        let ok = if (current < script.size) {
            script[current]
        } else {
            script[script.size - 1]
        }
        if (!ok) {
            throw ProbeException(ProbeErrorCode.COLLECT, '${nodeName} 拉取失败')
        }
        let now = clock.nowMs()
        ProbeSnapshot(nodeName, '${nodeName}-host', now,
            [ProbeAgentData("cpu", '${nodeName}-host', '{"usagePercent":10}', now, "")])
    }
}

/** 9.1：每个 tick 对每个节点恰好一次 collect。 */
@Test
public class PollLoopCollect_test {
    @TestCase
    public func eachTickCollectsEveryNodeExactlyOnce(): Unit {
        let clock = FakeClock(1000)
        let a = ScriptedSource("a", [true, true, true], clock)
        let b = ScriptedSource("b", [true, true, true], clock)
        let store = NodeStateStore()
        let events = ArrayList<NodeEvent>()
        let loop = PollLoop([a, b], store, clock, 5000, 2, {event => events.add(event)}, {_ => ()})

        loop.tick()
        clock.advance(5000)
        loop.tick()
        clock.advance(5000)
        loop.tick()

        @Assert(a.calls.load(), 3)
        @Assert(b.calls.load(), 3)
        @Assert(loop.tickCount(), 3)
        @Assert(store.get("a").getOrThrow().status, NodeStatus.ONLINE)
        @Assert(store.get("a").getOrThrow().snapshot.getOrThrow().timestamp, 11000)
        @Assert(store.get("b").getOrThrow().snapshot.getOrThrow().agents.size, 1)
        @Assert(events.isEmpty())
    }
}

/** 9.2：连续失败达阈值产生不可达事件，恢复产生恢复事件。 */
@Test
public class PollLoopFailureRecovery_test {
    @TestCase
    public func failureThresholdAndRecoveryAreReported(): Unit {
        let clock = FakeClock(1000)
        let a = ScriptedSource("a", [false, false, true, true, false, false], clock)
        let store = NodeStateStore()
        let events = ArrayList<NodeEvent>()
        let loop = PollLoop([a], store, clock, 5000, 2, {event => events.add(event)}, {_ => ()})

        loop.tick()
        @Assert(store.get("a").getOrThrow().consecutiveFailures, 1)
        @Assert(store.get("a").getOrThrow().status, NodeStatus.OFFLINE)
        @Assert(events.isEmpty())
        clock.advance(5000)

        loop.tick()
        @Assert(store.get("a").getOrThrow().consecutiveFailures, 2)
        @Assert(events.size, 1)
        @Assert(events[0].eventType, NodeEventType.UNREACHABLE)
        @Assert(events[0].node, "a")
        @Assert(events[0].failures, 2)
        @Assert(events[0].message.contains("不可达"))
        clock.advance(5000)

        loop.tick()
        @Assert(store.get("a").getOrThrow().consecutiveFailures, 0)
        @Assert(store.get("a").getOrThrow().status, NodeStatus.ONLINE)
        @Assert(events.size, 2)
        @Assert(events[1].eventType, NodeEventType.RECOVERED)
        @Assert(events[1].node, "a")
        @Assert(events[1].message.contains("恢复"))
        clock.advance(5000)

        loop.tick()
        @Assert(events.size, 2)
        clock.advance(5000)

        loop.tick()
        @Assert(store.get("a").getOrThrow().consecutiveFailures, 1)
        @Assert(events.size, 2)
        // 失败不清空上一次成功的快照
        @Assert(store.get("a").getOrThrow().snapshot.isSome())
        clock.advance(5000)

        loop.tick()
        @Assert(events.size, 3)
        @Assert(events[2].eventType, NodeEventType.UNREACHABLE)
        @Assert(events[2].failures, 2)
    }
}

/** 9.5：告警评估抛错被隔离，tick 计数继续增长。 */
@Test
public class PollLoopAlarmIsolation_test {
    @TestCase
    public func evaluatorExceptionDoesNotStopNextTick(): Unit {
        let clock = FakeClock(1000)
        let a = ScriptedSource("a", [true, true, true], clock)
        let store = NodeStateStore()
        let evaluations = AtomicInt64(0)
        let loop = PollLoop([a], store, clock, 5000, 2, {_ => ()}, {_ =>
                evaluations.fetchAdd(1)
                throw Exception("alarm engine exploded")
            })

        loop.tick()
        clock.advance(5000)
        loop.tick()
        clock.advance(5000)
        loop.tick()

        @Assert(loop.tickCount(), 3)
        @Assert(evaluations.load(), 3)
        @Assert(a.calls.load(), 3)
        @Assert(store.get("a").getOrThrow().status, NodeStatus.ONLINE)
    }
}
