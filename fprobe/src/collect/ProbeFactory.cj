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
import fountain::f_probe.{ProbeAgent, ProbeRegistry}
import fountain::fprobe.collect.health.{FHttpClientProbe, FNetHealthRpcTransport, HealthRpcTransport,
    HttpProbe, MvcHealthProbe, RpcHealthProbe}
import fountain::fprobe.collect.hw.{CommandRunner, FProcessRunner, HardwareProbe, IpmiProbe, SmartProbe,
    SnmpProbe}
import fountain::fprobe.collect.net.{ServiceReachabilityProbe, StdTcpProbe, TcpProbe}
import fountain::fprobe.collect.proc.{CpuProbe, DiskProbe, MemoryProbe, NetworkProbe, ProcReader, RealProcReader,
    SystemProbe}
import fountain::fprobe.collect.topology.TopologyProbe
import fountain::fprobe.config.AgentSettings

/**
 * 内置探针的组装与注册。
 *
 * 注册进 [ProbeRegistry] 而不是直接返回数组，是为了让 `kinds()` 与 supervisor
 * 看到的监控项一致；扩展库随后加载，因此不能覆盖同名 `kind`。
 *
 * 采集器接受注入，用例可用 fixture reader / 假命令执行器断言注册结果，
 * 生产装配使用 `RealProcReader`、`FProcessRunner`、`FHttpClientProbe`、`StdTcpProbe`
 * 与 `FNetHealthRpcTransport`。
 */
public class ProbeFactory {
    /** 注册内置监控项；已存在的 `kind` 跳过，保证重复调用幂等。 */
    public static func register(settings: AgentSettings, reader: ProcReader, runner: CommandRunner,
        http: HttpProbe, tcp: TcpProbe, health: HealthRpcTransport): Unit {
        registerIfAbsent("cpu", {=> CpuProbe(reader)})
        registerIfAbsent("memory", {=> MemoryProbe(reader)})
        registerIfAbsent("disk", {=> DiskProbe(reader, runner, settings.diskExcludeFs)})
        registerIfAbsent("system", {=> SystemProbe(reader)})
        registerIfAbsent("network", {=> NetworkProbe(reader, settings.networkInterfaces)})
        registerIfAbsent("hardware", {=>
            HardwareProbe(IpmiProbe(runner, enabled: settings.ipmiEnabled, timeoutMs: settings.commandTimeoutMs),
                SnmpProbe(runner, settings.snmpDevices, timeoutMs: settings.commandTimeoutMs),
                SmartProbe(runner, settings.smartDevices, timeoutMs: settings.commandTimeoutMs))
        })

        if (!settings.mvcHealthUrl.trimAscii().isEmpty()) {
            registerIfAbsent("mvc-health", {=>
                MvcHealthProbe(http, settings.mvcHealthUrl, timeoutMs: settings.httpTimeoutMs)
            })
        }
        if (!settings.rpcHealthTargets.isEmpty()) {
            registerIfAbsent("rpc-health", {=>
                RpcHealthProbe(health, settings.rpcHealthTargets, timeoutMs: settings.httpTimeoutMs)
            })
        }
        if (!settings.serviceTargets.isEmpty()) {
            registerIfAbsent("service", {=>
                ServiceReachabilityProbe(http, tcp, settings.serviceTargets, timeoutMs: settings.httpTimeoutMs)
            })
        }
        if (!settings.snmpDevices.isEmpty()) {
            registerIfAbsent("topology", {=>
                TopologyProbe(runner, settings.snmpDevices, timeoutMs: settings.commandTimeoutMs)
            })
        }
    }

    /** 按注册表顺序实例化全部监控项。 */
    public static func instantiate(): Array<ProbeAgent> {
        let kinds = ProbeRegistry.agents()
        let agents = ArrayList<ProbeAgent>()
        for (kind in kinds) {
            match (ProbeRegistry.agent(kind)) {
                case Some(factory) => agents.add(factory())
                case None => ()
            }
        }
        agents.toArray()
    }

    /** 生产环境的默认注册：真实 /proc、真实命令、真实 HTTP 与 TCP。 */
    public static func registerProduction(settings: AgentSettings): Unit {
        register(settings, RealProcReader(), FProcessRunner(), FHttpClientProbe(), StdTcpProbe(),
            FNetHealthRpcTransport())
    }

    private static func registerIfAbsent(kind: String, factory: () -> ProbeAgent): Unit {
        match (ProbeRegistry.agent(kind)) {
            case Some(_) => ()
            case None => ProbeRegistry.registerAgent(kind, factory)
        }
    }
}
