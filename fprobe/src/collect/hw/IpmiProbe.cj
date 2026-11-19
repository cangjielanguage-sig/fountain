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

/** 一条 IPMI 传感器读数。 */
@DataAssist[props fields]
public class IpmiReading {
    private var sensorType: String = ""
    private var name: String = ""
    private var value: Float64 = 0.0
    private var unit: String = ""
    private var status: String = ""
    private var available: Bool = true
    private var error: String = ""

    public init() {}

    public init(sensorType: String, name: String, value: Float64, unit: String, status: String, available: Bool,
        error: String) {
        this.sensorType = sensorType
        this.name = name
        this.value = value
        this.unit = unit
        this.status = status
        this.available = available
        this.error = error
    }
}

/**
 * IPMI 温度、风扇与电源传感器。
 *
 * 命令固定为 `ipmitool sdr`，再按单位/名称过滤出三类传感器：`ipmitool sdr type "Power Supply"`
 * 需要把含空格的类型名作为单个参数，既违反参数模板的稳定性，也容易被不同版本的 ipmitool 误解析。
 * 工具缺失、超时或非零退出都降级为一条 `available=false` 的读数，不影响其它监控项。
 */
public class IpmiProbe {
    private let runner: CommandRunner
    private let enabled: Bool
    private let timeoutMs: Int64

    public init(runner: CommandRunner, enabled!: Bool = true, timeoutMs!: Int64 = 3000) {
        this.runner = runner
        this.enabled = enabled
        this.timeoutMs = timeoutMs
    }

    public func collect(): Array<IpmiReading> {
        if (!enabled) {
            return Array<IpmiReading>()
        }

        let result = runner.run(["ipmitool", "sdr"], timeoutMs: timeoutMs)
        if (result.timedOut) {
            return failure('ipmitool 执行超时（${timeoutMs}ms）')
        }
        if (!result.error.isEmpty()) {
            return failure('ipmitool 不可用: ${result.error}')
        }
        if (result.exitCode != 0) {
            return failure('ipmitool 退出码 ${result.exitCode}: ${result.stderr.trimAscii()}')
        }
        parseSdr(result.stdout)
    }
}

private func failure(message: String): Array<IpmiReading> {
    [IpmiReading("ipmitool", "ipmitool", 0.0, "", "unknown", false, message)]
}

private func parseSdr(text: String): Array<IpmiReading> {
    let readings = ArrayList<IpmiReading>()
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        let parts = line.split("|")
        if (parts.size < 3) {
            continue
        }
        let name = parts[0].trimAscii()
        let reading = parts[1].trimAscii()
        let status = parts[2].trimAscii()
        let tokens = splitTokens(reading)
        if (tokens.isEmpty()) {
            continue
        }

        let unit = normalizeUnit(joinTokens(tokens, 1))
        let sensorType = classifySensor(name, unit)
        if (sensorType.isEmpty()) {
            continue
        }

        let value = match (tryFloat(tokens[0])) {
            case Some(number) => number
            case None =>
                if (sensorType == "Power Supply") {
                    0.0
                } else {
                    continue
                }
        }
        readings.add(IpmiReading(sensorType, name, value, unit, status, true, ""))
    }
    readings.toArray()
}

private func normalizeUnit(raw: String): String {
    let lower = raw.toAsciiLower()
    if (lower.contains("degree")) {
        "C"
    } else if (lower.contains("rpm")) {
        "RPM"
    } else {
        raw
    }
}

private func classifySensor(name: String, unit: String): String {
    if (unit == "C") {
        return "Temperature"
    }
    if (unit == "RPM") {
        return "Fan"
    }
    let lower = name.toAsciiLower()
    if (lower.contains("power") || lower.contains("psu") || lower.contains("supply") || lower.startsWith("ps")) {
        return "Power Supply"
    }
    ""
}
