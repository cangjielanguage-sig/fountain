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
package fountain::fprobe.collect.hw

import std.collection.ArrayList
import fountain::f_data.*
import fountain::f_data.macros.*

/** SNMP 传感器表的默认 walk 根（LM-SENSORS-MIB）。 */
public const SNMP_SENSOR_OID = "1.3.6.1.4.1.2021.13.16"

/** 一台 SNMP 设备的连接参数；community 不得含空白或 shell 元字符。 */
public class SnmpDevice {
    public let name: String
    public let host: String
    public let community: String

    public init(name: String, host: String, community: String) {
        this.name = name
        this.host = host
        this.community = community
    }
}

/** 一条 SNMP 传感器读数。 */
@DataAssist[props fields]
public class SnmpReading {
    private var device: String = ""
    private var oid: String = ""
    private var name: String = ""
    private var value: String = ""
    private var available: Bool = true
    private var error: String = ""

    public init() {}

    public init(device: String, oid: String, name: String, value: String, available: Bool, error: String) {
        this.device = device
        this.oid = oid
        this.name = name
        this.value = value
        this.available = available
        this.error = error
    }
}

/**
 * SNMP 传感器采集。
 *
 * 命令模板固定为 `snmpbulkwalk -v2c -c <community> <host> <oid>`，全部参数以数组直传；
 * 任一设备失败只产生该设备的 `available=false` 读数，不中断其它设备。
 */
public class SnmpProbe {
    private let runner: CommandRunner
    private let devices: Array<SnmpDevice>
    private let timeoutMs: Int64

    public init(runner: CommandRunner, devices: Array<SnmpDevice>, timeoutMs!: Int64 = 3000) {
        this.runner = runner
        this.devices = devices
        this.timeoutMs = timeoutMs
    }

    public func collect(): Array<SnmpReading> {
        let readings = ArrayList<SnmpReading>()
        for (device in devices) {
            let problem = unsafeReason(device)
            if (!problem.isEmpty()) {
                readings.add(failure(device.name, problem))
                continue
            }
            let result = runner.run(["snmpbulkwalk", "-v2c", "-c", device.community, device.host, SNMP_SENSOR_OID],
                timeoutMs: timeoutMs)
            if (result.timedOut) {
                readings.add(failure(device.name, 'snmpbulkwalk 执行超时（${timeoutMs}ms）'))
                continue
            }
            if (!result.error.isEmpty()) {
                readings.add(failure(device.name, 'snmpbulkwalk 不可用: ${result.error}'))
                continue
            }
            if (result.exitCode != 0) {
                readings.add(failure(device.name,
                    'snmpbulkwalk 退出码 ${result.exitCode}: ${result.stderr.trimAscii()}'))
                continue
            }
            readings.add(all: parseWalk(device.name, result.stdout))
        }
        readings.toArray()
    }
}

private func failure(device: String, message: String): SnmpReading {
    SnmpReading(device, "", "", "", false, message)
}

private func unsafeReason(device: SnmpDevice): String {
    if (device.community.isEmpty()) {
        return '设备 ${device.name} 的 community 不能为空'
    }
    if (hasWhitespace(device.host) || hasShellMeta(device.host)) {
        return '设备 ${device.name} 的 host 含非法字符: "${device.host}"'
    }
    if (hasWhitespace(device.community) || hasShellMeta(device.community)) {
        return '设备 ${device.name} 的 community 含非法字符: "${device.community}"'
    }
    ""
}

private func parseWalk(device: String, text: String): Array<SnmpReading> {
    let readings = ArrayList<SnmpReading>()
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        let separator = match (line.indexOf(" = ")) {
            case Some(index) => index
            case None => continue
        }
        let oid = line[0..separator].trimAscii()
        let rest = line[separator + 3..].trimAscii()
        if (oid.isEmpty() || rest.isEmpty()) {
            continue
        }
        let value = match (rest.indexOf(": ")) {
            case Some(index) => stripQuotes(rest[index + 2..])
            case None => stripQuotes(rest)
        }
        readings.add(SnmpReading(device, oid, oidName(oid), value, true, ""))
    }
    readings.toArray()
}

private func oidName(oid: String): String {
    match (oid.lastIndexOf('.')) {
        case Some(index) => oid[index + 1..]
        case None => oid
    }
}
