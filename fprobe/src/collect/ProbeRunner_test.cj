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
package fountain::fprobe.collect

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.{JsonObject, JsonValue}
import fountain::f_probe.{ProbeAgent, ProbeErrorCode, ProbeException}
import fountain::fprobe.collect.proc.{CpuProbe, FixtureProcReader}
import fountain::fprobe.snapshot.{ProbeAgentData, SnapshotStore}

private let CPU_FRAME_1 = '''
cpu  100 0 100 800 0 0 0 0 0 0
cpu0 50 0 50 400 0 0 0 0 0 0
cpu1 50 0 50 400 0 0 0 0 0 0
'''

private let CPU_FRAME_2 = '''
cpu  150 0 150 900 0 0 0 0 0 0
cpu0 75 0 75 450 0 0 0 0 0 0
cpu1 75 0 75 450 0 0 0 0 0 0
'''

private let CPU_LOADAVG = "0.10 0.20 0.30 1/100 1000\n"

@Test
public class ProbeRunner_test {
    /** 一次 tick 发布全部探针；坏探针只影响自己的条目。 */
    @TestCase
    public func tickPublishesAllAgentsAndIsolatesFailure(): Unit {
        let clock = FakeClock(1000)
        let store = SnapshotStore()
        let good = StaticAgent("cpu", '{"usagePercent":12.5}')
        let bad = MutableAgent("disk", '{"usedPercent":1}', failing: true)
        let runner = ProbeRunner([good, bad], store, clock, node: "node-a", host: "host-a", warmupMs: 200)

        let snapshot = runner.tick()

        @Assert(snapshot.node, "node-a")
        @Assert(snapshot.host, "host-a")
        @Assert(snapshot.timestamp, 1000)
        @Assert(snapshot.agents.size, 2)
        @Assert(snapshot.agents[0].kind, "cpu")
        @Assert(snapshot.agents[0].host, "host-a")
        @Assert(snapshot.agents[0].dataJson.contains("12.5"))
        @Assert(snapshot.agents[0].error, "")
        @Assert(snapshot.agents[0].collectedAt, 1000)
        @Assert(snapshot.agents[1].kind, "disk")
        @Assert(snapshot.agents[1].dataJson, "")
        @Assert(snapshot.agents[1].error.contains("boom"))
        @Assert(snapshot.agents[1].collectedAt, 0)

        // store 与返回值是同一批数据
        let published = store.collect()
        @Assert(published.timestamp, 1000)
        @Assert(published.agents.size, 2)
    }

    /** 探针失败时保留上一次成功的数据与时间戳，只更新 error。 */
    @TestCase
    public func failedProbeKeepsLastSuccessfulData(): Unit {
        let clock = FakeClock(1000)
        let store = SnapshotStore()
        let flaky = MutableAgent("cpu", '{"v":1}')
        let runner = ProbeRunner([flaky], store, clock, node: "n", host: "h")

        let first = runner.tick()
        @Assert(first.agents[0].dataJson.contains("\"v\":1"))
        @Assert(first.agents[0].collectedAt, 1000)

        flaky.payloadText = '{"v":2}'
        flaky.failing = true
        clock.advance(500)
        let second = runner.tick()

        @Assert(second.timestamp, 1500)
        @Assert(second.agents[0].dataJson.contains("\"v\":1"))
        @Assert(second.agents[0].collectedAt, 1000)
        @Assert(second.agents[0].error.contains("boom-cpu"))

        // 恢复后使用新数据并清空 error
        flaky.failing = false
        clock.advance(500)
        let third = runner.tick()
        @Assert(third.agents[0].dataJson.contains("\"v\":2"))
        @Assert(third.agents[0].collectedAt, 2000)
        @Assert(third.agents[0].error, "")
    }

    /** CPU 首帧前做一次短差分：预热推进 200ms，首个发布快照的使用率不为 0。 */
    @TestCase
    public func warmupEstablishesCpuBaseline(): Unit {
        let clock = FakeClock(1000)
        let store = SnapshotStore()
        let reader = FixtureProcReader([("/proc/stat", CPU_FRAME_1), ("/proc/loadavg", CPU_LOADAVG)])
        let cpu = CpuProbe(reader)
        let runner = ProbeRunner([cpu], store, clock, node: "n", host: "h", warmupMs: 200)

        runner.warmup()
        @Assert(clock.nowMs(), 1200)

        reader.set("/proc/stat", CPU_FRAME_2)
        let snapshot = runner.tick()
        let data = JsonValue.fromStr(snapshot.agents[0].dataJson).asObject()
        let usage = data.get("usagePercent").getOrThrow().asDecimal().toFloat64()
        @Assert(usage > 0.0)
        @Assert(abs(usage - 50.0) < 1e-9)
    }

    /** snapshot() 只读最近一次发布的快照，不触发新的采集。 */
    @TestCase
    public func snapshotReturnsPublishedWithoutCollecting(): Unit {
        let clock = FakeClock(1000)
        let store = SnapshotStore()
        let agent = MutableAgent("cpu", '{"v":1}')
        let runner = ProbeRunner([agent], store, clock, node: "n", host: "h")
        runner.tick()

        agent.payloadText = '{"v":2}'
        let snapshot = runner.snapshot()
        @Assert(snapshot.agents[0].dataJson.contains("\"v\":1"))
    }
}

@Test
public class ProbeSnapshotBuilder_test {
    /** dataJson 必须与 JsonValue.from(agent.data) 往返等价。 */
    @TestCase
    public func encodeRoundTripsThroughJson(): Unit {
        let agent = StaticAgent("cpu", '{"name":"中文 \\"quoted\\" <>&","usagePercent":12.5,"items":[1,2,3]}')
        let text = ProbeSnapshotBuilder.encode(agent)
        let original = JsonValue.from(agent.data)
        let restored = JsonValue.fromStr(text)
        @Assert(restored.toString(), original.toString())
    }

    /** agent 未声明 host 时用节点默认 host 补齐。 */
    @TestCase
    public func agentDataFallsBackToDefaultHost(): Unit {
        let agent = StaticAgent("cpu", "{}")
        let data = ProbeSnapshotBuilder.agentData(agent, "fallback-host", 42)
        @Assert(data.kind, "cpu")
        @Assert(data.host, "fallback-host")
        @Assert(data.collectedAt, 42)
        @Assert(data.error, "")
        @Assert(data.dataJson, "{}")
    }

    /** agent 自带 host 时优先使用 agent 的值。 */
    @TestCase
    public func agentDataPrefersAgentHost(): Unit {
        let agent = StaticAgent("cpu", "{}", host: "agent-host")
        let data = ProbeSnapshotBuilder.agentData(agent, "fallback-host", 42)
        @Assert(data.host, "agent-host")
    }

    /** 整批快照由 builder 组装，字段原样带入。 */
    @TestCase
    public func buildsWholeSnapshot(): Unit {
        let agents: Array<ProbeAgentData> = [ProbeAgentData("cpu", "h", "{}", 1, "")]
        let snapshot = ProbeSnapshotBuilder.build("node", "h", 1, agents)
        @Assert(snapshot.node, "node")
        @Assert(snapshot.host, "h")
        @Assert(snapshot.timestamp, 1)
        @Assert(snapshot.agents.size, 1)
    }
}

class StaticAgent <: ProbeAgent {
    private let kindName: String
    private let payload: JsonObject
    private let hostName: String

    public init(kind: String, payload: String, host!: String = "") {
        this.kindName = kind
        this.payload = JsonValue.fromStr(payload).asObject()
        this.hostName = host
    }

    public prop kind: String {
        get() {
            kindName
        }
    }

    public prop host: String {
        get() {
            hostName
        }
    }

    public prop data: JsonObject {
        get() {
            payload
        }
    }
}

class MutableAgent <: ProbeAgent {
    private let kindName: String
    public var payloadText: String
    public var failing: Bool

    public init(kind: String, payload: String, failing!: Bool = false) {
        this.kindName = kind
        this.payloadText = payload
        this.failing = failing
    }

    public prop kind: String {
        get() {
            kindName
        }
    }

    public prop data: JsonObject {
        get() {
            if (failing) {
                throw ProbeException(ProbeErrorCode.COLLECT, "boom-${kindName}")
            }
            JsonValue.fromStr(payloadText).asObject()
        }
    }
}
