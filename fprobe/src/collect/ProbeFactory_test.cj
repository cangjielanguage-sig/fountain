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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_probe.ProbeRegistry
import fountain::fprobe.collect.health.{HealthRpcResult, HealthRpcTransport, HttpProbe, HttpProbeResult}
import fountain::fprobe.collect.hw.{CommandResult, FixtureCommandRunner}
import fountain::fprobe.collect.net.{TcpProbe, TcpProbeResult}
import fountain::fprobe.collect.proc.FixtureProcReader
import fountain::fprobe.config.AgentSettings
import fountain::fprobe.rpc.NodeEndpoint

private class NoopHttp <: HttpProbe {
    public func get(url: String, timeoutMs: Int64): HttpProbeResult {
        HttpProbeResult(0, "", 0.0, false, "")
    }
}

private class NoopTcp <: TcpProbe {
    public func connect(host: String, port: UInt16, timeoutMs: Int64): TcpProbeResult {
        TcpProbeResult(false, 0.0, "noop")
    }
}

private class NoopHealth <: HealthRpcTransport {
    public func call(target: NodeEndpoint, timeoutMs: Int64): HealthRpcResult {
        HealthRpcResult(None, "", false, 0.0)
    }
}

/**
 * 内置探针注册：条件项只在配置存在时出现，重复注册不抛。
 */
@Test
public class ProbeFactory_test {
    private func settings(): AgentSettings {
        Config.set([("probe_mvcHealthUrl", ""), ("probe_rpcHealthTargets", ""),
            ("probe_serviceTargets", ""), ("probe_snmpDevices", ""), ("probe_ipmiEnabled", "false"),
            ("probe_smartDevices", ""), ("probe_networkInterfaces", "")])
        AgentSettings.load()
    }

    private func register(settings: AgentSettings): Unit {
        ProbeFactory.register(settings, FixtureProcReader([]), FixtureCommandRunner(), NoopHttp(),
            NoopTcp(), NoopHealth())
    }

    @TestCase
    public func registersFiveCoreKindsPlusHardware(): Unit {
        ProbeRegistry.clear()
        register(settings())
        let kinds = ProbeRegistry.agents()
        @Assert(kinds.contains("cpu"))
        @Assert(kinds.contains("memory"))
        @Assert(kinds.contains("disk"))
        @Assert(kinds.contains("system"))
        @Assert(kinds.contains("network"))
        @Assert(kinds.contains("hardware"))
        @Assert(kinds.size, 6)
    }

    @TestCase
    public func conditionalKindsFollowConfiguration(): Unit {
        ProbeRegistry.clear()
        Config.set([("probe_mvcHealthUrl", "http://127.0.0.1:8080/health"),
            ("probe_rpcHealthTargets", "local@127.0.0.1:12323"),
            ("probe_serviceTargets", "web@http://127.0.0.1:8080/health"),
            ("probe_snmpDevices", "sw1@127.0.0.1@public")])
        register(AgentSettings.load())
        let kinds = ProbeRegistry.agents()
        @Assert(kinds.contains("mvc-health"))
        @Assert(kinds.contains("rpc-health"))
        @Assert(kinds.contains("service"))
        @Assert(kinds.contains("topology"))
    }

    @TestCase
    public func duplicateRegistrationIsIgnored(): Unit {
        ProbeRegistry.clear()
        let first = settings()
        register(first)
        register(first)
        @Assert(ProbeRegistry.agents().size, 6)
    }

    @TestCase
    public func instantiateReturnsRegisteredAgents(): Unit {
        ProbeRegistry.clear()
        register(settings())
        let agents = ProbeFactory.instantiate()
        @Assert(agents.size, 6)
        let kinds = ArrayList<String>()
        for (agent in agents) {
            kinds.add(agent.kind)
        }
        @Assert(kinds.contains("cpu"))
        @Assert(kinds.contains("hardware"))
    }
}
