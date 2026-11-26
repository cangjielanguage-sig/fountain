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
package fountain::fprobe.collect.topology

import std.collection.{ArrayList, HashMap, HashSet}
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.ProbeAgent
import fountain::fprobe.collect.hw.{CommandRunner, SnmpDevice}

/** 拓扑中的一台设备及其端口。 */
@DataAssist[props fields]
public class TopologyDevice {
    private var name: String = ""
    private var host: String = ""
    private var ports: Array<String> = []

    public init() {}

    public init(name: String, host: String, ports: Array<String>) {
        this.name = name
        this.host = host
        this.ports = ports
    }
}

/** 一条无向链路；`from/localPort` 与 `to/remotePort` 互为一对端点。 */
@DataAssist[props fields]
public class TopologyLink {
    private var from: String = ""
    private var to: String = ""
    private var localPort: String = ""
    private var remotePort: String = ""

    public init() {}

    public init(from: String, to: String, localPort: String, remotePort: String) {
        this.from = from
        this.to = to
        this.localPort = localPort
        this.remotePort = remotePort
    }
}

/** `topology` 监控项的数据形状。 */
@DataAssist[props fields]
public class TopologySample {
    private var devices: Array<TopologyDevice> = []
    private var links: Array<TopologyLink> = []
    private var error: String = ""

    public init() {}

    public init(devices: Array<TopologyDevice>, links: Array<TopologyLink>, error: String) {
        this.devices = devices
        this.links = links
        this.error = error
    }
}

private class WalkResult {
    let output: String
    let error: String

    init(output: String, error: String) {
        this.output = output
        this.error = error
    }
}

/**
 * 网络拓扑：通过 SNMP IF-MIB + LLDP-MIB 发现设备端口与邻接关系。
 *
 * 没有配置 `probe_snmpDevices` 或工具不可用时只回写 `error`，不抛异常。
 * 邻接按两端端点（设备名 + 端口名）排序后去重，两台设备互相报告同一条链路时只保留一条。
 */
public class TopologyProbe <: ProbeAgent {
    private let runner: CommandRunner
    private let devices: Array<SnmpDevice>
    private let timeoutMs: Int64

    public init(runner: CommandRunner, devices: Array<SnmpDevice>, timeoutMs!: Int64 = 3000) {
        this.runner = runner
        this.devices = devices
        this.timeoutMs = timeoutMs
    }

    public prop kind: String {
        get() {
            "topology"
        }
    }

    public prop data: JsonObject {
        get() {
            if (devices.isEmpty()) {
                return json(TopologySample([], [], "未配置 probe_snmpDevices，拓扑发现已跳过"))
            }

            let errors = ArrayList<String>()
            let discovered = ArrayList<TopologyDevice>()
            let known = HashSet<String>()
            let neighbours = ArrayList<(String, Array<LldpObservation>)>()

            for (device in devices) {
                let ifWalk = runWalk(device, IF_MIB_WALK_OID)
                var ports = Array<IfPort>()
                if (!ifWalk.error.isEmpty()) {
                    errors.add(ifWalk.error)
                } else {
                    ports = parseIfMib(ifWalk.output)
                }

                let portNames = HashMap<Int64, String>()
                let names = ArrayList<String>()
                for (port in ports) {
                    portNames[port.index] = port.name
                    names.add(port.name)
                }

                let lldpWalk = runWalk(device, LLDP_MIB_WALK_OID)
                var observations = Array<LldpObservation>()
                if (!lldpWalk.error.isEmpty()) {
                    errors.add(lldpWalk.error)
                } else {
                    observations = parseLldp(lldpWalk.output, portNames)
                }

                if (!known.contains(device.name)) {
                    discovered.add(TopologyDevice(device.name, device.host, names.toArray()))
                    known.add(device.name)
                }
                neighbours.add((device.name, observations))
            }

            let links = ArrayList<TopologyLink>()
            let seen = HashSet<String>()
            for ((deviceName, observations) in neighbours) {
                for (observation in observations) {
                    if (observation.remoteSysName.isEmpty() || observation.localPort.isEmpty() ||
                        observation.remotePort.isEmpty()) {
                        continue
                    }
                    let key = edgeKey(deviceName, observation.localPort, observation.remoteSysName,
                        observation.remotePort)
                    if (seen.contains(key)) {
                        continue
                    }
                    seen.add(key)
                    links.add(TopologyLink(deviceName, observation.remoteSysName, observation.localPort,
                        observation.remotePort))
                    if (!known.contains(observation.remoteSysName)) {
                        discovered.add(TopologyDevice(observation.remoteSysName, observation.remoteSysName,
                            [observation.remotePort]))
                        known.add(observation.remoteSysName)
                    }
                }
            }

            json(TopologySample(discovered.toArray(), links.toArray(), joinErrors(errors)))
        }
    }

    private func runWalk(device: SnmpDevice, oid: String): WalkResult {
        try {
            let result = runner.run(["snmpbulkwalk", "-v2c", "-c", device.community, device.host, oid],
                timeoutMs: timeoutMs)
            if (result.timedOut) {
                return WalkResult("", '设备 ${device.name} 的 ${oid} walk 超时（${timeoutMs}ms）')
            }
            if (!result.error.isEmpty()) {
                return WalkResult("", '设备 ${device.name} 的 ${oid} walk 不可用: ${result.error}')
            }
            if (result.exitCode != 0) {
                return WalkResult("", '设备 ${device.name} 的 ${oid} walk 退出码 ${result.exitCode}: ' +
                    result.stderr.trimAscii())
            }
            WalkResult(result.stdout, "")
        } catch (e: Exception) {
            WalkResult("", '设备 ${device.name} 的 ${oid} walk 失败: ${e.message}')
        }
    }
}

private func json(sample: TopologySample): JsonObject {
    JsonValue.from(sample.toData()).asObject()
}

private func edgeKey(from: String, localPort: String, to: String, remotePort: String): String {
    let a = '${from}#${localPort}'
    let b = '${to}#${remotePort}'
    if (a > b) {
        '${b}|${a}'
    } else {
        '${a}|${b}'
    }
}

private func joinErrors(errors: ArrayList<String>): String {
    var result = ""
    for (message in errors) {
        if (!result.isEmpty()) {
            result += "; "
        }
        result += message
    }
    result
}
