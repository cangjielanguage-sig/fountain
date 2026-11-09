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
package fountain::fprobe.alarm

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.collect.FakeClock
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot}
import fountain::fprobe.supervisor.{NodeState, NodeStatus}

private func ruleOf(name: String, kind: String, path: String, op: String, threshold: Float64,
    forSeconds: Int64): AlarmRule {
    AlarmRule(name, kind, path, op, threshold, forSeconds, "warning")
}

private func onlineState(node: String, kind: String, dataJson: String, error!: String = ""): NodeState {
    let snapshot = ProbeSnapshot(node, "${node}-host", 0,
        [ProbeAgentData(kind, "${node}-host", dataJson, 0, error)])
    NodeState(node, NodeStatus.ONLINE, 0, Some(snapshot), "", 0)
}

private func stateWith(node: String, agents: Array<ProbeAgentData>): NodeState {
    let snapshot = ProbeSnapshot(node, "${node}-host", 0, agents)
    NodeState(node, NodeStatus.ONLINE, 0, Some(snapshot), "", 0)
}

/** 10.2：DataPath 嵌套路径取值与数组最大值聚合。 */
@Test
public class AlarmEngineValue_test {
    @TestCase
    public func nestedPathUsesMaximumValue(): Unit {
        let clock = FakeClock(1000)
        let events = ArrayList<AlarmEvent>()
        let rule = ruleOf("disk-high", "disk", "$.mounts[*].usedPercent", "gt", 75.0, 0)
        let engine = AlarmEngine([rule], clock, {event => events.add(event)})

        engine.evaluate([onlineState("web1", "disk", '{"mounts":[{"usedPercent":10},{"usedPercent":80}]}')])

        @Assert(events.size, 1)
        @Assert(events[0].eventType, AlarmEventType.FIRING)
        @Assert(events[0].node, "web1")
        @Assert(events[0].rule, "disk-high")
        @Assert(events[0].kind, "disk")
        @Assert(events[0].value.getOrThrow(), 80.0)
        @Assert(events[0].threshold, 75.0)
    }

    @TestCase
    public func missingPathDoesNotFire(): Unit {
        let clock = FakeClock(1000)
        let events = ArrayList<AlarmEvent>()
        let rule = ruleOf("missing", "cpu", "$.notThere", "gt", 1.0, 0)
        let engine = AlarmEngine([rule], clock, {event => events.add(event)})

        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.isEmpty())
    }
}

/** 10.3：forSeconds 需要连续满足，满时长只触发一次。 */
@Test
public class AlarmEngineForSeconds_test {
    @TestCase
    public func firesOnlyAfterContinuousWindow(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let rule = ruleOf("cpu-high", "cpu", "$.usagePercent", "gt", 85.0, 60)
        let engine = AlarmEngine([rule], clock, {event => events.add(event)})

        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.isEmpty())

        clock.advance(30000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.isEmpty())

        clock.advance(30000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.size, 1)
        @Assert(events[0].eventType, AlarmEventType.FIRING)

        clock.advance(30000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.size, 1)
    }

    @TestCase
    public func brokenWindowRestartsTimer(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let rule = ruleOf("cpu-high", "cpu", "$.usagePercent", "gt", 85.0, 60)
        let engine = AlarmEngine([rule], clock, {event => events.add(event)})

        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        clock.advance(30000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":10}')])
        clock.advance(30000)
        // 条件恢复后重新计时，此时只满足了 0 秒
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.isEmpty())

        clock.advance(60000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.size, 1)
    }
}

/** 10.4：冷却、恢复与冷却后重新告警。 */
@Test
public class AlarmEngineCooldown_test {
    @TestCase
    public func cooldownSuppressesRepeatsAndRecoveryIsNotified(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let rule = ruleOf("cpu-high", "cpu", "$.usagePercent", "gt", 85.0, 0)
        let engine = AlarmEngine([rule], clock, {event => events.add(event)}, cooldownMs: 300000)

        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.size, 1)
        @Assert(events[0].eventType, AlarmEventType.FIRING)

        clock.advance(1000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":91}')])
        @Assert(events.size, 1)

        clock.advance(1000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":10}')])
        @Assert(events.size, 2)
        @Assert(events[1].eventType, AlarmEventType.RECOVERY)
        @Assert(events[1].node, "web1")

        clock.advance(1000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":92}')])
        @Assert(events.size, 2)

        clock.advance(300000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":93}')])
        @Assert(events.size, 3)
        @Assert(events[2].eventType, AlarmEventType.FIRING)
    }

    @TestCase
    public func recoveryIsOptional(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let rule = ruleOf("cpu-high", "cpu", "$.usagePercent", "gt", 85.0, 0)
        let engine = AlarmEngine([rule], clock, {event => events.add(event)}, recoverNotify: false)

        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        clock.advance(1000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":10}')])

        @Assert(events.size, 1)
        @Assert(events[0].eventType, AlarmEventType.FIRING)
    }
}

/** 10.5：节点失败、探针 error、缺 kind 三类数据缺失。 */
@Test
public class AlarmEngineMissingData_test {
    @TestCase
    public func nodeFailureOnlyAlarmsAtThreshold(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let engine = AlarmEngine([], clock, {event => events.add(event)}, missingThreshold: 2)

        engine.evaluate([NodeState("web1", NodeStatus.OFFLINE, 1, None<ProbeSnapshot>, "timeout", 0)])
        @Assert(events.isEmpty())

        engine.evaluate([NodeState("web1", NodeStatus.OFFLINE, 2, None<ProbeSnapshot>, "timeout", 0)])
        @Assert(events.size, 1)
        @Assert(events[0].eventType, AlarmEventType.NODE_UNREACHABLE)
        @Assert(events[0].node, "web1")
        @Assert(events[0].message.contains("不可达"))

        // 同一个缺失条件只报一次
        clock.advance(1000)
        engine.evaluate([NodeState("web1", NodeStatus.OFFLINE, 3, None<ProbeSnapshot>, "timeout", 1000)])
        @Assert(events.size, 1)
    }

    @TestCase
    public func nodeRecoveryIsNotified(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let engine = AlarmEngine([], clock, {event => events.add(event)}, missingThreshold: 2)

        engine.evaluate([NodeState("web1", NodeStatus.OFFLINE, 2, None<ProbeSnapshot>, "timeout", 0)])
        clock.advance(1000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":1}')])

        @Assert(events.size, 2)
        @Assert(events[1].eventType, AlarmEventType.RECOVERY)
        @Assert(events[1].node, "web1")
    }

    @TestCase
    public func probeErrorIsReported(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let engine = AlarmEngine([], clock, {event => events.add(event)})

        engine.evaluate([onlineState("web1", "disk", "{}", error: "/proc/diskstats 读取失败")])
        @Assert(events.size, 1)
        @Assert(events[0].eventType, AlarmEventType.PROBE_ERROR)
        @Assert(events[0].kind, "disk")
        @Assert(events[0].message.contains("diskstats"))
    }

    @TestCase
    public func expectedKindMissingIsReported(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let engine = AlarmEngine([], clock, {event => events.add(event)}, expectKinds: ["cpu", "disk"])

        engine.evaluate([stateWith("web1",
            [ProbeAgentData("cpu", "web1-host", '{"usagePercent":1}', 0, "")])])
        @Assert(events.size, 1)
        @Assert(events[0].eventType, AlarmEventType.KIND_MISSING)
        @Assert(events[0].kind, "disk")
        @Assert(events[0].message.contains("disk"))
    }
}

/** 10.6：静音窗口内不发送，到期后恢复。 */
@Test
public class AlarmEngineMute_test {
    @TestCase
    public func mutedRuleStaysSilentUntilExpiry(): Unit {
        let clock = FakeClock(0)
        let events = ArrayList<AlarmEvent>()
        let rule = ruleOf("cpu-high", "cpu", "$.usagePercent", "gt", 85.0, 0)
        let engine = AlarmEngine([rule], clock, {event => events.add(event)})

        engine.mute("cpu-high", 60000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.isEmpty())

        clock.advance(30000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.isEmpty())

        clock.advance(30000)
        engine.evaluate([onlineState("web1", "cpu", '{"usagePercent":90}')])
        @Assert(events.size, 1)
        @Assert(events[0].eventType, AlarmEventType.FIRING)
    }
}
